// weather-demo — minimal Game.run showcase for Weather.rain. A
// single spinning cube acts as the focal point; the rain column
// tracks the camera so wherever the player stands, there's
// weather above them.
//
// Weather.fog returns a Fog instance configured for aerial
// perspective; it's consumed by `WaterPipeline.setFog` today.
// Wiring it into `Renderer3D`'s standard pass is a follow-up; in
// the meantime the clear-colour stands in for the horizon tint.
//
// Mouse drag orbits the camera; scroll zooms; Escape quits.

import "@hatch:game" for Game, Weather, Particles
import "@hatch:gpu"  for Renderer3D, Camera3D, Mesh, Material
import "@hatch:math" for Vec3, Vec4, Mat4

class WeatherDemo is Game {
  construct new() {}

  config { {
    "title":      "Weather demo — rain + fog",
    "width":      1280,
    "height":     720,
    "clearColor": [0.62, 0.74, 0.88, 1.0],
    "depth":      true
  } }

  setup(g) {
    _renderer = Renderer3D.new(g.device, g.surfaceFormat, g.depthFormat)
    _camera   = Camera3D.perspective(60, g.width / g.height, 0.1, 200)

    // Orbit-camera state. Mouse drag updates yaw/pitch; scroll
    // updates distance; refreshCamera_ recomputes eye + lookAt.
    _yaw      = 0
    _pitch    = 0.4
    _distance = 25
    _target   = Vec3.new(0, 1, 0)
    _lastMx   = 0
    _lastMy   = 0
    _dragging = false
    refreshCamera_()

    _cube     = Mesh.cube(g.device, 2.0)
    _material = Material.new(Vec4.new(0.7, 0.45, 0.25, 1.0))

    // Reuse a 1×1 white pixel as the rain sprite to keep the
    // example dep-free. A real game would load a streak PNG.
    _rainTex = g.device.createTexture({
      "width": 1, "height": 1, "format": "rgba8unorm",
      "usage": ["texture-binding", "copy-dst"]
    })
    g.device.writeTexture(_rainTex, ByteArray.fromList([255, 255, 255, 255]),
                          {"width": 1, "height": 1, "bytesPerRow": 4})

    _rain = Weather.rain(g.device, {
      "texture":   _rainTex,
      "capacity":  600,
      "intensity": 300,
      "area":      [25, 25]
    })
    Particles.register(_rain)

    _fog = Weather.fog({"density": 0.04, "color": [0.62, 0.74, 0.88]})
    _time = 0
  }

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

    var mx = g.input.mouseX
    var my = g.input.mouseY
    if (g.input.mouseDown("left")) {
      if (_dragging) {
        _yaw   = _yaw   - (mx - _lastMx) * 0.005
        _pitch = _pitch - (my - _lastMy) * 0.005
        if (_pitch >  1.4) _pitch =  1.4
        if (_pitch < -1.4) _pitch = -1.4
      }
      _dragging = true
    } else {
      _dragging = false
    }
    _lastMx = mx
    _lastMy = my

    if (g.input.scrollY != 0) {
      _distance = _distance - g.input.scrollY * 1.5
      if (_distance < 4)   _distance = 4
      if (_distance > 100) _distance = 100
    }
    refreshCamera_()

    if (g.input.justPressed("Escape")) g.requestQuit

    // Rain falls on the scene centre (the orbit target), not the
    // camera — keeps the falling streaks visible in the camera's
    // field of view from any orbit angle.
    _rain.setPosition(_target.x, _target.y + 15, _target.z)
  }

  draw(g) {
    _renderer.beginFrame(g.pass, _camera)
    _renderer.setAmbient(Vec3.new(0.55, 0.62, 0.72), 0.9)
    _renderer.addDirectional(Vec3.new(-0.4, -1, -0.3),
                             Vec3.new(1, 0.95, 0.9), 2.5)
    var model = Mat4.rotationY(_time * 0.8)
    _renderer.draw(_cube, _material, model)
    _rain.draw(_renderer)
    _renderer.endFrame()
  }
}

Game.run(WeatherDemo)
