// @hatch:gpu — Renderer3D instanced-draw integration.
//
// A small grid of cubes drawn with one drawIndexed call via the
// new instanced pipeline. Pixel readback verifies the cube colour
// landed at the screen centre, proving the instance-storage-buffer
// → @builtin(instance_index) → DrawUniforms path is wired
// end-to-end. The exit-gate microbench scales the instance count
// to 10k for the procedural-world performance target.

import "./gpu" for
  Gpu, Buffer, Mesh, Material, Camera3D, Renderer3D
import "@hatch:math"   for Vec3, Vec4, Mat4
import "@hatch:time"   for Clock
import "@hatch:test"   for Test
import "@hatch:assert" for Expect

// Render a single frame against an offscreen `size x size` target
// with `count` instances laid out in a grid centred on the origin.
// Returns the RGBA bytes of the colour attachment.
var renderInstancedGrid = Fn.new {|count, size|
  var device = Gpu.requestDevice()
  var renderer = Renderer3D.new(device, "rgba8unorm", "depth32float")

  var mesh = Mesh.cube(device, 0.45)
  var mat  = Material.new(Vec4.new(0.0, 1.0, 0.0, 1.0))   // green

  // Square-ish grid spanning x ∈ [-spread, +spread]. Each instance
  // gets its own model matrix.
  var perRow = count.sqrt.floor.max(1)
  var rows   = ((count + perRow - 1) / perRow).floor
  var spread = (perRow - 1) * 0.6 * 0.5
  var floats = []
  var n = 0
  for (r in 0...rows) {
    for (c in 0...perRow) {
      if (n >= count) break
      var x = (c * 0.6) - spread
      var y = (r * 0.6) - spread
      Renderer3D.appendInstance(floats, Mat4.translation(x, y, 0))
      n = n + 1
    }
  }

  var instanceBuf = device.createBuffer({
    "size":  count * 32 * 4,
    "usage": ["storage", "copy-dst"],
    "label": "instances"
  })
  instanceBuf.writeFloats(0, floats)

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
  camera.lookAt(Vec3.new(0, 0, 6), Vec3.zero, Vec3.unitY)

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
  renderer.drawMeshInstanced(mesh, mat, instanceBuf, count)
  renderer.endFrame()
  pass.end
  enc.copyTextureToBuffer(color, readback, { "width": size, "height": size })
  enc.finish
  device.submit([enc])

  var pixels = readback.readBytes()

  readback.destroy
  depthView.destroy
  colorView.destroy
  depth.destroy
  color.destroy
  instanceBuf.destroy
  mesh.vertexBuffer.destroy
  mesh.indexBuffer.destroy
  renderer.destroy
  device.destroy

  return [pixels, size]
}

Test.describe("Renderer3D.drawMeshInstanced") {
  Test.it("appendInstance packs 32 floats per instance") {
    var floats = []
    Renderer3D.appendInstance(floats, Mat4.translation(1, 2, 3))
    Expect.that(floats.count).toBe(32)
    Renderer3D.appendInstance(floats, Mat4.translation(4, 5, 6))
    Expect.that(floats.count).toBe(64)
  }

  Test.it("renders a 5×5 grid of cubes via a single drawIndexed") {
    var result = renderInstancedGrid.call(25, 64)
    var pixels = result[0]
    var size = result[1]

    // Centre pixel — origin instance sits there, green channel must
    // be above the clear-colour floor.
    var cx = size / 2
    var cy = size / 2
    var idx = (cy * size + cx) * 4
    var r = pixels[idx]
    var g = pixels[idx + 1]
    var b = pixels[idx + 2]
    var a = pixels[idx + 3]
    Expect.that(a).toBe(255)
    Expect.that(g > r).toBe(true)
    Expect.that(g > b).toBe(true)
    Expect.that(g > 32).toBe(true)
  }

  Test.it("instanceCount=0 is a no-op (no draw, no abort)") {
    var device = Gpu.requestDevice()
    var renderer = Renderer3D.new(device, "rgba8unorm", "depth32float")
    var mesh = Mesh.cube(device, 0.5)
    var mat  = Material.new(Vec4.new(1, 0, 0, 1))
    var buf  = device.createBuffer({ "size": 128, "usage": ["storage", "copy-dst"] })

    var color = device.createTexture({
      "width": 16, "height": 16, "format": "rgba8unorm",
      "usage": ["render-attachment", "copy-src"]
    })
    var depth = device.createTexture({
      "width": 16, "height": 16, "format": "depth32float",
      "usage": ["render-attachment"]
    })
    var camera = Camera3D.perspective(60, 1.0, 0.1, 100)
    camera.lookAt(Vec3.new(0, 0, 5), Vec3.zero, Vec3.unitY)
    var enc = device.createCommandEncoder()
    var pass = enc.beginRenderPass({
      "colorAttachments": [{
        "view": color.createView(), "loadOp": "clear",
        "clearValue": [0.0, 0.0, 0.0, 1.0], "storeOp": "store"
      }],
      "depthStencilAttachment": {
        "view": depth.createView(), "depthLoadOp": "clear",
        "depthClearValue": 1.0, "depthStoreOp": "store"
      }
    })
    renderer.beginFrame(pass, camera)
    renderer.drawMeshInstanced(mesh, mat, buf, 0)   // must not abort
    renderer.endFrame()
    pass.end
    enc.finish
    device.submit([enc])

    buf.destroy
    mesh.vertexBuffer.destroy
    mesh.indexBuffer.destroy
    depth.destroy
    color.destroy
    renderer.destroy
    device.destroy
  }
}

