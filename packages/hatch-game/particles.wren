//! `@hatch:game/particles` — CPU-driven 2D particle systems with
//! per-particle position, velocity, lifetime, size-over-life and
//! tint-over-life. Output goes through the same `Renderer2D`
//! sprite batcher as everything else, so a particle system is one
//! more `drawSprite` source — no extra pipeline, no texture
//! switches as long as everything sharing a batch uses the same
//! texture.
//!
//! ```wren
//! import "@hatch:game"  for Game, ParticleSystem
//! import "@hatch:gpu"   for Renderer2D, Camera2D
//! import "@hatch:image" for Image
//!
//! class Sparks is Game {
//!   construct new() {}
//!   setup(g) {
//!     var tex = g.device.uploadImage(Image.decode("spark.png"))
//!     _fire = ParticleSystem.new({
//!       "texture":      tex,
//!       "capacity":     500,
//!       "emissionRate": 80,                              // per second
//!       "lifetime":     [1.0, 1.5],                      // [min, max]
//!       "position":     [400, 300],
//!       "spread":       [10, 0],                         // x±10, y±0
//!       "velocity":     [[-20, -150], [20, -100]],       // box: [[xmin,ymin],[xmax,ymax]]
//!       "gravity":      [0, 200],
//!       "drag":         0.1,
//!       "size":         [16, 32],                        // [start, end]
//!       "color":        [[1, 1, 0.5, 1], [1, 0.3, 0, 0]] // [start, end]
//!     })
//!     _renderer = Renderer2D.new(g.device, g.surfaceFormat)
//!     _camera   = Camera2D.new(g.width, g.height)
//!   }
//!   update(g) {
//!     _fire.update(g.dt)
//!     if (g.input.justPressed("Space")) _fire.burst(40)
//!   }
//!   draw(g) {
//!     _renderer.beginFrame(_camera)
//!     _fire.draw(_renderer)
//!     _renderer.flush(g.pass)
//!   }
//! }
//! ```
//!
//! ## Auto-tick
//!
//! `Particles.register(system)` adds a system to a per-game pump
//! list that `Game.run` ticks every frame; you can also drive the
//! tick manually via `system.update(g.dt)` if you want explicit
//! control over timing (pausing, slow-mo).

import "random" for Random

/// One live particle. Internal — created up-front in the
/// `ParticleSystem` capacity pool and re-spawned in place when
/// new emissions need a slot. Holds raw position / velocity /
/// age / interpolation endpoints; the per-frame `update` walks
/// the pool and the per-frame `draw` writes the interpolated
/// values into the sprite batcher.
class Particle_ {
  // Constructor with `null`-init: every field is filled on spawn,
  // not at construction. Lets the system pre-allocate a pool of
  // capacity slots and reuse them without allocator churn.
  construct new_() {
    _x  = 0
    _y  = 0
    _vx = 0
    _vy = 0
    _age  = 0
    _life = 0
    _s0 = 0
    _s1 = 0
    _r0 = 1
    _g0 = 1
    _b0 = 1
    _a0 = 1
    _r1 = 1
    _g1 = 1
    _b1 = 1
    _a1 = 1
    _alive = false
  }

  alive { _alive }
  // Per-particle accessors. Public for the system's update path —
  // accessing through getters is friction-free in Wren (no field
  // dispatch overhead beyond the call) and keeps state encapsulated.
  x  { _x }    y  { _y }
  vx { _vx }   vy { _vy }
  age { _age } life { _life }

  // Setters used by the system on spawn + per-frame update.
  set_(x, y, vx, vy, life, s0, s1, r0, g0, b0, a0, r1, g1, b1, a1) {
    _x  = x
    _y  = y
    _vx = vx
    _vy = vy
    _age  = 0
    _life = life
    _s0 = s0
    _s1 = s1
    _r0 = r0
    _g0 = g0
    _b0 = b0
    _a0 = a0
    _r1 = r1
    _g1 = g1
    _b1 = b1
    _a1 = a1
    _alive = true
  }

  step_(dt, gx, gy, drag) {
    _vx = _vx + gx * dt - _vx * drag * dt
    _vy = _vy + gy * dt - _vy * drag * dt
    _x  = _x  + _vx * dt
    _y  = _y  + _vy * dt
    _age = _age + dt
    if (_age >= _life) _alive = false
  }

  // Normalised age `t` in `0..1`.
  t_ {
    if (_life <= 0) return 1
    var u = _age / _life
    return u > 1 ? 1 : u
  }

