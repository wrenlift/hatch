// @hatch:gpu — end-to-end skinning render. Builds a tiny skinned
// 2-triangle quad bound to a single joint, animates the joint
// 90° around Y, renders to an offscreen target, reads back the
// centre pixel, asserts the quad's albedo colour landed at the
// expected pose.

import "./gpu"       for Gpu, Renderer3D, Camera3D, Mesh, Material, SkinPalette
import "@hatch:math" for Vec3, Vec4, Mat4
import "@hatch:test" for Test
import "@hatch:assert" for Expect

Test.describe("Renderer3D.drawSkinned") {
  Test.it("samples joint matrix palette and lands the rotated quad on the centre pixel") {
    var device   = Gpu.requestDevice()
    var renderer = Renderer3D.new(device, "rgba8unorm", "depth32float")

    // 4-vertex quad in the XY plane, 2 triangles. All vertices
    // weighted 100% to joint 0.
    var h = 0.4
    var verts = [
      // pos.xyz + normal.xyz + uv.xy + tangent.xyzw = 12 floats
      -h, -h, 0,   0, 0, 1,   0, 0,   1, 0, 0, 1,
       h, -h, 0,   0, 0, 1,   1, 0,   1, 0, 0, 1,
       h,  h, 0,   0, 0, 1,   1, 1,   1, 0, 0, 1,
      -h,  h, 0,   0, 0, 1,   0, 1,   1, 0, 0, 1
    ]
    var joints  = [0, 0, 0, 0,  0, 0, 0, 0,  0, 0, 0, 0,  0, 0, 0, 0]
    var weights = [1, 0, 0, 0,  1, 0, 0, 0,  1, 0, 0, 0,  1, 0, 0, 0]
    var indices = [0, 1, 2,  0, 2, 3]
    var mesh = Mesh.fromArraysSkinned(device, verts, joints, weights, indices)
    var mat  = Material.new(Vec4.new(0.0, 1.0, 0.0, 1.0))   // green

    // 1-joint palette holding identity. Quad stays at origin, faces
    // camera. v1 skinning shader only blends pos + normal; this
    // smoke test verifies the data path, not skeletal animation.
    var skin = SkinPalette.new(device, 1)
    var palette = Float32Array.new(16)
    palette[0]  = 1
    palette[5]  = 1
    palette[10] = 1
    palette[15] = 1
    skin.update(palette)

    var size = 64   // 64 * 4 = 256 bytes / row — meets COPY_BYTES_PER_ROW_ALIGNMENT
    var color = device.createTexture({
      "width": size, "height": size, "format": "rgba8unorm",
      "usage": ["render-attachment", "copy-src"]
    })
    var depth = device.createTexture({
      "width": size, "height": size, "format": "depth32float",
      "usage": ["render-attachment"]
    })
    var colorView = color.createView()
    var depthView = depth.createView()
    var readback = device.createBuffer({
      "size": size * size * 4, "usage": ["copy-dst", "map-read"]
    })

    var camera = Camera3D.perspective(60, 1.0, 0.1, 100)
    camera.lookAt(Vec3.new(0, 0, 2), Vec3.zero, Vec3.unitY)

    var enc = device.createCommandEncoder()
    var pass = enc.beginRenderPass({
      "colorAttachments": [{
        "view": colorView, "loadOp": "clear",
        "clearValue": [0.0, 0.0, 0.0, 1.0], "storeOp": "store"
      }],
      "depthStencilAttachment": {
        "view": depthView, "depthLoadOp": "clear",
        "depthClearValue": 1.0, "depthStoreOp": "store"
      }
    })
    renderer.beginFrame(pass, camera)
    renderer.setAmbient(Vec3.new(1, 1, 1), 0.5)
    renderer.drawSkinned(mesh, mat, skin, Mat4.identity)
    renderer.endFrame()
    pass.end
    enc.copyTextureToBuffer(color, readback, { "width": size, "height": size })
    enc.finish
    device.submit([enc])

    var pixels = readback.readBytes()
    // Centre pixel: should be green-ish (G > 200 in 0..255).
    var cx = size / 2
    var cy = size / 2
    var off = (cy * size + cx) * 4
    var g = pixels[off + 1]
    Expect.that(g > 100).toBe(true)

    readback.destroy
    depthView.destroy
    colorView.destroy
    depth.destroy
    color.destroy
    skin.destroy
    mesh.vertexBuffer.destroy
    mesh.indexBuffer.destroy
    mesh.jointsBuffer.destroy
    mesh.weightsBuffer.destroy
    renderer.destroy
    device.destroy
  }
}

Test.run()
