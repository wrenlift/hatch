// @hatch:postfx — effect parameter binding, uniform layouts, and
// fragment-body sanity. The chain orchestration + GPU pipeline
// path is exercised by a running game; these specs cover the
// Wren-side surface (config parsing, uniform write contents,
// PostPass interface contract).

import "./postfx" for Tonemap, Vignette, FXAA, ColorGrade, ChromaticAberration, Bloom
import "@hatch:game"    for PostPass
import "@hatch:test"    for Test
import "@hatch:assert"  for Expect

// ──────────────────────────────────────────────────────────────────
// Tonemap
// ──────────────────────────────────────────────────────────────────

Test.describe("Tonemap") {
  Test.it("is a PostPass") {
    Expect.that(Tonemap.new() is PostPass).toBe(true)
  }

  Test.it("default exposure is 1.0") {
    var t = Tonemap.new()
    Expect.that(t.exposure).toBe(1.0)
    Expect.that(t.name).toBe("tonemap")
    Expect.that(t.uniformBytes).toBe(16)
  }

  Test.it("opts override exposure") {
    var t = Tonemap.new({ "exposure": 2.4 })
    Expect.that(t.exposure).toBe(2.4)
  }

  Test.it("opts={} keeps defaults") {
    var t = Tonemap.new({})
    Expect.that(t.exposure).toBe(1.0)
  }

  Test.it("setter updates uniform write") {
    var t = Tonemap.new()
    t.exposure = 0.5
    var scratch = [0, 0, 0, 0]
    t.writeUniforms(scratch)
    Expect.that(scratch[0]).toBe(0.5)
    Expect.that(scratch[1]).toBe(0)
  }

  Test.it("uniformWgsl declares exposure + padding") {
    var t = Tonemap.new()
    Expect.that(t.uniformWgsl.contains("exposure: f32")).toBe(true)
  }

  Test.it("fragment body references exposure + samples input") {
    var body = Tonemap.new().fragmentBody
    Expect.that(body.contains("textureSample(t, s, uv)")).toBe(true)
    Expect.that(body.contains("u.exposure")).toBe(true)
  }
}

// ──────────────────────────────────────────────────────────────────
// Vignette
// ──────────────────────────────────────────────────────────────────

Test.describe("Vignette") {
  Test.it("defaults") {
    var v = Vignette.new()
    Expect.that(v.strength).toBe(0.4)
    Expect.that(v.radius).toBe(0.75)
    Expect.that(v.softness).toBe(0.45)
    Expect.that(v.name).toBe("vignette")
  }

  Test.it("opts override individual fields") {
    var v = Vignette.new({ "strength": 0.9, "radius": 0.5, "softness": 0.2 })
    Expect.that(v.strength).toBe(0.9)
    Expect.that(v.radius).toBe(0.5)
    Expect.that(v.softness).toBe(0.2)
  }

  Test.it("partial opts leave other fields default") {
    var v = Vignette.new({ "radius": 0.5 })
    Expect.that(v.strength).toBe(0.4)
    Expect.that(v.radius).toBe(0.5)
    Expect.that(v.softness).toBe(0.45)
  }

  Test.it("setters update uniform write") {
    var v = Vignette.new()
    v.strength = 0.1
    v.radius   = 0.6
    v.softness = 0.3
    var scratch = [0, 0, 0, 0]
    v.writeUniforms(scratch)
    Expect.that(scratch[0]).toBe(0.1)
    Expect.that(scratch[1]).toBe(0.6)
    Expect.that(scratch[2]).toBe(0.3)
  }

  Test.it("fragment body references uniform fields") {
    var body = Vignette.new().fragmentBody
    Expect.that(body.contains("u.strength")).toBe(true)
    Expect.that(body.contains("u.radius")).toBe(true)
    Expect.that(body.contains("u.softness")).toBe(true)
  }
}

// ──────────────────────────────────────────────────────────────────
// FXAA
// ──────────────────────────────────────────────────────────────────