  // Interpolated draw inputs.
  size_  { _s0 + (_s1 - _s0) * t_ }
  red_   { _r0 + (_r1 - _r0) * t_ }
  green_ { _g0 + (_g1 - _g0) * t_ }
  blue_  { _b0 + (_b1 - _b0) * t_ }
  alpha_ { _a0 + (_a1 - _a0) * t_ }
}

/// CPU particle simulator + drawer. Owns a fixed-capacity pool of
/// `Particle_` slots; emits new ones into free slots at a
/// configured rate (or via explicit `burst(n)`); updates and
/// renders each frame.
///
/// All ranges are sampled uniformly between `[min, max]`. Pass the
/// same value twice (`[10, 10]`) for a constant.
class ParticleSystem {
  /// Build a system from a config Map. Recognised keys:
  ///
  /// | Key | Type | Required | Notes |
  /// |---|---|---|---|
  /// | `texture`      | `Texture` | ✓ | Per-particle sprite texture. |
  /// | `capacity`     | `Num`     |   | Max simultaneous particles. Default `200`. |
  /// | `emissionRate` | `Num`     |   | Particles per second. `0` = burst-only. |
  /// | `lifetime`     | `[min,max]` |   | Particle lifetime range in seconds. Default `[1, 1]`. |
  /// | `position`     | `[x,y]`   |   | Emitter origin. Default `[0, 0]`. |
  /// | `spread`       | `[dx,dy]` |   | Half-extent around `position`. Default `[0, 0]`. |
  /// | `velocity`     | `[[xMin,yMin],[xMax,yMax]]` |  | Initial-velocity box. Default `[[0,0],[0,0]]`. |
  /// | `gravity`      | `[gx,gy]` |   | Constant acceleration. Default `[0, 0]`. |
  /// | `drag`         | `Num`     |   | Per-second velocity damping. Default `0`. |
  /// | `size`         | `[start,end]` |  | Sprite side length over life. Default `[8, 8]`. |
  /// | `color`        | `[[r,g,b,a],[r,g,b,a]]` |  | Tint over life. Default `[[1,1,1,1],[1,1,1,1]]`. |
  /// | `blend`        | `String`  |   | `"alpha"` (default), `"additive"` (canonical for fire / sparks / glow), or `"premultiplied"`. Forwarded to `Renderer2D.setBlend` at draw time. |
  /// | `playing`      | `Bool`    |   | Start emitting on construct. Default `true`. |
  ///
  /// @param {Map} opts
  construct new(opts) {
    if (!(opts is Map)) {
      Fiber.abort("ParticleSystem.new: opts must be a Map, got %(opts.type)")
    }
    var tex = opts["texture"]
    if (tex == null) Fiber.abort("ParticleSystem.new: 'texture' is required")
    _texture      = tex
    _capacity     = ParticleSystem.intOr_(opts, "capacity",     200)
    _emissionRate = ParticleSystem.numOr_(opts, "emissionRate", 0)
    _lifetime     = ParticleSystem.pairOr_(opts, "lifetime",    1, 1)
    _position     = ParticleSystem.pairOr_(opts, "position",    0, 0)
    _spread       = ParticleSystem.pairOr_(opts, "spread",      0, 0)
    var vel = opts.containsKey("velocity") ? opts["velocity"] : [[0, 0], [0, 0]]
    _velMin = [vel[0][0], vel[0][1]]
    _velMax = [vel[1][0], vel[1][1]]
    _gravity      = ParticleSystem.pairOr_(opts, "gravity",     0, 0)
    _drag         = ParticleSystem.numOr_(opts, "drag",         0)
    _size         = ParticleSystem.pairOr_(opts, "size",        8, 8)
    var color = opts.containsKey("color") ? opts["color"] : [[1, 1, 1, 1], [1, 1, 1, 1]]
    _colorStart = color[0]
    _colorEnd   = color[1]
    _blend        = opts.containsKey("blend") ? opts["blend"] : "alpha"
    _playing      = opts.containsKey("playing") ? opts["playing"] : true

    // Pre-allocate the slot pool. `_count` is the number of slots
    // *used* (alive + recently-died, scanned linearly each frame);
    // `_pool` itself is fixed-size and never grows past capacity.
    _pool = []
    var i = 0
    while (i < _capacity) {
      _pool.add(Particle_.new_())
      i = i + 1
    }
    _emissionAccum = 0
    _liveCount     = 0
  }

  static numOr_(opts, key, fallback) {
    if (!opts.containsKey(key)) return fallback
    var v = opts[key]
    if (!(v is Num)) Fiber.abort("ParticleSystem: '%(key)' must be a Num, got %(v.type)")
    return v
  }
  static intOr_(opts, key, fallback) {
    var n = ParticleSystem.numOr_(opts, key, fallback)
    return n.floor
  }
  static pairOr_(opts, key, fallbackX, fallbackY) {
    if (!opts.containsKey(key)) return [fallbackX, fallbackY]
    var v = opts[key]
    if (!(v is List) || v.count < 2) {
      Fiber.abort("ParticleSystem: '%(key)' must be a 2-element List, got %(v.type)")
    }
    return [v[0], v[1]]
  }

