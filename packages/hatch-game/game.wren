// `@hatch:game`: minimal game-loop scaffold.
//
// PixiJS / Cocos / Godot-style: subclass `Game`, override the
// relevant hooks, and hand the class to `Game.run`. State
// lives in fields on the subclass. No userdata scratchpad,
// no closure ceremony.
//
// ```wren
// import "@hatch:game"  for Game
// import "@hatch:gpu"   for Renderer2D, Camera2D, Sprite
// import "@hatch:image" for Image
//
// class MyGame is Game {
//   // Wren doesn't inherit constructors; declare an empty
//   // `construct new() {}` so Game.run can instantiate.
//   construct new() {}
//
//   config { {
//     "title":      "Sprite Demo",
//     "width":      800, "height": 600,
//     "clearColor": [0.08, 0.08, 0.12, 1.0]
//   } }
//
//   setup(g) {
//     var img    = Image.decode(...)
//     _sprite    = Sprite.new(g.device.uploadImage(img))
//     _sprite.anchor(0.5, 0.5)
//     _renderer  = Renderer2D.new(g.device, g.surfaceFormat)
//     _camera    = Camera2D.new(g.width, g.height)
//   }
//
//   update(g) {
//     if (g.input.isDown("KeyD")) _sprite.x = _sprite.x + 200 * g.dt
//     if (g.input.isDown("KeyA")) _sprite.x = _sprite.x - 200 * g.dt
//     if (g.input.isDown("Escape")) g.requestQuit
//   }
//
//   draw(g) {
//     _renderer.beginFrame(_camera)
//     _sprite.draw(_renderer)
//     _renderer.flush(g.pass)
//   }
// }
//
// Game.run(MyGame)
// ```
//
// Window + device + surface lifetimes are managed by `Game.run`.
// Resize events trigger a surface re-configure automatically.
// Setting `g.requestQuit` from any hook exits on the next frame
// boundary.

import "@hatch:window" for Window
import "@hatch:gpu"    for Gpu
import "@hatch:time"   for Clock

// On web, the main fiber holds the JS thread until it parks on
// an async bridge. The frame loop yields with
// `Browser.nextFrame.await` (vsync-paced via requestAnimationFrame
// on the page thread) so the JS event loop drains every frame and
// the page stays responsive. The prelude's `Browser` class is
// only auto-injected into the user's `run()` source; bundle
// modules have to import it explicitly. Native builds strip
// this whole import via the cfg pre-pass.
#!wasm
import "wlift_prelude" for Browser

/// Aggregated keyboard / mouse state. Updated each frame by
/// `Game.run` from the window's event stream. Both event-style
/// (`g.events`, the raw list) and state-style polling (`g.input`)
/// are available; pick whichever fits the situation.
///
/// ## Example
///
/// ```wren
/// if (g.input.isDown("Space")) jump()
/// if (g.input.justPressed("Escape")) g.requestQuit
/// ```
///
/// Key names match winit's `physical_key` Debug formatting (e.g.
/// `KeyA`, `Space`, `Escape`, `ArrowLeft`). Mouse buttons are
/// `left`, `right`, `middle`, `other`.
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

  // winit returns values like "Code(KeyA)" / "Code(Space)" via
  // Debug formatting. Strip the wrapper so users write friendly
  // strings.
  static normalizeKey_(s) {
    if (!(s is String)) return s.toString
    if (s.startsWith("Code(") && s.endsWith(")")) {
      return s[5..(s.count - 2)]
    }
    return s
  }

  /// True while `key` is held: between key-down and key-up.
  ///
  /// @param {String} key. winit-style key code (`"KeyA"`, `"Space"`, ...).
  /// @returns {Bool}
  isDown(key) { _down.containsKey(key) }

  /// True only on the single frame `key` first transitioned to
  /// pressed. Reset by the next frame.
  ///
  /// @param {String} key
  /// @returns {Bool}
  justPressed(key) { _pressed.containsKey(key) }

  /// True only on the single frame `key` was released.
  ///
  /// @param {String} key
  /// @returns {Bool}
  justReleased(key) { _released.containsKey(key) }

  /// Mouse-button held state. `button` is one of
  /// `"left"` / `"right"` / `"middle"` / `"other"`.
  ///
  /// @param {String} button
  /// @returns {Bool}
  mouseDown(button)         { _mouseDown.containsKey(button) }

  /// True only on the single frame `button` first transitioned to
  /// pressed.
  ///
  /// @param {String} button
  /// @returns {Bool}
  mouseJustPressed(button)  { _mouseHit.containsKey(button) }

  /// True only on the single frame `button` was released.
  ///
  /// @param {String} button
  /// @returns {Bool}
  mouseJustReleased(button) { _mouseRel.containsKey(button) }

  /// Mouse X in surface pixels. Origin is the top-left.
  ///
  /// @returns {Num}
  mouseX { _mouseX }

  /// Mouse Y in surface pixels. Origin is the top-left.
  ///
  /// @returns {Num}
  mouseY { _mouseY }
}

