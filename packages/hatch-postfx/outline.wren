// `@hatch:postfx` — OutlinePass. Depth + normal Sobel edge
// detection that draws ink-style silhouettes over the scene
// without re-rendering geometry. Composes with toon shading for
// the full stylised anime aesthetic; works on top of plain PBR
// for a "comic-book-on-real" look.

import "@hatch:game" for PostPass

class OutlinePass is PostPass {
  /// Build an outline pass.
  ///
  /// `PostFX` must have been constructed with the
  /// `"normalFormat"` opt (and the scene's `Renderer3D` with a
  /// matching `normalFormat`) so the depth + normal G-buffer
  /// targets are populated. Without that, the pass clears the
  /// scene to the edge colour everywhere — clear evidence the
  /// wiring is missing.
  ///
  /// | Key | Type | Default | Notes |
  /// |---|---|---|---|
  /// | `depthThreshold`  | `Num`  | `0.005` | Raw-depth gradient cutoff. Lower → more edges. Scale with scene scale + camera near/far. |
  /// | `normalThreshold` | `Num`  | `0.30`  | `1 - dot(N, N_neighbour)` cutoff. `0.30` ≈ 45° normal break. |
  /// | `color`           | `List` | `[0.05, 0.05, 0.08, 1.0]` | RGBA ink colour. Alpha is the blend strength against the underlying scene. |
  /// | `thickness`       | `Num`  | `1.0` | Neighbour-sample radius in texels. `>1` → thicker line; aliasing rises. |
  ///
  /// @param {Device} device
  /// @param {Map}    opts
  construct new(device, opts) { init_(device, opts) }
  construct new(device)       { init_(device, {}) }

  init_(device, opts) {
    super()
    _device         = device
    _depthThreshold  = opts.containsKey("depthThreshold")  ? opts["depthThreshold"]  : 0.005
    _normalThreshold = opts.containsKey("normalThreshold") ? opts["normalThreshold"] : 0.30
    _color           = opts.containsKey("color")           ? opts["color"]           : [0.05, 0.05, 0.08, 1.0]
    _thickness       = opts.containsKey("thickness")       ? opts["thickness"]       : 1.0
    _initialised     = false
  }

  /// Diagnostic label.
  name { "outline" }

  /// `depthThreshold` getter / setter.
  /// @returns {Num}
  depthThreshold       { _depthThreshold }
  /// @param {Num} v
  depthThreshold=(v)   { _depthThreshold = v }

  /// `normalThreshold` getter / setter.
  /// @returns {Num}
  normalThreshold      { _normalThreshold }
  /// @param {Num} v
  normalThreshold=(v)  { _normalThreshold = v }

  /// `color` getter / setter — `[r, g, b, a]`.
  /// @returns {List}
  color                { _color }
  /// @param {List} v
  color=(v)            { _color = v }

  /// `thickness` getter / setter — texels.
  /// @returns {Num}
  thickness            { _thickness }
  /// @param {Num} v
  thickness=(v)        { _thickness = v }

  // OutlinePass owns its own bind-group layout + pipeline so it
  // can declare two extra texture bindings (depth + normal)
  // alongside the standard scene-input slot — same custom-pass
  // pattern Bloom uses for its mip pyramid.
  onAdded_(orchestrator) {
    _sampler      = orchestrator.sampler_
    _vertexWgsl   = orchestrator.vertexWgsl_
    _outputFormat = orchestrator.surfaceFormat_

    _bgl = _device.createBindGroupLayout({
      "entries": [
        { "binding": 0, "visibility": ["fragment"], "kind": "texture" },
        { "binding": 1, "visibility": ["fragment"], "kind": "sampler" },
        { "binding": 2, "visibility": ["fragment"], "kind": "uniform" },
        { "binding": 3, "visibility": ["fragment"], "kind": "texture", "sampleType": "depth" },
        { "binding": 4, "visibility": ["fragment"], "kind": "texture" }
      ],
      "label": "outline-bgl"
    })
    var layout = _device.createPipelineLayout({ "bindGroupLayouts": [_bgl] })

    var shader = _device.createShaderModule({
      "code":  _vertexWgsl + OutlinePass.FRAGMENT_WGSL_,
      "label": "outline-shader"
    })
    _pipeline = _device.createRenderPipeline({
      "layout": layout,
      "vertex":   { "module": shader, "entryPoint": "vs_main" },
      "fragment": {
        "module":     shader,
        "entryPoint": "fs_main",
        "targets":    [{ "format": _outputFormat }]
      },
      "primitive": { "topology": "triangle-list" },
      "label":     "outline-pipeline"
    })

    _ubo = _device.createBuffer({
      "size":  32,
      "usage": ["uniform", "copy-dst"],
      "label": "outline-ubo"
    })
    _scratch        = [0, 0, 0, 0, 0, 0, 0, 0]
    _bindGroupCache = {}
    _initialised    = true
  }

