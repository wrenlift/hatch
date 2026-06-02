// @hatch:game/weather — environmental forces and overlays for
// procedural worlds.
//
// `Wind` exposes a deterministic 3D vector field driven by
// `@hatch:noise` simplex3 — a "wind here, now" sampler suitable
// for particle integrators, foliage-sway shader uniforms, and
// gameplay rigs that need a coherent gust pattern.
//
// `Weather` ships preset constructors for the three workhorse
// outdoor effects: `Weather.rain(...)`, `Weather.snow(...)`,
// `Weather.fog(...)`. Rain + snow back onto the shipped
// `ParticleSystem3D` (CPU sim) so they work today; the
// compute-driven version that scales past ~5k particles plugs
// in via the same factory API once `ParticleSystem3DCompute`
// lands.
//
//   // Per-frame in your particle update
//   var w = Wind.sample({ "baseX": -1, "baseZ": 0, "gust": 0.8,
//                         "scale": 0.05, "timeScale": 0.3 },
//                       p.x, p.y, p.z, g.time)
//   p.vx = p.vx + w[0] * dt
//   p.vy = p.vy + w[1] * dt
//   p.vz = p.vz + w[2] * dt

import "@hatch:noise"   for Noise
import "./particles"    for ParticleSystem3D
import "./gpu_particles" for GpuParticleSystem3D
import "./fog"          for Fog

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

/// Preset weather effects. Each factory returns a fully-configured
/// `ParticleSystem3D` (rain / snow) or `Fog` (fog), tuned with
/// plausible defaults the caller can override via the `opts` Map.
/// The returned object is the same shape `Particles.register` and
/// the renderer's per-frame draw loop already consume.
///
/// ## Example
///
/// ```wren
/// var rain = Weather.rain(g.device, {
///   "texture":  rainTex,
///   "capacity": 800,
///   "wind":     [-2, 0, 0]
/// })
/// Particles.register(rain)
/// // ...later:
/// rain.setPosition(camera.x, camera.y + 15, camera.z)  // column above the camera
/// rain.draw(renderer)
/// ```
class Weather {
  /// Configure a rain column. Particles spawn in a (`spread.x`,
  /// 0, `spread.z`) box above the emitter position, fall under
  /// gravity, fade out at ground level (the caller drives the
  /// emitter to follow the camera so the column tracks the
  /// player).
  ///
  /// | Option       | Type        | Default              | Notes                                       |
  /// |--------------|-------------|----------------------|---------------------------------------------|
  /// | `texture`    | `Texture`   | required             | Streak / droplet sprite.                    |
  /// | `capacity`   | `Num`       | `1000`               | Max live particles.                         |
  /// | `intensity`  | `Num`       | `400`                | Particles spawned per second.               |
  /// | `area`       | `[Num, Num]`| `[40, 40]`           | XZ half-extent of the spawn column.         |
  /// | `fallSpeed`  | `Num`       | `12`                 | Downward velocity (m/s).                    |
  /// | `wind`       | `[Num, Num, Num]` | `[0, 0, 0]`    | Constant horizontal drift.                  |
  /// | `length`     | `Num`       | `1.2`                | Streak length (sprite height).              |
  /// | `width`      | `Num`       | `0.04`               | Streak width.                               |
  /// | `lifetime`   | `[Num, Num]`| `[0.6, 1.0]`         | Seconds.                                    |
  /// | `color`      | `[r,g,b,a]` | `[0.7, 0.8, 0.95, 0.4]` | Translucent water-blue.                |
  ///
  /// `opts.gpu = true` swaps the CPU `ParticleSystem3D` backing
  /// for the compute-driven `GpuParticleSystem3D`. GPU mode scales
  /// well past 100k drops at no CPU cost — at the price of losing
  /// the death-event hook (kill plane + per-impact rings) that
  /// the CPU sim exposes for the water-strike pattern. Use GPU
  /// for massive storms; stay on CPU when you need every drop's
  /// strike location.
  ///
  /// @param {Device} device
  /// @param {Map} opts
  /// @returns {ParticleSystem3D | GpuParticleSystem3D}
  static rain(device, opts) {
    if (opts == null) Fiber.abort("Weather.rain: opts is required")
    var tex = opts["texture"]
    if (tex == null) Fiber.abort("Weather.rain: opts.texture is required")
    var capacity = opts.containsKey("capacity")  ? opts["capacity"]  : 1000
    var rate     = opts.containsKey("intensity") ? opts["intensity"] : 400
    var area     = opts.containsKey("area")      ? opts["area"]      : [40, 40]
    var fall     = opts.containsKey("fallSpeed") ? opts["fallSpeed"] : 12
    var wind     = opts.containsKey("wind")      ? opts["wind"]      : [0, 0, 0]
    var length_  = opts.containsKey("length")    ? opts["length"]    : 1.2
    var width    = opts.containsKey("width")     ? opts["width"]     : 0.04
    var life     = opts.containsKey("lifetime")  ? opts["lifetime"]  : [0.6, 1.0]
    var color    = opts.containsKey("color")     ? opts["color"]     : [0.7, 0.8, 0.95, 0.4]
    var cfg = {
      "texture":      tex,
      "capacity":     capacity,
      "emissionRate": rate,
      "lifetime":     life,
      // Emitter origin is updated by the caller each frame to
      // track the camera; spawn spread covers the full column.
      "spread":       [area[0], 0, area[1]],
      "velocity":     [[wind[0], -fall, wind[2]], [wind[0], -fall, wind[2]]],
      "gravity":      [0, 0, 0],   // velocity already carries the fall
      "size":         [width, length_],
      "color":        [color, color]
    }
    var useGpu = opts.containsKey("gpu") ? opts["gpu"] : false
    if (useGpu) return GpuParticleSystem3D.new(device, cfg)
    return ParticleSystem3D.new(device, cfg)
  }

