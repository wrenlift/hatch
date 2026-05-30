// @hatch:game/terrain — heightmap-driven mesh generation.
//
// Two paths today:
//
//   Terrain.meshFromHeightmap(device, heights, w, d, opts)
//     Build a Mesh from a flat Float32Array. Caller-supplied
//     heights drive the y-coordinate; normals are computed via
//     central-difference gradients of the height field.
//
//   Terrain.fromNoise(device, opts)
//     Convenience: allocate a heightmap, fill it with
//     `Noise.fillSimplex2`, build the mesh. The composed path
//     for procedural terrain.
//
// The mesh slots directly into the existing Renderer3D draw path
// (8-float pos/normal/uv vertex layout, u32 indices). Pair with
// `@hatch:gpu`'s instanced + culled draw surface to cover wider
// worlds: bucket terrain chunks into a ClusterGrid, query the
// camera AABB per frame, draw the survivors.

import "@hatch:gpu"   for Mesh
import "@hatch:noise" for Noise

/// Static namespace for terrain mesh generation.
class Terrain {
  /// Build a `@hatch:gpu` Mesh from a height grid.
  ///
  /// The heightmap is laid out row-major: `heights[j * width + i]`
  /// holds the y-coordinate sample for grid cell `(i, j)`. The
  /// mesh spans `(width - 1) * stepX` units in X and `(depth - 1)
  /// * stepZ` in Z, centred on the origin.
  ///
  /// `opts` keys (all optional):
  ///   - `"stepX"` (Num, default 1) — world spacing per X column
  ///   - `"stepZ"` (Num, default 1) — world spacing per Z row
  ///   - `"amplitude"` (Num, default 1) — multiplier on the
  ///     height samples; cheap way to scale the relief without
  ///     resampling the heightmap.
  ///   - `"originX"` / `"originZ"` (Num, default centred) —
  ///     shift the mesh so a corner lands at a specific world
  ///     point; useful for tiling chunks.
  ///   - `"uvScale"` (Num, default 1) — `u = (i / (width - 1)) *
  ///     uvScale`, same for v. Set above 1 to tile a sampled
  ///     texture across the chunk.
  ///
  /// Normals are central-difference gradients of the height
  /// field, normalised — accurate for any smooth h(x, z) without
  /// touching the heightmap twice.
  ///
  /// Vertex layout matches Renderer3D's: `pos.xyz, normal.xyz,
  /// uv.xy` (8 floats per vertex). Index type is `u32`.
  ///
  /// @param {Device} device
  /// @param {Float32Array} heights
  /// @param {Num} width
  /// @param {Num} depth
  /// @param {Map} opts
  /// @returns {Mesh}
  static meshFromHeightmap(device, heights, width, depth, opts) {
    if (width < 2 || depth < 2) {
      Fiber.abort("Terrain.meshFromHeightmap: width and depth must be >= 2.")
    }
    var stepX     = opts.containsKey("stepX")     ? opts["stepX"]     : 1
    var stepZ     = opts.containsKey("stepZ")     ? opts["stepZ"]     : 1
    var amplitude = opts.containsKey("amplitude") ? opts["amplitude"] : 1
    var originX   = opts.containsKey("originX")   ? opts["originX"]   : -((width - 1) * stepX) / 2
    var originZ   = opts.containsKey("originZ")   ? opts["originZ"]   : -((depth - 1) * stepZ) / 2
    var uvScale   = opts.containsKey("uvScale")   ? opts["uvScale"]   : 1

    var invW = uvScale / (width - 1)
    var invD = uvScale / (depth - 1)
    var inv2sx = 1 / (2 * stepX)
    var inv2sz = 1 / (2 * stepZ)

    // Vertex stream: width * depth vertices × 8 floats.
    var vertices = []
    for (j in 0...depth) {
      var z = originZ + j * stepZ
      var jPrev = j == 0 ? 0 : j - 1
      var jNext = j == depth - 1 ? depth - 1 : j + 1
      for (i in 0...width) {
        var x = originX + i * stepX
        var h = heights[j * width + i] * amplitude

        // Central differences for the slope at (i, j); one-sided
        // at the boundary so we don't read out-of-bounds.
        var iPrev = i == 0 ? 0 : i - 1
        var iNext = i == width - 1 ? width - 1 : i + 1
        var dhdx = (heights[j * width + iNext] - heights[j * width + iPrev]) * amplitude * inv2sx
        var dhdz = (heights[jNext * width + i] - heights[jPrev * width + i]) * amplitude * inv2sz

        // Normal = (-dh/dx, 1, -dh/dz), normalised.
        var nx = -dhdx
        var ny = 1
        var nz = -dhdz
        var len = (nx * nx + ny * ny + nz * nz).sqrt
        if (len > 0) {
          nx = nx / len
          ny = ny / len
          nz = nz / len
        }

        vertices.add(x)
        vertices.add(h)
        vertices.add(z)
        vertices.add(nx)
        vertices.add(ny)
        vertices.add(nz)
        vertices.add(i * invW)
        vertices.add(j * invD)
      }
    }

    // Index stream: two triangles per cell, CCW winding so
    // `cullMode = back` keeps the top surface visible.
    var indices = []
    for (j in 0...(depth - 1)) {
      for (i in 0...(width - 1)) {
        var a = j * width + i
        var b = a + 1
        var c = a + width
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

  /// Convenience: allocate a `Float32Array`, fill it with
  /// `Noise.fillSimplex2`, then call `meshFromHeightmap`. The
  /// fastest path from "give me a procedural terrain" to a
  /// renderable Mesh.
  ///
  /// `opts` accepts every key `meshFromHeightmap` honours plus:
  ///
  ///   - `"width"`, `"depth"` (Num, required) — heightmap cells
  ///     per axis.
  ///   - `"noiseStepX"`, `"noiseStepZ"` (Num, default 0.05) —
  ///     spacing in *noise* space per heightmap step (separate
  ///     from world `stepX` / `stepZ`). Larger → smoother large
  ///     features, smaller → finer detail.
  ///   - `"noiseOriginX"`, `"noiseOriginZ"` (Num, default 0) —
  ///     starting noise sample; shift to seed neighbouring chunks
  ///     without seams.
  ///   - `"seed"` (Num, default 0).
  ///
  /// @param {Device} device
  /// @param {Map} opts
  /// @returns {Mesh}
  static fromNoise(device, opts) {
    var w = opts["width"]
    var d = opts["depth"]
    if (w == null || d == null) {
      Fiber.abort("Terrain.fromNoise: opts must include `width` and `depth`.")
    }
    var nsx = opts.containsKey("noiseStepX")   ? opts["noiseStepX"]   : 0.05
    var nsz = opts.containsKey("noiseStepZ")   ? opts["noiseStepZ"]   : 0.05
    var nox = opts.containsKey("noiseOriginX") ? opts["noiseOriginX"] : 0
    var noz = opts.containsKey("noiseOriginZ") ? opts["noiseOriginZ"] : 0
    var seed = opts.containsKey("seed")        ? opts["seed"]         : 0

    var heights = Float32Array.new(w * d)
    Noise.fillSimplex2(heights, nox, noz, nsx, nsz, w, d, seed)
    return Terrain.meshFromHeightmap(device, heights, w, d, opts)
  }

  /// Total vertex count for a `width × depth` grid. Helps size
  /// downstream buffers without instantiating the mesh.
  /// @param {Num} width
  /// @param {Num} depth
  /// @returns {Num}
  static vertexCount(width, depth) { width * depth }

  /// Total index count (two triangles per cell × 3 indices).
  /// @param {Num} width
  /// @param {Num} depth
  /// @returns {Num}
  static indexCount(width, depth) { 6 * (width - 1) * (depth - 1) }
}
