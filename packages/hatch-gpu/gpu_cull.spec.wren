// @hatch:gpu — ComputeCull smoke test.
//
// Builds a tiny 4-instance scene with 2 spheres inside the
// frustum and 2 well outside, dispatches the cull compute pass,
// reads back the DrawIndexedIndirectArgs buffer, and asserts the
// `instance_count` slot landed at 2.

import "./gpu"       for Gpu, Buffer, Mesh, Camera3D, Renderer3D, ComputeCull
import "@hatch:math" for Vec3, Mat4
import "@hatch:test" for Test
import "@hatch:assert" for Expect

Test.describe("ComputeCull") {
  Test.it("compacts instances inside the camera frustum, sets instance_count") {
    var device = Gpu.requestDevice()
    var mesh   = Mesh.cube(device, 0.5)
    var cull   = ComputeCull.new(device)

    // 4 instances: two at origin (visible), two far behind the
    // camera (clipped by the near plane).
    var count = 4
    var spheresBuf = ComputeCull.createSphereBuffer(device, count)
    var srcInstBuf = device.createBuffer({
      "size":  count * 128,
      "usage": ["storage", "copy-dst"],
      "label": "cull-src-inst"
    })
    var planesBuf  = ComputeCull.createFrustumBuffer(device)
    var indirect   = ComputeCull.createIndirectBuffer(device)
    var outInstBuf = ComputeCull.createOutputInstanceBuffer(device, count)

    // Bounding spheres: 4 × vec4(cx, cy, cz, radius).
    // Camera looks down -Z from (0, 0, 5); near plane ~0.1 in front.
    // Visible instances at z=0 (in view); culled at z=+100 (behind
    // the camera, far outside near-plane).
    var spheres = [
       0, 0, 0, 0.5,   // visible
       1, 0, 0, 0.5,   // visible
       0, 0, 100, 0.5, // BEHIND camera — clipped by far plane
      10, 0, 100, 0.5  // BEHIND camera — clipped
    ]
    spheresBuf.writeFloats(0, spheres)

    // Source instance buffer — content doesn't matter for this
    // smoke test; just needs to exist at the right stride. Fill
    // with identity matrices.
    var srcFloats = []
    var n = 0
    while (n < count) {
      Renderer3D.appendInstance(srcFloats, Mat4.identity)
      n = n + 1
    }
    srcInstBuf.writeFloats(0, srcFloats)

    // Camera at (0,0,5) looking at origin, aspect 1, near 0.1, far 50.
    var cam = Camera3D.perspective(60, 1.0, 0.1, 50)
    cam.lookAt(Vec3.new(0, 0, 5), Vec3.zero, Vec3.unitY)
    planesBuf.writeFloats(0, cam.frustumPlanes)

    ComputeCull.initIndirectArgs(indirect, mesh)

    var enc = device.createCommandEncoder()
    cull.cull(enc, spheresBuf, srcInstBuf, count, planesBuf, indirect, outInstBuf)

    // Stage the indirect-args back to CPU. Need a separate
    // copy-dst + map-read buffer.
    var readback = device.createBuffer({
      "size":  ComputeCull.INDIRECT_BYTES,
      "usage": ["copy-dst", "map-read"],
      "label": "cull-readback"
    })
    enc.copyBufferToBuffer(indirect, readback, ComputeCull.INDIRECT_BYTES)
    enc.finish
    device.submit([enc])

    var bytes = readback.readBytes()
    // u32 little-endian at byte offset 4: instance_count.
    var instCount = bytes[4] | (bytes[5] << 8) | (bytes[6] << 16) | (bytes[7] << 24)
    Expect.that(instCount).toBe(2)

    readback.destroy
    outInstBuf.destroy
    indirect.destroy
    planesBuf.destroy
    srcInstBuf.destroy
    spheresBuf.destroy
    cull.destroy
    mesh.vertexBuffer.destroy
    mesh.indexBuffer.destroy
    device.destroy
  }
}

Test.run()
