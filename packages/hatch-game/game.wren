// @hatch:game — minimal game-loop scaffold.
//
// LÖVE-style setup / update / draw lifecycle, PixiJS-style
// `Sprite` display object (in @hatch:gpu), Godot-flavoured
// state-based input polling. Window + device + surface
// lifetimes are managed by `Game.run`; user code is just the
// game.
//
//   import "@hatch:game"  for Game
//   import "@hatch:gpu"   for Renderer2D, Camera2D, Sprite
//   import "@hatch:image" for Image
//
//   Game.run({
//     "title":      "Sprite Demo",
//     "width":      800, "height": 600,
//     "clearColor": [0.08, 0.08, 0.12, 1.0],
//
//     "setup": Fn.new {|g|
//       var img = Image.decode(...)
//       var sprite = Sprite.new(g.device.uploadImage(img))
//       sprite.anchor(0.5, 0.5)
//       g.set("sprite",   sprite)
//       g.set("renderer", Renderer2D.new(g.device, g.surfaceFormat))
//       g.set("camera",   Camera2D.new(g.width, g.height))
//     },
//
//     "update": Fn.new {|g|
//       var s = g.get("sprite")
//       s.x = s.x + (g.input.isDown("KeyD") ? 200 * g.dt : 0)
//       s.x = s.x - (g.input.isDown("KeyA") ? 200 * g.dt : 0)
//       if (g.input.isDown("Escape")) g.requestQuit
//     },
//
//     "draw": Fn.new {|g|
//       var r = g.get("renderer")
//       r.beginFrame(g.get("camera"))
//       g.get("sprite").draw(r)
//       r.flush(g.pass)
//     }
//   })
//
// Resize events trigger a surface re-configure automatically.
// Setting `g.requestQuit` from setup / update / draw exits on
// the next frame boundary.

import "@hatch:window" for Window
import "@hatch:gpu"    for Gpu
import "@hatch:time"   for Clock

// Aggregated keyboard / mouse state. Updated each frame by
// Game.run from the window's event stream. Both event-style
// (`g.events`, the raw list) and state-style polling (`g.input`)
// are available — pick whichever fits the situation.
//
//   if (g.input.isDown("Space")) jump()
//   if (g.input.justPressed("Escape")) g.requestQuit
//
// Key names match winit's `physical_key` Debug formatting (e.g.
// `KeyA`, `Space`, `Escape`, `ArrowLeft`). Mouse buttons are
// `left`, `right`, `middle`, `other`.
class Input {
  construct new_() {
    _down       = {}    // key string → true while held
    _pressed    = {}    // key → true on the frame it was first pressed
    _released   = {}    // key → true on the frame it was released
    _mouseDown  = {}
    _mouseHit   = {}
    _mouseRel   = {}
    _mouseX     = 0
    _mouseY     = 0
  }

  // Begin a new frame: clear edge-triggered sets. `down` /
  // mouseDown persist across frames so `isDown` keeps reading
  // true while the key is held.
  beginFrame_ {
    _pressed = {}
    _released = {}
    _mouseHit = {}
    _mouseRel = {}
  }

  // Apply one event from the window's pollEvents list.
  applyEvent_(e) {
    var t = e["type"]
    if (t == "keyDown") {
      var k = Input.normalizeKey_(e["code"])
      if (!_down.containsKey(k)) _pressed[k] = true
      _down[k] = true
    } else if (t == "keyUp") {
      var k = Input.normalizeKey_(e["code"])
      _down.remove(k)
      _released[k] = true
    } else if (t == "mouseDown") {
      var b = e["button"]
      if (!_mouseDown.containsKey(b)) _mouseHit[b] = true
      _mouseDown[b] = true
    } else if (t == "mouseUp") {
      var b = e["button"]
      _mouseDown.remove(b)
      _mouseRel[b] = true
    } else if (t == "mouseMoved") {
      _mouseX = e["x"]
      _mouseY = e["y"]
    }
  }

  // winit gives us values like "Code(KeyA)" / "Code(Space)" via
  // Debug formatting. Strip the wrapper so users write friendly
  // strings.
  static normalizeKey_(s) {
    if (!(s is String)) return s.toString
    if (s.startsWith("Code(") && s.endsWith(")")) {
      return s[5..(s.count - 2)]
    }
    return s
  }

  // True while `key` is held — works between key-down and key-up.
  isDown(key) { _down.containsKey(key) }

  // True only on the single frame `key` first transitioned to
  // pressed. Reset by the next beginFrame_.
  justPressed(key) { _pressed.containsKey(key) }

  // True only on the single frame `key` was released.
  justReleased(key) { _released.containsKey(key) }

  // Mouse state — same model as keyboard. `button` is one of
  // "left" / "right" / "middle" / "other".
  mouseDown(button)        { _mouseDown.containsKey(button) }
  mouseJustPressed(button) { _mouseHit.containsKey(button) }
  mouseJustReleased(button) { _mouseRel.containsKey(button) }
  mouseX { _mouseX }
  mouseY { _mouseY }
}

