//! procedural-world: Quaternius foliage scatter + instance-buffer
//! pipeline.
//!
//! Owns:
//!   - per-bucket primitive lists (Quaternius gltf docs)
//!   - per-bucket instance GPU buffers + Float32Array staging
//!   - scatter sites + per-site bucket assignment + ground Y
//!   - lifecycle flags (dirty / upload-dirty / baked snapshots)
//!
//! Knobs read every frame via `update(g, waterY)`:
//!   knobs["scatter"]   — base pre-filter rate (used in matrix bake)
//!   knobs["grassDens"] — per-bucket dropout for bucket 0 (grass)
//!   knobs["otherDens"] — per-bucket dropout for buckets 1..4
//!
//! Rescatter fires only when `_terrain.amp` slid past ε since the
//! last scatter (the height threshold depends on terrain Y). The
//! cheaper matrix rebake fires when any density knob crosses ε or
//! the amp slider changes within the rescatter band.

import "@hatch:game" for Foliage
import "@hatch:gltf" for Gltf

class FoliageScene {
  /// Load Quaternius models, allocate instance buffers, run the
  /// first scatter + matrix bake.
  /// @param {GameState}    g
  /// @param {AssetDatabase} db
  /// @param {Topography}   terrain
  /// @param {Map}          knobs       — `Knobs.make()` Map.
  /// @param {Num}          waterY      — current water plane Y.
  /// @param {Num}          seed        — scatter RNG seed.
  construct new(g, db, terrain, knobs, waterY, seed) {
    _terrain = terrain
    _knobs   = knobs
    _waterY  = waterY
    _seed    = seed

    // Quaternius nature-kit variants (CC0 1.0 / @Quaternius). Five
    // models keep the palette-bucket scatter: noise picks a bucket
    // per site, the bucket selects which set of primitives renders.
    // Trees ship with separate bark / leaves primitives, so each
    // bucket is a LIST — every bucket's instance buffer drives one
    // drawIndexed per primitive.
    _prims = []
    // Order: most → least dense. The scatter's bucket-selection
    // weights below give grass the lion's share, bushes a chunk in
    // the middle, and trees the long tail.
    var nature = [
      "nature-kit/Grass_Common_Short.gltf",     // 0 — densest cover
      "nature-kit/Bush_Common.gltf",             // 1 — common bush
      "nature-kit/Bush_Common_Flowers.gltf",     // 2 — flowering bush
      "nature-kit/CommonTree_3.gltf",            // 3 — small tree
      "nature-kit/CommonTree_1.gltf"             // 4 — large tree, sparsest
    ]
    // Per-bucket world-scale multiplier. Quaternius native units
    // don't match the ~150 m island — these factors land things in
    // the right physical-height ratio (~0.4 m grass, ~0.8 m bushes,
    // ~4-6 m trees).
    //                grass  bush_c bush_f tree_s tree_l
    _scales = [        0.45,  0.55,  0.55,  1.0,   1.5 ]
    // Per-bucket sway, split across primitives. Trees ship as
    // (bark, leaves) — bark must be stiff or the trunk visibly
    // buckles; leaves can sway gently. Grass + bushes are single-
    // primitive, so both indices read the same factor.
    //                 grass  bush_c bush_f tree_s tree_l
    var primaryS  = [  0.85,  0.45,  0.45,  0.02,  0.01 ]
    var leafS     = [  0.85,  0.45,  0.45,  0.18,  0.12 ]
    var bi = 0
    while (bi < nature.count) {
      var path = nature[bi]
      var doc = Gltf.fromAssetsDir(g.device, db, path)
      var prims = []
      var sourcePrims = doc.meshes[0].primitives
      var pIdx = 0
      while (pIdx < sourcePrims.count) {
        var prim = sourcePrims[pIdx]
        if (prim.mesh != null) {
          var swayV = primaryS[bi]
          if (pIdx > 0) swayV = leafS[bi]
          prim.material.sway = swayV
          prims.add(prim)
        }
        pIdx = pIdx + 1
      }
      if (prims.count == 0) Fiber.abort("procedural-world: no usable primitives in %(path)")
      _prims.add(prims)
      bi = bi + 1
    }

    // Capacities sized at ~1.5× the worst-case post-dropout count
    // observed across HUD slider ranges (grass + scatter at 1.0
    // peaks at ~60 k grass + ~10 k bush_c + ~2 k bush_f + ~800
    // tree_s + ~220 tree_l). Total ~110 k slots × 32 floats ×
    // 4 bytes = ~14 MB instance-buffer memory — down from the
    // 297 k × 128 B = 38 MB cap the earlier defaults reserved
    // for unrealistic slider extremes. Slider drag past these
    // visible budgets safely overflows: `rebuild_` drops sites
    // when `slot >= caps[bucket]` instead of panicking.
    _capacity     = [120000, 16000, 4000, 1500, 500]
    _counts       = [0, 0, 0, 0, 0]
    _bufs         = []
    _floats       = []
    _dirty        = true
    _uploadDirty  = true
    _bakedAmpScale = 1.0
    var i = 0
    while (i < _prims.count) {
      var cap = _capacity[i]
      _bufs.add(g.device.createBuffer({
        "size":  cap * 32 * 4,
        "usage": ["storage", "copy-dst"],
        "label": "foliage-instances-%(i)"
      }))
      _floats.add(Float32Array.new(cap * 32))
      i = i + 1
    }

    _density           = _knobs["scatter"]["v"]
    _bakedGrassDens    = _knobs["grassDens"]["v"]
    _bakedOtherDens    = _knobs["otherDens"]["v"]
    _bakedScatterDens  = _knobs["scatter"]["v"]
    rescatter_()
  }

