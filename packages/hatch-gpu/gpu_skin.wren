// `@hatch:gpu/gpu_skin` — per-skin joint-matrix palette manager.
//
// Owns one storage buffer holding `jointCount * mat4x4<f32>` (64 B
// per joint). The skinning vertex shader binds it as
// `@group(3) @binding(0) var<storage, read> joint_matrices:
// array<mat4x4<f32>>` and indexes it with each vertex's `JOINTS_0`
// attribute, weighted by `WEIGHTS_0`.
//
// Each frame the host:
//   1. Composes the joint world matrices from the joint nodes'
//      Transforms (animation system already handles this).
//   2. Multiplies each joint world by its inverse-bind matrix
//      (from `GltfSkin.inverseBindMatrices`).
//   3. Writes the resulting palette into `SkinPalette.buffer` via
//      `palette.update(matrices)`.
//
// ## Quick start
//
// ```wren
// import "@hatch:gpu" for SkinPalette
//
// var palette = SkinPalette.new(device, 102)
// // ... per frame:
// palette.update(jointMatricesFloat32Array)
// // Skinning pipeline at @group(3) sees palette.bindGroup.
// ```

import "./gpu_native" for Buffer

/// Per-skin storage buffer holding the joint-matrix palette plus
/// a cached `BindGroup` against the renderer's skin `BindGroupLayout`.
/// Allocate one `SkinPalette` per skinned mesh; update each frame.
class SkinPalette {
  /// One `mat4x4<f32>` per joint = 64 bytes.
  static MAT4_BYTES { 64 }

  /// @param {Device} device
  /// @param {Num}    jointCount. Number of joints in the rig (102
  ///   for the_strangler, typically 30-200 for character rigs).
  construct new(device, jointCount) {
    if (jointCount <= 0) Fiber.abort("SkinPalette.new: jointCount must be > 0")
    _device = device
    _jointCount = jointCount
    _buffer = device.createBuffer({
      "size":  jointCount * SkinPalette.MAT4_BYTES,
      "usage": ["storage", "copy-dst"],
      "label": "skin-palette"
    })
    _bindGroup = null   // built lazily on first attach
  }

  /// Number of joints this palette holds. @returns {Num}
  jointCount { _jointCount }

  /// Underlying storage buffer. Bound at `@group(3) @binding(0)`
  /// by the skinning pipeline.
  /// @returns {Buffer}
  buffer { _buffer }

  /// `BindGroup` for `@group(3)`. Lazily built by `bindWith` so
  /// the renderer's BGL drives the layout. Cached for reuse.
  bindGroup { _bindGroup }

  /// Build (or reuse) the bind group using a renderer-supplied
  /// BGL. Renderer3D calls this on first attach so SkinPalette
  /// stays decoupled from the rest of the renderer's layout.
  ///
  /// @param {BindGroupLayout} bgl
  /// @returns {BindGroup}
  bindWith(bgl) {
    if (_bindGroup != null) return _bindGroup
    _bindGroup = _device.createBindGroup({
      "layout":  bgl,
      "entries": [{ "binding": 0, "buffer": _buffer }],
      "label":   "skin-palette-bg"
    })
    return _bindGroup
  }

  /// Upload a packed `Float32Array` of `jointCount * 16` floats
  /// (column-major `mat4x4` per joint, glTF convention) into the
  /// storage buffer. Caller composes each palette entry as
  /// `jointWorld * inverseBindMatrix` so the vertex shader can
  /// just multiply with the per-vertex weighted sum.
  ///
  /// @param {Float32Array} matrices
  update(matrices) {
    _buffer.writeFloats(0, matrices)
  }

  destroy {
    _buffer.destroy
  }
}
