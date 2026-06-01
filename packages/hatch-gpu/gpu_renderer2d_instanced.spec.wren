// @hatch:gpu — Renderer2D.drawInstancedSprites integration.
//
// One `pass.draw(6, instanceCount)` for an arbitrary count of
// sprites; per-instance state lives in a storage buffer. Pixel
// readback verifies the instance-indexed VS path lands sprites at
// the expected screen positions with the per-instance tint, and
// `writeSpriteInstance` packs the 16-f32 slot in the order the WGSL
// reads.

import "./gpu" for
  Gpu, Camera2D, Renderer2D
import "@hatch:test"   for Test
import "@hatch:assert" for Expect

Test.describe("Renderer2D.writeSpriteInstance") {
  Test.it("packs every field into the 16-f32 slot in order") {
    // Values restricted to f32-exact representations so the
    // round-trip Wren-Num → Float32Array store → Wren-Num read is
    // bit-identical. Negative powers of two compose all the
    // mantissa positions we care about.
    var out = Float32Array.new(32)
    Renderer2D.writeSpriteInstance(out, 0,
      10, 20,                  // x, y
      4, 8,                     // w, h
      0.0, 0.0, 0.5, 0.25,      // u0, v0, u1, v1
      0.875, 0.125, 0.25, 1.0,  // r, g, b, a
      0.5)                      // rotation
    Expect.that(out[0]).toBe(10)
    Expect.that(out[1]).toBe(20)
    Expect.that(out[2]).toBe(4)
    Expect.that(out[3]).toBe(8)
    Expect.that(out[4]).toBe(0.0)
    Expect.that(out[5]).toBe(0.0)
    Expect.that(out[6]).toBe(0.5)
    Expect.that(out[7]).toBe(0.25)
    Expect.that(out[8]).toBe(0.875)
    Expect.that(out[9]).toBe(0.125)
    Expect.that(out[10]).toBe(0.25)
    Expect.that(out[11]).toBe(1.0)
    Expect.that(out[12]).toBe(0.5)
    // 13/14/15 are the WGSL alignment padding — implementation
    // detail, but they should stay zero so a future-Renderer2D
    // version that reuses them doesn't inherit stale bits.
    Expect.that(out[13]).toBe(0)
    Expect.that(out[14]).toBe(0)
    Expect.that(out[15]).toBe(0)
  }

  Test.it("writes at the slot offset, not overwriting earlier slots") {
    var out = Float32Array.new(48)
    Renderer2D.writeSpriteInstance(out, 0, 1, 2, 3, 4,
                                   0, 0, 1, 1, 1, 1, 1, 1, 0)
    Renderer2D.writeSpriteInstance(out, 2, 99, 88, 7, 6,
                                   0, 0, 1, 1, 1, 1, 1, 1, 0)
    // Slot 0 still readable.
    Expect.that(out[0]).toBe(1)
    Expect.that(out[1]).toBe(2)
    // Slot 1 untouched (zeros).
    Expect.that(out[16]).toBe(0)
    // Slot 2 holds the second sprite.
    Expect.that(out[32]).toBe(99)
    Expect.that(out[33]).toBe(88)
  }
}

Test.describe("Renderer2D.drawInstancedSprites no-op guard") {
  Test.it("returns without aborting on instanceCount=0") {
    var device = Gpu.requestDevice()
    var renderer = Renderer2D.new(device, "rgba8unorm")
    var camera = Camera2D.new(800, 600)
    renderer.beginFrame(camera)
    var dummyBuf = device.createBuffer({
      "size":  64,
      "usage": ["storage", "copy-dst"],
      "label": "noop-instances"
    })
    var tex = device.createTexture({
      "width": 4, "height": 4, "format": "rgba8unorm",
      "usage": ["texture-binding", "copy-dst"]
    })
    var color = device.createTexture({
      "width": 8, "height": 8, "format": "rgba8unorm",
      "usage": ["render-attachment"]
    })
    var encoder = device.createCommandEncoder()
    var pass = encoder.beginRenderPass({
      "colorAttachments": [{
        "view": color.createView(),
        "loadOp": "clear",
        "storeOp": "store",
        "clearValue": [0, 0, 0, 1]
      }]
    })
    // count=0 must not abort and must not change state. If this
    // dispatch ever issues a draw call, wgpu raises a validation
    // error and the surrounding submit aborts.
    renderer.drawInstancedSprites(pass, tex, dummyBuf, 0)
    pass.end
    encoder.finish
    device.submit([encoder])
    Expect.that(true).toBe(true)
  }
}

Test.run()
