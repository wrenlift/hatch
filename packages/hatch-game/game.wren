// @hatch:game — minimal game-loop scaffold.
//
// PixiJS / Cocos / Godot-style: subclass `Game`, override the
// hooks you care about, hand the class to `Game.run`. State
// lives in fields on your subclass — no userdata scratchpad,
// no closure ceremony.
//
//   import "@hatch:game"  for Game
//   import "@hatch:gpu"   for Renderer2D, Camera2D, Sprite
//   import "@hatch:image" for Image
//
//   class MyGame is Game {
//     // Wren doesn't inherit constructors; declare an empty
//     // `construct new() {}` so Game.run can instantiate.
//     construct new() {}
//
//     config { {
//       "title":      "Sprite Demo",
//       "width":      800, "height": 600,
//       "clearColor": [0.08, 0.08, 0.12, 1.0]
//     } }
//
//     setup(g) {
//       var img    = Image.decode(...)
//       _sprite    = Sprite.new(g.device.uploadImage(img))
//       _sprite.anchor(0.5, 0.5)
//       _renderer  = Renderer2D.new(g.device, g.surfaceFormat)
//       _camera    = Camera2D.new(g.width, g.height)
//     }
//
//     update(g) {
//       if (g.input.isDown("KeyD")) _sprite.x = _sprite.x + 200 * g.dt
//       if (g.input.isDown("KeyA")) _sprite.x = _sprite.x - 200 * g.dt
//       if (g.input.isDown("Escape")) g.requestQuit
//     }
//
//     draw(g) {
//       _renderer.beginFrame(_camera)
//       _sprite.draw(_renderer)
//       _renderer.flush(g.pass)
//     }
//   }
//
//   Game.run(MyGame)
//
// Window + device + surface lifetimes are managed by Game.run.
// Resize events trigger a surface re-configure automatically.
// Setting `g.requestQuit` from any hook exits on the next frame
// boundary.

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

// Render-target dimensions in pixels. Lifecycle:
//   - constructed once at Game.run startup from the configured
//     surface size (post-clamp, see Surface.configure)
//   - replaced atomically when the framework re-configures the
//     surface on a window resize
//
// Frequently the only thing a Camera2D / Camera3D constructor
// needs, so renderers and game code can pass `g.viewport` around
// instead of unpacking `(g.width, g.height)` everywhere.
class Viewport {
  construct new_(w, h) {
    _width  = w
    _height = h
  }
  width  { _width }
  height { _height }
  aspect { _height == 0 ? 1.0 : (_width / _height) }
  toString { "Viewport(%(_width)x%(_height))" }
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
    _depthFormat = null
    _depthView   = null
    _pass    = null
    _events  = []
    _dt      = 0
    _tick    = 0
    _elapsed = 0
    _userData = {}
    _quit    = false
    _input   = Input.new_()
    _viewport = Viewport.new_(0, 0)
    _lastTime  = 0
    _startTime = 0
  }

  // Aggregated keyboard / mouse state for this frame. See `Input`
  // above — `g.input.isDown("Space")`, `g.input.mouseX`, etc.
  input { _input }

  // Depth attachment (`null` if the loop wasn't configured with
  // `"depth": true`). The framework attaches this automatically
  // when present; renderers like Renderer3D pass `g.depthFormat`
  // when they build their pipeline.
  depthFormat       { _depthFormat }
  depthFormat=(v)   { _depthFormat = v }
  depthView         { _depthView }
  depthView=(v)     { _depthView = v }

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

  // Surface dimensions in actual pixels — what wgpu draws into.
  // The framework keeps these in sync with the configured surface
  // (which may be clamped on resize past the GPU's max texture
  // dimension), so a Camera2D / Camera3D built from `g.width` /
  // `g.height` always matches the render target. Distinct from
  // `g.window.size`, which reports the OS window's pre-clamp size.
  //
  // `g.viewport` returns a `Viewport` value with .width / .height
  // / .aspect for callers that want to thread one object through.
  width    { _viewport.width }
  height   { _viewport.height }
  viewport { _viewport }
  // Internal: replace the viewport. Called by Game.run on startup
  // and on every resize event after the surface has been
  // re-configured.
  setViewport_(w, h) { _viewport = Viewport.new_(w, h) }

  // Internal: frame-clock state. Stored on `GameState` rather than
  // local variables in `Game.run`'s loop body because the
  // surrounding loop's complexity confuses the closure-upvalue
  // capture and the locals end up reading as undefined inside the
  // loop on the second-or-later iterations.
  lastTime_       { _lastTime }
  lastTime_=(v)   { _lastTime = v }
  startTime_      { _startTime }
  startTime_=(v)  { _startTime = v }

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

