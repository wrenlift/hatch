// @hatch:gpu — web backend.
//
// Mirrors `gpu_native.wren`'s API surface so portable game code
// runs on both targets unchanged. The implementation differs:
// instead of dlopen'ing wgpu, this file targets a pure-WebGPU
// plugin (`wlift_gpu_web`) that exposes a flat handle-based
// foreign surface (`GpuWeb_`) and translates between the
// native-shaped descriptors users write and the JSON the JS
// bridge consumes.
//
// Two-class foreign indirection:
//
//   `GpuWeb_`   — foreign class. Low-level handle API as the
//                 plugin exports it. Not part of the public
//                 surface; users go through `GpuCore`.
//
//   `GpuCore`   — Wren class. Takes the same Map descriptors
//                 as gpu_native.wren's `GpuCore` foreign class,
//                 stringifies + translates them, and delegates
//                 to `GpuWeb_`.
//
// The wrapper classes (Device, Buffer, Texture, RenderPipeline,
// CommandEncoder, RenderPass, Surface, Sprite, Renderer2D,
// Renderer3D, …) are *identical* to gpu_native.wren and route
// through `GpuCore`; both backends share the same author-facing
// shape.

import "@hatch:math" for Vec3, Vec4, Mat4

// ---------------------------------------------------------------
// Low-level foreign surface — the plugin's actual exports.
// Users go through `GpuCore` / the wrapper classes; this exists
// only to back them.
// ---------------------------------------------------------------
#!native = "wlift_gpu"
foreign class GpuWeb_ {
  #!symbol = "wlift_gpu_init"
  foreign static init()

  #!symbol = "wlift_gpu_attach_canvas"
  foreign static attachCanvas(canvasHandle)

  #!symbol = "wlift_gpu_begin_frame"
  foreign static beginFrame(surface)

  #!symbol = "wlift_gpu_clear"
  foreign static clear(frame, r, g, b, a)

  #!symbol = "wlift_gpu_end_frame"
  foreign static endFrame(frame)

  #!symbol = "wlift_gpu_create_buffer"
  foreign static createBuffer(size, usageBits)

  #!symbol = "wlift_gpu_buffer_write"
  foreign static bufferWrite(handle, offset, bytes)

  #!symbol = "wlift_gpu_destroy_buffer"
  foreign static destroyBuffer(handle)

  #!symbol = "wlift_gpu_create_buffer_from_floats"
  foreign static createBufferFromFloats(floats, usageBits)

  #!symbol = "wlift_gpu_buffer_write_floats"
  foreign static bufferWriteFloats(handle, offset, floats)

  #!symbol = "wlift_gpu_buffer_write_uints"
  foreign static bufferWriteUints(handle, offset, uints)

  #!symbol = "wlift_gpu_create_shader"
  foreign static createShader(wgsl)

  #!symbol = "wlift_gpu_create_bind_group_layout"
  foreign static createBindGroupLayout(descriptorJson)

  #!symbol = "wlift_gpu_create_bind_group"
  foreign static createBindGroup(descriptorJson)

  #!symbol = "wlift_gpu_create_pipeline"
  foreign static createPipeline(descriptorJson)

  #!symbol = "wlift_gpu_render_pass_begin"
  foreign static renderPassBegin(frame, descriptorJson)

  #!symbol = "wlift_gpu_render_pass_set_pipeline"
  foreign static renderPassSetPipeline(pass, pipeline)

  #!symbol = "wlift_gpu_render_pass_set_bind_group"
  foreign static renderPassSetBindGroup(pass, groupIndex, bindGroup)

  #!symbol = "wlift_gpu_render_pass_set_vertex_buffer"
  foreign static renderPassSetVertexBuffer(pass, slot, buffer)

  #!symbol = "wlift_gpu_render_pass_set_index_buffer"
  foreign static renderPassSetIndexBuffer(pass, buffer, format32)

  #!symbol = "wlift_gpu_render_pass_draw"
  foreign static renderPassDraw(pass, vertexCount, instanceCount, firstVertex, firstInstance)

  #!symbol = "wlift_gpu_render_pass_draw_indexed"
  foreign static renderPassDrawIndexed(pass, indexCount, instanceCount, firstIndex, baseVertex, firstInstance)

  #!symbol = "wlift_gpu_render_pass_end"
  foreign static renderPassEnd(pass)

  #!symbol = "wlift_gpu_create_texture"
  foreign static createTexture(descriptorJson)

  #!symbol = "wlift_gpu_create_texture_view"
  foreign static createTextureView(textureHandle, descriptorJson)

  #!symbol = "wlift_gpu_queue_write_texture"
  foreign static queueWriteTexture(textureHandle, bytes, descriptorJson)

  #!symbol = "wlift_gpu_create_sampler"
  foreign static createSampler(descriptorJson)

  #!symbol = "wlift_gpu_destroy"
  foreign static destroy(handle)
}

// ---------------------------------------------------------------
// JSON helpers. The JS bridge reads descriptor JSON from a Wren
// String slot — these emit minimal, deterministic JSON for the
// shapes the bridge expects. Pulled in here rather than via
// @hatch:json to keep gpu_web's dep graph identical to native's.
// ---------------------------------------------------------------
class Json_ {
  // Encode a value to JSON. Recurses through Maps and Lists; rejects
  // anything else with a clear error pointing at the value's class.
  // Strings escape `"` and `\`; numerics use Wren's default toString;
  // Bool / Null map to JSON literals.
  static stringify(v) { appendValue_("", v) }
  static appendValue_(out, v) {
    if (v == null)         return out + "null"
    if (v is Bool)         return out + (v ? "true" : "false")
    if (v is Num)          return out + numberToken_(v)
    if (v is String)       return out + escapeString_(v)
    if (v is List)         return appendList_(out, v)
    if (v is Map)          return appendMap_(out, v)
    Fiber.abort("Json_.stringify: unsupported %(v.type)")
  }
  static appendList_(out, list) {
    var s = out + "["
    var first = true
    for (item in list) {
      if (!first) s = s + ","
      s = appendValue_(s, item)
      first = false
    }
    return s + "]"
  }
  static appendMap_(out, map) {
    var s = out + "{"
    var first = true
    for (k in map.keys) {
      if (!(k is String)) Fiber.abort("Json_.stringify: object keys must be strings, got %(k.type)")
      if (!first) s = s + ","
      s = s + escapeString_(k) + ":"
      s = appendValue_(s, map[k])
      first = false
    }
    return s + "}"
  }
  static numberToken_(n) {
    // Wren's `Num.toString` already emits a decimal form WebGPU
    // accepts. The integer fast path keeps "1024.0" → "1024".
    if (n == n.floor && n.abs < 9007199254740992) return "%(n.floor)"
    return "%(n)"
  }
  static escapeString_(s) {
    var out = "\""
    var i = 0
    while (i < s.count) {
      var c = s[i]
      if (c == "\"")      out = out + "\\\""
      else if (c == "\\") out = out + "\\\\"
      else if (c == "\n") out = out + "\\n"
      else if (c == "\r") out = out + "\\r"
      else if (c == "\t") out = out + "\\t"
      else                out = out + c
      i = i + 1
    }
    return out + "\""
  }
}

