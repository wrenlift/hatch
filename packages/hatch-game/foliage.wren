// @hatch:game/foliage — instanced scatter for grass, trees, rocks,
// asteroids: anything you place hundreds-of-thousands of across a
// world surface. Generates 2D placement points only; the caller
// pulls a y-value from the terrain (or sets it explicitly) and
// feeds the (x, y, z) triples into a ClusterGrid / Octree for
// per-frame cull + LOD.
//
// The scatter strategy is jittered grid: each cell of a regular
// grid emits one candidate at the cell centre plus a deterministic
// random offset, optionally filtered against a density threshold
// (sample a `@hatch:noise` field, a biome mask, anything that maps
// (x, z) → 0..1).
//
// Output is a Map with parallel `Float32Array` columns plus a live
// `count`; iterating by index lets the caller pack into instance
// buffers, Octree inserts, or terrain placement loops without
// per-point heap allocation.
//
//   var sites = Foliage.scatter({
//     "bounds":  [-128, -128, 128, 128],
//     "spacing": 1.0,
//     "jitter":  0.4,
//     "seed":    1337,
//     "threshold": Fn.new {|x, z| Noise.simplex2(x * 0.02, z * 0.02, 7) * 0.5 + 0.5 }
//   })
//   for (i in 0...sites["count"]) {
//     var x = sites["xs"][i]
//     var z = sites["zs"][i]
//     var y = terrain.heightAt(x, z)
//     grid.insert(i, x, y, z)
//   }

/// Static namespace for foliage placement.
class Foliage {
  /// Jittered-grid scatter over a 2D bounds rectangle.
  ///
  /// `opts` keys:
  ///   - `"bounds"` (List, required) — `[minX, minZ, maxX, maxZ]`.
  ///   - `"spacing"` (Num, default 1) — distance between grid cells.
  ///     Each cell contributes at most one candidate.
  ///   - `"jitter"` (Num, default 0.5) — random offset within
  ///     [-jitter, +jitter] × spacing per axis. 0 disables jitter
  ///     (perfectly regular grid); >1 lets candidates cross cell
  ///     boundaries.
  ///   - `"seed"` (Num, default 0) — drives the LCG. Same seed +
  ///     same opts = identical placements across runs.
  ///   - `"threshold"` (Fn, optional) — called as `cb(x, z)`,
  ///     returns a number in `[0, 1]`. The candidate is accepted
  ///     when an LCG draw rolls *below* the returned value, so a
  ///     density field smoothly modulates coverage.
  ///
  /// Returns a Map:
  ///   `{ "xs": Float32Array, "zs": Float32Array, "count": Num }`.
  /// Both arrays are sized to the grid's total cells (the
  /// upper bound), with the first `count` slots holding live
  /// values; the tail is left at zero.
  ///
  /// @param {Map} opts
  /// @returns {Map}
  static scatter(opts) {
    var bounds = opts["bounds"]
    if (bounds == null || bounds.count < 4) {
      Fiber.abort("Foliage.scatter: opts.bounds must be [minX, minZ, maxX, maxZ].")
    }
    var minX = bounds[0]
    var minZ = bounds[1]
    var maxX = bounds[2]
    var maxZ = bounds[3]
    if (maxX <= minX || maxZ <= minZ) {
      Fiber.abort("Foliage.scatter: bounds max must exceed min on both axes.")
    }
    var spacing   = opts.containsKey("spacing")   ? opts["spacing"]   : 1
    var jitter    = opts.containsKey("jitter")    ? opts["jitter"]    : 0.5
    var seed      = opts.containsKey("seed")      ? opts["seed"]      : 0
    var threshold = opts.containsKey("threshold") ? opts["threshold"] : null
    if (spacing <= 0) Fiber.abort("Foliage.scatter: spacing must be > 0.")

    var nx = ((maxX - minX) / spacing).floor
    var nz = ((maxZ - minZ) / spacing).floor
    if (nx < 1 || nz < 1) {
      Fiber.abort("Foliage.scatter: bounds + spacing yield zero cells.")
    }
    var total = nx * nz
    var xs = Float32Array.new(total)
    var zs = Float32Array.new(total)

    // LCG (Numerical Recipes constants). Each call returns a u32
    // in [0, 2^32); divide by 2^32 for a normalised draw. Fast,
    // deterministic, allocation-free.
    var state = seed
    if (state < 0) state = state * -1
    state = state + 12345     // shift away from 0 so the first draw isn't pinned

    var count = 0
    for (j in 0...nz) {
      var cellZ = minZ + (j + 0.5) * spacing
      for (i in 0...nx) {
        var cellX = minX + (i + 0.5) * spacing

        state = (state * 1664525 + 1013904223) % 4294967296
        var jx = ((state / 4294967296) - 0.5) * 2 * jitter * spacing
        state = (state * 1664525 + 1013904223) % 4294967296
        var jz = ((state / 4294967296) - 0.5) * 2 * jitter * spacing
        var x = cellX + jx
        var z = cellZ + jz

        if (threshold != null) {
          state = (state * 1664525 + 1013904223) % 4294967296
          var roll = state / 4294967296
          if (roll >= threshold.call(x, z)) continue
        }

        xs[count] = x
        zs[count] = z
        count = count + 1
      }
    }

    return {
      "xs":    xs,
      "zs":    zs,
      "count": count
    }
  }
}
