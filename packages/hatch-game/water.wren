// @hatch:game/water — water-surface primitives. Two helpers
// today:
//
//   Water.makePlane(device, opts)
//     Subdivided horizontal mesh, vertex layout matching
//     Renderer3D. The subdivision matters — flat shading wants 1
//     quad, but vertex displacement in a custom WGSL shader needs
//     vertices to displace, so we expose subdivision as an opt
//     and ship 32 per side as the default sweet spot.
//
//   Water.waveHeight(opts, x, z, t)
//     Scalar height value for a sum of noise-driven waves at
//     world (x, z) and time t. Deterministic in inputs + seed; the
//     same shape feeds GPU shaders (sample at vertex position in
//     the VS) and CPU consumers (raycast-against-water for buoyant
//     props).
//
// A custom water material — refraction, foam, specular highlights
// — is a planned follow-up; the mesh + height sampler unblock the
// "I want a lake visible from the camera" case today.

import "@hatch:gpu"   for Mesh
import "@hatch:noise" for Noise

/// Static namespace for water-surface meshes and wave sampling.
class Water {
  /// Build a subdivided horizontal plane Mesh centred on
  /// `(opts.x, opts.y, opts.z)`.
  ///
  /// `opts` keys:
  ///   - `"size"` (Num, default 100) — total side length in world
  ///     units (the mesh is square).
  ///   - `"subdivisions"` (Num, default 32) — vertex count per
  ///     side; the resulting mesh has `(subdivisions + 1)^2`
  ///     vertices and `6 × subdivisions^2` indices. Bump this when
  ///     the displacement shader needs more samples (longer waves,
  ///     finer detail).
  ///   - `"y"` (Num, default 0) — vertical position of the plane.
  ///   - `"originX"` / `"originZ"` (Num, default centred) — shift
  ///     the corner instead of centring; useful for tiling
  ///     chunks against a Terrain footprint.
  ///   - `"uvScale"` (Num, default 1) — u = (i / N) * uvScale;
  ///     set above 1 to tile a normal map across the surface.
  ///
  /// Vertex layout matches Renderer3D's (pos.xyz, normal.xyz, uv.xy);
  /// normals point +Y because the mesh is flat. A displacement
  /// shader can rewrite per-vertex normals from the height
  /// gradient.
  ///
  /// @param {Device} device
  /// @param {Map} opts
  /// @returns {Mesh}
  static makePlane(device, opts) {
    var size = opts.containsKey("size") ? opts["size"] : 100
    var subs = opts.containsKey("subdivisions") ? opts["subdivisions"] : 32
    if (subs < 1) Fiber.abort("Water.makePlane: subdivisions must be >= 1.")
    var y = opts.containsKey("y") ? opts["y"] : 0
    var originX = opts.containsKey("originX") ? opts["originX"] : -size / 2
    var originZ = opts.containsKey("originZ") ? opts["originZ"] : -size / 2
    var uvScale = opts.containsKey("uvScale") ? opts["uvScale"] : 1

    var step = size / subs
    var n = subs + 1
    var inv = uvScale / subs

    var vertices = []
    for (j in 0...n) {
      var z = originZ + j * step
      for (i in 0...n) {
        var x = originX + i * step
        vertices.add(x)
        vertices.add(y)
        vertices.add(z)
        vertices.add(0)
        vertices.add(1)
        vertices.add(0)
        vertices.add(i * inv)
        vertices.add(j * inv)
      }
    }

    var indices = []
    for (j in 0...subs) {
      for (i in 0...subs) {
        var a = j * n + i
        var b = a + 1
        var c = a + n
        var d = c + 1
        indices.add(a)
        indices.add(c)
        indices.add(b)
        indices.add(b)
        indices.add(c)
        indices.add(d)
      }
    }
    return Mesh.fromArrays(device, vertices, indices)
  }

  /// Sum-of-octaves wave height at world `(x, z)` and time `t`.
  ///
  /// Uses `Noise.simplex3` with `z` repurposed as a 2D position
  /// component and `t * timeScale` as the third axis, so the
  /// wave field genuinely evolves over time rather than just
  /// scrolling.
  ///
  /// `opts` keys:
  ///   - `"amplitude"` (Num, default 0.5) — peak displacement;
  ///     a 2-unit ocean swell wants ~1.0, a kiddie pool wants 0.05.
  ///   - `"scale"` (Num, default 0.1) — spatial frequency. Larger
  ///     → tighter wavelength.
  ///   - `"timeScale"` (Num, default 0.5) — temporal evolution
  ///     rate.
  ///   - `"octaves"` (Num, default 3) — sum that many simplex3
  ///     samples with doubling frequency + halving amplitude per
  ///     octave; classic fBm shape.
  ///   - `"seed"` (Num, default 0).
  ///
  /// Designed to feed either a CPU buoyancy raycast or a vertex
  /// shader (sample at the post-displacement world point of each
  /// vertex). The output is amplitude-bounded by the configured
  /// `amplitude` × harmonic series, never beyond.
  ///
  /// @param {Map} opts
  /// @param {Num} x
  /// @param {Num} z
  /// @param {Num} t
  /// @returns {Num}
  static waveHeight(opts, x, z, t) {
    var amplitude = opts.containsKey("amplitude") ? opts["amplitude"] : 0.5
    var scale     = opts.containsKey("scale")     ? opts["scale"]     : 0.1
    var timeScale = opts.containsKey("timeScale") ? opts["timeScale"] : 0.5
    var octaves   = opts.containsKey("octaves")   ? opts["octaves"]   : 3
    var seed      = opts.containsKey("seed")      ? opts["seed"]      : 0
    if (octaves < 1 || octaves > 8) {
      Fiber.abort("Water.waveHeight: octaves must be in 1..8.")
    }

    var acc = 0
    var amp = amplitude
    var freq = scale
    var st = t * timeScale
    var i = 0
    while (i < octaves) {
      acc = acc + amp * Noise.simplex3(x * freq, z * freq, st * freq, seed + i)
      amp = amp * 0.5
      freq = freq * 2
      i = i + 1
    }
    return acc
  }
}
