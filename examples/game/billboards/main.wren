// billboards — a ring of 64 quads, each oriented along its own
// world-space axis (the radial direction out from the origin), so
// they fan outward instead of all facing the camera. Drawn via
// Renderer3D.drawMeshInstanced: one unit-quad mesh + per-instance
// model matrices that bake position + per-quad rotation +
// non-uniform size.
//
// Mouse drag orbits the camera; scroll zooms; Escape quits.

import "@hatch:game" for Game
import "@hatch:gpu"  for Renderer3D, Camera3D, Mesh, Material
import "@hatch:math" for Vec3, Vec4, Mat4

class Billboards is Game {
  construct new() {}

  config { {
    "title":  "Billboards demo",
    "width":  1280, "height": 720,
    "depth":  true
  } }

  setup(g) {
    _renderer = Renderer3D.new(g.device, g.surfaceFormat, g.depthFormat)
    _camera   = Camera3D.perspective(60, g.width / g.height, 0.1, 100)

    // Orbit-camera state. Eye = target + (cos(pitch)*sin(yaw),
    // sin(pitch), cos(pitch)*cos(yaw)) * distance. Clamping pitch
    // shy of ±π/2 keeps the up vector well-defined.
    _yaw       = 0
    _pitch     = 0.3
    _distance  = 14
    _target    = Vec3.zero
    _lastMx    = 0
    _lastMy    = 0
    _dragging  = false
    refreshCamera_()

    _count = 64
    // Custom double-sided unit quad — Mesh.plane is a single-sided
    // XZ quad with normal +Y, and Renderer3D's instanced pipeline
    // hard-codes `cullMode: "back"`, so the half of the ring whose
    // outward axis points away from the camera gets culled. We
    // build 8 vertices (4 front with normal +Y, 4 back with normal
    // -Y) and 12 indices wound in BOTH directions so each quad
    // shows whichever side faces the camera.
    var h = 0.5
    // Mesh vertex layout: pos.xyz + normal.xyz + uv.xy + tangent.xyzw.
    // Tangent along +X for the +Y front face; -X for the -Y back
    // face (mirroring the winding). Bitangent handedness +1.
    var verts = [
      // Front face (normal +Y), CCW seen from +Y.
      -h, 0, -h,  0, 1, 0,  0, 0,   1, 0, 0, 1,
       h, 0, -h,  0, 1, 0,  1, 0,   1, 0, 0, 1,
       h, 0,  h,  0, 1, 0,  1, 1,   1, 0, 0, 1,
      -h, 0,  h,  0, 1, 0,  0, 1,   1, 0, 0, 1,
      // Back face (normal -Y), CCW seen from -Y.
      -h, 0, -h,  0, -1, 0,  0, 0, -1, 0, 0, 1,
       h, 0, -h,  0, -1, 0,  1, 0, -1, 0, 0, 1,
       h, 0,  h,  0, -1, 0,  1, 1, -1, 0, 0, 1,
      -h, 0,  h,  0, -1, 0,  0, 1, -1, 0, 0, 1
    ]
    var idx = [
      0, 1, 2, 0, 2, 3,        // front, CCW from +Y
      4, 6, 5, 4, 7, 6         // back, CCW from -Y (reversed winding)
    ]
    _quad = Mesh.fromArrays(g.device, verts, idx)
    // One Material shared by every quad — `drawMeshInstanced`
    // submits the whole instance buffer with this material
    // applied uniformly. Per-instance tint would need either
    // one buffer-per-material or a custom shader reading colour
    // from the instance slot; the existing PBR-instanced pipeline
    // doesn't expose either yet.
    _material = Material.new(Vec4.new(0.85, 0.42, 0.45, 1.0))

    // Per-instance model + normalMat (32 floats per instance, per
    // Renderer3D.drawMeshInstanced's DrawUniforms layout).
    _instance = Float32Array.new(_count * 32)
    _instBuf = g.device.createBuffer({
      "size":  _count * 32 * 4,
      "usage": ["storage", "copy-dst"]
    })
    _time = 0
  }

  // Build a model matrix whose +Y axis points along `axis` and
  // whose origin is at `pos`. Right + forward are derived from a
  // world-up cross to stay orthonormal; size scales the quad's X
  // and Z extents while leaving the normal unit-length.
  modelFor_(axis, pos, sizeX, sizeZ) {
    var worldUp = axis.y.abs > 0.99 ? Vec3.new(1, 0, 0) : Vec3.new(0, 1, 0)
    var right = cross_(worldUp, axis)
    right = normalize_(right)
    var forward = cross_(axis, right)
    forward = normalize_(forward)

    var m = Mat4.identity
    m.set(0, 0, right.x * sizeX)
    m.set(1, 0, right.y * sizeX)
    m.set(2, 0, right.z * sizeX)
    m.set(0, 1, axis.x)
    m.set(1, 1, axis.y)
    m.set(2, 1, axis.z)
    m.set(0, 2, forward.x * sizeZ)
    m.set(1, 2, forward.y * sizeZ)
    m.set(2, 2, forward.z * sizeZ)
    m.set(0, 3, pos.x)
    m.set(1, 3, pos.y)
    m.set(2, 3, pos.z)
    return m
  }

