// skeletal-animation-demo — procedural rig + Renderer3D.drawSkinned
// end-to-end check. Builds a 4-vertex quad bound to two joints
// (left half ↔ joint 0, right half ↔ joint 1), animates joint 1's
// rotation around its anchor, renders with the GPU skinning
// pipeline.
//
// the_strangler glTF integration is parked: the .gltf parser is
// per-byte FFI in pure Wren and the asset's 63 MB scene.bin plus
// ~876k animation-sample floats trip the load-time budget. Once
// the parser ships a typed-array fast path the same demo can swap
// the procedural rig for `_scene.animations[0].applyTo(...)` +
// the_strangler skinned MeshRenderers without changing the rest
// of the pipeline.

import "@hatch:game"  for Game
import "@hatch:gpu"   for Renderer3D, Camera3D, Mesh, Material, SkinPalette
import "@hatch:math"  for Vec3, Vec4, Mat4

class SkeletalDemo is Game {
  config { {
    "title":      "Skeletal Animation Demo",
    "width":      960,
    "height":     720,
    "clearColor": [0.20, 0.22, 0.26, 1.0],
    "depth":      true
  } }

  setup(g) {
    _renderer = Renderer3D.new(g.device, g.surfaceFormat, g.depthFormat)
    _renderer.setAmbient(Vec3.new(0.5, 0.55, 0.65), 0.8)
    _camera = Camera3D.perspective(50, g.width / g.height, 0.1, 50)
    _camera.lookAt(Vec3.new(0, 0, 4), Vec3.zero, Vec3.unitY)

    // Quad — 4 vertices, 2 joints. Left edge fully weighted to
    // joint 0 (the anchor), right edge to joint 1 (the limb).
    var h = 0.5
    var verts = [
      // pos.xyz       normal.xyz   uv.xy     tangent.xyzw
      -h, -h, 0,       0, 0, 1,     0, 0,     1, 0, 0, 1,
       h, -h, 0,       0, 0, 1,     1, 0,     1, 0, 0, 1,
       h,  h, 0,       0, 0, 1,     1, 1,     1, 0, 0, 1,
      -h,  h, 0,       0, 0, 1,     0, 1,     1, 0, 0, 1
    ]
    // Joints + weights, 4 per vertex. Only one influence active.
    var joints  = [0, 0, 0, 0,  1, 0, 0, 0,  1, 0, 0, 0,  0, 0, 0, 0]
    var weights = [1, 0, 0, 0,  1, 0, 0, 0,  1, 0, 0, 0,  1, 0, 0, 0]
    var indices = [0, 1, 2,  0, 2, 3]
    _mesh = Mesh.fromArraysSkinned(g.device, verts, joints, weights, indices)
    _material = Material.new(Vec4.new(0.85, 0.30, 0.30, 1.0))

    _skin = SkinPalette.new(g.device, 2)
    _palette = Float32Array.new(2 * 16)
    _t = 0
  }

  // Joint 0 → identity at the origin. Joint 1 → rotation around
  // (-h, 0, 0) so the right edge of the quad swings. Both packed
  // column-major into _palette for upload.
  composePalette_(t) {
    var c = 0
    while (c < 32) {
      _palette[c] = 0
      c = c + 1
    }
    // Joint 0 (slot 0..15): identity.
    SkeletalDemo.writeMat4ColMajor_(_palette, 0, Mat4.identity)
    // Joint 1 (slot 16..31): rotate Z by (sin(t)*0.6) around (-0.5,0,0).
    var angle = t.sin * 0.6
    var anchor = -0.5
    // T(anchor, 0, 0) * Rz(angle) * T(-anchor, 0, 0)
    var m = Mat4.translation(anchor, 0, 0) *
            Mat4.rotationZ(angle) *
            Mat4.translation(-anchor, 0, 0)
    SkeletalDemo.writeMat4ColMajor_(_palette, 16, m)
    _skin.update(_palette)
  }

  static writeMat4ColMajor_(out, offset, m) {
    var d = m.data
    var c = 0
    while (c < 4) {
      var r = 0
      while (r < 4) {
        out[offset + c * 4 + r] = d[r * 4 + c]
        r = r + 1
      }
      c = c + 1
    }
  }

  update(g) {
    _t = _t + g.dt * 2.0
  }

  draw(g) {
    composePalette_(_t)
    _renderer.beginFrame(g.pass, _camera)
    _renderer.drawSkinned(_mesh, _material, _skin, Mat4.identity)
    _renderer.endFrame()
  }
}

Game.run(SkeletalDemo)
