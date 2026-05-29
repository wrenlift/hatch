// @hatch:game/chain — PostPass + PostFX chain primitive. Concrete
// effects (Tonemap, Vignette, Bloom, ...) live in @hatch:postfx
// and are tested there. This spec covers the subclass contract.

import "./chain"       for PostPass, PostFX
import "@hatch:test"   for Test
import "@hatch:assert" for Expect

Test.describe("PostPass base") {
  Test.it("default identity + stepCount + uniform shape") {
    var p = PostPass.new()
    Expect.that(p.name).toBe("unnamed")
    Expect.that(p.stepCount).toBe(1)
    Expect.that(p.uniformBytes).toBe(0)
    Expect.that(p.uniformWgsl).toBe("")
    Expect.that(p.wantsDepth).toBe(false)
  }

  Test.it("requestTargets defaults to empty list") {
    var p = PostPass.new()
    Expect.that(p.requestTargets(800, 600).count).toBe(0)
  }

  Test.it("writeUniforms is a no-op on the base") {
    var p = PostPass.new()
    var scratch = [1, 2, 3, 4]
    p.writeUniforms(scratch)
    Expect.that(scratch[0]).toBe(1)
  }

  Test.it("fragmentBody returns a passthrough sample") {
    var p = PostPass.new()
    Expect.that(p.fragmentBody.contains("textureSample(t, s, uv)")).toBe(true)
  }
}

Test.describe("PostPass subclass contract") {
  Test.it("custom single-pass effect overrides name + uniforms") {
    var s = SimpleSubclass_.new()
    Expect.that(s.name).toBe("simple")
    Expect.that(s.uniformBytes).toBe(16)
    Expect.that(s.uniformWgsl).toBe("strength: f32, _p0: f32, _p1: f32, _p2: f32")
    var scratch = [0, 0, 0, 0]
    s.writeUniforms(scratch)
    Expect.that(scratch[0]).toBe(0.42)
  }

  Test.it("multi-step subclass advertises stepCount + requestTargets") {
    var m = MultiStepSubclass_.new()
    Expect.that(m.stepCount).toBe(3)
    var targets = m.requestTargets(640, 480)
    Expect.that(targets.count).toBe(2)
    Expect.that(targets[0]["width"]).toBe(320)
    Expect.that(targets[1]["width"]).toBe(160)
  }

  Test.it("depth-aware subclass flags wantsDepth") {
    var d = DepthSubclass_.new()
    Expect.that(d.wantsDepth).toBe(true)
  }
}

class SimpleSubclass_ is PostPass {
  construct new() {
    super()
    _strength = 0.42
  }
  name         { "simple" }
  uniformBytes { 16 }
  uniformWgsl  { "strength: f32, _p0: f32, _p1: f32, _p2: f32" }
  fragmentBody { "let c = textureSample(t, s, uv); return c * u.strength;" }
  writeUniforms(scratch) {
    scratch[0] = _strength
    scratch[1] = 0
    scratch[2] = 0
    scratch[3] = 0
  }
}

class MultiStepSubclass_ is PostPass {
  construct new() { super() }
  name      { "multi" }
  stepCount { 3 }
  requestTargets(w, h) {
    return [
      { "width": (w / 2).floor, "height": (h / 2).floor, "format": "rgba16float" },
      { "width": (w / 4).floor, "height": (h / 4).floor, "format": "rgba16float" }
    ]
  }
}

class DepthSubclass_ is PostPass {
  construct new() { super() }
  name { "depth" }
  wantsDepth { true }
}

Test.run()
