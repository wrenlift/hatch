// @hatch:game/water acceptance tests. Mesh size math + the
// noise-driven wave-height sampler.

import "./water"      for Water
import "@hatch:gpu"   for Gpu
import "@hatch:test"   for Test
import "@hatch:assert" for Expect

Test.describe("Water.makePlane construction") {
  Test.it("produces a Mesh with the expected index count") {
    var device = Gpu.requestDevice()
    var mesh = Water.makePlane(device, { "size": 16, "subdivisions": 4 })
    // 4×4 cells × 6 indices each = 96.
    Expect.that(mesh.indexCount).toBe(96)
    device.destroy
  }

  Test.it("honours subdivisions = 1 (single quad fallback)") {
    var device = Gpu.requestDevice()
    var mesh = Water.makePlane(device, { "subdivisions": 1 })
    Expect.that(mesh.indexCount).toBe(6)
    device.destroy
  }

  Test.it("aborts on subdivisions < 1") {
    var device = Gpu.requestDevice()
    var e = Fiber.new {
      Water.makePlane(device, { "subdivisions": 0 })
    }.try()
    Expect.that(e).toContain("subdivisions")
    device.destroy
  }
}

Test.describe("Water.waveHeight") {
  Test.it("is deterministic in (opts, x, z, t)") {
    var opts = { "amplitude": 1, "scale": 0.2, "seed": 1 }
    var a = Water.waveHeight(opts, 3.2, 4.8, 1.5)
    var b = Water.waveHeight(opts, 3.2, 4.8, 1.5)
    Expect.that(a).toBe(b)
  }

  Test.it("evolves over time") {
    var opts = { "amplitude": 1, "scale": 0.2, "timeScale": 1, "seed": 1 }
    var a = Water.waveHeight(opts, 1.0, 2.0, 0.0)
    var b = Water.waveHeight(opts, 1.0, 2.0, 10.0)
    Expect.that(a == b).toBe(false)
  }

  Test.it("stays within roughly ±2 × amplitude across a sample grid") {
    // fBm with octaves=3 has a max bound of A + A/2 + A/4 = 1.75A,
    // and simplex returns values in [-1, 1], so |h| < 2A is a
    // generous envelope.
    var opts = { "amplitude": 0.4, "scale": 0.1, "octaves": 3, "seed": 5 }
    var lo = 999
    var hi = -999
    for (i in 0...30) {
      for (j in 0...30) {
        var h = Water.waveHeight(opts, i * 0.7, j * 0.7, i * 0.1)
        if (h < lo) lo = h
        if (h > hi) hi = h
      }
    }
    Expect.that(lo >= -0.8).toBe(true)
    Expect.that(hi <=  0.8).toBe(true)
  }

  Test.it("rejects octaves outside 1..8") {
    var e = Fiber.new {
      Water.waveHeight({ "octaves": 0 }, 0, 0, 0)
    }.try()
    Expect.that(e).toContain("octaves")
  }
}

Test.run()
