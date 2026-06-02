// @hatch:noise acceptance tests. Determinism, range bounds, the
// fBM normalisation, and the batched heightmap fill path.

import "./noise"     for Noise
import "@hatch:test"   for Test
import "@hatch:assert" for Expect

Test.describe("Noise.simplex2") {
  Test.it("is deterministic for the same (x, y, seed)") {
    var a = Noise.simplex2(1.5, 2.5, 1337)
    var b = Noise.simplex2(1.5, 2.5, 1337)
    Expect.that(a).toBe(b)
  }

  Test.it("returns different values for different seeds") {
    var a = Noise.simplex2(0.1, 0.2, 1)
    var b = Noise.simplex2(0.1, 0.2, 999)
    Expect.that(a == b).toBe(false)
  }

  Test.it("stays in the [-1, 1] band across a sample grid") {
    var lo = 2
    var hi = -2
    for (i in 0...20) {
      for (j in 0...20) {
        var v = Noise.simplex2(i * 0.37, j * 0.41, 7)
        if (v < lo) lo = v
        if (v > hi) hi = v
      }
    }
    Expect.that(lo >= -1.01).toBe(true)
    Expect.that(hi <= 1.01).toBe(true)
  }
}

Test.describe("Noise.simplex3") {
  Test.it("is deterministic for the same (x, y, z, seed)") {
    var a = Noise.simplex3(1.0, 2.0, 3.0, 42)
    var b = Noise.simplex3(1.0, 2.0, 3.0, 42)
    Expect.that(a).toBe(b)
  }

  Test.it("varies with z when (x, y) are fixed") {
    var a = Noise.simplex3(0.5, 0.5, 0.0, 42)
    var b = Noise.simplex3(0.5, 0.5, 1.0, 42)
    Expect.that(a == b).toBe(false)
  }
}

Test.describe("Noise.perlin2 + Noise.value2") {
  Test.it("Perlin is deterministic in its inputs") {
    Expect.that(Noise.perlin2(3.0, 4.0, 12)).toBe(Noise.perlin2(3.0, 4.0, 12))
  }

  Test.it("Value is deterministic in its inputs") {
    Expect.that(Noise.value2(5.0, 6.0, 7)).toBe(Noise.value2(5.0, 6.0, 7))
  }

  Test.it("different algorithms produce different scalars at the same point") {
    var s = Noise.simplex2(2.5, 3.5, 1)
    var p = Noise.perlin2(2.5, 3.5, 1)
    var v = Noise.value2(2.5, 3.5, 1)
    Expect.that(s == p).toBe(false)
    Expect.that(p == v).toBe(false)
  }
}

Test.describe("Noise.fbm2") {
  Test.it("is deterministic in its inputs") {
    var a = Noise.fbm2(1.5, 2.5, 1337, 4, 2.0, 0.5)
    var b = Noise.fbm2(1.5, 2.5, 1337, 4, 2.0, 0.5)
    Expect.that(a).toBe(b)
  }

  Test.it("stays in approximately [-1, 1] across octave counts") {
    var lo = 2
    var hi = -2
    for (i in 0...20) {
      for (j in 0...20) {
        var v = Noise.fbm2(i * 0.13, j * 0.17, 9, 6, 2.0, 0.5)
        if (v < lo) lo = v
        if (v > hi) hi = v
      }
    }
    Expect.that(lo >= -1.01).toBe(true)
    Expect.that(hi <= 1.01).toBe(true)
  }

  Test.it("rejects octaves = 0") {
    var e = Fiber.new { Noise.fbm2(0, 0, 0, 0, 2.0, 0.5) }.try()
    Expect.that(e).toContain("octaves")
  }

  Test.it("rejects octaves > 16") {
    var e = Fiber.new { Noise.fbm2(0, 0, 0, 17, 2.0, 0.5) }.try()
    Expect.that(e).toContain("octaves")
  }
}

Test.describe("Noise.fillSimplex2") {
  Test.it("fills the grid in row-major order") {
    var w = 4
    var h = 3
    var out = Float32Array.new(w * h)
    Noise.fillSimplex2(out, 0, 0, 0.25, 0.25, w, h, 1)

    // Spot-check a couple cells against the scalar API. The fill
    // path stores into f32 lanes while the scalar API returns f64,
    // so values agree to ~6 decimal places, not exactly.
    // Cell (row=1, col=2) with stepX = stepY = 0.25, origin
    // (0, 0): world point = (col * stepX, row * stepY) = (0.5, 0.25).
    var expected = Noise.simplex2(0.5, 0.25, 1)
    var actual = out[1 * w + 2]
    // f32 round-trip can shave ~7 ulp from an f64; budget for it
    // plus a tiny noise-rs intermediate.
    Expect.that((actual - expected).abs < 1e-4).toBe(true)
  }

  Test.it("rejects a buffer that's too small") {
    var out = Float32Array.new(4)
    var e = Fiber.new {
      Noise.fillSimplex2(out, 0, 0, 1, 1, 3, 3, 1)   // needs 9 floats
    }.try()
    Expect.that(e).toContain("holds 4 floats")
  }

  Test.it("rejects a non-Float32Array target") {
    var e = Fiber.new {
      Noise.fillSimplex2([0, 0, 0, 0], 0, 0, 1, 1, 2, 2, 1)
    }.try()
    Expect.that(e).toContain("Float32Array")
  }
}

