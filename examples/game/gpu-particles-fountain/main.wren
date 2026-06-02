// gpu-particles-fountain — 50k particles integrated entirely on
// the GPU via `GpuParticleSystem3D`. CPU only seeds new particles
// into the storage buffer at the emission rate; the per-frame
// integrate / colour / size work runs in a compute shader.
//
// Mouse drag orbits; scroll zooms; Escape quits.

import "@hatch:game" for Game, GpuParticleSystem3D, Particles
import "@hatch:gpu"  for Renderer3D, Camera3D
import "@hatch:math" for Vec3

class Fountain is Game {
  construct new() {}

  config { {
    "title":      "GPU particle fountain — 50k",
    "width":      1280,
    "height":     720,
    "clearColor": [0.10, 0.12, 0.18, 1.0],
    "depth":      true
  } }

  setup(g) {
    _renderer = Renderer3D.new(g.device, g.surfaceFormat, g.depthFormat)
    _camera   = Camera3D.perspective(60, g.width / g.height, 0.1, 200)

    _yaw      = 0.0
    _pitch    = 0.25
    _distance = 22
    _target   = Vec3.new(0, 4, 0)
    _lastMx   = 0
    _lastMy   = 0
    _dragging = false
    refreshCamera_()

    // 1×1 white texture so the demo is asset-free.
    _tex = g.device.createTexture({
      "width": 1, "height": 1, "format": "rgba8unorm",
      "usage": ["texture-binding", "copy-dst"]
    })
    g.device.writeTexture(_tex, ByteArray.fromList([255, 255, 255, 255]),
                          {"width": 1, "height": 1, "bytesPerRow": 4})

    // Fountain: 50k particles, emitting 30k/s with a wide arc,
    // gravity pulls them back down. Drag dampens velocity so the
    // arc settles instead of streaking out forever.
    _fx = GpuParticleSystem3D.new(g.device, {
      "texture":      _tex,
      "capacity":     50000,
      "emissionRate": 30000,
      "lifetime":     [1.6, 2.4],
      "position":     [0, 0, 0],
      "spread":       [0.4, 0, 0.4],
      "velocity":     [[-2.5, 8, -2.5], [2.5, 12, 2.5]],
      "gravity":      [0, -9.8, 0],
      "drag":         0.15,
      "size":         [0.06, 0.06],
      "color":        [[1.0, 0.95, 0.85, 1.0], [0.20, 0.55, 1.0, 0.0]]
    })
    Particles.register(_fx)
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
      _distance = _distance - g.input.scrollY * 1.2
      if (_distance < 5)  _distance = 5
      if (_distance > 80) _distance = 80
    }
    refreshCamera_()
    if (g.input.justPressed("Escape")) g.requestQuit
  }

  draw(g) {
    _renderer.beginFrame(g.pass, _camera)
    _renderer.setAmbient(Vec3.new(0.6, 0.65, 0.7), 1.0)
    _renderer.addDirectional(Vec3.new(-0.3, -1, -0.2),
                             Vec3.new(1, 0.95, 0.85), 2.5)
    // Compute first, then draw. The integrator writes the render
    // buffer in-place, so the upcoming drawBillboardN reads fresh
    // post-integration state.
    _fx.compute(g.encoder)
    _fx.draw(_renderer)
    _renderer.endFrame()
  }
}

Game.run(Fountain)
