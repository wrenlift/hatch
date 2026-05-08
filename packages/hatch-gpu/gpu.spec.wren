// @hatch:gpu acceptance tests.
//
// Walks every public class — device discovery, buffer lifecycle,
// scalar + math-batched buffer writes, shader compilation,
// texture / view / sampler construction, and the full headless
// render path: a fullscreen-triangle pass and an indexed cube
// with uniform + depth, both verified through pixel readback.

import "./gpu" for
  Gpu, Device, Buffer, ShaderModule, Texture, TextureView, Sampler,
  BindGroupLayout, BindGroup, PipelineLayout, RenderPipeline,
  CommandEncoder, RenderPass, LivePipeline
import "@hatch:math"   for Vec3, Vec4, Mat4, Quat
import "@hatch:assets" for Assets
import "@hatch:fs"     for Fs
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

  Test.it("writeFloats accepts a Float32Array (memcpy fast path)") {
    var device = Gpu.requestDevice()
    var buf = device.createBuffer({
      "size":  32,
      "usage": ["uniform", "copy-dst"]
    })
    var data = Float32Array.fromList([1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0])
    buf.writeFloats(0, data)
    buf.destroy
    device.destroy
  }

  Test.it("writeFloatsN uploads only the first count floats") {
    var device = Gpu.requestDevice()
    var buf = device.createBuffer({
      "size":  64,
      "usage": ["uniform", "copy-dst"]
    })
    var data = Float32Array.new(16)
    var i = 0
    while (i < 8) {
      data[i] = i + 1
      i = i + 1
    }
    // Only the first 8 lanes should be uploaded; the trailing
    // zeros stay out of the buffer entirely.
    buf.writeFloatsN(0, data, 8)
    buf.destroy
    device.destroy
  }

  Test.it("writeFloatsN rejects out-of-range count") {
    var device = Gpu.requestDevice()
    var buf = device.createBuffer({
      "size":  16,
      "usage": ["uniform", "copy-dst"]
    })
    var data = Float32Array.new(4)
    var e = Fiber.new {
      buf.writeFloatsN(0, data, 8)
    }.try()
    Expect.that(e).toContain("exceeds Float32Array length")
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

Test.describe("ShaderModule + Texture + Sampler") {
  Test.it("compiles a trivial WGSL shader") {
    var device = Gpu.requestDevice()
    var sm = device.createShaderModule({
      "code": "
        @vertex fn vs_main(@builtin(vertex_index) i: u32) -> @builtin(position) vec4<f32> {
          return vec4<f32>(0.0, 0.0, 0.0, 1.0);
        }
        @fragment fn fs_main() -> @location(0) vec4<f32> {
          return vec4<f32>(1.0, 0.0, 0.0, 1.0);
        }
      ",
      "label": "spec-trivial"
    })
    Expect.that(sm is ShaderModule).toBe(true)
    sm.destroy
    device.destroy
  }

  Test.it("creates a 2D texture and a default view") {
    var device = Gpu.requestDevice()
    var tex = device.createTexture({
      "width": 16, "height": 16,
      "format": "rgba8unorm",
      "usage": ["render-attachment", "copy-src"],
      "label": "spec-target"
    })
    Expect.that(tex is Texture).toBe(true)
    Expect.that(tex.width).toBe(16)
    Expect.that(tex.height).toBe(16)
    Expect.that(tex.format).toBe("rgba8unorm")

    var view = tex.createView()
    Expect.that(view is TextureView).toBe(true)
    view.destroy
    tex.destroy
    device.destroy
  }

  Test.it("rejects unknown formats") {
    var device = Gpu.requestDevice()
    var e = Fiber.new {
      device.createTexture({"width": 8, "height": 8, "format": "bogus", "usage": ["copy-src"]})
    }.try()
    Expect.that(e).toContain("unknown format")
    device.destroy
  }

  Test.it("creates a sampler with default config") {
    var device = Gpu.requestDevice()
    var s = device.createSampler({})
    Expect.that(s is Sampler).toBe(true)
    s.destroy
    device.destroy
  }
}

Test.describe("Render to texture + readback") {
  // Headless render path: render pass → texture, copy texture →
  // mappable buffer, map-and-read on the host. Validates the
  // entire pipeline (encoder, render pass, copy, queue submit,
  // sync map) end to end.
  //
  // Texture is 64×64 RGBA8 (256 bytes per row, exactly the
  // wgpu::COPY_BYTES_PER_ROW_ALIGNMENT). Smaller targets need
  // explicit padding which the spec doesn't bother with yet.

  Test.it("clears to magenta and reads back exact pixel values") {
    var device = Gpu.requestDevice()
    var target = device.createTexture({
      "width": 64, "height": 64,
      "format": "rgba8unorm",
      "usage": ["render-attachment", "copy-src"],
      "label": "spec-target"
    })
    var view = target.createView()

    var readback = device.createBuffer({
      "size":  16384,
      "usage": ["copy-dst", "map-read"],
      "label": "spec-readback"
    })

    var encoder = device.createCommandEncoder()
    var pass = encoder.beginRenderPass({
      "colorAttachments": [{
        "view": view,
        "loadOp": "clear",
        "clearValue": [1.0, 0.0, 1.0, 1.0],
        "storeOp": "store"
      }]
    })
    pass.end
    encoder.copyTextureToBuffer(target, readback, {"width": 64, "height": 64})
    encoder.finish
    device.submit([encoder])

    var pixels = readback.readBytes()
    Expect.that(pixels.count).toBe(16384)
    Expect.that(pixels[0]).toBe(255)
    Expect.that(pixels[1]).toBe(0)
    Expect.that(pixels[2]).toBe(255)
    Expect.that(pixels[3]).toBe(255)

    readback.destroy
    view.destroy
    target.destroy
    device.destroy
  }

  Test.it("renders a fullscreen-triangle shader to a green output") {
    var device = Gpu.requestDevice()

    // Vertex shader baked-in fullscreen triangle (no vertex buffer
    // needed). Fragment fills the screen with green. Reading back
    // the center pixel proves the pipeline + render pass executed
    // and produced new color, not the clear value.
    var wgsl = "
      @vertex
      fn vs_main(@builtin(vertex_index) vid: u32) -> @builtin(position) vec4<f32> {
        var p = array<vec2<f32>, 3>(
          vec2<f32>(-1.0, -1.0),
          vec2<f32>( 3.0, -1.0),
          vec2<f32>(-1.0,  3.0)
        );
        return vec4<f32>(p[vid], 0.0, 1.0);
      }
      @fragment
      fn fs_main() -> @location(0) vec4<f32> {
        return vec4<f32>(0.0, 1.0, 0.0, 1.0);
      }
    "

    var shader = device.createShaderModule({"code": wgsl, "label": "fullscreen-tri"})
    var pipeline = device.createRenderPipeline({
      "layout": "auto",
      "vertex":   { "module": shader, "entryPoint": "vs_main" },
      "fragment": { "module": shader, "entryPoint": "fs_main",
                    "targets": [{"format": "rgba8unorm"}] },
      "primitive": { "topology": "triangle-list" },
      "label": "spec-fullscreen"
    })

    var target = device.createTexture({
      "width": 64, "height": 64,
      "format": "rgba8unorm",
      "usage": ["render-attachment", "copy-src"]
    })
    var view = target.createView()
    var readback = device.createBuffer({
      "size":  16384,
      "usage": ["copy-dst", "map-read"]
    })

    var encoder = device.createCommandEncoder()
    var pass = encoder.beginRenderPass({
      "colorAttachments": [{
        "view": view,
        "loadOp": "clear",
        "clearValue": [1.0, 0.0, 0.0, 1.0],   // red clear, fragment overrides
        "storeOp": "store"
      }]
    })
    pass.setPipeline(pipeline)
    pass.draw(3)
    pass.end
    encoder.copyTextureToBuffer(target, readback, {"width": 64, "height": 64})
    encoder.finish
    device.submit([encoder])

    var pixels = readback.readBytes()
    // Center of a 64x64 image: row 32, col 32. Bytes per row = 256
    // (already aligned), so the pixel index is 32*256 + 32*4 = 8320.
    Expect.that(pixels[8320]).toBe(0)     // R (red clear was overdrawn)
    Expect.that(pixels[8321]).toBe(255)   // G
    Expect.that(pixels[8322]).toBe(0)     // B
    Expect.that(pixels[8323]).toBe(255)   // A

    readback.destroy
    view.destroy
    target.destroy
    pipeline.destroy
    shader.destroy
    device.destroy
  }
}

Test.describe("Indexed cube with uniform + depth") {
  // 3D integration test. Exercises:
  //   - Vertex buffer with position+color attribute layout
  //   - Index buffer (uint16)
  //   - Uniform buffer + BindGroupLayout + BindGroup + PipelineLayout
  //   - Mat4.perspective × Mat4.lookAt × Mat4 chain via writeMat4s
  //   - Depth attachment + back-face culling
  //
  // Asserts the center pixel is something other than the clear
  // color — proof that the cube actually rendered through the MVP
  // chain rather than just inheriting the background.

  Test.it("renders an indexed cube and writes non-clear pixels into the center") {
    var device = Gpu.requestDevice()

    var wgsl = "
      struct Uniforms { mvp: mat4x4<f32> };
      @group(0) @binding(0) var<uniform> u: Uniforms;

      struct VsIn  { @location(0) pos: vec3<f32>, @location(1) col: vec3<f32> };
      struct VsOut { @builtin(position) clip: vec4<f32>, @location(0) col: vec3<f32> };

      @vertex
      fn vs_main(in: VsIn) -> VsOut {
        var o: VsOut;
        o.clip = u.mvp * vec4<f32>(in.pos, 1.0);
        o.col  = in.col;
        return o;
      }
      @fragment
      fn fs_main(in: VsOut) -> @location(0) vec4<f32> {
        return vec4<f32>(in.col, 1.0);
      }
    "
    var shader = device.createShaderModule({"code": wgsl, "label": "cube"})

    // 8 cube corners — each carries a unique color so the center
    // pixel is guaranteed non-zero regardless of which face is
    // visible.
    var verts = [
      -1, -1, -1, 1, 0, 0,
       1, -1, -1, 0, 1, 0,
       1,  1, -1, 0, 0, 1,
      -1,  1, -1, 1, 1, 0,
      -1, -1,  1, 1, 0, 1,
       1, -1,  1, 0, 1, 1,
       1,  1,  1, 1, 1, 1,
      -1,  1,  1, 0.5, 0.5, 0.5
    ]
    var indices = [
      0, 1, 2,  0, 2, 3,   // -Z
      4, 6, 5,  4, 7, 6,   // +Z
      0, 4, 5,  0, 5, 1,   // -Y
      3, 2, 6,  3, 6, 7,   // +Y
      0, 3, 7,  0, 7, 4,   // -X
      1, 5, 6,  1, 6, 2    // +X
    ]

    var vbuf = device.createBuffer({
      "size": verts.count * 4, "usage": ["vertex", "copy-dst"], "label": "cube-vbo"
    })
    vbuf.writeFloats(0, verts)

    // 36 uint32 indices = 144 bytes. Buffer.writeUints emits u32
    // per Num so the index format matches the storage; switch to
    // a uint16 path once a writeUint16s helper is in place.
    var ibuf = device.createBuffer({
      "size": indices.count * 4, "usage": ["index", "copy-dst"], "label": "cube-ibo"
    })
    ibuf.writeUints(0, indices)

    // MVP: perspective × lookAt × identity model.
    var proj  = Mat4.perspective(60.0 * 3.14159265 / 180.0, 1.0, 0.1, 50.0)
    var view  = Mat4.lookAt(Vec3.new(2.5, 2.5, 4.0), Vec3.zero, Vec3.unitY)
    var mvp   = proj * view

    var ubuf = device.createBuffer({
      "size":  64, "usage": ["uniform", "copy-dst"], "label": "cube-mvp"
    })
    ubuf.writeMat4s(0, [mvp])

    var bgl = device.createBindGroupLayout({
      "entries": [{
        "binding": 0, "visibility": ["vertex"], "kind": "uniform"
      }]
    })
    var bg = device.createBindGroup({
      "layout": bgl,
      "entries": [{ "binding": 0, "buffer": ubuf, "size": 64 }]
    })
    var pl = device.createPipelineLayout({"bindGroupLayouts": [bgl]})

    var pipeline = device.createRenderPipeline({
      "layout": pl,
      "vertex": {
        "module": shader, "entryPoint": "vs_main",
        "buffers": [{
          "arrayStride": 24, "stepMode": "vertex",
          "attributes": [
            { "shaderLocation": 0, "offset": 0,  "format": "float32x3" },
            { "shaderLocation": 1, "offset": 12, "format": "float32x3" }
          ]
        }]
      },
      "fragment": { "module": shader, "entryPoint": "fs_main",
                    "targets": [{"format": "rgba8unorm"}] },
      "primitive": { "topology": "triangle-list", "cullMode": "back" },
      "depthStencil": { "format": "depth32float", "depthWriteEnabled": true,
                        "depthCompare": "less" },
      "label": "cube-pipeline"
    })

    var color = device.createTexture({
      "width": 64, "height": 64, "format": "rgba8unorm",
      "usage": ["render-attachment", "copy-src"]
    })
    var depth = device.createTexture({
      "width": 64, "height": 64, "format": "depth32float",
      "usage": ["render-attachment"]
    })
    var colorView = color.createView()
    var depthView = depth.createView()
    var readback = device.createBuffer({"size": 16384, "usage": ["copy-dst", "map-read"]})

    var encoder = device.createCommandEncoder()
    var pass = encoder.beginRenderPass({
      "colorAttachments": [{
        "view": colorView,
        "loadOp": "clear",
        "clearValue": [0.0, 0.0, 0.0, 1.0],
        "storeOp": "store"
      }],
      "depthStencilAttachment": {
        "view": depthView,
        "depthLoadOp":     "clear",
        "depthClearValue": 1.0,
        "depthStoreOp":    "store"
      }
    })
    pass.setPipeline(pipeline)
    pass.setBindGroup(0, bg)
    pass.setVertexBuffer(0, vbuf)
    pass.setIndexBuffer(ibuf, "uint32")
    pass.drawIndexed(36)
    pass.end
    encoder.copyTextureToBuffer(color, readback, {"width": 64, "height": 64})
    encoder.finish
    device.submit([encoder])

    var pixels = readback.readBytes()
    // Center pixel — same indexing as the triangle test.
    var r = pixels[8320]
    var g = pixels[8321]
    var b = pixels[8322]
    var a = pixels[8323]
    Expect.that(a).toBe(255)
    // Cube was lit by per-vertex colors; the center pixel must
    // have at least one channel above the clear color (0).
    Expect.that(r + g + b > 0).toBe(true)

    // Cleanup
    readback.destroy
    depthView.destroy
    colorView.destroy
    depth.destroy
    color.destroy
    pipeline.destroy
    pl.destroy
    bg.destroy
    bgl.destroy
    ubuf.destroy
    ibuf.destroy
    vbuf.destroy
    shader.destroy
    device.destroy
  }
}

Test.describe("LivePipeline shader hot reload") {
  Test.it("rebuilds the pipeline when the shader asset's hash changes") {
    // Stage shader v1 in a scratch dir, build a LivePipeline,
    // render once. Edit the shader on disk to v2 (different
    // fragment colour), trigger the assets-db handler the way
    // the SIGUSR1 path would, render again. Pixel readback must
    // show the new colour — proof the pipeline rebuilt with the
    // new code, not against the cached v1.

    var root = Fs.tmpDir + "/hatch-gpu-livepipeline"
    if (Fs.isDir(root)) Fs.removeTree(root)
    Fs.mkdirs(root + "/shaders")

    var v1 = "
      @vertex
      fn vs_main(@builtin(vertex_index) vid: u32) -> @builtin(position) vec4<f32> {
        var p = array<vec2<f32>, 3>(
          vec2<f32>(-1.0, -1.0),
          vec2<f32>( 3.0, -1.0),
          vec2<f32>(-1.0,  3.0)
        );
        return vec4<f32>(p[vid], 0.0, 1.0);
      }
      @fragment fn fs_main() -> @location(0) vec4<f32> {
        return vec4<f32>(1.0, 0.0, 0.0, 1.0);
      }
    "
    Fs.writeText(root + "/shaders/triangle.wgsl", v1)

    var device = Gpu.requestDevice()
    var assets = Assets.open(root)
    var pipeline = LivePipeline.new(device, assets, "shaders/triangle.wgsl", {
      "layout": "auto",
      "vertex":   { "entryPoint": "vs_main" },
      "fragment": { "entryPoint": "fs_main",
                    "targets": [{"format": "rgba8unorm"}] },
      "primitive": { "topology": "triangle-list" }
    })

    var renderOnce = Fn.new {
      var target = device.createTexture({
        "width": 64, "height": 64, "format": "rgba8unorm",
        "usage": ["render-attachment", "copy-src"]
      })
      var view = target.createView()
      var readback = device.createBuffer({"size": 16384, "usage": ["copy-dst", "map-read"]})
      var enc = device.createCommandEncoder()
      var pass = enc.beginRenderPass({
        "colorAttachments": [{
          "view": view,
          "loadOp": "clear",
          "clearValue": [0.0, 0.0, 0.0, 1.0],
          "storeOp": "store"
        }]
      })
      pass.setPipeline(pipeline)
      pass.draw(3)
      pass.end
      enc.copyTextureToBuffer(target, readback, {"width": 64, "height": 64})
      enc.finish
      device.submit([enc])
      var pixels = readback.readBytes()
      var rgba = [pixels[8320], pixels[8321], pixels[8322], pixels[8323]]
      readback.destroy
      view.destroy
      target.destroy
      return rgba
    }

    var first = renderOnce.call()
    Expect.that(first[0]).toBe(255)
    Expect.that(first[1]).toBe(0)
    Expect.that(first[2]).toBe(0)

    var v2 = "
      @vertex
      fn vs_main(@builtin(vertex_index) vid: u32) -> @builtin(position) vec4<f32> {
        var p = array<vec2<f32>, 3>(
          vec2<f32>(-1.0, -1.0),
          vec2<f32>( 3.0, -1.0),
          vec2<f32>(-1.0,  3.0)
        );
        return vec4<f32>(p[vid], 0.0, 1.0);
      }
      @fragment fn fs_main() -> @location(0) vec4<f32> {
        return vec4<f32>(0.0, 1.0, 0.0, 1.0);
      }
    "
    Fs.writeText(root + "/shaders/triangle.wgsl", v2)
    assets.handleFileChange_(root + "/shaders/triangle.wgsl")

    var second = renderOnce.call()
    Expect.that(second[0]).toBe(0)
    Expect.that(second[1]).toBe(255)
    Expect.that(second[2]).toBe(0)

    pipeline.destroy
    device.destroy
  }
}

Test.run()
