// Bouncing Ball — @hatch:game + @hatch:physics demo.
//
//   wlift main.wren
//
// Click anywhere to drop a new ball at the cursor; it falls under
// gravity, bounces off the static ground, and is drawn as a
// tinted sprite. State lives in fields on `BouncingBall`; no
// closures, no scratchpad maps.

import "@hatch:game"    for Game
import "@hatch:gpu"     for Renderer2D, Camera2D, Sprite
import "@hatch:image"   for Image
import "@hatch:physics" for World2D, Collider2D

// One pixel of solid white — uploaded once, tinted per-sprite to
// produce coloured balls without shipping any image assets.
class WhitePixel {
  static texture(device) {
    var pixels = [255, 255, 255, 255]
    var img = Image.new(1, 1, pixels)
    return device.uploadImage(img)
  }
}

class Ball {
  construct new(body, sprite) {
    _body   = body
    _sprite = sprite
  }
  body   { _body }
  sprite { _sprite }
}

class BouncingBall is Game {
  construct new() {}

  config { {
    "title":      "Bouncing Ball",
    "width":      800,
    "height":     600,
    "clearColor": [0.05, 0.06, 0.10, 1.0]
  } }

  setup(g) {
    _renderer = Renderer2D.new(g.device, g.surfaceFormat)
    _camera   = Camera2D.new(g.width, g.height)
    _texture  = WhitePixel.texture(g.device)
    _balls    = []
    _palette  = [
      [0.95, 0.40, 0.45, 1.0],
      [0.40, 0.85, 0.60, 1.0],
      [0.40, 0.60, 0.95, 1.0],
      [0.95, 0.85, 0.40, 1.0],
      [0.80, 0.55, 0.95, 1.0]
    ]
    _colorIdx = 0

    // Pixels-per-metre. Physics works in metres; we render in
    // pixels and scale at the boundary.
    _ppm = 50

    // Gravity points down in physics-space (-Y). The renderer
    // uses screen coords (+Y down), so we flip on the way out.
    _world = World2D.new({"gravity": [0, -9.81]})

    // Place the ground so its top edge sits exactly on the bottom
    // of the visible screen, and side walls so balls can't drift
    // off-screen on resize. Computed from the screen size + ppm
    // so the visuals stay aligned with the physics state.
    _groundHalf = 0.4
    _wallHalf   = 0.5
    var halfH = (g.height / 2) / _ppm
    var halfW = (g.width  / 2) / _ppm
    _groundY  = -halfH + _groundHalf

    _world.spawnStatic({
      "position": [0, _groundY],
      "shape":    Collider2D.box(halfW + 2, _groundHalf, {"restitution": 0.6})
    })
    // Side walls keep balls from drifting away on a resize.
    _world.spawnStatic({
      "position": [-halfW - _wallHalf, 0],
      "shape":    Collider2D.box(_wallHalf, halfH * 2, {"restitution": 0.4})
    })
    _world.spawnStatic({
      "position": [ halfW + _wallHalf, 0],
      "shape":    Collider2D.box(_wallHalf, halfH * 2, {"restitution": 0.4})
    })

    // Drop a few seed balls so the demo has motion on first paint.
    // Spaced > one ball-diameter apart so the rapier solver doesn't
    // fire them apart on the first step from overlapping spawns.
    var seeds = [
      [-3.0, 4.0],
      [-1.5, 5.0],
      [ 0.0, 6.0],
      [ 1.5, 5.0],
      [ 3.0, 4.0]
    ]
    for (p in seeds) spawnBallAt_(p[0], p[1])
  }

  resize(g, w, h) {
    // Rebuild camera + walls so the playfield tracks the new
    // surface dimensions. Existing balls stay in the world.
    _camera = Camera2D.new(w, h)
  }

  update(g) {
    if (g.input.justPressed("Escape")) g.requestQuit
    if (g.input.mouseJustPressed("left")) {
      // Convert mouse pixels → world metres around screen centre.
      var wx = (g.input.mouseX - g.width / 2) / _ppm
      var wy = (g.height / 2 - g.input.mouseY) / _ppm
      spawnBallAt_(wx, wy)
    }

    // Step physics with the frame dt; on the very first frame
    // dt is 0 so this is a no-op.
    _world.step(g.dt)

    // Cull balls that escaped the world (shouldn't happen with
    // walls, but guards against penetration corner-cases).
    var halfW = (g.width  / 2) / _ppm + 5
    var alive = []
    for (b in _balls) {
      var p = _world.position(b.body)
      if (p[0] > -halfW && p[0] < halfW && p[1] > _groundY - 5) {
        alive.add(b)
      } else {
        _world.despawn(b.body)
      }
    }
    _balls = alive
  }

  draw(g) {
    _renderer.beginFrame(_camera)

    // Ground band sized + placed from the physics ground so the
    // visuals and the collider line up exactly.
    var groundTopWorld = _groundY + _groundHalf
    var groundTopScreen = g.height / 2 - groundTopWorld * _ppm
    var groundSprite = Sprite.new(_texture)
    groundSprite.x = 0
    groundSprite.y = groundTopScreen
    groundSprite.width  = g.width
    groundSprite.height = g.height - groundTopScreen
    groundSprite.tint = [0.30, 0.32, 0.40, 1.0]
    groundSprite.draw(_renderer)

    for (b in _balls) {
      var p = _world.position(b.body)
      // World → pixel: centre origin in screen, flip Y.
      b.sprite.x = g.width / 2 + p[0] * _ppm
      b.sprite.y = g.height / 2 - p[1] * _ppm
      b.sprite.draw(_renderer)
    }
    _renderer.flush(g.pass)
  }

  spawnBallAt_(wx, wy) {
    var radius = 0.4
    var body = _world.spawnDynamic({
      "position": [wx, wy],
      "shape":    Collider2D.ball(radius, {"restitution": 0.78}),
      "mass":     1
    })
    var px = radius * 2 * _ppm
    var sprite = Sprite.new(_texture)
    sprite.width  = px
    sprite.height = px
    sprite.anchor(0.5, 0.5)
    sprite.tint = _palette[_colorIdx % _palette.count]
    _colorIdx = _colorIdx + 1
    _balls.add(Ball.new(body, sprite))
  }
}

Game.run(BouncingBall)