  /// Emitter origin. Move per frame to follow a player, mouse,
  /// projectile, etc.
  /// @param {Num} x
  /// @param {Num} y
  position(x, y) {
    _position[0] = x
    _position[1] = y
  }

  /// True while the auto-emitter is on (continues to spawn new
  /// particles each frame at `emissionRate`). `burst(n)` ignores
  /// the playing flag — burst-only systems can leave `playing` off
  /// and just call `burst` on demand.
  /// @returns {Bool}
  playing { _playing }
  /// Resume emission.
  start { _playing = true }
  /// Pause emission. Existing particles keep ticking until their
  /// lifetime expires.
  stop  { _playing = false }

  /// Number of live particles (alive this frame). Useful for HUDs
  /// or debug overlays.
  /// @returns {Num}
  liveCount { _liveCount }

  /// Pool capacity (set at construct). Constant.
  /// @returns {Num}
  capacity { _capacity }

  /// Spawn `n` particles right now, regardless of `playing` /
  /// `emissionRate`. Caps at remaining pool capacity — additional
  /// particles past the cap are dropped silently so an explosion
  /// can't grow the pool past its budget.
  ///
  /// @param  {Num} n
  /// @returns {Num} actual number spawned (≤ n)
  burst(n) {
    var spawned = 0
    var i = 0
    while (i < n) {
      if (!spawnOne_()) break
      spawned = spawned + 1
      i = i + 1
    }
    return spawned
  }

  // Find a dead slot and re-spawn it with fresh state. Returns
  // false when the pool is fully alive (i.e. capacity hit) so
  // burst() can stop trying.
  spawnOne_() {
    var slot = null
    var i = 0
    while (i < _pool.count) {
      if (!_pool[i].alive) {
        slot = _pool[i]
        break
      }
      i = i + 1
    }
    if (slot == null) return false

    var rx = _spread[0] == 0 ? 0 : ParticleSystem.lerp_(-_spread[0], _spread[0], ParticleSystem.rand_())
    var ry = _spread[1] == 0 ? 0 : ParticleSystem.lerp_(-_spread[1], _spread[1], ParticleSystem.rand_())
    var vx = ParticleSystem.lerp_(_velMin[0], _velMax[0], ParticleSystem.rand_())
    var vy = ParticleSystem.lerp_(_velMin[1], _velMax[1], ParticleSystem.rand_())
    var life = ParticleSystem.lerp_(_lifetime[0], _lifetime[1], ParticleSystem.rand_())

    slot.set_(
      _position[0] + rx, _position[1] + ry,
      vx, vy, life,
      _size[0], _size[1],
      _colorStart[0], _colorStart[1], _colorStart[2], _colorStart[3],
      _colorEnd[0],   _colorEnd[1],   _colorEnd[2],   _colorEnd[3]
    )
    return true
  }

  /// Advance the simulation by `dt` seconds: integrates motion,
  /// ages live particles, and emits new ones from the auto-emitter
  /// when `playing`.
  ///
  /// @param {Num} dt
  update(dt) {
    if (_playing && _emissionRate > 0) {
      _emissionAccum = _emissionAccum + _emissionRate * dt
      while (_emissionAccum >= 1) {
        if (!spawnOne_()) break
        _emissionAccum = _emissionAccum - 1
      }
    }
    var alive = 0
    var i = 0
    while (i < _pool.count) {
      var p = _pool[i]
      if (p.alive) {
        p.step_(dt, _gravity[0], _gravity[1], _drag)
        if (p.alive) alive = alive + 1
      }
      i = i + 1
    }
    _liveCount = alive
  }

  /// Queue every live particle into `renderer`'s batch as a tinted
  /// sprite at its current position, size, and colour. Caller is
  /// still responsible for `renderer.beginFrame(...)` /
  /// `renderer.flush(pass)`.
  ///
  /// @param {Renderer2D} renderer
  draw(renderer) {
    renderer.setBlend(_blend)
    var i = 0
    while (i < _pool.count) {
      var p = _pool[i]
      if (p.alive) {
        var s  = p.size_
        var x  = p.x - s / 2
        var y  = p.y - s / 2
        renderer.drawSpriteTinted(
          _texture, x, y, s, s,
          p.red_, p.green_, p.blue_, p.alpha_
        )
      }
      i = i + 1
    }
  }