// ---------------------------------------------------------------
// Static module entry — `Gpu.requestDevice({...})`. Mirrors
// gpu_native.wren's static class.
// ---------------------------------------------------------------
/// Static module entry. `Gpu.requestDevice({...})` returns the
/// process-wide [Device]; everything else (textures, buffers,
/// pipelines, surfaces) is built off of the device.
class Gpu {
  /// Request a GPU device. `descriptor` is accepted for parity
  /// with the native API; on web, `backends` / `powerPreference`
  /// are ignored (the JS adapter request happens at plugin
  /// install). Aborts the fiber when WebGPU isn't available.
  ///
  /// @param {Map} descriptor
  /// @returns {Device}
  static requestDevice(descriptor) {
    if (!(descriptor is Map)) Fiber.abort("Gpu.requestDevice: descriptor must be a Map.")
    if (!GpuWeb_.init()) Fiber.abort("Gpu.requestDevice: WebGPU not available in this browser.")
    return Device.new_(0)
  }

  /// Request a GPU device with default options.
  /// @returns {Device}
  static requestDevice() { Gpu.requestDevice({}) }
}

// ---------------------------------------------------------------
// `GpuCore` — Wren class that emulates gpu_native.wren's foreign
// `GpuCore` surface so the rest of the wrappers can be ported
// verbatim. Methods accept the same `descriptor` Maps the native
// foreign class does; this layer translates them into the web
// plugin's flat handle / JSON shape.
// ---------------------------------------------------------------
class GpuCore {
  // -- Device --------------------------------------------------
  static requestDevice(descriptor) { 0 } // single global device on web; just an opaque token
  static deviceDestroy(id)         {}     // no-op; the JS-side device lives for the page
  static deviceInfo(id) {
    return { "name": "WebGPU", "backend": "webgpu", "deviceType": "browser" }
  }

  // -- Buffer --------------------------------------------------
  static bufferCreate(deviceId, descriptor) {
    var size  = descriptor["size"]
    var usage = bufferUsageBits_(descriptor["usage"])
    var h = GpuWeb_.createBuffer(size, usage)
    if (h < 0) Fiber.abort("GpuCore.bufferCreate: device returned no handle.")
    return h
  }
  static bufferDestroy(id) { GpuWeb_.destroyBuffer(id) }
  static bufferSize(id)    { 0 } // size is tracked Wren-side; foreign doesn't expose it
  static bufferWriteFloats(id, offset, data) { GpuWeb_.bufferWriteFloats(id, offset, data) }
  static bufferWriteUints(id, offset, data)  { GpuWeb_.bufferWriteUints(id, offset, data) }
  static bufferWriteMat4s(id, offset, mats)  {
    var floats = []
    for (m in mats) { for (i in 0...16) floats.add(m[i]) }
    GpuWeb_.bufferWriteFloats(id, offset, floats)
  }
  static bufferWriteVec3s(id, offset, vecs) {
    var floats = []
    for (v in vecs) {
      floats.add(v[0])
      floats.add(v[1])
      floats.add(v[2])
    }
    GpuWeb_.bufferWriteFloats(id, offset, floats)
  }
  static bufferWriteVec4s(id, offset, vecs) {
    var floats = []
    for (v in vecs) {
      floats.add(v[0])
      floats.add(v[1])
      floats.add(v[2])
      floats.add(v[3])
    }
    GpuWeb_.bufferWriteFloats(id, offset, floats)
  }
  static bufferWriteQuats(id, offset, quats) { bufferWriteVec4s(id, offset, quats) }
  static bufferReadBytes(id) { Fiber.abort("GpuCore.bufferReadBytes: not yet supported on the web backend.") }

  // -- Shader --------------------------------------------------
  static shaderCreate(deviceId, descriptor) {
    var h = GpuWeb_.createShader(descriptor["code"])
    if (h < 0) Fiber.abort("GpuCore.shaderCreate: shader compile failed.")
    return h
  }
  static shaderDestroy(id) { GpuWeb_.destroy(id) }

  // -- Texture -------------------------------------------------
  static textureCreate(deviceId, descriptor) {
    var json = {
      "width":  descriptor["width"],
      "height": descriptor["height"],
      "format": descriptor["format"],
      "usage":  textureUsageBits_(descriptor["usage"])
    }
    if (descriptor.containsKey("depth"))         json["depth"]         = descriptor["depth"]
    if (descriptor.containsKey("dimension"))     json["dimension"]     = descriptor["dimension"]
    if (descriptor.containsKey("mipLevelCount")) json["mipLevelCount"] = descriptor["mipLevelCount"]
    if (descriptor.containsKey("sampleCount"))   json["sampleCount"]   = descriptor["sampleCount"]
    var h = GpuWeb_.createTexture(Json_.stringify(json))
    if (h < 0) Fiber.abort("GpuCore.textureCreate: device returned no handle.")
    return h
  }
  static textureDestroy(id) { GpuWeb_.destroy(id) }
  static textureCreateView(textureId) {
    var h = GpuWeb_.createTextureView(textureId, null)
    if (h < 0) Fiber.abort("GpuCore.textureCreateView: failed.")
    return h
  }
  static viewDestroy(id) { GpuWeb_.destroy(id) }

  // -- Sampler -------------------------------------------------
  static samplerCreate(deviceId, descriptor) {
    var json = descriptor is Map ? descriptor : {}
    var h = GpuWeb_.createSampler(Json_.stringify(json))
    if (h < 0) Fiber.abort("GpuCore.samplerCreate: failed.")
    return h
  }
  static samplerDestroy(id) { GpuWeb_.destroy(id) }

  // -- Bind group layout / pipeline layout / bind group -------
  static bindGroupLayoutCreate(deviceId, descriptor) {
    var entries = []
    for (e in descriptor["entries"]) {
      var rec = {
        "binding":    e["binding"],
        "visibility": visibilityString_(e["visibility"])
      }
      var kind = e["kind"]
      if (kind == "uniform") {
        rec["buffer"] = { "type": "uniform" }
      } else if (kind == "storage") {
        rec["buffer"] = { "type": "storage" }
      } else if (kind == "read-only-storage") {
        rec["buffer"] = { "type": "read-only-storage" }
      } else if (kind == "sampler") {
        rec["sampler"] = {}
      } else if (kind == "texture") {
        var t = {}
        if (e.containsKey("sampleType"))    t["sampleType"]    = e["sampleType"]
        if (e.containsKey("viewDimension")) t["viewDimension"] = e["viewDimension"]
        if (e.containsKey("multisampled"))  t["multisampled"]  = e["multisampled"]
        rec["texture"] = t
      } else if (kind == "storage-texture") {
        var st = {}
        if (e.containsKey("access"))        st["access"]        = e["access"]
        if (e.containsKey("format"))        st["format"]        = e["format"]
        if (e.containsKey("viewDimension")) st["viewDimension"] = e["viewDimension"]
        rec["storageTexture"] = st
      } else {
        Fiber.abort("GpuCore.bindGroupLayoutCreate: unknown kind %(kind)")
      }
      entries.add(rec)
    }
    var h = GpuWeb_.createBindGroupLayout(Json_.stringify({ "entries": entries }))
    if (h < 0) Fiber.abort("GpuCore.bindGroupLayoutCreate: failed.")
    return h
  }
  static bindGroupLayoutDestroy(id) { GpuWeb_.destroy(id) }