  // Diagnostic accessors used by the HUD readout.
  counts      { _counts }
  paletteHist { _paletteHist }

  /// Tell the scene the current water Y for the NEXT rescatter.
  /// Doesn't fire one — the water slider is allowed to slide
  /// without dropping all the trees underwater (looks ugly mid-
  /// drag); a rescatter only fires when the terrain amp also
  /// crosses ε.
  /// @param {Num} y
  setWaterY(y) { _waterY = y }

  /// Per-frame logic. Decides whether to rescatter or rebuild
  /// matrices based on knob deltas + terrain amp drift.
  /// @param {Num} ampScale. `terrain.amp / terrain.ampBase`.
  update(ampScale) {
    if ((_terrain.amp - _scatterAmp).abs > 0.5) {
      rescatter_()
      rebuild_(ampScale)
      return
    }
    var needsRebuild = _dirty ||
      (ampScale - _bakedAmpScale).abs > 0.001 ||
      (_knobs["grassDens"]["v"] - _bakedGrassDens).abs > 0.005 ||
      (_knobs["otherDens"]["v"] - _bakedOtherDens).abs > 0.005 ||
      (_knobs["scatter"]["v"]   - _bakedScatterDens).abs > 0.005
    if (needsRebuild) rebuild_(ampScale)
  }

  /// Upload any dirty bucket buffers and issue one
  /// `drawMeshInstanced` per primitive per non-empty bucket.
  /// Called both from the main pass and from the planar-reflection
  /// pass — same data, two passes.
  /// @param {Renderer3D} renderer
  draw(renderer) {
    var bi = 0
    var bn = _floats.count
    while (bi < bn) {
      var n = _counts[bi]
      if (n > 0) {
        if (_uploadDirty) {
          _bufs[bi].writeFloatsN(0, _floats[bi], n * 32)
        }
        var prims = _prims[bi]
        var pi = 0
        var pn = prims.count
        while (pi < pn) {
          var prim = prims[pi]
          renderer.drawMeshInstanced(prim.mesh, prim.material, _bufs[bi], n)
          pi = pi + 1
        }
      }
      bi = bi + 1
    }
    if (_uploadDirty) _uploadDirty = false
  }

  /// Release every per-bucket instance buffer.
  destroy {
    var i = 0
    while (i < _bufs.count) {
      _bufs[i].destroy
      i = i + 1
    }
  }

  // ── Internals ───────────────────────────────────────────────────