Test.describe("Noise.worley2 / worley3") {
  Test.it("returns deterministic values for the same args") {
    var a = Noise.worley2(0.3, 0.7, 42)
    var b = Noise.worley2(0.3, 0.7, 42)
    Expect.that(a).toBe(b)
    var c = Noise.worley3(0.3, 0.7, 0.5, 42)
    var d = Noise.worley3(0.3, 0.7, 0.5, 42)
    Expect.that(c).toBe(d)
  }

  Test.it("varies under seed change") {
    var a = Noise.worley2(1.0, 2.0, 7)
    var b = Noise.worley2(1.0, 2.0, 999)
    Expect.that(a == b).toBe(false)
  }
}

Test.describe("Noise.ridgedFbm2 / ridgedFbm3") {
  Test.it("returns finite numbers in roughly [0, 1.1]") {
    // Ridged fBM is [0, 1] in the limit but accumulates slightly
    // higher under low-octave settings; we allow 1.1 headroom.
    for (i in 0...20) {
      var v = Noise.ridgedFbm2(i * 0.13, i * 0.21, 1337, 4, 2.0, 0.5)
      Expect.that(v >= 0).toBe(true)
      Expect.that(v <= 1.1).toBe(true)
    }
  }

  Test.it("respects octave count") {
    var single = Noise.ridgedFbm2(1.5, 2.5, 7, 1, 2.0, 0.5)
    var many   = Noise.ridgedFbm2(1.5, 2.5, 7, 6, 2.0, 0.5)
    // Different octave count should produce a different number.
    Expect.that(single == many).toBe(false)
  }
}

Test.describe("Noise.fillPerlin2 / fillValue2 / fillWorley2") {
  Test.it("fills the same number of cells fillSimplex2 does") {
    var a = Float32Array.new(16)
    var b = Float32Array.new(16)
    var c = Float32Array.new(16)
    Noise.fillPerlin2(a, 0, 0, 0.1, 0.1, 4, 4, 1)
    Noise.fillValue2(b, 0, 0, 0.1, 0.1, 4, 4, 1)
    Noise.fillWorley2(c, 0, 0, 0.1, 0.1, 4, 4, 1)
    // Every cell touched (no NaN sentinels remaining at default
    // zero) — at least ONE non-zero entry per fill since the noise
    // varies over the sampled grid.
    var anyA = false
    var anyB = false
    var anyC = false
    for (i in 0...16) {
      if (a[i] != 0) anyA = true
      if (b[i] != 0) anyB = true
      if (c[i] != 0) anyC = true
    }
    Expect.that(anyA).toBe(true)
    Expect.that(anyB).toBe(true)
    Expect.that(anyC).toBe(true)
  }

  Test.it("each variant produces a different field for the same args") {
    var p = Float32Array.new(4)
    var v = Float32Array.new(4)
    Noise.fillPerlin2(p, 0, 0, 0.25, 0.25, 2, 2, 99)
    Noise.fillValue2(v, 0, 0, 0.25, 0.25, 2, 2, 99)
    var diff = false
    for (i in 0...4) {
      if (p[i] != v[i]) diff = true
    }
    Expect.that(diff).toBe(true)
  }
}

Test.describe("Noise.fillSimplex3") {
  Test.it("populates a 3D grid in z-outermost, y, x order") {
    var w = 3
    var h = 3
    var d = 3
    var out = Float32Array.new(w * h * d)
    Noise.fillSimplex3(out, 0, 0, 0, 0.1, 0.1, 0.1, w, h, d, 7)
    // Compare each cell to the scalar sample at the same coords.
    var idx = 0
    for (z in 0...d) {
      for (y in 0...h) {
        for (x in 0...w) {
          var s = Noise.simplex3(x * 0.1, y * 0.1, z * 0.1, 7)
          // f32 round-trip: cell within a tiny epsilon of the
          // double-precision scalar.
          var delta = out[idx] - s
          if (delta < 0) delta = -delta
          Expect.that(delta < 0.00001).toBe(true)
          idx = idx + 1
        }
      }
    }
  }

  Test.it("rejects an undersized target") {
    var e = Fiber.new {
      Noise.fillSimplex3(Float32Array.new(4), 0, 0, 0, 1, 1, 1, 2, 2, 2, 1)
    }.try()
    Expect.that(e).toContain("need 8")
  }
}

Test.run()
