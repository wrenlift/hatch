//! `@hatch:game/chain` — fullscreen post-processing chain core.
//!
//! Ships the orchestration primitive: scene renders into an
//! offscreen colour target, a sequence of `PostPass` effects then
//! read the previous output and write to the next intermediate,
//! ending with a write into the swap chain. Effects themselves
//! live in `@hatch:postfx` so the engine doesn't carry the full
//! catalogue.
//!
//! ```wren
//! import "@hatch:game"   for Game, PostFX
//! import "@hatch:postfx" for Tonemap, Vignette, Bloom
//!
//! class Demo is Game {
//!   construct new() {}
//!   setup(g) {
//!     g.postFX = PostFX.new(g)
//!     g.postFX.add(Bloom.new({ "threshold": 1.0, "intensity": 0.6 }))
//!     g.postFX.add(Tonemap.new({ "exposure": 1.2 }))
//!     g.postFX.add(Vignette.new({ "strength": 0.4 }))
//!   }
//!   draw(g) {
//!     // `g.pass` is now the scene render target; the chain runs
//!     // after `draw` returns.
//!     _renderer.beginFrame(_camera)
//!     _sprite.draw(_renderer)
//!     _renderer.flush(g.pass)
//!   }
//! }
//! ```
//!
//! ## Writing a new `PostPass`
//!
//! Simple single-pass effect: subclass `PostPass`, override `name`,
//! `fragmentBody` (WGSL), and (if needed) `uniformWgsl` +
//! `uniformBytes` + `writeUniforms`. The orchestrator builds the
//! pipeline, binds your input texture / sampler / uniforms, and
//! runs a single fullscreen draw.
//!
//! Multi-pass effect (bloom, separable blur, depth-of-field):
//! override `stepCount` to return N, `requestTargets(w, h)` to
//! return the list of intermediate target descriptors you need
//! allocated, and `dispatchStep_(orchestrator, encoder, ctx)` to
//! drive your own render passes per step. Use
//! `orchestrator.buildPipeline_(...)` to build per-step pipelines
//! during `onAdded_` (called when the pass is registered).

import "@hatch:gpu" for Gpu

/// Base class for a post-processing effect. The interface has two
/// surfaces:
///
/// **Single-pass (typical effects).** Subclass overrides `name`,
/// `fragmentBody`, and optionally `uniformWgsl` + `uniformBytes` +
/// `writeUniforms(scratch)`. The orchestrator handles pipeline
/// creation, bind group setup, and the single render pass.
///
/// **Multi-pass (bloom, DoF, separable blur).** Subclass also
/// overrides `stepCount` and `requestTargets(w, h)`, plus
/// `dispatchStep_(orchestrator, encoder, ctx)` to take control of
/// each step's render pass. The orchestrator allocates the
/// intermediate targets from `requestTargets`; the pass uses them
/// (plus the helper `orchestrator.runFragmentStep_`) to chain
/// internally.
///
/// `ctx` (handed to `dispatchStep_`) is a Map with:
///   - `"inputView"`  : the chain's current input (TextureView)
///   - `"outputView"` : where the *final* step of this pass should
///                      write — typically pong or the swap chain
///                      view. Intermediate steps use the pass's
///                      own `intermediates` instead.
///   - `"stepIndex"`  : `0..stepCount`
///   - `"intermediates"`: List<TextureView> from `requestTargets`
///   - `"depthView"`  : scene depth (only when `wantsDepth`); else null
class PostPass {
  /// Construct the base. Subclass constructors should call
  /// `super()` so the cached resource maps initialise.
  construct new() {
    _pipelines     = []      // cached per-step pipelines, populated by orchestrator
    _bindGroups    = []      // cached per-step bind groups (keyed by view id)
    _uniformBuffer = null    // built lazily by orchestrator if uniformBytes > 0
    _intermediates = []      // TextureViews allocated by orchestrator from requestTargets
  }

  // ─── Identity ───────────────────────────────────────────────────

  /// Diagnostic label. Override.
  /// @returns {String}
  name { "unnamed" }

