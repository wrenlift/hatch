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

  // -- Shader ----------------------------------------------------

  #!symbol = "wlift_gpu_shader_create"
  foreign static shaderCreate(deviceId, descriptor)

  #!symbol = "wlift_gpu_shader_destroy"
  foreign static shaderDestroy(id)

  // -- Texture ---------------------------------------------------

  #!symbol = "wlift_gpu_texture_create"
  foreign static textureCreate(deviceId, descriptor)

  #!symbol = "wlift_gpu_texture_destroy"
  foreign static textureDestroy(id)

  #!symbol = "wlift_gpu_texture_create_view"
  foreign static textureCreateView(textureId)

  #!symbol = "wlift_gpu_view_destroy"
  foreign static viewDestroy(id)

  // -- Sampler ---------------------------------------------------

  #!symbol = "wlift_gpu_sampler_create"
  foreign static samplerCreate(deviceId, descriptor)

  #!symbol = "wlift_gpu_sampler_destroy"
  foreign static samplerDestroy(id)

  // -- Bind group layouts + bind groups --------------------------

  #!symbol = "wlift_gpu_bind_group_layout_create"
  foreign static bindGroupLayoutCreate(deviceId, descriptor)

  #!symbol = "wlift_gpu_bind_group_layout_destroy"
  foreign static bindGroupLayoutDestroy(id)

  #!symbol = "wlift_gpu_pipeline_layout_create"
  foreign static pipelineLayoutCreate(deviceId, descriptor)

  #!symbol = "wlift_gpu_pipeline_layout_destroy"
  foreign static pipelineLayoutDestroy(id)

  #!symbol = "wlift_gpu_bind_group_create"
  foreign static bindGroupCreate(deviceId, descriptor)

  #!symbol = "wlift_gpu_bind_group_destroy"
  foreign static bindGroupDestroy(id)

  // -- Render pipelines ------------------------------------------

  #!symbol = "wlift_gpu_render_pipeline_create"
  foreign static renderPipelineCreate(deviceId, descriptor)

  #!symbol = "wlift_gpu_render_pipeline_destroy"
  foreign static renderPipelineDestroy(id)

  // -- CommandEncoder + render pass + readback -------------------

  #!symbol = "wlift_gpu_encoder_create"
  foreign static encoderCreate(deviceId, descriptor)

  #!symbol = "wlift_gpu_encoder_destroy"
  foreign static encoderDestroy(id)

  #!symbol = "wlift_gpu_encoder_record_pass"
  foreign static encoderRecordPass(encoderId, descriptor)

  #!symbol = "wlift_gpu_encoder_copy_texture_to_buffer"
  foreign static encoderCopyTextureToBuffer(encoderId, textureId, bufferId, descriptor)

  #!symbol = "wlift_gpu_encoder_finish"
  foreign static encoderFinish(id)

  #!symbol = "wlift_gpu_queue_submit"
  foreign static queueSubmit(deviceId, encoderIds)

  #!symbol = "wlift_gpu_buffer_read_bytes"
  foreign static bufferReadBytes(id)
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

  // Compile a WGSL shader. Descriptor:
  //   "code":  String  — WGSL source
  //   "label": String? — diagnostics
  createShaderModule(descriptor) {
    if (!(descriptor is Map)) Fiber.abort("Device.createShaderModule: descriptor must be a Map.")
    var sid = GpuCore.shaderCreate(_id, descriptor)
    return ShaderModule.new_(sid)
  }

  // Allocate a texture. Descriptor:
  //   "width":  Num
  //   "height": Num
  //   "depth":  Num?              (default 1, layer count for arrays)
  //   "format": String            ("rgba8unorm", "depth32float", ...)
  //   "usage":  List<String>      ("render-attachment", "texture-binding",
  //                                "storage-binding", "copy-src", "copy-dst")
  //   "sampleCount": Num?         (default 1)
  //   "label":  String?
  createTexture(descriptor) {
    if (!(descriptor is Map)) Fiber.abort("Device.createTexture: descriptor must be a Map.")
    var tid = GpuCore.textureCreate(_id, descriptor)
    return Texture.new_(tid, descriptor)
  }

  // Allocate a sampler. Descriptor (all optional):
  //   "magFilter":     "nearest" | "linear"   (default linear)
  //   "minFilter":     "nearest" | "linear"   (default linear)
  //   "mipmapFilter":  "nearest" | "linear"   (default nearest)
  //   "addressModeU":  "clamp-to-edge" | "repeat" | "mirror-repeat"
  //   "addressModeV":  same
  //   "addressModeW":  same
  //   "label":         String?
  createSampler(descriptor) {
    if (!(descriptor is Map)) descriptor = {}
    var sid = GpuCore.samplerCreate(_id, descriptor)
    return Sampler.new_(sid)
  }

  // Create a bind group layout. Descriptor:
  //   "entries": [
  //     { "binding": Num,
  //       "visibility": ["vertex" | "fragment" | "compute"],
  //       "kind": "uniform" | "storage" | "read-only-storage" |
  //               "sampler" | "texture",
  //       // texture-only:
  //       "sampleType": "float" | "depth" | "uint" | "sint",
  //     }, ...
  //   ]
  createBindGroupLayout(descriptor) {
    var lid = GpuCore.bindGroupLayoutCreate(_id, descriptor)
    return BindGroupLayout.new_(lid)
  }

  // Combine bind group layouts into a pipeline layout.
  //   "bindGroupLayouts": [BindGroupLayout, ...]
  createPipelineLayout(descriptor) {
    var ids = []
    for (l in descriptor["bindGroupLayouts"]) ids.add(l.id)
    var pdesc = { "bindGroupLayouts": ids }
    if (descriptor.containsKey("label")) pdesc["label"] = descriptor["label"]
    var plid = GpuCore.pipelineLayoutCreate(_id, pdesc)
    return PipelineLayout.new_(plid)
  }

  // Bind buffers / samplers / texture views to a layout's slots.
  //   "layout":  BindGroupLayout
  //   "entries": [
  //     { "binding": Num, "buffer":  Buffer, "offset"?: Num, "size"?: Num },
  //     { "binding": Num, "sampler": Sampler },
  //     { "binding": Num, "view":    TextureView },
  //   ]
  createBindGroup(descriptor) {
    var entries = []
    for (e in descriptor["entries"]) {
      var rewritten = { "binding": e["binding"] }
      if (e.containsKey("buffer"))  rewritten["buffer"]  = e["buffer"].id
      if (e.containsKey("offset"))  rewritten["offset"]  = e["offset"]
      if (e.containsKey("size"))    rewritten["size"]    = e["size"]
      if (e.containsKey("sampler")) rewritten["sampler"] = e["sampler"].id
      if (e.containsKey("view"))    rewritten["view"]    = e["view"].id
      entries.add(rewritten)
    }
    var dec = { "layout": descriptor["layout"].id, "entries": entries }
    if (descriptor.containsKey("label")) dec["label"] = descriptor["label"]
    var bid = GpuCore.bindGroupCreate(_id, dec)
    return BindGroup.new_(bid)
  }

  // Create a render pipeline. See gpu.spec.wren for the full
  // descriptor shape.
  createRenderPipeline(descriptor) {
    var dec = RenderPipeline.normalize_(descriptor)
    var pid = GpuCore.renderPipelineCreate(_id, dec)
    return RenderPipeline.new_(pid)
  }

  // Open a fresh command encoder. Descriptor optional ({"label":...}).
  createCommandEncoder() { createCommandEncoder({}) }
  createCommandEncoder(descriptor) {
    var eid = GpuCore.encoderCreate(_id, descriptor)
    return CommandEncoder.new_(eid, this)
  }

  // Submit a list of finished CommandEncoders to this device's queue.
  submit(encoders) {
    var ids = []
    for (e in encoders) ids.add(e.id)
    GpuCore.queueSubmit(_id, ids)
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

  // Synchronously map for read + copy bytes back to Wren as a
  // List<Num>, one entry per byte. Blocks the host while wgpu
  // drains pending submissions, so use sparingly — best for tests
  // and one-shot CPU readback.
  readBytes() { GpuCore.bufferReadBytes(_id) }

  destroy {
    GpuCore.bufferDestroy(_id)
    _id = -1
  }

  toString { "Buffer(%(_id), %(_size) bytes)" }
}

