//! `@hatch:postfx/bloom` — physically-based mip-pyramid bloom.
//!
//! Four-stage chain:
//!
//!   1. **Threshold** — read scene, write soft-thresholded bright
//!      pixels to `mip[0]` (half-res).
//!   2. **Downsample** — successive `mip[i-1] → mip[i]` 4-tap box
//!      filters, halving resolution each step.
//!   3. **Upsample** — walk back up, additive-blending each smaller
//!      mip into the next-larger one with a 9-tap tent filter.
//!      Requires the `@hatch:gpu` blend-state extension landed in
//!      `wlift_gpu` so the pipeline's `blend = additive` actually
//!      configures the wgpu colour target.
//!   4. **Composite** — sample scene + accumulated bloom `mip[0]`
//!      and write the sum to the chain's output view.
//!
//! Memory: one mip pyramid (`_levels` textures). Default 4 levels,
//! so a 1280×720 surface allocates ~640×360 + 320×180 + 160×90 +
//! 80×45 ≈ 0.55 megapixels of intermediate storage.

import "@hatch:game" for PostPass

/// Mip-pyramid bloom. Sample order: scene → threshold → downsample
/// chain → upsample chain (additive) → composite.
class Bloom is PostPass {
  /// Build a bloom pass.
  ///
  /// | Key | Type | Default | Notes |
  /// |---|---|---|---|
  /// | `threshold` | `Num` | `1.0` | Luminance cutoff for the bright-pass extract. |
  /// | `knee`      | `Num` | `0.5` | Smoothstep width around `threshold` (softer edge). |
  /// | `intensity` | `Num` | `0.6` | Multiplier on the bloom mip during the final composite. |
  /// | `levels`    | `Num` | `4`   | Mip-pyramid depth; higher = wider, softer halos. |
  /// | `filterRadius` | `Num` | `1.0` | Upsample tent-kernel radius in texels. |
  ///
  /// @param {Map} opts
  construct new(opts) {
    super()
    _threshold    = Bloom.numOr_(opts, "threshold",    1.0)
    _knee         = Bloom.numOr_(opts, "knee",         0.5)
    _intensity    = Bloom.numOr_(opts, "intensity",    0.6)
    _levels       = Bloom.intOr_(opts, "levels",       4)
    _filterRadius = Bloom.numOr_(opts, "filterRadius", 1.0)
    _initialised  = false
  }

  /// Build with defaults.
  construct new() {
    super()
    _threshold    = 1.0
    _knee         = 0.5
    _intensity    = 0.6
    _levels       = 4
    _filterRadius = 1.0
    _initialised  = false
  }

  static numOr_(opts, key, fallback) {
    if (opts == null || !opts.containsKey(key)) return fallback
    return opts[key]
  }
  static intOr_(opts, key, fallback) {
    if (opts == null || !opts.containsKey(key)) return fallback
    return opts[key].floor
  }

  /// @returns {Num}
  threshold       { _threshold }
  /// @param   {Num} v
  threshold=(v)   { _threshold = v }
  /// @returns {Num}
  knee            { _knee }
  /// @param   {Num} v
  knee=(v)        { _knee = v }
  /// @returns {Num}
  intensity       { _intensity }
  /// @param   {Num} v
  intensity=(v)   { _intensity = v }
  /// @returns {Num}
  levels          { _levels }
  /// @returns {Num}
  filterRadius    { _filterRadius }
  /// @param   {Num} v
  filterRadius=(v){ _filterRadius = v }

  name { "bloom" }

  // 2 * levels steps:
  //   step 0          : threshold (scene → mip[0])
  //   steps 1..L-1    : downsample mip[i-1] → mip[i]
  //   steps L..2L-2   : upsample mip[end-...] → mip[…] (additive)
  //   step 2L-1       : composite (scene + mip[0]) → outputView
  stepCount { 2 * _levels }

