// @hatch:gpu Material — pure-Wren data + packing tests. No GPU
// device involved; the renderer's bind-group integration is
// exercised by the hardware-bound gpu.spec.wren.

import "./gpu_material" for Material
import "@hatch:math"    for Vec4
import "@hatch:test"    for Test
import "@hatch:assert"  for Expect

Test.describe("Material defaults") {
  Test.it("opaque white non-metal at full roughness with no textures") {
    var m = Material.new()
    Expect.that(m.albedoColor.x).toBe(1)
    Expect.that(m.albedoColor.y).toBe(1)
    Expect.that(m.albedoColor.z).toBe(1)
    Expect.that(m.albedoColor.w).toBe(1)
    Expect.that(m.metallicFactor).toBe(0)
    Expect.that(m.roughnessFactor).toBe(1)
    Expect.that(m.alphaMode).toBe("opaque")
    Expect.that(m.albedoTexture).toBe(null)
    Expect.that(m.metallicRoughnessTexture).toBe(null)
    Expect.that(m.normalTexture).toBe(null)
    Expect.that(m.occlusionTexture).toBe(null)
    Expect.that(m.emissiveTexture).toBe(null)
    Expect.that(m.doubleSided).toBe(false)
  }

  Test.it("flat-colour ctor sets albedo + mid roughness") {
    var m = Material.new(Vec4.new(0.85, 0.42, 0.45, 1.0))
    Expect.that(m.albedoColor.x).toBe(0.85)
    Expect.that(m.roughnessFactor).toBe(0.6)
    Expect.that(m.metallicFactor).toBe(0)
  }

  Test.it("legacy `color` getter/setter mirrors albedoColor") {
    var m = Material.new()
    m.color = Vec4.new(1, 0, 0, 1)
    Expect.that(m.albedoColor.x).toBe(1)
    Expect.that(m.color.x).toBe(1)
  }
}

Test.describe("Material revision bookkeeping") {
  Test.it("revision_ starts at 0 and ticks on every mutation") {
    var m = Material.new()
    Expect.that(m.revision_).toBe(0)

    m.albedoColor = Vec4.new(0.5, 0.5, 0.5, 1)
    Expect.that(m.revision_).toBe(1)

    m.metallicFactor = 0.8
    Expect.that(m.revision_).toBe(2)

    m.roughnessFactor = 0.2
    Expect.that(m.revision_).toBe(3)

    m.normalScale = 1.5
    Expect.that(m.revision_).toBe(4)
  }

  Test.it("setting the same property still ticks revision (no equality cache)") {
    var m = Material.new()
    var c = Vec4.new(1, 1, 1, 1)
    m.albedoColor = c
    var r1 = m.revision_
    m.albedoColor = c
    Expect.that(m.revision_ > r1).toBe(true)
  }
}

Test.describe("Material.packUniform_") {
  Test.it("packs the WGSL MaterialUniforms layout (20 floats)") {
    var m = Material.new()
    m.albedoColor      = Vec4.new(0.85, 0.42, 0.45, 1.0)
    m.emissiveColor    = Vec4.new(0.1, 0.2, 0.3, 1.0)
    m.metallicFactor   = 0.25
    m.roughnessFactor  = 0.75
    m.normalScale      = 1.5
    m.occlusionStrength = 0.5
    m.alphaMode        = "blend"
    m.alphaCutoff      = 0.4
    m.doubleSided      = true
    m.bands            = 4
    m.rimStrength      = 0.6
    m.rimWidth         = 3.0
    m.ambientFloor     = 0.3

    var out = []
    m.packUniform_(out)
    Expect.that(out.count).toBe(20)

    // albedo_color (4)
    Expect.that(out[0]).toBe(0.85)
    Expect.that(out[1]).toBe(0.42)
    Expect.that(out[2]).toBe(0.45)
    Expect.that(out[3]).toBe(1.0)
    // emissive_color (4)
    Expect.that(out[4]).toBe(0.1)
    Expect.that(out[5]).toBe(0.2)
    Expect.that(out[6]).toBe(0.3)
    Expect.that(out[7]).toBe(1.0)
    // factors: metallic, roughness, normalScale, occlusionStrength
    Expect.that(out[8]).toBe(0.25)
    Expect.that(out[9]).toBe(0.75)
    Expect.that(out[10]).toBe(1.5)
    Expect.that(out[11]).toBe(0.5)
    // alpha: mode(blend=2), cutoff, doubleSided(1), sway-default(0)
    Expect.that(out[12]).toBe(2)
    Expect.that(out[13]).toBe(0.4)
    Expect.that(out[14]).toBe(1.0)
    Expect.that(out[15]).toBe(0)
    // toon: bands, rimStrength, rimWidth, ambientFloor (read by the
    // cel-shaded pipeline; the PBR shader ignores this slot but the
    // UBO layout stays uniform across pipelines).
    Expect.that(out[16]).toBe(4)
    Expect.that(out[17]).toBe(0.6)
    Expect.that(out[18]).toBe(3.0)
    Expect.that(out[19]).toBe(0.3)
  }

  Test.it("default material packs neutral toon params (bands=3, rim=0, floor=0.35)") {
    // A freshly-constructed PBR material still emits the toon slot
    // — keeps the UBO layout uniform so both pipelines bind the
    // same struct. The defaults are chosen so a caller who flips
    // shadingModel = "toon" without setting anything else lands in
    // a sensible three-band cel look with no rim.
    var m = Material.new()
    var out = []
    m.packUniform_(out)
    Expect.that(out[16]).toBe(3)       // bands
    Expect.that(out[17]).toBe(0)       // rim strength (off by default)
    Expect.that(out[18]).toBe(4)       // rim width (Fresnel exponent)
    Expect.that(out[19]).toBe(0.35)    // ambient floor
  }

  Test.it("toon param setters tick revision (renderer rebuild trigger)") {
    var m = Material.new()
    var r0 = m.revision_
    m.bands = 5
    Expect.that(m.revision_ > r0).toBe(true)
    var r1 = m.revision_
    m.rimStrength = 0.5
    Expect.that(m.revision_ > r1).toBe(true)
    var r2 = m.revision_
    m.rimWidth = 3.0
    Expect.that(m.revision_ > r2).toBe(true)
    var r3 = m.revision_
    m.ambientFloor = 0.5
    Expect.that(m.revision_ > r3).toBe(true)
    var r4 = m.revision_
    m.shadingModel = "toon"
    Expect.that(m.revision_ > r4).toBe(true)
  }

  Test.it("shadingModel defaults to 'pbr'") {
    var m = Material.new()
    Expect.that(m.shadingModel).toBe("pbr")
  }

  Test.it("alphaMode maps 'opaque' → 0 / 'mask' → 1 / 'blend' → 2") {
    var m = Material.new()
    var out = []

    m.alphaMode = "opaque"
    out.clear()
    m.packUniform_(out)
    Expect.that(out[12]).toBe(0)

    m.alphaMode = "mask"
    out.clear()
    m.packUniform_(out)
    Expect.that(out[12]).toBe(1)

    m.alphaMode = "blend"
    out.clear()
    m.packUniform_(out)
    Expect.that(out[12]).toBe(2)
  }
}

Test.run()
