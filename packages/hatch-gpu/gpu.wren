// @hatch:gpu — GPU primitives backed by wgpu.
//
//   import "@hatch:gpu" for Gpu, Device
//
//   var device = Gpu.requestDevice({})
//   System.print(device.info["backend"])  // "metal" / "vulkan" / "dx12"
//
// Currently exposes the headless rendering core: Adapter, Device,
// Queue, Buffer, Texture, ShaderModule, RenderPipeline,
// CommandEncoder, RenderPass, Sampler, BindGroup{,Layout}. Window
// and Surface support is on the way; until then, render to a
// texture and read pixels back via Buffer.readBytes for tests and
// off-screen pipelines.
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

import "@hatch:math" for Vec3, Vec4, Mat4

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

  // -- Surface (bring-your-own-window) ---------------------------

  #!symbol = "wlift_gpu_surface_create_from_handle"
  foreign static surfaceCreate(deviceId, handle)

  #!symbol = "wlift_gpu_surface_destroy"
  foreign static surfaceDestroy(id)

  #!symbol = "wlift_gpu_surface_configure"
  foreign static surfaceConfigure(id, descriptor)

  #!symbol = "wlift_gpu_surface_acquire"
  foreign static surfaceAcquire(id)

  #!symbol = "wlift_gpu_surface_present_frame"
  foreign static surfacePresentFrame(frameId)

  // -- Texture upload --------------------------------------------
  // Image decoding lives in @hatch:image; this is the lower-level
  // bytes→texture path (also used for font atlases, dynamic
  // updates, GPU compute outputs, etc.).

  #!symbol = "wlift_gpu_queue_write_texture"
  foreign static queueWriteTexture(textureId, bytes, descriptor)
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

  // Build a texture from a decoded image. The argument duck-types
  // on `width`, `height`, and `pixels` (a ByteArray or List<Num>
  // of RGBA8 bytes) — anything that exposes those three reads
  // works, including @hatch:image's `Image` class.
  //
  //   import "@hatch:image" for Image
  //   import "@hatch:assets" for Assets
  //
  //   var img = Image.decode(Assets.open("assets").bytes("hero.png"))
  //   var tex = device.uploadImage(img)
  //
  // `options` (Map, all optional):
  //   "label":      String?
  //   "format":     "rgba8unorm" | "rgba8unorm-srgb" (default srgb)
  //   "extraUsage": List<String> appended to ["texture-binding", "copy-dst"]
  uploadImage(image) { uploadImage(image, {}) }
  uploadImage(image, options) {
    var format = options.containsKey("format") ? options["format"] : "rgba8unorm-srgb"
    var extraUsage = options.containsKey("extraUsage") ? options["extraUsage"] : []
    var usage = ["texture-binding", "copy-dst"]
    for (u in extraUsage) usage.add(u)
    var desc = {
      "width":  image.width,
      "height": image.height,
      "format": format,
      "usage":  usage
    }
    if (options.containsKey("label")) desc["label"] = options["label"]
    var tex = createTexture(desc)
    writeTexture(tex, image.pixels, {
      "width":       image.width,
      "height":      image.height,
      "bytesPerRow": image.width * 4
    })
    return tex
  }

  // Direct CPU → texture upload via the device queue. Useful for
  // dynamic textures (font atlases, GPU-readback round-trips,
  // procedurally-generated content). The descriptor:
  //
  //   "x", "y":         Num?  (default 0; copy origin within the texture)
  //   "width", "height": Num
  //   "bytesPerRow":     Num
  //   "rowsPerImage":    Num?  (default = height)
  writeTexture(texture, bytes, descriptor) {
    GpuCore.queueWriteTexture(texture.id, bytes, descriptor)
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

  // Build a Surface bound to this device from a raw window
  // handle. The `handle` Map is platform-tagged with the same
  // shape as raw_window_handle's variants; any window provider
  // can produce one — @hatch:window is the default winit-backed
  // implementation, but custom embedders (IDE viewports, native
  // shells, host apps) just need to surface the right pointer
  // integers and pick the right "platform" string.
  //
  // Examples:
  //
  //   // macOS via @hatch:window:
  //   var surface = device.createSurface(window.handle)
  //
  //   // Custom AppKit embed (already have an NSView*):
  //   var surface = device.createSurface({
  //     "platform": "appkit",
  //     "ns_view": nsViewPtr  // as Num
  //   })
  //
  // The caller MUST keep the underlying window alive at least as
  // long as the Surface — wgpu doesn't pin it.
  createSurface(handle) {
    if (!(handle is Map)) Fiber.abort("Device.createSurface: handle must be a Map.")
    var sid = GpuCore.surfaceCreate(_id, handle)
    return Surface.new_(sid, this)
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

// 2D texture — render attachment, readback source, or sampled
// input for fragment shaders. Only `D2` dimension is exposed
// today; 1D / 3D / cube can be added on demand.
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

// -- Renderer2D --------------------------------------------------
//
// Sprite batcher + ortho camera. Built on top of every other
// primitive in this module — pure Wren, no extra plugin.
//
//   var renderer = Renderer2D.new(device, surfaceFormat)
//   renderer.beginFrame(camera)
//
//   // ... render-pass setup as usual; bind via renderer.bind(pass) ...
//   renderer.drawSprite(texture, x, y, w, h)
//   renderer.flush(pass)
//
// One pipeline + one vertex buffer + one uniform buffer per
// renderer. Sprites with the same texture get coalesced into one
// draw call; a texture switch flushes the current batch and
// starts a new one. The current cap is 4096 sprites per flush
// (32 floats per sprite × 4096 = 512 KB vertex buffer); flushes
// are explicit so the user controls when GPU work goes out.

class Camera2D {
  // Build an orthographic projection that maps the half-extents
  // (x = ±width/2, y = ±height/2) to NDC. Origin centred — most
  // game cameras want this. Use `worldOrigin` to shift the
  // visible region around.
  construct new(width, height) {
    _width  = width
    _height = height
    _origin = Vec3.new(0, 0, 0)
  }

  width   { _width }
  height  { _height }
  origin  { _origin }
  origin=(v) { _origin = v }

  // Compute view-projection. Ortho maps (-w/2 + ox, -h/2 + oy)
  // through (w/2 + ox, h/2 + oy) onto NDC. Z range is generous
  // (-1000..1000) so callers can layer sprites by Z without
  // worrying about clipping.
  viewProj {
    var hw = _width  / 2
    var hh = _height / 2
    var l = _origin.x - hw
    var r = _origin.x + hw
    var b = _origin.y - hh
    var t = _origin.y + hh
    return Mat4.ortho(l, r, b, t, -1000, 1000)
  }
}

class Renderer2D {
  // Default sprite shader — position (vec2) + uv (vec2) +
  // color (vec4) per vertex; one mat4 view-projection in a
  // uniform; sampler + texture in the same bind group.
  static SPRITE_WGSL_ {
    return "
      struct Uniforms { vp: mat4x4<f32> };
      @group(0) @binding(0) var<uniform> u: Uniforms;
      @group(0) @binding(1) var t: texture_2d<f32>;
      @group(0) @binding(2) var s: sampler;

      struct VsIn  {
        @location(0) pos:   vec2<f32>,
        @location(1) uv:    vec2<f32>,
        @location(2) color: vec4<f32>,
      };
      struct VsOut {
        @builtin(position) clip:  vec4<f32>,
        @location(0)       uv:    vec2<f32>,
        @location(1)       color: vec4<f32>,
      };

      @vertex
      fn vs_main(in: VsIn) -> VsOut {
        var o: VsOut;
        o.clip  = u.vp * vec4<f32>(in.pos, 0.0, 1.0);
        o.uv    = in.uv;
        o.color = in.color;
        return o;
      }
      @fragment
      fn fs_main(in: VsOut) -> @location(0) vec4<f32> {
        return textureSample(t, s, in.uv) * in.color;
      }
    "
  }

  static MAX_SPRITES_  { 4096 }
  static FLOATS_PER_VERTEX_  { 8 }   // 2 pos + 2 uv + 4 color
  static VERTS_PER_SPRITE_   { 6 }   // two triangles, no shared verts (simpler)

  // Build a sprite renderer. Pass `depthFormat` if you plan to
  // use this renderer inside a render pass that has a depth
  // attachment — typically when stacking 2D HUDs over a 3D
  // scene drawn by Renderer3D in the same pass. The 2D pipeline
  // sets `depthWriteEnabled: false` and `depthCompare: always`
  // so sprites land on top of whatever's already in the depth
  // buffer without contributing to it.
  construct new(device, surfaceFormat) {
    new(device, surfaceFormat, null)
  }
  construct new(device, surfaceFormat, depthFormat) {
    _device = device

    var shader = device.createShaderModule({
      "code": Renderer2D.SPRITE_WGSL_,
      "label": "renderer2d-sprite"
    })

    _bgl = device.createBindGroupLayout({
      "entries": [
        { "binding": 0, "visibility": ["vertex"],   "kind": "uniform" },
        { "binding": 1, "visibility": ["fragment"], "kind": "texture" },
        { "binding": 2, "visibility": ["fragment"], "kind": "sampler" }
      ]
    })
    _pipelineLayout = device.createPipelineLayout({"bindGroupLayouts": [_bgl]})

    var pipelineDesc = {
      "layout": _pipelineLayout,
      "vertex": {
        "module": shader, "entryPoint": "vs_main",
        "buffers": [{
          "arrayStride": Renderer2D.FLOATS_PER_VERTEX_ * 4,
          "stepMode": "vertex",
          "attributes": [
            { "shaderLocation": 0, "offset": 0,  "format": "float32x2" },
            { "shaderLocation": 1, "offset": 8,  "format": "float32x2" },
            { "shaderLocation": 2, "offset": 16, "format": "float32x4" }
          ]
        }]
      },
      "fragment": {
        "module": shader, "entryPoint": "fs_main",
        "targets": [{ "format": surfaceFormat }]
      },
      "primitive": { "topology": "triangle-list", "cullMode": "none" },
      "label": "renderer2d-pipeline"
    }
    if (depthFormat != null) {
      // depth-test on but always-pass + depth-write off, so 2D
      // sprites overlay whatever depth value's already there
      // without participating in the depth buffer's contents.
      pipelineDesc["depthStencil"] = {
        "format": depthFormat,
        "depthWriteEnabled": false,
        "depthCompare": "always"
      }
    }
    _pipeline = device.createRenderPipeline(pipelineDesc)

    var vboBytes = Renderer2D.MAX_SPRITES_ *
                   Renderer2D.VERTS_PER_SPRITE_ *
                   Renderer2D.FLOATS_PER_VERTEX_ * 4
    _vbo = device.createBuffer({
      "size":  vboBytes,
      "usage": ["vertex", "copy-dst"],
      "label": "renderer2d-vbo"
    })
    _ubo = device.createBuffer({
      "size":  64,            // one mat4
      "usage": ["uniform", "copy-dst"],
      "label": "renderer2d-ubo"
    })
    _sampler = device.createSampler({
      "magFilter": "linear", "minFilter": "linear",
      "addressModeU": "clamp-to-edge", "addressModeV": "clamp-to-edge"
    })

    // Per-frame state
    _floats     = []
    _spriteCount = 0
    _curTexture  = null
    _curBindGroup = null
    _bindGroups   = {}    // texture id → BindGroup (lazy cache)
  }

  // Begin a new frame. Resets the batch + uploads the camera
  // view-projection. Call before any drawSprite calls.
  beginFrame(camera) {
    _ubo.writeMat4s(0, [camera.viewProj])
    _floats = []
    _spriteCount = 0
    _curTexture = null
    _curBindGroup = null
  }

  // Queue a sprite. `dst` is screen-space; `uv` defaults to the
  // full texture (0, 0)–(1, 1). `color` is an RGBA tint, default
  // opaque white.
  //
  //   renderer.drawSprite(tex, x, y, w, h)
  //   renderer.drawSpriteUV(tex, x, y, w, h, u0, v0, u1, v1)
  //   renderer.drawSpriteTinted(tex, x, y, w, h, color)
  drawSprite(texture, x, y, w, h) {
    drawSprite_(texture, x, y, w, h, 0, 0, 1, 1, 1, 1, 1, 1)
  }
  drawSpriteUV(texture, x, y, w, h, u0, v0, u1, v1) {
    drawSprite_(texture, x, y, w, h, u0, v0, u1, v1, 1, 1, 1, 1)
  }
  drawSpriteTinted(texture, x, y, w, h, r, g, b, a) {
    drawSprite_(texture, x, y, w, h, 0, 0, 1, 1, r, g, b, a)
  }
  // PixiJS-style: pass a Sprite display object and let it handle
  // the transform + uv + tint extraction.
  draw(sprite) { sprite.draw(this) }

  // Internal — does the actual vertex emit. Two triangles per
  // sprite, no shared vertices to keep the fragment-stage
  // colour interpolation correct without an index buffer.
  drawSprite_(texture, x, y, w, h, u0, v0, u1, v1, r, g, b, a) {
    if (_curTexture != null && _curTexture.id != texture.id) {
      Fiber.abort("Renderer2D: texture switches require an explicit flush(pass).")
    }
    _curTexture = texture
    if (_spriteCount >= Renderer2D.MAX_SPRITES_) {
      Fiber.abort("Renderer2D: batch full (%(_spriteCount) sprites). Call flush(pass) sooner.")
    }
    var x1 = x + w
    var y1 = y + h
    var f = _floats

    // Triangle 1 — top-left, bottom-left, bottom-right
    pushVertex_(f, x,  y,  u0, v0, r, g, b, a)
    pushVertex_(f, x,  y1, u0, v1, r, g, b, a)
    pushVertex_(f, x1, y1, u1, v1, r, g, b, a)
    // Triangle 2 — top-left, bottom-right, top-right
    pushVertex_(f, x,  y,  u0, v0, r, g, b, a)
    pushVertex_(f, x1, y1, u1, v1, r, g, b, a)
    pushVertex_(f, x1, y,  u1, v0, r, g, b, a)
    _spriteCount = _spriteCount + 1
  }

  // Tight scalar push so drawSprite_ stays linear and readable.
  pushVertex_(f, px, py, u, v, r, g, b, a) {
    f.add(px)
    f.add(py)
    f.add(u)
    f.add(v)
    f.add(r)
    f.add(g)
    f.add(b)
    f.add(a)
  }

  // Lazily cache one BindGroup per (texture id) — sampler + UBO
  // are shared, so the only thing that varies per texture is the
  // view binding.
  bindGroupFor_(texture) {
    if (_bindGroups.containsKey(texture.id)) return _bindGroups[texture.id]
    var bg = _device.createBindGroup({
      "layout": _bgl,
      "entries": [
        { "binding": 0, "buffer":  _ubo },
        { "binding": 1, "view":    texture.createView() },
        { "binding": 2, "sampler": _sampler }
      ]
    })
    _bindGroups[texture.id] = bg
    return bg
  }

  // Flush whatever's in the batch into `pass`. Call at the end
  // of each frame (after all drawSprite calls), and again every
  // time you swap textures.
  flush(pass) {
    if (_spriteCount == 0) return
    _vbo.writeFloats(0, _floats)
    var bg = bindGroupFor_(_curTexture)
    pass.setPipeline(_pipeline)
    pass.setBindGroup(0, bg)
    pass.setVertexBuffer(0, _vbo)
    pass.draw(_spriteCount * Renderer2D.VERTS_PER_SPRITE_)
    _floats = []
    _spriteCount = 0
    _curTexture = null
  }

  destroy {
    _vbo.destroy
    _ubo.destroy
    _sampler.destroy
    _pipeline.destroy
    _pipelineLayout.destroy
    _bgl.destroy
  }
}

// -- Sprite display object ---------------------------------------
//
// PixiJS / Cocos / Godot lineage: a transformable handle to a
// texture region with mutable position / size / scale / anchor /
// tint / uv. Lives independently of the Renderer2D — `r.draw(s)`
// (or `s.draw(r)`) emits a quad into the active batch.
//
//   var s = Sprite.new(tex)
//   s.anchor(0.5, 0.5)
//   s.x = 100; s.y = 60
//   s.scale = 2
//   s.tint  = [1.0, 0.4, 0.4, 1.0]
//   r.draw(s)
//
// Anchor is a fractional offset (0,0 = top-left, 0.5,0.5 =
// centre, 1,1 = bottom-right) so changes to scale / size pivot
// around the same point. Rotation isn't supported in v0 — a
// rotation-aware drawSprite path lands once the renderer's
// vertex shader gains the matrix uniform per sprite.
class Sprite {
  construct new(texture) {
    _tex      = texture
    _x        = 0
    _y        = 0
    _w        = texture.width
    _h        = texture.height
    _scaleX   = 1
    _scaleY   = 1
    _anchorX  = 0
    _anchorY  = 0
    _tintR    = 1
    _tintG    = 1
    _tintB    = 1
    _tintA    = 1
    _u0       = 0
    _v0       = 0
    _u1       = 1
    _v1       = 1
    _visible  = true
  }

  texture  { _tex }
  texture=(t) { _tex = t }

  x        { _x }
  x=(v)    { _x = v }
  y        { _y }
  y=(v)    { _y = v }

  width    { _w }
  width=(v) { _w = v }
  height   { _h }
  height=(v) { _h = v }

  scaleX   { _scaleX }
  scaleX=(v) { _scaleX = v }
  scaleY   { _scaleY }
  scaleY=(v) { _scaleY = v }
  // Uniform scale shorthand — sets both axes.
  scale=(v) {
    _scaleX = v
    _scaleY = v
  }

  // Anchor is set as a fractional pair. (0,0) is the top-left
  // (default — quads grow down-right). (0.5, 0.5) centres the
  // sprite around (x, y).
  anchorX  { _anchorX }
  anchorY  { _anchorY }
  anchor(ax, ay) {
    _anchorX = ax
    _anchorY = ay
  }

  // Tint is multiplied with the sampled texture in the fragment
  // shader. RGB drives colourisation; A modulates opacity.
  tint     { [_tintR, _tintG, _tintB, _tintA] }
  tint=(rgba) {
    _tintR = rgba[0]
    _tintG = rgba[1]
    _tintB = rgba[2]
    _tintA = rgba[3]
  }
  alpha    { _tintA }
  alpha=(a) { _tintA = a }

  // UV rect — sub-region of `texture` to sample. (0,0)–(1,1) is
  // the whole image.
  uv(u0, v0, u1, v1) {
    _u0 = u0
    _v0 = v0
    _u1 = u1
    _v1 = v1
  }

  visible  { _visible }
  visible=(v) { _visible = v }

  // Translate the sprite's logical pos / size / anchor / scale
  // into a world-space drawSprite call against the renderer.
  draw(renderer) {
    if (!_visible) return
    var dw = _w * _scaleX
    var dh = _h * _scaleY
    var dx = _x - _anchorX * dw
    var dy = _y - _anchorY * dh
    if (_u0 == 0 && _v0 == 0 && _u1 == 1 && _v1 == 1 &&
        _tintR == 1 && _tintG == 1 && _tintB == 1 && _tintA == 1) {
      renderer.drawSprite(_tex, dx, dy, dw, dh)
    } else {
      renderer.drawSprite_(_tex, dx, dy, dw, dh, _u0, _v0, _u1, _v1,
                           _tintR, _tintG, _tintB, _tintA)
    }
  }

  toString { "Sprite(%(_tex), %(_x), %(_y), %(_w)x%(_h))" }
}

// -- 3D camera ---------------------------------------------------
//
// Either a perspective frustum or an ortho box. The camera owns
// its own eye / target / up + projection params; `viewProj`
// composes them into a Mat4 ready for the renderer's uniform.
//
//   var cam = Camera3D.perspective(60, w / h, 0.1, 100)
//   cam.lookAt(Vec3.new(3, 3, 5), Vec3.zero, Vec3.unitY)
//
// `fovY` is in DEGREES for the perspective variant. The
// orthographic variant takes half-extents and matches Mat4.ortho.
class Camera3D {
  // Perspective: vertical FOV in degrees, aspect, near, far.
  static perspective(fovY, aspect, near, far) {
    var c = Camera3D.new_()
    c.setProjection_(Mat4.perspective(fovY * 3.141592653589793 / 180, aspect, near, far))
    return c
  }

  // Orthographic: full width / height, near / far.
  static orthographic(width, height, near, far) {
    var c = Camera3D.new_()
    var hw = width / 2
    var hh = height / 2
    c.setProjection_(Mat4.ortho(-hw, hw, -hh, hh, near, far))
    return c
  }

  construct new_() {
    _proj   = Mat4.identity
    _view   = Mat4.identity
    _eye    = Vec3.new(0, 0, 5)
    _target = Vec3.new(0, 0, 0)
    _up     = Vec3.new(0, 1, 0)
    _viewDirty = true
  }

  setProjection_(m) { _proj = m }

  // Build the view matrix from eye → target. Idempotent — call
  // every frame if the camera moves.
  lookAt(eye, target, up) {
    _eye = eye
    _target = target
    _up = up
    _viewDirty = true
  }

  // Re-aim the projection without rebuilding the camera (e.g.
  // after a window resize).
  setPerspective(fovY, aspect, near, far) {
    _proj = Mat4.perspective(fovY * 3.141592653589793 / 180, aspect, near, far)
  }

  eye    { _eye }
  target { _target }
  up     { _up }

  // Compute view-projection. Lazily rebuilds the view matrix
  // when eye/target/up change.
  viewProj {
    if (_viewDirty) {
      _view = Mat4.lookAt(_eye, _target, _up)
      _viewDirty = false
    }
    return _proj * _view
  }
}

// -- Light -------------------------------------------------------
//
// One directional light + ambient term, encoded as the Renderer3D
// expects. Set `direction` as the vector light *travels in* (i.e.
// from sun → ground); the shader negates it before dotting with
// the surface normal.
class Light {
  construct new() {
    _direction = Vec3.new(-0.3, -1.0, -0.5)
    _color     = Vec3.new(1.0, 1.0, 1.0)
    _ambient   = Vec3.new(0.15, 0.15, 0.18)
  }
  direction       { _direction }
  direction=(v)   { _direction = v }
  color           { _color }
  color=(v)       { _color = v }
  ambient         { _ambient }
  ambient=(v)     { _ambient = v }
}

// -- Mesh --------------------------------------------------------
//
// Vertex layout: position vec3 + normal vec3 + uv vec2, 32 bytes
// total. Indices are u32 so meshes with > 65k vertices work.
//
// Build meshes via the static helpers (`Mesh.cube`, etc.) for
// procedural primitives, or call `Mesh.fromArrays(device,
// vertices, indices)` to upload your own buffers — typically
// from a glTF / OBJ loader.
class Mesh {
  construct new_(device, vertexBuffer, indexBuffer, indexCount) {
    _device = device
    _vbo    = vertexBuffer
    _ibo    = indexBuffer
    _indexCount = indexCount
  }

  vertexBuffer { _vbo }
  indexBuffer  { _ibo }
  indexCount   { _indexCount }

  // Build a Mesh from interleaved-vertex data + indices. `vertices`
  // is a flat List of Nums in pos.xyz / normal.xyz / uv.xy order
  // (8 floats per vertex). `indices` is a List<Num> of 0-based
  // u32 vertex indices.
  static fromArrays(device, vertices, indices) {
    var vbo = device.createBuffer({
      "size":  vertices.count * 4,
      "usage": ["vertex", "copy-dst"]
    })
    vbo.writeFloats(0, vertices)
    var ibo = device.createBuffer({
      "size":  indices.count * 4,
      "usage": ["index", "copy-dst"]
    })
    ibo.writeUints(0, indices)
    return Mesh.new_(device, vbo, ibo, indices.count)
  }

  // Axis-aligned cube centred on origin. Side length = 2 * half
  // (default 1 — total side length 2). Vertices are duplicated
  // per face so face-normals stay flat (no normal averaging).
  static cube(device) { cube(device, 1) }
  static cube(device, half) {
    var h = half
    // Vertices: 6 faces × 4 verts = 24, each (pos.xyz, n.xyz, u, v)
    var v = []
    var pushFace = Fn.new {|nx, ny, nz, p0, p1, p2, p3|
      // Each face: 4 verts, normal shared, uvs (0,0)(1,0)(1,1)(0,1)
      var quad = [p0, p1, p2, p3]
      var uvs  = [[0, 0], [1, 0], [1, 1], [0, 1]]
      var i = 0
      while (i < 4) {
        v.add(quad[i][0])
        v.add(quad[i][1])
        v.add(quad[i][2])
        v.add(nx)
        v.add(ny)
        v.add(nz)
        v.add(uvs[i][0])
        v.add(uvs[i][1])
        i = i + 1
      }
    }

    // +X face
    pushFace.call( 1, 0, 0,
      [ h, -h, -h], [ h, -h,  h], [ h,  h,  h], [ h,  h, -h])
    // -X face
    pushFace.call(-1, 0, 0,
      [-h, -h,  h], [-h, -h, -h], [-h,  h, -h], [-h,  h,  h])
    // +Y face
    pushFace.call( 0, 1, 0,
      [-h,  h, -h], [ h,  h, -h], [ h,  h,  h], [-h,  h,  h])
    // -Y face
    pushFace.call( 0,-1, 0,
      [-h, -h,  h], [ h, -h,  h], [ h, -h, -h], [-h, -h, -h])
    // +Z face
    pushFace.call( 0, 0, 1,
      [ h, -h,  h], [-h, -h,  h], [-h,  h,  h], [ h,  h,  h])
    // -Z face
    pushFace.call( 0, 0,-1,
      [-h, -h, -h], [ h, -h, -h], [ h,  h, -h], [-h,  h, -h])

    // Indices: 6 faces × 2 triangles × 3 = 36, base offsets 0,4,8,...
    var indices = []
    var f = 0
    while (f < 6) {
      var base = f * 4
      indices.add(base)
      indices.add(base + 1)
      indices.add(base + 2)
      indices.add(base)
      indices.add(base + 2)
      indices.add(base + 3)
      f = f + 1
    }
    return Mesh.fromArrays(device, v, indices)
  }

  // Flat plane on the X-Z axis (Y up), centred on origin.
  static plane(device, size) {
    var h = size / 2
    var v = [
      -h, 0, -h,  0, 1, 0,  0, 0,
       h, 0, -h,  0, 1, 0,  1, 0,
       h, 0,  h,  0, 1, 0,  1, 1,
      -h, 0,  h,  0, 1, 0,  0, 1
    ]
    var indices = [0, 1, 2, 0, 2, 3]
    return Mesh.fromArrays(device, v, indices)
  }

  destroy {
    _vbo.destroy
    _ibo.destroy
  }
}

// -- Material ----------------------------------------------------
//
// v0 supports a flat tint colour. Texture maps land alongside the
// glTF loader in a follow-up; the Renderer3D shader is shaped so
// adding `albedoMap` is a small change.
class Material {
  construct new() {
    _color = Vec4.new(0.8, 0.8, 0.85, 1.0)
  }
  construct new(color) {
    _color = color
  }
  color    { _color }
  color=(c) { _color = c }
}

// -- Renderer3D --------------------------------------------------
//
// One pipeline + one scene-uniform buffer + per-draw model + tint
// uploads. Each `renderer.draw(mesh, material, modelMatrix)`
// rewrites the per-draw uniform and emits one indexed draw call.
//
//   var renderer = Renderer3D.new(device, surfaceFormat, depthFormat)
//   renderer.beginFrame(pass, camera, light)
//   renderer.draw(cubeMesh, redMaterial, Mat4.translation(0, 0, 0))
//   renderer.draw(planeMesh, greenMaterial, Mat4.translation(0, -1, 0))
//
// The renderer doesn't own the depth target — the caller passes
// one as part of the render-pass descriptor (see the demo).
class Renderer3D {
  // Default lit shader. Single uniform block with view-projection,
  // model, tint, and one directional light.
  static LIT_WGSL_ {
    return "
      struct Uniforms {
        vp:           mat4x4<f32>,
        model:        mat4x4<f32>,
        normal_mat:   mat4x4<f32>,
        tint:         vec4<f32>,
        light_dir:    vec4<f32>,
        light_color:  vec4<f32>,
        ambient:      vec4<f32>,
      };
      @group(0) @binding(0) var<uniform> u: Uniforms;

      struct VsIn  {
        @location(0) pos:    vec3<f32>,
        @location(1) normal: vec3<f32>,
        @location(2) uv:     vec2<f32>,
      };
      struct VsOut {
        @builtin(position) clip:   vec4<f32>,
        @location(0)       world:  vec3<f32>,
        @location(1)       normal: vec3<f32>,
        @location(2)       uv:     vec2<f32>,
      };

      @vertex
      fn vs_main(in: VsIn) -> VsOut {
        var o: VsOut;
        let world_pos  = u.model * vec4<f32>(in.pos, 1.0);
        let world_norm = (u.normal_mat * vec4<f32>(in.normal, 0.0)).xyz;
        o.clip   = u.vp * world_pos;
        o.world  = world_pos.xyz;
        o.normal = world_norm;
        o.uv     = in.uv;
        return o;
      }

      @fragment
      fn fs_main(in: VsOut) -> @location(0) vec4<f32> {
        let n   = normalize(in.normal);
        let l   = normalize(-u.light_dir.xyz);
        let nl  = max(dot(n, l), 0.0);
        let lit = u.ambient.xyz + u.light_color.xyz * nl;
        let rgb = u.tint.xyz * lit;
        return vec4<f32>(rgb, u.tint.w);
      }
    "
  }

  static FLOATS_PER_VERTEX_  { 8 }   // 3 pos + 3 normal + 2 uv
  // Uniform block size: vp + model + normal_mat + tint + light_dir
  // + light_color + ambient = 64*3 + 16*4 = 256 bytes. Aligned.
  static UBO_BYTES_          { 256 }

  construct new(device, surfaceFormat, depthFormat) {
    _device = device

    var shader = device.createShaderModule({
      "code":  Renderer3D.LIT_WGSL_,
      "label": "renderer3d-lit"
    })

    _bgl = device.createBindGroupLayout({
      "entries": [
        { "binding": 0, "visibility": ["vertex", "fragment"], "kind": "uniform" }
      ]
    })
    _pipelineLayout = device.createPipelineLayout({"bindGroupLayouts": [_bgl]})

    _pipeline = device.createRenderPipeline({
      "layout": _pipelineLayout,
      "vertex": {
        "module": shader, "entryPoint": "vs_main",
        "buffers": [{
          "arrayStride": Renderer3D.FLOATS_PER_VERTEX_ * 4,
          "stepMode": "vertex",
          "attributes": [
            { "shaderLocation": 0, "offset": 0,  "format": "float32x3" },
            { "shaderLocation": 1, "offset": 12, "format": "float32x3" },
            { "shaderLocation": 2, "offset": 24, "format": "float32x2" }
          ]
        }]
      },
      "fragment": {
        "module": shader, "entryPoint": "fs_main",
        "targets": [{ "format": surfaceFormat }]
      },
      "primitive":    { "topology": "triangle-list", "cullMode": "back" },
      "depthStencil": {
        "format": depthFormat, "depthWriteEnabled": true,
        "depthCompare": "less"
      },
      "label": "renderer3d-pipeline"
    })

    _ubo = device.createBuffer({
      "size":  Renderer3D.UBO_BYTES_,
      "usage": ["uniform", "copy-dst"],
      "label": "renderer3d-ubo"
    })
    _bindGroup = device.createBindGroup({
      "layout":  _bgl,
      "entries": [{ "binding": 0, "buffer": _ubo, "size": Renderer3D.UBO_BYTES_ }]
    })

    _vp        = Mat4.identity
    _light     = Light.new()
    _pass      = null
  }

  // Begin a frame. Stores the active pass + scene uniforms;
  // each subsequent draw rewrites the model + tint slots.
  beginFrame(pass, camera, light) {
    _pass = pass
    _vp = camera.viewProj
    _light = light
    pass.setPipeline(_pipeline)
    pass.setBindGroup(0, _bindGroup)
  }

  // Issue one draw. `model` is a Mat4 transform. The renderer
  // uploads (vp, model, normal_mat, tint, light) into the single
  // uniform block, then dispatches an indexed draw.
  draw(mesh, material, model) {
    if (_pass == null) Fiber.abort("Renderer3D.draw: call beginFrame first.")

    // Build a per-draw uniform block by concatenating the floats.
    // Order matches the shader's Uniforms struct exactly.
    var floats = []
    appendMat4_(floats, _vp)
    appendMat4_(floats, model)
    // normal_mat = inverse(transpose(model)). For orthonormal
    // model matrices (rotation + translation only), the model
    // matrix's upper-3x3 itself works as the normal matrix —
    // good enough for v0; full inverse-transpose lands when we
    // expose a Mat4.inverse helper.
    appendMat4_(floats, model)
    appendVec4_(floats, material.color)
    var ld = _light.direction
    floats.add(ld.x)
    floats.add(ld.y)
    floats.add(ld.z)
    floats.add(0)
    var lc = _light.color
    floats.add(lc.x)
    floats.add(lc.y)
    floats.add(lc.z)
    floats.add(0)
    var amb = _light.ambient
    floats.add(amb.x)
    floats.add(amb.y)
    floats.add(amb.z)
    floats.add(0)

    _ubo.writeFloats(0, floats)

    var pass = _pass
    pass.setVertexBuffer(0, mesh.vertexBuffer)
    pass.setIndexBuffer(mesh.indexBuffer, "uint32")
    pass.drawIndexed(mesh.indexCount)
  }

  endFrame() { _pass = null }

  appendMat4_(out, m) {
    var data = m.data
    var i = 0
    while (i < 16) {
      out.add(data[i])
      i = i + 1
    }
  }
  appendVec4_(out, v) {
    out.add(v.x)
    out.add(v.y)
    out.add(v.z)
    out.add(v.w)
  }

  destroy {
    _ubo.destroy
    _pipeline.destroy
    _pipelineLayout.destroy
    _bgl.destroy
  }
}

// -- Hot-reloaded pipeline ---------------------------------------
//
// Reads its WGSL from a `@hatch:assets` database; rebuilds the
// underlying RenderPipeline in place whenever the shader file's
// content hash advances. From the caller's perspective it
// behaves exactly like a normal RenderPipeline — bind it via
// `pass.setPipeline(livePipeline)` and the .id getter resolves
// to the current internal pipeline at record time.
//
//   var assets   = Assets.open("assets")
//   var pipeline = LivePipeline.new(device, assets,
//                                   "shaders/triangle.wgsl", {
//     "vertex":   { "entryPoint": "vs_main" },
//     "fragment": { "entryPoint": "fs_main",
//                   "targets": [{"format": "rgba8unorm"}] },
//     "primitive": { "topology": "triangle-list" }
//   })
//
// Edits to the shader file fire the rebuild between frames; in-
// flight render passes that already captured the old id finish
// against the old code, the next pass picks up the new one.
class LivePipeline {
  construct new(device, db, shaderPath, descriptor) {
    _device     = device
    _db         = db
    _shaderPath = shaderPath
    _desc       = descriptor
    _pipeline   = null
    _shader     = null
    rebuild_()
    var self = this
    db.on(shaderPath) {|asset| self.rebuild_() }
  }

  // Forwards setPipeline / debug callers — always points at the
  // freshest internal pipeline.
  id { _pipeline.id }

  // Drop watchers + the underlying pipeline + shader. The
  // assets db's on() registration leaks intentionally — the
  // user is expected to keep the LivePipeline alive for the
  // lifetime of the application.
  destroy {
    if (_pipeline != null) _pipeline.destroy
    if (_shader != null) _shader.destroy
    _pipeline = null
    _shader = null
  }

  // Re-read shader source, recompile, rebuild the pipeline using
  // the new shader as both vertex + fragment module. Old shader +
  // pipeline are dropped after the new ones land — wgpu
  // ref-counts them, so any setPipeline that already captured the
  // old id still resolves correctly through the foreign registry
  // until the encoder it lives in is submitted.
  rebuild_() {
    var oldPipe   = _pipeline
    var oldShader = _shader
    var src = _db.text(_shaderPath)
    var shader = _device.createShaderModule({"code": src, "label": _shaderPath})

    var dec = { "vertex": {
      "module":     shader,
      "entryPoint": _desc["vertex"]["entryPoint"]
    } }
    if (_desc["vertex"].containsKey("buffers")) {
      dec["vertex"]["buffers"] = _desc["vertex"]["buffers"]
    }
    if (_desc.containsKey("layout"))    dec["layout"]    = _desc["layout"]
    if (_desc.containsKey("fragment")) {
      var f = _desc["fragment"]
      dec["fragment"] = {
        "module":     shader,
        "entryPoint": f["entryPoint"],
        "targets":    f["targets"]
      }
    }
    if (_desc.containsKey("primitive"))    dec["primitive"]    = _desc["primitive"]
    if (_desc.containsKey("depthStencil")) dec["depthStencil"] = _desc["depthStencil"]
    if (_desc.containsKey("label"))        dec["label"]        = _desc["label"]

    _shader   = shader
    _pipeline = _device.createRenderPipeline(dec)

    if (oldPipe != null) oldPipe.destroy
    if (oldShader != null) oldShader.destroy
  }
}

// -- Surface + SurfaceFrame --------------------------------------
//
// Surface is the swap-chain target tied to a window. After
// `Device.createSurface(windowHandle)`, you must call
// `surface.configure({...})` before the first `acquire`, and
// again on every window-resize event:
//
//   surface.configure({
//     "width": 1280, "height": 720,
//     "format": "bgra8unorm",
//     "presentMode": "fifo"           // default
//   })
//
// The render loop is:
//
//   var frame = surface.acquire()    // a SurfaceFrame
//   var enc = device.createCommandEncoder()
//   var pass = enc.beginRenderPass({
//     "colorAttachments": [{
//       "view": frame.view, ...
//     }]
//   })
//   pass.setPipeline(p); pass.draw(3); pass.end
//   enc.finish
//   device.submit([enc])
//   frame.present                    // schedules vblank
class Surface {
  construct new_(id, device) {
    _id     = id
    _device = device
  }

  id { _id }

  configure(descriptor) { GpuCore.surfaceConfigure(_id, descriptor) }

  // Acquire the next swap-chain image as a SurfaceFrame. The
  // frame's `view` is a TextureView usable in render-pass
  // colorAttachments; `frame.present` schedules the swap.
  // Aborts if the swap chain is lost / outdated — callers
  // should re-configure on a window-resize event and retry.
  acquire() {
    var pair = GpuCore.surfaceAcquire(_id)
    return SurfaceFrame.new_(pair["frame"], pair["view"])
  }

  destroy {
    GpuCore.surfaceDestroy(_id)
    _id = -1
  }
}

// One in-flight swap-chain frame. `view` is consumed by render
// passes, `present` retires the frame to the compositor. The
// underlying SurfaceTexture is held in the foreign registry so
// the view stays valid for the whole render pass; presenting
// drops both at once.
class SurfaceFrame {
  construct new_(frameId, viewId) {
    _id   = frameId
    _view = TextureView.new_(viewId, null, 0, 0)
  }

  id   { _id }
  view { _view }

  present {
    GpuCore.surfacePresentFrame(_id)
    _id = -1
  }
}
