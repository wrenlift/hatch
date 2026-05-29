GPU primitives plus 2D and 3D renderers, written once against `wgpu` on native and `navigator.gpu` on web. The low layer hands you `Device`, `Buffer`, `Texture`, `Sampler`, `ShaderModule`, `BindGroup`, `RenderPipeline`, `ComputePipeline`, `CommandEncoder`, `RenderPass`, and `ComputePass`. The high layer adds `Camera2D` / `Camera3D`, a sprite-batching `Renderer2D`, and a lit `Renderer3D` over `Mesh` and `Material`. One Wren API, two backends behind it.

## Overview

Open a device against your window's surface, allocate buffers and textures, build a pipeline, encode a pass per frame. The high-level renderers handle the bind-group dance for the common 2D / 3D shapes; the low-level `RenderPipeline` API is there when full control is needed.

```wren
import "@hatch:gpu"   for Renderer2D, Camera2D, Sprite
import "@hatch:image" for Image

var renderer = Renderer2D.new(g.device, g.surfaceFormat)
var camera   = Camera2D.new(g.width, g.height)
var sprite   = Sprite.new(g.device.uploadImage(Image.decode(bytes)))
sprite.anchor(0.5, 0.5)

renderer.beginFrame(camera)
sprite.draw(renderer)
renderer.flush(g.pass)
```

`Renderer2D` is a batcher. Every `sprite.draw(renderer)` accumulates against the current camera; `flush(pass)` issues the actual draw calls. The 3D renderer follows the same pacing with `Renderer3D`, `Mesh`, and `Material`.

## Instanced meshes

`Renderer3D.drawMeshInstanced(mesh, material, instanceBuffer, count)` issues one `drawIndexed` for an arbitrary number of copies of `mesh`. The per-instance `model` + `normalMat` matrices live in a storage buffer; the vertex shader reads them via `@builtin(instance_index)`. The same buffer can be the direct output of a compute pass — write transforms, do culling, select LODs, then draw — no round-trip through Wren.

```wren
import "@hatch:gpu"  for Gpu, Mesh, Material, Camera3D, Renderer3D
import "@hatch:math" for Vec3, Vec4, Mat4

var device   = Gpu.requestDevice()
var renderer = Renderer3D.new(device, surfaceFormat, depthFormat)
var cube     = Mesh.cube(device, 0.5)
var grass    = Material.new(Vec4.new(0.4, 0.8, 0.2, 1.0))

// 32 floats per instance: 16 model + 16 normalMat. For orthonormal
// transforms the one-arg form copies model into normalMat.
var floats = []
for (i in 0...10000) Renderer3D.appendInstance(floats, Mat4.translation(...))

var instances = device.createBuffer({
  "size":  10000 * 32 * 4,
  "usage": ["storage", "copy-dst"]
})
instances.writeFloats(0, floats)

renderer.beginFrame(pass, camera)
renderer.drawMeshInstanced(cube, grass, instances, 10000)   // one drawIndexed
renderer.endFrame()
```

## Compute

`Device.createComputePipeline` plus `CommandEncoder.beginComputePass` give you a WebGPU-style compute path for general-purpose GPU work — particle simulation, mesh skinning, terrain noise, anything that wants to mutate a storage buffer in parallel.

```wren
import "@hatch:gpu" for Gpu

var device   = Gpu.requestDevice()
var shader   = device.createShaderModule({ "code": wgsl })
var bgl      = device.createBindGroupLayout({
  "entries": [{ "binding": 0, "visibility": ["compute"], "kind": "storage" }]
})
var pipeline = device.createComputePipeline({
  "module": shader, "entryPoint": "main",
  "layout": device.createPipelineLayout({ "bindGroupLayouts": [bgl] })
})

var data    = device.createBuffer({ "size": n * 4, "usage": ["storage", "copy-src", "copy-dst"] })
var staging = device.createBuffer({ "size": n * 4, "usage": ["copy-dst", "map-read"] })
var bg      = device.createBindGroup({ "layout": bgl, "entries": [{ "binding": 0, "buffer": data }] })

var enc  = device.createCommandEncoder()
var pass = enc.beginComputePass()
pass.setPipeline(pipeline)
pass.setBindGroup(0, bg)
pass.dispatchWorkgroups((n + 255) / 256)
pass.end
enc.copyBufferToBuffer(data, staging, n * 4)
device.submit([enc.finish])

var out = Float32Array.new(n)
staging.readInto(out)        // memcpy back into a typed array — no per-byte Wren Num allocation
```

`Buffer.readInto(typedArray)` is the fast readback path for megabyte-class workloads. The list-of-bytes `Buffer.readBytes` is still there for small probes (pixel reads, asserts).

## Hot reload via `LivePipeline`

`LivePipeline` watches WGSL shader sources via any duck-typed `db` with `.text(path)` (typically an `@hatch:assets` database) and rebuilds the pipeline when the file's content hash advances. Use it during development to iterate on shaders without rebuilding the binary.

```wren
import "@hatch:gpu"    for LivePipeline
import "@hatch:assets" for Assets

var assets = Assets.open("assets")
var live   = LivePipeline.new(g.device, assets, "shaders/triangle.wgsl", layout)

// Each frame:
live.poll
g.pass.setPipeline(live.pipeline)
```

> **Note: cross-target gaps**
> Both backends ship the full class surface (`Renderer2D`, `Renderer3D`, `LivePipeline`, plus the underlying `Buffer` / `Texture` / `Shader` / `RenderPipeline` / `ComputePipeline` primitives). The web backend has three outstanding gaps: GPU→CPU readback (`Buffer.readBytes` / `Buffer.readInto` / `encoderCopyTextureToBuffer` / `encoderCopyBufferToBuffer`) lands when WebGPU's mapAsync path is wired, compute (`ComputePipeline`, `ComputePass`) lands when the JS bridge grows a compute path, and `LivePipeline` shader hot-reload is build-once on web pending a browser-side filesystem watch. Cross-target game code that avoids those features works unchanged; opt in via `#!native` / `#!wasm` attributes when a path needs them.

> **Note: WebGPU on the desktop browser matrix**
> Chromium, recent Firefox, and Safari on current macOS all ship WebGPU by default. Some mobile builds and older Safari versions (pre-current macOS) lack the API. Surface creation aborts on browsers without WebGPU; check `navigator.gpu` from the host page if a 2D-canvas fallback is needed.

## Compatibility

Wren 0.4 and WrenLift runtime 0.1 or newer. Depends on `@hatch:math`. Native targets pull `wgpu` (Vulkan / Metal / DirectX 12 / OpenGL); web targets reach for `navigator.gpu`. Optional companions: `@hatch:assets` for `LivePipeline`, `@hatch:image` for texture decode.