  rescatter_() {
    var half = _terrain.size / 2
    var seedLocal       = _seed
    var terrainAmpLocal = _terrain.amp
    var stepLocal       = _terrain.step
    var heightsLocal    = _terrain.heights
    var colsLocal       = _terrain.cols
    var rowsLocal       = _terrain.rows
    var originXLocal    = -half
    var originZLocal    = -half
    var waterYLocal     = _waterY
    // Inline heightAt closure — bilinearly samples the heightmap
    // at world (x, z). Captures `stepLocal / heights / cols / rows`
    // by ref so the hot scatter loop doesn't pay field-access cost
    // per sample.
    var heightAt = Fn.new {|x, z|
      var fx = (x - originXLocal) / stepLocal
      var fz = (z - originZLocal) / stepLocal
      var i0 = fx.floor
      var j0 = fz.floor
      var tx = fx - i0
      var tz = fz - j0
      if (i0 < 0) {
        i0 = 0
        tx = 0
      }
      if (i0 >= colsLocal - 1) {
        i0 = colsLocal - 2
        tx = 1
      }
      if (j0 < 0) {
        j0 = 0
        tz = 0
      }
      if (j0 >= rowsLocal - 1) {
        j0 = rowsLocal - 2
        tz = 1
      }
      var h00 = heightsLocal[j0 * colsLocal + i0]
      var h10 = heightsLocal[j0 * colsLocal + i0 + 1]
      var h01 = heightsLocal[(j0 + 1) * colsLocal + i0]
      var h11 = heightsLocal[(j0 + 1) * colsLocal + i0 + 1]
      var h0  = h00 + (h10 - h00) * tx
      var h1  = h01 + (h11 - h01) * tx
      return (h0 + (h1 - h0) * tz) * terrainAmpLocal
    }
    // Slope estimator. Gradient magnitude — high on cliffs, near-
    // zero on plains. Foliage prefers plains.
    var slopeAt = Fn.new {|x, z|
      var s = stepLocal
      var h  = heightAt.call(x, z)
      var hx = heightAt.call(x + s, z)
      var hz = heightAt.call(x, z + s)
      var dx = hx - h
      var dz = hz - h
      return (dx * dx + dz * dz).sqrt
    }
    var sites = Foliage.scatter({
      "bounds":    [-half * 0.95, -half * 0.95, half * 0.95, half * 0.95],
      // Tight spacing for a dense grass field — the bucket weight
      // table below thins trees back down so they stay rare even
      // at this resolution.
      "spacing":   0.20,
      "jitter":    0.55,
      "seed":      seedLocal + 9999,
      "threshold": Fn.new {|x, z|
        // Site-validity only — submerged, summit, or cliff sites
        // get culled here. Density is applied per-class downstream
        // in `rebuild_` so the grass slider and the scatter slider
        // thin grass and non-grass independently.
        var y = heightAt.call(x, z)
        if (y < waterYLocal + 0.3) return 0
        if (y > terrainAmpLocal * 0.85) return 0
        if (slopeAt.call(x, z) > 1.2) return 0
        return 1.0
      }
    })
    _sites = sites
    var count = sites["count"]
    _ys       = Float32Array.new(count)
    _palettes = []
    var si = 0
    while (si < count) {
      var x = sites["xs"][si]
      var z = sites["zs"][si]
      _ys[si] = heightAt.call(x, z)
      // Per-site uniform-[0,1] hash. OpenSimplex output is narrowly
      // bounded and biases heavily after rescale-and-clamp; a plain
      // sine-hash gives a flat distribution so the bucket thresholds
      // correspond to their intended percentages.
      var hashV = (x * 12.9898 + z * 78.233 + seedLocal * 0.31).sin * 43758.5453
      var p = hashV - hashV.floor
      if (p < 0) p = p + 1
      var slot = 0
      if (p >= 0.80)  slot = 1   // bush common      (15%)
      if (p >= 0.95)  slot = 2   // bush flowers     (3%)
      if (p >= 0.98)  slot = 3   // small tree       (1.5%)
      if (p >= 0.995) slot = 4   // large tree       (0.5%)
      _palettes.add(slot)
      si = si + 1
    }
    _count       = count
    _dirty       = true
    _scatterAmp  = _terrain.amp
    // Diagnostic histogram of how the SCATTER assigned buckets,
    // independent of the per-class dropout in rebuild.
    _paletteHist = [0, 0, 0, 0, 0]
    var hi = 0
    while (hi < _palettes.count) {
      var b = _palettes[hi]
      _paletteHist[b] = _paletteHist[b] + 1
      hi = hi + 1
    }
  }