// Compiled WGSL module — stamped out by Device.createShaderModule.
// Used as a vertex / fragment / compute stage source on a pipeline.
class ShaderModule {
  construct new_(id) { _id = id }
  id { _id }
  destroy {
    GpuCore.shaderDestroy(_id)
    _id = -1
  }
  toString { "ShaderModule(%(_id))" }
}

// 2D texture. Phase 1 supports only D2 textures (no 1D / 3D /
// cube). Used as a render attachment + readback source for the
// headless tests, and as a sampled texture once the sprite/mesh
// renderers land.
class Texture {
  construct new_(id, descriptor) {
    _id     = id
    _width  = descriptor["width"]
    _height = descriptor["height"]
    _format = descriptor["format"]
  }

  id     { _id }
  width  { _width }
  height { _height }
  format { _format }

  // Default view — covers the whole texture, matches the texture's
  // format. Higher-level renderers can build sliced views by
  // calling the foreign API directly when needed.
  createView() {
    var vid = GpuCore.textureCreateView(_id)
    return TextureView.new_(vid, _format, _width, _height)
  }

  destroy {
    GpuCore.textureDestroy(_id)
    _id = -1
  }

  toString { "Texture(%(_id), %(_width)x%(_height) %(_format))" }
}

class TextureView {
  construct new_(id, format, width, height) {
    _id     = id
    _format = format
    _width  = width
    _height = height
  }