// Base class for user games. Subclass it, override
// `config` / `setup` / `update` / `draw` (each optional), and
// hand the subclass to `Game.run`. Default implementations are
// no-ops so a stub subclass with only `draw` runs cleanly.
class Game {
  construct new() {}

  // Window / surface configuration. Override in your subclass:
  //
  //   class MyGame is Game {
  //     config { {"title": "...", "width": 800, "height": 600} }
  //   }
  //
  // Defaults below merge in for any key the override leaves out.
  config { {} }

  // Lifecycle hooks. `g` is the per-frame `GameState` — see the
  // class above for getters (g.dt, g.input, g.pass, etc.).
  setup(g)  {}
  update(g) {}
  draw(g)   {}

  // Fired after the surface (and optional depth attachment) have
  // been re-allocated to match the new size. Override to rebuild
  // anything tied to viewport dimensions — typically a Camera2D /
  // Camera3D — so projections track the window.
  //
  //   resize(g, w, h) {
  //     _camera = Camera2D.new(w, h)
  //   }
  resize(g, width, height) {}

  // Defaults applied for keys the user's `config` override omits.
  // Pass `"depth": true` (or a format string like `"depth32float"`)
  // in your config to have the loop allocate + bind a depth
  // attachment automatically — required for 3D rendering and
  // the recommended path for any game that mixes Renderer2D
  // HUDs over a Renderer3D scene.
  static DEFAULTS_ {
    return {
      "title":        "wlift",
      "width":        1280,
      "height":       720,
      "resizable":    true,
      "surfaceFormat": "bgra8unorm",
      "clearColor":   [0.0, 0.0, 0.0, 1.0],
      "presentMode":  "fifo",
      "depth":        false       // Bool or "depth32float" / "depth24plus"
    }
  }

  // Static entry point. Constructs an instance of `klass`,
  // resolves its config, opens window + device + surface, and
  // drives the loop until the window closes or `g.requestQuit`
  // is called.
  //
  //   class MyGame is Game { ... }
  //   Game.run(MyGame)
  // Walk every queued OS event, route input through `g.input`,
  // and honour close requests. Resize events are intentionally
  // *not* handled here — `Game.run` polls `Window.size` directly
  // every frame. See the call site for why polling beats
  // event-driven resizes on macOS.
  //
  // Indexed `while` loop, NOT `for (e in events)` — the for-in
  // body forms a closure for outer-scope locals, and the
  // closure-upvalue mutation bug means writes to captured
  // counters inside don't propagate back.
  static drainEvents_(events, g) {
    var n = events.count
    var i = 0
    while (i < n) {
      var e = events[i]
      g.input.applyEvent_(e)
      if (e["type"] == "close") g.requestQuit
      i = i + 1
    }
  }

