// `@hatch:game`: minimal game-loop scaffold.
//
// Subclass `Game`, override the relevant hooks, and hand the
// class to `Game.run`. State lives in fields on the subclass.
// No userdata scratchpad, no closure ceremony.
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

// Scene-graph types. Re-exported so consumers pull `Transform`,
// `GlobalTransform`, `MeshRenderer`, light components, and the
// `TransformPropagation` system straight from `@hatch:game`
// without learning the sibling module name.
import "./scene" for
  Transform,
  GlobalTransform,
  MeshRenderer,
  RigidBody,
  Collider,
  PhysicsSystem3D,
  PhysicsSystem2D,
  AudioSource,
  AudioListener,
  DirectionalLight,
  PointLight,
  SpotLight,
  AmbientLight,
  TransformPropagation,
  SceneRenderer3D

// ECS-shaped Phase 2 components + systems. `Active{Camera}` marks
// the renderer's primary camera, `SpriteRenderer` wraps a 2D
// drawable, `Animator` wraps an `AnimationPlayer`. The systems
// (`CameraSystem`, `SpriteRenderSystem`, `AnimationSystem`,
// `AudioSystem`) are static `run(world, …)` entry points called
// once per frame.
import "./ecs_components" for
  ActiveCamera,
  SpriteRenderer,
  Animator,
  CameraSystem,
  SpriteRenderSystem,
  AnimationSystem,
  AudioSystem

// Semantic input mapping. `Actions.define("jump", [...])` and
// `Actions.justPressed("jump")` decouple game code from raw key
// codes; `Actions.emitter` exposes the press / release stream
// so `@hatch:fsm` statecharts can subscribe directly via
// `chart.bindEvents(Actions.emitter, [...])`.
import "./actions" for Actions

// Tweens + keyframe clips. `Tweens.add(...)` schedules a property
// animator that ticks every frame; `AnimationPlayer` drives one
// or more `Clip`s with optional crossfade and FSM-statechart
// binding. Game.run pumps the tween manager once per frame so
// user code only writes the `Tween.new` call.
import "./animation" for Tween, Tweens, Clip, AnimationPlayer, Behaviors

// CPU particle systems. `ParticleSystem.new({...})` configures one
// system; `Particles.register(sys)` opts it into Game.run's per-
// frame tick (or call `sys.update(dt)` manually). Output routes
// through `Renderer2D.drawSpriteTinted` so particles share the
// existing batch pipeline.
import "./particles"     for ParticleSystem, ParticleSystem3D, Particles
import "./gpu_particles" for GpuParticleSystem3D
import "./decals"        for Decal, DecalLayer, Decals
import "./debug"     for
  FrameTimer,
  DebugOverlay,
  EntityInspector,
  PhysicsDebugDraw,
  InputRecorder,
  InputReplayer

// Fullscreen post-processing chain. Setting `g.postFX = PostFX.new(g)`
// in `setup` re-routes the scene render through an offscreen
// target; the chain then runs each `PostPass` in order, ending
// with a write to the swap chain. The chain primitive lives here;
// concrete effects (tonemap, bloom, FXAA, ...) ship in the
// separate `@hatch:postfx` package so the engine doesn't grow as
// the effect catalogue does.
import "./chain" for PostFX, PostPass

// Heightmap-driven terrain mesh generation. Composes @hatch:noise
// + @hatch:gpu's Mesh path; lives here because procedural worlds
// are a scene-level concern, not a pure-algorithm one.
import "./terrain"        for Terrain
import "./terrain_chunks" for TerrainChunk, TerrainStreamer

// Jittered-grid instanced scatter for grass / trees / rocks /
// asteroids. Returns parallel Float32Array columns ready to feed
// a ClusterGrid + writeInstance pipeline; the cull / LOD / draw
// loop is the caller's.
import "./foliage" for Foliage

