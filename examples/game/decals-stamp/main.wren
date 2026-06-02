// decals-stamp — click-to-stamp decals on a ground plane via the
// new `DecalLayer` + `Decal` API in `@hatch:game/decals`.
//
// Left mouse drops a coloured splat where the cursor's screen-
// space ray intersects the y=0 plane. Each decal fades in over
// 0.2 s, holds for 5 s, then fades out over 2 s. Up to 256 live
// decals before new ones are dropped.

import "@hatch:game" for Game, Decal, DecalLayer, Decals, Particles
import "@hatch:gpu"  for Renderer3D, Camera3D, Mesh, Material
import "@hatch:math" for Vec3, Vec4, Mat4

class DecalsDemo is Game {
  construct new() {}

  config { {
    "title":      "Decals stamp",
    "width":      1280,
    "height":     720,
    "clearColor": [0.18, 0.20, 0.24, 1.0],
    "depth":      true
  } }

  // Procedural 64×64 splat texture — soft round disc.
  makeSplatTexture_(device, size) {
    var bytes = []
    var half = size / 2.0
    var y = 0
    while (y < size) {
      var x = 0
      while (x < size) {
        var dx = (x + 0.5) - half
        var dy = (y + 0.5) - half
        var d  = (dx * dx + dy * dy).sqrt / half
        // Pixels outside the inscribed disc are fully transparent
        // — without this clip, even a tiny floor alpha (e.g. 35)
        // shows the quad's rectangular boundary on the surface.
        var a = 0
        if (d < 1) {
          var fall = 1 - d
          a = (fall * fall * 255).floor
        }
        bytes.add(255)
        bytes.add(255)
        bytes.add(255)
        bytes.add(a)
        x = x + 1
      }
      y = y + 1
    }
    var tex = device.createTexture({
      "width": size, "height": size, "format": "rgba8unorm",
      "usage": ["texture-binding", "copy-dst"]
    })
    device.writeTexture(tex, ByteArray.fromList(bytes),
                        {"width": size, "height": size, "bytesPerRow": size * 4})
    return tex
  }

  setup(g) {
    _renderer = Renderer3D.new(g.device, g.surfaceFormat, g.depthFormat)
    _camera   = Camera3D.perspective(55, g.width / g.height, 0.1, 100)

    _yaw      = 0.5
    _pitch    = 0.7
    _distance = 18
    _target   = Vec3.new(0, 0, 0)
    _lastMx   = 0
    _lastMy   = 0
    _dragging = false
    refreshCamera_()

    // Ground plane — a 20×20 cube, scaled flat. Lets us stamp
    // decals on something visible. PBR-shaded so the decals
    // interact properly with the lighting setup.
    _ground = Mesh.plane(g.device, 20)
    _groundMat = Material.new(Vec4.new(0.35, 0.42, 0.30, 1.0))
    _groundModel = Mat4.identity

    // Decal layer. 256-decal capacity; one shared splat texture.
    _splatTex = makeSplatTexture_(g.device, 64)
    _decalLayer = DecalLayer.new(g.device, g.surfaceFormat, g.depthFormat,
                                 _splatTex, 256)
    Decals.register(_decalLayer)

    // Track right-click vs left-click for two colour profiles.
    _palette = [
      [0.95, 0.20, 0.20, 0.95],  // red
      [0.25, 0.85, 0.30, 0.85],  // green
      [0.30, 0.50, 0.95, 0.90],  // blue
      [0.95, 0.85, 0.30, 0.85]   // yellow
    ]
    _paletteIx = 0
    _wasDown = false
    _hint = "left-click ground to stamp; space cycles colour"
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

  // Cast a ray from the mouse into the y=0 plane via a manual
  // camera-basis reconstruction (Mat4 has no `.inverse` exposed
  // yet). Returns world-space hit point, or null if the ray
  // misses the plane.
  pickGround_(g) {
    var eye = _camera.eye
    var tgt = _camera.target
    // forward = normalize(target - eye)
    var fx = tgt.x - eye.x
    var fy = tgt.y - eye.y
    var fz = tgt.z - eye.z
    var fl = (fx * fx + fy * fy + fz * fz).sqrt
    fx = fx / fl
    fy = fy / fl
    fz = fz / fl
    // right = normalize(cross(forward, worldUp))
    var wu = _camera.up
    var rx = fy * wu.z - fz * wu.y
    var ry = fz * wu.x - fx * wu.z
    var rz = fx * wu.y - fy * wu.x
    var rl = (rx * rx + ry * ry + rz * rz).sqrt
    rx = rx / rl
    ry = ry / rl
    rz = rz / rl
    // up = cross(right, forward)
    var ux = ry * fz - rz * fy
    var uy = rz * fx - rx * fz
    var uz = rx * fy - ry * fx
    // NDC: (-1..1, -1..1). Screen y is top-down so flip.
    var nx = (g.input.mouseX / g.width)  * 2 - 1
    var ny = 1 - (g.input.mouseY / g.height) * 2
    var aspect = g.width / g.height
    // Same FOV the camera was built with (see setup).
    var tanHalfFovY = (55 * 0.5 * 3.14159265 / 180).tan
    var tanHalfFovX = tanHalfFovY * aspect
    var dx = nx * tanHalfFovX
    var dy = ny * tanHalfFovY
    // Ray dir = forward + right * dx + up * dy
    var rdx = fx + rx * dx + ux * dy
    var rdy = fy + ry * dx + uy * dy
    var rdz = fz + rz * dx + uz * dy
    if (rdy.abs < 0.00001) return null
    // Solve eye.y + t * rdy = 0
    var t = -eye.y / rdy
    if (t < 0) return null
    return Vec3.new(eye.x + rdx * t, 0, eye.z + rdz * t)
  }

  update(g) {
    var mx = g.input.mouseX
    var my = g.input.mouseY
    // Right-drag orbits. Reserve left-click for stamping.
    if (g.input.mouseDown("right")) {
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
      _distance = _distance - g.input.scrollY * 1.0
      if (_distance < 4)  _distance = 4
      if (_distance > 60) _distance = 60
    }
    refreshCamera_()

    // Left-click stamps a decal.
    var leftDown = g.input.mouseDown("left")
    if (leftDown && !_wasDown) {
      var hit = pickGround_(g)
      if (hit != null) {
        var col = _palette[_paletteIx]
        _decalLayer.add(Decal.new({
          "position": hit,
          "normal":   Vec3.unitY,
          "size":     [1.6, 1.6],
          "texture":  _splatTex,
          "tint":     col,
          "lifetime": 5.0,
          "fadeIn":   0.15,
          "fadeOut":  2.0,
          "rotation": (System.clock * 7.3) - (System.clock * 7.3).floor
        }))
      }
    }
    _wasDown = leftDown

    if (g.input.justPressed("Space")) {
      _paletteIx = (_paletteIx + 1) % _palette.count
    }
    if (g.input.justPressed("Escape")) g.requestQuit
  }

  draw(g) {
    _renderer.beginFrame(g.pass, _camera)
    _renderer.setAmbient(Vec3.new(0.5, 0.55, 0.6), 0.9)
    _renderer.addDirectional(Vec3.new(-0.3, -1, -0.4),
                             Vec3.new(1, 0.95, 0.85), 2.8)
    _renderer.draw(_ground, _groundMat, _groundModel)
    _renderer.endFrame()
    // Decals on top — depth-tested against the just-written
    // ground depth so they sit ON it, not floating in mid-air.
    _decalLayer.draw(g.pass, _camera)
  }
}

Game.run(DecalsDemo)
