// @hatch:gpu. GPU primitives backed by wgpu.
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

// Target-agnostic classes — same source in `gpu_web`. Re-exported
// here so consumers can `import "@hatch:gpu" for Shader, Material,
// Renderer3D` regardless of which backend bundle they're running
// under.
import "./gpu_shader"     for Shader
import "./gpu_material"   for Material
import "./gpu_renderer3d" for Renderer3D

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

  #!symbol = "wlift_gpu_buffer_write_floats_n"
  foreign static bufferWriteFloatsN(id, offset, data, count)

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

  // -- Compute pipelines -----------------------------------------

  #!symbol = "wlift_gpu_compute_pipeline_create"
  foreign static computePipelineCreate(deviceId, descriptor)

  #!symbol = "wlift_gpu_compute_pipeline_destroy"
  foreign static computePipelineDestroy(id)

  // -- CommandEncoder + render pass + readback -------------------

  #!symbol = "wlift_gpu_encoder_create"
  foreign static encoderCreate(deviceId, descriptor)

  #!symbol = "wlift_gpu_encoder_destroy"
  foreign static encoderDestroy(id)

  #!symbol = "wlift_gpu_encoder_record_pass"
  foreign static encoderRecordPass(encoderId, descriptor)

  #!symbol = "wlift_gpu_encoder_record_compute_pass"
  foreign static encoderRecordComputePass(encoderId, descriptor)

  #!symbol = "wlift_gpu_encoder_copy_texture_to_buffer"
  foreign static encoderCopyTextureToBuffer(encoderId, textureId, bufferId, descriptor)

  #!symbol = "wlift_gpu_encoder_finish"
  foreign static encoderFinish(id)

  #!symbol = "wlift_gpu_queue_submit"
  foreign static queueSubmit(deviceId, encoderIds)

  #!symbol = "wlift_gpu_buffer_read_bytes"
  foreign static bufferReadBytes(id)

  #!symbol = "wlift_gpu_buffer_read_into_typed_array"
  foreign static bufferReadInto(id, typedArray)

  #!symbol = "wlift_gpu_encoder_copy_buffer_to_buffer"
  foreign static encoderCopyBufferToBuffer(encoderId, srcId, dstId, srcOffset, dstOffset, size)

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
  // bytes-to-texture path (also used for font atlases, dynamic
  // updates, GPU compute outputs, etc.).

  #!symbol = "wlift_gpu_queue_write_texture"
  foreign static queueWriteTexture(textureId, bytes, descriptor)
}

/// Static module entry. `Gpu.requestDevice({...})` returns the
/// process-wide [Device]; everything else (textures, buffers,
/// pipelines, surfaces) is built off of the device.
class Gpu {
  /// Request a GPU device + queue. `descriptor` is a Map; all
  /// keys are optional:
  ///
  /// - `"backends"`: `"primary"` (default), `"all"`, `"metal"`,
  ///   `"vulkan"`, `"dx12"`, or `"gl"`.
  /// - `"powerPreference"`: `"low-power"` or `"high-performance"`.
  /// - `"label"`: String passed to wgpu for diagnostics.
  ///
  /// Aborts the fiber when no compatible adapter is available.
  ///
  /// @param {Map} descriptor
  /// @returns {Device}
  static requestDevice(descriptor) {
    if (!(descriptor is Map)) Fiber.abort("Gpu.requestDevice: descriptor must be a Map.")
    var id = GpuCore.requestDevice(descriptor)
    return Device.new_(id)
  }

  /// Request a GPU device with default options.
  /// @returns {Device}
  static requestDevice() { Gpu.requestDevice({}) }
}

/// Owns one wgpu device and queue. All GPU resource creation
/// hangs off here: buffers, textures, shaders, pipelines, command
/// encoders, surfaces.
class Device {
  construct new_(id) {
    _id = id
  }

  /// Foreign-handle id (internal).
  /// @returns {Num}
  id { _id }

  /// Adapter / device metadata as a Map with `name` / `backend` /
  /// `deviceType` keys. Useful for diagnostics and for asserting
  /// "is this a real GPU" inside CI.
  /// @returns {Map}
  info { GpuCore.deviceInfo(_id) }

  /// Allocate a [Buffer] on this device. Descriptor keys:
  ///
  /// - `"size"`: Num, bytes (must be multiple of 4).
  /// - `"usage"`: list with any of `"vertex"`, `"index"`,
  ///   `"uniform"`, `"storage"`, `"indirect"`, `"copy-src"`,
  ///   `"copy-dst"`, `"map-read"`, `"map-write"`.
  /// - `"label"`: optional String, diagnostics.
  ///
  /// @param {Map} descriptor
  /// @returns {Buffer}
  createBuffer(descriptor) {
    if (!(descriptor is Map)) Fiber.abort("Device.createBuffer: descriptor must be a Map.")
    var bid = GpuCore.bufferCreate(_id, descriptor)
    return Buffer.new_(bid, descriptor["size"])
  }

  /// Compile a WGSL [ShaderModule]. Descriptor:
  ///
  /// - `"code"`: String, WGSL source.
  /// - `"label"`: optional String, diagnostics.
  ///
  /// @param {Map} descriptor
  /// @returns {ShaderModule}
  createShaderModule(descriptor) {
    if (!(descriptor is Map)) Fiber.abort("Device.createShaderModule: descriptor must be a Map.")
    var sid = GpuCore.shaderCreate(_id, descriptor)
    return ShaderModule.new_(sid)
  }

  /// Allocate a [Texture]. Descriptor:
  ///
  /// - `"width"`, `"height"`: Num.
  /// - `"depth"`: optional, layer count for arrays (default 1).
  /// - `"format"`: `"rgba8unorm"`, `"depth32float"`, etc.
  /// - `"usage"`: list with any of `"render-attachment"`,
  ///   `"texture-binding"`, `"storage-binding"`, `"copy-src"`,
  ///   `"copy-dst"`.
  /// - `"sampleCount"`: optional, default 1.
  /// - `"label"`: optional, diagnostics.
  ///
  /// @param {Map} descriptor
  /// @returns {Texture}
  createTexture(descriptor) {
    if (!(descriptor is Map)) Fiber.abort("Device.createTexture: descriptor must be a Map.")
    var tid = GpuCore.textureCreate(_id, descriptor)
    return Texture.new_(tid, descriptor)
  }

  /// Build a [Texture] from a decoded image. The argument
  /// duck-types on `width`, `height`, and `pixels` (a `ByteArray`
  /// or list of RGBA8 bytes). Anything that exposes those three
  /// reads works, including `@hatch:image`'s `Image` class.
  ///
  /// ## Example
  ///
  /// ```wren
  /// import "@hatch:image"  for Image
  /// import "@hatch:assets" for Assets
  ///
  /// var img = Image.decode(Assets.open("assets").bytes("hero.png"))
  /// var tex = device.uploadImage(img)
  /// ```
  ///
  /// @param {Object} image
  /// @returns {Texture}
  uploadImage(image) { uploadImage(image, {}) }

  /// Same as `uploadImage(image)` with an `options` Map for
  /// `"label"`, `"format"` (default `"rgba8unorm-srgb"`), and
  /// `"extraUsage"` (appended to the default
  /// `["texture-binding", "copy-dst"]`).
  ///
  /// @param {Object} image
  /// @param {Map} options
  /// @returns {Texture}
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

  /// Direct CPU-to-texture upload via the device queue. Useful
  /// for dynamic textures (font atlases, GPU-readback round-
  /// trips, procedurally-generated content). Descriptor:
  ///
  /// - `"x"`, `"y"`: optional copy origin within the texture
  ///   (default 0).
  /// - `"width"`, `"height"`: Num.
  /// - `"bytesPerRow"`: Num.
  /// - `"rowsPerImage"`: optional, default `height`.
  ///
  /// @param {Texture} texture
  /// @param {ByteArray} bytes
  /// @param {Map} descriptor
  writeTexture(texture, bytes, descriptor) {
    GpuCore.queueWriteTexture(texture.id, bytes, descriptor)
  }

  /// Allocate a [Sampler]. Descriptor keys (all optional):
  ///
  /// - `"magFilter"` / `"minFilter"`: `"nearest"` or `"linear"`
  ///   (default `"linear"`).
  /// - `"mipmapFilter"`: `"nearest"` or `"linear"` (default
  ///   `"nearest"`).
  /// - `"addressModeU"` / `"addressModeV"` / `"addressModeW"`:
  ///   `"clamp-to-edge"`, `"repeat"`, or `"mirror-repeat"`.
  /// - `"label"`: optional String.
  ///
  /// @param {Map} descriptor
  /// @returns {Sampler}
  createSampler(descriptor) {
    if (!(descriptor is Map)) descriptor = {}
    var sid = GpuCore.samplerCreate(_id, descriptor)
    return Sampler.new_(sid)
  }

  /// Create a [BindGroupLayout]. Descriptor:
  ///
  /// - `"entries"`: list of Maps, each with:
  ///   - `"binding"`: Num.
  ///   - `"visibility"`: list with any of `"vertex"`,
  ///     `"fragment"`, `"compute"`.
  ///   - `"kind"`: `"uniform"`, `"storage"`,
  ///     `"read-only-storage"`, `"sampler"`, or `"texture"`.
  ///   - `"sampleType"` (texture-only): `"float"`, `"depth"`,
  ///     `"uint"`, or `"sint"`.
  ///
  /// @param {Map} descriptor
  /// @returns {BindGroupLayout}
  createBindGroupLayout(descriptor) {
    var lid = GpuCore.bindGroupLayoutCreate(_id, descriptor)
    return BindGroupLayout.new_(lid)
  }

  /// Combine [BindGroupLayout]s into a [PipelineLayout].
  /// Descriptor: `"bindGroupLayouts"` is a list of layouts.
  ///
  /// @param {Map} descriptor
  /// @returns {PipelineLayout}
  createPipelineLayout(descriptor) {
    var ids = []
    for (l in descriptor["bindGroupLayouts"]) ids.add(l.id)
    var pdesc = { "bindGroupLayouts": ids }
    if (descriptor.containsKey("label")) pdesc["label"] = descriptor["label"]
    var plid = GpuCore.pipelineLayoutCreate(_id, pdesc)
    return PipelineLayout.new_(plid)
  }

