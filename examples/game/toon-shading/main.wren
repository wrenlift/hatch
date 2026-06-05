// Toon Shading — cel-shaded materials on @hatch:gpu's Renderer3D.
//
//   wlift main.wren
//
// Three spheres demonstrating the toon dials:
//
//   left   — 2 bands, no rim                (hard cel cut)
//   middle — 3 bands, no rim                (canonical Ghibli)
//   right  — 4 bands, strong fresnel rim    (anime hero light)
//
// A PBR ground plane runs behind them so the difference between
// the cel-quantised lighting and the smooth PBR term reads at a
// glance. One directional sun + a light ambient term feeds both
// pipelines; the toon path adds an `ambientFloor` so the shadow
// side never crushes to black (Ghibli's signature).

import "@hatch:game"  for Game
import "@hatch:gpu"   for Renderer3D, Camera3D, Mesh, Material
import "@hatch:math"  for Vec3, Vec4, Mat4

class ToonShading is Game {
  construct new() {}

  config { {
    "title":      "Toon Shading",
    "width":      1280,
    "height":     720,
    "clearColor": [0.86, 0.92, 1.00, 1.0],
    "depth":      true
  } }

  setup(g) {
    var aspect = g.width / g.height
    _camera = Camera3D.perspective(45, aspect, 0.1, 100)
    _camera.lookAt(Vec3.new(0, 1.8, 7.5), Vec3.new(0, 0.6, 0), Vec3.new(0, 1, 0))

    _sunDir       = Vec3.new(-0.3, -0.8, -0.5)
    _sunColor     = Vec3.new(1.00, 0.96, 0.88)
    _sunIntensity = 3.5
    _ambient      = Vec3.new(0.30, 0.35, 0.45)

    _renderer3d = Renderer3D.new(g.device, g.surfaceFormat, g.depthFormat)
    _sphere     = Mesh.sphere(g.device, 0.8, 32)
    _ground     = Mesh.plane(g.device, 20)

    // PBR reference (the ground stays photorealistic for contrast).
    _groundMat = Material.new(Vec4.new(0.42, 0.62, 0.38, 1.0))
    _groundMat.roughnessFactor = 0.9

    // 2-band hard cel — minimum reading of "toon".
    _hardCel = Material.new(Vec4.new(0.92, 0.45, 0.40, 1.0))
    _hardCel.shadingModel = "toon"
    _hardCel.bands        = 2
    _hardCel.rimStrength  = 0.0
    _hardCel.ambientFloor = 0.40

    // 3-band Ghibli-default cel.
    _ghibli = Material.new(Vec4.new(0.55, 0.78, 0.92, 1.0))
    _ghibli.shadingModel = "toon"
    _ghibli.bands        = 3
    _ghibli.rimStrength  = 0.0
    _ghibli.ambientFloor = 0.45

    // 4-band hero-light with rim — anime / action key shot.
    _heroRim = Material.new(Vec4.new(0.96, 0.84, 0.42, 1.0))
    _heroRim.shadingModel = "toon"
    _heroRim.bands        = 4
    _heroRim.rimStrength  = 0.85
    _heroRim.rimWidth     = 3.5
    _heroRim.ambientFloor = 0.30
  }

  resize(g, w, h) {
    _camera.setPerspective(45, w / h, 0.1, 100)
  }

  update(g) {
    if (g.input.justPressed("Escape")) g.requestQuit
  }

  draw(g) {
    var t = g.elapsed
    _renderer3d.beginFrame(g.pass, _camera)
    _renderer3d.setAmbient(_ambient, 1.0)
    _renderer3d.addDirectional(_sunDir, _sunColor, _sunIntensity)

    var groundXf = Mat4.translation(0, -0.2, 0)
    _renderer3d.draw(_ground, _groundMat, groundXf)

    var spin = Mat4.rotationY(t * 0.7)
    _renderer3d.draw(_sphere, _hardCel, Mat4.translation(-2.4, 0.6, 0) * spin)
    _renderer3d.draw(_sphere, _ghibli,  Mat4.translation( 0.0, 0.6, 0) * spin)
    _renderer3d.draw(_sphere, _heroRim, Mat4.translation( 2.4, 0.6, 0) * spin)
  }
}

Game.run(ToonShading)