  // ─── Single-pass interface ──────────────────────────────────────

  /// Fragment-stage body. The orchestrator wraps this with the
  /// shared vertex shader and a fragment entry point exposing:
  ///   - `t`: input `texture_2d<f32>`
  ///   - `s`: input `sampler`
  ///   - `uv`: `vec2<f32>` in `0..1`
  ///   - `u`: the uniform struct (when `uniformBytes > 0`)
  ///   - `depthTex`: input `texture_depth_2d` (when `wantsDepth`)
  /// Must `return vec4<f32>(...)`.
  /// @returns {String}
  fragmentBody { "return textureSample(t, s, uv);" }

  /// WGSL declaration for the uniform struct fields (without the
  /// `struct U { ... };` wrapper — just the field list). Example:
  /// `"exposure: f32, _pad0: f32, _pad1: f32, _pad2: f32"`. Pad to
  /// 16-byte vec4 chunks per std140-ish alignment.
  /// @returns {String}
  uniformWgsl { "" }

  /// Size of the uniform block in bytes (a multiple of 16). `0`
  /// means no uniforms — the orchestrator omits the UBO binding.
  /// @returns {Num}
  uniformBytes { 0 }

  /// Populate `scratch[i]` with current Float32 uniform values.
  /// Called every frame before this pass's first step. Default
  /// is a no-op for passes without uniforms.
  /// @param {List<Num>} scratch
  writeUniforms(scratch) {}

  // ─── Multi-pass interface ───────────────────────────────────────

  /// How many render passes this effect dispatches per frame.
  /// Default `1` for the simple-pass shape. Bloom returns
  /// `2 * levels + 2` (threshold + N downsample + N upsample +
  /// composite).
  /// @returns {Num}
  stepCount { 1 }

  /// Target descriptors the orchestrator allocates on `add` (and
  /// re-allocates on resize). Each Map needs at least `"format"`,
  /// `"width"`, `"height"`. Bloom uses a mip pyramid:
  ///
  /// ```wren
  /// requestTargets(w, h) {
  ///   var out = []; var d = 2
  ///   for (i in 0..._levels) {
  ///     out.add({ "format": "rgba16float", "width": (w/d).floor, "height": (h/d).floor })
  ///     d = d * 2
  ///   }
  ///   return out
  /// }
  /// ```
  ///
  /// Default returns an empty list (no intermediates).
  /// @param  {Num} width
  /// @param  {Num} height
  /// @returns {List<Map>}
  requestTargets(width, height) { [] }

  /// When `true`, the orchestrator binds the scene's depth view
  /// as binding 3 in this pass's pipeline layouts so the
  /// fragment body can sample `depthTex` (for DoF, SSAO, etc.).
  /// @returns {Bool}
  wantsDepth { false }

  // ─── Dispatch + lifecycle ───────────────────────────────────────

  /// Called when this pass is registered with a `PostFX`
  /// orchestrator. Default impl pre-builds the per-step pipeline
  /// from `fragmentBody` / `uniformWgsl`. Override to build
  /// custom pipelines (multiple per pass for multi-step effects).
  /// @param {PostFX} orchestrator
  onAdded_(orchestrator) {
    var pipe = orchestrator.buildFragmentPipeline_(this)
    _pipelines.add(pipe)
    if (uniformBytes > 0) {
      _uniformBuffer = orchestrator.device_.createBuffer({
        "size":  uniformBytes,
        "usage": ["uniform", "copy-dst"],
        "label": "postfx-" + name + "-ubo"
      })
    }
  }

  /// Called once per step by the orchestrator. Default impl
  /// (single-pass effects) runs one fullscreen draw with the
  /// pass's pipeline 0; multi-step effects override to drive
  /// their own per-step logic.
  /// @param {PostFX}        orchestrator
  /// @param {CommandEncoder} encoder
  /// @param {Map}           ctx
  dispatchStep_(orchestrator, encoder, ctx) {
    orchestrator.runFragmentStep_(this, encoder, ctx, 0)
  }