/// Render-target dimensions in pixels.
///
/// Constructed once at `Game.run` startup from the configured
/// surface size (post-clamp), and replaced atomically when the
/// framework re-configures the surface on a window resize.
///
/// Frequently the only thing a `Camera2D` / `Camera3D` constructor
/// needs, so renderers and game code can pass `g.viewport` around
/// instead of unpacking `(g.width, g.height)` everywhere.
class Viewport {
  construct new_(w, h) {
    _width  = w
    _height = h
  }
  /// Width in surface pixels.
  /// @returns {Num}
  width  { _width }
  /// Height in surface pixels.
  /// @returns {Num}
  height { _height }
  /// Width / height. Returns 1.0 when the height is zero so
  /// callers can do `camera.aspect = g.viewport.aspect` without
  /// guarding against division by zero on the first frame.
  /// @returns {Num}
  aspect { _height == 0 ? 1.0 : (_width / _height) }
  toString { "Viewport(%(_width)x%(_height))" }
}

/// Per-frame state passed to the user's `setup` / `update` / `draw`.
/// Wraps the long-lived pieces (window, device, surface) plus a
/// scratchpad Map so users can stash frame-to-frame state without
/// closing over locals or building their own struct.
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

  /// Aggregated keyboard / mouse state for this frame.
  /// See [Input]: `g.input.isDown("Space")`, `g.input.mouseX`, etc.
  /// @returns {Input}
  input { _input }

  /// Depth attachment format string (`null` if the loop wasn't
  /// configured with `"depth": true`). Renderers like Renderer3D
  /// thread this into their pipeline build.
  /// @returns {String}
  depthFormat       { _depthFormat }
  depthFormat=(v)   { _depthFormat = v }
  /// Bound depth `TextureView` for this frame. Framework-managed.
  depthView         { _depthView }
  depthView=(v)     { _depthView = v }

  /// The active `Window`.
  window        { _window }
  /// The GPU `Device` for this run.
  device        { _device }
  /// The active `Surface`. Set after the first configure.
  surface       { _surface }
  surface=(s)   { _surface = s }
  /// Surface texture format string (e.g. `"bgra8unorm"`).
  /// @returns {String}
  surfaceFormat { _surfaceFormat }

  /// Active `RenderPass` for this frame. `null` outside `draw`.
  pass          { _pass }
  pass=(p)      { _pass = p }

  /// Raw OS event list for this frame. Useful only when state
  /// polling via `g.input` doesn't fit. Each entry is a `Map`.
  /// @returns {List}
  events        { _events }
  events=(e)    { _events = e }

  /// Seconds since the previous frame. Zero on the first frame
  /// (before any time has elapsed); guard division accordingly.
  /// @returns {Num}
  dt            { _dt }
  dt=(v)        { _dt = v }

  /// Total elapsed seconds since `Game.run` started.
  /// @returns {Num}
  elapsed       { _elapsed }
  elapsed=(v)   { _elapsed = v }

  /// Frame index, monotonically increasing from 0.
  /// @returns {Num}
  tick          { _tick }
  tick=(v)      { _tick = v }

  /// Surface dimensions in actual pixels. These are what wgpu
  /// draws into. The framework keeps these in sync with the
  /// configured surface (which may be clamped on resize past
  /// the GPU's max texture dimension), so a `Camera2D` /
  /// `Camera3D` built from `g.width` / `g.height` always matches
  /// the render target. Distinct from `g.window.size`, which
  /// reports the OS window's pre-clamp size.
  /// @returns {Num}
  width    { _viewport.width }
  /// Surface height in pixels. See [GameState.width].
  /// @returns {Num}
  height   { _viewport.height }
  /// `Viewport` value with `.width` / `.height` / `.aspect`.
  /// The convenient single-object form for callers that want
  /// to thread one parameter through.
  /// @returns {Viewport}
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

  /// Scratchpad write. `g.set("renderer", r)` in `setup`,
  /// `g.get("renderer")` in `draw`. Keeps frame-to-frame state
  /// out of closure capture.
  ///
  /// @param {String} key
  /// @param {Object} value
  set(key, value) { _userData[key] = value }
  /// Scratchpad read. Returns `null` when the key isn't set.
  /// @param {String} key
  /// @returns {Object}
  get(key)        { _userData[key] }
  /// True when `key` has been set on the scratchpad.
  /// @param {String} key
  /// @returns {Bool}
  has(key)        { _userData.containsKey(key) }

  /// Mark the loop for shutdown. `Game.run` returns at the next
  /// frame boundary.
  requestQuit { _quit = true }
  /// True once any code path has called `requestQuit`.
  /// @returns {Bool}
  quitRequested { _quit }
}

/// Base class for user games. Subclass it, override
/// `config` / `setup` / `update` / `draw` (each optional), and
/// hand the subclass to `Game.run`. Default implementations are
/// no-ops so a stub subclass with only `draw` runs cleanly.
class Game {
  construct new() {}

