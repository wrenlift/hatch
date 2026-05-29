// `@hatch:noise`. CPU-side scalar samplers for procedural
// generation pipelines. All entry points are pure functions —
// seed in, deterministic value out — so the same code path
// drives offline tooling (asset preprocessing) and runtime
// terrain / foliage placement.
//
// Returned scalars sit roughly in [-1, 1] (Simplex / Perlin /
// Value) regardless of dimension. `Noise.fbm2` / `Noise.fbm3`
// average octaves of OpenSimplex with caller-controlled
// `lacunarity` (frequency multiplier per octave) and
// `persistence` (amplitude multiplier per octave); the result is
// normalised so it stays in roughly the same range.
//
//   var h = Noise.fbm2(x * 0.01, z * 0.01, 1337, 6, 2.0, 0.5)
//   // h ∈ [-1, 1], use h * heightScale for terrain altitude.
//
// `Noise.fillSimplex2(out, originX, originY, stepX, stepY,
// width, height, seed)` is the batched fast path for heightmap
// generation — pass in a `Float32Array(width * height)` and one
// foreign call samples the whole grid.

#!native = "wlift_noise"
foreign class NoiseCore {
  #!symbol = "wlift_noise_simplex2"
  foreign static simplex2(x, y, seed)

  #!symbol = "wlift_noise_simplex3"
  foreign static simplex3(x, y, z, seed)

  #!symbol = "wlift_noise_perlin2"
  foreign static perlin2(x, y, seed)

  #!symbol = "wlift_noise_perlin3"
  foreign static perlin3(x, y, z, seed)

  #!symbol = "wlift_noise_value2"
  foreign static value2(x, y, seed)

  #!symbol = "wlift_noise_value3"
  foreign static value3(x, y, z, seed)

  #!symbol = "wlift_noise_fbm2"
  foreign static fbm2(x, y, seed, octaves, lacunarity, persistence)

  #!symbol = "wlift_noise_fbm3"
  foreign static fbm3(x, y, z, seed, octaves, lacunarity, persistence)

  #!symbol = "wlift_noise_fill_simplex2"
  foreign static fillSimplex2(out, originX, originY, stepX, stepY, width, height, seed)
}

/// Static namespace for procedural noise scalars. Every function
/// is deterministic in its arguments + `seed` — replays of the
/// same call yield identical bits so generators are reproducible
/// across runs / machines / versions.
class Noise {
  /// 2D OpenSimplex noise. Smooth, isotropic, patent-free; the
  /// default choice for terrain heightmaps and 2D scalar fields.
  /// Range ≈ `[-1, 1]`.
  ///
  /// @param {Num} x
  /// @param {Num} y
  /// @param {Num} seed. 32-bit non-negative integer.
  /// @returns {Num}
  static simplex2(x, y, seed) { NoiseCore.simplex2(x, y, seed) }

  /// 3D OpenSimplex noise. Use for volumetric or animated noise
  /// (`z` as time).
  ///
  /// @param {Num} x
  /// @param {Num} y
  /// @param {Num} z
  /// @param {Num} seed
  /// @returns {Num}
  static simplex3(x, y, z, seed) { NoiseCore.simplex3(x, y, z, seed) }

  /// 2D Perlin gradient noise. Slightly cheaper than Simplex;
  /// shows mild axis-aligned artefacts at high octaves.
  ///
  /// @param {Num} x
  /// @param {Num} y
  /// @param {Num} seed
  /// @returns {Num}
  static perlin2(x, y, seed) { NoiseCore.perlin2(x, y, seed) }

  /// 3D Perlin gradient noise.
  ///
  /// @param {Num} x
  /// @param {Num} y
  /// @param {Num} z
  /// @param {Num} seed
  /// @returns {Num}
  static perlin3(x, y, z, seed) { NoiseCore.perlin3(x, y, z, seed) }

  /// 2D Value noise (lattice-based, smooth interpolation).
  /// Cheapest of the three; blockier look than gradient noise,
  /// good for placeholder terrain and tight CPU budgets.
  ///
  /// @param {Num} x
  /// @param {Num} y
  /// @param {Num} seed
  /// @returns {Num}
  static value2(x, y, seed) { NoiseCore.value2(x, y, seed) }

  /// 3D Value noise.
  ///
  /// @param {Num} x
  /// @param {Num} y
  /// @param {Num} z
  /// @param {Num} seed
  /// @returns {Num}
  static value3(x, y, z, seed) { NoiseCore.value3(x, y, z, seed) }

  /// 2D fractal Brownian motion: sum of `octaves` OpenSimplex
  /// samples, doubling (or `lacunarity`-folding) frequency and
  /// scaling amplitude by `persistence` per step. Result is
  /// normalised so the output range still sits in roughly
  /// `[-1, 1]` regardless of octave count.
  ///
  /// Typical terrain settings: `octaves = 6`, `lacunarity = 2.0`,
  /// `persistence = 0.5`. Drop octaves for cheaper variation.
  ///
  /// @param {Num} x
  /// @param {Num} y
  /// @param {Num} seed
  /// @param {Num} octaves. 1..16.
  /// @param {Num} lacunarity
  /// @param {Num} persistence
  /// @returns {Num}
  static fbm2(x, y, seed, octaves, lacunarity, persistence) {
    NoiseCore.fbm2(x, y, seed, octaves, lacunarity, persistence)
  }

  /// 3D fractal Brownian motion.
  ///
  /// @param {Num} x
  /// @param {Num} y
  /// @param {Num} z
  /// @param {Num} seed
  /// @param {Num} octaves
  /// @param {Num} lacunarity
  /// @param {Num} persistence
  /// @returns {Num}
  static fbm3(x, y, z, seed, octaves, lacunarity, persistence) {
    NoiseCore.fbm3(x, y, z, seed, octaves, lacunarity, persistence)
  }

  /// Batched 2D OpenSimplex heightmap generator. Samples a
  /// `width × height` grid starting at `(originX, originY)` with
  /// per-cell step `(stepX, stepY)`, writes `width * height`
  /// floats into `out` (row-major). One foreign call vs.
  /// `width * height` for a Wren-side loop.
  ///
  /// `out` must be a `Float32Array` with at least `width * height`
  /// slots.
  ///
  /// @param {Float32Array} out
  /// @param {Num} originX
  /// @param {Num} originY
  /// @param {Num} stepX
  /// @param {Num} stepY
  /// @param {Num} width
  /// @param {Num} height
  /// @param {Num} seed
  static fillSimplex2(out, originX, originY, stepX, stepY, width, height, seed) {
    NoiseCore.fillSimplex2(out, originX, originY, stepX, stepY, width, height, seed)
  }
}