  /// Bind buffers / samplers / texture views to a layout's
  /// slots. Descriptor:
  ///
  /// - `"layout"`: a [BindGroupLayout].
  /// - `"entries"`: list of Maps, each with `"binding": Num`
  ///   plus one of `"buffer": Buffer` (optionally `"offset"` /
  ///   `"size"`), `"sampler": Sampler`, or `"view": TextureView`.
  ///
  /// @param {Map} descriptor
  /// @returns {BindGroup}
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

  /// Compile a [RenderPipeline] from a descriptor (vertex /
  /// fragment shader entry points, primitive state, blend / cull
  /// modes, target formats, and so on). See `gpu.spec.wren` for
  /// the full descriptor shape.
  ///
  /// @param {Map} descriptor
  /// @returns {RenderPipeline}
  createRenderPipeline(descriptor) {
    var dec = RenderPipeline.normalize_(descriptor)
    var pid = GpuCore.renderPipelineCreate(_id, dec)
    return RenderPipeline.new_(pid)
  }

  /// Compile a [ComputePipeline] from a descriptor. Keys:
  ///
  /// - `"module"` ([ShaderModule], required) — the WGSL module
  ///   containing the compute entry point.
  /// - `"entryPoint"` (String, required) — the `@compute` function
  ///   in `module` to dispatch.
  /// - `"layout"` (`"auto"` or [PipelineLayout], optional) —
  ///   defaults to `"auto"`.
  /// - `"label"` (String, optional).
  ///
  /// @param {Map} descriptor
  /// @returns {ComputePipeline}
  createComputePipeline(descriptor) {
    var dec = ComputePipeline.normalize_(descriptor)
    var pid = GpuCore.computePipelineCreate(_id, dec)
    return ComputePipeline.new_(pid)
  }

  /// Build a fresh [CommandEncoder] for this frame.
  /// @returns {CommandEncoder}
  createCommandEncoder() { createCommandEncoder({}) }

  /// Build a [CommandEncoder] from an explicit descriptor
  /// (currently only `{"label": String}` is honoured).
  ///
  /// @param {Map} descriptor
  /// @returns {CommandEncoder}
  createCommandEncoder(descriptor) {
    var eid = GpuCore.encoderCreate(_id, descriptor)
    return CommandEncoder.new_(eid, this)
  }

  /// Submit one or more finished [CommandEncoder]s to the GPU
  /// queue. Encoders must have been closed via `enc.finish`.
  ///
  /// @param {List} encoders
  submit(encoders) {
    var ids = []
    for (e in encoders) ids.add(e.id)
    GpuCore.queueSubmit(_id, ids)
  }

  /// Build a [Surface] bound to this device from a raw window
  /// handle. The `handle` Map is platform-tagged with the same
  /// shape as `raw_window_handle`'s variants; any window provider
  /// can produce one. `@hatch:window` is the default winit-backed
  /// implementation, but custom embedders (IDE viewports, native
  /// shells, host apps) just need to surface the right pointer
  /// integers and pick the right `"platform"` string.
  ///
  /// ## Example
  ///
  /// ```wren
  /// // macOS via @hatch:window:
  /// var surface = device.createSurface(window.handle)
  ///
  /// // Custom AppKit embed (already have an NSView*):
  /// var surface = device.createSurface({
  ///   "platform": "appkit",
  ///   "ns_view":  nsViewPtr      // as Num
  /// })
  /// ```
  ///
  /// The caller MUST keep the underlying window alive at least
  /// as long as the Surface; wgpu does not pin it.
  ///
  /// @param {Map} handle
  /// @returns {Surface}
  createSurface(handle) {
    if (!(handle is Map)) Fiber.abort("Device.createSurface: handle must be a Map.")
    var sid = GpuCore.surfaceCreate(_id, handle)
    return Surface.new_(sid, this)
  }

  /// Drop the underlying wgpu device and queue. Idempotent;
  /// calling twice is fine.
  destroy {
    GpuCore.deviceDestroy(_id)
    _id = -1
  }

  toString { "Device(%(_id))" }
}

/// GPU buffer (vertex / index / uniform / storage). Always
/// owned by exactly one [Device]. Dropping the device invalidates
/// the buffer; writes after that surface a runtime error.
class Buffer {
  construct new_(id, size) {
    _id = id
    _size = size
  }

  /// Foreign-handle id (internal).
  /// @returns {Num}
  id   { _id }
  /// Buffer size in bytes.
  /// @returns {Num}
  size { _size }

  /// Pack a list of f32 values starting at `offset` bytes. One
  /// FFI call regardless of list length. Accepts either a
  /// `List<Num>` (each entry is converted f64 → f32) or a
  /// `Float32Array` (the full backing bytes are written verbatim
  /// — one `queue.write_buffer` call, zero per-element walking).
  ///
  /// @param {Num} offset
  /// @param {List|Float32Array} data
  writeFloats(offset, data) { GpuCore.bufferWriteFloats(_id, offset, data) }

  /// Like [Buffer.writeFloats] but for a partial upload of a
  /// pre-allocated `Float32Array` — only the first `count`
  /// floats are sent. Lets `Renderer2D` flush its variable per-
  /// frame vertex stream without paying the bandwidth cost of
  /// the whole `MAX_SPRITES`-sized backing array. The plugin
  /// emits a single `queue.write_buffer` of `count * 4` bytes;
  /// no per-element walking either way.
  ///
  /// @param {Num} offset
  /// @param {Float32Array} data
  /// @param {Num} count    number of f32 lanes to upload
  writeFloatsN(offset, data, count) {
    GpuCore.bufferWriteFloatsN(_id, offset, data, count)
  }

  /// Pack a list of u32 values starting at `offset` bytes. One
  /// FFI call regardless of list length.
  ///
  /// @param {Num} offset
  /// @param {List} data
  writeUints(offset, data)  { GpuCore.bufferWriteUints(_id, offset, data) }

  /// Pack a list of `Mat4` values (16 f32 row-major per element)
  /// starting at `offset`.
  ///
  /// @param {Num} offset
  /// @param {List} mats
  writeMat4s(offset, mats) { GpuCore.bufferWriteMat4s(_id, offset, Buffer.dataOf_(mats)) }

  /// Pack a list of `Vec3` values (3 f32 each, no padding; the
  /// caller pads if the shader expects std140-aligned vec3s).
  ///
  /// @param {Num} offset
  /// @param {List} vecs
  writeVec3s(offset, vecs) { GpuCore.bufferWriteVec3s(_id, offset, Buffer.dataOf_(vecs)) }

  /// Pack a list of `Vec4` values (4 f32 each).
  ///
  /// @param {Num} offset
  /// @param {List} vecs
  writeVec4s(offset, vecs) { GpuCore.bufferWriteVec4s(_id, offset, Buffer.dataOf_(vecs)) }

  /// Pack a list of `Quat` values (4 f32 each, `(w, x, y, z)`
  /// order).
  ///
  /// @param {Num} offset
  /// @param {List} quats
  writeQuats(offset, quats) { GpuCore.bufferWriteQuats(_id, offset, Buffer.dataOf_(quats)) }

  // Extract the `data` getter from each element. Done in Wren so
  // the foreign packer doesn't need to call back into the VM mid-
  // conversion (a path that fights the GC's nursery promotion).
  static dataOf_(items) {
    var out = []
    for (item in items) out.add(item.data)
    return out
  }

  /// Synchronously map for read + copy bytes back to Wren as a
  /// `List` of Nums (one entry per byte). Blocks the host while
  /// wgpu drains pending submissions, so use sparingly. Best
  /// suited for tests and one-shot CPU readback.
  ///
  /// @returns {List}
  readBytes() { GpuCore.bufferReadBytes(_id) }

  /// Fast in-place readback. Maps the buffer for read, copies its
  /// bytes into `typedArray` (which must match the buffer's byte
  /// length), then unmaps. Skips the per-byte `Num` allocation that
  /// `readBytes` pays — required for sane wall-clock at compute
  /// readback sizes (megabytes and up).
  ///
  /// @param {Float32Array|Uint8Array|Int32Array} typedArray
  readInto(typedArray) { GpuCore.bufferReadInto(_id, typedArray) }

  /// Release the buffer's GPU memory. Idempotent.
  destroy {
    GpuCore.bufferDestroy(_id)
    _id = -1
  }

  toString { "Buffer(%(_id), %(_size) bytes)" }
}

/// Compiled WGSL module. Stamped out by
/// [Device.createShaderModule]. Used as a vertex / fragment /
/// compute stage source on a pipeline.
class ShaderModule {
  construct new_(id) { _id = id }
  /// Foreign-handle id (internal).
  /// @returns {Num}
  id { _id }
  /// Release the compiled shader. Idempotent.
  destroy {
    GpuCore.shaderDestroy(_id)
    _id = -1
  }
  toString { "ShaderModule(%(_id))" }
}

/// 2D texture. Render attachment, readback source, or sampled
/// input for fragment shaders. Only the `D2` dimension is exposed
/// today; 1D / 3D / cube can be added on demand.
class Texture {
  construct new_(id, descriptor) {
    _id     = id
    _width  = descriptor["width"]
    _height = descriptor["height"]
    _format = descriptor["format"]
  }

  /// Foreign-handle id (internal).
  /// @returns {Num}
  id     { _id }
  /// Texture width in texels.
  /// @returns {Num}
  width  { _width }
  /// Texture height in texels.
  /// @returns {Num}
  height { _height }
  /// Texture format string (`"rgba8unorm"`, `"depth32float"`, etc.).
  /// @returns {String}
  format { _format }

  /// Build a default [TextureView]. Covers the whole texture at
  /// the texture's own format. Higher-level renderers can build
  /// sliced views by calling the foreign API directly.
  /// @returns {TextureView}
  createView() {
    var vid = GpuCore.textureCreateView(_id)
    return TextureView.new_(vid, _format, _width, _height)
  }

  /// Release the texture. Idempotent.
  destroy {
    GpuCore.textureDestroy(_id)
    _id = -1
  }

  toString { "Texture(%(_id), %(_width)x%(_height) %(_format))" }
}