  // Bake every foliage instance's TRS matrix (translation × scale)
  // into the per-bucket Float32Array — once per scatter, plus once
  // whenever the terrain amp slider crosses a small delta. The
  // matrices match what `Renderer3D.writeInstance` produces
  // (column-major model + normalMat, 32 floats each).
  rebuild_(ampScale) {
    var ci = 0
    var cn = _counts.count
    while (ci < cn) {
      _counts[ci] = 0
      ci = ci + 1
    }
    var xs       = _sites["xs"]
    var zs       = _sites["zs"]
    var ys       = _ys
    var palettes = _palettes
    var scales   = _scales
    var caps     = _capacity
    var buckets  = _floats
    var counts   = _counts
    var grassDensity   = _knobs["grassDens"]["v"]
    var otherDensity   = _knobs["otherDens"]["v"]
    var scatterDensity = _knobs["scatter"]["v"]
    // Pre-multiplied non-grass keep rate. Avoids repeated map
    // indexing in the hot loop.
    var nonGrassKeep = otherDensity * scatterDensity
    var seedLocal    = _seed
    var i = 0
    while (i < _count) {
      var bucket = palettes[i]
      // Per-class dropout via a uniform-[0,1] hash. Grass is gated
      // only by the grass slider; non-grass by foliage × scatter.
      var dh = (xs[i] * 9.7531 + zs[i] * 23.197 + seedLocal * 0.137).sin * 87412.3
      var dropoutSample = dh - dh.floor
      if (dropoutSample < 0) dropoutSample = dropoutSample + 1
      var keep = nonGrassKeep
      if (bucket == 0) keep = grassDensity
      if (dropoutSample > keep) {
        i = i + 1
        continue
      }
      var slot = counts[bucket]
      if (slot >= caps[bucket]) {
        i = i + 1
        continue
      }
      var s = scales[bucket]
      var arr = buckets[bucket]
      var off = slot * 32
      var x = xs[i]
      var y = ys[i] * ampScale
      var z = zs[i]
      // Column-major model matrix (4 rows × 4 cols) for uniform
      // scale + translation: cols 0..2 are scaled basis vectors,
      // col 3 is the world position.
      arr[off]      = s
      arr[off + 1]  = 0
      arr[off + 2]  = 0
      arr[off + 3]  = 0
      arr[off + 4]  = 0
      arr[off + 5]  = s
      arr[off + 6]  = 0
      arr[off + 7]  = 0
      arr[off + 8]  = 0
      arr[off + 9]  = 0
      arr[off + 10] = s
      arr[off + 11] = 0
      arr[off + 12] = x
      arr[off + 13] = y
      arr[off + 14] = z
      arr[off + 15] = 1
      // Normal matrix — same as model for uniform scale; shader
      // re-normalises so the `s` magnitude is harmless.
      arr[off + 16] = s
      arr[off + 17] = 0
      arr[off + 18] = 0
      arr[off + 19] = 0
      arr[off + 20] = 0
      arr[off + 21] = s
      arr[off + 22] = 0
      arr[off + 23] = 0
      arr[off + 24] = 0
      arr[off + 25] = 0
      arr[off + 26] = s
      arr[off + 27] = 0
      arr[off + 28] = x
      arr[off + 29] = y
      arr[off + 30] = z
      arr[off + 31] = 1
      counts[bucket] = slot + 1
      i = i + 1
    }
    _dirty       = false
    _uploadDirty = true
    _bakedAmpScale    = ampScale
    _bakedGrassDens   = grassDensity
    _bakedOtherDens   = otherDensity
    _bakedScatterDens = _knobs["scatter"]["v"]
  }
}
