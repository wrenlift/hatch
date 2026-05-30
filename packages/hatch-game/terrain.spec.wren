// @hatch:game/terrain acceptance tests. Mesh-builder math, the
// flat-heightmap edge case, and the @hatch:noise composition.

import "./terrain"   for Terrain
import "@hatch:gpu"  for Gpu
import "@hatch:test" for Test
import "@hatch:assert" for Expect

Test.describe("Terrain.vertexCount / indexCount") {
  Test.it("vertex count equals width × depth") {
    Expect.that(Terrain.vertexCount(2, 2)).toBe(4)
    Expect.that(Terrain.vertexCount(64, 64)).toBe(4096)
    Expect.that(Terrain.vertexCount(100, 50)).toBe(5000)
  }

  Test.it("index count equals 6 × (width − 1) × (depth − 1)") {
    Expect.that(Terrain.indexCount(2, 2)).toBe(6)        // one quad → 6
    Expect.that(Terrain.indexCount(3, 3)).toBe(24)       // 4 quads × 6
    Expect.that(Terrain.indexCount(64, 64)).toBe(6 * 63 * 63)
  }
}

Test.describe("Terrain.meshFromHeightmap input guards") {
  Test.it("rejects width < 2") {
    var device = Gpu.requestDevice()
    var heights = Float32Array.new(2)
    var e = Fiber.new {
      Terrain.meshFromHeightmap(device, heights, 1, 2, {})
    }.try()
    Expect.that(e).toContain("width and depth")
    device.destroy
  }

  Test.it("rejects depth < 2") {
    var device = Gpu.requestDevice()
    var heights = Float32Array.new(2)
    var e = Fiber.new {
      Terrain.meshFromHeightmap(device, heights, 2, 1, {})
    }.try()
    Expect.that(e).toContain("width and depth")
    device.destroy
  }
}

Test.describe("Terrain.meshFromHeightmap construction") {
  Test.it("produces a Mesh with the expected index count for a flat grid") {
    var device = Gpu.requestDevice()
    var w = 8
    var d = 6
    var heights = Float32Array.new(w * d)   // all zeros
    var mesh = Terrain.meshFromHeightmap(device, heights, w, d, {})
    Expect.that(mesh.indexCount).toBe(Terrain.indexCount(w, d))
    device.destroy
  }

  Test.it("scales relief by `amplitude` without resampling") {
    var device = Gpu.requestDevice()
    var w = 4
    var d = 4
    var heights = Float32Array.new(w * d)
    for (i in 0...w * d) heights[i] = 1.0     // every vertex y = 1 * amplitude
    var mesh = Terrain.meshFromHeightmap(device, heights, w, d, { "amplitude": 7.5 })
    Expect.that(mesh.indexCount).toBe(Terrain.indexCount(w, d))
    device.destroy
  }
}

Test.describe("Terrain.fromNoise") {
  Test.it("aborts when `width` or `depth` are missing") {
    var device = Gpu.requestDevice()
    var e1 = Fiber.new {
      Terrain.fromNoise(device, { "depth": 16 })
    }.try()
    Expect.that(e1).toContain("width")
    var e2 = Fiber.new {
      Terrain.fromNoise(device, { "width": 16 })
    }.try()
    Expect.that(e2).toContain("width")
    device.destroy
  }

  Test.it("samples Noise.fillSimplex2 and builds a Mesh") {
    var device = Gpu.requestDevice()
    var w = 16
    var d = 16
    var mesh = Terrain.fromNoise(device, {
      "width":  w,
      "depth":  d,
      "seed":   1337,
      "amplitude": 3.0,
      "noiseStepX": 0.1,
      "noiseStepZ": 0.1
    })
    Expect.that(mesh.indexCount).toBe(Terrain.indexCount(w, d))
    device.destroy
  }
}

Test.run()
