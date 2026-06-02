// storm-100k — 100,000-particle rain storm via `Weather.rain` in
// GPU mode (compute-shader integration). CPU only seeds spawn
// slots at the emission rate; per-frame motion + colour + size
// run entirely on the GPU.
//
// Mouse drag orbits; scroll zooms; Escape quits.

import "@hatch:game" for Game, Weather, Particles
import "@hatch:gpu"  for Renderer3D, Camera3D, Mesh, Material
import "@hatch:math" for Vec3, Vec4, Mat4

class Storm is Game {
  construct new() {}

  config { {
    "title":      "Storm — 100k GPU particles",
    "width":      1280,
    "height":     720,
    "clearColor": [0.13, 0.16, 0.22, 1.0],
    "depth":      true
  } }

  setup(g) {
    _renderer = Renderer3D.new(g.device, g.surfaceFormat, g.depthFormat)
    _camera   = Camera3D.perspective(60, g.width / g.height, 0.1, 400)

    _yaw      = 0.4
    _pitch    = 0.25
    _distance = 60
    _target   = Vec3.new(0, 5, 0)
    _lastMx   = 0
    _lastMy   = 0
    _dragging = false
    refreshCamera_()

    // Ground plane so the storm has a backdrop. 200×200m.
    _ground    = Mesh.plane(g.device, 200)
    _groundMat = Material.new(Vec4.new(0.18, 0.22, 0.18, 1.0))
    _groundModel = Mat4.identity

    // 1×1 white rain texture — thin streaks read as pale slashes
    // against the dark sky without needing an authored asset.
    _rainTex = g.device.createTexture({
      "width": 1, "height": 1, "format": "rgba8unorm",
      "usage": ["texture-binding", "copy-dst"]
    })
    g.device.writeTexture(_rainTex, ByteArray.fromList([255, 255, 255, 255]),
                          {"width": 1, "height": 1, "bytesPerRow": 4})

    // GPU rain. 100k capacity at 40k/s emission × ~2.5s avg
    // lifetime ≈ 100k live drops in steady state.
    _rain = Weather.rain(g.device, {
      "gpu":       true,
      "texture":   _rainTex,
      "capacity":  100000,
      "intensity": 40000,
      "area":      [60, 60],
      "fallSpeed": 16,
      "length":    2.4,
      "width":     0.025,
      "lifetime":  [2.0, 3.0],
      "color":     [0.82, 0.88, 0.98, 0.4]
    })
    Particles.register(_rain)
    _rainOn = true
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
      _distance = _distance - g.input.scrollY * 2
      if (_distance < 10)  _distance = 10
      if (_distance > 200) _distance = 200
    }
    refreshCamera_()

    if (g.input.justPressed("Space")) {
      _rainOn = !_rainOn
      _rain.isPlaying = _rainOn
    }
    if (g.input.justPressed("Escape")) g.requestQuit

    // Rain spawn column tracks the camera target so the storm is
    // always overhead. The CPU side only writes a few hundred
    // spawn slots per frame — no per-particle iteration.
    _rain.setPosition(_target.x, _target.y + 25, _target.z)
  }

  draw(g) {
    _renderer.beginFrame(g.pass, _camera)
    _renderer.setAmbient(Vec3.new(0.4, 0.45, 0.55), 1.1)
    _renderer.addDirectional(Vec3.new(-0.4, -1, -0.3),
                             Vec3.new(0.95, 0.95, 1.0), 1.8)
    _renderer.draw(_ground, _groundMat, _groundModel)
    // Compute integration before the billboard draw reads the
    // storage buffer. One workgroup dispatch covers all 100k.
    _rain.compute(g.encoder)
    _rain.draw(_renderer)
    _renderer.endFrame()
  }
}

Game.run(Storm)
