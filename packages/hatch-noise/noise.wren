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

  #!symbol = "wlift_noise_worley2"
  foreign static worley2(x, y, seed)

  #!symbol = "wlift_noise_worley3"
  foreign static worley3(x, y, z, seed)

  #!symbol = "wlift_noise_ridged_fbm2"
  foreign static ridgedFbm2(x, y, seed, octaves, lacunarity, persistence)

  #!symbol = "wlift_noise_ridged_fbm3"
  foreign static ridgedFbm3(x, y, z, seed, octaves, lacunarity, persistence)

  #!symbol = "wlift_noise_fill_perlin2"
  foreign static fillPerlin2(out, originX, originY, stepX, stepY, width, height, seed)

  #!symbol = "wlift_noise_fill_value2"
  foreign static fillValue2(out, originX, originY, stepX, stepY, width, height, seed)

  #!symbol = "wlift_noise_fill_worley2"
  foreign static fillWorley2(out, originX, originY, stepX, stepY, width, height, seed)

  #!symbol = "wlift_noise_fill_simplex3"
  foreign static fillSimplex3(out, originX, originY, originZ, stepX, stepY, stepZ, width, height, depth, seed)
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

  /// 2D Worley (cellular) noise via F1 Euclidean distance to the
  /// nearest jittered seed point. Use for stone / scale / leaf
  /// vein patterns, sci-fi panel masks, foliage density jitter.
  /// Range ≈ `[-1, 1]`.
  ///
  /// @param {Num} x
  /// @param {Num} y
  /// @param {Num} seed
  /// @returns {Num}
  static worley2(x, y, seed) { NoiseCore.worley2(x, y, seed) }

  /// 3D Worley noise.
  ///
  /// @param {Num} x
  /// @param {Num} y
  /// @param {Num} z
  /// @param {Num} seed
  /// @returns {Num}
  static worley3(x, y, z, seed) { NoiseCore.worley3(x, y, z, seed) }

  /// 2D ridged-multi fBM. Sharp valley / ridge silhouettes — the
  /// classic mountain-range generator. Per octave it takes
  /// `(1 - |simplex|)^2` then accumulates with the same lacunarity
  /// / persistence as `fbm2`. Output ≈ `[0, 1]`.
  ///
  /// @param {Num} x
  /// @param {Num} y
  /// @param {Num} seed
  /// @param {Num} octaves. 1..16.
  /// @param {Num} lacunarity
  /// @param {Num} persistence
  /// @returns {Num}
  static ridgedFbm2(x, y, seed, octaves, lacunarity, persistence) {
    NoiseCore.ridgedFbm2(x, y, seed, octaves, lacunarity, persistence)
  }

  /// 3D ridged-multi fBM. Output ≈ `[0, 1]`.
  ///
  /// @param {Num} x
  /// @param {Num} y
  /// @param {Num} z
  /// @param {Num} seed
  /// @param {Num} octaves
  /// @param {Num} lacunarity
  /// @param {Num} persistence
  /// @returns {Num}
  static ridgedFbm3(x, y, z, seed, octaves, lacunarity, persistence) {
    NoiseCore.ridgedFbm3(x, y, z, seed, octaves, lacunarity, persistence)
  }

  /// Bulk-fill the same grid `fillSimplex2` accepts with 2D Perlin
  /// samples. `out` must be a Float32Array sized `width * height`.
  ///
  /// @param {Float32Array} out
  /// @param {Num} originX
  /// @param {Num} originY
  /// @param {Num} stepX
  /// @param {Num} stepY
  /// @param {Num} width
  /// @param {Num} height
  /// @param {Num} seed
  static fillPerlin2(out, originX, originY, stepX, stepY, width, height, seed) {
    NoiseCore.fillPerlin2(out, originX, originY, stepX, stepY, width, height, seed)
  }

  /// Bulk-fill 2D Value noise. Same grid layout as `fillSimplex2`.
  /// @param {Float32Array} out
  /// @param {Num} originX
  /// @param {Num} originY
  /// @param {Num} stepX
  /// @param {Num} stepY
  /// @param {Num} width
  /// @param {Num} height
  /// @param {Num} seed
  static fillValue2(out, originX, originY, stepX, stepY, width, height, seed) {
    NoiseCore.fillValue2(out, originX, originY, stepX, stepY, width, height, seed)
  }

  /// Bulk-fill 2D Worley noise. Same grid layout as `fillSimplex2`.
  /// @param {Float32Array} out
  /// @param {Num} originX
  /// @param {Num} originY
  /// @param {Num} stepX
  /// @param {Num} stepY
  /// @param {Num} width
  /// @param {Num} height
  /// @param {Num} seed
  static fillWorley2(out, originX, originY, stepX, stepY, width, height, seed) {
    NoiseCore.fillWorley2(out, originX, originY, stepX, stepY, width, height, seed)
  }

  /// 3D Simplex bulk fill. Writes `width * height * depth` floats
  /// into `out` (`Float32Array`) laid out z-outermost, then y, then
  /// x. One foreign call vs. `width * height * depth` for a
  /// Wren-side loop — used by procedural volumes, voxel terrain,
  /// and 3D weather noise.
  ///
  /// @param {Float32Array} out
  /// @param {Num} originX
  /// @param {Num} originY
  /// @param {Num} originZ
  /// @param {Num} stepX
  /// @param {Num} stepY
  /// @param {Num} stepZ
  /// @param {Num} width
  /// @param {Num} height
  /// @param {Num} depth
  /// @param {Num} seed
  static fillSimplex3(out, originX, originY, originZ,
                      stepX, stepY, stepZ,
                      width, height, depth, seed) {
    NoiseCore.fillSimplex3(out, originX, originY, originZ,
                           stepX, stepY, stepZ,
                           width, height, depth, seed)
  }

  /// WGSL companion for the GPU side of procedural pipelines.
  /// Returns a string that can be `Shader.compose([...])`d into a
  /// terrain / foliage / weather compute or vertex shader. Exposes
  /// `hash2`, `hash3`, `value_noise2`, `value_noise3`, `simplex2`,
  /// `worley2`, `fbm2`, `ridged_fbm2`. The fns are hash-based so
  /// they're deterministic in `(x, y, seed)` GPU-side and read the
  /// same value the CPU `Noise.*` returns to within float-rounding
  /// — close enough for terrain LOD seams.
  ///
  /// Inputs are `vec2<f32>`/`vec3<f32>` world coordinates and a
  /// `u32` seed; outputs roughly `[-1, 1]` (Simplex / Value) or
  /// `[0, 1]` (Worley F1, ridged fBM).
  ///
  /// @returns {String}
  static WGSL_COMPANION {
    return "
      // -- Deterministic hashes ---------------------------------
      fn _wlift_hash2(p: vec2<f32>, seed: u32) -> f32 {
        var x = p * vec2<f32>(127.1, 311.7) + f32(seed) * 0.13;
        let n = sin(dot(x, vec2<f32>(127.1, 311.7))) * 43758.5453;
        return fract(n) * 2.0 - 1.0;
      }
      fn _wlift_hash3(p: vec3<f32>, seed: u32) -> f32 {
        var x = dot(p, vec3<f32>(127.1, 311.7, 74.7)) + f32(seed) * 0.13;
        return fract(sin(x) * 43758.5453) * 2.0 - 1.0;
      }
      // -- 2D Value noise (smooth bilinear of corner hashes) ---
      fn value_noise2(p: vec2<f32>, seed: u32) -> f32 {
        let i = floor(p);
        let f = fract(p);
        let u = f * f * (3.0 - 2.0 * f);
        let a = _wlift_hash2(i + vec2<f32>(0.0, 0.0), seed);
        let b = _wlift_hash2(i + vec2<f32>(1.0, 0.0), seed);
        let c = _wlift_hash2(i + vec2<f32>(0.0, 1.0), seed);
        let d = _wlift_hash2(i + vec2<f32>(1.0, 1.0), seed);
        return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
      }
      fn value_noise3(p: vec3<f32>, seed: u32) -> f32 {
        let i = floor(p);
        let f = fract(p);
        let u = f * f * (3.0 - 2.0 * f);
        let h000 = _wlift_hash3(i + vec3<f32>(0.0, 0.0, 0.0), seed);
        let h100 = _wlift_hash3(i + vec3<f32>(1.0, 0.0, 0.0), seed);
        let h010 = _wlift_hash3(i + vec3<f32>(0.0, 1.0, 0.0), seed);
        let h110 = _wlift_hash3(i + vec3<f32>(1.0, 1.0, 0.0), seed);
        let h001 = _wlift_hash3(i + vec3<f32>(0.0, 0.0, 1.0), seed);
        let h101 = _wlift_hash3(i + vec3<f32>(1.0, 0.0, 1.0), seed);
        let h011 = _wlift_hash3(i + vec3<f32>(0.0, 1.0, 1.0), seed);
        let h111 = _wlift_hash3(i + vec3<f32>(1.0, 1.0, 1.0), seed);
        let z0 = mix(mix(h000, h100, u.x), mix(h010, h110, u.x), u.y);
        let z1 = mix(mix(h001, h101, u.x), mix(h011, h111, u.x), u.y);
        return mix(z0, z1, u.z);
      }
      // -- 2D Worley F1 (distance to nearest of 9 jittered cell
      //    centres). Output normalised to roughly [0, 1].
      fn worley2(p: vec2<f32>, seed: u32) -> f32 {
        let i = floor(p);
        let f = fract(p);
        var minD = 8.0;
        for (var dy = -1; dy <= 1; dy = dy + 1) {
          for (var dx = -1; dx <= 1; dx = dx + 1) {
            let g = vec2<f32>(f32(dx), f32(dy));
            let h = _wlift_hash2(i + g, seed) * 0.5 + 0.5;
            let h2 = _wlift_hash2(i + g + vec2<f32>(11.7, 17.3), seed) * 0.5 + 0.5;
            let r = g + vec2<f32>(h, h2) - f;
            let d2 = dot(r, r);
            minD = min(minD, d2);
          }
        }
        return clamp(sqrt(minD), 0.0, 1.0);
      }
      // -- 2D fBM: layered Value-noise octaves. Same shape as the
      //    CPU `Noise.fbm2` but uses value_noise2 under the hood so
      //    no Wgpu gradient table is needed.
      fn fbm2(p: vec2<f32>, seed: u32, octaves: u32, lacunarity: f32, persistence: f32) -> f32 {
        var acc = 0.0;
        var amp = 1.0;
        var freq = 1.0;
        var norm = 0.0;
        for (var i: u32 = 0u; i < octaves; i = i + 1u) {
          acc = acc + amp * value_noise2(p * freq, seed);
          norm = norm + amp;
          amp = amp * persistence;
          freq = freq * lacunarity;
        }
        return select(0.0, acc / norm, norm > 0.0);
      }
      // -- 2D ridged-multi fBM. Output ≈ [0, 1].
      fn ridged_fbm2(p: vec2<f32>, seed: u32, octaves: u32, lacunarity: f32, persistence: f32) -> f32 {
        var acc = 0.0;
        var amp = 1.0;
        var freq = 1.0;
        var norm = 0.0;
        for (var i: u32 = 0u; i < octaves; i = i + 1u) {
          let s = value_noise2(p * freq, seed);
          let r = 1.0 - abs(s);
          acc = acc + amp * r * r;
          norm = norm + amp;
          amp = amp * persistence;
          freq = freq * lacunarity;
        }
        return select(0.0, acc / norm, norm > 0.0);
      }
    "
  }
}