  // Linear interpolation for spawn-time sampling.
  static lerp_(a, b, t) { a + (b - a) * t }

  // Deterministic-ish PRNG isn't required — visual particles are
  // chaotic by nature. Lazy-init so importing the module doesn't
  // touch the clock; seeded off `System.clock` (microsecond-ish
  // wall time) so two runs produce different particle scatters.
  // The runtime's zero-arg `Random.new` primitive is registered
  // without arity-paren parsing, so we always pass a seed.
  static rand_() {
    if (RANDOM_HOLDER_[0] == null) {
      RANDOM_HOLDER_[0] = Random.new((System.clock * 1000000).floor)
    }
    return RANDOM_HOLDER_[0].float()
  }
}

/// Per-game particle-system registry. `Particles.register(sys)`
/// adds `sys` to the auto-tick list driven by `Game.run`; manual
/// `system.update(dt)` calls still work for code that wants
/// explicit control (slow-mo, pausing).
class Particles {
  /// Register `system` so `Game.run` calls `system.update(g.dt)`
  /// every frame. Idempotent — adding the same system twice is a
  /// no-op.
  /// @param {ParticleSystem} system
  static register(system) {
    // Duck-typed against an `update(dt)` method so both
    // ParticleSystem (2D) and ParticleSystem3D plug into the same
    // pump. `is ParticleSystem` would close that door.
    if (PARTICLE_LIST_.contains(system)) return
    PARTICLE_LIST_.add(system)
  }

  /// Remove `system` from the registry. Existing particles in the
  /// pool stop ticking — call `system.update(dt)` manually to
  /// drain them if needed.
  /// @param {ParticleSystem} system
  static unregister(system) {
    var i = 0
    while (i < PARTICLE_LIST_.count) {
      if (PARTICLE_LIST_[i] == system) {
        PARTICLE_LIST_.removeAt(i)
        return
      }
      i = i + 1
    }
  }

  /// Drop every registered system. Useful between scene loads.
  static clear() { PARTICLE_LIST_.clear() }

  /// Number of registered systems.
  /// @returns {Num}
  static count { PARTICLE_LIST_.count }

  /// Tick every registered system by `dt`. Called once per frame
  /// by `Game.run`; user code rarely calls this directly.
  /// @param {Num} dt
  static update(dt) {
    var i = 0
    while (i < PARTICLE_LIST_.count) {
      PARTICLE_LIST_[i].update(dt)
      i = i + 1
    }
  }
}

// Module-private. Matches the `ACTION_REGISTRY_` / `TWEEN_LIST_`
// pattern from sibling modules — Wren's `__foo` static-field path
// is brittle through this codebase's class table, so manager state
// lives at module scope. `RANDOM_HOLDER_` is a one-cell list so
// the lazy init can swap the pointer in.
var PARTICLE_LIST_ = []
var RANDOM_HOLDER_ = [null]