  id     { _id }
  format { _format }
  width  { _width }
  height { _height }

  destroy {
    GpuCore.viewDestroy(_id)
    _id = -1
  }

  toString { "TextureView(%(_id))" }
}

class Sampler {
  construct new_(id) { _id = id }
  id { _id }
  destroy {
    GpuCore.samplerDestroy(_id)
    _id = -1
  }
  toString { "Sampler(%(_id))" }
}

// -- Bind groups -------------------------------------------------

class BindGroupLayout {
  construct new_(id) { _id = id }
  id { _id }
  destroy {
    GpuCore.bindGroupLayoutDestroy(_id)
    _id = -1
  }
}

class PipelineLayout {
  construct new_(id) { _id = id }
  id { _id }
  destroy {
    GpuCore.pipelineLayoutDestroy(_id)
    _id = -1
  }
}

class BindGroup {
  construct new_(id) { _id = id }
  id { _id }
  destroy {
    GpuCore.bindGroupDestroy(_id)
    _id = -1
  }
}

// -- Render pipeline --------------------------------------------

class RenderPipeline {
  construct new_(id) { _id = id }
  id { _id }
  destroy {
    GpuCore.renderPipelineDestroy(_id)
    _id = -1
  }

  // Translate a user-friendly descriptor into the flat Map shape
  // the foreign side expects. We unwrap shader / layout objects
  // into raw ids so the descriptor is pure data when it crosses
  // the FFI boundary.
  static normalize_(d) {
    var out = {}
    if (d.containsKey("label")) out["label"] = d["label"]

    // layout: "auto" or a PipelineLayout
    if (d.containsKey("layout")) {
      var l = d["layout"]
      out["layout"] = (l is String) ? l : l.id
    }

    // vertex stage
    var v = d["vertex"]
    var vout = { "module": v["module"].id, "entryPoint": v["entryPoint"] }
    if (v.containsKey("buffers")) vout["buffers"] = v["buffers"]
    out["vertex"] = vout

    // fragment stage (optional)
    if (d.containsKey("fragment")) {
      var f = d["fragment"]
      out["fragment"] = {
        "module":     f["module"].id,
        "entryPoint": f["entryPoint"],
        "targets":    f["targets"]
      }
    }

    if (d.containsKey("primitive"))    out["primitive"]    = d["primitive"]
    if (d.containsKey("depthStencil")) out["depthStencil"] = d["depthStencil"]
    return out
  }
}