  // Mip pyramid: width/2^(i+1) × height/2^(i+1). Surface-format
  // so the output blends straight into the chain's pong/final
  // view without a format mismatch.
  requestTargets(width, height) {
    var out = []
    var d = 2
    var i = 0
    while (i < _levels) {
      out.add({
        "width":  (width  / d).floor,
        "height": (height / d).floor,
        "format": "rgba16float"
      })
      d = d * 2
      i = i + 1
    }
    return out
  }

  // Build all four pipelines + bind-group layouts on add. We
  // can't reuse the chain's `buildFragmentPipeline_` helper
  // because (a) the upsample step needs additive blending, (b)
  // the composite step samples two textures, and (c) each
  // pipeline binds an `rgba16float` target instead of the
  // chain's surface format.
  onAdded_(orchestrator) {
    _device    = orchestrator.device_
    _sampler   = orchestrator.sampler_
    _vertexWgsl = orchestrator.vertexWgsl_
    _outputFormat = orchestrator.surfaceFormat_

    // Bind-group layouts. Threshold, downsample, upsample all
    // bind 1 input texture; composite binds 2.
    _bglOneInput = _device.createBindGroupLayout({
      "entries": [
        { "binding": 0, "visibility": ["fragment"], "kind": "texture" },
        { "binding": 1, "visibility": ["fragment"], "kind": "sampler" },
        { "binding": 2, "visibility": ["fragment"], "kind": "uniform" }
      ]
    })
    _bglTwoInputs = _device.createBindGroupLayout({
      "entries": [
        { "binding": 0, "visibility": ["fragment"], "kind": "texture" },
        { "binding": 1, "visibility": ["fragment"], "kind": "sampler" },
        { "binding": 2, "visibility": ["fragment"], "kind": "texture" },
        { "binding": 3, "visibility": ["fragment"], "kind": "uniform" }
      ]
    })
    _layoutOneInput  = _device.createPipelineLayout({ "bindGroupLayouts": [_bglOneInput] })
    _layoutTwoInputs = _device.createPipelineLayout({ "bindGroupLayouts": [_bglTwoInputs] })

    // Threshold + downsample + upsample all write to mip targets
    // in `rgba16float`. Composite writes to the chain's surface
    // format (typically `bgra8unorm`).
    _pipelineThreshold = buildPipelineOneInput_(
      Bloom.SHADER_THRESHOLD_, "rgba16float", null
    )
    _pipelineDownsample = buildPipelineOneInput_(
      Bloom.SHADER_DOWNSAMPLE_, "rgba16float", null
    )
    _pipelineUpsample = buildPipelineOneInput_(
      Bloom.SHADER_UPSAMPLE_, "rgba16float", "additive"
    )
    _pipelineComposite = buildPipelineTwoInputs_(
      Bloom.SHADER_COMPOSITE_, _outputFormat, null
    )

    // Uniform buffers — one per shader that takes one. Threshold
    // takes (threshold, knee, _, _); upsample takes (radius, _, _, _);
    // composite takes (intensity, _, _, _).
    _uboThreshold = _device.createBuffer({
      "size":  16, "usage": ["uniform", "copy-dst"],
      "label": "bloom-threshold-ubo"
    })
    _uboUpsample = _device.createBuffer({
      "size":  16, "usage": ["uniform", "copy-dst"],
      "label": "bloom-upsample-ubo"
    })
    _uboComposite = _device.createBuffer({
      "size":  16, "usage": ["uniform", "copy-dst"],
      "label": "bloom-composite-ubo"
    })

    // Downsample has no uniforms, but the standard one-input
    // layout includes a UBO binding — provide a tiny zero buffer
    // so the bind group is valid.
    _uboEmpty = _device.createBuffer({
      "size":  16, "usage": ["uniform", "copy-dst"],
      "label": "bloom-empty-ubo"
    })

    // Per-step bind groups + per-step scratch. Reset on every
    // resize (via the chain's setIntermediates_ which clears
    // bindGroups_).
    _bindGroupCache = []
    _scratch        = [0, 0, 0, 0]
    _initialised    = true
  }

