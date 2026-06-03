// `@hatch:gpu/gpu_cull` — GPU compute cull pipeline. Reads a list
// of per-instance bounding spheres + the camera's frustum planes,
// writes a compacted output-instance buffer + a
// `DrawIndexedIndirectArgs` record whose `instance_count` is the
// count of visible instances. Pair with [Renderer3D.
// drawMeshInstancedIndirect] to issue the post-cull draw without
// any CPU readback.
//
// ## Quick start
//
// ```wren
// import "@hatch:gpu" for ComputeCull, Renderer3D, Camera3D
//
// // setup
// var cull       = ComputeCull.new(device)
// var spheresBuf = ComputeCull.createSphereBuffer(device, maxN)
// var srcInstBuf = device.createBuffer({ "size": maxN * 128,
//                  "usage": ["storage", "copy-dst"] })
// var planesBuf  = ComputeCull.createFrustumBuffer(device)
// var indirect   = ComputeCull.createIndirectBuffer(device)
// var outInst    = ComputeCull.createOutputInstanceBuffer(device, maxN)
//
// // per-frame
// planesBuf.writeFloats(0, camera.frustumPlanes)
// ComputeCull.initIndirectArgs(indirect, mesh)
// spheresBuf.writeFloats(0, sphereFloats)
// srcInstBuf.writeFloats(0, instanceFloats)
// var enc = device.createCommandEncoder()
// cull.cull(enc, spheresBuf, srcInstBuf, count, planesBuf, indirect, outInst)
// // ... beginRenderPass + drawMeshInstancedIndirect ...
// device.submit([enc.finish])
// ```
//
// ## Convention notes
//
// - Bounding-sphere SSBO: one `vec4<f32>` per instance — `(cx, cy,
//   cz, radius)`. Caller owns the data; usually built CPU-side
//   from mesh AABB + instance transform.
// - Frustum-planes UBO mirrors `Camera3D.frustumPlanes` (24 f32 =
//   6 × (nx, ny, nz, d)).
// - Indirect-args record matches `wgpu::util::DrawIndexedIndirect`:
//   `[indexCount, instanceCount, firstIndex, baseVertex,
//   firstInstance]` (5 × u32 = 20 B). `instanceCount` is the only
//   field the compute shader writes; pre-init the others CPU-side
//   via [ComputeCull.initIndirectArgs].
// - Compacted output-instance SSBO uses the same 128 B / slot
//   stride as `Renderer3D.drawMeshInstanced` consumes.

import "./gpu_native" for Buffer

/// GPU compute cull. One [ComputeCull] per (device,
/// instance-buffer-budget) caches the pipeline + bind-group layout;
/// rebinding the actual buffers happens lazily inside `cull(...)`.
class ComputeCull {
  /// Per-instance bounding-sphere stride: `vec4<f32>` = 16 bytes.
  static SPHERE_BYTES   { 16 }
  /// `DrawIndexedIndirectArgs` size: 5 × u32 = 20 bytes.
  static INDIRECT_BYTES { 20 }
  /// `CullMeta` UBO stride: u32 + 3 × u32 pad = 16 bytes.
  static META_BYTES     { 16 }
  /// Frustum UBO stride: 6 × `vec4<f32>` = 96 bytes.
  static FRUSTUM_BYTES  { 96 }

