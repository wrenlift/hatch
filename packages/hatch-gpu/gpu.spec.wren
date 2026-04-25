// @hatch:gpu — phase 1 acceptance test.
//
// Headless device request is the most basic exercise: prove the
// dylib loads, the adapter is discoverable, and the Wren wrapper
// hands back a valid id with sane metadata. Higher-level passes
// (buffer, texture, shader, render-to-texture readback) are added
// as the foreign surface grows.

import "./gpu"         for Gpu, Device
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

Test.run()
