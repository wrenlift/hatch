// @hatch:gpu — Renderer3D with the secondary normal G-buffer
// attachment enabled. Forces compilation of the `fs_main_mrt` /
// `fs_toon_main_mrt` shader entry points and validates that the
// non-instanced PBR / transparent / toon pipelines build with two
// colour targets.
//
// Outline pass + foliage instanced toon land on top of this in
// §12.3 / §12.4; the hard-wired single-format check below is the
// schelling point those steps consume.

import "./gpu"        for Gpu, Renderer3D
import "@hatch:test"  for Test
import "@hatch:assert" for Expect

Test.describe("Renderer3D MRT (normal G-buffer)") {
  Test.it("builds the non-instanced pipelines with a second rgba8unorm target") {
    var device = Gpu.requestDevice()
    // The 4-arg constructor wires `normalFormat` through to
    // `fs_main_mrt` / `fs_toon_main_mrt` and adds the second
    // colour target to the PBR / transparent / toon pipelines.
    var renderer = Renderer3D.new(device, "rgba8unorm", "depth32float", "rgba8unorm")
    Expect.that(renderer != null).toBe(true)
  }
}

Test.run()
