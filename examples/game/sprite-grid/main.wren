// Sprite Grid — Renderer2D batching + input polling.
//
//   wlift main.wren
//
// Draws a grid of tinted sprites that rainbow over time. WASD
// nudges the grid offset; Escape quits. All sprites flush in a
// single draw call because they share the same texture.

import "@hatch:game"  for Game
import "@hatch:gpu"   for Renderer2D, Camera2D, Sprite
import "@hatch:image" for Image

class SpriteGrid is Game {
  construct new() {}

  config { {
    "title":      "Sprite Grid",
    "width":      960,
    "height":     720,
    "clearColor": [0.04, 0.05, 0.08, 1.0]
  } }

  setup(g) {
    _renderer = Renderer2D.new(g.device, g.surfaceFormat)
    // Aspect-fit contain: the 960x720 design rectangle stays
    // intact at any window size, with the clear colour painting
    // the letterbox / pillarbox bars.
    _camera   = Camera2D.contain(960, 720, g.width, g.height)

    // 8x8 white tile — bigger than 1×1 so anchor / scale show off
    // the full unit-quad path.
    var w = 8
    var h = 8
    var pixels = []
    var i = 0
    while (i < w * h) {
      pixels.add(255)
      pixels.add(255)
      pixels.add(255)
      pixels.add(255)
      i = i + 1
    }
    _texture = g.device.uploadImage(Image.new(w, h, pixels))

    _cols = 24
    _rows = 18
    _cell = 36
    _offsetX = 0
    _offsetY = 0

    // Pre-build sprites once. We mutate position + tint each
    // frame; Renderer2D batches them into one draw call.
    _sprites = []
    var r = 0
    while (r < _rows) {
      var c = 0
      while (c < _cols) {
        var s = Sprite.new(_texture)
        s.width  = _cell - 4
        s.height = _cell - 4
        s.anchor(0.5, 0.5)
        _sprites.add(s)
        c = c + 1
      }
      r = r + 1
    }
  }

  resize(g, w, h) {
    _camera.fitContain(w, h)
  }

  update(g) {
    if (g.input.justPressed("Escape")) g.requestQuit
    var speed = 200 * g.dt
    if (g.input.isDown("KeyA") || g.input.isDown("ArrowLeft"))  _offsetX = _offsetX - speed
    if (g.input.isDown("KeyD") || g.input.isDown("ArrowRight")) _offsetX = _offsetX + speed
    if (g.input.isDown("KeyW") || g.input.isDown("ArrowUp"))    _offsetY = _offsetY - speed
    if (g.input.isDown("KeyS") || g.input.isDown("ArrowDown"))  _offsetY = _offsetY + speed
  }

  draw(g) {
    _renderer.beginFrame(_camera)

    var t = g.elapsed
    // Centre the grid in the *design* rectangle, not the surface
    // — `g.width` / `g.height` track the live window; the camera
    // is in contain mode so the grid drifts off-centre under a
    // resize unless we anchor to the design size instead.
    var originX = (_camera.width  - _cols * _cell) / 2 + _offsetX
    var originY = (_camera.height - _rows * _cell) / 2 + _offsetY

    var idx = 0
    var r = 0
    while (r < _rows) {
      var c = 0
      while (c < _cols) {
        var s = _sprites[idx]
        s.x = originX + c * _cell + _cell / 2
        s.y = originY + r * _cell + _cell / 2
        // Smooth gradient that ripples diagonally. `setTint` skips
        // the 4-element list allocation that `s.tint = [...]`
        // would do — at 432 sprites × 60 fps that's ~25k fewer
        // allocations per second.
        var phase = (c + r) * 0.25 + t * 1.5
        s.setTint(
          0.5 + 0.5 * phase.sin,
          0.5 + 0.5 * (phase + 2.094).sin,
          0.5 + 0.5 * (phase + 4.188).sin,
          1.0
        )
        s.draw(_renderer)
        idx = idx + 1
        c = c + 1
      }
      r = r + 1
    }

    _renderer.flush(g.pass)
  }
}

Game.run(SpriteGrid)