  /// Window / surface configuration. Override in your subclass.
  ///
  /// ## Example
  ///
  /// ```wren
  /// class MyGame is Game {
  ///   config { {"title": "...", "width": 800, "height": 600} }
  /// }
  /// ```
  ///
  /// `Game.DEFAULTS_` merges in for any key the override omits.
  ///
  /// @returns {Map}
  config { {} }

  /// One-time initialisation hook. Called after the window /
  /// device / surface are ready, before the first frame.
  ///
  /// @param {GameState} g
  setup(g)  {}

  /// Per-frame update hook. Called once per vsync after input
  /// state has been refreshed and before `draw`.
  ///
  /// @param {GameState} g
  update(g) {}

  /// Per-frame render hook. `g.pass` is bound to the active
  /// `RenderPass`; flush any batches before returning.
  ///
  /// @param {GameState} g
  draw(g)   {}

  /// Fired after the surface (and optional depth attachment) have
  /// been re-allocated to match the new size. Override to rebuild
  /// anything tied to viewport dimensions (typically a `Camera2D`
  /// or `Camera3D`) so projections track the window.
  ///
  /// ## Example
  ///
  /// ```wren
  /// resize(g, w, h) {
  ///   _camera = Camera2D.new(w, h)
  /// }
  /// ```
  ///
  /// @param {GameState} g
  /// @param {Num} width
  /// @param {Num} height
  resize(g, width, height) {}

  // Defaults applied for keys the user's `config` override omits.
  // Pass `"depth": true` (or a format string like `"depth32float"`)
  // in the config to have the loop allocate + bind a depth
  // attachment automatically. Required for 3D rendering and
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
      "depth":        false,      // Bool or "depth32float" / "depth24plus"
      // Web-only: DOM id of an existing `<canvas>` to attach to.
      // When set, the runner skips the fresh-canvas path and the
      // surface configures against the element's natural size
      // instead of the `width` / `height` defaults. Ignored on
      // native (winit always opens a fresh window). Lets pages
      // embed a wlift game inside their own layout and styling
      // without having to override `Game.run` to thread the
      // descriptor manually.
      "canvas":       null
    }
  }

  // Walk every queued OS event, route input through `g.input`,
  // and honour close requests. Resize events are intentionally
  // *not* handled here. `Game.run` polls `Window.size` directly
  // every frame.
  //
  // Indexed `while` loop, NOT `for (e in events)`. The for-in
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

  /// Static entry point. Instantiates `klass`, resolves its
  /// `config`, opens window + device + surface, and drives the
  /// loop until the window closes or any code path calls
  /// `g.requestQuit`.
  ///
  /// ## Example
  ///
  /// ```wren
  /// class MyGame is Game { ... }
  /// Game.run(MyGame)
  /// ```
  ///
  /// @param {Class} klass. A class extending `Game`.
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

    // Build the Window descriptor. On web, `c["canvas"]` (if set)
    // routes through the page-owned-canvas attach path; on native
    // the key is ignored and `width`/`height` open a fresh winit
    // window. When attached, pull the natural element size out
    // afterwards so the surface configure / first render see the
    // page's actual layout dimensions instead of the descriptor's
    // (possibly default) numbers.
    var winDesc = {
      "title":     c["title"],
      "width":     c["width"],
      "height":    c["height"],
      "resizable": c["resizable"]
    }
    if (c["canvas"] is String) winDesc["canvas"] = c["canvas"]
    var window = Window.create(winDesc)

    var configW = c["width"]
    var configH = c["height"]
    if (c["canvas"] is String) {
      var s = window.size
      if (s is Map) {
        configW = s["width"]
        configH = s["height"]
      }
    }

    var device  = Gpu.requestDevice()
    var surface = device.createSurface(window.handle)
    var initial = surface.configure({
      "width":       configW,
      "height":      configH,
      "format":      c["surfaceFormat"],
      "presentMode": c["presentMode"]
    })
    var sw = initial is Map ? initial["width"]  : configW
    var sh = initial is Map ? initial["height"] : configH

    // Resolve depth attachment config. true means "depth32float";
    // a string overrides; false or null means no depth attachment.
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
      // bug. The surrounding `lastTime` / `startTime` get
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
      //     `windowDidEndLiveResize`, i.e. when the user
      //     releases the mouse. During the drag, the run loop
      //     is in NSEventTrackingRunLoopMode, the pump call
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

      // On web, the main fiber holds the JS thread until it parks
      // on an async bridge. `Browser.nextFrame` is the right
      // primitive: backed by `requestAnimationFrame`, so vsync-
      // paced, paint-aligned, and naturally throttled when the
      // tab is backgrounded. Worker mode falls back to a ~16 ms
      // timer because rAF is main-thread-only; see the bridge
      // shim in worker.js. Native winit windows pace via their
      // own event pump; this gate strips on host builds.
      #!wasm
      Browser.nextFrame.await
    }

    surface.destroy
    window.destroy
  }
}
