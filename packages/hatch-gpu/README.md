GPU primitives plus 2D and 3D renderers, written once against `wgpu` on native and `navigator.gpu` on web. The low layer hands you `Device`, `Buffer`, `Texture`, `Sampler`, `ShaderModule`, `BindGroup`, `RenderPipeline`, `CommandEncoder`, and `RenderPass`. The high layer adds `Camera2D` / `Camera3D`, a sprite-batching `Renderer2D`, and a lit `Renderer3D` over `Mesh` and `Material`. One Wren API, two backends behind it.

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
> Both backends ship the full class surface (`Renderer2D`, `Renderer3D`, `LivePipeline`, plus the underlying `Buffer` / `Texture` / `Shader` / `RenderPipeline` primitives). The web backend has two outstanding gaps: GPU→CPU readback (`Buffer.readBytes`, `encoderCopyTextureToBuffer`) lands when WebGPU's mapAsync path is wired, and `LivePipeline` shader hot-reload is build-once on web pending a browser-side filesystem watch. Cross-target game code that avoids those features works unchanged; opt in via `#!native` / `#!wasm` attributes when a path needs them.

> **Note: WebGPU on the desktop browser matrix**
> Chromium, recent Firefox, and Safari on current macOS all ship WebGPU by default. Some mobile builds and older Safari versions (pre-current macOS) lack the API. Surface creation aborts on browsers without WebGPU; check `navigator.gpu` from the host page if a 2D-canvas fallback is needed.

## Compatibility

Wren 0.4 and WrenLift runtime 0.1 or newer. Depends on `@hatch:math`. Native targets pull `wgpu` (Vulkan / Metal / DirectX 12 / OpenGL); web targets reach for `navigator.gpu`. Optional companions: `@hatch:assets` for `LivePipeline`, `@hatch:image` for texture decode.