  // PipelineLayout — web has no separate handle for it. Encode
  // the bgls as a list and stash; renderPipelineCreate consumes it.
  // Returns the JSON-encoded bgl-id list as the "id"; consumers
  // pass the wrapper through unchanged.
  static pipelineLayoutCreate(deviceId, descriptor) {
    return descriptor["bindGroupLayouts"]   // List<Num> (bgl ids)
  }
  static pipelineLayoutDestroy(id) {}

  static bindGroupCreate(deviceId, descriptor) {
    var entries = []
    for (e in descriptor["entries"]) {
      var resource = null
      if (e.containsKey("buffer")) {
        resource = { "kind": "buffer", "buffer": e["buffer"] }
        if (e.containsKey("offset")) resource["offset"] = e["offset"]
        if (e.containsKey("size"))   resource["size"]   = e["size"]
      } else if (e.containsKey("view")) {
        resource = { "kind": "textureView", "view": e["view"] }
      } else if (e.containsKey("sampler")) {
        resource = { "kind": "sampler", "sampler": e["sampler"] }
      } else {
        Fiber.abort("GpuCore.bindGroupCreate: entry needs buffer / view / sampler.")
      }
      entries.add({ "binding": e["binding"], "resource": resource })
    }
    var json = { "layout": descriptor["layout"], "entries": entries }
    var h = GpuWeb_.createBindGroup(Json_.stringify(json))
    if (h < 0) Fiber.abort("GpuCore.bindGroupCreate: failed.")
    return h
  }
  static bindGroupDestroy(id) { GpuWeb_.destroy(id) }

  // -- Render pipeline ----------------------------------------
  static renderPipelineCreate(deviceId, descriptor) {
    var v = descriptor["vertex"]
    var vout = {
      "shader": v["module"],
      "entry":  v["entryPoint"]
    }
    if (v.containsKey("buffers")) vout["buffers"] = v["buffers"]
    var json = { "vertex": vout }
    if (descriptor.containsKey("layout")) {
      var l = descriptor["layout"]
      // l is either "auto" or a List<Num> (from pipelineLayoutCreate
      // above), or an Object with .id (PipelineLayout wrapper).
      if (l is String) {
        // "auto" — just omit, JS bridge defaults.
      } else if (l is List) {
        json["layouts"] = l
      } else {
        Fiber.abort("GpuCore.renderPipelineCreate: unrecognised layout shape.")
      }
    }
    if (descriptor.containsKey("fragment")) {
      var f = descriptor["fragment"]
      json["fragment"] = {
        "shader":  f["module"],
        "entry":   f["entryPoint"],
        "targets": f["targets"]
      }
    }
    if (descriptor.containsKey("primitive"))    json["primitive"]    = descriptor["primitive"]
    if (descriptor.containsKey("depthStencil")) json["depthStencil"] = descriptor["depthStencil"]
    var h = GpuWeb_.createPipeline(Json_.stringify(json))
    if (h < 0) Fiber.abort("GpuCore.renderPipelineCreate: failed.")
    return h
  }
  static renderPipelineDestroy(id) { GpuWeb_.destroy(id) }

  // -- Encoder + render pass ----------------------------------
  // Web has no explicit encoder; "begin frame" creates one
  // implicitly. We fake an encoder id by carrying the frame
  // handle through. `encoderRecordPass` plays back a list of
  // render-pass commands against the live GPU pass handle.
  static encoderCreate(deviceId, descriptor) { 0 } // not used on web
  static encoderDestroy(id) {}
  static encoderRecordPass(encoderId, descriptor) {
    var passDesc = {}
    var cas = []
    for (a in descriptor["colorAttachments"]) {
      var rec = {}
      // `view: -1` is the SurfaceFrame sentinel — omit so the JS
      // bridge falls back to the frame's surface view.
      if (a.containsKey("view") && a["view"] >= 0) rec["view"] = a["view"]
      if (a.containsKey("loadOp"))     rec["loadOp"]     = a["loadOp"]
      if (a.containsKey("clearValue")) rec["clearValue"] = a["clearValue"]
      if (a.containsKey("storeOp"))    rec["storeOp"]    = a["storeOp"]
      cas.add(rec)
    }
    passDesc["colorAttachments"] = cas
    if (descriptor.containsKey("depthStencilAttachment")) {
      var ds = descriptor["depthStencilAttachment"]
      var rec = { "view": ds["view"] }
      if (ds.containsKey("depthLoadOp"))     rec["depthLoadOp"]     = ds["depthLoadOp"]
      if (ds.containsKey("depthClearValue")) rec["depthClearValue"] = ds["depthClearValue"]
      if (ds.containsKey("depthStoreOp"))    rec["depthStoreOp"]    = ds["depthStoreOp"]
      passDesc["depthStencilAttachment"] = rec
    }
    var pass = GpuWeb_.renderPassBegin(encoderId, Json_.stringify(passDesc))
    if (pass < 0) Fiber.abort("GpuCore.encoderRecordPass: renderPassBegin failed.")
    for (cmd in descriptor["commands"]) {
      var op = cmd["op"]
      if (op == "setPipeline") {
        GpuWeb_.renderPassSetPipeline(pass, cmd["pipeline"])
      } else if (op == "setBindGroup") {
        GpuWeb_.renderPassSetBindGroup(pass, cmd["index"], cmd["group"])
      } else if (op == "setVertexBuffer") {
        GpuWeb_.renderPassSetVertexBuffer(pass, cmd["slot"], cmd["buffer"])
      } else if (op == "setIndexBuffer") {
        var fmt32 = cmd["format"] == "uint32" ? 1 : 0
        GpuWeb_.renderPassSetIndexBuffer(pass, cmd["buffer"], fmt32)
      } else if (op == "draw") {
        GpuWeb_.renderPassDraw(pass,
          cmd["vertexCount"],
          cmd.containsKey("instanceCount") ? cmd["instanceCount"] : 1,
          0, 0)
      } else if (op == "drawIndexed") {
        GpuWeb_.renderPassDrawIndexed(pass,
          cmd["indexCount"],
          cmd.containsKey("instanceCount") ? cmd["instanceCount"] : 1,
          0, 0, 0)
      } else {
        Fiber.abort("GpuCore.encoderRecordPass: unknown op %(op)")
      }
    }
    GpuWeb_.renderPassEnd(pass)
  }
  static encoderCopyTextureToBuffer(encoderId, textureId, bufferId, descriptor) {
    Fiber.abort("GpuCore.encoderCopyTextureToBuffer: not supported on the web backend.")
  }
  static encoderFinish(id) {} // queueSubmit ends the frame