// Per-frame state passed to the user's setup / update / draw.
// Wraps the long-lived pieces (window, device, surface) plus a
// scratchpad Map so users can stash frame-to-frame state without
// closing over locals or building their own struct.
class GameState {
  construct new_(window, device, surfaceFormat) {
    _window  = window
    _device  = device
    _surface = null         // set after first configure
    _surfaceFormat = surfaceFormat
    _pass    = null
    _events  = []
    _dt      = 0
    _tick    = 0
    _elapsed = 0
    _userData = {}
    _quit    = false
    _input   = Input.new_()
  }

  // Aggregated keyboard / mouse state for this frame. See `Input`
  // above — `g.input.isDown("Space")`, `g.input.mouseX`, etc.
  input { _input }

  window        { _window }
  device        { _device }
  surface       { _surface }
  surface=(s)   { _surface = s }
  surfaceFormat { _surfaceFormat }

  pass          { _pass }
  pass=(p)      { _pass = p }

  events        { _events }
  events=(e)    { _events = e }

  // Seconds since the previous frame. Zero on the first frame
  // (before any time has elapsed) — guard division accordingly.
  dt            { _dt }
  dt=(v)        { _dt = v }

  // Total elapsed seconds since Game.run started.
  elapsed       { _elapsed }
  elapsed=(v)   { _elapsed = v }

  // Frame index, monotonically increasing from 0.
  tick          { _tick }
  tick=(v)      { _tick = v }

  // Window dimensions sourced from the latest resize event.
  // Convenience over `g.window.size["width"]`.
  width  { _window.size["width"] }
  height { _window.size["height"] }

  // Scratchpad. `g.set("renderer", r)` from setup, `g.get("renderer")`
  // from draw — keeps the user out of closure-state-management.
  set(key, value) { _userData[key] = value }
  get(key)        { _userData[key] }
  has(key)        { _userData.containsKey(key) }

  // Set from anywhere to break the loop on the next frame
  // boundary. `Game.run` returns shortly after.
  requestQuit { _quit = true }
  quitRequested { _quit }
}

class Game {
  // Defaults applied when a config key is missing. `Map.containsKey`
  // checks below let the user omit any of these.
  static DEFAULTS_ {
    return {
      "title":        "wlift",
      "width":        1280,
      "height":       720,
      "resizable":    true,
      "surfaceFormat": "bgra8unorm",
      "clearColor":   [0.0, 0.0, 0.0, 1.0],
      "presentMode":  "fifo"
    }
  }

  // Open a window, request a device, configure a surface, and
  // run the loop. `config` is a Map; `setup` / `update` / `draw`
  // callbacks are optional but `draw` is the usual minimum. The
  // call returns once the window's close box is clicked or
  // `g.requestQuit` is invoked.
  static run(config) {
    var d = Game.DEFAULTS_
    var c = {}
    for (k in d.keys) c[k] = d[k]
    if (config is Map) {
      for (k in config.keys) c[k] = config[k]
    }

    var window = Window.create({
      "title":     c["title"],
      "width":     c["width"],
      "height":    c["height"],
      "resizable": c["resizable"]
    })
    var device  = Gpu.requestDevice()
    var surface = device.createSurface(window.handle)
    surface.configure({
      "width":       c["width"],
      "height":      c["height"],
      "format":      c["surfaceFormat"],
      "presentMode": c["presentMode"]
    })

    var g = GameState.new_(window, device, c["surfaceFormat"])
    g.surface = surface

    var setupFn  = c.containsKey("setup")  ? c["setup"]  : null
    var updateFn = c.containsKey("update") ? c["update"] : null
    var drawFn   = c.containsKey("draw")   ? c["draw"]   : null

    if (setupFn != null) setupFn.call(g)

    var lastTime = Clock.mono
    var startTime = lastTime

    while (!g.quitRequested && !window.closeRequested) {
      // Drain OS events; rebuild surface when the window resizes
      // so the swap chain matches the new dimensions, and route
      // each event through Input so state polling reflects the
      // freshest values.
      var events = window.pollEvents
      g.input.beginFrame_
      for (e in events) {
        g.input.applyEvent_(e)
        if (e["type"] == "close") {
          g.requestQuit
        } else if (e["type"] == "resize") {
          var w = e["width"]
          var h = e["height"]
          if (w > 0 && h > 0) {
            surface.configure({
              "width":       w,
              "height":      h,
              "format":      c["surfaceFormat"],
              "presentMode": c["presentMode"]
            })
          }
        }
      }
      g.events = events

      var now = Clock.mono
      g.dt      = now - lastTime
      g.elapsed = now - startTime
      lastTime  = now

      if (updateFn != null) updateFn.call(g)

      var frame = surface.acquire()
      var encoder = device.createCommandEncoder()
      var pass = encoder.beginRenderPass({
        "colorAttachments": [{
          "view":       frame.view,
          "loadOp":     "clear",
          "clearValue": c["clearColor"],
          "storeOp":    "store"
        }]
      })
      g.pass = pass
      if (drawFn != null) drawFn.call(g)
      g.pass = null
      pass.end
      encoder.finish
      device.submit([encoder])
      frame.present

      g.tick = g.tick + 1
    }

    surface.destroy
    window.destroy
  }
}
