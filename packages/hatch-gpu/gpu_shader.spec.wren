// @hatch:gpu Shader factory — pure-Wren composition tests. The
// resulting WGSL strings aren't compiled here; the hardware-bound
// gpu.spec.wren picks them up the next time a renderer is built.

import "./gpu_shader"  for Shader
import "@hatch:test"   for Test
import "@hatch:assert" for Expect

Test.describe("Shader fragment library") {
  Test.it("prelude exposes PI + saturate + sRGB helpers") {
    var s = Shader.prelude
    Expect.that(s.contains("const PI: f32 = 3.14159")).toBe(true)
    Expect.that(s.contains("fn saturate")).toBe(true)
    Expect.that(s.contains("fn srgb_to_linear")).toBe(true)
    Expect.that(s.contains("fn linear_to_srgb")).toBe(true)
  }

  Test.it("lightTypes defines DirLight / PointLight / SpotLight structs") {
    var s = Shader.lightTypes
    Expect.that(s.contains("struct DirLight")).toBe(true)
    Expect.that(s.contains("struct PointLight")).toBe(true)
    Expect.that(s.contains("struct SpotLight")).toBe(true)
  }

  Test.it("lightAttenuation exposes distance + spot helpers") {
    var s = Shader.lightAttenuation
    Expect.that(s.contains("fn distance_attenuation")).toBe(true)
    Expect.that(s.contains("fn spot_attenuation")).toBe(true)
  }

  Test.it("pbrBrdf exposes GGX / Smith / Schlick + pbr_direct entry") {
    var s = Shader.pbrBrdf
    Expect.that(s.contains("fn ggx_distribution")).toBe(true)
    Expect.that(s.contains("fn smith_g")).toBe(true)
    Expect.that(s.contains("fn schlick_fresnel")).toBe(true)
    Expect.that(s.contains("fn pbr_direct")).toBe(true)
  }

  Test.it("normalMapping exposes perturb_normal") {
    Expect.that(Shader.normalMapping.contains("fn perturb_normal")).toBe(true)
  }

  Test.it("tonemapping exposes ACES + Reinhard") {
    var s = Shader.tonemapping
    Expect.that(s.contains("fn tonemap_aces")).toBe(true)
    Expect.that(s.contains("fn tonemap_reinhard")).toBe(true)
  }
}

Test.describe("Shader.compose") {
  Test.it("joins fragments in declaration order with newlines") {
    var out = Shader.compose(["alpha", "beta", "gamma"])
    Expect.that(out).toBe("alpha\nbeta\ngamma\n")
  }

  Test.it("handles an empty list as an empty WGSL source") {
    Expect.that(Shader.compose([])).toBe("")
  }

  Test.it("preserves PI from the prelude when composed with downstream fragments") {
    var src = Shader.compose([Shader.prelude, Shader.pbrBrdf])
    Expect.that(src.contains("const PI")).toBe(true)
    Expect.that(src.contains("fn pbr_direct")).toBe(true)
  }
}

Test.describe("Shader.module") {
  Test.it("calls device.createShaderModule with composed source + label") {
    var captured = null
    var fakeDevice = MockDevice_.new() { |desc| captured = desc }
    var result = Shader.module(fakeDevice, ["a", "b"], "test-label")
    Expect.that(captured["code"]).toBe("a\nb\n")
    Expect.that(captured["label"]).toBe("test-label")
    Expect.that(result).toBe("mock-shader")
  }
}

// Mock device that records the descriptor it received and returns
// a sentinel value the spec can identify-check.
class MockDevice_ {
  construct new(captureFn) { _capture = captureFn }
  createShaderModule(desc) {
    _capture.call(desc)
    return "mock-shader"
  }
}

Test.run()