Test.describe("FXAA") {
  Test.it("defaults") {
    var f = FXAA.new()
    Expect.that(f.subpixel).toBe(0.75)
    Expect.that(f.edgeThreshold).toBe(0.166)
    Expect.that(f.edgeThresholdMin).toBe(0.0312)
    Expect.that(f.name).toBe("fxaa")
  }

  Test.it("opts override") {
    var f = FXAA.new({ "subpixel": 0.5, "edgeThreshold": 0.1 })
    Expect.that(f.subpixel).toBe(0.5)
    Expect.that(f.edgeThreshold).toBe(0.1)
    Expect.that(f.edgeThresholdMin).toBe(0.0312)
  }

  Test.it("uniform write order: subpixel, edgeThreshold, edgeThresholdMin, pad") {
    var f = FXAA.new()
    f.subpixel        = 0.4
    f.edgeThreshold   = 0.2
    f.edgeThresholdMin = 0.05
    var scratch = [0, 0, 0, 0]
    f.writeUniforms(scratch)
    Expect.that(scratch[0]).toBe(0.4)
    Expect.that(scratch[1]).toBe(0.2)
    Expect.that(scratch[2]).toBe(0.05)
    Expect.that(scratch[3]).toBe(0)
  }

  Test.it("fragment body computes luma + early-outs cleanly") {
    var body = FXAA.new().fragmentBody
    Expect.that(body.contains("dot(centre.rgb, lumaCoef)")).toBe(true)
    // The "no edge here" early-out keeps perf reasonable.
    Expect.that(body.contains("return centre")).toBe(true)
  }
}

// ──────────────────────────────────────────────────────────────────
// ColorGrade
// ──────────────────────────────────────────────────────────────────

Test.describe("ColorGrade") {
  Test.it("defaults") {
    var c = ColorGrade.new()
    Expect.that(c.lift).toEqual([0, 0, 0])
    Expect.that(c.gamma).toEqual([1, 1, 1])
    Expect.that(c.gain).toEqual([1, 1, 1])
    Expect.that(c.saturation).toBe(1.0)
    Expect.that(c.uniformBytes).toBe(64)
  }

  Test.it("opts override vec3 bands") {
    var c = ColorGrade.new({
      "lift":  [0.1, 0, -0.05],
      "gamma": [1.2, 1.0, 1.0],
      "gain":  [1.05, 1.0, 0.95]
    })
    Expect.that(c.lift[0]).toBe(0.1)
    Expect.that(c.gamma[0]).toBe(1.2)
    Expect.that(c.gain[2]).toBe(0.95)
  }

  Test.it("non-list lift aborts") {
    Expect.that(Fn.new { ColorGrade.new({ "lift": 0.5 }) }).toAbort()
  }

  Test.it("uniform write packs 4 vec4 chunks") {
    var c = ColorGrade.new({
      "lift":  [0.1, 0.2, 0.3],
      "gamma": [1.1, 1.2, 1.3],
      "gain":  [2.1, 2.2, 2.3],
      "saturation": 0.5
    })
    var scratch = []
    var i = 0
    while (i < 16) {
      scratch.add(0)
      i = i + 1
    }
    c.writeUniforms(scratch)
    Expect.that(scratch[0]).toBe(0.1)   // lift.x
    Expect.that(scratch[4]).toBe(1.1)   // gamma.x
    Expect.that(scratch[8]).toBe(2.1)   // gain.x
    Expect.that(scratch[12]).toBe(0.5)  // saturation.x
    // Padding stays zeroed.
    Expect.that(scratch[3]).toBe(0)
    Expect.that(scratch[15]).toBe(0)
  }

  Test.it("fragment body references all three bands + saturation") {
    var body = ColorGrade.new().fragmentBody
    Expect.that(body.contains("u.lift")).toBe(true)
    Expect.that(body.contains("u.gamma")).toBe(true)
    Expect.that(body.contains("u.gain")).toBe(true)
    Expect.that(body.contains("u.saturation")).toBe(true)
  }
}

// ──────────────────────────────────────────────────────────────────
// ChromaticAberration
// ──────────────────────────────────────────────────────────────────

Test.describe("ChromaticAberration") {
  Test.it("defaults") {
    var ca = ChromaticAberration.new()
    Expect.that(ca.strength).toBe(0.003)
    Expect.that(ca.falloff).toBe(2.0)
    Expect.that(ca.name).toBe("chromatic-aberration")
  }

  Test.it("opts override") {
    var ca = ChromaticAberration.new({ "strength": 0.01, "falloff": 3 })
    Expect.that(ca.strength).toBe(0.01)
    Expect.that(ca.falloff).toBe(3)
  }

  Test.it("uniform write") {
    var ca = ChromaticAberration.new()
    ca.strength = 0.005
    ca.falloff  = 1.5
    var scratch = [0, 0, 0, 0]
    ca.writeUniforms(scratch)
    Expect.that(scratch[0]).toBe(0.005)
    Expect.that(scratch[1]).toBe(1.5)
  }

  Test.it("fragment body samples all three channels separately") {
    var body = ChromaticAberration.new().fragmentBody
    // R uses +offset, B uses -offset; G + A are centre samples.
    Expect.that(body.contains("uv + dir * amt")).toBe(true)
    Expect.that(body.contains("uv - dir * amt")).toBe(true)
  }
}