  /// Configure a snow column. Same shape as `rain` but with
  /// gentler defaults, side-to-side wind drift, and an aged
  /// fade-out alpha curve.
  ///
  /// | Option       | Type        | Default              | Notes                                       |
  /// |--------------|-------------|----------------------|---------------------------------------------|
  /// | `texture`    | `Texture`   | required             | Snowflake sprite (or a small white disc).   |
  /// | `capacity`   | `Num`       | `1500`               | Max live particles.                         |
  /// | `intensity`  | `Num`       | `200`                | Particles spawned per second.               |
  /// | `area`       | `[Num, Num]`| `[60, 60]`           | XZ half-extent of the spawn column.         |
  /// | `fallSpeed`  | `Num`       | `2.0`                | Downward velocity (m/s).                    |
  /// | `wind`       | `[Num, Num, Num]` | `[0.5, 0, 0.5]`| Slight drift.                              |
  /// | `size`       | `Num`       | `0.18`               | Flake size (both width + height).           |
  /// | `lifetime`   | `[Num, Num]`| `[4.0, 6.0]`         | Long visible life for slow falls.           |
  /// | `color`      | `[r,g,b,a]` | `[1.0, 1.0, 1.0, 0.85]` | Near-white.                            |
  ///
  /// @param {Device} device
  /// @param {Map} opts
  /// @returns {ParticleSystem3D}
  static snow(device, opts) {
    if (opts == null) Fiber.abort("Weather.snow: opts is required")
    var tex = opts["texture"]
    if (tex == null) Fiber.abort("Weather.snow: opts.texture is required")
    var capacity = opts.containsKey("capacity")  ? opts["capacity"]  : 1500
    var rate     = opts.containsKey("intensity") ? opts["intensity"] : 200
    var area     = opts.containsKey("area")      ? opts["area"]      : [60, 60]
    var fall     = opts.containsKey("fallSpeed") ? opts["fallSpeed"] : 2.0
    var wind     = opts.containsKey("wind")      ? opts["wind"]      : [0.5, 0, 0.5]
    var size     = opts.containsKey("size")      ? opts["size"]      : 0.18
    var life     = opts.containsKey("lifetime")  ? opts["lifetime"]  : [4.0, 6.0]
    var color    = opts.containsKey("color")     ? opts["color"]     : [1.0, 1.0, 1.0, 0.85]
    var cfg = {
      "texture":      tex,
      "capacity":     capacity,
      "emissionRate": rate,
      "lifetime":     life,
      "spread":       [area[0], 0, area[1]],
      "velocity":     [[wind[0] - 0.4, -fall, wind[2] - 0.4],
                       [wind[0] + 0.4, -fall, wind[2] + 0.4]],
      "gravity":      [0, 0, 0],
      "size":         [size, size],
      "color":        [color, color]
    }
    var useGpu = opts.containsKey("gpu") ? opts["gpu"] : false
    if (useGpu) return GpuParticleSystem3D.new(device, cfg)
    return ParticleSystem3D.new(device, cfg)
  }

  /// Configure an aerial fog. Wraps `Fog` (see `./fog`) with
  /// presets tuned for the requested density / range. Use the
  /// returned `Fog` exactly like a hand-built one: pass it to
  /// `WaterPipeline.setFog(fog)` and any `Renderer3D` consumer
  /// that exposes `setFog`.
  ///
  /// | Option   | Type        | Default                  | Notes                                              |
  /// |----------|-------------|--------------------------|----------------------------------------------------|
  /// | `density`| `Num`       | `0.02`                   | exp²-curve density (m⁻¹). Higher → thicker fog.    |
  /// | `start`  | `Num`       | `60`                     | Distance the linear curve starts at.               |
  /// | `end`    | `Num`       | `130`                    | Distance the linear curve fully saturates.         |
  /// | `curve`  | `Num`       | `1`                      | `0` linear, `1` exp² — exp² reads as atmospheric.  |
  /// | `color`  | `[r,g,b]`   | `[0.96, 0.86, 0.72]`     | Should match the sky's horizon band.               |
  ///
  /// @param {Map} opts
  /// @returns {Fog}
  static fog(opts) {
    if (opts == null) opts = {}
    var f = Fog.new()
    if (opts.containsKey("density")) f.density = opts["density"]
    if (opts.containsKey("start"))   f.start   = opts["start"]
    if (opts.containsKey("end"))     f.end     = opts["end"]
    if (opts.containsKey("curve"))   f.curve   = opts["curve"]
    if (opts.containsKey("color"))   f.color   = opts["color"]
    return f
  }
}