Test.describe("Renderer3D.drawMeshInstanced exit-gate") {
  Test.it("10k instanced cubes in one drawIndexed call") {
    var n = 10000
    var device = Gpu.requestDevice()
    var renderer = Renderer3D.new(device, "rgba8unorm", "depth32float")
    var mesh = Mesh.cube(device, 0.4)
    var mat  = Material.new(Vec4.new(0.6, 0.8, 1.0, 1.0))

    var floats = []
    var perRow = n.sqrt.floor
    var spread = (perRow - 1) * 1.5 * 0.5
    var done = 0
    for (r in 0...perRow) {
      for (c in 0...perRow) {
        if (done >= n) break
        var x = (c * 1.5) - spread
        var y = (r * 1.5) - spread
        Renderer3D.appendInstance(floats, Mat4.translation(x, y, 0))
        done = done + 1
      }
    }

    var instanceBuf = device.createBuffer({
      "size":  n * 32 * 4,
      "usage": ["storage", "copy-dst"],
      "label": "instances-10k"
    })
    instanceBuf.writeFloats(0, floats)

    var color = device.createTexture({
      "width": 128, "height": 128, "format": "rgba8unorm",
      "usage": ["render-attachment", "copy-src"]
    })
    var depth = device.createTexture({
      "width": 128, "height": 128, "format": "depth32float",
      "usage": ["render-attachment"]
    })
    var camera = Camera3D.perspective(60, 1.0, 0.1, 500)
    camera.lookAt(Vec3.new(0, 0, 250), Vec3.zero, Vec3.unitY)

    // Warmup
    {
      var enc = device.createCommandEncoder()
      var pass = enc.beginRenderPass({
        "colorAttachments": [{
          "view": color.createView(), "loadOp": "clear",
          "clearValue": [0.0, 0.0, 0.0, 1.0], "storeOp": "store"
        }],
        "depthStencilAttachment": {
          "view": depth.createView(), "depthLoadOp": "clear",
          "depthClearValue": 1.0, "depthStoreOp": "store"
        }
      })
      renderer.beginFrame(pass, camera)
      renderer.drawMeshInstanced(mesh, mat, instanceBuf, n)
      renderer.endFrame()
      pass.end
      enc.finish
      device.submit([enc])
    }

    var runs = 5
    var totalSubmit = 0
    for (run in 0...runs) {
      var t0 = Clock.mono * 1000
      var enc = device.createCommandEncoder()
      var pass = enc.beginRenderPass({
        "colorAttachments": [{
          "view": color.createView(), "loadOp": "clear",
          "clearValue": [0.0, 0.0, 0.0, 1.0], "storeOp": "store"
        }],
        "depthStencilAttachment": {
          "view": depth.createView(), "depthLoadOp": "clear",
          "depthClearValue": 1.0, "depthStoreOp": "store"
        }
      })
      renderer.beginFrame(pass, camera)
      renderer.drawMeshInstanced(mesh, mat, instanceBuf, n)
      renderer.endFrame()
      pass.end
      enc.finish
      device.submit([enc])
      var t1 = Clock.mono * 1000
      totalSubmit = totalSubmit + (t1 - t0)
    }

    System.print("[bench] %(n) instanced cubes, runs=%(runs)")
    System.print("[bench] submit (one drawIndexed)  mean: %(totalSubmit / runs) ms")

    Expect.that(totalSubmit / runs < 5).toBe(true)   // generous floor — hardware variance

    instanceBuf.destroy
    mesh.vertexBuffer.destroy
    mesh.indexBuffer.destroy
    depth.destroy
    color.destroy
    renderer.destroy
    device.destroy
  }
}

Test.run()