  buildPipelineOneInput_(fragmentWgsl, targetFormat, blendMode) {
    var shader = _device.createShaderModule({
      "code":  _vertexWgsl + fragmentWgsl,
      "label": "bloom-" + name + "-one-input"
    })
    var target = { "format": targetFormat }
    if (blendMode != null) target["blend"] = blendMode
    return _device.createRenderPipeline({
      "layout":   _layoutOneInput,
      "vertex":   { "module": shader, "entryPoint": "vs_main" },
      "fragment": {
        "module":     shader,
        "entryPoint": "fs_main",
        "targets":    [target]
      },
      "primitive": { "topology": "triangle-list" },
      "label":     "bloom-pipe-one-input"
    })
  }

  buildPipelineTwoInputs_(fragmentWgsl, targetFormat, blendMode) {
    var shader = _device.createShaderModule({
      "code":  _vertexWgsl + fragmentWgsl,
      "label": "bloom-" + name + "-two-inputs"
    })
    var target = { "format": targetFormat }
    if (blendMode != null) target["blend"] = blendMode
    return _device.createRenderPipeline({
      "layout":   _layoutTwoInputs,
      "vertex":   { "module": shader, "entryPoint": "vs_main" },
      "fragment": {
        "module":     shader,
        "entryPoint": "fs_main",
        "targets":    [target]
      },
      "primitive": { "topology": "triangle-list" },
      "label":     "bloom-pipe-two-inputs"
    })
  }

  // Cached bind-group lookup. Each pipeline + (inputViewId,
  // inputViewId2) tuple maps to one bind group; cleared by the
  // chain on resize.
  cacheBindGroup_(layout, entries, key) {
    var i = 0
    while (i < _bindGroupCache.count) {
      if (_bindGroupCache[i]["key"] == key) return _bindGroupCache[i]["bg"]
      i = i + 1
    }
    var bg = _device.createBindGroup({
      "layout":  layout,
      "entries": entries,
      "label":   "bloom-bg"
    })
    _bindGroupCache.add({ "key": key, "bg": bg })
    return bg
  }

  // The chain calls this once per stepIndex; we route to the
  // right sub-shader and dispatch the right pass.
  dispatchStep_(orchestrator, encoder, ctx) {
    var sceneView = ctx["inputView"]
    var mips      = ctx["intermediates"]
    var finalOut  = ctx["outputView"]
    var step      = ctx["stepIndex"]

    if (step == 0) {
      runThreshold_(encoder, sceneView, mips[0])
    } else if (step < _levels) {
      // Downsample mip[step - 1] → mip[step].
      runDownsample_(encoder, mips[step - 1], mips[step])
    } else if (step < 2 * _levels - 1) {
      // Upsample. After threshold + (L-1) downsamples, we have
      // mips populated 0..L-1. Now walk back: at upsample step k
      // (0-indexed from L), read mip[L - 1 - k] and additive-blend
      // into mip[L - 2 - k].
      var k = step - _levels
      var inputIdx  = _levels - 1 - k
      var outputIdx = _levels - 2 - k
      runUpsample_(encoder, mips[inputIdx], mips[outputIdx])
    } else {
      // Composite scene + bloom mip[0] → final output.
      runComposite_(encoder, sceneView, mips[0], finalOut)
    }
  }

  runThreshold_(encoder, inputView, outputView) {
    _scratch[0] = _threshold
    _scratch[1] = _knee
    _scratch[2] = 0
    _scratch[3] = 0
    _uboThreshold.writeFloats(0, _scratch)

    var bg = cacheBindGroup_(_bglOneInput, [
      { "binding": 0, "view":    inputView },
      { "binding": 1, "sampler": _sampler },
      { "binding": 2, "buffer":  _uboThreshold }
    ], "thresh:" + inputView.id.toString)

    var rp = encoder.beginRenderPass({
      "colorAttachments": [{
        "view":       outputView,
        "loadOp":     "clear",
        "clearValue": [0, 0, 0, 1],
        "storeOp":    "store"
      }],
      "label": "bloom-threshold"
    })
    rp.setPipeline(_pipelineThreshold)
    rp.setBindGroup(0, bg)
    rp.draw(6, 1)
    rp.end
  }

