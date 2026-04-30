// @hatch:window — default window provider for WrenLift games.
//
//   import "@hatch:window" for Window
//   import "@hatch:gpu"    for Gpu
//
//   var win = Window.create({"title": "Demo", "width": 1280, "height": 720})
//   var dev = Gpu.requestDevice()
//
//   var surf = dev.createSurface(win.handle)
//   surf.configure({"width": 1280, "height": 720})
//
//   while (!win.closeRequested) {
//     for (event in win.pollEvents) {
//       if (event["type"] == "resize") {
//         surf.configure({"width": event["width"], "height": event["height"]})
//       }
//     }
//
//     var frame = surf.acquire()
//     // ... render to frame.view ...
//     frame.present
//   }
//
// Backed by winit via the wlift_window dylib. The platform-tagged
// handle Map produced by `Window.handle` is the same shape any
// other embedder (custom shells, IDE viewports, host apps) can
// produce — bring-your-own-window is a Wren-level contract, not
// a plugin one. Replacing this package with a hand-rolled one is
// a matter of producing the same handle Map.

/// Low-level foreign surface — the plugin's actual exports.
/// Game code goes through [Window]; this exists only to back it.
#!native = "wlift_window"
foreign class WindowCore {
  /// Open a new winit window. See [Window.create] for the
  /// descriptor shape. Returns the registry id.
  /// @param {Map} descriptor
  /// @returns {Num}
  #!symbol = "wlift_window_create"
  foreign static create(descriptor)

  /// Release the window at `id`.
  /// @param {Num} id
  #!symbol = "wlift_window_destroy"
  foreign static destroy(id)

  /// Pump the OS event loop without draining events.
  #!symbol = "wlift_window_pump"
  foreign static pump()

  /// True once the user has requested the window close.
  /// @param {Num} id
  /// @returns {Bool}
  #!symbol = "wlift_window_close_requested"
  foreign static closeRequested(id)

  /// Latest OS-reported size as `{"width": Num, "height": Num}`.
  /// @param {Num} id
  /// @returns {Map}
  #!symbol = "wlift_window_size"
  foreign static size(id)

  /// Drain pending OS events as a list of Maps. See
  /// [Window.pollEvents] for the full event-shape contract.
  /// @param {Num} id
  /// @returns {List}
  #!symbol = "wlift_window_drain_events"
  foreign static drainEvents(id)

  /// Raw `raw_window_handle`-style Map for the window — what
  /// [Device.createSurface] consumes.
  /// @param {Num} id
  /// @returns {Map}
  #!symbol = "wlift_window_handle"
  foreign static handle(id)
}

/// Public Window class. `Window.create({...})` returns an
/// instance you keep around; instance methods drive the
/// underlying winit window.
///
/// ## Example
///
/// ```wren
/// import "@hatch:window" for Window
/// import "@hatch:gpu"    for Gpu
///
/// var win = Window.create({"title": "Demo", "width": 1280, "height": 720})
/// var dev = Gpu.requestDevice()
/// var surf = dev.createSurface(win.handle)
/// surf.configure({"width": 1280, "height": 720})
///
/// while (!win.closeRequested) {
///   for (event in win.pollEvents) {
///     if (event["type"] == "resize") {
///       surf.configure({"width": event["width"], "height": event["height"]})
///     }
///   }
///
///   var frame = surf.acquire()
///   // ... render to frame.view ...
///   frame.present
/// }
/// ```
class Window {
  /// Open a new window. Descriptor keys (all optional):
  ///
  /// - `"title"` — String (default `"wlift"`).
  /// - `"width"` — Num (default 1280).
  /// - `"height"` — Num (default 720).
  /// - `"resizable"` — Bool (default `true`).
  ///
  /// @param {Map} descriptor
  /// @returns {Window}
  static create(descriptor) {
    if (!(descriptor is Map)) descriptor = {}
    var id = WindowCore.create(descriptor)
    return Window.new_(id)
  }

  /// Open a window with default options.
  /// @returns {Window}
  static create() { create({}) }

  construct new_(id) { _id = id }

  /// Foreign-handle id (internal).
  /// @returns {Num}
  id { _id }

  /// Latest OS-reported size as `{"width": Num, "height": Num}`.
  /// Resize events fired through [Window.pollEvents] track the
  /// same value frame-by-frame.
  /// @returns {Map}
  size { WindowCore.size(_id) }

  /// True once the user has requested the window close (clicked
  /// the close box, hit cmd-W, etc.). Once true it stays true.
  /// @returns {Bool}
  closeRequested { WindowCore.closeRequested(_id) }

  /// Drain pending OS events as a list of Maps:
  ///
  /// - `{"type": "close"}`
  /// - `{"type": "resize",     "width": Num, "height": Num}`
  /// - `{"type": "keyDown",    "code": String}`
  /// - `{"type": "keyUp",      "code": String}`
  /// - `{"type": "mouseMoved", "x": Num, "y": Num}`
  /// - `{"type": "mouseDown",  "button": "left"|"right"|"middle"|"other"}`
  /// - `{"type": "mouseUp",    "button": "..."}`
  ///
  /// Calling `pollEvents` implicitly pumps winit, so a typical
  /// game loop just reads from this list once per frame.
  /// @returns {List}
  pollEvents { WindowCore.drainEvents(_id) }

  /// Drive winit without draining events — useful when keeping
  /// a window responsive during async work.
  pump() { WindowCore.pump() }

  /// Raw window handle as the platform-tagged Map
  /// [Device.createSurface] accepts. Custom embedders that
  /// produce the same shape are interchangeable — that's the
  /// whole point of the BYO-window contract.
  /// @returns {Map}
  handle { WindowCore.handle(_id) }

  /// Release the window. Idempotent.
  destroy {
    WindowCore.destroy(_id)
    _id = -1
  }

  toString { "Window(%(_id))" }
}