// Environmental forces. Today: Wind — noise-driven 3D vector
// field with time evolution. Drop into particle integrators,
// foliage sway, water surface ripples.
import "./weather" for Wind, Weather

// Water surfaces. Subdivided plane mesh + a noise-driven wave
// height sampler that's shared between CPU buoyancy queries and
// vertex-shader displacement (sample at the same world point in
// both paths to keep them consistent). WaterPipeline is the
// self-contained render pipeline that displaces + fresnels +
// speculars the water mesh on the GPU.
import "./water" for Water, WaterPipeline
import "./sky"   for SkyboxPipeline
import "./fog"   for Fog

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
    _scrollX    = 0     // edge-triggered scroll delta for this frame
    _scrollY    = 0
    // Gamepad state. Buttons are 0/1 in the axisMap so
    // `Actions.bind("Jump", ["GamepadButtonA"])` reads via the
    // same axis-lookup path that gamepad sticks use. Axes are
    // signed -1..1 and persist until the next AxisChanged event.
    _gamepadAxis = {}   // code (String) → Num
    // Edge-triggered gamepad button state. Mirrors the keyboard
    // `_pressed` / `_released` pattern so HUD focus nav + game
    // logic can both ask `gamepadJustPressed("GamepadButtonA")`.
    _gamepadPressed  = {}
    _gamepadReleased = {}
  }

  // Begin a new frame: clear edge-triggered sets. `down` /
  // mouseDown persist across frames so `isDown` keeps reading
  // true while the key is held. Scroll deltas reset to zero so
  // each frame sees only its own wheel input.
  beginFrame_ {
    _pressed = {}
    _released = {}
    _mouseHit = {}
    _mouseRel = {}
    _scrollX = 0
    _scrollY = 0
    _gamepadPressed  = {}
    _gamepadReleased = {}
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
    } else if (t == "mouseWheel") {
      // Deltas accumulate within a frame so multiple wheel events
      // (typical on a trackpad) sum into one scrubbed value the
      // consumer reads once per frame.
      _scrollX = _scrollX + e["dx"]
      _scrollY = _scrollY + e["dy"]
    } else if (t == "gamepadButtonDown") {
      // Map gamepad buttons into the same axisMap Actions reads
      // for sticks, but with value 1. Held until the up event.
      var code = e["code"]
      if (!_gamepadAxis.containsKey(code) || _gamepadAxis[code] != 1) {
        _gamepadPressed[code] = true
      }
      _gamepadAxis[code] = 1
    } else if (t == "gamepadButtonUp") {
      var code = e["code"]
      _gamepadAxis.remove(code)
      _gamepadReleased[code] = true
    } else if (t == "gamepadAxis") {
      _gamepadAxis[e["code"]] = e["value"]
    }
  }

  /// True only on the frame `code` first transitioned to pressed
  /// (`"GamepadButtonA"`, `"GamepadDPadUp"`, ...). Mirrors the
  /// keyboard / mouse `justPressed` shape so HUD focus nav and
  /// game logic share the same edge-triggered idiom.
  /// @param {String} code
  /// @returns {Bool}
  gamepadJustPressed(code) { _gamepadPressed.containsKey(code) }

  /// True only on the frame `code` was released.
  /// @param {String} code
  /// @returns {Bool}
  gamepadJustReleased(code) { _gamepadReleased.containsKey(code) }

  /// True while `code` is held (button down between press / release).
  /// @param {String} code
  /// @returns {Bool}
  gamepadDown(code) {
    return _gamepadAxis.containsKey(code) && _gamepadAxis[code] == 1
  }

  /// Snapshot of the current gamepad input as a `Map<String, Num>`
  /// keyed by binding name (`"GamepadButtonA"`, `"GamepadAxisLX"`,
  /// ...). Passed to `Actions.update_` as the axisMap argument so
  /// the same binding lookup that handles keyboard / mouse works
  /// for sticks and buttons.
  ///
  /// @returns {Map}
  gamepadAxisMap { _gamepadAxis }

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

  /// Mouse-wheel horizontal delta this frame. Sums every
  /// `MouseWheel` event since the previous `beginFrame_`.
  /// Trackpad horizontal swipes and tilt-wheels both feed in.
  ///
  /// @returns {Num}
  scrollX { _scrollX }

  /// Mouse-wheel vertical delta this frame. Positive when the
  /// content under the cursor moves down (typical scroll-up). Use
  /// for camera zoom: `_distance = _distance - g.input.scrollY * k`.
  ///
  /// @returns {Num}
  scrollY { _scrollY }
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
    _colorView   = null
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
    _encoder   = null
    _postFX    = null
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
  /// Active colour `TextureView` for this frame. Framework-set
  /// before user `draw`; useful when ending the active pass and
  /// opening a follow-up that needs to load the same attachment
  /// (e.g. water sampling the depth buffer with a read-only depth
  /// attachment).
  colorView         { _colorView }
  colorView=(v)     { _colorView = v }

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

  /// Active `CommandEncoder` for this frame. Set by `Game.run`
  /// each iteration before `update` / `draw`, cleared after the
  /// frame's `submit`. Surfaced primarily for `PostFX` and other
  /// chains that need to record their own passes alongside the
  /// user's `draw(g)` work.
  /// @returns {CommandEncoder}
  encoder       { _encoder }
  encoder=(e)   { _encoder = e }

  /// Optional `PostFX` chain. When set, `Game.run` re-routes
  /// `g.pass` to the chain's offscreen scene target, drives the
  /// chain after `draw(g)` returns, and writes the final output
  /// into the swap chain. Set in `setup(g)`:
  ///
  /// ```wren
  /// g.postFX = PostFX.new(g)
  /// g.postFX.add(TonemapPass.new())
  /// ```
  ///
  /// `null` (the default) keeps the direct-to-swap-chain path.
  /// @returns {PostFX}
  postFX        { _postFX }
  postFX=(p)    { _postFX = p }

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
    // Open the native window VISIBLE from the start. The user's
    // bigger UX complaint was a multi-second wait before any window
    // appears (Gpu.requestDevice + surface.configure + first paint
    // were all running pre-show); showing the window immediately is
    // a clearer signal that the app is alive even if the content
    // area briefly carries the OS default background until the first
    // wgpu present lands. The clear-color first paint below still
    // runs ASAP and replaces the OS background with the configured
    // colour, normally within a few hundred ms of launch.
    //
    // On web the canvas is page-owned and `visible` is ignored.
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
        // `texture-binding` lets a downstream pipeline sample the
        // depth attachment in a fragment shader (with a read-only
        // depth attachment on the sampling pass). Cost is zero when
        // no shader reads it.
        "usage":  ["render-attachment", "texture-binding"]
      })
      depthView = depthTexture.createView()
    }

    var g = GameState.new_(window, device, c["surfaceFormat"])
    g.surface     = surface
    g.depthFormat = depthFormat
    g.depthView   = depthView
    g.setViewport_(sw, sh)

    // Loading-screen paint: clear the swap-chain to the configured
    // background colour. Used both for the immediate "window now
    // visible" first frame AND between yields of the setup pump
    // below — long asset loads inside setup() can take seconds,
    // and each yield gets one cleared frame + one OS event drain
    // so the window stays responsive and macOS doesn't beachball.
    var paintLoadingFrame = Fn.new {
      window.pollEvents
      var frame = surface.acquire()
      if (frame != null) {
        var enc  = device.createCommandEncoder()
        var attach = {
          "view":       frame.view,
          "loadOp":     "clear",
          "clearValue": c["clearColor"],
          "storeOp":    "store"
        }
        var desc = { "colorAttachments": [attach] }
        if (depthView != null) {
          desc["depthStencilAttachment"] = {
            "view":            depthView,
            "depthLoadOp":     "clear",
            "depthClearValue": 1.0,
            "depthStoreOp":    "store"
          }
        }
        var pass = enc.beginRenderPass(desc)
        pass.end
        enc.finish
        device.submit([enc])
        frame.present
      }
    }

    // First paint: clears the swap chain to the configured
    // background colour ASAP, replacing the OS default background
    // the user briefly sees in the window's content area while
    // GPU init was finishing. Two paints (+ poll between) let winit
    // settle macOS NSWindow's first display cycle before user code
    // (setup) starts running.
    paintLoadingFrame.call()
    paintLoadingFrame.call()

    // Setup pump. Run instance.setup(g) inside a Fiber and pump
    // events + paint between its yields. Setups that never yield
    // run to completion on the first iteration (one extra paint
    // and one extra pollEvents vs. the legacy sync path — both
    // already happening in pre-paint anyway). Setups that DO
    // yield — typically because they call a yielding loader like
    // `Gltf.fromAssetsDir` — get a responsive window throughout.
    // System.print("[launch] entering setup(): %(((Clock.mono - tStart) * 1000).round)ms")
    var setupFiber = Fiber.new { instance.setup(g) }
    var setupErrRaw = null
    while (!setupFiber.isDone) {
      if (window.closeRequested) break
      setupErrRaw = setupFiber.call()
      paintLoadingFrame.call()
    }
    // Stale-slot guard — fiber.call can leak a stale slot value
    // on a clean return (see feedback_fiber_try_stale_slot.md).
    var setupErr = setupErrRaw is String ? setupErrRaw : null
    if (setupErr != null) Fiber.abort(setupErr)

    // System.print("[launch] setup done, main loop: %(((Clock.mono - tStart) * 1000).round)ms")
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
      // Refresh semantic action state (held / justPressed /
      // justReleased / value) from the now-current Input. Also
      // emits press / release events on `Actions.emitter` —
      // any StateChart that called `bindEvents(Actions.emitter, …)`
      // sees them as transition triggers without the frame loop
      // needing to know about it.
      //
      // The null guards on Actions / Tweens / Particles below are
      // load-bearing on the wasm playground: the cross-target
      // bundle's sibling-module imports for these three (`./actions`,
      // `./animation`, `./particles`) bind to null in @hatch:game's
      // module-vars on the web runtime even though the modules ship
      // in the bundle. Without the guards the first frame aborts at
      // `Null does not implement update_(_)`. Native binds them
      // correctly so the guards are a no-op there.
      if (Actions   != null) Actions.update_(g.input, g.input.gamepadAxisMap)
      // Advance any scheduled tweens. `Tweens.add(t)` is the
      // user-facing entry; this is the matching pump call so user
      // code doesn't have to remember to drive it.
      if (Tweens    != null) Tweens.update(g.dt)
      // Tick registered particle systems. Systems that prefer
      // explicit timing skip `Particles.register` and call
      // `system.update(dt)` themselves.
      if (Particles != null) Particles.update(g.dt)
      // Age registered decal layers. Drops expired decals so user
      // code never has to remember to drain them between frames.
      if (Decals    != null) Decals.update(g.dt)

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
            "usage":  ["render-attachment", "texture-binding"]
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
      g.encoder = encoder

      // PostFX chain: scene render goes to the chain's offscreen
      // colour target instead of the swap chain, and a final
      // chain-end pass writes the processed result into `frame.view`.
      // When no PostFX is configured, the scene draws directly to
      // the swap chain (the unchanged fast path).
      var post = g.postFX
      var sceneColorView = frame.view
      var sceneDepthView = depthView
      var sceneNormalView = null
      if (post != null) {
        post.resize_(g.width, g.height)
        sceneColorView = post.sceneView_
        if (post.sceneDepthView_ != null) sceneDepthView = post.sceneDepthView_
        sceneNormalView = post.sceneNormalView_
      }

      var colorAttachments = [{
        "view":       sceneColorView,
        "loadOp":     "clear",
        "clearValue": c["clearColor"],
        "storeOp":    "store"
      }]
      // Secondary normal G-buffer — only attached when PostFX was
      // built with `{ "normalFormat": ... }` (typically an
      // OutlinePass downstream). Cleared to (0.5, 0.5, 1, 1) which
      // packs as the +Z (camera-facing) unit normal, so any
      // fragment the scene doesn't write resolves to "no edge"
      // under depth+normal Sobel.
      if (sceneNormalView != null) {
        colorAttachments.add({
          "view":       sceneNormalView,
          "loadOp":     "clear",
          "clearValue": [0.5, 0.5, 1.0, 1.0],
          "storeOp":    "store"
        })
      }
      var passDesc = { "colorAttachments": colorAttachments }
      if (sceneDepthView != null) {
        passDesc["depthStencilAttachment"] = {
          "view":            sceneDepthView,
          "depthLoadOp":     "clear",
          "depthClearValue": 1.0,
          "depthStoreOp":    "store"
        }
      }
      var pass = encoder.beginRenderPass(passDesc)
      g.pass = pass
      // Stash the active colour view on `g` so a user draw can
      // end this pass and open a follow-up pass that loads the same
      // attachment (needed for depth-as-sampled-texture in shore
      // foam / refraction effects).
      g.colorView = sceneColorView
      // Mirror the depth view that pass 1 actually wrote into so
      // demo follow-up passes (water, shore-foam refraction) load
      // and sample the SAME depth texture. Without PostFX,
      // `sceneDepthView` already is `g.depthView` so this is a
      // no-op on the fast path.
      var savedDepthView = g.depthView
      g.depthView = sceneDepthView
      // Run the user draw in a child fiber so the GPU teardown
      // below ALWAYS executes. If draw aborts mid-frame the
      // SurfaceTexture and open CommandEncoder would otherwise
      // stay live in @hatch:gpu's registries; on process exit the
      // cdylib's static-OnceLock drop order is unspecified and the
      // leaked SurfaceTexture's Drop would dereference a freed
      // Surface. We capture the error, finish the frame, and
      // re-raise after the device has been told to submit.
      var drawFiber = Fiber.new { instance.draw(g) }
      var drawErrRaw = drawFiber.try()
      // Workaround for a wlift codegen bug: `Fiber.try()` on a
      // cleanly-returning fiber occasionally returns whatever was
      // last in the result slot (a stale String / Num / Object) in
      // place of `null`. A genuine `Fiber.abort(...)` always passes
      // a String message, so we accept only Strings as real errors.
      // Anything else (Num, Map, instance, etc.) we treat as a
      // clean exit. If we ever start using non-string abort values
      // intentionally, switch this to a sentinel match instead.
      var drawErr = drawErrRaw is String ? drawErrRaw : null
      // End whichever pass is currently active on `g`. If the user
      // ended `pass` (the framework-opened one) and started their
      // own follow-up, `g.pass` now references the follow-up; we
      // end that. If they didn't swap, `g.pass == pass` and we end
      // the original. Either way the encoder lands at zero open
      // passes before submit.
      var finalPass = g.pass
      g.pass = null
      g.colorView = null
      g.depthView = savedDepthView
      if (finalPass != null) finalPass.end
      pass = null

      if (post != null && drawErr == null) post.runChain(encoder, frame.view)

      encoder.finish
      device.submit([encoder])
      // submit already removed the encoder from the registry; the
      // destroy here is the proactive Wren-side cleanup that nulls
      // the wrapper so GC reclaims it on the next cycle without
      // waiting for the frame-loop iteration to drop the local.
      encoder.destroy
      encoder = null
      g.encoder = null
      frame.present
      frame = null
      passDesc = null

      if (drawErr != null) Fiber.abort(drawErr)

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
