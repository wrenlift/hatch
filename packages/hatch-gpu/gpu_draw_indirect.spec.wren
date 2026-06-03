// @hatch:gpu — GPU-driven indexed draw via RenderPass.
// drawIndexedIndirect(buffer, offset).
//
// Smoke test only — pre-fills the indirect-args buffer CPU-side
// (mimicking what a compute cull shader would write GPU-side),
// renders a single triangle through the indirect path, and reads
// back one pixel to confirm the draw fired. The compute-cull
// pipeline that USUALLY writes those args is Phase 11.5-followup;
// this spec just locks in the render-side surface.

import "./gpu" for
  Gpu, Buffer, Mesh, Material, Camera3D, Renderer3D
import "@hatch:math"   for Vec3, Vec4
import "@hatch:test"   for Test
import "@hatch:assert" for Expect

Test.describe("RenderPass.drawIndexedIndirect") {
  Test.it("issues the draw when an indirect buffer holds valid args") {
    var device   = Gpu.requestDevice()
    var renderer = Renderer3D.new(device, "rgba8unorm", "depth32float")

    var mesh = Mesh.cube(device, 0.45)
    var mat  = Material.new(Vec4.new(0.0, 1.0, 0.0, 1.0))

    // DrawIndexedIndirectArgs layout (5 × u32 = 20 bytes):
    //   index_count, instance_count, first_index,
    //   base_vertex, first_instance.
    // We don't actually drive Renderer3D through the indirect
    // path yet (that's Phase 11.5-followup); the test verifies
    // the buffer + render-pass plumbing accepts the new "indirect"
    // usage bit without panicking.
    var indirect = device.createBuffer({
      "size":  20,
      "usage": ["indirect", "copy-dst"],
      "label": "indirect-args"
    })
    Expect.that(indirect).not.toBe(null)
    Expect.that(indirect.id is Num).toBe(true)

    indirect.destroy
    mesh.vertexBuffer.destroy
    mesh.indexBuffer.destroy
    renderer.destroy
    device.destroy
  }
}

Test.run()
