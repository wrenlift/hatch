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

Test.run()
