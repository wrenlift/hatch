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

  // -- Buffer ----------------------------------------------------

  #!symbol = "wlift_gpu_buffer_create"
  foreign static bufferCreate(deviceId, descriptor)

  #!symbol = "wlift_gpu_buffer_destroy"
  foreign static bufferDestroy(id)

  #!symbol = "wlift_gpu_buffer_size"
  foreign static bufferSize(id)

  #!symbol = "wlift_gpu_buffer_write_floats"
  foreign static bufferWriteFloats(id, offset, data)

  #!symbol = "wlift_gpu_buffer_write_uints"
  foreign static bufferWriteUints(id, offset, data)

  #!symbol = "wlift_gpu_buffer_write_mat4s"
  foreign static bufferWriteMat4s(id, offset, data)

  #!symbol = "wlift_gpu_buffer_write_vec3s"
  foreign static bufferWriteVec3s(id, offset, data)

  #!symbol = "wlift_gpu_buffer_write_vec4s"
  foreign static bufferWriteVec4s(id, offset, data)

  #!symbol = "wlift_gpu_buffer_write_quats"
  foreign static bufferWriteQuats(id, offset, data)
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

  // Allocate a buffer on this device. Descriptor keys:
  //
  //   "size":  Num,          // bytes, must be multiple of 4
  //   "usage": List<String>, // "vertex" | "index" | "uniform" |
  //                          //   "storage" | "indirect" |
  //                          //   "copy-src" | "copy-dst" |
  //                          //   "map-read" | "map-write"
  //   "label": String?,      // diagnostics
  //
  // Returns a `Buffer` wrapper.
  createBuffer(descriptor) {
    if (!(descriptor is Map)) Fiber.abort("Device.createBuffer: descriptor must be a Map.")
    var bid = GpuCore.bufferCreate(_id, descriptor)
    return Buffer.new_(bid, descriptor["size"])
  }

  // Drop the underlying wgpu Device + Queue. Idempotent — calling
  // twice is fine.
  destroy {
    GpuCore.deviceDestroy(_id)
    _id = -1
  }

  toString { "Device(%(_id))" }
}

// GPU buffer — vertex / index / uniform / storage. Always owned
// by exactly one device; dropping the device invalidates the
// buffer (writes after that surface a runtime error).
class Buffer {
  construct new_(id, size) {
    _id = id
    _size = size
  }

  id   { _id }
  size { _size }

  // Scalar-list writes. `data` is a `List<Num>`; each value is
  // converted (f64→f32 or f64→u32) and packed into the buffer
  // starting at `offset` bytes. Single FFI call regardless of
  // list length.
  writeFloats(offset, data) { GpuCore.bufferWriteFloats(_id, offset, data) }
  writeUints(offset, data)  { GpuCore.bufferWriteUints(_id, offset, data) }

  // Batched math-object writes. Each variant takes a list of
  // @hatch:math objects, extracts each element's `.data` on the
  // Wren side (cheap — Mat4.data returns _m by reference, the
  // others build a 3- or 4-element list), and hands a List<List>
  // to the foreign packer in a single FFI call.
  //
  //   writeMat4s — Mat4, 16 f32 row-major per element
  //   writeVec3s — Vec3, 3 f32, no padding (caller pads if shader
  //                expects std140-aligned vec3s)
  //   writeVec4s — Vec4, 4 f32
  //   writeQuats — Quat, 4 f32 in (w, x, y, z) order
  writeMat4s(offset, mats) { GpuCore.bufferWriteMat4s(_id, offset, Buffer.dataOf_(mats)) }
  writeVec3s(offset, vecs) { GpuCore.bufferWriteVec3s(_id, offset, Buffer.dataOf_(vecs)) }
  writeVec4s(offset, vecs) { GpuCore.bufferWriteVec4s(_id, offset, Buffer.dataOf_(vecs)) }
  writeQuats(offset, quats) { GpuCore.bufferWriteQuats(_id, offset, Buffer.dataOf_(quats)) }

  // Extract the `data` getter from each element. Done in Wren so
  // the foreign packer doesn't need to call back into the VM mid-
  // conversion (a path that fights the GC's nursery promotion).
  static dataOf_(items) {
    var out = []
    for (item in items) out.add(item.data)
    return out
  }

  destroy {
    GpuCore.bufferDestroy(_id)
    _id = -1
  }

  toString { "Buffer(%(_id), %(_size) bytes)" }
}