/// View into a [Texture]. Bound into a pipeline's colour and
/// depth attachments, and into [BindGroup] entries.
class TextureView {
  construct new_(id, format, width, height) {
    _id     = id
    _format = format
    _width  = width
    _height = height
  }

  /// Foreign-handle id (internal).
  /// @returns {Num}
  id     { _id }
  /// View format string.
  /// @returns {String}
  format { _format }
  /// Width in texels.
  /// @returns {Num}
  width  { _width }
  /// Height in texels.
  /// @returns {Num}
  height { _height }

  /// Release the view. Idempotent.
  destroy {
    GpuCore.viewDestroy(_id)
    _id = -1
  }

  toString { "TextureView(%(_id))" }
}

/// GPU sampler. Controls how a [Texture] is filtered and
/// addressed when sampled in a fragment shader.
class Sampler {
  construct new_(id) { _id = id }
  /// Foreign-handle id (internal).
  /// @returns {Num}
  id { _id }
  /// Release the sampler. Idempotent.
  destroy {
    GpuCore.samplerDestroy(_id)
    _id = -1
  }
  toString { "Sampler(%(_id))" }
}

/// -- Bind groups -------------------------------------------------

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

/// -- Render pipeline --------------------------------------------

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

/// A compiled compute pipeline. Built by
/// [Device.createComputePipeline]; bound inside a [ComputePass] via
/// `pass.setPipeline`.
class ComputePipeline {
  construct new_(id) { _id = id }
  id { _id }
  destroy {
    GpuCore.computePipelineDestroy(_id)
    _id = -1
  }

  static normalize_(d) {
    var out = {
      "module":     d["module"].id,
      "entryPoint": d["entryPoint"]
    }
    if (d.containsKey("label")) out["label"] = d["label"]
    if (d.containsKey("layout")) {
      var l = d["layout"]
      out["layout"] = (l is String) ? l : l.id
    }
    return out
  }
}

// -- Command encoder + render pass -------------------------------

/// Records GPU commands. Build one per frame via
/// [Device.createCommandEncoder], open a render pass with
/// [CommandEncoder.beginRenderPass], record draws, call `finish`,
/// then submit through `device.submit([enc])`.
class CommandEncoder {
  construct new_(id, device) {
    _id = id
    _device = device
  }

  /// Foreign-handle id (internal).
  /// @returns {Num}
  id     { _id }
  /// The owning [Device].
  /// @returns {Device}
  device { _device }

  /// Open a render pass against `descriptor` (colour / depth
  /// attachments, clear values, etc.). Returns a [RenderPass]
  /// that accumulates commands; call `pass.end` to flush them
  /// into the encoder.
  ///
  /// @param {Map} descriptor
  /// @returns {RenderPass}
  beginRenderPass(descriptor) {
    return RenderPass.new_(this, descriptor)
  }

  /// Open a compute pass against `descriptor`. Returns a
  /// [ComputePass] that accumulates `setPipeline` / `setBindGroup`
  /// / `dispatchWorkgroups` commands; `pass.end` flushes them into
  /// the encoder.
  ///
  /// `descriptor` keys are all optional today (`label`). Future
  /// timestamp / query knobs will land here without breaking
  /// existing callers.
  ///
  /// @param {Map} descriptor
  /// @returns {ComputePass}
  beginComputePass(descriptor) {
    return ComputePass.new_(this, descriptor)
  }
  /// Same as `beginComputePass({})`.
  /// @returns {ComputePass}
  beginComputePass() {
    return ComputePass.new_(this, {})
  }

  /// Copy `texture` into `buffer` so the host can read pixels
  /// back. Descriptor keys:
  ///
  /// - `"width"`, `"height"`: copy region size.
  /// - `"bytesPerRow"`, `"rowsPerImage"`: optional layout
  ///   overrides.
  ///
  /// @param {Texture} texture
  /// @param {Buffer} buffer
  /// @param {Map} descriptor
  copyTextureToBuffer(texture, buffer, descriptor) {
    GpuCore.encoderCopyTextureToBuffer(_id, texture.id, buffer.id, descriptor)
  }

  /// Copy `size` bytes from `src` (at `srcOffset`) into `dst` (at
  /// `dstOffset`). The standard plumbing for moving compute
  /// outputs from a `storage | copy-src` buffer into a
  /// `copy-dst | map-read` staging buffer.
  ///
  /// @param {Buffer} src
  /// @param {Buffer} dst
  /// @param {Num} srcOffset
  /// @param {Num} dstOffset
  /// @param {Num} size
  copyBufferToBuffer(src, dst, srcOffset, dstOffset, size) {
    GpuCore.encoderCopyBufferToBuffer(_id, src.id, dst.id, srcOffset, dstOffset, size)
  }
  /// Convenience: copy the full `size` bytes from `src@0` → `dst@0`.
  ///
  /// @param {Buffer} src
  /// @param {Buffer} dst
  /// @param {Num} size
  copyBufferToBuffer(src, dst, size) {
    copyBufferToBuffer(src, dst, 0, 0, size)
  }

  /// Close recording. Returns `this` so callers can chain
  /// `device.submit([enc.finish])` on a single line.
  /// @returns {CommandEncoder}
  finish {
    GpuCore.encoderFinish(_id)
    return this
  }

  /// Release the encoder. Idempotent.
  destroy {
    GpuCore.encoderDestroy(_id)
    _id = -1
  }
}

/// Render-pass builder. Accumulates commands client-side and
/// emits them in a single foreign call on `end`. Sidesteps the
/// `wgpu::RenderPass<'a>` lifetime; no long-lived borrow on the
/// encoder needs to cross the FFI boundary.
class RenderPass {
  construct new_(encoder, descriptor) {
    _encoder = encoder
    _desc    = descriptor
    _cmds    = []
  }

  /// Bind a [RenderPipeline] for subsequent draws.
  /// @param {RenderPipeline} p
  /// @returns {RenderPass}
  setPipeline(p) {
    _cmds.add({ "op": "setPipeline", "pipeline": p.id })
    return this
  }

  /// Bind a [Buffer] as the vertex source for `slot`.
  /// @param {Num} slot
  /// @param {Buffer} buffer
  /// @returns {RenderPass}
  setVertexBuffer(slot, buffer) {
    _cmds.add({ "op": "setVertexBuffer", "slot": slot, "buffer": buffer.id })
    return this
  }

  /// Bind a [Buffer] as the index source. `format` is
  /// `"uint16"` (default) or `"uint32"`.
  ///
  /// @param {Buffer} buffer
  /// @param {String} format
  /// @returns {RenderPass}
  setIndexBuffer(buffer, format) {
    _cmds.add({ "op": "setIndexBuffer", "buffer": buffer.id, "format": format })
    return this
  }
  /// Bind a `uint16`-format [Buffer] as the index source.
  /// @param {Buffer} buffer
  /// @returns {RenderPass}
  setIndexBuffer(buffer) { setIndexBuffer(buffer, "uint16") }

  /// Bind a [BindGroup] at `index`.
  /// @param {Num} index
  /// @param {BindGroup} group
  /// @returns {RenderPass}
  setBindGroup(index, group) {
    _cmds.add({ "op": "setBindGroup", "index": index, "group": group.id })
    return this
  }

  /// Issue a non-indexed draw of `vertexCount` vertices.
  /// @param {Num} vertexCount
  /// @returns {RenderPass}
  draw(vertexCount) { draw(vertexCount, 1) }

  /// Same as `draw(vertexCount)` with an explicit instance count.
  /// @param {Num} vertexCount
  /// @param {Num} instanceCount
  /// @returns {RenderPass}
  draw(vertexCount, instanceCount) {
    _cmds.add({ "op": "draw", "vertexCount": vertexCount, "instanceCount": instanceCount })
    return this
  }

  /// Issue an indexed draw of `indexCount` indices.
  /// @param {Num} indexCount
  /// @returns {RenderPass}
  drawIndexed(indexCount) { drawIndexed(indexCount, 1) }

  /// Same as `drawIndexed(indexCount)` with an explicit instance count.
  /// @param {Num} indexCount
  /// @param {Num} instanceCount
  /// @returns {RenderPass}
  drawIndexed(indexCount, instanceCount) {
    _cmds.add({ "op": "drawIndexed", "indexCount": indexCount, "instanceCount": instanceCount })
    return this
  }

  /// Flush the recorded commands into the parent encoder.
  /// Closes this render pass; call once per pass.
  end {
    var dec = RenderPass.normalizeDescriptor_(_desc)
    dec["commands"] = _cmds
    GpuCore.encoderRecordPass(_encoder.id, dec)
    // Proactively release the per-draw command Maps so they're
    // collected on the next GC cycle instead of being pinned by
    // the caller's local until the frame function returns.
    _cmds = null
    _desc = null
    _encoder = null
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
      // `depthReadOnly: true` marks the depth attachment as
      // read-only so a fragment shader of the same pass can sample
      // it (e.g. shore-foam in water). load/store ops are ignored
      // by the plugin when this flag is set.
      if (ds.containsKey("depthReadOnly"))   rec["depthReadOnly"]   = ds["depthReadOnly"]
      out["depthStencilAttachment"] = rec
    }
    return out
  }
}

/// Compute-pass builder. Mirrors [RenderPass]: commands accumulate
/// client-side and emit in a single foreign call on `end`. Open
/// one via [CommandEncoder.beginComputePass].
class ComputePass {
  construct new_(encoder, descriptor) {
    _encoder = encoder
    _desc    = descriptor
    _cmds    = []
  }

  /// Bind a [ComputePipeline] for subsequent dispatches.
  /// @param {ComputePipeline} p
  /// @returns {ComputePass}
  setPipeline(p) {
    _cmds.add({ "op": "setPipeline", "pipeline": p.id })
    return this
  }

  /// Bind a [BindGroup] at `index` (matching the pipeline's BGL
  /// at that slot).
  /// @param {Num} index
  /// @param {BindGroup} group
  /// @returns {ComputePass}
  setBindGroup(index, group) {
    _cmds.add({ "op": "setBindGroup", "index": index, "group": group.id })
    return this
  }

