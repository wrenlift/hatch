// billboards — 64 camera-facing billboards arranged in a horizontal
// circle around the origin, drawn in one drawBillboardN call.
// Cycles their hue over time. The single Game class shows the
// minimum surface a 3D-particle / decal / damage-number system
// needs: pack the per-instance state into a Float32Array,
// writeFloats into a storage buffer, dispatch one draw.

import "@hatch:game" for Game
import "@hatch:gpu"  for Renderer3D, Camera3D
import "@hatch:math" for Vec3

class Billboards is Game {
  construct new() {}

  config { {
    "title":  "Billboards demo",
    "width":  1280, "height": 720
  } }

  setup(g) {
    _renderer = Renderer3D.new(g.device, g.surfaceFormat, "depth32float")
    _camera   = Camera3D.perspective(60, g.width / g.height, 0.1, 100)
    _camera.lookAt(Vec3.new(0, 4, 14), Vec3.zero, Vec3.unitY)

    // 1×1 white sprite — keeps the example dep-free. Real callers
    // upload a particle / decal texture instead.
    _tex = g.device.createTexture({
      "width": 1, "height": 1, "format": "rgba8unorm",
      "usage": ["texture-binding", "copy-dst"]
    })
    g.device.writeTexture(_tex, ByteArray.fromList([255, 255, 255, 255]),
                          {"width": 1, "height": 1, "bytesPerRow": 4})

    _count = 64
    _state = Float32Array.new(_count * Renderer3D.FLOATS_PER_BILLBOARD_)
    _buf = g.device.createBuffer({
      "size":  _count * Renderer3D.FLOATS_PER_BILLBOARD_ * 4,
      "usage": ["storage", "copy-dst"]
    })
    _time = 0
  }

  update(g) { _time = _time + g.dt }

  draw(g) {
    // Re-pack the ring each frame so colour and rotation evolve.
    var twoPi = 6.28318530718
    var i = 0
    while (i < _count) {
      var a = (i / _count) * twoPi
      var ox = a.cos * 6
      var oz = a.sin * 6
      var hue = (a + _time * 1.5) / twoPi - ((a + _time * 1.5) / twoPi).floor
      var r = (hue * 6.28).sin * 0.5 + 0.5
      var gC = ((hue + 0.33) * 6.28).sin * 0.5 + 0.5
      var b = ((hue + 0.66) * 6.28).sin * 0.5 + 0.5
      Renderer3D.writeBillboardInstance(_state, i,
        ox, 2, oz,    // origin
        0.8, 1.6,     // size
        0, 0, 1, 1,   // uv rect
        r, gC, b, 1,  // rgba
        a + _time,    // rotation
        0)            // lodIndex
      i = i + 1
    }
    _buf.writeFloats(0, _state)

    _renderer.beginFrame(g.pass, _camera)
    _renderer.drawBillboardN(_tex, _buf, _count)
    _renderer.endFrame()
  }
}

Game.run(Billboards)
