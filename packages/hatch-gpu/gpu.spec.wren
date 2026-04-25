// @hatch:gpu — phase 1 acceptance test.
//
// Headless device request is the most basic exercise: prove the
// dylib loads, the adapter is discoverable, and the Wren wrapper
// hands back a valid id with sane metadata. Higher-level passes
// (buffer, texture, shader, render-to-texture readback) are added
// as the foreign surface grows.

import "./gpu"         for Gpu, Device, Buffer
import "@hatch:math"   for Vec3, Vec4, Mat4, Quat
import "@hatch:test"   for Test
import "@hatch:assert" for Expect

Test.describe("Gpu.requestDevice") {
  Test.it("returns a Device with a backend in info") {
    var device = Gpu.requestDevice()
    Expect.that(device is Device).toBe(true)

    var info = device.info
    Expect.that(info["name"]).not.toBeNull()
    Expect.that(info["backend"]).not.toBeNull()
    Expect.that(info["deviceType"]).not.toBeNull()

    device.destroy
  }

  Test.it("honours the powerPreference descriptor key") {
    // We can't assert which adapter wins (depends on host hardware),
    // but the call must succeed without aborting.
    var device = Gpu.requestDevice({"powerPreference": "low-power"})
    Expect.that(device.info["backend"]).not.toBeNull()
    device.destroy
  }
}

Test.describe("Device.createBuffer") {
  Test.it("allocates a buffer with the requested size + usage") {
    var device = Gpu.requestDevice()
    var buf = device.createBuffer({
      "size":  256,
      "usage": ["uniform", "copy-dst"],
      "label": "spec-uniforms"
    })
    Expect.that(buf is Buffer).toBe(true)
    Expect.that(buf.size).toBe(256)
    buf.destroy
    device.destroy
  }

  Test.it("rejects unaligned sizes") {
    var device = Gpu.requestDevice()
    var e = Fiber.new {
      device.createBuffer({"size": 7, "usage": ["copy-dst"]})
    }.try()
    Expect.that(e).toContain("aligned")
    device.destroy
  }

  Test.it("rejects unknown usage flags") {
    var device = Gpu.requestDevice()
    var e = Fiber.new {
      device.createBuffer({"size": 16, "usage": ["bogus"]})
    }.try()
    Expect.that(e).toContain("unknown usage flag")
    device.destroy
  }
}

Test.describe("Buffer.writeFloats / writeUints") {
  Test.it("scalar list writes complete without error") {
    var device = Gpu.requestDevice()
    var buf = device.createBuffer({
      "size":  64,
      "usage": ["uniform", "copy-dst"]
    })
    buf.writeFloats(0, [1.0, 2.0, 3.0, 4.0])
    buf.writeUints(16, [42, 7, 0, 0])
    buf.destroy
    device.destroy
  }

  Test.it("element-type errors abort with a useful message") {
    var device = Gpu.requestDevice()
    var buf = device.createBuffer({
      "size":  16,
      "usage": ["uniform", "copy-dst"]
    })
    var e = Fiber.new {
      buf.writeFloats(0, ["not-a-number"])
    }.try()
    Expect.that(e).toContain("must be a number")
    buf.destroy
    device.destroy
  }
}

Test.describe("Buffer batched math writes") {
  Test.it("writeMat4s packs each Mat4.data as 16 f32") {
    var device = Gpu.requestDevice()
    var buf = device.createBuffer({
      "size":  128,
      "usage": ["uniform", "copy-dst"]
    })
    var mats = [Mat4.identity, Mat4.translation(1, 2, 3)]
    buf.writeMat4s(0, mats)
    buf.destroy
    device.destroy
  }

  Test.it("writeVec3s rejects wrong arity") {
    var device = Gpu.requestDevice()
    var buf = device.createBuffer({
      "size":  64,
      "usage": ["uniform", "copy-dst"]
    })
    var e = Fiber.new {
      buf.writeVec3s(0, [Vec4.new(1, 2, 3, 4)])  // 4 components, not 3
    }.try()
    Expect.that(e).toContain("expected 3")
    buf.destroy
    device.destroy
  }

  Test.it("writeVec4s + writeQuats accept matching arities") {
    var device = Gpu.requestDevice()
    var buf = device.createBuffer({
      "size":  256,
      "usage": ["uniform", "copy-dst"]
    })
    buf.writeVec3s(0,  [Vec3.new(1, 2, 3), Vec3.new(4, 5, 6)])
    buf.writeVec4s(32, [Vec4.new(0.1, 0.2, 0.3, 1.0)])
    buf.writeQuats(64, [Quat.fromAxisAngle(Vec3.unitY, 1.5708)])
    buf.destroy
    device.destroy
  }
}

Test.run()