  cross_(a, b) {
    return Vec3.new(
      a.y * b.z - a.z * b.y,
      a.z * b.x - a.x * b.z,
      a.x * b.y - a.y * b.x)
  }

  normalize_(v) {
    var len = (v.x * v.x + v.y * v.y + v.z * v.z).sqrt
    if (len < 1e-6) return Vec3.new(1, 0, 0)
    return Vec3.new(v.x / len, v.y / len, v.z / len)
  }

  // Recompute the camera eye from yaw/pitch/distance + lookAt.
  refreshCamera_() {
    var cp = _pitch.cos
    var sp = _pitch.sin
    var cy = _yaw.cos
    var sy = _yaw.sin
    var ex = _target.x + _distance * cp * sy
    var ey = _target.y + _distance * sp
    var ez = _target.z + _distance * cp * cy
    _camera.lookAt(Vec3.new(ex, ey, ez), _target, Vec3.unitY)
  }

  update(g) {
    _time = _time + g.dt

    // Drag-to-orbit. Sensitivity scales mouse pixels to radians;
    // 0.005 ≈ one full revolution per 1200 px of drag.
    var mx = g.input.mouseX
    var my = g.input.mouseY
    if (g.input.mouseDown("left")) {
      if (_dragging) {
        var dx = mx - _lastMx
        var dy = my - _lastMy
        _yaw   = _yaw   - dx * 0.005
        _pitch = _pitch - dy * 0.005
        // Clamp pitch shy of straight-up / straight-down so the
        // lookAt up-vector stays unambiguous.
        if (_pitch >  1.4) _pitch =  1.4
        if (_pitch < -1.4) _pitch = -1.4
      }
      _dragging = true
    } else {
      _dragging = false
    }
    _lastMx = mx
    _lastMy = my

    // Scroll wheel zooms. Positive scrollY (wheel-up) pulls in.
    if (g.input.scrollY != 0) {
      _distance = _distance - g.input.scrollY * 0.8
      if (_distance < 2)   _distance = 2
      if (_distance > 60)  _distance = 60
    }

    refreshCamera_()

    if (g.input.justPressed("Escape")) g.requestQuit
  }

  draw(g) {
    // Re-pack each frame so the per-instance spin evolves. Each
    // quad's world axis is the radial direction out from the
    // origin (+ a small tilt for variety); the model matrix
    // composes that orientation with the ring position + a
    // non-uniform XZ scale.
    var twoPi = 6.28318530718
    var i = 0
    while (i < _count) {
      var a = (i / _count) * twoPi
      var ox = a.cos * 6
      var oz = a.sin * 6
      var pos = Vec3.new(ox, 2, oz)
      // Radial direction = the quad's own world-space normal.
      // Add a small time-varying tilt so the surfaces wobble
      // without rotating en masse.
      var axis = normalize_(Vec3.new(a.cos, (a + _time).sin * 0.3, a.sin))
      var model = modelFor_(axis, pos, 1.4, 2.2)
      Renderer3D.writeInstance(_instance, i, model)
      i = i + 1
    }
    _instBuf.writeFloats(0, _instance)

    _renderer.beginFrame(g.pass, _camera)
    _renderer.setAmbient(Vec3.new(0.6, 0.65, 0.7), 1.0)
    _renderer.addDirectional(Vec3.new(-0.4, -1, -0.3),
                             Vec3.new(1, 0.95, 0.85), 3.0)
    // Cycle the shared material's tint over time so the demo
    // stays visually interesting without per-quad material
    // overhead. One drawMeshInstanced call covers the whole ring.
    var hue = _time * 0.4 - (_time * 0.4).floor
    var r  = (hue * twoPi).sin * 0.5 + 0.5
    var gC = ((hue + 0.33) * twoPi).sin * 0.5 + 0.5
    var b  = ((hue + 0.66) * twoPi).sin * 0.5 + 0.5
    _material.albedoColor = Vec4.new(r, gC, b, 1)
    _renderer.drawMeshInstanced(_quad, _material, _instBuf, _count)
    _renderer.endFrame()
  }
}

Game.run(Billboards)