  static run(klass) {
    if (!(klass is Class)) {
      Fiber.abort("Game.run: argument must be a Class extending Game.")
    }
    var instance = klass.new()
    var defaults = Game.DEFAULTS_
    var c = {}
    for (k in defaults.keys) c[k] = defaults[k]
    var override = instance.config
    if (override is Map) {
      for (k in override.keys) c[k] = override[k]
    }

    var window = Window.create({
      "title":     c["title"],
      "width":     c["width"],
      "height":    c["height"],
      "resizable": c["resizable"]
    })
    var device  = Gpu.requestDevice()
    var surface = device.createSurface(window.handle)
    var initial = surface.configure({
      "width":       c["width"],
      "height":      c["height"],
      "format":      c["surfaceFormat"],
      "presentMode": c["presentMode"]
    })
    var sw = initial is Map ? initial["width"]  : c["width"]
    var sh = initial is Map ? initial["height"] : c["height"]

    // Resolve depth attachment config. true → "depth32float";
    // a string overrides; false / null → no depth attachment.
    var depthFormat = null
    if (c["depth"] is String) depthFormat = c["depth"]
    if (c["depth"] == true)   depthFormat = "depth32float"

    var depthTexture = null
    var depthView    = null
    if (depthFormat != null) {
      depthTexture = device.createTexture({
        "width":  sw, "height": sh,
        "format": depthFormat,
        "usage":  ["render-attachment"]
      })
      depthView = depthTexture.createView()
    }

    var g = GameState.new_(window, device, c["surfaceFormat"])
    g.surface     = surface
    g.depthFormat = depthFormat
    g.depthView   = depthView
    g.setViewport_(sw, sh)

    instance.setup(g)

    g.lastTime_  = Clock.mono
    g.startTime_ = g.lastTime_

    // Track the *requested* window size, not the clamped surface
    // dimensions, so the resize check below doesn't loop forever
    // when the GPU's `max_texture_dimension_2d` clamps the surface
    // (Apple integrated GPUs cap at 2048; a 3024px-wide retina
    // window stays clamped to 2048 forever, so comparing winW
    // against `g.width` would request a reconfigure every frame).
    var lastReqW = sw
    var lastReqH = sh

    while (!g.quitRequested && !window.closeRequested) {
      // Drain OS events. Use an index-based while loop instead of
      // `for (e in events)` because mutating outer-scope locals
      // from inside a `for-in` body trips a known closure-upvalue
      // bug — the surrounding `lastTime` / `startTime` get
      // clobbered, then `now - lastTime` raises "Right operand
      // must be a number" the next frame.
      var events = window.pollEvents
      g.input.beginFrame_
      Game.drainEvents_(events, g)

      // Poll the live window size every frame instead of relying
      // on `WindowEvent::Resized` reaching us through the event
      // queue. Two reasons:
      //
      //  1. winit on macOS only fires `Resized` at
      //     `windowDidEndLiveResize` — i.e. when the user
      //     releases the mouse. During the drag, the run loop
      //     is in NSEventTrackingRunLoopMode, our pump call
      //     returns nothing, and the swap chain stays at its
      //     stale dimensions. The visible window grows,
      //     uncovered area shows the OS background through.
      //  2. After `windowDidEndLiveResize` the Resized event
      //     does come through, but on some macOS / winit
      //     combinations only one of the two dimensions
      //     updates per event and we miss the other axis until
      //     the next event.
      //
      // `Window.size` reads back the live cached `inner_size`
      // that the winit event handler keeps current, which is
      // updated even when the queued `Resized` event has not
      // yet been popped by `pollEvents`. Comparing it to the
      // surface's published viewport gives a reliable resize
      // signal.
      var ws = window.size
      var winW = ws["width"]
      var winH = ws["height"]
      if (winW > 0 && winH > 0 && (winW != lastReqW || winH != lastReqH)) {
        lastReqW = winW
        lastReqH = winH
        var actual = surface.configure({
          "width":       winW,
          "height":      winH,
          "format":      c["surfaceFormat"],
          "presentMode": c["presentMode"]
        })
        var aw = actual is Map ? actual["width"]  : winW
        var ah = actual is Map ? actual["height"] : winH
        g.setViewport_(aw, ah)
        if (depthFormat != null) {
          depthTexture = device.createTexture({
            "width":  aw, "height": ah,
            "format": depthFormat,
            "usage":  ["render-attachment"]
          })
          depthView = depthTexture.createView()
          g.depthView = depthView
        }
        instance.resize(g, aw, ah)
      }
      g.events = events

      var now = Clock.mono
      g.dt      = now - g.lastTime_
      g.elapsed = now - g.startTime_
      g.lastTime_ = now

      instance.update(g)

      var frame = surface.acquire()
      var encoder = device.createCommandEncoder()
      var passDesc = {
        "colorAttachments": [{
          "view":       frame.view,
          "loadOp":     "clear",
          "clearValue": c["clearColor"],
          "storeOp":    "store"
        }]
      }
      if (depthView != null) {
        passDesc["depthStencilAttachment"] = {
          "view":            depthView,
          "depthLoadOp":     "clear",
          "depthClearValue": 1.0,
          "depthStoreOp":    "store"
        }
      }
      var pass = encoder.beginRenderPass(passDesc)
      g.pass = pass
      instance.draw(g)
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