  // ─── Orchestrator-private accessors (rest of the file uses
  // these; subclasses shouldn't touch them) ───────────────────────
  pipelines_         { _pipelines }
  bindGroups_        { _bindGroups }
  uniformBuffer_     { _uniformBuffer }
  intermediates_     { _intermediates }
  setIntermediates_(t) { _intermediates = t }
}

// Shared vertex shader for every fullscreen-quad pass. Generates a
// triangle pair covering NDC [-1, 1]² with uv [0, 1]² from the 6
// `vertex_index` values the orchestrator feeds via `draw(6, 1)`.
// No vertex buffer needed.
class PostFXShader_ {
  static VERTEX_WGSL {
    return "
      struct VsOut {
        @builtin(position) clip: vec4<f32>,
        @location(0)       uv:   vec2<f32>,
      };
      @vertex
      fn vs_main(@builtin(vertex_index) i: u32) -> VsOut {
        var positions = array<vec2<f32>, 6>(
          vec2(-1.0, -1.0), vec2( 1.0, -1.0), vec2(-1.0,  1.0),
          vec2( 1.0, -1.0), vec2( 1.0,  1.0), vec2(-1.0,  1.0),
        );
        var uvs = array<vec2<f32>, 6>(
          vec2(0.0, 1.0), vec2(1.0, 1.0), vec2(0.0, 0.0),
          vec2(1.0, 1.0), vec2(1.0, 0.0), vec2(0.0, 0.0),
        );
        var o: VsOut;
        o.clip = vec4<f32>(positions[i], 0.0, 1.0);
        o.uv   = uvs[i];
        return o;
      }
    "
  }

  // Build a per-pass shader source by combining the vertex stage
  // with a fragment wrapper that exposes `t`, `s`, `uv`, `u`, and
  // optionally `depthTex`. Each pass supplies only its uniform
  // field declarations + the body that returns a vec4.
  static buildSource(pass) {
    var bindings = "
      @group(0) @binding(0) var t: texture_2d<f32>;
      @group(0) @binding(1) var s: sampler;
    "
    var uniformDecl = ""
    if (pass.uniformBytes > 0) {
      uniformDecl = "
        struct U { " + pass.uniformWgsl + " };
        @group(0) @binding(2) var<uniform> u: U;
      "
    }
    var depthDecl = ""
    if (pass.wantsDepth) {
      depthDecl = "
        @group(0) @binding(3) var depthTex: texture_depth_2d;
      "
    }
    return PostFXShader_.VERTEX_WGSL + bindings + uniformDecl + depthDecl + "
      @fragment
      fn fs_main(@location(0) uv: vec2<f32>) -> @location(0) vec4<f32> {
        " + pass.fragmentBody + "
      }
    "
  }
}