  /// Build the compute pipeline + reusable layout objects.
  /// @param {Device} device
  construct new(device) {
    _device = device
    _shader = device.createShaderModule({
      "code":  ComputeCull.WGSL_,
      "label": "cull-shader"
    })
    _bgl = device.createBindGroupLayout({
      "entries": [
        { "binding": 0, "visibility": ["compute"], "kind": "read-only-storage" },
        { "binding": 1, "visibility": ["compute"], "kind": "read-only-storage" },
        { "binding": 2, "visibility": ["compute"], "kind": "uniform"           },
        { "binding": 3, "visibility": ["compute"], "kind": "uniform"           },
        { "binding": 4, "visibility": ["compute"], "kind": "storage"           },
        { "binding": 5, "visibility": ["compute"], "kind": "storage"           }
      ],
      "label": "cull-bgl"
    })
    _layout = device.createPipelineLayout({
      "bindGroupLayouts": [_bgl],
      "label": "cull-pipeline-layout"
    })
    _pipeline = device.createComputePipeline({
      "module":     _shader,
      "entryPoint": "cull_main",
      "layout":     _layout,
      "label":      "cull-pipeline"
    })
    // Scratch UBO for the per-dispatch instance count.
    _metaBuf = device.createBuffer({
      "size":  ComputeCull.META_BYTES,
      "usage": ["uniform", "copy-dst"],
      "label": "cull-meta"
    })
    _bgCache = {}
  }

  /// Convenience: allocate a frustum-planes UBO. 96 B, layout
  /// matches `Camera3D.frustumPlanes`.
  /// @param {Device} device
  /// @returns {Buffer}
  static createFrustumBuffer(device) {
    return device.createBuffer({
      "size":  ComputeCull.FRUSTUM_BYTES,
      "usage": ["uniform", "copy-dst"],
      "label": "cull-frustum"
    })
  }

  /// Allocate a bounding-sphere SSBO sized for `maxInstances`.
  /// @param {Device} device
  /// @param {Num}    maxInstances
  /// @returns {Buffer}
  static createSphereBuffer(device, maxInstances) {
    return device.createBuffer({
      "size":  maxInstances * ComputeCull.SPHERE_BYTES,
      "usage": ["storage", "copy-dst"],
      "label": "cull-spheres"
    })
  }

  /// Allocate a 20-B `DrawIndexedIndirectArgs` buffer. Usage flags
  /// cover indirect-draw + compute-write + CPU init + readback.
  /// @param {Device} device
  /// @returns {Buffer}
  static createIndirectBuffer(device) {
    return device.createBuffer({
      "size":  ComputeCull.INDIRECT_BYTES,
      "usage": ["indirect", "storage", "copy-dst", "copy-src"],
      "label": "cull-indirect"
    })
  }

  /// Allocate a compacted-output instance SSBO. Mirrors the
  /// 128-B-per-slot stride `Renderer3D.drawMeshInstanced` consumes.
  /// @param {Device} device
  /// @param {Num}    maxInstances
  /// @returns {Buffer}
  static createOutputInstanceBuffer(device, maxInstances) {
    return device.createBuffer({
      "size":  maxInstances * 128,
      "usage": ["storage", "copy-dst"],
      "label": "cull-out-instances"
    })
  }

  /// Pre-init the indirect args. CPU writes everything but
  /// `instance_count` (slot 1) — the compute shader resets that
  /// to 0 then atomically bumps it as it admits visible instances.
  /// Call once after creating the buffer (or whenever the mesh's
  /// `indexCount` changes).
  ///
  /// @param {Buffer} indirectBuffer
  /// @param {Mesh}   mesh
  static initIndirectArgs(indirectBuffer, mesh) {
    indirectBuffer.writeUints(0, [
      mesh.indexCount,  // index_count
      0,                // instance_count (compute writes)
      0,                // first_index
      0,                // base_vertex
      0                 // first_instance
    ])
  }

