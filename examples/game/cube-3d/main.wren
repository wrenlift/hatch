// Cube 3D — Renderer3D + Renderer2D HUD overlay.
//
//   wlift main.wren
//
// A directional light, a ground plane, a spinning cube, and a
// 2D health-bar HUD drawn on top of the scene. The Game.run
// config opts into a depth attachment with `"depth": true`;
// Renderer2D is built with that same depth format so its draws
// share the pass without fighting depth.

import "@hatch:game"  for Game
import "@hatch:gpu"   for Renderer3D, Renderer2D, Camera3D, Camera2D, Mesh,
                          Material, Light, Sprite
import "@hatch:math"  for Vec3, Vec4, Mat4
import "@hatch:image" for Image

class Cube3D is Game {
  construct new() {}

  config { {
    "title":      "Cube 3D",
    "width":      1024,
    "height":     720,
    "clearColor": [0.07, 0.10, 0.16, 1.0],
    "depth":      true
  } }

  setup(g) {
    var aspect = g.width / g.height
    _camera = Camera3D.perspective(60, aspect, 0.1, 100)
    _camera.lookAt(Vec3.new(3, 2.5, 5), Vec3.new(0, 0, 0), Vec3.new(0, 1, 0))

    _light = Light.new()
    _light.direction = Vec3.new(-0.4, -1.0, -0.3)
    _light.color     = Vec3.new(1.0, 0.95, 0.85)
    _light.ambient   = Vec3.new(0.18, 0.20, 0.25)

    _renderer3d = Renderer3D.new(g.device, g.surfaceFormat, g.depthFormat)

    _cube      = Mesh.cube(g.device, 0.75)
    _ground    = Mesh.plane(g.device, 8)
    _cubeMat   = Material.new(Vec4.new(0.85, 0.42, 0.45, 1.0))
    _groundMat = Material.new(Vec4.new(0.30, 0.55, 0.40, 1.0))

    // Renderer2D depth-aware variant — same depth format as the
    // pass, with depthCompare = always. Lets the HUD render after
    // the scene without writing to or being clipped by depth.
    _renderer2d = Renderer2D.new(g.device, g.surfaceFormat, g.depthFormat)
    _camera2d   = Camera2D.new(g.width, g.height)

    var pixels = [255, 255, 255, 255]
    _white = g.device.uploadImage(Image.new(1, 1, pixels))
    _hudBg = Sprite.new(_white)
    _hudBg.width  = 220
    _hudBg.height = 18
    _hudBg.x = 20
    _hudBg.y = 20
    _hudBg.tint = [0.05, 0.05, 0.08, 0.7]

    _hudFill = Sprite.new(_white)
    _hudFill.height = 14
    _hudFill.x = 22
    _hudFill.y = 22
    _hudFill.tint = [0.95, 0.65, 0.30, 1.0]
  }

  resize(g, w, h) {
    _camera.setPerspective(60, w / h, 0.1, 100)
    _camera2d = Camera2D.new(w, h)
  }

  update(g) {
    if (g.input.justPressed("Escape")) g.requestQuit
  }

  draw(g) {
    var t = g.elapsed

    _renderer3d.beginFrame(g.pass, _camera, _light)

    var groundXf = Mat4.translation(0, -0.75, 0)
    _renderer3d.draw(_ground, _groundMat, groundXf)

    var spin = Mat4.rotationY(t)
    var bob  = Mat4.translation(0, 0.15 * (t * 1.5).sin, 0)
    _renderer3d.draw(_cube, _cubeMat, bob * spin)

    // HUD pass — the renderer reuses g.pass; the depth-aware
    // pipeline keeps the HUD on top regardless of cube depth.
    _renderer2d.beginFrame(_camera2d)
    _hudBg.draw(_renderer2d)
    var pulse = 0.5 + 0.5 * (t * 2).sin
    _hudFill.width = 4 + 212 * pulse
    _hudFill.draw(_renderer2d)
    _renderer2d.flush(g.pass)
  }
}

Game.run(Cube3D)
