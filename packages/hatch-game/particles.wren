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
    _instBuf = device.createBuffer({
      "size":  _capacity * 16 * 4,
      "usage": ["storage", "copy-dst"],
      "label": "particles3d-instance"
    })
    _emissionAccum = 0
    _liveCount     = 0
    _seed          = 0
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
    var i = 0
    // Compact: walk the sim array, integrate alive slots, drop
    // expired ones by swapping with the last-live slot.
    while (i < _liveCount) {
      var off = i * 8
      var age = _sim[off + 6] + dt
      if (age >= _sim[off + 7]) {
        // Expired — swap with the last-live slot. Decrements
        // liveCount; recheck this index next iter so the swapped-
        // in slot also gets integrated.
        _liveCount = _liveCount - 1
        if (i != _liveCount) {
          var srcOff = _liveCount * 8
          var k = 0
          while (k < 8) {
            _sim[off + k] = _sim[srcOff + k]
            k = k + 1
          }
        }
        continue
      }
      // Integrate.
      _sim[off + 3] = _sim[off + 3] + _gravity[0] * dt - _sim[off + 3] * _drag * dt
      _sim[off + 4] = _sim[off + 4] + _gravity[1] * dt - _sim[off + 4] * _drag * dt
      _sim[off + 5] = _sim[off + 5] + _gravity[2] * dt - _sim[off + 5] * _drag * dt
      _sim[off]     = _sim[off]     + _sim[off + 3] * dt
      _sim[off + 1] = _sim[off + 1] + _sim[off + 4] * dt
      _sim[off + 2] = _sim[off + 2] + _sim[off + 5] * dt
      _sim[off + 6] = age
      i = i + 1
    }
    // Auto-emit if playing + a rate is configured.
    if (_playing && _emissionRate > 0) {
      _emissionAccum = _emissionAccum + _emissionRate * dt
      while (_emissionAccum >= 1) {
        if (!spawnOne_()) break
        _emissionAccum = _emissionAccum - 1
      }
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
    _sim[off + 7] = _lifetime[0] + random_() * (_lifetime[1] - _lifetime[0])
    _liveCount = _liveCount + 1
    return true
  }

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
    var sx = _size[0]
    var sy = _size[1]
    // Pack each live particle into the instance buffer with
    // colour interpolated from start → end across its life.
    var i = 0
    while (i < _liveCount) {
      var simOff = i * 8
      var t = _sim[simOff + 6] / _sim[simOff + 7]
      if (t < 0) t = 0
      if (t > 1) t = 1
      var r = _colorStart[0] + (_colorEnd[0] - _colorStart[0]) * t
      var g = _colorStart[1] + (_colorEnd[1] - _colorStart[1]) * t
      var b = _colorStart[2] + (_colorEnd[2] - _colorStart[2]) * t
      var a = _colorStart[3] + (_colorEnd[3] - _colorStart[3]) * t
      var off = i * 16
      _inst[off]      = _sim[simOff]      // ox
      _inst[off + 1]  = _sim[simOff + 1]  // oy
      _inst[off + 2]  = _sim[simOff + 2]  // oz
      _inst[off + 3]  = sx
      _inst[off + 4]  = sy
      _inst[off + 5]  = 0      // u0
      _inst[off + 6]  = 0      // v0
      _inst[off + 7]  = 1      // u1
      _inst[off + 8]  = 1      // v1
      _inst[off + 9]  = r
      _inst[off + 10] = g
      _inst[off + 11] = b
      _inst[off + 12] = a
      _inst[off + 13] = 0      // rotation — fixed for now
      _inst[off + 14] = 0      // lodIndex
      _inst[off + 15] = 0
      i = i + 1
    }
    _instBuf.writeFloats(0, _inst)
    renderer.drawBillboardN(_texture, _instBuf, _liveCount)
  }
}