  static queueSubmit(deviceId, encoderIds) {
    // Each "encoder id" is the frame handle. End them all.
    for (id in encoderIds) GpuWeb_.endFrame(id)
  }

  // -- Surface ------------------------------------------------
  // Web's surface is just the canvas attachment. `handle` is
  // either a Map (native shape) or a Num (web shape — the canvas
  // handle from @hatch:window's `Window.create_`). We accept
  // both; Map shape takes the canvas handle from `handle["canvas"]`
  // when present (a future bridge form), otherwise aborts.
  static surfaceCreate(deviceId, handle) {
    var canvas = -1
    if (handle is Num) canvas = handle
    if (handle is Map && handle.containsKey("canvas")) canvas = handle["canvas"]
    if (canvas < 0) Fiber.abort("GpuCore.surfaceCreate: web requires a canvas Num handle.")
    var s = GpuWeb_.attachCanvas(canvas)
    if (s < 0) Fiber.abort("GpuCore.surfaceCreate: attach failed.")
    return s
  }
  static surfaceDestroy(id)             {}    // canvas lives until the page goes away
  static surfaceConfigure(id, descriptor) {}  // canvas was configured at attach time
  static surfaceAcquire(id) {
    var frame = GpuWeb_.beginFrame(id)
    if (frame < 0) Fiber.abort("GpuCore.surfaceAcquire: beginFrame failed.")
    // No separate "view" handle on web — the JS bridge resolves
    // the surface view internally when the render pass omits it.
    return { "frame": frame, "view": -1 }
  }
  static surfacePresentFrame(frameId) { GpuWeb_.endFrame(frameId) }

  // -- Texture upload -----------------------------------------
  static queueWriteTexture(textureId, bytes, descriptor) {
    var json = {
      "bytesPerRow": descriptor["bytesPerRow"]
    }
    if (descriptor.containsKey("rowsPerImage")) json["rowsPerImage"] = descriptor["rowsPerImage"]
    if (descriptor.containsKey("width"))        json["width"]        = descriptor["width"]
    if (descriptor.containsKey("height"))       json["height"]       = descriptor["height"]
    if (descriptor.containsKey("depth"))        json["depth"]        = descriptor["depth"]
    if (descriptor.containsKey("mipLevel"))     json["mipLevel"]     = descriptor["mipLevel"]
    // Native uses "x"/"y" inline — translate to WebGPU's "origin".
    if (descriptor.containsKey("x") || descriptor.containsKey("y")) {
      json["origin"] = {
        "x": descriptor.containsKey("x") ? descriptor["x"] : 0,
        "y": descriptor.containsKey("y") ? descriptor["y"] : 0,
        "z": 0
      }
    }
    var ok = GpuWeb_.queueWriteTexture(textureId, bytes, Json_.stringify(json))
    if (ok < 1) Fiber.abort("GpuCore.queueWriteTexture: failed.")
  }

  // -- Internal helpers ---------------------------------------
  // Native uses string-list usage; the web foreign API takes a
  // numeric bitset. Mappings come from GPUBufferUsage /
  // GPUTextureUsage spec values.
  static bufferUsageBits_(usage) {
    if (usage is Num) return usage
    var bits = 0
    for (u in usage) {
      if      (u == "map-read")  bits = bits | 1
      else if (u == "map-write") bits = bits | 2
      else if (u == "copy-src")  bits = bits | 4
      else if (u == "copy-dst")  bits = bits | 8
      else if (u == "index")     bits = bits | 16
      else if (u == "vertex")    bits = bits | 32
      else if (u == "uniform")   bits = bits | 64
      else if (u == "storage")   bits = bits | 128
      else if (u == "indirect")  bits = bits | 256
      else if (u == "query-resolve") bits = bits | 512
      else Fiber.abort("GpuCore: unknown buffer usage %(u)")
    }
    return bits
  }
  static textureUsageBits_(usage) {
    if (usage is Num) return usage
    var bits = 0
    for (u in usage) {
      if      (u == "copy-src")          bits = bits | 1
      else if (u == "copy-dst")          bits = bits | 2
      else if (u == "texture-binding")   bits = bits | 4
      else if (u == "storage-binding")   bits = bits | 8
      else if (u == "render-attachment") bits = bits | 16
      else Fiber.abort("GpuCore: unknown texture usage %(u)")
    }
    return bits
  }
  static visibilityString_(v) {
    // Native uses a List<String> ["vertex", "fragment", ...]; the
    // web JSON expects a pipe-joined string or numeric bitset.
    // Emit pipe form so the JS bridge's parseVisibility handles it.
    if (v is String) return v
    if (v is Num)    return v
    var parts = []
    for (s in v) parts.add(s)
    var out = ""
    var first = true
    for (s in parts) {
      if (!first) out = out + "|"
      out = out + s
      first = false
    }
    return out
  }
}

// ---------------------------------------------------------------
// Wrapper classes — identical shape to gpu_native.wren.
// `GpuCore` (above) handles the foreign translation; everything
// below is target-agnostic.
// ---------------------------------------------------------------

/// GPU device — the root of every GPU resource. Build one with
/// [Gpu.requestDevice], then create [Buffer]s, [Texture]s,
/// [Sampler]s, [ShaderModule]s, [BindGroupLayout]s,
/// [PipelineLayout]s, [BindGroup]s, [RenderPipeline]s,
/// [CommandEncoder]s, and [Surface]s off of it.
class Device {
  construct new_(id) {
    _id = id
    _lastFrame = -1
  }
  /// Foreign-handle id (internal).
  /// @returns {Num}
  id { _id }
  /// Device info string (driver / adapter description).
  /// @returns {String}
  info { GpuCore.deviceInfo(_id) }

  // Web-only — the most-recently-acquired SurfaceFrame's handle.
  // `Surface.acquire()` stamps it; `createCommandEncoder()` reads
  // it so a fresh encoder targets the live frame. Native users
  // never need this getter; on web it lets the same flow
  // (`surface.acquire(); device.createCommandEncoder(); ...`)
  // produce the right submission.
  lastFrame_           { _lastFrame }
  setLastFrame_(f)     { _lastFrame = f }

  /// Allocate a [Buffer] from a descriptor (`size`, `usage`,
  /// optional `mappedAtCreation`).
  ///
  /// @param {Map} descriptor
  /// @returns {Buffer}
  createBuffer(descriptor) {
    if (!(descriptor is Map)) Fiber.abort("Device.createBuffer: descriptor must be a Map.")
    var bid = GpuCore.bufferCreate(_id, descriptor)
    return Buffer.new_(bid, descriptor["size"])
  }

