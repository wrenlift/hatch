//! `@hatch:game/gpu_particles` — GPU compute-driven 3D particles.
//!
//! Where `ParticleSystem3D` (in `./particles`) keeps its sim on the
//! CPU and writes a fresh instance buffer every frame, this variant
//! runs the per-frame integration in a compute shader against a
//! storage buffer that the billboard pipeline reads directly.
//!
//! Use it when:
//!  - The system needs to scale past ~10k live particles. CPU
//!    integration crosses the per-frame budget around there;
//!    compute holds well past 100k on a mid-tier laptop.
//!  - Per-particle Wren overhead is unacceptable (foliage wind,
//!    snow blizzard, ambient dust).
//!
//! Use the CPU `ParticleSystem3D` when:
//!  - Capacity ≤ a few thousand. CPU is simpler, no compute pipeline
//!    boot cost, easier to debug.
//!  - You need death-event callbacks / kill planes / per-impact
//!    feedback (the CPU system has `consumeDeaths`; the GPU one
//!    doesn't yet — the data lives on the GPU).
//!
//! ## Example
//! ```wren
//! import "@hatch:game" for Game, GpuParticleSystem3D, Particles
//! import "@hatch:gpu"  for Renderer3D, Camera3D
//!
//! class Fountain is Game {
//!   construct new() {}
//!   config { {"depth": true, "width": 1280, "height": 720} }
//!   setup(g) {
//!     _renderer = Renderer3D.new(g.device, g.surfaceFormat, g.depthFormat)
//!     _camera   = Camera3D.perspective(60, g.width / g.height, 0.1, 200)
//!     _camera.lookAt(Vec3.new(0, 10, 30), Vec3.new(0, 4, 0), Vec3.unitY)
//!     _tex = g.device.createTexture(...)
//!     _fx  = GpuParticleSystem3D.new(g.device, {
//!       "texture":      _tex,
//!       "capacity":     50000,
//!       "emissionRate": 30000,
//!       "lifetime":     [1.5, 2.5],
//!       "position":     [0, 0, 0],
//!       "spread":       [0.2, 0, 0.2],
//!       "velocity":     [[-2, 8, -2], [2, 12, 2]],
//!       "gravity":      [0, -9.8, 0],
//!       "size":         [0.08, 0.08],
//!       "color":        [[1.0, 0.95, 0.85, 1.0], [0.2, 0.5, 1.0, 0.0]]
//!     })
//!     Particles.register(_fx)
//!   }
//!   draw(g) {
//!     _renderer.beginFrame(g.pass, _camera)
//!     _fx.compute(g.encoder)        // dispatch sim before draw
//!     _fx.draw(_renderer)
//!     _renderer.endFrame()
//!   }
//! }
//! Game.run(Fountain)
//! ```

import "random" for Random

