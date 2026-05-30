// @hatch:game/water acceptance tests. Mesh size math + the
// noise-driven wave-height sampler.

import "./water"        for Water, WaterPipeline
import "@hatch:gpu"     for Gpu, Camera3D
import "@hatch:math"    for Vec3, Mat4
import "@hatch:test"    for Test
import "@hatch:assert"  for Expect

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

Test.describe("WaterPipeline shader source") {
  Test.it("declares the wave_height + vs_main + fs_main entries") {
    var wgsl = WaterPipeline.SHADER_WGSL_
    Expect.that(wgsl.contains("fn wave_height")).toBe(true)
    Expect.that(wgsl.contains("@vertex")).toBe(true)
    Expect.that(wgsl.contains("@fragment")).toBe(true)
    Expect.that(wgsl.contains("fn vs_main")).toBe(true)
    Expect.that(wgsl.contains("fn fs_main")).toBe(true)
  }

  Test.it("samples wave_height twice in vs_main to derive the normal gradient") {
    var wgsl = WaterPipeline.SHADER_WGSL_
    // The vertex shader needs at least three wave_height samples
    // (centre + two offset for the gradient). The function
    // definition counts as the first, so >=4 total.
    var count = 0
    var i = 0
    while (i < wgsl.count) {
      var hit = wgsl.indexOf("wave_height", i)
      if (hit < 0) break
      count = count + 1
      i = hit + 1
    }
    Expect.that(count >= 4).toBe(true)
  }

  Test.it("uses the Schlick fresnel term and Blinn-Phong specular") {
    var wgsl = WaterPipeline.SHADER_WGSL_
    Expect.that(wgsl.contains("pow(1.0 - NdotV")).toBe(true)
    Expect.that(wgsl.contains("normalize(L + V)")).toBe(true)
    Expect.that(wgsl.contains("pow(NdotH")).toBe(true)
  }
}

Test.describe("WaterPipeline construction") {
  Test.it("builds + destroys cleanly against a real device") {
    var device = Gpu.requestDevice()
    var pipe = WaterPipeline.new(device, "rgba8unorm", "depth32float")
    pipe.destroy
    device.destroy
  }

  Test.it("setSun / setWave / setColors / setAmbient all mutate without aborting") {
    var device = Gpu.requestDevice()
    var pipe = WaterPipeline.new(device, "rgba8unorm", "depth32float")
    pipe.setSun([-0.2, -1.0, 0.0], [1.0, 0.95, 0.8], 4.0)
    pipe.setWave(0.6, 0.15, 0.3)
    pipe.setColors([0.02, 0.10, 0.18, 0.9], [0.6, 0.8, 0.95], 4.0)
    pipe.setAmbient([0.05, 0.10, 0.15])
    pipe.destroy
    device.destroy
  }
}

Test.describe("WaterPipeline draw lifecycle") {
  Test.it("draw before beginFrame aborts cleanly") {
    var device = Gpu.requestDevice()
    var pipe = WaterPipeline.new(device, "rgba8unorm", "depth32float")
    var mesh = Water.makePlane(device, { "subdivisions": 2 })
    var e = Fiber.new { pipe.draw(mesh, Mat4.identity) }.try()
    Expect.that(e).toContain("beginFrame")
    pipe.destroy
    device.destroy
  }
}

Test.run()
