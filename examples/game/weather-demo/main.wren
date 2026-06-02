// weather-demo — minimal Game.run showcase for Weather.rain +
// Weather.fog. A single spinning cube acts as the focal point;
// the rain column tracks the camera so wherever the player
// stands, there's weather above them. Fog gives the scene aerial
// perspective and matches the sky's horizon band.

import "@hatch:game" for Game, Weather, Particles
import "@hatch:gpu"  for Renderer3D, Camera3D, Mesh, Material
import "@hatch:math" for Vec3, Vec4, Mat4

class WeatherDemo is Game {
  construct new() {}

  config { {
    "title":      "Weather demo — rain + fog",
    "width":      1280,
    "height":     720,
    "clearColor": [0.62, 0.74, 0.88, 1.0]
  } }

  setup(g) {
    _renderer = Renderer3D.new(g.device, g.surfaceFormat, "depth32float")
    _camera   = Camera3D.perspective(60, g.width / g.height, 0.1, 200)
    _camera.lookAt(Vec3.new(0, 8, 25), Vec3.zero, Vec3.unitY)
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

  update(g) {
    _time = _time + g.dt
    // Rain column tracks the camera in XZ so the player always
    // stands under the falling particles.
    _rain.setPosition(_camera.eye.x, _camera.eye.y + 15, _camera.eye.z)
  }

  draw(g) {
    _renderer.beginFrame(g.pass, _camera)
    _renderer.setFog(_fog)
    var model = Mat4.rotationY(_time * 0.8)
    _renderer.draw(_cube, _material, model)
    _rain.draw(_renderer)
    _renderer.endFrame()
  }
}

Game.run(WeatherDemo)