  /// Compile a WGSL [ShaderModule]. `descriptor.code` is the
  /// shader source string.
  ///
  /// @param {Map} descriptor
  /// @returns {ShaderModule}
  createShaderModule(descriptor) {
    if (!(descriptor is Map)) Fiber.abort("Device.createShaderModule: descriptor must be a Map.")
    var sid = GpuCore.shaderCreate(_id, descriptor)
    return ShaderModule.new_(sid)
  }

  /// Allocate a [Texture] from a descriptor (`width`, `height`,
  /// `format`, `usage`).
  ///
  /// @param {Map} descriptor
  /// @returns {Texture}
  createTexture(descriptor) {
    if (!(descriptor is Map)) Fiber.abort("Device.createTexture: descriptor must be a Map.")
    var tid = GpuCore.textureCreate(_id, descriptor)
    return Texture.new_(tid, descriptor)
  }

  /// Build a [Texture] from a decoded image (anything with
  /// `.width` / `.height` / `.pixels`).
  ///
  /// @param {Object} image
  /// @returns {Texture}
  uploadImage(image) { uploadImage(image, {}) }

  /// Same as `uploadImage(image)` with an `options` Map for
  /// `format` (default `"rgba8unorm-srgb"`) and `extraUsage`.
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
    var tex = createTexture(desc)
    writeTexture(tex, image.pixels, {
      "width":       image.width,
      "height":      image.height,
      "bytesPerRow": image.width * 4
    })
    return tex
  }

  /// Upload pixel bytes into a [Texture]. `descriptor` carries
  /// `width` / `height` / `bytesPerRow`; the texture must have
  /// been created with `"copy-dst"` in its `usage`.
  ///
  /// @param {Texture} texture
  /// @param {ByteArray} bytes
  /// @param {Map} descriptor
  writeTexture(texture, bytes, descriptor) {
    GpuCore.queueWriteTexture(texture.id, bytes, descriptor)
  }

  /// Allocate a [Sampler] from a descriptor (`magFilter`,
  /// `minFilter`, `addressModeU`, …).
  ///
  /// @param {Map} descriptor
  /// @returns {Sampler}
  createSampler(descriptor) {
    if (!(descriptor is Map)) descriptor = {}
    var sid = GpuCore.samplerCreate(_id, descriptor)
    return Sampler.new_(sid)
  }

  createBindGroupLayout(descriptor) {
    var lid = GpuCore.bindGroupLayoutCreate(_id, descriptor)
    return BindGroupLayout.new_(lid)
  }

  createPipelineLayout(descriptor) {
    var ids = []
    for (l in descriptor["bindGroupLayouts"]) ids.add(l.id)
    var pdesc = { "bindGroupLayouts": ids }
    var plid = GpuCore.pipelineLayoutCreate(_id, pdesc)
    return PipelineLayout.new_(plid)
  }

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
    var bid = GpuCore.bindGroupCreate(_id, dec)
    return BindGroup.new_(bid)
  }

  /// Compile a [RenderPipeline] from a descriptor (vertex /
  /// fragment shader entry points, primitive state, blend / cull
  /// modes, target formats, …).
  ///
  /// @param {Map} descriptor
  /// @returns {RenderPipeline}
  createRenderPipeline(descriptor) {
    var dec = RenderPipeline.normalize_(descriptor)
    var pid = GpuCore.renderPipelineCreate(_id, dec)
    return RenderPipeline.new_(pid)
  }

  /// Build a fresh [CommandEncoder] for this frame.
  /// @returns {CommandEncoder}
  createCommandEncoder() { createCommandEncoder({}) }

  /// Build a [CommandEncoder] from an explicit descriptor
  /// (currently a no-op on web; accepted for API parity).
  ///
  /// @param {Map} descriptor
  /// @returns {CommandEncoder}
  createCommandEncoder(descriptor) {
    var enc = CommandEncoder.new_(0, this)
    // Capture the live surface frame so `enc.beginRenderPass`
    // and `device.submit([enc])` know which frame to act on.
    enc.attachFrame_(_lastFrame)
    return enc
  }

  /// Submit one or more finished [CommandEncoder]s to the GPU
  /// queue. Encoders must have been closed via `enc.finish`.
  ///
  /// @param {List} encoders
  submit(encoders) {
    var ids = []
    for (e in encoders) ids.add(e.frameHandle_)
    GpuCore.queueSubmit(_id, ids)
  }

  /// Build a [Surface] backed by a window or canvas. `handle` is
  /// either a `Num` (DOM canvas id from
  /// `wlift_dom_create_canvas`) or a `Map` describing an
  /// already-created surface.
  ///
  /// @param {Object} handle
  /// @returns {Surface}
  createSurface(handle) {
    if (!(handle is Map) && !(handle is Num)) {
      Fiber.abort("Device.createSurface: handle must be a Num (canvas) or Map.")
    }
    var sid = GpuCore.surfaceCreate(_id, handle)
    return Surface.new_(sid, this)
  }

  /// Release the device. After destroy, all derived resources
  /// (buffers, textures, pipelines …) are also invalid.
  destroy {
    GpuCore.deviceDestroy(_id)
    _id = -1
  }

  toString { "Device(%(_id))" }
}

class Buffer {
  construct new_(id, size) {
    _id = id
    _size = size
  }
  id   { _id }
  size { _size }

  writeFloats(offset, data) { GpuCore.bufferWriteFloats(_id, offset, data) }
  writeUints(offset, data)  { GpuCore.bufferWriteUints(_id, offset, data) }

  writeMat4s(offset, mats) { GpuCore.bufferWriteMat4s(_id, offset, Buffer.dataOf_(mats)) }
  writeVec3s(offset, vecs) { GpuCore.bufferWriteVec3s(_id, offset, Buffer.dataOf_(vecs)) }
  writeVec4s(offset, vecs) { GpuCore.bufferWriteVec4s(_id, offset, Buffer.dataOf_(vecs)) }
  writeQuats(offset, quats) { GpuCore.bufferWriteQuats(_id, offset, Buffer.dataOf_(quats)) }

  static dataOf_(items) {
    var out = []
    for (item in items) out.add(item.data)
    return out
  }

  readBytes() { GpuCore.bufferReadBytes(_id) }

  destroy {
    GpuCore.bufferDestroy(_id)
    _id = -1
  }

  toString { "Buffer(%(_id), %(_size) bytes)" }
}

class ShaderModule {
  construct new_(id) { _id = id }
  id { _id }
  destroy {
    GpuCore.shaderDestroy(_id)
    _id = -1
  }
  toString { "ShaderModule(%(_id))" }
}

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

class RenderPipeline {
  construct new_(id) { _id = id }
  id { _id }
  destroy {
    GpuCore.renderPipelineDestroy(_id)
    _id = -1
  }

