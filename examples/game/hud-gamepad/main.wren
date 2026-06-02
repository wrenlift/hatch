// hud-gamepad — three-button pause menu, navigable by both mouse
// (hover + click) and gamepad (DPad/stick + A). The HUD's focus
// model is per-frame: each button(...) call registers its id in
// draw order, and beginFrame steps the focus pointer based on
// gamepad input from the previous frame.

import "@hatch:game" for Game
import "@hatch:gpu"  for Renderer2D, Camera2D
import "@hatch:hud"  for HUD

class HudGamepad is Game {
  construct new() {
    _pickedLabel = "(none yet)"
  }

  config { {
    "title":      "HUD gamepad nav",
    "width":      900, "height": 540,
    "clearColor": [0.10, 0.12, 0.18, 1.0]
  } }

  setup(g) {
    _renderer = Renderer2D.new(g.device, g.surfaceFormat)
    _camera   = Camera2D.new(g.width, g.height)
    _hud      = HUD.new(g)
  }

  update(g) {}

  draw(g) {
    _renderer.beginFrame(_camera)
    _renderer.beginPass(g.pass)

    _hud.beginFrame(g, _renderer)
    _hud.label("Pause", 40, 40, 3, [1, 1, 1, 1])
    _hud.label("Picked: %(_pickedLabel)", 40, 80, 1, [0.8, 0.85, 1, 1])
    if (_hud.button("Resume", 40, 140, 220, 56))   _pickedLabel = "Resume"
    if (_hud.button("Settings", 40, 210, 220, 56)) _pickedLabel = "Settings"
    if (_hud.button("Quit", 40, 280, 220, 56)) {
      _pickedLabel = "Quit"
      g.requestQuit
    }
    _hud.label("DPad/Left-Stick : nav · A : press · mouse also works",
               40, 380, 1, [0.6, 0.65, 0.75, 1])
    _hud.endFrame

    _renderer.flush(g.pass)
    _renderer.endPass()
  }
}

Game.run(HudGamepad)