  /// Dispatch the cull pass. Records into `encoder`. Caller is
  /// responsible for uploading bounding spheres, instance
  /// transforms, and `camera.frustumPlanes` to the respective
  /// buffers before invoking this — and for submitting the encoder
  /// + issuing the `drawMeshInstancedIndirect` afterward.
  ///
  /// @param {CommandEncoder} encoder
  /// @param {Buffer} spheresBuf   bounding-sphere SSBO
  /// @param {Buffer} srcInstBuf   source instances SSBO
  /// @param {Num}    count        active instance count
  /// @param {Buffer} planesBuf    96-B frustum UBO
  /// @param {Buffer} indirectBuf  5-u32 indirect-args SSBO
  /// @param {Buffer} outInstBuf   compacted-output instance SSBO
  cull(encoder, spheresBuf, srcInstBuf, count, planesBuf, indirectBuf, outInstBuf) {
    if (count <= 0) return
    // Reset instance_count (slot 1) to 0 — compute atomically
    // bumps it; we must clear stale frame state first.
    indirectBuf.writeUints(4, [0])
    // Push per-dispatch instance count into the meta UBO.
    _metaBuf.writeUints(0, [count, 0, 0, 0])

    var bg = bindGroupFor_(spheresBuf, srcInstBuf, planesBuf, indirectBuf, outInstBuf)
    var pass = encoder.beginComputePass({ "label": "cull-pass" })
    pass.setPipeline(_pipeline)
    pass.setBindGroup(0, bg)
    var groups = ((count + 63) / 64).floor
    pass.dispatchWorkgroups(groups)
    pass.end
  }

  bindGroupFor_(spheres, srcInst, planes, indirect, outInst) {
    var key = "%(spheres.id):%(srcInst.id):%(planes.id):%(indirect.id):%(outInst.id)"
    var existing = _bgCache[key]
    if (existing != null) return existing
    var bg = _device.createBindGroup({
      "layout":  _bgl,
      "entries": [
        { "binding": 0, "buffer": spheres  },
        { "binding": 1, "buffer": srcInst  },
        { "binding": 2, "buffer": planes   },
        { "binding": 3, "buffer": _metaBuf },
        { "binding": 4, "buffer": indirect },
        { "binding": 5, "buffer": outInst  }
      ],
      "label": "cull-bg"
    })
    _bgCache[key] = bg
    return bg
  }

  destroy {
    _metaBuf.destroy
  }

  // The compute shader. Sphere-vs-frustum: a sphere is *outside*
  // the frustum iff its signed distance to ANY plane is < -radius
  // (conservative — passes spheres that straddle a corner; cheaper
  // than AABB-vs-plane). Matches `Frustum.sphereVisible`.
  static WGSL_ {
    return "
      struct DrawUniforms {
        model:      mat4x4<f32>,
        normal_mat: mat4x4<f32>,
      };

      struct DrawIndexedIndirectArgs {
        index_count:    atomic<u32>,
        instance_count: atomic<u32>,
        first_index:    atomic<u32>,
        base_vertex:    atomic<u32>,
        first_instance: atomic<u32>,
      };

      struct Frustum  { planes: array<vec4<f32>, 6> };
      struct CullMeta { count: u32, _pad0: u32, _pad1: u32, _pad2: u32 };

      @group(0) @binding(0) var<storage, read>       spheres:  array<vec4<f32>>;
      @group(0) @binding(1) var<storage, read>       src_inst: array<DrawUniforms>;
      @group(0) @binding(2) var<uniform>             frust:    Frustum;
      @group(0) @binding(3) var<uniform>             cull_meta: CullMeta;
      @group(0) @binding(4) var<storage, read_write> indirect: DrawIndexedIndirectArgs;
      @group(0) @binding(5) var<storage, read_write> out_inst: array<DrawUniforms>;

      @compute @workgroup_size(64)
      fn cull_main(@builtin(global_invocation_id) gid: vec3<u32>) {
        let i = gid.x;
        if (i >= cull_meta.count) { return; }

        let s = spheres[i];
        let center = vec4<f32>(s.xyz, 1.0);
        let radius = s.w;

        var visible: bool = true;
        for (var p: u32 = 0u; p < 6u; p = p + 1u) {
          let dist = dot(frust.planes[p], center);
          if (dist < -radius) { visible = false; }
        }
        if (!visible) { return; }

        let slot = atomicAdd(&indirect.instance_count, 1u);
        out_inst[slot] = src_inst[i];
      }
    "
  }
}
