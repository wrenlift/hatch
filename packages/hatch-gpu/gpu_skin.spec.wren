// @hatch:gpu — SkinPalette + Mesh.fromArraysSkinned smoke tests.

import "./gpu"       for Gpu, SkinPalette, Mesh
import "@hatch:test" for Test
import "@hatch:assert" for Expect

Test.describe("SkinPalette") {
  Test.it("aborts on jointCount <= 0") {
    var device = Gpu.requestDevice()
    var fiber = Fiber.new { SkinPalette.new(device, 0) }
    Expect.that(fiber.try() is String).toBe(true)
    device.destroy
  }

  Test.it("allocates a storage buffer sized jointCount * 64 bytes") {
    var device = Gpu.requestDevice()
    var p = SkinPalette.new(device, 32)
    Expect.that(p.jointCount).toBe(32)
    Expect.that(p.buffer).not.toBe(null)
    Expect.that(p.bindGroup).toBe(null)   // lazy
    p.destroy
    device.destroy
  }

  Test.it("update accepts a Float32Array of jointCount*16 floats") {
    var device = Gpu.requestDevice()
    var p = SkinPalette.new(device, 4)
    var palette = Float32Array.new(4 * 16)
    // identity per joint
    var j = 0
    while (j < 4) {
      var b = j * 16
      palette[b + 0]  = 1
      palette[b + 5]  = 1
      palette[b + 10] = 1
      palette[b + 15] = 1
      j = j + 1
    }
    p.update(palette)
    p.destroy
    device.destroy
  }
}

Test.describe("Mesh.fromArraysSkinned") {
  Test.it("attaches joints + weights VBOs alongside the static VBO") {
    var device = Gpu.requestDevice()
    // 3 vertices, minimal triangle. Static layout = 12 floats /
    // vertex (pos.xyz + normal.xyz + uv.xy + tangent.xyzw).
    var V = 3
    var verts = []
    var i = 0
    while (i < V * 12) {
      verts.add(0)
      i = i + 1
    }
    var joints  = [0, 0, 0, 0,  1, 0, 0, 0,  2, 0, 0, 0]
    var weights = [1.0, 0, 0, 0,  1.0, 0, 0, 0,  1.0, 0, 0, 0]
    var indices = [0, 1, 2]
    var mesh = Mesh.fromArraysSkinned(device, verts, joints, weights, indices)
    Expect.that(mesh.vertexBuffer).not.toBe(null)
    Expect.that(mesh.jointsBuffer).not.toBe(null)
    Expect.that(mesh.weightsBuffer).not.toBe(null)
    Expect.that(mesh.indexCount).toBe(3)
    mesh.vertexBuffer.destroy
    mesh.indexBuffer.destroy
    mesh.jointsBuffer.destroy
    mesh.weightsBuffer.destroy
    device.destroy
  }

  Test.it("fromArrays leaves the skin VBOs as null on static meshes") {
    var device = Gpu.requestDevice()
    var mesh = Mesh.cube(device)
    Expect.that(mesh.jointsBuffer).toBe(null)
    Expect.that(mesh.weightsBuffer).toBe(null)
    mesh.vertexBuffer.destroy
    mesh.indexBuffer.destroy
    device.destroy
  }
}

Test.run()
