// Wren-side wrapper for wlift_gpu_web. Pure pass-throughs;
// games typically wrap these into a higher-level renderer.

#!native = "wlift_gpu"
foreign class Gpu {
  // Returns true if WebGPU is available + adapter+device pair
  // was acquired at install. Subsequent calls assume true.
  #!symbol = "wlift_gpu_init"
  foreign static init_()

  // Bind a canvas to a GPU surface. `canvasHandle` comes from
  // @hatch:window's `Window.create_` on wasm builds. Returns
  // surface handle (Num), or `-1` on failure.
  #!symbol = "wlift_gpu_attach_canvas"
  foreign static attachCanvas_(canvasHandle)

  // ---- Frame ----
  #!symbol = "wlift_gpu_begin_frame"
  foreign static beginFrame_(surface)

  // Convenience: clear the frame's surface to a colour without
  // a render pipeline. Equivalent to renderPassBegin_ + end_
  // with a clear-only pass.
  #!symbol = "wlift_gpu_clear"
  foreign static clear_(frame, r, g, b, a)

  #!symbol = "wlift_gpu_end_frame"
  foreign static endFrame_(frame)

  // ---- Buffers ----
  // GPUBufferUsage flags (numeric bitset):
  //   1=MAP_READ, 2=MAP_WRITE, 4=COPY_SRC, 8=COPY_DST,
  //  16=INDEX,    32=VERTEX,   64=UNIFORM, 128=STORAGE,
  // 256=INDIRECT, 512=QUERY_RESOLVE.
  #!symbol = "wlift_gpu_create_buffer"
  foreign static createBuffer_(size, usageBits)

  #!symbol = "wlift_gpu_buffer_write"
  foreign static bufferWrite_(handle, offset, bytes)

  #!symbol = "wlift_gpu_destroy_buffer"
  foreign static destroyBuffer_(handle)

  // Pack a `List<Num>` as `Float32Array` and create a buffer.
  // Pragmatic ergonomics — Wren doesn't have a clean float-bits
  // intrinsic, so the bridge does the conversion.
  #!symbol = "wlift_gpu_create_buffer_from_floats"
  foreign static createBufferFromFloats_(floats, usageBits)

  // Same shape for an existing buffer (per-frame uniform updates).
  #!symbol = "wlift_gpu_buffer_write_floats"
  foreign static bufferWriteFloats_(handle, offset, floats)

  // ---- Shaders / pipelines / bind groups ----
  #!symbol = "wlift_gpu_create_shader"
  foreign static createShader_(wgsl)

  // Descriptors are JSON strings. The bridge parses + maps to
  // GPU* objects. See the plugin lib.rs for descriptor shapes.
  #!symbol = "wlift_gpu_create_bind_group_layout"
  foreign static createBindGroupLayout_(descriptorJson)

  #!symbol = "wlift_gpu_create_bind_group"
  foreign static createBindGroup_(descriptorJson)

  #!symbol = "wlift_gpu_create_pipeline"
  foreign static createPipeline_(descriptorJson)

  // ---- Render pass ----
  // `descriptorJson` may be empty/null for default attachments.
  #!symbol = "wlift_gpu_render_pass_begin"
  foreign static renderPassBegin_(frame, descriptorJson)

  #!symbol = "wlift_gpu_render_pass_set_pipeline"
  foreign static renderPassSetPipeline_(pass, pipeline)

  #!symbol = "wlift_gpu_render_pass_set_bind_group"
  foreign static renderPassSetBindGroup_(pass, groupIndex, bindGroup)

  #!symbol = "wlift_gpu_render_pass_set_vertex_buffer"
  foreign static renderPassSetVertexBuffer_(pass, slot, buffer)

  #!symbol = "wlift_gpu_render_pass_set_index_buffer"
  foreign static renderPassSetIndexBuffer_(pass, buffer, format32)

  #!symbol = "wlift_gpu_render_pass_draw"
  foreign static renderPassDraw_(pass, vertexCount, instanceCount, firstVertex, firstInstance)

  #!symbol = "wlift_gpu_render_pass_draw_indexed"
  foreign static renderPassDrawIndexed_(pass, indexCount, instanceCount, firstIndex, baseVertex, firstInstance)

  #!symbol = "wlift_gpu_render_pass_end"
  foreign static renderPassEnd_(pass)

  // ---- Generic destroy ----
  #!symbol = "wlift_gpu_destroy"
  foreign static destroy_(handle)
}