  // Identical to native: unwrap shader / layout objects into raw
  // ids so the descriptor handed to GpuCore is pure data.
  static normalize_(d) {
    var out = {}
    if (d.containsKey("label")) out["label"] = d["label"]
    if (d.containsKey("layout")) {
      var l = d["layout"]
      out["layout"] = (l is String) ? l : l.id
    }
    var v = d["vertex"]
    var vout = { "module": v["module"].id, "entryPoint": v["entryPoint"] }
    if (v.containsKey("buffers")) vout["buffers"] = v["buffers"]
    out["vertex"] = vout
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

/// Records GPU commands. Build one per frame via
/// [Device.createCommandEncoder], open a render pass with
/// [CommandEncoder.beginRenderPass], record draws, call `finish`,
/// then submit through `device.submit([enc])`.
class CommandEncoder {
  construct new_(id, device) {
    _id = id
    _device = device
    _frame = -1
  }

  /// Foreign-handle id. Internal — passed to GPU bridge calls.
  /// @returns {Num}
  id     { _id }
  /// The owning [Device].
  /// @returns {Device}
  device { _device }

  // Web detail: the frame handle lives on the encoder so
  // `device.submit([enc])` can call endFrame on it. The Surface's
  // acquire stamps it via `attachFrame_` below.
  frameHandle_     { _frame }
  attachFrame_(f)  { _frame = f }

  /// Open a render pass against the given descriptor (colour /
  /// depth attachments, clear values, …) and return a
  /// [RenderPass] for recording draws.
  ///
  /// ## Example
  ///
  /// ```wren
  /// var pass = enc.beginRenderPass({
  ///   "colorAttachments": [{
  ///     "view":       frame.view,
  ///     "loadOp":     "clear",
  ///     "clearValue": { "r": 0, "g": 0, "b": 0, "a": 1 },
  ///     "storeOp":    "store"
  ///   }]
  /// })
  /// ```
  ///
  /// @param {Map} descriptor
  /// @returns {RenderPass}
  beginRenderPass(descriptor) { return RenderPass.new_(this, descriptor) }

  /// Copy texels from a [Texture] into a [Buffer].
  ///
  /// @param {Texture} texture
  /// @param {Buffer} buffer
  /// @param {Map} descriptor
  copyTextureToBuffer(texture, buffer, descriptor) {
    GpuCore.encoderCopyTextureToBuffer(_id, texture.id, buffer.id, descriptor)
  }

  /// Close recording. Returns `this` so callers can chain
  /// `device.submit([enc.finish])` on a single line.
  /// @returns {CommandEncoder}
  finish {
    GpuCore.encoderFinish(_id)
    return this
  }

  /// Release the encoder's GPU resources.
  destroy {
    GpuCore.encoderDestroy(_id)
    _id = -1
  }
}

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

  end {
    var dec = RenderPass.normalizeDescriptor_(_desc)
    dec["commands"] = _cmds
    // The "encoderId" on web is the frame handle. Pull it out of
    // the encoder so encoderRecordPass (which calls renderPassBegin
    // against a frame) gets the right one.
    GpuCore.encoderRecordPass(_encoder.frameHandle_, dec)
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

/// Render target backed by a window or canvas. Configure once
/// (size + format), then call [Surface.acquire] each frame to
/// get the next frame's view.
class Surface {
  construct new_(id, device) {
    _id     = id
    _device = device
  }

  /// Foreign-handle id (internal).
  /// @returns {Num}
  id { _id }

  /// Apply a configuration descriptor (`width`, `height`,
  /// `format`, `presentMode`, …). Call after window resize.
  /// @param {Map} descriptor
  configure(descriptor) { GpuCore.surfaceConfigure(_id, descriptor) }

  /// Acquire the next frame for rendering. Returns a
  /// [SurfaceFrame] with the texture view to attach in the
  /// render-pass descriptor.
  /// @returns {SurfaceFrame}
  acquire() {
    var pair = GpuCore.surfaceAcquire(_id)
    // Stamp the device so a subsequent `createCommandEncoder()`
    // picks this frame up; keeps the native flow
    // (`acquire; createCommandEncoder; ...`) working unchanged.
    _device.setLastFrame_(pair["frame"])
    return SurfaceFrame.new_(pair["frame"], pair["view"])
  }

  /// Release the surface.
  destroy {
    GpuCore.surfaceDestroy(_id)
    _id = -1
  }
}

/// One frame's worth of [Surface] state — texture view + handle.
/// Returned by [Surface.acquire]; pass `view` into the colour
/// attachment of [CommandEncoder.beginRenderPass].
class SurfaceFrame {
  construct new_(frameId, viewId) {
    _id   = frameId
    _view = TextureView.new_(viewId, null, 0, 0)
  }

  /// Foreign-handle id (internal).
  /// @returns {Num}
  id   { _id }
  /// `TextureView` to bind into a render pass's colour attachment.
  /// @returns {TextureView}
  view { _view }

  // Web detail: `device.submit([encoder])` already calls
  // endFrame internally, so present is a no-op when the user
  // followed that flow. Calling it explicitly is still safe and
  // matches native's contract (where it schedules the swap).

  /// Present the frame. On web, `device.submit([encoder])`
  /// already presents internally; calling this explicitly is
  /// safe and matches the native contract (where it schedules
  /// the swap).
  present {
    if (_id >= 0) {
      GpuCore.surfacePresentFrame(_id)
      _id = -1
    }
  }
}

// ---------------------------------------------------------------
// Higher-level helpers — pure Wren, ported verbatim from
// gpu_native.wren. They build on Device / Buffer / Texture /
// RenderPipeline / RenderPass and have no foreign calls of their
// own, so the same code runs on both targets.
// ---------------------------------------------------------------

/// Orthographic camera for 2D scenes. `(0, 0)` is the top-left
/// of the design-space rectangle the camera describes; `(width,
/// height)` is the bottom-right. Set `origin` to scroll.
///
/// Pair with [Camera2D.fitContain] (or [Camera2D.contain] which
/// builds + fits in one call) to letterbox the design rect into
/// a differently-sized surface without distorting aspect ratio.
class Camera2D {
  /// Build a camera with the given design-space dimensions.
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

  /// Build a camera and fit it into a surface in one call. The
  /// design rect (`designW × designH`) is letterboxed to keep
  /// its aspect ratio when the surface aspect differs.
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

  /// Recompute letterbox padding so the design rect fits inside
  /// `(surfaceW × surfaceH)` while preserving aspect ratio.
  /// Call after window resizes — `Game.resize` is the typical
  /// home for this.
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
      _padX = (_height * sa - _width) / 2
      _padY = 0
    } else {
      _padX = 0
      _padY = (_width / sa - _height) / 2
    }
  }

  /// Drop letterbox padding so the design rect stretches to
  /// fill the surface (aspect ratio not preserved).
  fitStretch() {
    _padX = 0
    _padY = 0
  }

  /// View-projection matrix for this frame. Pass to
  /// [Renderer2D.beginFrame] (or any 2D renderer that consumes
  /// a `viewProj` uniform).
  /// @returns {Mat4}
  viewProj {
    var l = _origin.x - _padX
    var r = _origin.x + _width + _padX
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
/// past the cap aborts the fiber — flush more often, or split
/// the scene into multiple passes.
class Renderer2D {
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
  static FLOATS_PER_VERTEX_  { 8 }
  static VERTS_PER_SPRITE_   { 6 }

  /// Build a 2D sprite batcher targeting a colour-only attachment.
  ///
  /// @param {Device} device
  /// @param {String} surfaceFormat — e.g. `"bgra8unorm"`.
  construct new(device, surfaceFormat) { init_(device, surfaceFormat, null) }

  /// Build a 2D batcher that also writes to a depth attachment.
  /// Use when overlaying 2D HUDs on top of a 3D scene.
  ///
  /// @param {Device} device
  /// @param {String} surfaceFormat
  /// @param {String} depthFormat — e.g. `"depth32float"`.
  construct new(device, surfaceFormat, depthFormat) { init_(device, surfaceFormat, depthFormat) }

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
        "targets": [{
          "format": surfaceFormat,
          // Standard alpha-blend (src-over). Without this the
          // colour target writes RGB verbatim regardless of the
          // fragment's alpha — soft sprites (gradient glows,
          // anti-aliased edges) read as hard discs.
          "blend": {
            "color": {
              "srcFactor": "src-alpha",
              "dstFactor": "one-minus-src-alpha",
              "operation": "add"
            },
            "alpha": {
              "srcFactor": "one",
              "dstFactor": "one-minus-src-alpha",
              "operation": "add"
            }
          }
        }]
      },
      "primitive": { "topology": "triangle-list", "cullMode": "none" },
      "label": "renderer2d-pipeline"
    }
    if (depthFormat != null) {
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
      "size":  64,
      "usage": ["uniform", "copy-dst"],
      "label": "renderer2d-ubo"
    })
    _sampler = device.createSampler({
      "magFilter": "linear", "minFilter": "linear",
      "addressModeU": "clamp-to-edge", "addressModeV": "clamp-to-edge"
    })