  /// Dispatch `x * y * z` workgroups of the current pipeline. `y`
  /// and `z` default to 1, matching the common 1D layout
  /// (`@workgroup_size(64)` over a flat array, etc).
  ///
  /// @param {Num} x
  /// @returns {ComputePass}
  dispatchWorkgroups(x) { dispatchWorkgroups(x, 1, 1) }
  /// @param {Num} x
  /// @param {Num} y
  /// @returns {ComputePass}
  dispatchWorkgroups(x, y) { dispatchWorkgroups(x, y, 1) }
  /// @param {Num} x
  /// @param {Num} y
  /// @param {Num} z
  /// @returns {ComputePass}
  dispatchWorkgroups(x, y, z) {
    _cmds.add({ "op": "dispatch", "x": x, "y": y, "z": z })
    return this
  }

  /// Flush the recorded commands into the parent encoder. Closes
  /// this compute pass; call once per pass.
  end {
    var dec = { "commands": _cmds }
    if (_desc.containsKey("label")) dec["label"] = _desc["label"]
    GpuCore.encoderRecordComputePass(_encoder.id, dec)
    _cmds = null
    _desc = null
    _encoder = null
  }
}

// -- Renderer2D --------------------------------------------------
//
// Sprite batcher and ortho camera. Built on top of every other
// primitive in this module. Pure Wren, no extra plugin.
//
//   var renderer = Renderer2D.new(device, surfaceFormat)
//   renderer.beginFrame(camera)
//
//   // ... render-pass setup as usual; bind via renderer.bind(pass) ...
//   renderer.drawSprite(texture, x, y, w, h)
//   renderer.flush(pass)
//
// One pipeline, one vertex buffer, and one uniform buffer per
// renderer. Sprites with the same texture get coalesced into one
// draw call; a texture switch flushes the current batch and
// starts a new one. The current cap is 4096 sprites per flush
// (32 floats per sprite times 4096 = 512 KB vertex buffer);
// flushes are explicit so the user controls when GPU work goes
// out.

/// Orthographic camera for 2D scenes. `(0, 0)` is the top-left
/// of the design-space rectangle the camera describes; `(width,
/// height)` is the bottom-right, +y points down. Set `origin`
/// to scroll.
///
/// Pair with [Camera2D.fitContain] (or [Camera2D.contain] which
/// builds + fits in one call) to letterbox the design rect into
/// a differently-sized surface without distorting aspect ratio.
class Camera2D {
  /// Build a camera with the given design-space dimensions.
  /// Defaults to the stretch-to-surface projection. Call
  /// [Camera2D.fitContain] to letterbox.
  ///
  /// @param {Num} width
  /// @param {Num} height
  construct new(width, height) {
    _width  = width
    _height = height
    _origin = Vec3.new(0, 0, 0)
    _padX   = 0
    _padY   = 0
  }

  /// Aspect-fit-contain projection. The design rectangle
  /// (`designW` by `designH`) renders at the largest size that
  /// fits inside the surface (`surfaceW` by `surfaceH`), centred.
  /// The leftover area on the wider axis is padded by extending
  /// the orthographic bounds past the design rectangle, so any
  /// draw outside design space simply lands in the letterbox
  /// region. The render pass's clear colour already paints that
  /// whole area, giving free letterbox bars without a render-pass
  /// viewport call.
  ///
  /// ## Example
  ///
  /// ```wren
  /// class MyGame is Game {
  ///   setup(g) {
  ///     _camera = Camera2D.contain(960, 720, g.width, g.height)
  ///   }
  ///   resize(g, w, h) {
  ///     _camera.fitContain(w, h)
  ///   }
  /// }
  /// ```
  ///
  /// @param {Num} designW
  /// @param {Num} designH
  /// @param {Num} surfaceW
  /// @param {Num} surfaceH
  /// @returns {Camera2D}
  static contain(designW, designH, surfaceW, surfaceH) {
    var c = Camera2D.new(designW, designH)
    c.fitContain(surfaceW, surfaceH)
    return c
  }

  /// Design-space width in pixels.
  /// @returns {Num}
  width   { _width }
  /// Design-space height in pixels.
  /// @returns {Num}
  height  { _height }
  /// Top-left scroll offset, as a `Vec3` (z is ignored for 2D).
  /// Move it to pan the camera.
  /// @returns {Vec3}
  origin  { _origin }
  origin=(v) { _origin = v }

  /// Refit the projection to a new surface size while keeping
  /// the design rectangle (`width` by `height`) intact. Call from
  /// a `Game.resize` override so a single camera tracks resizes
  /// without being reallocated each frame.
  ///
  /// @param {Num} surfaceW
  /// @param {Num} surfaceH
  fitContain(surfaceW, surfaceH) {
    if (surfaceH == 0 || _height == 0) {
      _padX = 0
      _padY = 0
      return
    }
    var sa = surfaceW / surfaceH
    var da = _width   / _height
    if (sa > da) {
      // Surface is wider than design: pillarbox left and right.
      // Extend the ortho bounds horizontally so the design
      // rectangle's width maps to the largest centred sub-region
      // that preserves aspect.
      _padX = (_height * sa - _width) / 2
      _padY = 0
    } else {
      // Surface is taller than design: letterbox top and bottom.
      _padX = 0
      _padY = (_width / sa - _height) / 2
    }
  }

  /// Reset to stretch-to-surface after a previous `fitContain`.
  /// Useful if a fullscreen toggle wants to drop the letterbox.
  fitStretch() {
    _padX = 0
    _padY = 0
  }

  /// View-projection matrix for this frame. Screen-pixel
  /// convention: `(0, 0)` is the top-left, `(width, height)` is
  /// the bottom-right, +y points down. Matches PixiJS / Cocos /
  /// Defold. Z range is generous (-1000..1000) so callers can
  /// layer sprites by Z without worrying about clipping.
  ///
  /// `origin` shifts the entire view; setting it to the
  /// player's world-space pixel position turns `Camera2D` into
  /// a scrolling camera. Pass to [Renderer2D.beginFrame] (or
  /// any 2D renderer that consumes a `viewProj` uniform).
  ///
  /// @returns {Mat4}
  viewProj {
    var l = _origin.x - _padX
    var r = _origin.x + _width + _padX
    // bottom > top makes m[1,1] negative; y axis flips so
    // screen-pixel coordinates (y-down) land on the WebGPU NDC
    // the shader expects.
    var b = _origin.y + _height + _padY
    var t = _origin.y - _padY
    return Mat4.ortho(l, r, b, t, -1000, 1000)
  }
}

/// Sprite batcher. Builds one big vertex buffer per frame and
/// flushes it as a single draw call, so per-frame cost is
/// dominated by the number of *texture switches*, not the
/// number of sprites.
///
/// Pair with a [Camera2D] for the view-projection matrix:
///
/// ```wren
/// _renderer = Renderer2D.new(g.device, g.surfaceFormat)
/// _camera   = Camera2D.contain(640, 480, g.width, g.height)
///
/// // in draw(g):
/// _renderer.beginFrame(_camera)
/// sprite.draw(_renderer)        // queues into the batch
/// _renderer.flush(g.pass)       // single GPU draw call
/// ```
///
/// Capacity is `MAX_SPRITES_` (4096). Calling [Renderer2D.drawSprite]
/// past the cap aborts the fiber. Flush more often, or split
/// the scene into multiple passes.
class Renderer2D {
  // Default sprite shader. Position (vec2), uv (vec2), and color
  // (vec4) per vertex; one mat4 view-projection in a uniform;
  // sampler + texture in the same bind group.
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

  // Instanced-sprite shader. The Wren-side state buffer is laid
  // out as `array<SpriteInstance>` with 16 f32 per slot:
  //   [posX, posY, sizeX, sizeY,
  //    u0, v0, u1, v1,
  //    r, g, b, a,
  //    rotation, _pad, _pad, _pad]
  // posX/posY is the sprite centre; rotation is in radians. The
  // last three pads keep the struct at a 16-byte WGSL stride so
  // future fields (LOD index, atlas slice, etc.) can slot in
  // without breaking existing buffers.
  static INSTANCED_SPRITE_WGSL_ {
    return "
      struct Uniforms { vp: mat4x4<f32> };
      @group(0) @binding(0) var<uniform> u: Uniforms;
      struct SpriteInstance {
        pos:      vec2<f32>,
        size:     vec2<f32>,
        uv0:      vec2<f32>,
        uv1:      vec2<f32>,
        color:    vec4<f32>,
        rotation: f32,
        _pad0:    f32,
        _pad1:    f32,
        _pad2:    f32,
      };
      @group(0) @binding(1) var<storage, read> instances: array<SpriteInstance>;
      @group(0) @binding(2) var t: texture_2d<f32>;
      @group(0) @binding(3) var s: sampler;

      struct VsOut {
        @builtin(position) clip:  vec4<f32>,
        @location(0)       uv:    vec2<f32>,
        @location(1)       color: vec4<f32>,
      };

      @vertex
      fn vs_main(@builtin(vertex_index)   vi: u32,
                 @builtin(instance_index) ii: u32) -> VsOut {
        // Two-triangle unit quad with corner offsets in [-0.5, 0.5]
        // so the per-instance rotation pivots around the sprite's
        // centre. Index pattern: TL, BL, BR, TL, BR, TR.
        var dx = array<f32, 6>(-0.5, -0.5, 0.5, -0.5, 0.5, 0.5);
        var dy = array<f32, 6>(-0.5, 0.5, 0.5, -0.5, 0.5, -0.5);
        var ux = array<f32, 6>( 0.0, 0.0, 1.0, 0.0, 1.0, 1.0);
        var uy = array<f32, 6>( 0.0, 1.0, 1.0, 0.0, 1.0, 0.0);
        let inst = instances[ii];
        let cosR = cos(inst.rotation);
        let sinR = sin(inst.rotation);
        // Local-quad → rotation → translation. Size is applied
        // before rotation so non-uniform scale stays axis-aligned
        // to the sprite's local frame.
        let lx = dx[vi] * inst.size.x;
        let ly = dy[vi] * inst.size.y;
        let wx = lx * cosR - ly * sinR + inst.pos.x;
        let wy = lx * sinR + ly * cosR + inst.pos.y;
        var o: VsOut;
        o.clip  = u.vp * vec4<f32>(wx, wy, 0.0, 1.0);
        o.uv    = mix(inst.uv0, inst.uv1, vec2<f32>(ux[vi], uy[vi]));
        o.color = inst.color;
        return o;
      }
      @fragment
      fn fs_main(in: VsOut) -> @location(0) vec4<f32> {
        return textureSample(t, s, in.uv) * in.color;
      }
    "
  }