/// Orchestrates the chain of `PostPass` effects between scene
/// render and final swap-chain write. Owns:
///
/// - Scene colour target (size + format match the surface).
/// - Scene depth target when `g.depthFormat != null`.
/// - Ping-pong intermediate (alternate output between passes).
/// - Per-pass intermediate targets (from `requestTargets`).
/// - Shared sampler + bind-group layouts.
class PostFX {
  /// Build a chain bound to the game's current device + surface
  /// format. Inherits the framework's depth-attachment shape: if
  /// `g.depthFormat` is set, the chain allocates a matching depth
  /// texture so depth-tested 3D scenes still resolve correctly
  /// while drawing into the offscreen target.
  ///
  /// @param {GameState} g
  construct new(g) {
    _device        = g.device
    _surfaceFormat = g.surfaceFormat
    _depthFormat   = g.depthFormat
    _width         = 0       // forces first-frame allocation
    _height        = 0
    _passes        = []
    _sceneTex      = null
    _sceneView     = null
    _sceneDepthTex = null
    _sceneDepthView= null
    _pongTex       = null
    _pongView      = null
    _scratch       = []      // grown on first uniform write per pass

    _sampler = _device.createSampler({
      "magFilter":     "linear",
      "minFilter":     "linear",
      "addressModeU":  "clamp-to-edge",
      "addressModeV":  "clamp-to-edge",
      "label":         "postfx-linear-clamp"
    })

    // Four standing layouts: with/without uniforms × with/without depth.
    // Custom advanced effects build their own layouts when they need
    // non-standard binding shapes.
    _bglUniform     = _device.createBindGroupLayout({
      "entries": [
        { "binding": 0, "visibility": ["fragment"], "kind": "texture" },
        { "binding": 1, "visibility": ["fragment"], "kind": "sampler" },
        { "binding": 2, "visibility": ["fragment"], "kind": "uniform" }
      ]
    })
    _bglPlain       = _device.createBindGroupLayout({
      "entries": [
        { "binding": 0, "visibility": ["fragment"], "kind": "texture" },
        { "binding": 1, "visibility": ["fragment"], "kind": "sampler" }
      ]
    })
    _bglUniformDepth = _device.createBindGroupLayout({
      "entries": [
        { "binding": 0, "visibility": ["fragment"], "kind": "texture" },
        { "binding": 1, "visibility": ["fragment"], "kind": "sampler" },
        { "binding": 2, "visibility": ["fragment"], "kind": "uniform" },
        { "binding": 3, "visibility": ["fragment"], "kind": "texture", "sampleType": "depth" }
      ]
    })
    _bglPlainDepth   = _device.createBindGroupLayout({
      "entries": [
        { "binding": 0, "visibility": ["fragment"], "kind": "texture" },
        { "binding": 1, "visibility": ["fragment"], "kind": "sampler" },
        { "binding": 3, "visibility": ["fragment"], "kind": "texture", "sampleType": "depth" }
      ]
    })

    _layoutUniform      = _device.createPipelineLayout({ "bindGroupLayouts": [_bglUniform] })
    _layoutPlain        = _device.createPipelineLayout({ "bindGroupLayouts": [_bglPlain] })
    _layoutUniformDepth = _device.createPipelineLayout({ "bindGroupLayouts": [_bglUniformDepth] })
    _layoutPlainDepth   = _device.createPipelineLayout({ "bindGroupLayouts": [_bglPlainDepth] })

    // Per-pass storage of allocated intermediate Texture handles.
    // Parallel-indexed with `_passes`; `_intermediateTex[i]` is the
    // list of foreign textures owned by pass `i`. Needed for the
    // resize path so we can drop them before the next allocation
    // round.
    _intermediateTex = []
  }

  // Internal accessors used by `PostPass.onAdded_` and helpers
  // when building per-pass resources.
  device_         { _device }
  surfaceFormat_  { _surfaceFormat }
  sampler_        { _sampler }
  bglUniform_     { _bglUniform }
  bglPlain_       { _bglPlain }
  bglUniformDepth_{ _bglUniformDepth }
  bglPlainDepth_  { _bglPlainDepth }

  /// Shared vertex-shader WGSL used by every chain pipeline.
  /// Generates the fullscreen-triangle pair from the 6 vertex
  /// indices via `draw(6, 1)`. Exposed so advanced effects
  /// building their own pipelines (Bloom, separable blur,
  /// depth-of-field) can stitch the same vertex stage onto their
  /// fragment shaders.
  /// @returns {String}
  vertexWgsl_ { PostFXShader_.VERTEX_WGSL }

  /// Number of registered passes.
  /// @returns {Num}
  count { _passes.count }

  /// Internal: scene-target view (Game.run binds this as the
  /// scene render pass's colour attachment when the chain is
  /// active).
  /// @returns {TextureView}
  sceneView_       { _sceneView }

  /// Internal: matching depth view, or `null` when no depth
  /// configured.
  /// @returns {TextureView}
  sceneDepthView_  { _sceneDepthView }

  /// Append `pass` to the chain. Triggers the pass's `onAdded_`
  /// hook so it pre-builds pipelines + uniform buffers; targets
  /// are allocated lazily on the next `resize_` call (which fires
  /// before every frame in `Game.run`).
  ///
  /// @param {PostPass} pass
  add(pass) {
    if (!(pass is PostPass)) {
      Fiber.abort("PostFX.add: pass must be a PostPass, got %(pass.type)")
    }
    _passes.add(pass)
    _intermediateTex.add([])
    pass.onAdded_(this)
  }