/// CPU-driven 3D particle system. Simulates positions / velocities
/// in world space; renders each particle as a spherical camera-
/// facing billboard via `Renderer3D.drawBillboardN`. One FFI call
/// + one drawIndexed per system, regardless of live count.
///
/// Configured by an options Map mirroring [ParticleSystem]:
///
/// | Option         | Type                | Notes                                                  |
/// |----------------|---------------------|--------------------------------------------------------|
/// | `texture`      | `Texture`           | Required. The sprite atlas the billboard samples.     |
/// | `capacity`     | `Num`               | Max live particles. Default `200`.                     |
/// | `emissionRate` | `Num`               | Particles per second. `0` disables auto-emission.     |
/// | `lifetime`     | `[Num, Num]`        | Min/max lifetime seconds. Default `[1, 1]`.            |
/// | `position`     | `[Num, Num, Num]`   | Emitter origin (mutated via `setPosition`).           |
/// | `spread`       | `[Num, Num, Num]`   | Per-axis ± half-extent at spawn. Default `[0, 0, 0]`. |
/// | `velocity`     | `[[vx,vy,vz],[vx,vy,vz]]` | Min/max spawn velocity. Default zero.             |
/// | `gravity`      | `[Num, Num, Num]`   | Constant accel. Default `[0, -9.8, 0]`.                |
/// | `drag`         | `Num`               | Per-second velocity decay 0..1. Default `0`.           |
/// | `size`         | `[Num, Num]`        | World-space half-extent (sx, sy). Default `[1, 1]`.    |
/// | `color`        | `[[r,g,b,a],[r,g,b,a]]` | Tint over life. Default `[[1,1,1,1],[1,1,1,1]]`.  |
/// | `playing`      | `Bool`              | Start emitting on construct. Default `true`.           |
///
/// ## Example
///
/// ```wren
/// var fire = ParticleSystem3D.new(g.device, {
///   "texture":      flameTex,
///   "capacity":     500,
///   "emissionRate": 100,
///   "position":     [0, 0, 0],
///   "spread":       [0.2, 0, 0.2],
///   "velocity":     [[-1, 2, -1], [1, 4, 1]],
///   "gravity":      [0, -1, 0],
///   "lifetime":     [0.5, 1.5],
///   "size":         [0.5, 0.5],
///   "color":        [[1, 0.5, 0, 1], [1, 0, 0, 0]]
/// })
/// Particles.register(fire)
/// // ...later in draw():
/// fire.draw(renderer)
/// ```
class ParticleSystem3D {
  /// Build a 3D particle system. Allocates the per-particle sim
  /// state (`_sim`) and GPU-instance buffer (`_inst`) at full
  /// capacity so steady-state allocation count is zero.
  ///
  /// @param {Device} device
  /// @param {Map} opts
  construct new(device, opts) {
    if (!(opts is Map)) Fiber.abort("ParticleSystem3D.new: opts must be a Map")
    var tex = opts["texture"]
    if (tex == null) Fiber.abort("ParticleSystem3D.new: 'texture' is required")
    _texture      = tex
    _capacity     = ParticleSystem.intOr_(opts, "capacity",     200)
    _emissionRate = ParticleSystem.numOr_(opts, "emissionRate", 0)
    _lifetime     = ParticleSystem.pairOr_(opts, "lifetime",    1, 1)
    _position     = ParticleSystem3D.triple_(opts, "position", 0, 0, 0)
    _spread       = ParticleSystem3D.triple_(opts, "spread",   0, 0, 0)
    var vel = opts.containsKey("velocity") ? opts["velocity"] : [[0, 0, 0], [0, 0, 0]]
    _velMin = [vel[0][0], vel[0][1], vel[0][2]]
    _velMax = [vel[1][0], vel[1][1], vel[1][2]]
    _gravity      = ParticleSystem3D.triple_(opts, "gravity",  0, -9.8, 0)
    _drag         = ParticleSystem.numOr_(opts, "drag",         0)
    _size         = ParticleSystem.pairOr_(opts, "size",        1, 1)
    var color = opts.containsKey("color") ? opts["color"] : [[1, 1, 1, 1], [1, 1, 1, 1]]
    _colorStart = color[0]
    _colorEnd   = color[1]
    _playing      = opts.containsKey("playing") ? opts["playing"] : true

    // Sim state — Float32Array indexed by slot * 8 (px, py, pz,
    // vx, vy, vz, age, lifetime). Float32Array means inline
    // writes with no boxing or method dispatch in the hot path.
    _sim = Float32Array.new(_capacity * 8)
    // GPU instance buffer — Float32Array sized for the full
    // capacity matching Renderer3D.FLOATS_PER_BILLBOARD_ (16).
    _inst = Float32Array.new(_capacity * 16)
    // Pre-fill the constant per-slot fields once at construct so
    // the per-frame `draw` hot loop only touches position / size /
    // colour / rotation. UV-rect (5..8), lodIndex (14), and pad
    // (15) stay at (0, 0, 1, 1, 0, 0) for the whole system's
    // lifetime. For 100k particles this cuts 700k writes / frame
    // off the draw loop.
    {
      var k = 0
      while (k < _capacity) {
        var b = k * 16
        _inst[b + 5] = 0
        _inst[b + 6] = 0
        _inst[b + 7] = 1
        _inst[b + 8] = 1
        _inst[b + 14] = 0
        _inst[b + 15] = 0
        k = k + 1
      }
    }
    _instBuf = device.createBuffer({
      "size":  _capacity * 16 * 4,
      "usage": ["storage", "copy-dst"],
      "label": "particles3d-instance"
    })
    _emissionAccum = 0
    _liveCount     = 0
    _seed          = 0
    // Optional screen-space-width override. `_widthScaleRef`
    // > 0 enables per-particle width scaling by camera distance;
    // `_cameraEye` is the eye position the current frame's
    // distance is measured from. Both default to off.
    _widthScaleRef = 0
    _cameraEye     = null
    // Optional uniform rotation around the camera-forward axis
    // applied to every drawn instance. Used by `Weather.rain` to
    // slant the streaks with the wind vector.
    _rotation      = 0
    // Optional kill plane: when `_killPlaneOn`, any particle
    // crossing `y <= _killPlaneY` during `update` dies immediately
    // (independent of lifetime) and its position is queued for
    // observers via `consumeDeaths`. Used by `Weather.rain` to
    // emit per-impact splash points at the water surface.
    _killPlaneOn = false
    _killPlaneY  = 0
    // Death-position queue. The first two floats are a sentinel
    // header the native plugin writes [deathCount, reserved] into;
    // the kill-position triples start at index 2 onward. `consume-
    // Deaths` walks `[2, 2 + deathCount*3)` instead of `[0, count*3)`.
    _deaths      = Float32Array.new(_capacity * 3 + 2)
    _deathCount  = 0
    // Pre-allocated scratch params for the foreign plugin calls.
    // `_updateParams` mirrors `wlift_particles_integrate`'s params
    // slot (8 floats); `_drawParams` mirrors `wlift_particles_pack`'s
    // params slot (16 floats). Re-used every frame — no per-call
    // allocation.
    _updateParams = Float32Array.new(8)
    _drawParams   = Float32Array.new(16)
  }