  /// Number of f32 per instance in the buffer `drawInstancedSprites`
  /// reads. Each slot packs `[posX, posY, sizeX, sizeY, u0, v0,
  /// u1, v1, r, g, b, a, rotation, _pad, _pad, _pad]`.
  static FLOATS_PER_INSTANCE_ { 16 }

  static MAX_SPRITES_  { 4096 }
  static FLOATS_PER_VERTEX_  { 8 }   // 2 pos + 2 uv + 4 color
  static VERTS_PER_SPRITE_   { 6 }   // two triangles, no shared verts (simpler)

  /// Build a 2D sprite batcher targeting a colour-only
  /// attachment.
  ///
  /// @param {Device} device
  /// @param {String} surfaceFormat (for example, `"bgra8unorm"`).
  construct new(device, surfaceFormat) {
    init_(device, surfaceFormat, null)
  }

  /// Build a 2D batcher that also writes to a depth attachment.
  /// Use when overlaying 2D HUDs on top of a 3D scene drawn by
  /// `Renderer3D` in the same pass. The 2D pipeline sets
  /// `depthWriteEnabled: false` + `depthCompare: always` so
  /// sprites land on top of whatever's already in the depth
  /// buffer without contributing to it.
  ///
  /// @param {Device} device
  /// @param {String} surfaceFormat
  /// @param {String} depthFormat (for example, `"depth32float"`).
  construct new(device, surfaceFormat, depthFormat) {
    init_(device, surfaceFormat, depthFormat)
  }

  // Wren doesn't support constructor-to-constructor delegation,
  // so the shared setup body lives in a regular method that both
  // constructors invoke. Field accessors work the same as inside
  // a constructor.
  init_(device, surfaceFormat, depthFormat) {
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

    // Per-blend-mode pipeline cache. Renderer2D batches by texture
    // so a blend switch mid-frame flushes the current batch and
    // rebinds a parallel pipeline — same auto-flush shape the
    // texture-switch guard uses. Default is `"alpha"` (transparent
    // texels for bitmap fonts + soft-edged sprites); `"additive"`
    // and `"premultiplied"` are built on demand the first time
    // `setBlend` switches to them. Custom blend maps (per the
    // plugin's `blend_state_from_value` decoder) are accepted too:
    // the key is the literal mode value (String or Map.toString),
    // so callers reusing the same Map handle hit the cache.
    _shader        = shader
    _surfaceFormat = surfaceFormat
    _depthFormat   = depthFormat
    _pipelines     = {}
    _currentBlend  = "alpha"
    _pipelines["alpha"] = buildPipelineFor_("alpha")
    _pipeline      = _pipelines["alpha"]

    // Instanced-sprite shader + pipeline. Vertex-pulling: VS
    // generates the unit-quad corner from `@builtin(vertex_index)`
    // (0..5 for two triangles), reads per-instance state out of a
    // storage buffer indexed by `@builtin(instance_index)`. One
    // `pass.draw(6, N)` covers N sprites — no per-instance Wren
    // overhead. Pairs with [drawInstancedSprites].
    _instancedShader = device.createShaderModule({
      "code":  Renderer2D.INSTANCED_SPRITE_WGSL_,
      "label": "renderer2d-instanced-sprite"
    })
    _instancedBgl = device.createBindGroupLayout({
      "entries": [
        { "binding": 0, "visibility": ["vertex"],   "kind": "uniform" },
        { "binding": 1, "visibility": ["vertex"],   "kind": "read-only-storage" },
        { "binding": 2, "visibility": ["fragment"], "kind": "texture" },
        { "binding": 3, "visibility": ["fragment"], "kind": "sampler" }
      ]
    })
    _instancedPipelineLayout = device.createPipelineLayout(
      {"bindGroupLayouts": [_instancedBgl]})
    _instancedPipelines = {}
    _instancedPipelines["alpha"] = buildInstancedPipelineFor_("alpha")
    _instancedBgCache = {}

    var vboBytes = Renderer2D.MAX_SPRITES_ *
                   Renderer2D.VERTS_PER_SPRITE_ *
                   Renderer2D.FLOATS_PER_VERTEX_ * 4
    // VBO ring — one buffer per `flush()` call that fires inside a
    // single render pass. A single shared VBO breaks because both
    // `writeFloatsN(0, …)` calls land at the same offset before the
    // GPU submits, so the first `pass.draw` reads the second batch's
    // bytes and the earliest sprites visually vanish (the WORLD
    // panel title / FPS / count rows in the two-panel HUD layout).
    // Pool grows lazily; rotated by `_vboIndex` per flush; reset
    // each `beginFrame` so steady-state size is bounded by the
    // peak flush count of any one frame.
    _vboBytes = vboBytes
    _vbos     = [device.createBuffer({
      "size":  vboBytes,
      "usage": ["vertex", "copy-dst"],
      "label": "renderer2d-vbo-0"
    })]
    _vboIndex = 0
    _ubo = device.createBuffer({
      "size":  64,            // one mat4
      "usage": ["uniform", "copy-dst"],
      "label": "renderer2d-ubo"
    })
    _sampler = device.createSampler({
      "magFilter": "linear", "minFilter": "linear",
      "addressModeU": "clamp-to-edge", "addressModeV": "clamp-to-edge"
    })

    // Per-frame vertex stream. `_floats` is a Float32Array
    // pre-allocated to the worst case — one big buffer that the
    // plugin uploads via a single `queue.write_buffer` of the
    // bytes used so far. Replaces an earlier `_floats = []`
    // (Wren List) where every `pushVertex_` did 8 List.add
    // calls — each one a method dispatch + Num boxing + Vec
    // grow. At 1000 sprites that was 48k method dispatches per
    // frame just for the vertex emit. The Float32Array path
    // does an indexed `_floats[off+k] = v` instead — no method
    // dispatch, no allocation, no boxing.
    //
    // `_floatHead` tracks the running write position; `flush`
    // sends `_floats[0..head]` via `writeFloatsN`, then resets
    // head to 0. No `clear` needed — unused tail is just
    // ignored.
    _floats     = Float32Array.new(
      Renderer2D.MAX_SPRITES_ *
      Renderer2D.VERTS_PER_SPRITE_ *
      Renderer2D.FLOATS_PER_VERTEX_)
    _floatHead  = 0
    // Camera matrix scratch — 16 floats every beginFrame.
    // Float32Array for the same reason as `_floats`: indexed
    // writes are inline, no boxing or method dispatch. Sized
    // exactly to the final upload (16 floats) so the existing
    // `writeFloats` path's typed-array memcpy fast path uploads
    // the whole array without a count parameter.
    _cameraScratch = Float32Array.new(16)
    _spriteCount = 0
    _curTexture  = null
    _curBindGroup = null
    _bindGroups   = {}    // texture id -> BindGroup (lazy cache)
    // When non-null, drawSprite_ auto-flushes into this pass on a
    // texture switch or full batch instead of aborting. Set by
    // beginPass(pass) / cleared by endPass().
    _pendingPass = null
  }

  /// Reset the per-frame batch and upload `camera.viewProj`'s
  /// matrix into the uniform buffer. Call once per frame, before
  /// any `drawSprite*` calls.
  ///
  /// @param {Camera2D} camera
  beginFrame(camera) {
    // Rewind the VBO ring so the first `flush` of this frame
    // reuses `_vbos[0]`. Buffers allocated during peak-flush
    // frames are kept around for the next frame — the ring grows
    // to the high-water mark and stops.
    _vboIndex = 0
    // Mat4 stores row-major; WGSL's mat4x4 reads 16 floats as
    // column-major. Transpose at the upload boundary so the
    // ortho's translation column lands where the shader expects.
    // The transpose is unrolled and uses index assignment into
    // a pre-allocated `_cameraScratch` instead of nested while
    // loops calling `add`; the looped form miscompiled under
    // tiered execution and dropped elements, surfacing as
    // `Buffer.writeFloats: every element must be a number`.
    var d = camera.viewProj.data
    _cameraScratch[0]  = d[0]
    _cameraScratch[1]  = d[4]
    _cameraScratch[2]  = d[8]
    _cameraScratch[3]  = d[12]
    _cameraScratch[4]  = d[1]
    _cameraScratch[5]  = d[5]
    _cameraScratch[6]  = d[9]
    _cameraScratch[7]  = d[13]
    _cameraScratch[8]  = d[2]
    _cameraScratch[9]  = d[6]
    _cameraScratch[10] = d[10]
    _cameraScratch[11] = d[14]
    _cameraScratch[12] = d[3]
    _cameraScratch[13] = d[7]
    _cameraScratch[14] = d[11]
    _cameraScratch[15] = d[15]
    _ubo.writeFloats(0, _cameraScratch)
    _floatHead   = 0
    _spriteCount = 0
    _curTexture = null
    _curBindGroup = null
    _pendingPass = null
  }

  /// Bind `pass` as the auto-flush target. While bound, a texture
  /// switch or full batch inside `drawSprite_` flushes into `pass`
  /// and continues with the new state instead of aborting. Pair
  /// with [endPass] once the pass is finished.
  ///
  /// @param {RenderPass} pass
  beginPass(pass) { _pendingPass = pass }

  /// Clear the auto-flush pass set by [beginPass]. After this,
  /// texture switches and full batches abort again until the next
  /// [beginPass].
  endPass() { _pendingPass = null }

