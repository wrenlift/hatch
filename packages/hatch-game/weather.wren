// @hatch:game/weather — environmental forces and overlays for
// procedural worlds. Ships in stages; today this module exposes
// `Wind` — a deterministic 3D vector field driven by `@hatch:noise`
// simplex3 with caller-controlled base direction, gust amplitude,
// and time evolution. Drop it into your particle system's
// per-frame integrator, your foliage's sway shader, or any other
// place a "wind here, now" value is needed.
//
// Full rain / snow / cloud overlays compose on top of `Wind` plus
// the existing `ParticleSystem` and Renderer3D pipeline; they ship
// in a follow-up release once the compute-particle path lands.
//
//   // Per-frame in your particle update
//   var w = Wind.sample({ "baseX": -1, "baseZ": 0, "gust": 0.8,
//                         "scale": 0.05, "timeScale": 0.3 },
//                       p.x, p.y, p.z, g.time)
//   p.vx = p.vx + w[0] * dt
//   p.vy = p.vy + w[1] * dt
//   p.vz = p.vz + w[2] * dt

import "@hatch:noise" for Noise

/// Static namespace for the wind sampler. Deterministic: same
/// `(opts, x, y, z, t)` → identical vector across runs / machines.
class Wind {
  /// Sample the wind vector at world position `(x, y, z)` and
  /// time `t`. Returns `[vx, vy, vz]`.
  ///
  /// `opts` keys (all optional):
  ///   - `"baseX"` / `"baseY"` / `"baseZ"` (Num, default
  ///     `(1, 0, 0)`) — directional bias. The unmodulated part of
  ///     the field; set to your prevailing-wind unit vector and
  ///     scale by `"baseStrength"`.
  ///   - `"baseStrength"` (Num, default 1) — scalar applied to
  ///     the base direction. World-units per second.
  ///   - `"gust"` (Num, default 0.5) — amplitude of the turbulent
  ///     simplex3 perturbation, in the same units as
  ///     `baseStrength`.
  ///   - `"scale"` (Num, default 0.05) — spatial frequency of
  ///     the turbulence. Smaller → broader gusts; larger →
  ///     finer chop. Apply consistently across uses or the field
  ///     looks discontinuous between samplers.
  ///   - `"timeScale"` (Num, default 0.25) — temporal evolution
  ///     rate. Larger → wind shifts more quickly.
  ///   - `"seed"` (Num, default 0).
  ///
  /// Implementation: each component (x, y, z) is one
  /// `Noise.simplex3` lookup at a slightly offset point in
  /// (x, y, z, t) space, so the three components decorrelate and
  /// the field reads as a true vector rather than a scalar
  /// projected onto a basis.
  ///
  /// @param {Map} opts
  /// @param {Num} x
  /// @param {Num} y
  /// @param {Num} z
  /// @param {Num} t
  /// @returns {List} `[vx, vy, vz]`
  static sample(opts, x, y, z, t) {
    var baseX = opts.containsKey("baseX") ? opts["baseX"] : 1
    var baseY = opts.containsKey("baseY") ? opts["baseY"] : 0
    var baseZ = opts.containsKey("baseZ") ? opts["baseZ"] : 0
    var baseStrength = opts.containsKey("baseStrength") ? opts["baseStrength"] : 1
    var gust         = opts.containsKey("gust")         ? opts["gust"]         : 0.5
    var scale        = opts.containsKey("scale")        ? opts["scale"]        : 0.05
    var timeScale    = opts.containsKey("timeScale")    ? opts["timeScale"]    : 0.25
    var seed         = opts.containsKey("seed")         ? opts["seed"]         : 0

    var sx = x * scale
    var sy = y * scale
    var sz = z * scale
    var st = t * timeScale

    // Decorrelate the three turbulence channels two ways:
    //   1. Distinct seed offsets so each channel reads a different
    //      noise field even at the origin (where simplex3 collapses
    //      to 0 regardless of seed).
    //   2. Per-channel constant offsets in noise space so a wind
    //      sampler at world (0, 0, 0) doesn't pin one component to
    //      simplex3(0, 0, 0).
    var tx = Noise.simplex3(sx + st + 17.13, sy + 31.71,      sz + 53.43,      seed)
    var ty = Noise.simplex3(sx + 53.43,      sy + st + 17.13, sz + 31.71,      seed + 1)
    var tz = Noise.simplex3(sx + 31.71,      sy + 53.43,      sz + st + 17.13, seed + 2)

    return [
      baseX * baseStrength + tx * gust,
      baseY * baseStrength + ty * gust,
      baseZ * baseStrength + tz * gust
    ]
  }

  /// Apply a wind impulse to a velocity triple. Saves the
  /// vector-allocation per particle the explicit two-step
  /// `var w = Wind.sample(...); p.vx = p.vx + w[0] * dt` pattern
  /// requires. Mutates `velocity` in place; returns it for
  /// chaining.
  ///
  /// `velocity` must be a 3-element List `[vx, vy, vz]`.
  ///
  /// @param {Map} opts
  /// @param {Num} x
  /// @param {Num} y
  /// @param {Num} z
  /// @param {Num} t
  /// @param {Num} dt
  /// @param {List} velocity
  /// @returns {List}
  static apply(opts, x, y, z, t, dt, velocity) {
    var w = Wind.sample(opts, x, y, z, t)
    velocity[0] = velocity[0] + w[0] * dt
    velocity[1] = velocity[1] + w[1] * dt
    velocity[2] = velocity[2] + w[2] * dt
    return velocity
  }
}
