// ECS Asteroids — @hatch:ecs + @hatch:game.
//
//   wlift main.wren
//
// 200 entities drift across the screen and wrap around the
// edges. Two systems (`stepMotion` over [Position, Velocity];
// `wrapBounds` over [Position]) plus one render pass over
// [Position, SpriteRef] — exactly the loop pattern @hatch:ecs
// is designed for.
//
// Each frame:
//   - update(): motion, then wrap
//   - draw():   one query over (Position, SpriteRef), one batched flush

import "@hatch:game"  for Game
import "@hatch:gpu"   for Renderer2D, Camera2D, Sprite
import "@hatch:ecs"   for World
import "@hatch:image" for Image

// -- Components --------------------------------------------------

class Position {
  construct new(x, y) {
    _x = x
    _y = y
  }
  x       { _x }
  x=(v)   { _x = v }
  y       { _y }
  y=(v)   { _y = v }
}

class Velocity {
  construct new(x, y) {
    _x = x
    _y = y
  }
  x       { _x }
  y       { _y }
}

// SpriteRef is just a tag carrying the per-entity Sprite. We
// keep the component pool dense by storing the Sprite directly;
// the renderer mutates its position in the draw system.
class SpriteRef {
  construct new(sprite) { _sprite = sprite }
  sprite { _sprite }
}

class Asteroids is Game {
  construct new() {}

  config { {
    "title":      "ECS Asteroids",
    "width":      960,
    "height":     720,
    "clearColor": [0.02, 0.02, 0.05, 1.0]
  } }

  setup(g) {
    _renderer = Renderer2D.new(g.device, g.surfaceFormat)
    _camera   = Camera2D.new(g.width, g.height)
    _world    = World.new()
    _width    = g.width
    _height   = g.height

    var pixels = [255, 255, 255, 255]
    _texture = g.device.uploadImage(Image.new(1, 1, pixels))

    var rng = Rng.new(1234)
    var n = 200
    var i = 0
    while (i < n) {
      var e = _world.spawn()
      _world.attach(e, Position.new(rng.range(0, _width), rng.range(0, _height)))
      _world.attach(e, Velocity.new(rng.range(-60, 60), rng.range(-60, 60)))

      var size = rng.range(4, 14)
      var s = Sprite.new(_texture)
      s.width  = size
      s.height = size
      s.anchor(0.5, 0.5)
      s.tint = [
        0.6 + 0.4 * rng.next,
        0.6 + 0.4 * rng.next,
        0.7 + 0.3 * rng.next,
        1.0
      ]
      _world.attach(e, SpriteRef.new(s))
      i = i + 1
    }
  }

  resize(g, w, h) {
    _camera = Camera2D.new(w, h)
    _width  = w
    _height = h
  }

  update(g) {
    if (g.input.justPressed("Escape")) g.requestQuit
    stepMotion_(g.dt)
    wrapBounds_()
  }

  draw(g) {
    _renderer.beginFrame(_camera)
    var renderer = _renderer  // closures capture locals, not fields
    _world.each([Position, SpriteRef]) {|w, e|
      var p = w.get(e, Position)
      var s = w.get(e, SpriteRef).sprite
      s.x = p.x
      s.y = p.y
      s.draw(renderer)
    }
    _renderer.flush(g.pass)
  }

  stepMotion_(dt) {
    _world.each([Position, Velocity]) {|w, e|
      var p = w.get(e, Position)
      var v = w.get(e, Velocity)
      p.x = p.x + v.x * dt
      p.y = p.y + v.y * dt
    }
  }

  wrapBounds_() {
    var width  = _width
    var height = _height
    _world.each([Position]) {|w, e|
      var p = w.get(e, Position)
      if (p.x < 0)       p.x = p.x + width
      if (p.x > width)   p.x = p.x - width
      if (p.y < 0)       p.y = p.y + height
      if (p.y > height)  p.y = p.y - height
    }
  }
}

// Tiny LCG RNG so the demo is deterministic and stdlib-free.
class Rng {
  construct new(seed) { _state = seed }
  next {
    _state = (_state * 1103515245 + 12345) % 2147483647
    return _state / 2147483647
  }
  range(lo, hi) { lo + (hi - lo) * next }
}

Game.run(Asteroids)