  /// Switch the active blend mode. If a pass is bound (`beginPass`)
  /// and the current batch has pending sprites, they are flushed
  /// into that pass first so the new mode applies only to sprites
  /// queued from this point. Accepted built-ins: `"alpha"` (default
  /// — straight alpha), `"premultiplied"` (pre-multiplied alpha,
  /// useful when the source texture already bakes alpha into the
  /// colour channels), `"additive"` (HDR-style accumulation —
  /// canonical for fire / sparks / glow particle textures). Pass a
  /// Map of the shape the plugin's blend-state decoder accepts for
  /// custom configurations (see `RenderPipelineLayout`'s blend
  /// docs); the map is its own cache key so reusing the same Map
  /// handle hits the cache.
  ///
  /// @param {String|Map} mode
  setBlend(mode) {
    if (mode == _currentBlend) return
    if (_pendingPass != null && _spriteCount > 0) {
      flush(_pendingPass)
    }
    _currentBlend = mode
    if (!_pipelines.containsKey(mode)) {
      _pipelines[mode] = buildPipelineFor_(mode)
    }
    _pipeline = _pipelines[mode]
  }

  // Build an instanced-sprite pipeline for `blendMode`. No vertex
  // buffer is bound — the VS pulls quad geometry from the vertex
  // index. The fragment target inherits the renderer's surface
  // format + depth format so the instanced path composites
  // identically to the non-instanced batcher.
  buildInstancedPipelineFor_(blendMode) {
    var pipelineDesc = {
      "layout": _instancedPipelineLayout,
      "vertex": {
        "module": _instancedShader, "entryPoint": "vs_main",
        "buffers": []
      },
      "fragment": {
        "module": _instancedShader, "entryPoint": "fs_main",
        "targets": [{ "format": _surfaceFormat, "blend": blendMode }]
      },
      "primitive": { "topology": "triangle-list", "cullMode": "none" },
      "label": "renderer2d-instanced-%(blendMode)"
    }
    if (_depthFormat != null) {
      pipelineDesc["depthStencil"] = {
        "format": _depthFormat,
        "depthWriteEnabled": false,
        "depthCompare": "always"
      }
    }
    return _device.createRenderPipeline(pipelineDesc)
  }

  /// Build a Renderer2D pipeline for `blendMode`. Called lazily from
  /// `setBlend` on the first switch into a not-yet-cached mode.
  buildPipelineFor_(blendMode) {
    var pipelineDesc = {
      "layout": _pipelineLayout,
      "vertex": {
        "module": _shader, "entryPoint": "vs_main",
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
        "module": _shader, "entryPoint": "fs_main",
        "targets": [{ "format": _surfaceFormat, "blend": blendMode }]
      },
      "primitive": { "topology": "triangle-list", "cullMode": "none" },
      "label": "renderer2d-pipeline-%(blendMode)"
    }
    if (_depthFormat != null) {
      pipelineDesc["depthStencil"] = {
        "format": _depthFormat,
        "depthWriteEnabled": false,
        "depthCompare": "always"
      }
    }
    return _device.createRenderPipeline(pipelineDesc)
  }

  /// Queue an axis-aligned, full-texture sprite at `(x, y)`
  /// with the given size. Position is the top-left corner.
  ///
  /// @param {Texture} texture
  /// @param {Num} x
  /// @param {Num} y
  /// @param {Num} w
  /// @param {Num} h
  drawSprite(texture, x, y, w, h) {
    drawSprite_(texture, x, y, w, h, 0, 0, 1, 1, 1, 1, 1, 1)
  }

  /// Queue an axis-aligned sprite with custom UV bounds. Useful
  /// for atlas slicing.
  ///
  /// @param {Texture} texture
  /// @param {Num} x
  /// @param {Num} y
  /// @param {Num} w
  /// @param {Num} h
  /// @param {Num} u0
  /// @param {Num} v0
  /// @param {Num} u1
  /// @param {Num} v1
  drawSpriteUV(texture, x, y, w, h, u0, v0, u1, v1) {
    drawSprite_(texture, x, y, w, h, u0, v0, u1, v1, 1, 1, 1, 1)
  }

  /// Queue an axis-aligned sprite with a per-vertex tint.
  /// `(r, g, b, a)` are floats in `[0, 1]`.
  ///
  /// @param {Texture} texture
  /// @param {Num} x
  /// @param {Num} y
  /// @param {Num} w
  /// @param {Num} h
  /// @param {Num} r
  /// @param {Num} g
  /// @param {Num} b
  /// @param {Num} a
  drawSpriteTinted(texture, x, y, w, h, r, g, b, a) {
    drawSprite_(texture, x, y, w, h, 0, 0, 1, 1, r, g, b, a)
  }

  /// Queue a [Sprite] instance (delegates to `sprite.draw(this)`).
  /// @param {Sprite} sprite
  draw(sprite) { sprite.draw(this) }

  // Internal. Does the actual vertex emit. Two triangles per
  // sprite, no shared vertices to keep the fragment-stage
  // colour interpolation correct without an index buffer.
  drawSprite_(texture, x, y, w, h, u0, v0, u1, v1, r, g, b, a) {
    if (_curTexture != null && _curTexture.id != texture.id) {
      if (_pendingPass != null) {
        flush(_pendingPass)
      } else {
        Fiber.abort("Renderer2D: texture switches require an explicit flush(pass).")
      }
    }
    _curTexture = texture
    if (_spriteCount >= Renderer2D.MAX_SPRITES_) {
      if (_pendingPass != null) {
        flush(_pendingPass)
        _curTexture = texture
      } else {
        Fiber.abort("Renderer2D: batch full (%(_spriteCount) sprites). Call flush(pass) sooner.")
      }
    }
    var x1 = x + w
    var y1 = y + h
    var head = _floatHead

    // Triangle 1: top-left, bottom-left, bottom-right.
    head = pushVertex_(head, x,  y,  u0, v0, r, g, b, a)
    head = pushVertex_(head, x,  y1, u0, v1, r, g, b, a)
    head = pushVertex_(head, x1, y1, u1, v1, r, g, b, a)
    // Triangle 2: top-left, bottom-right, top-right.
    head = pushVertex_(head, x,  y,  u0, v0, r, g, b, a)
    head = pushVertex_(head, x1, y1, u1, v1, r, g, b, a)
    head = pushVertex_(head, x1, y,  u1, v0, r, g, b, a)
    _floatHead   = head
    _spriteCount = _spriteCount + 1
  }

  // Indexed-write vertex push. Writes 8 floats starting at
  // `head`, returns the new head. Each write is a Float32Array
  // subscript-set: no method dispatch, no boxing, no Vec grow.
  // Earlier shape called `f.add(num)` 8 times against a Wren
  // `List`; that was 8 method dispatches + 8 Num→f64 box→f32
  // conversions per vertex × 6 vertices per sprite = 48
  // dispatches per sprite. The new shape is the same number of
  // arithmetic ops but no dispatch / no allocation.
  pushVertex_(head, px, py, u, v, r, g, b, a) {
    var f = _floats
    f[head]     = px
    f[head + 1] = py
    f[head + 2] = u
    f[head + 3] = v
    f[head + 4] = r
    f[head + 5] = g
    f[head + 6] = b
    f[head + 7] = a
    return head + 8
  }

  // Lazily cache one BindGroup per (texture id). Sampler and UBO
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

  /// Submit the queued batch to `pass` as a single draw call,
  /// then reset for the next frame. No-op when nothing is
  /// queued. Call at the end of each frame and again every
  /// time you swap textures.
  ///
  /// @param {RenderPass} pass
  flush(pass) {
    if (_spriteCount == 0) return
    // Pick the next VBO from the per-frame ring. Each flush gets
    // its own buffer so two batches inside one render pass don't
    // alias to offset 0 of the same VBO at submit time.
    if (_vboIndex >= _vbos.count) {
      _vbos.add(_device.createBuffer({
        "size":  _vboBytes,
        "usage": ["vertex", "copy-dst"],
        "label": "renderer2d-vbo-%(_vboIndex)"
      }))
    }
    var vbo = _vbos[_vboIndex]
    _vboIndex = _vboIndex + 1
    // Partial upload: only the floats actually written this
    // frame. Sends `_floatHead * 4` bytes; the plugin path is
    // a single `queue.write_buffer` of that slice — no per-
    // element walk.
    vbo.writeFloatsN(0, _floats, _floatHead)
    var bg = bindGroupFor_(_curTexture)
    pass.setPipeline(_pipeline)
    pass.setBindGroup(0, bg)
    pass.setVertexBuffer(0, vbo)
    pass.draw(_spriteCount * Renderer2D.VERTS_PER_SPRITE_)
    _floatHead   = 0
    _spriteCount = 0
    _curTexture = null
  }

  /// Instanced sprite draw. `instanceBuffer` is a storage buffer
  /// (usage `["storage", "copy-dst"]`) laid out as
  /// `array<SpriteInstance>` with 16 f32 per slot — see
  /// `INSTANCED_SPRITE_WGSL_` for the field order. Pack with
  /// `Renderer2D.writeSpriteInstance(out, i, x, y, w, h, u0, v0,
  /// u1, v1, r, g, b, a, rotation)` and upload via
  /// `instanceBuffer.writeFloats(0, out)`.
  ///
  /// One `pass.draw(6, instanceCount)` covers the whole batch — no
  /// per-instance Wren overhead. The buffer can also be the direct
  /// output of a compute pass (decals, damage numbers, GPU-driven
  /// UI) so the CPU never reads it.
  ///
  /// Honours the renderer's `setBlend` mode. Auto-flushes any
  /// queued non-instanced sprites first so the existing batch
  /// lands ahead of the instanced draw in submit order.
  ///
  /// @param {RenderPass} pass
  /// @param {Texture} texture
  /// @param {Buffer} instanceBuffer
  /// @param {Num} instanceCount
  drawInstancedSprites(pass, texture, instanceBuffer, instanceCount) {
    if (instanceCount <= 0) return
    if (_spriteCount > 0) flush(pass)
    if (!_instancedPipelines.containsKey(_currentBlend)) {
      _instancedPipelines[_currentBlend] = buildInstancedPipelineFor_(_currentBlend)
    }
    var bg = instancedBindGroupFor_(texture, instanceBuffer)
    pass.setPipeline(_instancedPipelines[_currentBlend])
    pass.setBindGroup(0, bg)
    pass.draw(6, instanceCount)
  }

