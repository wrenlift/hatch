// noise-worley — sample the new @hatch:noise functions at a few
// points + bulk-fill a 4×4 simplex heightmap. The WGSL companion
// is printed alongside so terrain / foliage / weather shaders can
// `Shader.compose([Noise.WGSL_COMPANION, ...])` and call
// `worley2(p, seed)` / `fbm2(p, seed, octaves, lac, pers)` from
// inside compute / vertex stages.

import "@hatch:noise" for Noise

System.print("Worley + ridged-fBM samples (seed=1337):")
for (i in 0...5) {
  var p = i * 0.7
  var w  = Noise.worley2(p, p + 1.5, 1337)
  var rf = Noise.ridgedFbm2(p, p + 1.5, 1337, 4, 2.0, 0.5)
  System.print("  p=%(p) → worley=%(w)  ridged_fbm=%(rf)")
}

// Bulk fill a 4×4 simplex heightmap so a terrain layer can drive
// `Terrain.meshFromHeightmap` from one foreign call instead of 16
// per-cell samples.
var heights = Float32Array.new(16)
Noise.fillSimplex2(heights, 0, 0, 0.5, 0.5, 4, 4, 42)
System.print("\nfillSimplex2 (4×4 row-major):")
for (j in 0...4) {
  var row = ""
  for (i in 0...4) {
    var v = heights[j * 4 + i]
    row = row + "  %(v.toString)"
  }
  System.print(row)
}

// 3D bulk fill for volumetrics — same shape, z outermost.
var vol = Float32Array.new(2 * 2 * 2)
Noise.fillSimplex3(vol, 0, 0, 0,  1, 1, 1,  2, 2, 2, 7)
System.print("\nfillSimplex3 (2×2×2):")
for (i in 0...8) System.print("  vol[%(i)] = %(vol[i])")

// The WGSL companion ships ready to compose into any compute or
// fragment shader that needs deterministic GPU-side noise.
var wgsl = Noise.WGSL_COMPANION
System.print("\nWGSL_COMPANION is %(wgsl.count) chars; exposes:")
for (name in ["value_noise2", "worley2", "fbm2", "ridged_fbm2"]) {
  var has = wgsl.contains("fn %(name)")
  System.print("  %(name): %(has ? "yes" : "MISSING")")
}