  /// Drop every registered pass. Pipeline + buffer objects stay
  /// around until garbage collected.
  clear() {
    _passes.clear()
    _intermediateTex.clear()
  }

  /// Build a single-pass render pipeline for `pass` using the
  /// chain's shared vertex shader and `pass.fragmentBody`. Called
  /// by the default `PostPass.onAdded_` and available to advanced
  /// effects that build extra pipelines for multi-step work.
  ///
  /// @param  {PostPass} pass
  /// @returns {RenderPipeline}
  buildFragmentPipeline_(pass) {
    var shader = _device.createShaderModule({
      "code":  PostFXShader_.buildSource(pass),
      "label": "postfx-" + pass.name
    })
    var layout = pickLayout_(pass)
    return _device.createRenderPipeline({
      "layout":  layout,
      "vertex":  { "module": shader, "entryPoint": "vs_main" },
      "fragment": {
        "module":     shader,
        "entryPoint": "fs_main",
        "targets":    [{ "format": _surfaceFormat }]
      },
      "primitive": { "topology": "triangle-list" },
      "label":     "postfx-" + pass.name
    })
  }

  // Pick the right pipeline layout for a pass based on its
  // uniform + depth needs. Four combinations, four layouts.
  pickLayout_(pass) {
    var hasU = pass.uniformBytes > 0
    var hasD = pass.wantsDepth
    if (hasU && hasD)   return _layoutUniformDepth
    if (hasU)           return _layoutUniform
    if (hasD)           return _layoutPlainDepth
    return _layoutPlain
  }

  /// Run one fullscreen-quad pass for `pass` against `pipelineIdx`
  /// (index into `pass.pipelines_`). Used by single-pass effects'
  /// default `dispatchStep_` and by multi-step effects for each
  /// of their internal steps.
  ///
  /// @param {PostPass}        pass
  /// @param {CommandEncoder}  encoder
  /// @param {Map}             ctx
  /// @param {Num}             pipelineIdx
  runFragmentStep_(pass, encoder, ctx, pipelineIdx) {
    var inputView  = ctx["inputView"]
    var outputView = ctx["outputView"]
    var pipeline   = pass.pipelines_[pipelineIdx]
    var bg = buildOrCacheBindGroup_(pass, pipelineIdx, inputView, ctx["depthView"])

    if (pass.uniformBuffer_ != null) {
      var floats = pass.uniformBytes / 4
      while (_scratch.count < floats) _scratch.add(0)
      pass.writeUniforms(_scratch)
      pass.uniformBuffer_.writeFloats(0, _scratch)
    }

    var rp = encoder.beginRenderPass({
      "colorAttachments": [{
        "view":       outputView,
        "loadOp":     "clear",
        "clearValue": [0, 0, 0, 1],
        "storeOp":    "store"
      }],
      "label": "postfx-" + pass.name
    })
    rp.setPipeline(pipeline)
    rp.setBindGroup(0, bg)
    rp.draw(6, 1)
    rp.end
  }

  // Build (and cache per input view) a bind group for `pass`.
  // Bind groups close over the input view, so each distinct
  // input needs its own — multi-step effects routinely cycle
  // through several intermediates per frame.
  buildOrCacheBindGroup_(pass, pipelineIdx, inputView, depthView) {
    var key   = pipelineIdx * 100000 + inputView.id
    var cache = pass.bindGroups_
    var i = 0
    while (i < cache.count) {
      if (cache[i]["key"] == key) return cache[i]["bg"]
      i = i + 1
    }
    var entries = [
      { "binding": 0, "view":    inputView },
      { "binding": 1, "sampler": _sampler }
    ]
    if (pass.uniformBuffer_ != null) {
      entries.add({ "binding": 2, "buffer": pass.uniformBuffer_ })
    }
    if (pass.wantsDepth && depthView != null) {
      entries.add({ "binding": 3, "view": depthView })
    }
    var bg = _device.createBindGroup({
      "layout":  pickLayout_(pass),
      "entries": entries,
      "label":   "postfx-" + pass.name + "-bg-" + pipelineIdx.toString
    })
    cache.add({ "key": key, "bg": bg })
    return bg
  }