  // Cache the BindGroup that ties (texture, instanceBuffer) to
  // the instanced pipeline. Keyed by `texture.id`+`buffer.id` so
  // a caller reusing the same pair across frames hits the cache.
  instancedBindGroupFor_(texture, instanceBuffer) {
    var key = "%(texture.id):%(instanceBuffer.id)"
    var existing = _instancedBgCache[key]
    if (existing != null) return existing
    var bg = _device.createBindGroup({
      "layout":  _instancedBgl,
      "entries": [
        { "binding": 0, "buffer":  _ubo },
        { "binding": 1, "buffer":  instanceBuffer },
        { "binding": 2, "texture": texture.view },
        { "binding": 3, "sampler": _sampler }
      ]
    })
    _instancedBgCache[key] = bg
    return bg
  }

  /// Pack one sprite instance into a 16-f32 slot at `slotIndex`
  /// of `out`. Slot stride is `Renderer2D.FLOATS_PER_INSTANCE_`
  /// (16). Pre-allocate `out` as
  /// `Float32Array.new(capacity * 16)`; on upload pass the whole
  /// buffer or a prefix to `instanceBuffer.writeFloats(0, out)`.
  ///
  /// `(x, y)` is the sprite centre. `(u0, v0, u1, v1)` is the UV
  /// rectangle into the bound texture (axis-aligned; flip by
  /// swapping bounds). `rotation` is in radians around the centre.
  ///
  /// @param {Float32Array} out
  /// @param {Num} slotIndex
  /// @param {Num} x
  /// @param {Num} y
  /// @param {Num} w
  /// @param {Num} h
  /// @param {Num} u0
  /// @param {Num} v0
  /// @param {Num} u1
  /// @param {Num} v1
  /// @param {Num} r
  /// @param {Num} g
  /// @param {Num} b
  /// @param {Num} a
  /// @param {Num} rotation
  static writeSpriteInstance(out, slotIndex, x, y, w, h,
                             u0, v0, u1, v1, r, g, b, a, rotation) {
    var off = slotIndex * 16
    out[off]      = x
    out[off + 1]  = y
    out[off + 2]  = w
    out[off + 3]  = h
    out[off + 4]  = u0
    out[off + 5]  = v0
    out[off + 6]  = u1
    out[off + 7]  = v1
    out[off + 8]  = r
    out[off + 9]  = g
    out[off + 10] = b
    out[off + 11] = a
    out[off + 12] = rotation
    out[off + 13] = 0
    out[off + 14] = 0
    out[off + 15] = 0
  }

  /// Release the GPU resources held by this renderer (vertex /
  /// uniform buffers, sampler, pipelines, layouts). Call when the
  /// renderer goes out of scope; not called automatically.
  destroy {
    for (b in _vbos) b.destroy
    _ubo.destroy
    _sampler.destroy
    for (p in _pipelines.values) p.destroy
    for (p in _instancedPipelines.values) p.destroy
    _pipelineLayout.destroy
    _instancedPipelineLayout.destroy
    _bgl.destroy
    _instancedBgl.destroy
  }
}

/// Mutable sprite state. `(texture, x, y, w, h)` plus tint /
/// scale / anchor / UV. Reuse one `Sprite` across many frames;
/// mutate its fields between draws. The renderer batches by
/// texture, so swapping `_quad`'s position and UV per call
/// keeps everything in a single draw call.
///
/// Anchor is a fractional offset (`(0, 0)` = top-left,
/// `(0.5, 0.5)` = centre, `(1, 1)` = bottom-right) so changes
/// to scale / size pivot around the same point.
///
/// ```wren
/// var s = Sprite.new(tex)
/// s.anchor(0.5, 0.5)
/// s.x = 100; s.y = 60
/// s.scale = 2
/// s.setTint(1.0, 0.4, 0.4, 1.0)
/// r.draw(s)
/// ```
class Sprite {
  /// Build a sprite for `texture`, with width/height initialised
  /// to the texture's natural size. Anchor defaults to top-left;
  /// call [Sprite.anchor] to recentre.
  ///
  /// @param {Texture} texture
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

  /// The bound `Texture`. Reassign to swap atlases mid-frame.
  /// @returns {Texture}
  texture  { _tex }
  texture=(t) { _tex = t }

  /// Anchor-relative X position in surface pixels.
  /// @returns {Num}
  x        { _x }
  x=(v)    { _x = v }
  /// Anchor-relative Y position in surface pixels.
  /// @returns {Num}
  y        { _y }
  y=(v)    { _y = v }

  /// Pre-scale width.
  /// @returns {Num}
  width    { _w }
  width=(v) { _w = v }
  /// Pre-scale height.
  /// @returns {Num}
  height   { _h }
  height=(v) { _h = v }

  /// Multiplier on `width`. @returns {Num}
  scaleX   { _scaleX }
  scaleX=(v) { _scaleX = v }
  /// Multiplier on `height`. @returns {Num}
  scaleY   { _scaleY }
  scaleY=(v) { _scaleY = v }
  /// Set both `scaleX` and `scaleY` to the same value.
  /// @param {Num} v
  scale=(v) {
    _scaleX = v
    _scaleY = v
  }

  /// Anchor X in `[0, 1]`. `0` = left edge, `0.5` = centre,
  /// `1` = right.
  /// @returns {Num}
  anchorX  { _anchorX }
  /// Anchor Y in `[0, 1]`. `0` = top, `0.5` = centre,
  /// `1` = bottom.
  /// @returns {Num}
  anchorY  { _anchorY }
  /// Set the anchor in one call.
  /// @param {Num} ax
  /// @param {Num} ay
  anchor(ax, ay) {
    _anchorX = ax
    _anchorY = ay
  }

  /// Per-vertex tint as an `[r, g, b, a]` list, each in
  /// `[0, 1]`. Multiplied with the sampled texture in the
  /// fragment shader.
  /// @returns {List}
  tint     { [_tintR, _tintG, _tintB, _tintA] }
  /// Replace the tint from a 4-element list. Allocates the list
  /// on every read of `tint`; prefer [Sprite.setTint] in hot
  /// paths.
  /// @param {List} rgba
  tint=(rgba) {
    _tintR = rgba[0]
    _tintG = rgba[1]
    _tintB = rgba[2]
    _tintA = rgba[3]
  }
  /// Set all four tint channels in a single call without
  /// allocating an intermediate list. Prefer this in hot per-
  /// frame draw loops; reserve `tint = [r,g,b,a]` for setup /
  /// cold-path code where readability beats an alloc.
  ///
  /// @param {Num} r
  /// @param {Num} g
  /// @param {Num} b
  /// @param {Num} a
  setTint(r, g, b, a) {
    _tintR = r
    _tintG = g
    _tintB = b
    _tintA = a
  }
  /// Alpha channel of the tint. `1.0` is fully opaque.
  /// @returns {Num}
  alpha    { _tintA }
  alpha=(a) { _tintA = a }

  /// Set custom UV bounds for atlas slicing. `(u0, v0)` is the
  /// top-left, `(u1, v1)` is the bottom-right, both in `[0, 1]`.
  ///
  /// @param {Num} u0
  /// @param {Num} v0
  /// @param {Num} u1
  /// @param {Num} v1
  uv(u0, v0, u1, v1) {
    _u0 = u0
    _v0 = v0
    _u1 = u1
    _v1 = v1
  }

  /// Visibility gate. `false` skips this sprite during `draw`.
  /// @returns {Bool}
  visible  { _visible }
  visible=(v) { _visible = v }

  /// Queue this sprite into `renderer`'s batch. Picks the fast
  /// axis-aligned path when UV / tint are at defaults; otherwise
  /// routes through the tinted path.
  ///
  /// @param {Renderer2D} renderer
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

/// -- 3D camera ---------------------------------------------------
///
/// Either a perspective frustum or an ortho box. The camera owns
/// its own eye / target / up + projection params; `viewProj`
/// composes them into a Mat4 ready for the renderer's uniform.
///
///   var cam = Camera3D.perspective(60, w / h, 0.1, 100)
///   cam.lookAt(Vec3.new(3, 3, 5), Vec3.zero, Vec3.unitY)
///
/// `fovY` is in DEGREES for the perspective variant. The
/// orthographic variant takes half-extents and matches Mat4.ortho.
class Camera3D {
  /// Perspective: vertical FOV in degrees, aspect, near, far.
  static perspective(fovY, aspect, near, far) {
    var c = Camera3D.new_()
    c.setProjection_(Mat4.perspective(fovY * 3.141592653589793 / 180, aspect, near, far))
    return c
  }

  /// Orthographic: full width / height, near / far.
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
    _planes = Float32Array.new(24)
    _planesDirty = true
  }

  setProjection_(m) {
    _proj = m
    _planesDirty = true
  }

  /// Build the view matrix from eye to target. Idempotent; call
  /// every frame if the camera moves.
  lookAt(eye, target, up) {
    _eye = eye
    _target = target
    _up = up
    _viewDirty = true
    _planesDirty = true
  }

  /// Re-aim the projection without rebuilding the camera (e.g.
  /// after a window resize).
  setPerspective(fovY, aspect, near, far) {
    _proj = Mat4.perspective(fovY * 3.141592653589793 / 180, aspect, near, far)
    _planesDirty = true
  }

  eye    { _eye }
  target { _target }
  up     { _up }

  /// Compute view-projection. Lazily rebuilds the view matrix
  /// when eye/target/up change.
  viewProj {
    if (_viewDirty) {
      _view = Mat4.lookAt(_eye, _target, _up)
      _viewDirty = false
    }
    return _proj * _view
  }

  /// World-space frustum planes derived from the view-projection
  /// matrix via the Gribb-Hartmann clip-space method. Returns a
  /// `Float32Array.new(24)` laid out as `(nx, ny, nz, d) × 6` in
  /// the order `left, right, bottom, top, near, far` — feed it to
  /// `Frustum.sphereVisible` (or any custom test) without a copy.
  /// Lazily rebuilt: untouched until the camera matrix changes.
  ///
  /// Tracks `@hatch:math`'s clip-space convention (OpenGL [-1, 1]
  /// depth: `Mat4.perspective` builds a matrix where the near
  /// plane is `z_clip = -w_clip`). When a future host migrates the
  /// math library to WebGPU's [0, 1] depth, this derivation moves
  /// in lockstep.
  ///
  /// @returns {Float32Array}
  frustumPlanes {
    if (_planesDirty) {
      buildFrustumPlanes_()
      _planesDirty = false
    }
    return _planes
  }