// ──────────────────────────────────────────────────────────────────
// Bloom — multi-pass effect, custom pipelines + bind-group layouts.
// Specs cover config surface, stepCount, requestTargets, and the
// shader source contents. GPU pipeline build is exercised only by a
// running game (Bloom touches the device on `onAdded_`).
// ──────────────────────────────────────────────────────────────────

Test.describe("Bloom") {
  Test.it("is a PostPass") {
    Expect.that(Bloom.new() is PostPass).toBe(true)
  }

  Test.it("defaults") {
    var b = Bloom.new()
    Expect.that(b.threshold).toBe(1.0)
    Expect.that(b.knee).toBe(0.5)
    Expect.that(b.intensity).toBe(0.6)
    Expect.that(b.levels).toBe(4)
    Expect.that(b.filterRadius).toBe(1.0)
    Expect.that(b.name).toBe("bloom")
  }

  Test.it("opts override individual fields") {
    var b = Bloom.new({
      "threshold": 1.5,
      "knee":      0.2,
      "intensity": 1.0,
      "levels":    5,
      "filterRadius": 1.5
    })
    Expect.that(b.threshold).toBe(1.5)
    Expect.that(b.knee).toBe(0.2)
    Expect.that(b.intensity).toBe(1.0)
    Expect.that(b.levels).toBe(5)
    Expect.that(b.filterRadius).toBe(1.5)
  }

  Test.it("opts={} keeps defaults") {
    var b = Bloom.new({})
    Expect.that(b.threshold).toBe(1.0)
  }

  Test.it("stepCount is 2 * levels") {
    var b = Bloom.new({ "levels": 4 })
    Expect.that(b.stepCount).toBe(8)
    var b2 = Bloom.new({ "levels": 6 })
    Expect.that(b2.stepCount).toBe(12)
  }

  Test.it("requestTargets returns one descriptor per level, each halving size") {
    var b = Bloom.new({ "levels": 4 })
    var targets = b.requestTargets(1280, 720)
    Expect.that(targets.count).toBe(4)
    Expect.that(targets[0]["width"]).toBe(640)
    Expect.that(targets[0]["height"]).toBe(360)
    Expect.that(targets[1]["width"]).toBe(320)
    Expect.that(targets[1]["height"]).toBe(180)
    Expect.that(targets[2]["width"]).toBe(160)
    Expect.that(targets[2]["height"]).toBe(90)
    Expect.that(targets[3]["width"]).toBe(80)
    Expect.that(targets[3]["height"]).toBe(45)
  }

  Test.it("targets use rgba16float for HDR-ish intermediate precision") {
    var b = Bloom.new()
    var targets = b.requestTargets(512, 512)
    var i = 0
    while (i < targets.count) {
      Expect.that(targets[i]["format"]).toBe("rgba16float")
      i = i + 1
    }
  }

  Test.it("setters update parameters") {
    var b = Bloom.new()
    b.threshold = 2.0
    b.knee      = 0.1
    b.intensity = 0.9
    b.filterRadius = 2.0
    Expect.that(b.threshold).toBe(2.0)
    Expect.that(b.knee).toBe(0.1)
    Expect.that(b.intensity).toBe(0.9)
    Expect.that(b.filterRadius).toBe(2.0)
  }

  Test.it("threshold shader uses soft-cutoff (smoothstep around threshold ± knee)") {
    Expect.that(Bloom.SHADER_THRESHOLD_.contains("smoothstep")).toBe(true)
    Expect.that(Bloom.SHADER_THRESHOLD_.contains("u.threshold")).toBe(true)
    Expect.that(Bloom.SHADER_THRESHOLD_.contains("u.knee")).toBe(true)
  }

  Test.it("downsample shader is a 4-tap box filter") {
    var s = Bloom.SHADER_DOWNSAMPLE_
    Expect.that(s.contains("textureSample")).toBe(true)
    Expect.that(s.contains("0.25")).toBe(true)
  }

  Test.it("upsample shader uses 9-tap tent filter scaled by filterRadius") {
    var s = Bloom.SHADER_UPSAMPLE_
    Expect.that(s.contains("u.filterRadius")).toBe(true)
    Expect.that(s.contains("16.0")).toBe(true)
  }

  Test.it("composite shader samples both scene and bloom + scales by intensity") {
    var s = Bloom.SHADER_COMPOSITE_
    Expect.that(s.contains("sceneTex")).toBe(true)
    Expect.that(s.contains("bloomTex")).toBe(true)
    Expect.that(s.contains("u.intensity")).toBe(true)
  }
}

Test.run()
