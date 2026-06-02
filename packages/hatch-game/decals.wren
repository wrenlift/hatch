//! `@hatch:game/decals` — projected surface stamps.
//!
//! A `Decal` is a textured oriented quad with a lifetime: stamp it
//! on a surface (a normal vector + world position) and it fades in,
//! holds, then fades out. Use cases: blood splats, scorch marks,
//! bullet holes, foot prints, paint splashes — anything persistent
//! that wants to read as stuck on the underlying surface.
//!
//! `DecalLayer` is the renderer + pool: one instance buffer + one
//! pipeline + one draw call per frame, regardless of decal count.
//! Add decals via `layer.add(Decal.new(...))`; the layer ages them
//! each frame and removes expired ones via swap-delete.
//!
//! ## Limitations (V1)
//!
//! Flat surfaces only — the decal is a single quad oriented to the
//! supplied normal. On uneven ground (a heightfield with metres of
//! relief inside the decal's footprint) it will clip or hover at
//! the edges. Deferred screen-space decals that conform to the
//! depth buffer are a future enhancement.
//!
//! ## Example
//!
//! ```wren
//! import "@hatch:game" for Game, Decal, DecalLayer
//! import "@hatch:gpu"  for Renderer3D
//! import "@hatch:math" for Vec3
//!
//! class Demo is Game {
//!   construct new() {}
//!   config { {"depth": true, "width": 1280, "height": 720} }
//!   setup(g) {
//!     _renderer = Renderer3D.new(g.device, g.surfaceFormat, g.depthFormat)
//!     _decals   = DecalLayer.new(g.device, g.surfaceFormat, g.depthFormat)
//!     _splatTex = g.device.uploadImage(Image.decode("splat.png"))
//!   }
//!   update(g) {
//!     if (g.input.justPressed("MouseLeft")) {
//!       _decals.add(Decal.new({
//!         "position": Vec3.new(0, 0.01, 0),
//!         "normal":   Vec3.unitY,
//!         "size":     [1.5, 1.5],
//!         "texture":  _splatTex,
//!         "tint":     [1, 0.2, 0.2, 1],
//!         "lifetime": 6,
//!         "fadeOut":  2
//!       }))
//!     }
//!   }
//!   draw(g) {
//!     _renderer.beginFrame(g.pass, _camera)
//!     // ... scene draws ...
//!     _decals.draw(g.pass, _camera, g.dt)
//!     _renderer.endFrame()
//!   }
//! }
//! ```

/// Single decal placement. Constructed via `Decal.new(opts)` and
/// added to a `DecalLayer`. The layer reads + ages the fields each
/// frame; user code can mutate `tint` / `size` to drive runtime
/// effects (e.g. damage decals that brighten as they accumulate).
class Decal {
  /// Build a decal placement. Recognised keys:
  ///
  /// | Key | Type | Required | Notes |
  /// |---|---|---|---|
  /// | `position` | `Vec3` | ✓ | World position on the target surface. |
  /// | `normal`   | `Vec3` | ✓ | Outward normal of the surface (will be normalised). |
  /// | `size`     | `[w,h]` |  | World-space extent. Default `[1, 1]`. |
  /// | `texture`  | `Texture` | ✓ | Sampled across the quad. |
  /// | `tint`     | `[r,g,b,a]` |  | Multiplied with the texture. Default `[1,1,1,1]`. |
  /// | `lifetime` | `Num` |  | Seconds before removal. Default `5`. |
  /// | `fadeIn`   | `Num` |  | Seconds at the start where alpha ramps up. Default `0`. |
  /// | `fadeOut`  | `Num` |  | Seconds at the end where alpha ramps down. Default `1`. |
  /// | `rotation` | `Num` |  | Radians around the surface normal. Default `0`. |
  ///
  /// @param {Map} opts
  construct new(opts) {
    if (!(opts is Map)) Fiber.abort("Decal.new: opts must be a Map")
    _position = Decal.requireVec3_(opts, "position")
    _normal   = Decal.requireVec3_(opts, "normal")
    var size = opts.containsKey("size") ? opts["size"] : [1, 1]
    _sizeX = size[0]
    _sizeY = size[1]
    _texture = opts["texture"]
    if (_texture == null) Fiber.abort("Decal.new: 'texture' is required")
    var tint = opts.containsKey("tint") ? opts["tint"] : [1, 1, 1, 1]
    _r = tint[0]
    _g = tint[1]
    _b = tint[2]
    _a = tint[3]
    _lifetime = opts.containsKey("lifetime") ? opts["lifetime"] : 5
    _fadeIn   = opts.containsKey("fadeIn")   ? opts["fadeIn"]   : 0
    _fadeOut  = opts.containsKey("fadeOut")  ? opts["fadeOut"]  : 1
    _rotation = opts.containsKey("rotation") ? opts["rotation"] : 0
    _age = 0
  }