  static triple_(opts, key, fx, fy, fz) {
    if (!opts.containsKey(key)) return [fx, fy, fz]
    var v = opts[key]
    if (!(v is List) || v.count < 3) {
      Fiber.abort("ParticleSystem3D: '%(key)' must be a 3-element List")
    }
    return [v[0], v[1], v[2]]
  }

  /// True while the auto-emitter is on. @returns {Bool}
  isPlaying      { _playing }
  /// Toggle the auto-emitter.
  isPlaying=(b)  { _playing = b }
  /// Particles spawned per second while playing.
  /// @returns {Num}
  emissionRate     { _emissionRate }
  /// Live-tune the spawn rate. Clamped at 0 — negative rates
  /// would reverse the emission accumulator and never spawn.
  emissionRate=(v) { _emissionRate = v < 0 ? 0 : v }
  /// Current live-particle count. @returns {Num}
  liveCount      { _liveCount }
  /// Max simultaneous particles. @returns {Num}
  capacity       { _capacity }

  /// Reposition the emitter origin.
  /// @param {Num} x
  /// @param {Num} y
  /// @param {Num} z
  setPosition(x, y, z) {
    _position[0] = x
    _position[1] = y
    _position[2] = z
  }

  /// Push a horizontal drift (m/s) into both min + max of the
  /// spawn-velocity range. Use to bind rain / snow / dust to a
  /// per-frame wind field — the Y axis (the dominant fall speed
  /// in weather presets) is left untouched.
  ///
  /// @param {Num} vx  Drift along world +x (m/s).
  /// @param {Num} vz  Drift along world +z (m/s).
  setWindDrift(vx, vz) {
    _velMin[0] = vx
    _velMax[0] = vx
    _velMin[2] = vz
    _velMax[2] = vz
  }

  /// Enable distance-scaled width so particles read at roughly
  /// constant screen-space thickness regardless of how close they
  /// are to the camera. `refDistance` is the world distance at
  /// which the configured `width` reads unchanged; closer
  /// particles shrink proportionally, farther particles grow.
  /// Pass `0` to disable (the default).
  ///
  /// Used by `Weather.rain` so streaks don't fatten into blobs as
  /// they pass near the camera; ParticleSystem3D also needs the
  /// current camera eye (see `setCameraEye`) so it can compute
  /// per-particle distance each frame.
  ///
  /// @param {Num} refDistance
  setScreenSpaceWidth(refDistance) { _widthScaleRef = refDistance }

  /// Inform the system of the camera eye position. Required when
  /// `setScreenSpaceWidth` is active; ignored otherwise. Call
  /// once per frame, before `draw`.
  ///
  /// @param {Num} x
  /// @param {Num} y
  /// @param {Num} z
  setCameraEye(x, y, z) {
    if (_cameraEye == null) _cameraEye = [0, 0, 0]
    _cameraEye[0] = x
    _cameraEye[1] = y
    _cameraEye[2] = z
  }

  /// Uniform billboard rotation (radians) applied to every drawn
  /// instance, around the camera-forward axis. `Weather.rain`
  /// drives this from the wind vector so streaks slant rather than
  /// drifting horizontally.
  /// @returns {Num}
  rotation      { _rotation }
  /// Set the uniform billboard rotation in radians.
  rotation=(v)  { _rotation = v }

  /// Configure a horizontal kill plane in world space. Particles
  /// crossing `y <= y_plane` during `update` die immediately and
  /// have their pre-death position queued for `consumeDeaths`.
  /// Useful for rain hitting water / floor / windshield.
  ///
  /// @param {Num} y_plane   Y threshold (m).
  setKillPlane(y_plane) {
    _killPlaneOn = true
    _killPlaneY  = y_plane
  }

  /// Disable the kill plane (particles die only by lifetime).
  clearKillPlane() { _killPlaneOn = false }