  /// Internal: build / rebuild scene + ping-pong + per-pass
  /// intermediates to match `width / height`. Called by
  /// `Game.run` before beginning the scene render pass each
  /// frame.
  /// @param {Num} width
  /// @param {Num} height
  resize_(width, height) {
    if (width == _width && height == _height && _sceneTex != null) return
    // Drop previous-size resources first so GPU memory doesn't
    // double during the alloc round.
    destroyView_(_sceneView)
    destroyTex_(_sceneTex)
    destroyView_(_sceneDepthView)
    destroyTex_(_sceneDepthTex)
    destroyView_(_pongView)
    destroyTex_(_pongTex)

    _sceneTex = _device.createTexture({
      "width": width, "height": height,
      "format": _surfaceFormat,
      "usage":  ["render-attachment", "texture-binding"],
      "label":  "postfx-scene"
    })
    _sceneView = _sceneTex.createView()
    if (_depthFormat != null) {
      _sceneDepthTex = _device.createTexture({
        "width": width, "height": height,
        "format": _depthFormat,
        "usage":  ["render-attachment", "texture-binding"],
        "label":  "postfx-scene-depth"
      })
      _sceneDepthView = _sceneDepthTex.createView()
    }
    _pongTex = _device.createTexture({
      "width": width, "height": height,
      "format": _surfaceFormat,
      "usage":  ["render-attachment", "texture-binding"],
      "label":  "postfx-pong"
    })
    _pongView = _pongTex.createView()

    // Re-allocate every pass's intermediates and invalidate stale
    // bind groups.
    var p = 0
    while (p < _passes.count) {
      var pass = _passes[p]
      var oldTex = _intermediateTex[p]
      var k = 0
      while (k < oldTex.count) {
        oldTex[k].destroy
        k = k + 1
      }
      _intermediateTex[p] = []

      var descs = pass.requestTargets(width, height)
      var freshViews = []
      var i = 0
      while (i < descs.count) {
        var d = descs[i]
        var tex = _device.createTexture({
          "width":  d["width"],
          "height": d["height"],
          "format": d["format"],
          "usage":  ["render-attachment", "texture-binding"],
          "label":  "postfx-" + pass.name + "-intermediate-" + i.toString
        })
        _intermediateTex[p].add(tex)
        freshViews.add(tex.createView())
        i = i + 1
      }
      pass.setIntermediates_(freshViews)
      pass.bindGroups_.clear()
      p = p + 1
    }
    _width  = width
    _height = height
  }

  destroyView_(v) { if (v != null) v.destroy }
  destroyTex_(t)  { if (t != null) t.destroy }

  /// Run the chain end-to-end: scene target → each pass → final
  /// view (the swap chain). No-op when the chain has zero passes.
  ///
  /// @param {CommandEncoder} encoder
  /// @param {TextureView}    finalView
  runChain(encoder, finalView) {
    if (_passes.count == 0) return
    var inputView = _sceneView
    var i = 0
    while (i < _passes.count) {
      var pass    = _passes[i]
      var isLast  = i == _passes.count - 1
      var outputView = isLast ? finalView : (inputView == _sceneView ? _pongView : _sceneView)

      // Walk every step the pass advertises. The default impl
      // (single-pass effects) dispatches one full-screen draw;
      // multi-step effects override `dispatchStep_` and manage
      // their own per-step routing through `pass.intermediates_`.
      var s = 0
      var steps = pass.stepCount
      while (s < steps) {
        pass.dispatchStep_(this, encoder, {
          "inputView":     inputView,
          "outputView":    outputView,
          "stepIndex":     s,
          "intermediates": pass.intermediates_,
          "depthView":     _sceneDepthView
        })
        s = s + 1
      }

      inputView = outputView
      i = i + 1
    }
  }
}
