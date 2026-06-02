// instanced-sprites — 256 spinning sprites arranged in a 16×16
// grid, drawn through Renderer2D.drawInstancedSprites in one
// dispatch. The instance buffer is uploaded once at setup +
// re-written each frame so rotation animates.

import "@hatch:game" for Game
import "@hatch:gpu"  for Renderer2D, Camera2D

class InstancedSprites is Game {
  construct new() {}

  config { {
    "title":      "Instanced sprites",
    "width":      1280,
    "height":     720,
    "clearColor": [0.05, 0.05, 0.08, 1.0]
  } }

  setup(g) {
    _renderer = Renderer2D.new(g.device, g.surfaceFormat)
    _camera   = Camera2D.new(g.width, g.height)

    // 1×1 white texture, tinted per-instance via the rgba slot.
    _tex = g.device.createTexture({
      "width": 1, "height": 1, "format": "rgba8unorm",
      "usage": ["texture-binding", "copy-dst"]
    })
    g.device.writeTexture(_tex, ByteArray.fromList([255, 255, 255, 255]),
                          {"width": 1, "height": 1, "bytesPerRow": 4})

    _count = 256
    _state = Float32Array.new(_count * Renderer2D.FLOATS_PER_INSTANCE_)
    _buf = g.device.createBuffer({
      "size":  _count * Renderer2D.FLOATS_PER_INSTANCE_ * 4,
      "usage": ["storage", "copy-dst"]
    })
    _t = 0
  }

  update(g) { _t = _t + g.dt }

  draw(g) {
    _renderer.beginFrame(_camera)
    // Re-pack the grid each frame so the per-instance rotation
    // is visible.
    var k = 0
    while (k < _count) {
      var ix = k % 16
      var iy = (k / 16).floor
      var cx = 100 + ix * 70
      var cy = 60  + iy * 40
      var hue = (k / _count + _t * 0.4)
      var r = (hue * 6.28).sin * 0.5 + 0.5
      var g_ = ((hue + 0.33) * 6.28).sin * 0.5 + 0.5
      var b = ((hue + 0.66) * 6.28).sin * 0.5 + 0.5
      Renderer2D.writeSpriteInstance(_state, k,
        cx, cy,
        20, 30,
        0, 0, 1, 1,
        r, g_, b, 1,
        _t + k * 0.05)
      k = k + 1
    }
    _buf.writeFloats(0, _state)
    _renderer.beginPass(g.pass)
    _renderer.drawInstancedSprites(g.pass, _tex, _buf, _count)
    _renderer.endPass()
  }
}

Game.run(InstancedSprites)
