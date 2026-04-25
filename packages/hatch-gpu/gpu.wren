// @hatch:gpu — GPU primitives backed by wgpu.
//
//   import "@hatch:gpu" for Gpu, Device
//
//   var device = Gpu.requestDevice({})
//   System.print(device.info["backend"])  // "metal" / "vulkan" / "dx12"
//
// Phase 1 ships the headless rendering core: Adapter, Device,
// Queue, Buffer, Texture, ShaderModule, RenderPipeline,
// CommandEncoder, RenderPass, Sampler, BindGroup{,Layout}. No
// window or surface yet — those land in phase 3.
//
// API shape mirrors WebGPU JS where possible: descriptor maps,
// command encoder + render pass, async device request resolved
// synchronously via `pollster::block_on` inside the plugin (one-
// shot at startup, milliseconds, no benefit to fiber-yielding).
//
// All foreign methods live on `GpuCore` and dispatch through a
// global registry keyed by `u64` ids inside the dylib. The
// classes below are ergonomic Wren wrappers that own an id and
// translate calls into the foreign surface.

#!native = "wlift_gpu"
foreign class GpuCore {
  #!symbol = "wlift_gpu_request_device"
  foreign static requestDevice(descriptor)

  #!symbol = "wlift_gpu_device_destroy"
  foreign static deviceDestroy(id)

  #!symbol = "wlift_gpu_device_info"
  foreign static deviceInfo(id)
}

// Static entry point — `Gpu.requestDevice({...})`.
class Gpu {
  // Request a GPU device + queue. `descriptor` is a Map; supported
  // keys (all optional):
  //
  //   "backends":         "primary" (default) | "all" | "metal" |
  //                       "vulkan" | "dx12" | "gl"
  //   "powerPreference":  "low-power" | "high-performance"
  //   "label":            String — passed to wgpu for diagnostics
  //
  // Aborts the fiber if no compatible adapter is available.
  static requestDevice(descriptor) {
    if (!(descriptor is Map)) Fiber.abort("Gpu.requestDevice: descriptor must be a Map.")
    var id = GpuCore.requestDevice(descriptor)
    return Device.new_(id)
  }

  static requestDevice() { Gpu.requestDevice({}) }
}

// Owns one wgpu Device + Queue. All resource creation hangs off
// here — buffers, textures, shaders, pipelines, command encoders.
class Device {
  construct new_(id) {
    _id = id
  }

  id { _id }

  // Adapter / device metadata as a Map: { "name", "backend",
  // "deviceType" }. Useful for diagnostics and for asserting
  // "is this a real GPU" inside CI.
  info { GpuCore.deviceInfo(_id) }

  // Drop the underlying wgpu Device + Queue. Idempotent — calling
  // twice is fine.
  destroy {
    GpuCore.deviceDestroy(_id)
    _id = -1
  }

  toString { "Device(%(_id))" }
}
