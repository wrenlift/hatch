// Renderer3D — shadow helpers (the math is pure and testable
// without a real GPU device). Full integration is exercised by a
// running game.

import "./gpu_renderer3d" for Renderer3D
import "@hatch:math"      for Vec3, Mat4
import "@hatch:test"      for Test
import "@hatch:assert"    for Expect

Test.describe("Renderer3D.computeLightVP_") {
  Test.it("returns a Mat4") {
    var vp = Renderer3D.computeLightVP_(
      Vec3.new(0, -1, 0), Vec3.new(0, 0, 0),
      10.0, 0.1, 50.0
    )
    Expect.that(vp is Mat4).toBe(true)
  }

  Test.it("projects the scene origin to roughly the centre of clip XY") {
    // Straight-down light, origin centred. Origin should land near
    // x=0, y=0 in clip space (the centre of the shadow map).
    var vp = Renderer3D.computeLightVP_(
      Vec3.new(0, -1, 0), Vec3.new(0, 0, 0),
      10.0, 0.1, 50.0
    )
    var p = vp.transformPoint(Vec3.new(0, 0, 0))
    Expect.that(p.x.abs < 0.0001).toBe(true)
    Expect.that(p.y.abs < 0.0001).toBe(true)
  }

  Test.it("projects extent-distance points to the clip-space edges") {
    // The right-handed lookAt may flip the x axis depending on
    // basis orientation, so test the absolute extent rather than
    // assuming a sign convention. What matters: a point one
    // `extent` away from centre lands at clip.x ≈ ±1.
    var vp = Renderer3D.computeLightVP_(
      Vec3.new(0, -1, 0), Vec3.new(0, 0, 0),
      10.0, 0.1, 50.0
    )
    var pos = vp.transformPoint(Vec3.new(10, 0, 0))
    var neg = vp.transformPoint(Vec3.new(-10, 0, 0))
    Expect.that((pos.x.abs - 1.0).abs < 0.01).toBe(true)
    Expect.that((neg.x.abs - 1.0).abs < 0.01).toBe(true)
    // The two extents land on opposite sides of clip.x = 0.
    Expect.that((pos.x + neg.x).abs < 0.0001).toBe(true)
  }

  Test.it("handles a straight-down light without basis collapse") {
    // (0, -1, 0) is the degenerate case for the default up = (0,1,0).
    // The constructor swaps to world-Z up internally — exercise it
    // to confirm the matrix is well-formed (no NaN / no Inf).
    var vp = Renderer3D.computeLightVP_(
      Vec3.new(0, -1, 0), Vec3.new(0, 0, 0),
      10.0, 0.1, 50.0
    )
    var p = vp.transformPoint(Vec3.new(0, 0, 0))
    Expect.that(p.x == p.x).toBe(true)   // NaN check via reflexivity
    Expect.that(p.y == p.y).toBe(true)
    Expect.that(p.z == p.z).toBe(true)
  }

  Test.it("handles an oblique light direction without crashing") {
    var vp = Renderer3D.computeLightVP_(
      Vec3.new(-0.3, -1.0, -0.5).normalized, Vec3.new(0, 0, 0),
      50.0, 0.1, 100.0
    )
    Expect.that(vp is Mat4).toBe(true)
  }
}

Test.describe("Renderer3D shader source") {
  Test.it("PBR shader declares the shadow_factor helper") {
    Expect.that(Renderer3D.PBR_WGSL_.contains("fn shadow_factor")).toBe(true)
    Expect.that(Renderer3D.PBR_WGSL_.contains("textureSampleCompare")).toBe(true)
  }

  Test.it("PBR shader applies shadow_factor only to the first dir light") {
    Expect.that(Renderer3D.PBR_WGSL_.contains("if (i == 0u)")).toBe(true)
  }

  Test.it("Shadow vertex shader takes ShadowUniforms (light_vp + model)") {
    var s = Renderer3D.SHADOW_WGSL_
    Expect.that(s.contains("light_vp")).toBe(true)
    Expect.that(s.contains("model")).toBe(true)
    Expect.that(s.contains("@vertex")).toBe(true)
    // Depth-only — no @fragment in the shadow shader.
    Expect.that(s.contains("@fragment")).toBe(false)
  }
}

Test.run()
