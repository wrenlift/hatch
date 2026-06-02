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

  /// Poisson-disc scatter — points uniformly spaced by at least
  /// `r` apart, no clustering. The canonical "natural-looking"
  /// foliage pattern: no two grass blades closer than blade
  /// thickness, no two trees inside their canopy radius, etc.
  /// Implements Bridson (2007): maintain an active list, sample
  /// new candidates in the (r, 2r) annulus around active points,
  /// reject candidates within `r` of any accepted point via a
  /// uniform-grid hash.
  ///
  /// | Option         | Type   | Default | Notes                                             |
  /// |----------------|--------|---------|---------------------------------------------------|
  /// | `bounds`       | List   | required | `[minX, minZ, maxX, maxZ]` axis-aligned XZ box.  |
  /// | `r`            | Num    | required | Minimum distance between accepted points.        |
  /// | `seed`         | Num    | `0`     | LCG seed.                                         |
  /// | `attempts`     | Num    | `30`    | Per-active-point candidate budget (Bridson's `k`). |
  /// | `threshold`    | `Fn`   | `null`  | `Fn.new {\|x, z\| weight}` returning 0..1 — extra acceptance probability check (e.g. for foliage density falloff). Pre-distance, post-bounds. |
  ///
  /// Returns the same `{xs, zs, count}` Map shape as `scatter`,
  /// suitable for direct feed into instance-buffer packing.
  ///
  /// @param {Map} opts
  /// @returns {Map}
  static poisson(opts) {
    var bounds = opts["bounds"]
    if (bounds == null || bounds.count < 4) {
      Fiber.abort("Foliage.poisson: opts.bounds must be [minX, minZ, maxX, maxZ].")
    }
    var minX = bounds[0]
    var minZ = bounds[1]
    var maxX = bounds[2]
    var maxZ = bounds[3]
    if (maxX <= minX || maxZ <= minZ) {
      Fiber.abort("Foliage.poisson: bounds max must exceed min on both axes.")
    }
    var r = opts["r"]
    if (r == null) Fiber.abort("Foliage.poisson: opts.r is required (minimum spacing).")
    if (r <= 0) Fiber.abort("Foliage.poisson: r must be > 0.")
    var seed       = opts.containsKey("seed") ? opts["seed"] : 0
    var attempts   = opts.containsKey("attempts") ? opts["attempts"] : 30
    var threshold  = opts.containsKey("threshold") ? opts["threshold"] : null

    var width  = maxX - minX
    var depth  = maxZ - minZ
    // Bridson's grid: cell size = r / sqrt(2) so each cell holds
    // at most one accepted point. Lookups scan the 5×5 grid block
    // around a candidate (range r covered).
    var cellSize = r / 1.41421356237
    var gridW = (width / cellSize).ceil + 1
    var gridH = (depth / cellSize).ceil + 1
    var grid  = List.filled(gridW * gridH, -1)  // index into xs/zs, -1 = empty

    // Worst-case sizing: area / (π * (r/2)²). The actual count is
    // typically lower; we let the caller see the trailing zeros.
    var capacity = ((width * depth) / (r * r * 0.7)).floor + 32
    var xs = Float32Array.new(capacity)
    var zs = Float32Array.new(capacity)
    var count = 0

    // LCG — same family as `scatter` for cross-method seed parity.
    var state = seed
    if (state < 0) state = state * -1
    state = state + 12345

    var nextRand = Fn.new {
      state = (state * 1664525 + 1013904223) % 4294967296
      return state / 4294967296
    }

    var active = []  // indices into xs/zs

    var cellOf = Fn.new {|x, z|
      var cx = ((x - minX) / cellSize).floor
      var cz = ((z - minZ) / cellSize).floor
      if (cx < 0) cx = 0
      if (cz < 0) cz = 0
      if (cx >= gridW) cx = gridW - 1
      if (cz >= gridH) cz = gridH - 1
      return [cx, cz]
    }

    var fits = Fn.new {|x, z|
      var c = cellOf.call(x, z)
      var dy = -2
      while (dy <= 2) {
        var dx = -2
        while (dx <= 2) {
          var nx = c[0] + dx
          var nz = c[1] + dy
          if (nx >= 0 && nx < gridW && nz >= 0 && nz < gridH) {
            var existing = grid[nz * gridW + nx]
            if (existing >= 0) {
              var ex = xs[existing]
              var ez = zs[existing]
              var ddx = x - ex
              var ddz = z - ez
              if (ddx * ddx + ddz * ddz < r * r) return false
            }
          }
          dx = dx + 1
        }
        dy = dy + 1
      }
      return true
    }

    var emit = Fn.new {|x, z|
      if (count >= capacity) return false
      var c = cellOf.call(x, z)
      xs[count] = x
      zs[count] = z
      grid[c[1] * gridW + c[0]] = count
      active.add(count)
      count = count + 1
      return true
    }

    // Seed: drop one point near the centre. Density-threshold
    // callers can pre-empt this if they want a darker start.
    var sx = minX + width * 0.5
    var sz = minZ + depth * 0.5
    if (threshold == null || nextRand.call() < threshold.call(sx, sz)) {
      emit.call(sx, sz)
    } else {
      // Threshold rejected the seed — keep trying random ones for
      // a small budget before giving up. Otherwise dense-then-
      // sparse maps degenerate to empty output.
      var tries = 0
      while (tries < 50 && count == 0) {
        var rx = minX + nextRand.call() * width
        var rz = minZ + nextRand.call() * depth
        if (nextRand.call() < threshold.call(rx, rz)) emit.call(rx, rz)
        tries = tries + 1
      }
    }

    while (active.count > 0) {
      // Pick a random active point.
      var ai = (nextRand.call() * active.count).floor
      if (ai >= active.count) ai = active.count - 1
      var pi = active[ai]
      var px = xs[pi]
      var pz = zs[pi]
      var found = false
      var attempt = 0
      while (attempt < attempts && !found) {
        // Sample uniformly from the annulus r..2r around (px, pz).
        var angle = nextRand.call() * 6.28318530718
        var dist  = r * (1 + nextRand.call())
        var nx = px + dist * angle.cos
        var nz = pz + dist * angle.sin
        attempt = attempt + 1
        if (nx < minX || nx >= maxX || nz < minZ || nz >= maxZ) continue
        if (!fits.call(nx, nz)) continue
        if (threshold != null && nextRand.call() >= threshold.call(nx, nz)) continue
        if (!emit.call(nx, nz)) {
          // Output buffer full — stop accepting; the partial
          // tessellation is still usable.
          return { "xs": xs, "zs": zs, "count": count }
        }
        found = true
      }
      if (!found) {
        // Exhausted this seed's neighbourhood — retire it.
        active.removeAt(ai)
      }
    }

    return { "xs": xs, "zs": zs, "count": count }
  }

  /// Scatter + heightmap-slope rejection. Drops candidate points
  /// where the underlying terrain slope falls outside
  /// `[slopeMin, slopeMax]`. Slope is approximated as
  /// `|dH/dx| + |dH/dz|` from neighbour heightmap samples.
  ///
  /// Use for grass-on-grass / rocks-on-rocks scatter: pass a
  /// noise-derived heightmap, the world-space terrain extent, and
  /// a slope window — e.g. grass on flats (slope < 0.4), rocks on
  /// cliffs (slope > 0.6).
  ///
  /// | Option       | Type           | Default | Notes                                                          |
  /// |--------------|----------------|---------|----------------------------------------------------------------|
  /// | `bounds`     | List           | required | `[minX, minZ, maxX, maxZ]` — world-space scatter area.        |
  /// | `r`          | Num            | required | Poisson minimum spacing.                                       |
  /// | `heightmap`  | Float32Array   | required | width × height row-major altitudes.                            |
  /// | `width`      | Num            | required | Heightmap column count.                                        |
  /// | `height`     | Num            | required | Heightmap row count.                                           |
  /// | `worldSize`  | List<Num>      | required | `[wx, wz]` — world-space extent the heightmap covers (origin at `bounds` min). |
  /// | `slopeMin`   | Num            | `0`     | Reject samples below this slope.                               |
  /// | `slopeMax`   | Num            | `1e30`  | Reject samples above this slope.                               |
  /// | `seed`       | Num            | `0`     | LCG seed.                                                      |
  /// | `attempts`   | Num            | `30`    | Bridson `k`.                                                   |
  ///
  /// @param {Map} opts
  /// @returns {Map}
  static fromHeightmap(opts) {
    var bounds   = opts["bounds"]
    var hm       = opts["heightmap"]
    var hmW      = opts["width"]
    var hmH      = opts["height"]
    var worldSize = opts["worldSize"]
    if (bounds == null || hm == null || hmW == null || hmH == null || worldSize == null) {
      Fiber.abort("Foliage.fromHeightmap: bounds, heightmap, width, height, worldSize are required.")
    }
    var slopeMin = opts.containsKey("slopeMin") ? opts["slopeMin"] : 0
    var slopeMax = opts.containsKey("slopeMax") ? opts["slopeMax"] : 1e30
    var wx = worldSize[0]
    var wz = worldSize[1]

    var slopeOf = Fn.new {|x, z|
      // Map world (x, z) → heightmap (u, v) → texel indices.
      var u = (x - bounds[0]) / wx
      var v = (z - bounds[1]) / wz
      if (u < 0) u = 0
      if (v < 0) v = 0
      if (u > 1) u = 1
      if (v > 1) v = 1
      var i = (u * (hmW - 1)).floor
      var j = (v * (hmH - 1)).floor
      // Forward differences clamped at the right / bottom edge.
      var iNext = i + 1
      if (iNext >= hmW) iNext = i
      var jNext = j + 1
      if (jNext >= hmH) jNext = j
      var hc = hm[j * hmW + i]
      var hx = hm[j * hmW + iNext]
      var hz = hm[jNext * hmW + i]
      var dx = hx - hc
      var dz = hz - hc
      if (dx < 0) dx = -dx
      if (dz < 0) dz = -dz
      return dx + dz
    }

    return Foliage.poisson({
      "bounds":   bounds,
      "r":        opts["r"],
      "seed":     opts.containsKey("seed") ? opts["seed"] : 0,
      "attempts": opts.containsKey("attempts") ? opts["attempts"] : 30,
      "threshold": Fn.new {|x, z|
        var s = slopeOf.call(x, z)
        if (s < slopeMin) return 0
        if (s > slopeMax) return 0
        return 1
      }
    })
  }
}