    _floats     = []
    _cameraScratch = List.filled(16, 0)
    _spriteCount = 0
    _curTexture  = null
    _curBindGroup = null
    _bindGroups   = {}
  }

  /// Reset the per-frame batch and upload `camera.viewProj`'s
  /// matrix into the uniform buffer. Call once per frame, before
  /// any `drawSprite*` calls.
  ///
  /// @param {Camera2D} camera
  beginFrame(camera) {
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
    _floats.clear()
    _spriteCount = 0
    _curTexture = null
    _curBindGroup = null
  }

  /// Queue an axis-aligned, full-texture sprite at `(x, y)` with
  /// the given size. Position is the top-left corner.
  ///
  /// @param {Texture} texture
  /// @param {Num} x
  /// @param {Num} y
  /// @param {Num} w
  /// @param {Num} h
  drawSprite(texture, x, y, w, h) {
    drawSprite_(texture, x, y, w, h, 0, 0, 1, 1, 1, 1, 1, 1)
  }

  /// Queue an axis-aligned sprite with custom UV bounds —
  /// useful for atlas slicing.
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

    pushVertex_(f, x,  y,  u0, v0, r, g, b, a)
    pushVertex_(f, x,  y1, u0, v1, r, g, b, a)
    pushVertex_(f, x1, y1, u1, v1, r, g, b, a)
    pushVertex_(f, x,  y,  u0, v0, r, g, b, a)
    pushVertex_(f, x1, y1, u1, v1, r, g, b, a)
    pushVertex_(f, x1, y,  u1, v0, r, g, b, a)
    _spriteCount = _spriteCount + 1
  }

  // Rotated quad. (cx, cy) is the centre; w/h are full width and
  // height; rot is in radians. Local-space corners (-hw,-hh),
  // (hw,-hh), (hw,hh), (-hw,hh) are rotated then translated to
  // (cx, cy). Same vertex layout as drawSprite_ so it batches in
  // the same flush call.
  drawSpriteRotated_(texture, cx, cy, w, h, rot, u0, v0, u1, v1, r, g, b, a) {
    if (_curTexture != null && _curTexture.id != texture.id) {
      Fiber.abort("Renderer2D: texture switches require an explicit flush(pass).")
    }
    _curTexture = texture
    if (_spriteCount >= Renderer2D.MAX_SPRITES_) {
      Fiber.abort("Renderer2D: batch full (%(_spriteCount) sprites). Call flush(pass) sooner.")
    }
    var hw = w / 2
    var hh = h / 2
    var co = rot.cos
    var si = rot.sin
    var x0 = cx + (-hw)*co - (-hh)*si
    var y0 = cy + (-hw)*si + (-hh)*co
    var x1 = cx + ( hw)*co - (-hh)*si
    var y1 = cy + ( hw)*si + (-hh)*co
    var x2 = cx + ( hw)*co - ( hh)*si
    var y2 = cy + ( hw)*si + ( hh)*co
    var x3 = cx + (-hw)*co - ( hh)*si
    var y3 = cy + (-hw)*si + ( hh)*co
    var f = _floats
    pushVertex_(f, x0, y0, u0, v0, r, g, b, a)
    pushVertex_(f, x3, y3, u0, v1, r, g, b, a)
    pushVertex_(f, x2, y2, u1, v1, r, g, b, a)
    pushVertex_(f, x0, y0, u0, v0, r, g, b, a)
    pushVertex_(f, x2, y2, u1, v1, r, g, b, a)
    pushVertex_(f, x1, y1, u1, v0, r, g, b, a)
    _spriteCount = _spriteCount + 1
  }

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
  /// then reset for the next frame. No-op when nothing is queued.
  ///
  /// @param {RenderPass} pass
  flush(pass) {
    if (_spriteCount == 0) return
    _vbo.writeFloats(0, _floats)
    var bg = bindGroupFor_(_curTexture)
    pass.setPipeline(_pipeline)
    pass.setBindGroup(0, bg)
    pass.setVertexBuffer(0, _vbo)
    pass.draw(_spriteCount * Renderer2D.VERTS_PER_SPRITE_)
    _floats.clear()
    _spriteCount = 0
    _curTexture = null
  }

  /// Release the GPU resources held by this renderer (vertex /
  /// uniform buffers, sampler, pipeline, layouts). Call when the
  /// renderer goes out of scope; not called automatically.
  destroy {
    _vbo.destroy
    _ubo.destroy
    _sampler.destroy
    _pipeline.destroy
    _pipelineLayout.destroy
    _bgl.destroy
  }
}