  buildFrustumPlanes_() {
    // Mat4.data is row-major (data[0..3] = row 0, etc).
    // For row-major M, world-space planes from clip-space are:
    //   left  = row3 + row0       right = row3 - row0
    //   bot   = row3 + row1       top   = row3 - row1
    //   near  = row3 + row2       far   = row3 - row2     (OpenGL [-1,1] depth)
    // Each plane (a, b, c, d) is normalised by 1 / |(a, b, c)|
    // so the sphere test reads as a true signed distance.
    var m = viewProj.data
    var r00 = m[0]
    var r01 = m[1]
    var r02 = m[2]
    var r03 = m[3]
    var r10 = m[4]
    var r11 = m[5]
    var r12 = m[6]
    var r13 = m[7]
    var r20 = m[8]
    var r21 = m[9]
    var r22 = m[10]
    var r23 = m[11]
    var r30 = m[12]
    var r31 = m[13]
    var r32 = m[14]
    var r33 = m[15]
    var p = _planes
    setPlane_(p,  0, r30 + r00, r31 + r01, r32 + r02, r33 + r03)
    setPlane_(p,  4, r30 - r00, r31 - r01, r32 - r02, r33 - r03)
    setPlane_(p,  8, r30 + r10, r31 + r11, r32 + r12, r33 + r13)
    setPlane_(p, 12, r30 - r10, r31 - r11, r32 - r12, r33 - r13)
    setPlane_(p, 16, r30 + r20, r31 + r21, r32 + r22, r33 + r23)
    setPlane_(p, 20, r30 - r20, r31 - r21, r32 - r22, r33 - r23)
  }

  setPlane_(p, off, a, b, c, d) {
    var inv = 1 / (a * a + b * b + c * c).sqrt
    p[off]     = a * inv
    p[off + 1] = b * inv
    p[off + 2] = c * inv
    p[off + 3] = d * inv
  }
}

/// Per-instance level-of-detail selection. Static — callers feed
/// scalar coordinates so the inner loop stays allocation-free
/// and JIT-friendly. Pair with a per-bucket instance buffer and
/// dispatch one `drawMeshInstanced` per LOD with the matching
/// mesh.
class Lod {
  /// 3-tier LOD by squared distance from the camera eye. Returns:
  ///
  ///   - `0` (highest detail) when `distance² <  t0sq`
  ///   - `1` (mid detail)     when `distance² <  t1sq`
  ///   - `2` (lowest detail)  otherwise
  ///
  /// Squared thresholds skip a sqrt per call — compute them once
  /// at setup as `t0 * t0`, `t1 * t1`. Add a `Frustum.sphereVisible`
  /// pass before this to drop the off-screen majority; LOD only
  /// runs on cubes the camera can actually see.
  ///
  /// @param {Num} eyeX
  /// @param {Num} eyeY
  /// @param {Num} eyeZ
  /// @param {Num} cx
  /// @param {Num} cy
  /// @param {Num} cz
  /// @param {Num} t0sq
  /// @param {Num} t1sq
  /// @returns {Num}
  static select3(eyeX, eyeY, eyeZ, cx, cy, cz, t0sq, t1sq) {
    var dx = cx - eyeX
    var dy = cy - eyeY
    var dz = cz - eyeZ
    var d2 = dx * dx + dy * dy + dz * dz
    if (d2 < t0sq) return 0
    if (d2 < t1sq) return 1
    return 2
  }
}

/// Frustum-vs-volume tests against a `Camera3D.frustumPlanes`
/// payload. Static — the plane array carries all the state.
class Frustum {
  /// Returns `true` when a sphere at `(cx, cy, cz)` with the
  /// given world-space `radius` is at least partially inside
  /// every frustum plane. `false` only when the sphere lies
  /// fully outside at least one plane — the classic conservative
  /// cull test, may pass spheres that sit inside the corner of
  /// two near-parallel planes (rare in practice; cheap enough).
  ///
  /// `planes` must be `Float32Array.new(24)` shaped like
  /// `Camera3D.frustumPlanes`.
  ///
  /// @param {Float32Array} planes
  /// @param {Num} cx
  /// @param {Num} cy
  /// @param {Num} cz
  /// @param {Num} radius
  /// @returns {Bool}
  static sphereVisible(planes, cx, cy, cz, radius) {
    var i = 0
    var negR = -radius
    while (i < 24) {
      var d = planes[i] * cx + planes[i + 1] * cy + planes[i + 2] * cz + planes[i + 3]
      if (d < negR) return false
      i = i + 4
    }
    return true
  }
}

/// -- Light -------------------------------------------------------
///
/// One directional light plus ambient term, encoded as the
/// Renderer3D expects. Set `direction` as the vector light
/// *travels in* (sun-to-ground); the shader negates it before
/// dotting with the surface normal.
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

/// -- Mesh --------------------------------------------------------
///
/// Vertex layout: position vec3, normal vec3, uv vec2; 32 bytes
/// total. Indices are u32 so meshes with more than 65k vertices
/// work.
///
/// Build meshes via the static helpers (`Mesh.cube`, etc.) for
/// procedural primitives, or call `Mesh.fromArrays(device,
/// vertices, indices)` to upload your own buffers, typically
/// from a glTF / OBJ loader.
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

  /// Build a Mesh from interleaved-vertex data + indices. `vertices`
  /// is a flat List of Nums in pos.xyz / normal.xyz / uv.xy order
  /// (8 floats per vertex). `indices` is a List<Num> of 0-based
  /// u32 vertex indices.
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

  /// Axis-aligned cube centred on origin. Side length = 2 * half
  /// (default 1, for a total side length of 2). Vertices are
  /// duplicated per face so face-normals stay flat (no normal
  /// averaging).
  static cube(device) { cube(device, 1) }
  static cube(device, half) {
    var h = half
    // Vertices: 6 faces, 4 verts each = 24, each (pos.xyz, n.xyz, u, v).
    var v = []
    var pushFace = Fn.new {|nx, ny, nz, p0, p1, p2, p3|
      // Each face: 4 verts, normal shared, uvs (0,0)(1,0)(1,1)(0,1).
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

  /// Flat plane on the X-Z axis (Y up), centred on origin.
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

/// -- Hot-reloaded pipeline ---------------------------------------
///
/// Reads its WGSL from a `@hatch:assets` database; rebuilds the
/// underlying RenderPipeline in place whenever the shader file's
/// content hash advances. From the caller's perspective it
/// behaves exactly like a normal RenderPipeline. Bind it via
/// `pass.setPipeline(livePipeline)` and the .id getter resolves
/// to the current internal pipeline at record time.
///
///   var assets   = Assets.open("assets")
///   var pipeline = LivePipeline.new(device, assets,
///                                   "shaders/triangle.wgsl", {
///     "vertex":   { "entryPoint": "vs_main" },
///     "fragment": { "entryPoint": "fs_main",
///                   "targets": [{"format": "rgba8unorm"}] },
///     "primitive": { "topology": "triangle-list" }
///   })
///
/// Edits to the shader file fire the rebuild between frames; in-
/// flight render passes that already captured the old id finish
/// against the old code, the next pass picks up the new one.
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

  /// Forwards `setPipeline` and debug callers. Always points at
  /// the freshest internal pipeline.
  id { _pipeline.id }

  /// Drop watchers, the underlying pipeline, and the shader. The
  /// assets db's on() registration leaks intentionally; the user
  /// is expected to keep the LivePipeline alive for the lifetime
  /// of the application.
  destroy {
    if (_pipeline != null) _pipeline.destroy
    if (_shader != null) _shader.destroy
    _pipeline = null
    _shader = null
  }

  // Re-read shader source, recompile, rebuild the pipeline using
  // the new shader as both vertex and fragment module. The old
  // shader and pipeline are dropped after the new ones land;
  // wgpu ref-counts them, so any `setPipeline` that already
  // captured the old id still resolves correctly through the
  // foreign registry until the encoder it lives in is submitted.
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
/// Render target backed by a window. Configure once (size +
/// format), then call [Surface.acquire] each frame to get the
/// next swap-chain image.
class Surface {
  construct new_(id, device) {
    _id     = id
    _device = device
  }

  /// Foreign-handle id (internal).
  /// @returns {Num}
  id { _id }

  /// Apply a configuration descriptor (`width`, `height`,
  /// `format`, `presentMode`, etc.). Call after window resize.
  /// @param {Map} descriptor
  configure(descriptor) { GpuCore.surfaceConfigure(_id, descriptor) }

  /// Acquire the next swap-chain image as a [SurfaceFrame].
  /// Its `view` is usable as a render-pass colour attachment;
  /// `frame.present` schedules the swap. Aborts the fiber if
  /// the swap chain is lost or outdated. Callers should
  /// re-configure on a window-resize event and retry.
  /// @returns {SurfaceFrame}
  acquire() {
    var pair = GpuCore.surfaceAcquire(_id)
    return SurfaceFrame.new_(pair["frame"], pair["view"])
  }

  /// Release the surface.
  destroy {
    GpuCore.surfaceDestroy(_id)
    _id = -1
  }
}

/// One in-flight swap-chain frame. `view` is consumed by render
/// passes; `present` retires the frame to the compositor. The
/// underlying surface texture is held in the foreign registry
/// so the view stays valid for the whole render pass; presenting
/// drops both at once.
class SurfaceFrame {
  construct new_(frameId, viewId) {
    _id   = frameId
    _view = TextureView.new_(viewId, null, 0, 0)
  }

  /// Foreign-handle id (internal).
  /// @returns {Num}
  id   { _id }
  /// `TextureView` to bind into a render pass's colour
  /// attachment.
  /// @returns {TextureView}
  view { _view }

  /// Present the frame. Schedules the swap and drops the held
  /// `SurfaceTexture` + view.
  present {
    GpuCore.surfacePresentFrame(_id)
    _id   = -1
    // Release the per-frame TextureView wrapper alongside the
    // frame itself; the Rust-side view entry was removed inside
    // `surfacePresentFrame`.
    _view = null
  }
}
