// @hatch:gpu — entry module that re-exports the right backend
// for the current bundle target. Per-target source lives in:
//
//   gpu_native.wren — wgpu-backed cdylib (macOS/Linux/Windows).
//                     Rich Wren-level API (Device / Queue / Buffer /
//                     Texture / RenderPipeline / 2D + 3D renderers).
//
//   gpu_web.wren    — navigator.gpu-backed wasm plugin (browser).
//                     Flat foreign-method surface; smaller footprint
//                     than the native crate's wgpu deps.
//
// Both shapes ship in the same package; the bundler picks the
// right [native_libs] entry per --bundle-target. Wren-side, the
// `#!native` / `#!wasm` cfg attributes below switch which set of
// re-exports the consumer sees.
//
// Note that the two backends do *not* expose an identical
// Wren-level API today — the native variant has classes the web
// one doesn't (the 2D + 3D renderers, the LivePipeline hot
// reload). Game code that wants to be portable should target
// the lowest common denominator, or branch on the target itself
// using its own `#!wasm` / `#!native` attributes. Convergence is
// future work; for now this file just unifies the *package* so
// users only need one import line.

// Wren imports must be single-line, hence the long lists.
#!native
import "gpu_native" for GpuCore, Gpu, Device, Buffer, ShaderModule, Texture, TextureView, Sampler, BindGroupLayout, PipelineLayout, BindGroup, RenderPipeline, CommandEncoder, RenderPass, Camera2D, Renderer2D, Sprite, Camera3D, Light, Mesh, Material, Renderer3D, LivePipeline, Surface, SurfaceFrame

#!wasm
import "gpu_web" for Gpu
