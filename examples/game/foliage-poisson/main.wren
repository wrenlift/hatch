// foliage-poisson — generate a 32×32 fbm heightmap, then drop
// Poisson-disc samples that respect a slope window. Mimics the
// pipeline a procedural-world scatter pass walks each frame:
// noise → heightmap → slope-aware scatter → instance buffer.

import "@hatch:game"  for Foliage
import "@hatch:noise" for Noise

var W = 32
var H = 32
var heights = Float32Array.new(W * H)
Noise.fillSimplex2(heights, 0, 0, 0.08, 0.08, W, H, 1337)

// World-space extent the heightmap covers + scatter bounds. Same
// numbers a real Terrain.fromNoise mesh would consume.
var worldSize = [64, 64]
var bounds    = [0, 0, 64, 64]

// Grass cover — flat-ish slopes, dense.
var grass = Foliage.fromHeightmap({
  "bounds":    bounds,
  "r":         2.0,
  "heightmap": heights,
  "width":     W,
  "height":    H,
  "worldSize": worldSize,
  "slopeMin":  0,
  "slopeMax":  0.3,
  "seed":      42
})
System.print("Grass (flat slopes ≤ 0.3): %(grass["count"]) points")

// Rocks — steeper, sparser.
var rocks = Foliage.fromHeightmap({
  "bounds":    bounds,
  "r":         4.0,
  "heightmap": heights,
  "width":     W,
  "height":    H,
  "worldSize": worldSize,
  "slopeMin":  0.4,
  "slopeMax":  10,
  "seed":      77
})
System.print("Rocks (steep slopes > 0.4): %(rocks["count"]) points")

// Sanity scan: every accepted grass point should sit on a low-
// slope cell. Reuse Foliage's accepted output to pick a few and
// look up the slope in the heightmap.
System.print("\nFirst 5 grass points (x, z, height):")
for (i in 0...5) {
  if (i >= grass["count"]) break
  var x = grass["xs"][i]
  var z = grass["zs"][i]
  // Heightmap index lookup at (x, z).
  var ix = ((x / worldSize[0]) * (W - 1)).floor
  var iz = ((z / worldSize[1]) * (H - 1)).floor
  var h = heights[iz * W + ix]
  System.print("  (%(x), %(z), h=%(h))")
}