/// Mutable sprite state — `(texture, x, y, w, h)` plus tint /
/// scale / anchor / rotation / UV. Reuse one `Sprite` across
/// many frames; mutate its fields between draws. The renderer
/// batches by texture, so swapping `_quad`'s position + UV per
/// call keeps everything in a single draw call.
///
/// ```wren
/// _quad = Sprite.new(_atlas)
/// _quad.anchor(0.5, 0.5)
///
/// // each frame:
/// _quad.x = enemy.x
/// _quad.y = enemy.y
/// _quad.uv(u0, v0, u1, v1)
/// _quad.draw(_renderer)
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
    _rotation = 0
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
  /// Anchor X in `[0, 1]` — `0` = left edge, `0.5` = centre, `1` = right.
  /// @returns {Num}
  anchorX  { _anchorX }
  /// Anchor Y in `[0, 1]` — `0` = top, `0.5` = centre, `1` = bottom.
  /// @returns {Num}
  anchorY  { _anchorY }
  /// Set the anchor in one call.
  /// @param {Num} ax
  /// @param {Num} ay
  anchor(ax, ay) {
    _anchorX = ax
    _anchorY = ay
  }
  /// Per-vertex tint as an `[r, g, b, a]` list, each in `[0, 1]`.
  /// @returns {List}
  tint     { [_tintR, _tintG, _tintB, _tintA] }
  /// Replace the tint from a 4-element list. Allocates the list on
  /// every read of `tint`; prefer [Sprite.setTint] in hot paths.
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
  /// Rotation in radians, around the anchor. `0` keeps the
  /// sprite axis-aligned (faster path).
  /// @returns {Num}
  rotation   { _rotation }
  rotation=(r) { _rotation = r }

  /// Queue this sprite into `renderer`'s batch. Picks the
  /// fast axis-aligned path when `rotation == 0` and the UV /
  /// tint are at defaults; otherwise routes through the rotated
  /// or tinted path.
  ///
  /// @param {Renderer2D} renderer
  draw(renderer) {
    if (!_visible) return
    var dw = _w * _scaleX
    var dh = _h * _scaleY
    if (_rotation != 0) {
      // Rotated path. The rotation pivot is the visual centre of
      // the sprite; we offset by (anchor - 0.5) so the pivot
      // matches the axis-aligned anchor convention.
      var ox = (0.5 - _anchorX) * dw
      var oy = (0.5 - _anchorY) * dh
      renderer.drawSpriteRotated_(_tex, _x + ox, _y + oy, dw, dh, _rotation,
                                  _u0, _v0, _u1, _v1,
                                  _tintR, _tintG, _tintB, _tintA)
      return
    }
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

class Camera3D {
  static perspective(fovY, aspect, near, far) {
    var c = Camera3D.new_()
    c.setProjection_(Mat4.perspective(fovY * 3.141592653589793 / 180, aspect, near, far))
    return c
  }

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

  lookAt(eye, target, up) {
    _eye = eye
    _target = target
    _up = up
    _viewDirty = true
  }

  setPerspective(fovY, aspect, near, far) {
    _proj = Mat4.perspective(fovY * 3.141592653589793 / 180, aspect, near, far)
  }

  eye    { _eye }
  target { _target }
  up     { _up }

  viewProj {
    if (_viewDirty) {
      _view = Mat4.lookAt(_eye, _target, _up)
      _viewDirty = false
    }
    return _proj * _view
  }
}

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

  static cube(device) { cube(device, 1) }
  static cube(device, half) {
    var h = half
    var v = []
    var pushFace = Fn.new {|nx, ny, nz, p0, p1, p2, p3|
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

    pushFace.call( 1, 0, 0,
      [ h, -h, -h], [ h, -h,  h], [ h,  h,  h], [ h,  h, -h])
    pushFace.call(-1, 0, 0,
      [-h, -h,  h], [-h, -h, -h], [-h,  h, -h], [-h,  h,  h])
    pushFace.call( 0, 1, 0,
      [-h,  h, -h], [ h,  h, -h], [ h,  h,  h], [-h,  h,  h])
    pushFace.call( 0,-1, 0,
      [-h, -h,  h], [ h, -h,  h], [ h, -h, -h], [-h, -h, -h])
    pushFace.call( 0, 0, 1,
      [ h, -h,  h], [-h, -h,  h], [-h,  h,  h], [ h,  h,  h])
    pushFace.call( 0, 0,-1,
      [-h, -h, -h], [ h, -h, -h], [ h,  h, -h], [-h,  h, -h])

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

class Renderer3D {
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

  static FLOATS_PER_VERTEX_  { 8 }
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

  beginFrame(pass, camera, light) {
    _pass = pass
    _vp = camera.viewProj
    _light = light
    pass.setPipeline(_pipeline)
    pass.setBindGroup(0, _bindGroup)
  }

  draw(mesh, material, model) {
    if (_pass == null) Fiber.abort("Renderer3D.draw: call beginFrame first.")

    var floats = []
    appendMat4_(floats, _vp)
    appendMat4_(floats, model)
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
    var d = m.data
    out.add(d[0])
    out.add(d[4])
    out.add(d[8])
    out.add(d[12])
    out.add(d[1])
    out.add(d[5])
    out.add(d[9])
    out.add(d[13])
    out.add(d[2])
    out.add(d[6])
    out.add(d[10])
    out.add(d[14])
    out.add(d[3])
    out.add(d[7])
    out.add(d[11])
    out.add(d[15])
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

// LivePipeline on the web is a one-shot wrapper today; live
// hot-reload is planned and needs the parked-fiber + watch path
// to round-trip from the browser's filesystem proxy. The
// constructor builds once and keeps the shape so
// portable code referencing `LivePipeline` doesn't break.
class LivePipeline {
  construct new(device, db, shaderPath, descriptor) {
    _device     = device
    _shaderPath = shaderPath
    _shader     = device.createShaderModule({ "code": db.text(shaderPath), "label": shaderPath })
    var dec = { "vertex": {
      "module":     _shader,
      "entryPoint": descriptor["vertex"]["entryPoint"]
    } }
    if (descriptor["vertex"].containsKey("buffers")) {
      dec["vertex"]["buffers"] = descriptor["vertex"]["buffers"]
    }
    if (descriptor.containsKey("layout")) dec["layout"] = descriptor["layout"]
    if (descriptor.containsKey("fragment")) {
      var f = descriptor["fragment"]
      dec["fragment"] = {
        "module":     _shader,
        "entryPoint": f["entryPoint"],
        "targets":    f["targets"]
      }
    }
    if (descriptor.containsKey("primitive"))    dec["primitive"]    = descriptor["primitive"]
    if (descriptor.containsKey("depthStencil")) dec["depthStencil"] = descriptor["depthStencil"]
    _pipeline = device.createRenderPipeline(dec)
  }

  id { _pipeline.id }

  destroy {
    if (_pipeline != null) _pipeline.destroy
    if (_shader != null) _shader.destroy
    _pipeline = null
    _shader = null
  }
}
