// Grass Field — cel-shaded blades + wind sway VS + Foliage scatter.
//
//   wlift main.wren
//
// 5,000 toon-shaded grass blades render through ONE drawMeshInstanced
// against a green ground plane. Each blade gets its own
// (x, z, yaw, scale) packed via `Renderer3D.writeInstanceXYZ` — the
// foliage fast path that skips the Mat4 construct cycle. Wind
// sway is the vertex stage's `apply_sway` term, driven by
// `Renderer3D.setWind` + `setWindTime`; the camera orbits so you
// can read the wind direction as the field bends and recovers.

import "@hatch:game"  for Game, Foliage
import "@hatch:gpu"   for Renderer3D, Camera3D, Mesh, Material
import "@hatch:math"  for Vec3, Vec4, Mat4

class GrassField is Game {
  construct new() {}

  config { {
    "title":      "Grass Field — Cel-Shaded",
    "width":      1280,
    "height":     720,
    "clearColor": [0.86, 0.92, 1.00, 1.0],
    "depth":      true
  } }

  setup(g) {
    var aspect = g.width / g.height
    _camera = Camera3D.perspective(55, aspect, 0.1, 200)

    _renderer3d = Renderer3D.new(g.device, g.surfaceFormat, g.depthFormat)
    _renderer3d.setAmbient(Vec3.new(0.32, 0.42, 0.55), 1.0)

    // Wind blowing mostly along +X with a touch of +Z lift.
    // Strength 0.6 = clearly readable curl without going stormy;
    // bump to ~1.5 for a wind-storm look.
    _renderer3d.setWind(1.0, 0.25, 0.6)

    _sunColor     = Vec3.new(1.00, 0.96, 0.85)
    _sunIntensity = 3.0
    _sunDir       = Vec3.new(-0.4, -0.8, -0.3)

    // ----- Ground plane. PBR-coloured low-poly grass tint;
    // doesn't sway (sway = 0 is the default for Material).
    _ground    = Mesh.plane(g.device, 50)
    _groundMat = Material.new(Vec4.new(0.38, 0.58, 0.32, 1.0))
    _groundMat.shadingModel = "toon"
    _groundMat.bands         = 3
    _groundMat.ambientFloor  = 0.50

    // ----- Grass blade primitive + material. `sway = 1.0` opts
    // every blade into full wind response; the per-vertex factor
    // in `apply_sway` then scales the bend by local-y so the base
    // stays planted and the tip arcs.
    _blade    = Mesh.grassBlade(g.device, 0.75, 0.07, 6)
    _grassMat = Material.new(Vec4.new(0.55, 0.82, 0.30, 1.0))
    _grassMat.shadingModel = "toon"
    _grassMat.bands         = 3
    _grassMat.ambientFloor  = 0.40
    _grassMat.sway          = 1.0
    _grassMat.doubleSided   = true  // blades read from both sides

    // ----- Scatter placement. Bounds 30×30, spacing 0.42 →
    // ~5,000 blades. Adjust spacing down for a denser field;
    // CPU pack stays fast because `writeInstanceXYZ` is
    // allocator-free.
    var sites = Foliage.scatter({
      "bounds":  [-15, -15, 15, 15],
      "spacing": 0.42,
      "jitter":  0.45,
      "seed":    1337
    })
    _grassCount = sites["count"]

    // ----- Pack instance transforms. `Float32Array.new(count * 32)`
    // is the storage-buffer layout the instanced shader expects
    // (16 floats model + 16 floats normal_mat per instance).
    // Per-blade yaw + scale are seeded deterministically off the
    // (x, z) so re-running the demo looks identical.
    var scratch = Float32Array.new(_grassCount * 32)
    var xs = sites["xs"]
    var zs = sites["zs"]
    var i = 0
    while (i < _grassCount) {
      var x = xs[i]
      var z = zs[i]
      var yaw   = (x * 7.31 + z * 11.07).sin * 3.14159
      var scale = 0.7 + ((x * 13.7 + z * 5.3).sin * 0.5 + 0.5) * 0.55
      Renderer3D.writeInstanceXYZ(scratch, i, x, 0, z, scale, yaw)
      i = i + 1
    }

    _instanceBuffer = g.device.createBuffer({
      "size":  _grassCount * 128,
      "usage": ["storage", "copy-dst"],
      "label": "grass-instances"
    })
    _instanceBuffer.writeFloats(0, scratch)

    System.print("grass-field: %(_grassCount) blades scattered")
  }

  resize(g, w, h) {
    _camera.setPerspective(55, w / h, 0.1, 200)
  }

  update(g) {
    if (g.input.justPressed("Escape")) g.requestQuit
  }

  draw(g) {
    var t = g.elapsed

    // Camera orbits slowly so the wind direction reads as the
    // field bends past the viewer.
    var orbit = t * 0.22
    var radius = 18
    var camX = orbit.cos * radius
    var camZ = orbit.sin * radius
    _camera.lookAt(Vec3.new(camX, 5.2, camZ), Vec3.new(0, 1, 0), Vec3.new(0, 1, 0))

    // Advance wind phase. The VS samples `sin(anchor_world.x *
    // 0.45 + anchor_world.z * 0.37 + wind.z * 2.6)` so blades at
    // different world positions sway out-of-phase even though
    // they share the same time value.
    _renderer3d.setWindTime(t)

    _renderer3d.beginFrame(g.pass, _camera)
    _renderer3d.addDirectional(_sunDir, _sunColor, _sunIntensity)

    _renderer3d.draw(_ground, _groundMat, Mat4.translation(0, 0, 0))
    _renderer3d.drawMeshInstanced(_blade, _grassMat, _instanceBuffer, _grassCount)
  }
}

Game.run(GrassField)
