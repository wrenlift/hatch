// `@hatch:gpu`. Entry module that re-exports the right backend
// for the current bundle target. Per-target source lives in:
//
// | File              | Backend                                                                                                                |
// |-------------------|------------------------------------------------------------------------------------------------------------------------|
// | `gpu_native.wren` | `wgpu`-backed cdylib (macOS / Linux / Windows). Rich Wren-level API (`Device` / `Queue` / `Buffer` / `Texture` / `RenderPipeline` / 2D + 3D renderers). |
// | `gpu_web.wren`    | `navigator.gpu`-backed wasm plugin (browser). Flat foreign-method surface; smaller footprint than the native crate's wgpu deps. |
//
// Both shapes ship in the same package; the bundler picks the
// right `[native_libs]` entry per `--bundle-target`. Wren-side,
// the `#!native` / `#!wasm` cfg attributes below switch which
// set of re-exports the consumer sees.
//
// The two backends do *not* expose an identical Wren-level API
// today. The native variant has classes the web one does not
// (the 2D + 3D renderers, the `LivePipeline` hot reload). Game
// code that wants to be portable should target the lowest common
// denominator, or branch on the target itself using its own
// `#!wasm` / `#!native` attributes. Convergence comes later; for
// now this file unifies the *package* so users only need one
// import line.

// Wren imports must be single-line, hence the long lists.
#!native
import "gpu_native" for GpuCore, Gpu, Device, Buffer, ShaderModule, Texture, TextureView, Sampler, BindGroupLayout, PipelineLayout, BindGroup, RenderPipeline, CommandEncoder, RenderPass, Camera2D, Renderer2D, Sprite, Camera3D, Light, Mesh, Material, Renderer3D, LivePipeline, Surface, SurfaceFrame

#!wasm
import "gpu_web" for GpuCore, Gpu, Device, Buffer, ShaderModule, Texture, TextureView, Sampler, BindGroupLayout, PipelineLayout, BindGroup, RenderPipeline, CommandEncoder, RenderPass, Camera2D, Renderer2D, Sprite, Camera3D, Light, Mesh, Material, Renderer3D, LivePipeline, Surface, SurfaceFrame
