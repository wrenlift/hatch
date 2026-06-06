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

import "@hatch:game" for Game, Foliage
import "@hatch:gpu"  for Renderer3D, Camera3D, Mesh, Material
import "@hatch:math" for Vec3, Vec4, Mat4

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

    // Per-frame lighting + wind state — set in draw() so
    // commitScene_ reads live values; configuration that doesn't
    // need to repeat per frame stays as instance fields.
    _ambient      = Vec3.new(0.32, 0.42, 0.55)
    _sunColor     = Vec3.new(1.00, 0.96, 0.85)
    _sunIntensity = 3.0
    _sunDir       = Vec3.new(-0.4, -0.8, -0.3)

    // ----- Ground plane. Soil-brown earth so the grass tufts
    // read against a warm contrast; doesn't sway (sway = 0 is
    // the default for Material).
    _ground    = Mesh.plane(g.device, 50)
    _groundMat = Material.new(Vec4.new(0.42, 0.28, 0.18, 1.0))
    _groundMat.shadingModel = "toon"
    _groundMat.bands         = 3
    _groundMat.ambientFloor  = 0.50

    // ----- Grass blade primitive + material. `sway = 1.0` opts
    // every blade into full wind response; the per-vertex factor
    // in `apply_sway` then scales the bend by local-y so the base
    // stays planted and the tip arcs.
    _blade    = Mesh.grassBlade(g.device, 0.75, 0.10, 6)
    _grassMat = Material.new(Vec4.new(0.55, 0.82, 0.30, 1.0))
    _grassMat.shadingModel = "toon"
    _grassMat.bands         = 3
    _grassMat.ambientFloor  = 0.40
    _grassMat.sway          = 1.0
    _grassMat.doubleSided   = true  // blades read from both sides

    // ----- Scatter placement. 30×30 area at spacing 0.22 +
    // jitter 0.45 → ~17k scatter points; each point gets a
    // 3-blade tuft at 0°/60°/120° yaw offsets so the field
    // fills the gap from any view angle without tripling the
    // scatter cost (the screen-space silhouette gets ~3× denser
    // for a 3× draw-count, ~1× scatter cost).
    // Dense scatter — no Perlin threshold; every grid cell emits
    // a candidate. 30×30 / 0.20 ≈ 17k tufts × 3 blades = ~50k
    // blades total, packed organically.
    var sites = Foliage.scatter({
      "bounds":  [-14, -14, 14, 14],
      "spacing": 0.20,
      "jitter":  0.50,
      "seed":    1337
    })
    var bladesPerSite = 3
    _grassCount = sites["count"] * bladesPerSite

    // ----- Pack instance transforms. Each blade gets its OWN
    // pseudo-random scale (varied height — real grass isn't
    // monoculture-flat) seeded off (x, z, b). Yaw is offset 0° /
    // 120° / 240° per blade inside a tuft so the silhouette
    // covers every view angle.
    var scratch = Float32Array.new(_grassCount * 32)
    var xs = sites["xs"]
    var zs = sites["zs"]
    var twoPiThird = 3.14159 * 2 / 3
    var slot = 0
    var i = 0
    while (i < sites["count"]) {
      var x = xs[i]
      var z = zs[i]
      var baseYaw = (x * 7.31 + z * 11.07).sin * 3.14159
      var b = 0
      while (b < bladesPerSite) {
        var yaw = baseYaw + b * twoPiThird
        // Per-blade scale variation: 0.6 .. 1.4 (50% range
        // around mesh-native height). The (x, z, b) hash spreads
        // tall and short blades evenly across the field.
        var rand = ((x * 17.3 + z * 9.7 + b * 31.1).sin * 0.5 + 0.5)
        var scale = 0.6 + rand * 0.8
        Renderer3D.writeInstanceXYZ(scratch, slot, x, 0, z, scale, yaw)
        slot = slot + 1
        b = b + 1
      }
      i = i + 1
    }

    _instanceBuffer = g.device.createBuffer({
      "size":  _grassCount * 128,
      "usage": ["storage", "copy-dst"],
      "label": "grass-instances"
    })
    _instanceBuffer.writeFloats(0, scratch)
  }

  resize(g, w, h) {
    _camera.setPerspective(55, w / h, 0.1, 200)
  }

  update(g) {
    if (g.input.justPressed("Escape")) g.requestQuit
  }

  draw(g) {
    var t = g.elapsed

    // Camera orbits at a steep down-angle so bare-soil patches
    // read between the grass clumps; ~45° down (height / radius
    // ≈ 1) keeps the field horizontal but exposes ground between
    // tufts.
    var orbit = t * 0.22
    var radius = 13
    var camX = orbit.cos * radius
    var camZ = orbit.sin * radius
    _camera.lookAt(Vec3.new(camX, 11, camZ), Vec3.new(0, 0, 0), Vec3.new(0, 1, 0))

    _renderer3d.beginFrame(g.pass, _camera)
    // Per-frame scene state — commitScene_ snapshots these values
    // on the first draw of the frame. Wind direction stays
    // constant but the time phase advances so blades sway with
    // the wind sin().
    _renderer3d.setAmbient(_ambient, 1.0)
    _renderer3d.setWind(1.0, 0.25, 0.6)
    _renderer3d.setWindTime(t)
    _renderer3d.addDirectional(_sunDir, _sunColor, _sunIntensity)

    _renderer3d.draw(_ground, _groundMat, Mat4.translation(0, 0, 0))
    _renderer3d.drawMeshInstanced(_blade, _grassMat, _instanceBuffer, _grassCount)
  }
}

Game.run(GrassField)