  // Custom dispatch — binds the depth + normal views the chain
  // surfaces via `ctx`, then draws one fullscreen pass.
  dispatchStep_(orchestrator, encoder, ctx) {
    if (!_initialised) Fiber.abort("OutlinePass.dispatchStep_: pipeline not built (forgot to add to PostFX?)")
    var depthView  = ctx["depthView"]
    var normalView = ctx["normalView"]
    if (depthView == null) {
      Fiber.abort("OutlinePass: PostFX must have a depth target (Game config `\"depth\": true`).")
    }
    if (normalView == null) {
      Fiber.abort("OutlinePass: PostFX must be built with `{ \"normalFormat\": ... }` so the scene normal G-buffer exists.")
    }

    // Push current uniform values. `1.0 / thickness` is the texel
    // step packed into a vec2 in the shader; we send the raw
    // thickness and let WGSL multiply by the texel size.
    _scratch[0] = _depthThreshold
    _scratch[1] = _normalThreshold
    _scratch[2] = _thickness
    _scratch[3] = 0
    _scratch[4] = _color[0]
    _scratch[5] = _color[1]
    _scratch[6] = _color[2]
    _scratch[7] = _color.count > 3 ? _color[3] : 1.0
    _ubo.writeFloats(0, _scratch)

    var inputView = ctx["inputView"]
    var bgKey = "%(inputView.id)/%(normalView.id)/%(depthView.id)"
    var bg = _bindGroupCache[bgKey]
    if (bg == null) {
      bg = _device.createBindGroup({
        "layout": _bgl,
        "entries": [
          { "binding": 0, "resource": inputView },
          { "binding": 1, "resource": _sampler },
          { "binding": 2, "resource": _ubo },
          { "binding": 3, "resource": depthView },
          { "binding": 4, "resource": normalView }
        ],
        "label": "outline-bg-" + bgKey
      })
      _bindGroupCache[bgKey] = bg
    }

    var pass = encoder.beginRenderPass({
      "colorAttachments": [{
        "view":       ctx["outputView"],
        "loadOp":     "clear",
        "clearValue": [0, 0, 0, 1],
        "storeOp":    "store"
      }]
    })
    pass.setPipeline(_pipeline)
    pass.setBindGroup(0, bg)
    pass.draw(6, 1)
    pass.end()
  }

  // Sobel-style edge detection on depth + normal G-buffers.
  // The 4-tap cross neighbourhood is cheap and reads "drawn"
  // enough for the cel-shaded aesthetic; an 8-tap version would add
  // diagonals at the cost of ~2× the texture reads. Edge colour
  // alpha multiplies the blend strength so opaque ink lines
  // (a=1) and softer washes (a<1) both compose cleanly.
  static FRAGMENT_WGSL_ {
    return "
      struct U {
        depth_threshold:  f32,
        normal_threshold: f32,
        thickness:        f32,
        _p0:              f32,
        color:            vec4<f32>,
      };
      @group(0) @binding(0) var t:         texture_2d<f32>;
      @group(0) @binding(1) var s:         sampler;
      @group(0) @binding(2) var<uniform> u: U;
      @group(0) @binding(3) var depth_tex: texture_depth_2d;
      @group(0) @binding(4) var normal_tex: texture_2d<f32>;

      struct VsOut {
        @builtin(position) clip: vec4<f32>,
        @location(0)       uv:   vec2<f32>,
      };

      @fragment
      fn fs_main(in: VsOut) -> @location(0) vec4<f32> {
        let scene = textureSample(t, s, in.uv);
        let dims  = vec2<f32>(textureDimensions(t));
        let off   = u.thickness / dims;

        let uv_n = in.uv + vec2<f32>(0.0, -off.y);
        let uv_s = in.uv + vec2<f32>(0.0,  off.y);
        let uv_e = in.uv + vec2<f32>( off.x, 0.0);
        let uv_w = in.uv + vec2<f32>(-off.x, 0.0);

        let d0 = textureSample(depth_tex, s, in.uv);
        let dn = textureSample(depth_tex, s, uv_n);
        let ds = textureSample(depth_tex, s, uv_s);
        let de = textureSample(depth_tex, s, uv_e);
        let dw = textureSample(depth_tex, s, uv_w);
        let depth_grad = max(
          max(abs(d0 - dn), abs(d0 - ds)),
          max(abs(d0 - de), abs(d0 - dw))
        );
        let depth_edge = step(u.depth_threshold, depth_grad);

        let n0 = textureSample(normal_tex, s, in.uv).rgb * 2.0 - vec3<f32>(1.0);
        let nn = textureSample(normal_tex, s, uv_n).rgb * 2.0 - vec3<f32>(1.0);
        let ns = textureSample(normal_tex, s, uv_s).rgb * 2.0 - vec3<f32>(1.0);
        let ne = textureSample(normal_tex, s, uv_e).rgb * 2.0 - vec3<f32>(1.0);
        let nw = textureSample(normal_tex, s, uv_w).rgb * 2.0 - vec3<f32>(1.0);
        let normal_diff = max(
          max(1.0 - dot(n0, nn), 1.0 - dot(n0, ns)),
          max(1.0 - dot(n0, ne), 1.0 - dot(n0, nw))
        );
        let normal_edge = step(u.normal_threshold, normal_diff);

        let edge_mask = max(depth_edge, normal_edge);
        let blend     = edge_mask * u.color.a;
        let composite = mix(scene.rgb, u.color.rgb, blend);
        return vec4<f32>(composite, scene.a);
      }
    "
  }
}