  /// Number of particles that died this frame. Cleared on the next
  /// `update`; consumers must call `consumeDeaths` (or read
  /// `deathPositions`) before the next tick or the data is lost.
  /// @returns {Num}
  deathCount { _deathCount }

  /// Position triples (x, y, z) for every particle that died this
  /// frame, packed in a Float32Array of length `_deathCount * 3`.
  /// The array slot is reused across frames — observers should
  /// read it within the same frame the deaths happened.
  /// @returns {Float32Array}
  deathPositions { _deaths }

  /// Convenience: hand the death buffer to a callback and clear
  /// it. The callback receives (x, y, z) for each death, in
  /// emission order. Equivalent to iterating `deathPositions` to
  /// length `deathCount * 3`.
  /// @param {Fn} fn   `Fn.new { |x, y, z| ... }`
  consumeDeaths(fn) {
    // The plugin's integrate writes [deathCount, _] into the first
    // two slots of `_deaths`; kill positions start at index 2.
    var i = 0
    while (i < _deathCount) {
      var off = 2 + i * 3
      fn.call(_deaths[off], _deaths[off + 1], _deaths[off + 2])
      i = i + 1
    }
    _deathCount = 0
  }

  /// Spawn `n` particles immediately, regardless of `playing` or
  /// `emissionRate`. Used for explosions, hit FX, one-shots.
  /// @param {Num} n
  burst(n) {
    var i = 0
    while (i < n) {
      if (!spawnOne_()) return
      i = i + 1
    }
  }

  /// Tick every live particle by `dt` seconds. Kills expired
  /// particles, auto-emits new ones at `emissionRate` while
  /// `isPlaying`.
  /// @param {Num} dt
  update(dt) {
    // Hot per-particle integration runs in native Rust via the
    // `wlift_particles` plugin. The Wren wrapper just packs the
    // per-frame params into the pre-allocated `_updateParams`
    // Float32Array and hands the sim + deaths buffers across. At
    // 100k particles the native loop measures well under the parity
    // 8 ms exit gate, where the pure-Wren version sat at ~6 ms
    // pre-optimisation and ~186 ms before that — the JIT can't beat
    // a hand-written tight loop over a `&mut [f32]` for this
    // workload, so we let Rust do it.
    var p = _updateParams
    p[0] = dt
    p[1] = _gravity[0]
    p[2] = _gravity[1]
    p[3] = _gravity[2]
    p[4] = _drag
    p[5] = _killPlaneOn ? 1 : 0
    p[6] = _killPlaneY
    p[7] = 0
    _liveCount  = ParticleSim3DCore.integrate(_sim, _liveCount, p, _deaths)
    _deathCount = _deaths[0]

    // Auto-emit if playing + a rate is configured. Spawn logic
    // stays in Wren — `spawnOne_` writes a handful of f32s per
    // emission, which is a rounding-error cost compared to the
    // integration loop.
    if (_playing && _emissionRate > 0) {
      _emissionAccum = _emissionAccum + _emissionRate * dt
      while (_emissionAccum >= 1) {
        if (!spawnOne_()) {
          // Capacity full — pending spawns can't land. Clamp the
          // accumulator so it doesn't grow unbounded across frames
          // and dump a burst once particles start dying.
          if (_emissionAccum > 1) _emissionAccum = 1
          break
        }
        _emissionAccum = _emissionAccum - 1
      }
    } else if (!_playing) {
      // Don't carry pending spawns across a pause/resume — picks up
      // immediately on resume instead of a backlog snap.
      _emissionAccum = 0
    }
  }

  // Allocate one new particle. Returns false when the pool is
  // full (caller should give up trying to burst further).
  spawnOne_() {
    if (_liveCount >= _capacity) return false
    var off = _liveCount * 8
    // Spawn position: emitter ± per-axis spread.
    _sim[off]     = _position[0] + (random_() - 0.5) * 2 * _spread[0]
    _sim[off + 1] = _position[1] + (random_() - 0.5) * 2 * _spread[1]
    _sim[off + 2] = _position[2] + (random_() - 0.5) * 2 * _spread[2]
    _sim[off + 3] = _velMin[0] + random_() * (_velMax[0] - _velMin[0])
    _sim[off + 4] = _velMin[1] + random_() * (_velMax[1] - _velMin[1])
    _sim[off + 5] = _velMin[2] + random_() * (_velMax[2] - _velMin[2])
    _sim[off + 6] = 0
    // Store 1/lifetime so the update + draw hot paths use a
    // multiply instead of a divide per particle. Death check
    // becomes `age * invLife >= 1`; colour-lerp `t = age * invLife`.
    var life = _lifetime[0] + random_() * (_lifetime[1] - _lifetime[0])
    _sim[off + 7] = life > 0 ? 1.0 / life : 1.0
    _liveCount = _liveCount + 1
    return true
  }

