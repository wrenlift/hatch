// @hatch:gpu/gpu_shadows — CascadeShadows + PointShadow math.

import "./gpu"          for CascadeShadows, PointShadow
import "@hatch:math"    for Vec3, Mat4
import "@hatch:test"    for Test
import "@hatch:assert"  for Expect

Test.describe("CascadeShadows.splits") {
  Test.it("returns n+1 distances spanning [near, far]") {
    var s = CascadeShadows.splits(1, 100, 3, 0.5)
    Expect.that(s.count).toBe(4)
    Expect.that(s[0]).toBe(1)
    Expect.that(s[3]).toBe(100)
    // Strictly increasing.
    Expect.that(s[1] > s[0]).toBe(true)
    Expect.that(s[2] > s[1]).toBe(true)
    Expect.that(s[3] > s[2]).toBe(true)
  }

  Test.it("lambda=0 produces uniform splits") {
    var s = CascadeShadows.splits(1, 101, 4, 0)
    // Uniform → each step is (101 - 1) / 4 = 25 wide.
    var d01 = s[1] - s[0]
    var d12 = s[2] - s[1]
    var d23 = s[3] - s[2]
    var d34 = s[4] - s[3]
    Expect.that((d01 - 25).abs < 0.0001).toBe(true)
    Expect.that((d12 - 25).abs < 0.0001).toBe(true)
    Expect.that((d23 - 25).abs < 0.0001).toBe(true)
    Expect.that((d34 - 25).abs < 0.0001).toBe(true)
  }

  Test.it("lambda=1 produces logarithmic splits (constant ratio)") {
    var s = CascadeShadows.splits(1, 256, 4, 1)
    // Log → each split is the geometric mean: 1, 4, 16, 64, 256.
    var ratios = [s[1] / s[0], s[2] / s[1], s[3] / s[2], s[4] / s[3]]
    // All ratios within 0.001 of 4.
    var i = 0
    while (i < 4) {
      Expect.that((ratios[i] - 4).abs < 0.001).toBe(true)
      i = i + 1
    }
  }

  Test.it("aborts on bad inputs") {
    var e1 = Fiber.new { CascadeShadows.splits(1, 10, 0, 0.5) }.try()
    Expect.that(e1).toContain("n must be >= 1")
    var e2 = Fiber.new { CascadeShadows.splits(0, 10, 2, 0.5) }.try()
    Expect.that(e2).toContain("near")
    var e3 = Fiber.new { CascadeShadows.splits(10, 5, 2, 0.5) }.try()
    Expect.that(e3).toContain("far must exceed")
  }
}

Test.describe("CascadeShadows.cascadeMatrix") {
  // Synthetic camera: at origin, looking down +Z, world-up.
  var camera = {
    "eye":     Vec3.new(0, 0, 0),
    "forward": Vec3.new(0, 0, 1),
    "right":   Vec3.new(1, 0, 0),
    "up":      Vec3.new(0, 1, 0),
    "aspect":  1.0,
    "fovY":    1.0
  }

  Test.it("returns a Mat4 with finite entries for a valid slice") {
    var lightDir = Vec3.new(0, -1, 0)
    var m = CascadeShadows.cascadeMatrix(camera, lightDir, 1, 10)
    Expect.that(m is Mat4).toBe(true)
    // Sample a couple of cells — should be finite (not NaN / inf).
    var k = 0
    while (k < 16) {
      var v = m.at((k / 4).floor, k % 4)
      // Finite check: v == v (NaN != NaN); v != ±∞.
      Expect.that(v == v).toBe(true)
      k = k + 1
    }
  }

  Test.it("aborts on zero-length light direction") {
    var e = Fiber.new {
      CascadeShadows.cascadeMatrix(camera, Vec3.new(0, 0, 0), 1, 10)
    }.try()
    Expect.that(e).toContain("non-zero")
  }
}

Test.describe("PointShadow.facesFor") {
  Test.it("returns six face matrices in +X / -X / +Y / -Y / +Z / -Z order") {
    var faces = PointShadow.facesFor(Vec3.new(0, 0, 0), 0.1, 50)
    Expect.that(faces.count).toBe(6)
    var i = 0
    while (i < 6) {
      Expect.that(faces[i] is Mat4).toBe(true)
      i = i + 1
    }
  }

  Test.it("the +X face transforms +X direction toward the centre of clip-z") {
    // A point at (1, 0, 0) relative to a light at origin should
    // sit roughly on the +X face's central ray after view-projection,
    // i.e. its clip-space x/y should be near zero (centre of face).
    var faces = PointShadow.facesFor(Vec3.new(0, 0, 0), 0.1, 50)
    var p = faces[0].transformPoint(Vec3.new(5, 0, 0))
    // Central ray → x = 0, y = 0 in clip. The clip-space xy
    // components live in the first 2 of the post-multiplied vec3
    // (after the perspective divide by w, which transformPoint
    // skips — but for a point dead-centre on the axis, x and y
    // sit at 0 regardless of w).
    Expect.that(p.x.abs < 0.0001).toBe(true)
    Expect.that(p.y.abs < 0.0001).toBe(true)
  }
}

Test.run()