  runDownsample_(encoder, inputView, outputView) {
    var bg = cacheBindGroup_(_bglOneInput, [
      { "binding": 0, "view":    inputView },
      { "binding": 1, "sampler": _sampler },
      { "binding": 2, "buffer":  _uboEmpty }
    ], "down:" + inputView.id.toString)

    var rp = encoder.beginRenderPass({
      "colorAttachments": [{
        "view":       outputView,
        "loadOp":     "clear",
        "clearValue": [0, 0, 0, 1],
        "storeOp":    "store"
      }],
      "label": "bloom-downsample"
    })
    rp.setPipeline(_pipelineDownsample)
    rp.setBindGroup(0, bg)
    rp.draw(6, 1)
    rp.end
  }

  runUpsample_(encoder, inputView, outputView) {
    _scratch[0] = _filterRadius
    _scratch[1] = 0
    _scratch[2] = 0
    _scratch[3] = 0
    _uboUpsample.writeFloats(0, _scratch)

    var bg = cacheBindGroup_(_bglOneInput, [
      { "binding": 0, "view":    inputView },
      { "binding": 1, "sampler": _sampler },
      { "binding": 2, "buffer":  _uboUpsample }
    ], "up:" + inputView.id.toString)

    // CRITICAL: `loadOp = "load"` preserves the existing
    // downsample content in the target, so the additive
    // pipeline blend (`src + dst`) accumulates onto it. Without
    // load, the clear wipes everything first and additive blend
    // is equivalent to overwrite — defeating the bloom-up walk.
    var rp = encoder.beginRenderPass({
      "colorAttachments": [{
        "view":     outputView,
        "loadOp":   "load",
        "storeOp":  "store"
      }],
      "label": "bloom-upsample"
    })
    rp.setPipeline(_pipelineUpsample)
    rp.setBindGroup(0, bg)
    rp.draw(6, 1)
    rp.end
  }

  runComposite_(encoder, sceneView, bloomView, outputView) {
    _scratch[0] = _intensity
    _scratch[1] = 0
    _scratch[2] = 0
    _scratch[3] = 0
    _uboComposite.writeFloats(0, _scratch)

    var bg = cacheBindGroup_(_bglTwoInputs, [
      { "binding": 0, "view":    sceneView },
      { "binding": 1, "sampler": _sampler },
      { "binding": 2, "view":    bloomView },
      { "binding": 3, "buffer":  _uboComposite }
    ], "comp:" + sceneView.id.toString + "," + bloomView.id.toString)

    var rp = encoder.beginRenderPass({
      "colorAttachments": [{
        "view":       outputView,
        "loadOp":     "clear",
        "clearValue": [0, 0, 0, 1],
        "storeOp":    "store"
      }],
      "label": "bloom-composite"
    })
    rp.setPipeline(_pipelineComposite)
    rp.setBindGroup(0, bg)
    rp.draw(6, 1)
    rp.end
  }

  // ── WGSL source for the four fragment stages ───────────────────

  static SHADER_THRESHOLD_ {
    return "
      @group(0) @binding(0) var sceneTex: texture_2d<f32>;
      @group(0) @binding(1) var sceneSampler: sampler;
      struct U {
        threshold: f32,
        knee:      f32,
        _p0:       f32,
        _p1:       f32,
      };
      @group(0) @binding(2) var<uniform> u: U;
      @fragment
      fn fs_main(@location(0) uv: vec2<f32>) -> @location(0) vec4<f32> {
        let c     = textureSample(sceneTex, sceneSampler, uv).rgb;
        let luma  = dot(c, vec3<f32>(0.299, 0.587, 0.114));
        let mask  = smoothstep(u.threshold - u.knee, u.threshold + u.knee, luma);
        return vec4<f32>(c * mask, 1.0);
      }
    "
  }