  // (killSlot_ + recordDeath_ moved into the wlift_particles plugin's
  // integrate kernel — the swap-with-last compaction and the death-
  // queue write both happen in native Rust now.)

  // Inline PRNG. Same shape as the 2D ParticleSystem path —
  // a single-cell holder for the lazy Random instance. Wren's
  // Random requires an explicit seed; we hash the wall clock so
  // every new system gets a distinct stream.
  random_() {
    if (RANDOM_HOLDER_[0] == null) {
      RANDOM_HOLDER_[0] = Random.new((System.clock * 1000000).floor)
    }
    return RANDOM_HOLDER_[0].float()
  }

  /// Build the GPU instance buffer from the current sim state and
  /// issue a single `drawBillboardN`. Call once per frame, AFTER
  /// `beginFrame` on `renderer` and before `endFrame`. The whole
  /// alive set goes through one drawIndexed.
  ///
  /// @param {Renderer3D} renderer
  draw(renderer) {
    if (_liveCount == 0) return
    // Hot per-particle instance-buffer pack runs in native Rust via
    // the `wlift_particles` plugin. The Wren wrapper packs the
    // per-frame params (color start + delta, base size, rotation,
    // optional screen-space-width inputs) into the pre-allocated
    // `_drawParams` Float32Array and hands the sim + inst buffers
    // across. The plugin does the lerp, the optional distance
    // scaling, and the 11 stores per slot in one tight Rust loop.
    var widthScale = _widthScaleRef > 0 && _cameraEye != null
    var dp = _drawParams
    var cs0 = _colorStart[0]
    var cs1 = _colorStart[1]
    var cs2 = _colorStart[2]
    var cs3 = _colorStart[3]
    dp[0]  = cs0
    dp[1]  = cs1
    dp[2]  = cs2
    dp[3]  = cs3
    dp[4]  = _colorEnd[0] - cs0
    dp[5]  = _colorEnd[1] - cs1
    dp[6]  = _colorEnd[2] - cs2
    dp[7]  = _colorEnd[3] - cs3
    dp[8]  = _size[0]
    dp[9]  = _size[1]
    dp[10] = _rotation
    dp[11] = widthScale ? 1 : 0
    dp[12] = _widthScaleRef
    if (widthScale) {
      dp[13] = _cameraEye[0]
      dp[14] = _cameraEye[1]
      dp[15] = _cameraEye[2]
    } else {
      dp[13] = 0
      dp[14] = 0
      dp[15] = 0
    }
    ParticleSim3DCore.pack(_sim, _inst, _liveCount, dp)
    _instBuf.writeFloatsN(0, _inst, _liveCount * 16)
    renderer.drawBillboardN(_texture, _instBuf, _liveCount)
  }
}

// Native plugin entry points. The hot per-frame integrate + pack
// loops live in `plugins/wlift_particles` — the wlift JIT can't beat
// a hand-written `&mut [f32]` tight loop for the 100k-particle
// workload that the parity Phase 6d exit gate targets, so we hand
// the work off to Rust.
#!native = "wlift_particles"
foreign class ParticleSim3DCore {
  /// Integrate `liveCount` particles in `sim` (8 f32/slot) by the
  /// scalar params in `params` (8 f32 — see plugin source for the
  /// layout). Records expired + kill-plane-crossed deaths into
  /// `deaths` (capacity*3 + 2 floats: header [deathCount, _] then
  /// triple positions). Compacts the sim by swap-with-last and
  /// returns the new live count.
  ///
  /// @param  {Float32Array} sim
  /// @param  {Num}          liveCount
  /// @param  {Float32Array} params  8 floats
  /// @param  {Float32Array} deaths  capacity*3 + 2 floats
  /// @returns {Num}                 new live count
  #!symbol = "wlift_particles_integrate"
  foreign static integrate(sim, liveCount, params, deaths)

  /// Pack `liveCount` live particles from `sim` into `inst` (16
  /// f32/slot, matching `Renderer3D.drawBillboardN`). Caller passes
  /// the per-frame colour gradient + size + rotation + optional
  /// screen-space-width inputs in `params` (16 f32).
  ///
  /// @param  {Float32Array} sim
  /// @param  {Float32Array} inst
  /// @param  {Num}          liveCount
  /// @param  {Float32Array} params  16 floats
  /// @returns {Num}                 the same liveCount, for chaining
  #!symbol = "wlift_particles_pack"
  foreign static pack(sim, inst, liveCount, params)
}