  static requireVec3_(opts, key) {
    var v = opts[key]
    if (v == null) Fiber.abort("Decal.new: '%(key)' is required")
    return v
  }

  position { _position }
  normal   { _normal }
  texture  { _texture }
  sizeX    { _sizeX }
  sizeY    { _sizeY }
  rotation { _rotation }
  age      { _age }
  lifetime { _lifetime }
  fadeIn   { _fadeIn }
  fadeOut  { _fadeOut }
  r { _r }   g { _g }   b { _b }   a { _a }

  /// Tint setter — overwrites all four channels.
  /// @param {List} rgba
  tint=(rgba) {
    _r = rgba[0]
    _g = rgba[1]
    _b = rgba[2]
    _a = rgba[3]
  }

  /// Age the decal by `dt`. Returns `true` when the decal has
  /// expired (age ≥ lifetime) so the layer can swap-delete it.
  /// @returns {Bool}
  step(dt) {
    _age = _age + dt
    return _age >= _lifetime
  }
}

/// Instanced-draw renderer for a homogeneous set of decals. One
/// pipeline + one storage buffer + one draw call per frame.
///
/// Different decal textures need different layers (textures are
/// bound per pipeline). For two decal flavours (blood + scorch),
/// build two `DecalLayer`s.
///
/// All decals in a layer share blending semantics — the pipeline
/// uses `src-alpha / one-minus-src-alpha` ("alpha") today; an
/// "additive" toggle is on the V2 list.
class DecalLayer {
  // WGSL — flat textured quad oriented to per-decal normal, depth-
  // tested but not writing depth so stacked decals don't z-fight.
  static SHADER_WGSL_ { "
    struct SceneUniforms {
      vp: mat4x4<f32>,
    };

    struct DecalInst {
      v0: vec4<f32>,   // position.xyz, sizeX
      v1: vec4<f32>,   // normal.xyz,   sizeY
      v2: vec4<f32>,   // tint rgba
      v3: vec4<f32>,   // age, lifetime, fadeIn, fadeOut
      v4: vec4<f32>,   // rotation, pad, pad, pad
    };

    @group(0) @binding(0) var<uniform>             scene:  SceneUniforms;
    @group(0) @binding(1) var<storage, read>       decals: array<DecalInst>;
    @group(0) @binding(2) var                      tex:    texture_2d<f32>;
    @group(0) @binding(3) var                      samp:   sampler;

    struct VsOut {
      @builtin(position) clip: vec4<f32>,
      @location(0)       uv:   vec2<f32>,
      @location(1)       tint: vec4<f32>,
    };

    // Build an orthonormal basis whose +Z axis is the surface
    // normal. The other two axes are arbitrary — we just need a
    // consistent tangent frame. Rotation around the normal is
    // applied separately as a 2D rotation in tangent space.
    fn build_basis(n_in: vec3<f32>) -> mat3x3<f32> {
      let n = normalize(n_in);
      var up = vec3<f32>(0.0, 1.0, 0.0);
      if (abs(n.y) > 0.99) { up = vec3<f32>(1.0, 0.0, 0.0); }
      let t = normalize(cross(up, n));
      let b = cross(n, t);
      return mat3x3<f32>(t, b, n);
    }

    @vertex
    fn vs_main(@builtin(vertex_index) v: u32,
               @builtin(instance_index) i: u32) -> VsOut {
      let d = decals[i];

      // Quad corners in tangent space. 6 vertices = 2 triangles.
      var corners = array<vec2<f32>, 6>(
        vec2<f32>(-0.5, -0.5),
        vec2<f32>( 0.5, -0.5),
        vec2<f32>( 0.5,  0.5),
        vec2<f32>(-0.5, -0.5),
        vec2<f32>( 0.5,  0.5),
        vec2<f32>(-0.5,  0.5),
      );
      let local = corners[v];

      // Apply per-decal rotation around the surface normal.
      let rot = d.v4.x;
      let cs  = cos(rot);
      let sn  = sin(rot);
      let rotated = vec2<f32>(local.x * cs - local.y * sn,
                              local.x * sn + local.y * cs);

      let basis  = build_basis(d.v1.xyz);
      let sx = d.v0.w;
      let sy = d.v1.w;
      // Nudge slightly along the normal so decals don't z-fight
      // with the underlying surface. 1 mm at typical scales is
      // invisible but enough to clear depth precision.
      let offset = basis * vec3<f32>(rotated.x * sx, rotated.y * sy, 0.001);
      let world  = d.v0.xyz + offset;

      // Age-driven alpha. fadeIn ramp at the start, fadeOut ramp
      // at the end, full alpha in between.
      let age = d.v3.x;
      let life = d.v3.y;
      let fIn  = max(d.v3.z, 0.0001);
      let fOut = max(d.v3.w, 0.0001);
      var a: f32 = 1.0;
      if (age < fIn) { a = age / fIn; }
      let outStart = life - fOut;
      if (age > outStart) {
        a = a * max((life - age) / fOut, 0.0);
      }
      a = clamp(a, 0.0, 1.0);

      var out: VsOut;
      out.clip = scene.vp * vec4<f32>(world, 1.0);
      out.uv   = local + vec2<f32>(0.5, 0.5);
      out.tint = vec4<f32>(d.v2.rgb, d.v2.a * a);
      return out;
    }

    @fragment
    fn fs_main(in: VsOut) -> @location(0) vec4<f32> {
      let c = textureSample(tex, samp, in.uv);
      return vec4<f32>(c.rgb * in.tint.rgb, c.a * in.tint.a);
    }
  " }

  static FLOATS_PER_DECAL_ { 20 }   // 5 vec4 per slot
  static BYTES_PER_DECAL_  { 80 }
  static SCENE_UBO_BYTES_  { 64 }   // mat4
  static DEFAULT_CAPACITY_ { 256 }

  /// Build a decal layer bound to one texture. The texture is
  /// shared across every decal in the layer; build a second layer
  /// for a different texture.
  ///
  /// @param {Device} device
  /// @param {String} surfaceFormat   Colour attachment format.
  /// @param {String} depthFormat     Depth attachment format.
  /// @param {Texture} texture        Atlas used by every decal.
  /// @param {Num} capacity           Max simultaneous decals. Default 256.
  construct new(device, surfaceFormat, depthFormat, texture, capacity) {
    _device   = device
    _texture  = texture
    _capacity = capacity == null ? DecalLayer.DEFAULT_CAPACITY_ : capacity.floor
    _decals   = []
    _instArr  = Float32Array.new(_capacity * DecalLayer.FLOATS_PER_DECAL_)

    var shader = device.createShaderModule({
      "code":  DecalLayer.SHADER_WGSL_,
      "label": "decal-layer-shader"
    })

    _instBuf = device.createBuffer({
      "size":  _capacity * DecalLayer.BYTES_PER_DECAL_,
      "usage": ["storage", "copy-dst"],
      "label": "decal-instances"
    })
    _sceneUbo = device.createBuffer({
      "size":  DecalLayer.SCENE_UBO_BYTES_,
      "usage": ["uniform", "copy-dst"],
      "label": "decal-scene-ubo"
    })
    _sceneScratch = Float32Array.new(16)
    _sampler = device.createSampler({
      "magFilter":    "linear",
      "minFilter":    "linear",
      "addressModeU": "clamp-to-edge",
      "addressModeV": "clamp-to-edge",
      "label":        "decal-sampler"
    })

    _bgl = device.createBindGroupLayout({
      "entries": [
        { "binding": 0, "visibility": ["vertex"],   "kind": "uniform" },
        { "binding": 1, "visibility": ["vertex"],   "kind": "read-only-storage" },
        { "binding": 2, "visibility": ["fragment"], "kind": "texture" },
        { "binding": 3, "visibility": ["fragment"], "kind": "sampler" }
      ],
      "label": "decal-bgl"
    })
    var layout = device.createPipelineLayout({
      "bindGroupLayouts": [_bgl],
      "label": "decal-pl"
    })

    _pipeline = device.createRenderPipeline({
      "layout": layout,
      "vertex":   { "module": shader, "entryPoint": "vs_main" },
      "fragment": {
        "module": shader, "entryPoint": "fs_main",
        "targets": [{
          "format": surfaceFormat,
          "blend": {
            "color": {
              "srcFactor": "src-alpha",
              "dstFactor": "one-minus-src-alpha",
              "operation": "add"
            },
            "alpha": {
              "srcFactor": "one",
              "dstFactor": "one-minus-src-alpha",
              "operation": "add"
            }
          }
        }]
      },
      "primitive":    { "topology": "triangle-list", "cullMode": "none" },
      // Depth test ON so decals respect occluders; depth WRITE off
      // so two stacked decals don't z-fight with each other.
      "depthStencil": {
        "format": depthFormat,
        "depthWriteEnabled": false,
        "depthCompare":      "less-equal"
      },
      "label": "decal-pipeline"
    })

    _bindGroup = device.createBindGroup({
      "layout":  _bgl,
      "entries": [
        { "binding": 0, "buffer":  _sceneUbo, "size": DecalLayer.SCENE_UBO_BYTES_ },
        { "binding": 1, "buffer":  _instBuf },
        { "binding": 2, "view":    _texture.createView() },
        { "binding": 3, "sampler": _sampler }
      ],
      "label": "decal-bg"
    })
  }

  /// Number of live decals this frame.
  /// @returns {Num}
  count    { _decals.count }
  /// Pool capacity (set at construct). @returns {Num}
  capacity { _capacity }

  /// Stamp a decal on the surface. Drops silently when the pool
  /// is full so a runaway emitter can't overrun the budget.
  /// @param {Decal} decal
  add(decal) {
    if (_decals.count >= _capacity) return
    _decals.add(decal)
  }

  /// Remove every live decal. Useful between scenes / on reset.
  clear() { _decals.clear() }

  /// Ages every live decal by `dt` and removes expired ones. Call
  /// once per frame from `update(g)` (or register with a per-game
  /// auto-tick — `Decals.register(layer)`).
  /// @param {Num} dt
  update(dt) {
    var i = 0
    while (i < _decals.count) {
      if (_decals[i].step(dt)) {
        // Swap-delete: move last into i, shrink list, recheck i.
        var last = _decals.count - 1
        if (i != last) _decals[i] = _decals[last]
        _decals.removeAt(last)
      } else {
        i = i + 1
      }
    }
  }

  /// Draw every live decal in one instanced call. Call from
  /// `draw(g)` after the scene has been laid down so depth-test
  /// against opaque geometry is in place.
  ///
  /// @param {RenderPass} pass     The active render pass.
  /// @param {Camera3D} camera     View / projection source.
  draw(pass, camera) {
    var n = _decals.count
    if (n <= 0) return

    // Pack scene UBO with the current view-projection.
    writeMat4_(_sceneScratch, 0, camera.viewProj)
    _sceneUbo.writeFloats(0, _sceneScratch)

    // Pack instance buffer.
    var i = 0
    while (i < n) {
      var d = _decals[i]
      var off = i * 20
      var p = d.position
      var nrm = d.normal
      _instArr[off]      = p.x
      _instArr[off + 1]  = p.y
      _instArr[off + 2]  = p.z
      _instArr[off + 3]  = d.sizeX
      _instArr[off + 4]  = nrm.x
      _instArr[off + 5]  = nrm.y
      _instArr[off + 6]  = nrm.z
      _instArr[off + 7]  = d.sizeY
      _instArr[off + 8]  = d.r
      _instArr[off + 9]  = d.g
      _instArr[off + 10] = d.b
      _instArr[off + 11] = d.a
      _instArr[off + 12] = d.age
      _instArr[off + 13] = d.lifetime
      _instArr[off + 14] = d.fadeIn
      _instArr[off + 15] = d.fadeOut
      _instArr[off + 16] = d.rotation
      _instArr[off + 17] = 0
      _instArr[off + 18] = 0
      _instArr[off + 19] = 0
      i = i + 1
    }
    _instBuf.writeFloatsN(0, _instArr, n * 20)

    pass.setPipeline(_pipeline)
    pass.setBindGroup(0, _bindGroup)
    pass.draw(6, n)
  }

  // Write a Mat4 into a Float32Array at `off`, transposing from
  // row-major (Mat4.data) to column-major (WGSL std140).
  writeMat4_(arr, off, m) {
    var d = m.data
    arr[off]      = d[0]
    arr[off + 1]  = d[4]
    arr[off + 2]  = d[8]
    arr[off + 3]  = d[12]
    arr[off + 4]  = d[1]
    arr[off + 5]  = d[5]
    arr[off + 6]  = d[9]
    arr[off + 7]  = d[13]
    arr[off + 8]  = d[2]
    arr[off + 9]  = d[6]
    arr[off + 10] = d[10]
    arr[off + 11] = d[14]
    arr[off + 12] = d[3]
    arr[off + 13] = d[7]
    arr[off + 14] = d[11]
    arr[off + 15] = d[15]
  }
}

/// Per-game decal-layer registry. `Decals.register(layer)` opts a
/// layer into a per-frame `update(dt)` pump driven by `Game.run`,
/// matching the `Particles` and `Tweens` patterns. Manual
/// `layer.update(dt)` calls still work when you want explicit
/// timing.
class Decals {
  /// Register `layer` so `Game.run` calls `layer.update(g.dt)`
  /// every frame. Idempotent — adding the same layer twice is a
  /// no-op.
  /// @param {DecalLayer} layer
  static register(layer) {
    if (DECAL_LIST_.contains(layer)) return
    DECAL_LIST_.add(layer)
  }

  /// Remove `layer` from the registry. Live decals on the layer
  /// stop aging — call `layer.update(dt)` manually to drain them
  /// if needed.
  /// @param {DecalLayer} layer
  static unregister(layer) {
    var i = 0
    while (i < DECAL_LIST_.count) {
      if (DECAL_LIST_[i] == layer) {
        DECAL_LIST_.removeAt(i)
        return
      }
      i = i + 1
    }
  }

  /// Drop every registered layer (useful between scene loads).
  static clear() { DECAL_LIST_.clear() }

  /// Number of registered layers. @returns {Num}
  static count { DECAL_LIST_.count }

  /// Tick every registered layer. Called once per frame by
  /// `Game.run`; user code rarely calls this directly.
  /// @param {Num} dt
  static update(dt) {
    var i = 0
    while (i < DECAL_LIST_.count) {
      DECAL_LIST_[i].update(dt)
      i = i + 1
    }
  }
}

// Module-private registry list.
var DECAL_LIST_ = []