/// Compute-shader-driven 3D particle system. Per-frame integration
/// (pos += vel·dt, drag, gravity, lifetime, colour/size lerp) runs
/// entirely on the GPU; CPU only writes per-frame uniforms +
/// occasionally seeds spawn slots when the emitter is firing.
///
/// Memory: capacity × 32 bytes (state) + capacity × 64 bytes
/// (render). At 100k particles that's 9.6 MB — cheap on any GPU.
///
/// Configured by an options Map mirroring [ParticleSystem3D]:
///
/// | Option         | Type                    | Notes                                              |
/// |----------------|-------------------------|----------------------------------------------------|
/// | `texture`      | `Texture`               | Required. Per-particle sprite.                    |
/// | `capacity`     | `Num`                   | Max live particles. Default `5000`.               |
/// | `emissionRate` | `Num`                   | Particles per second. `0` = burst-only.           |
/// | `lifetime`     | `[Num, Num]`            | Min/max lifetime seconds. Default `[1, 1]`.       |
/// | `position`     | `[Num, Num, Num]`       | Emitter origin (mutated via `setPosition`).      |
/// | `spread`       | `[Num, Num, Num]`       | Per-axis ± half-extent at spawn. Default zero.    |
/// | `velocity`     | `[[vx,vy,vz],[vx,vy,vz]]` | Min/max spawn velocity. Default zero.           |
/// | `gravity`      | `[Num, Num, Num]`       | Constant accel. Default `[0, -9.8, 0]`.            |
/// | `drag`         | `Num`                   | Per-second velocity decay. Default `0`.            |
/// | `size`         | `[Num, Num]`            | World-space half-extent (sx, sy). Default `[1, 1]`. |
/// | `color`        | `[[r,g,b,a],[r,g,b,a]]` | Tint over life. Default `[[1,1,1,1],[1,1,1,1]]`. |
/// | `playing`      | `Bool`                  | Start emitting on construct. Default `true`.       |
class GpuParticleSystem3D {
  // WGSL compute shader. Workgroup size 64 × 1 × 1; caller
  // dispatches `ceil(capacity / 64)` workgroups each frame.
  //
  // Layout (must stay in sync with the Wren-side writes):
  //   Params (UBO, group 0 binding 0):
  //     vec4 dt_time_drag_capacity  (x=dt, y=time, z=drag, w=cap)
  //     vec4 gravity_xyz_pad
  //     vec4 color_start_rgba
  //     vec4 color_end_rgba
  //     vec4 size_x_size_y_rot_pad
  //   State (SSBO, group 0 binding 1):
  //     vec4 pos_age   (xyz = pos, w = age)
  //     vec4 vel_life  (xyz = vel, w = lifetime — 0 marks empty)
  //   Render (SSBO, group 0 binding 2):
  //     4 × vec4 packed per `Renderer3D.drawBillboardN`'s 16-float
  //     instance format.
  static COMPUTE_WGSL_ { "
    struct Params {
      dt_time_drag_cap: vec4<f32>,
      gravity:          vec4<f32>,
      color_start:      vec4<f32>,
      color_end:        vec4<f32>,
      size_rot:         vec4<f32>,
    };

    struct State {
      pos_age:  vec4<f32>,
      vel_life: vec4<f32>,
    };

    struct RenderInst {
      v0: vec4<f32>,
      v1: vec4<f32>,
      v2: vec4<f32>,
      v3: vec4<f32>,
    };

    @group(0) @binding(0) var<uniform>             params:  Params;
    @group(0) @binding(1) var<storage, read_write> state:   array<State>;
    @group(0) @binding(2) var<storage, read_write> render:  array<RenderInst>;

    @compute @workgroup_size(64)
    fn integrate(@builtin(global_invocation_id) gid: vec3<u32>) {
      let i = gid.x;
      let cap = u32(params.dt_time_drag_cap.w);
      if (i >= cap) { return; }

      var s   = state[i];
      let dt  = params.dt_time_drag_cap.x;
      let drg = params.dt_time_drag_cap.z;
      let g   = params.gravity.xyz;
      let life = s.vel_life.w;

      // Empty / expired — write an invisible instance and return.
      // Lifetime 0 marks a slot the CPU hasn't seeded yet.
      if (life <= 0.0 || s.pos_age.w >= life) {
        render[i].v0 = vec4<f32>(0.0, 0.0, 0.0, 0.0);
        render[i].v1 = vec4<f32>(0.0, 0.0, 0.0, 0.0);
        render[i].v2 = vec4<f32>(0.0, 0.0, 0.0, 0.0);
        render[i].v3 = vec4<f32>(0.0, 0.0, 0.0, 0.0);
        return;
      }

      // Integrate.
      var v = s.vel_life.xyz;
      v = v + g * dt - v * drg * dt;
      var p = s.pos_age.xyz + v * dt;
      let new_age = s.pos_age.w + dt;
      s.pos_age  = vec4<f32>(p, new_age);
      s.vel_life = vec4<f32>(v, life);
      state[i]   = s;

      // Colour + size interpolation across life.
      var t = new_age / life;
      if (t < 0.0) { t = 0.0; }
      if (t > 1.0) { t = 1.0; }
      let c = mix(params.color_start, params.color_end, t);
      let sx = params.size_rot.x;
      let sy = params.size_rot.y;
      let rt = params.size_rot.z;

      // Pack render instance:
      //   v0 = (ox, oy, oz, sx)
      //   v1 = (sy, u0, v0, u1)
      //   v2 = (v1, r, g, b)
      //   v3 = (a, rotation, lodIndex, pad)
      render[i].v0 = vec4<f32>(p.x, p.y, p.z, sx);
      render[i].v1 = vec4<f32>(sy,  0.0, 0.0, 1.0);
      render[i].v2 = vec4<f32>(1.0, c.r, c.g, c.b);
      render[i].v3 = vec4<f32>(c.a, rt,  0.0, 0.0);
    }
  " }

  static FLOATS_PER_STATE_     { 8 }   // 2 × vec4
  static FLOATS_PER_RENDER_    { 16 }  // 4 × vec4 (matches drawBillboardN)
  static FLOATS_PER_PARAMS_    { 20 }  // 5 × vec4 (padded to 16)
  static PARAMS_UBO_BYTES_     { 80 }  // 20 × 4 — already a multiple of 16

  /// Build the system. Allocates state + render storage buffers,
  /// the params UBO, and the compute pipeline.
  ///
  /// @param {Device} device
  /// @param {Map} opts   See class-level docs.
  construct new(device, opts) {
    if (!(opts is Map)) Fiber.abort("GpuParticleSystem3D.new: opts must be a Map")
    var tex = opts["texture"]
    if (tex == null) Fiber.abort("GpuParticleSystem3D.new: 'texture' is required")
    _texture      = tex
    _capacity     = GpuParticleSystem3D.intOr_(opts, "capacity", 5000)
    _emissionRate = GpuParticleSystem3D.numOr_(opts, "emissionRate", 0)
    _lifetime     = GpuParticleSystem3D.pairOr_(opts, "lifetime", 1, 1)
    _position     = GpuParticleSystem3D.triple_(opts, "position", 0, 0, 0)
    _spread       = GpuParticleSystem3D.triple_(opts, "spread", 0, 0, 0)
    var vel = opts.containsKey("velocity") ? opts["velocity"] : [[0, 0, 0], [0, 0, 0]]
    _velMin = [vel[0][0], vel[0][1], vel[0][2]]
    _velMax = [vel[1][0], vel[1][1], vel[1][2]]
    _gravity      = GpuParticleSystem3D.triple_(opts, "gravity", 0, -9.8, 0)
    _drag         = GpuParticleSystem3D.numOr_(opts, "drag", 0)
    _size         = GpuParticleSystem3D.pairOr_(opts, "size", 1, 1)
    var color = opts.containsKey("color") ? opts["color"] : [[1, 1, 1, 1], [1, 1, 1, 1]]
    _colorStart = color[0]
    _colorEnd   = color[1]
    _playing    = opts.containsKey("playing") ? opts["playing"] : true
    _rotation   = 0
    _time       = 0
    _emissionAccum = 0
    _spawnNext  = 0
    _lastDt     = 0

    _device = device

    // Storage buffers. Sized for capacity — never grows.
    _stateBuf = device.createBuffer({
      "size":  _capacity * GpuParticleSystem3D.FLOATS_PER_STATE_ * 4,
      "usage": ["storage", "copy-dst"],
      "label": "gpu-particles3d-state"
    })
    _renderBuf = device.createBuffer({
      "size":  _capacity * GpuParticleSystem3D.FLOATS_PER_RENDER_ * 4,
      "usage": ["storage", "copy-dst"],
      "label": "gpu-particles3d-render"
    })
    // Params UBO — re-uploaded each frame with dt/time/uniforms.
    _paramsUbo = device.createBuffer({
      "size":  GpuParticleSystem3D.PARAMS_UBO_BYTES_,
      "usage": ["uniform", "copy-dst"],
      "label": "gpu-particles3d-params"
    })
    _paramsScratch = Float32Array.new(GpuParticleSystem3D.FLOATS_PER_PARAMS_)

    // Spawn scratchpad. Reused across frames; sized to "max
    // realistic emissions per frame" — capacity itself is the
    // upper bound (a single-frame burst), but in steady state
    // we'll only touch the first few slots.
    _spawnScratch = Float32Array.new(_capacity * GpuParticleSystem3D.FLOATS_PER_STATE_)

    // Compute pipeline.
    var shader = device.createShaderModule({
      "code":  GpuParticleSystem3D.COMPUTE_WGSL_,
      "label": "gpu-particles3d-integrate"
    })
    _bgl = device.createBindGroupLayout({
      "entries": [
        { "binding": 0, "visibility": ["compute"], "kind": "uniform" },
        { "binding": 1, "visibility": ["compute"], "kind": "storage" },
        { "binding": 2, "visibility": ["compute"], "kind": "storage" }
      ],
      "label": "gpu-particles3d-bgl"
    })
    var layout = device.createPipelineLayout({
      "bindGroupLayouts": [_bgl],
      "label": "gpu-particles3d-pl"
    })
    _pipeline = device.createComputePipeline({
      "module":     shader,
      "entryPoint": "integrate",
      "layout":     layout,
      "label":      "gpu-particles3d-cp"
    })
    _bindGroup = device.createBindGroup({
      "layout":  _bgl,
      "entries": [
        { "binding": 0, "buffer": _paramsUbo,  "size": GpuParticleSystem3D.PARAMS_UBO_BYTES_ },
        { "binding": 1, "buffer": _stateBuf },
        { "binding": 2, "buffer": _renderBuf }
      ],
      "label": "gpu-particles3d-bg"
    })
  }

  // -- Config helpers --------------------------------------------
  static numOr_(opts, key, fallback) {
    if (!opts.containsKey(key)) return fallback
    var v = opts[key]
    if (!(v is Num)) Fiber.abort("GpuParticleSystem3D: '%(key)' must be Num")
    return v
  }
  static intOr_(opts, key, fallback) {
    return GpuParticleSystem3D.numOr_(opts, key, fallback).floor
  }
  static pairOr_(opts, key, fx, fy) {
    if (!opts.containsKey(key)) return [fx, fy]
    var v = opts[key]
    if (!(v is List) || v.count < 2) Fiber.abort("GpuParticleSystem3D: '%(key)' must be a 2-list")
    return [v[0], v[1]]
  }
  static triple_(opts, key, fx, fy, fz) {
    if (!opts.containsKey(key)) return [fx, fy, fz]
    var v = opts[key]
    if (!(v is List) || v.count < 3) Fiber.abort("GpuParticleSystem3D: '%(key)' must be a 3-list")
    return [v[0], v[1], v[2]]
  }

  // -- Public surface --------------------------------------------
  /// Pool capacity (set at construct). Constant. @returns {Num}
  capacity     { _capacity }
  /// Live-tune the auto-emission rate. Clamped at 0.
  emissionRate     { _emissionRate }
  emissionRate=(v) { _emissionRate = v < 0 ? 0 : v }
  /// Toggle the auto-emitter.
  isPlaying     { _playing }
  isPlaying=(b) { _playing = b }
  /// Uniform rotation (radians) applied to every drawn instance.
  rotation     { _rotation }
  rotation=(v) { _rotation = v }

  /// Reposition the emitter origin.
  setPosition(x, y, z) {
    _position[0] = x
    _position[1] = y
    _position[2] = z
  }

  /// Set a horizontal drift on the spawn-velocity range (binds rain
  /// / snow / dust to a wind field; Y is left untouched).
  setWindDrift(vx, vz) {
    _velMin[0] = vx
    _velMax[0] = vx
    _velMin[2] = vz
    _velMax[2] = vz
  }

  /// Ticked by `Particles.register` each frame. CPU-side work is
  /// just: (a) advance emission accumulator, (b) seed N new slots
  /// in `_stateBuf` with fresh state. The integration itself
  /// happens later in `compute(encoder)` from the user's draw.
  ///
  /// @param {Num} dt
  update(dt) {
    _lastDt = dt
    _time = _time + dt
    if (!(_playing && _emissionRate > 0)) return
    _emissionAccum = _emissionAccum + _emissionRate * dt
    var spawnN = _emissionAccum.floor
    if (spawnN <= 0) return
    _emissionAccum = _emissionAccum - spawnN
    seedSpawns_(spawnN)
  }

  // Write `n` fresh particle states into `_stateBuf`, starting at
  // round-robin slot `_spawnNext`. If the request would cross the
  // capacity boundary, clip to what fits this frame and wrap the
  // remainder on the next call — the lost few drops show up at
  // the next emission tick.
  seedSpawns_(n) {
    var headRoom = _capacity - _spawnNext
    if (n > headRoom) n = headRoom
    if (n <= 0) {
      // Wrap point — reset and let the next frame fill from zero.
      _spawnNext = 0
      return
    }
    var i = 0
    while (i < n) {
      var off = i * 8
      _spawnScratch[off]     = _position[0] + (random_() - 0.5) * 2 * _spread[0]
      _spawnScratch[off + 1] = _position[1] + (random_() - 0.5) * 2 * _spread[1]
      _spawnScratch[off + 2] = _position[2] + (random_() - 0.5) * 2 * _spread[2]
      _spawnScratch[off + 3] = 0   // age
      _spawnScratch[off + 4] = _velMin[0] + random_() * (_velMax[0] - _velMin[0])
      _spawnScratch[off + 5] = _velMin[1] + random_() * (_velMax[1] - _velMin[1])
      _spawnScratch[off + 6] = _velMin[2] + random_() * (_velMax[2] - _velMin[2])
      _spawnScratch[off + 7] = _lifetime[0] + random_() * (_lifetime[1] - _lifetime[0])
      i = i + 1
    }
    _stateBuf.writeFloatsN(_spawnNext * 32, _spawnScratch, n * 8)
    _spawnNext = (_spawnNext + n) % _capacity
  }

  /// Encode the per-frame compute dispatch on `encoder`. Call from
  /// the user's `draw(g)` AFTER `renderer.beginFrame` but BEFORE
  /// the matching `drawBillboardN` so the storage buffer is
  /// populated before the render pass reads it.
  ///
  /// @param {CommandEncoder} encoder   `g.encoder` from Game.run.
  compute(encoder) {
    if (encoder == null) Fiber.abort("GpuParticleSystem3D.compute: encoder is null (call inside draw)")
    writeParams_()
    var pass = encoder.beginComputePass()
    pass.setPipeline(_pipeline)
    pass.setBindGroup(0, _bindGroup)
    var groups = ((_capacity + 63) / 64).floor
    pass.dispatchWorkgroups(groups)
    pass.end
  }

  // Pack the params UBO with the current frame's uniforms.
  writeParams_() {
    var f = _paramsScratch
    // dt comes from `update(dt)` via `_lastDt` (set once per frame
    // by `Particles.update`'s pump). When `compute` runs before
    // any update has fired, _lastDt is 0 and the integration is a
    // no-op for that frame.
    f[0]  = _lastDt
    f[1]  = _time
    f[2]  = _drag
    f[3]  = _capacity
    f[4]  = _gravity[0]
    f[5]  = _gravity[1]
    f[6]  = _gravity[2]
    f[7]  = 0
    f[8]  = _colorStart[0]
    f[9]  = _colorStart[1]
    f[10] = _colorStart[2]
    f[11] = _colorStart[3]
    f[12] = _colorEnd[0]
    f[13] = _colorEnd[1]
    f[14] = _colorEnd[2]
    f[15] = _colorEnd[3]
    f[16] = _size[0]
    f[17] = _size[1]
    f[18] = _rotation
    f[19] = 0
    _paramsUbo.writeFloats(0, _paramsScratch)
  }

  /// Issue a single instanced billboard draw covering every slot.
  /// Dead slots got rewritten to zero-sized instances by the
  /// compute pass, so they cost a vertex-shader invocation but
  /// rasterise nothing.
  ///
  /// @param {Renderer3D} renderer
  draw(renderer) {
    renderer.drawBillboardN(_texture, _renderBuf, _capacity)
  }

  // PRNG — shared shape with ParticleSystem3D. The Wren primitive
  // requires an explicit seed; hash the wall clock so each new
  // system picks up a distinct stream.
  random_() {
    if (RANDOM_HOLDER_[0] == null) {
      RANDOM_HOLDER_[0] = Random.new((System.clock * 1000000).floor)
    }
    return RANDOM_HOLDER_[0].float()
  }
}

// Module-private RNG cell. Mirrors `particles.wren`.
var RANDOM_HOLDER_ = [null]