  static SHADER_DOWNSAMPLE_ {
    return "
      @group(0) @binding(0) var inputTex: texture_2d<f32>;
      @group(0) @binding(1) var inputSampler: sampler;
      // Downsample has no real uniforms; binding 2 is a tiny
      // zero buffer the host wires up so the bind-group layout
      // matches the upsample / threshold shape.
      struct U { _p0: f32, _p1: f32, _p2: f32, _p3: f32 };
      @group(0) @binding(2) var<uniform> u: U;
      @fragment
      fn fs_main(@location(0) uv: vec2<f32>) -> @location(0) vec4<f32> {
        let dims  = vec2<f32>(textureDimensions(inputTex));
        let texel = vec2<f32>(1.0) / dims;
        let a = textureSample(inputTex, inputSampler, uv + vec2<f32>(-texel.x, -texel.y)).rgb;
        let b = textureSample(inputTex, inputSampler, uv + vec2<f32>( texel.x, -texel.y)).rgb;
        let c = textureSample(inputTex, inputSampler, uv + vec2<f32>(-texel.x,  texel.y)).rgb;
        let d = textureSample(inputTex, inputSampler, uv + vec2<f32>( texel.x,  texel.y)).rgb;
        return vec4<f32>((a + b + c + d) * 0.25, 1.0);
      }
    "
  }

  static SHADER_UPSAMPLE_ {
    return "
      @group(0) @binding(0) var inputTex: texture_2d<f32>;
      @group(0) @binding(1) var inputSampler: sampler;
      struct U {
        filterRadius: f32,
        _p0:          f32,
        _p1:          f32,
        _p2:          f32,
      };
      @group(0) @binding(2) var<uniform> u: U;
      @fragment
      fn fs_main(@location(0) uv: vec2<f32>) -> @location(0) vec4<f32> {
        let dims  = vec2<f32>(textureDimensions(inputTex));
        let texel = vec2<f32>(1.0) / dims;
        let r     = u.filterRadius * texel;
        // 9-tap tent kernel (1/16 weighted).
        let a = textureSample(inputTex, inputSampler, uv + vec2<f32>(-r.x, -r.y)).rgb;
        let b = textureSample(inputTex, inputSampler, uv + vec2<f32>( 0.0, -r.y)).rgb;
        let c = textureSample(inputTex, inputSampler, uv + vec2<f32>( r.x, -r.y)).rgb;
        let d = textureSample(inputTex, inputSampler, uv + vec2<f32>(-r.x,  0.0)).rgb;
        let e = textureSample(inputTex, inputSampler, uv).rgb;
        let f = textureSample(inputTex, inputSampler, uv + vec2<f32>( r.x,  0.0)).rgb;
        let g = textureSample(inputTex, inputSampler, uv + vec2<f32>(-r.x,  r.y)).rgb;
        let h = textureSample(inputTex, inputSampler, uv + vec2<f32>( 0.0,  r.y)).rgb;
        let i = textureSample(inputTex, inputSampler, uv + vec2<f32>( r.x,  r.y)).rgb;
        let summed = (a + c + g + i) * 1.0 + (b + d + f + h) * 2.0 + e * 4.0;
        return vec4<f32>(summed / 16.0, 1.0);
      }
    "
  }

  static SHADER_COMPOSITE_ {
    return "
      @group(0) @binding(0) var sceneTex: texture_2d<f32>;
      @group(0) @binding(1) var samp:     sampler;
      @group(0) @binding(2) var bloomTex: texture_2d<f32>;
      struct U {
        intensity: f32,
        _p0:       f32,
        _p1:       f32,
        _p2:       f32,
      };
      @group(0) @binding(3) var<uniform> u: U;
      @fragment
      fn fs_main(@location(0) uv: vec2<f32>) -> @location(0) vec4<f32> {
        let s = textureSample(sceneTex, samp, uv).rgb;
        let b = textureSample(bloomTex, samp, uv).rgb;
        return vec4<f32>(s + b * u.intensity, 1.0);
      }
    "
  }
}