// -- Command encoder + render pass -------------------------------

class CommandEncoder {
  construct new_(id, device) {
    _id = id
    _device = device
  }

  id     { _id }
  device { _device }

  // Open a render pass. Returns a `RenderPass` that accumulates
  // commands; call `pass.end` to flush them into the encoder.
  beginRenderPass(descriptor) {
    return RenderPass.new_(this, descriptor)
  }

  // Copy `texture` into `buffer` so the host can read pixels back.
  // `descriptor` keys:
  //   "width", "height": copy region size
  //   "bytesPerRow"?, "rowsPerImage"?: layout overrides
  copyTextureToBuffer(texture, buffer, descriptor) {
    GpuCore.encoderCopyTextureToBuffer(_id, texture.id, buffer.id, descriptor)
  }

  finish {
    GpuCore.encoderFinish(_id)
    return this
  }

  destroy {
    GpuCore.encoderDestroy(_id)
    _id = -1
  }
}

// Render pass builder. Accumulates commands client-side and emits
// them in a single foreign call on `end`. Sidesteps the
// wgpu::RenderPass<'a> lifetime — no long-lived borrow on the
// encoder needs to cross the FFI boundary.
class RenderPass {
  construct new_(encoder, descriptor) {
    _encoder = encoder
    _desc    = descriptor
    _cmds    = []
  }

  setPipeline(p) {
    _cmds.add({ "op": "setPipeline", "pipeline": p.id })
    return this
  }
  setVertexBuffer(slot, buffer) {
    _cmds.add({ "op": "setVertexBuffer", "slot": slot, "buffer": buffer.id })
    return this
  }
  // `format` is "uint16" (default) or "uint32".
  setIndexBuffer(buffer, format) {
    _cmds.add({ "op": "setIndexBuffer", "buffer": buffer.id, "format": format })
    return this
  }
  setIndexBuffer(buffer) { setIndexBuffer(buffer, "uint16") }
  setBindGroup(index, group) {
    _cmds.add({ "op": "setBindGroup", "index": index, "group": group.id })
    return this
  }
  draw(vertexCount) { draw(vertexCount, 1) }
  draw(vertexCount, instanceCount) {
    _cmds.add({ "op": "draw", "vertexCount": vertexCount, "instanceCount": instanceCount })
    return this
  }
  drawIndexed(indexCount) { drawIndexed(indexCount, 1) }
  drawIndexed(indexCount, instanceCount) {
    _cmds.add({ "op": "drawIndexed", "indexCount": indexCount, "instanceCount": instanceCount })
    return this
  }

  // Translate object refs in the original descriptor into raw ids
  // and forward the whole record (descriptor + commands) to the
  // foreign side.
  end {
    var dec = RenderPass.normalizeDescriptor_(_desc)
    dec["commands"] = _cmds
    GpuCore.encoderRecordPass(_encoder.id, dec)
  }

  static normalizeDescriptor_(d) {
    var out = {}
    var attachments = []
    for (a in d["colorAttachments"]) {
      var rec = { "view": a["view"].id }
      if (a.containsKey("loadOp"))     rec["loadOp"]     = a["loadOp"]
      if (a.containsKey("clearValue")) rec["clearValue"] = a["clearValue"]
      if (a.containsKey("storeOp"))    rec["storeOp"]    = a["storeOp"]
      attachments.add(rec)
    }
    out["colorAttachments"] = attachments
    if (d.containsKey("depthStencilAttachment")) {
      var ds = d["depthStencilAttachment"]
      var rec = { "view": ds["view"].id }
      if (ds.containsKey("depthLoadOp"))     rec["depthLoadOp"]     = ds["depthLoadOp"]
      if (ds.containsKey("depthClearValue")) rec["depthClearValue"] = ds["depthClearValue"]
      if (ds.containsKey("depthStoreOp"))    rec["depthStoreOp"]    = ds["depthStoreOp"]
      out["depthStencilAttachment"] = rec
    }
    return out
  }
}
