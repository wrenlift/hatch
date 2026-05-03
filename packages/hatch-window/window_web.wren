// @hatch:window: web backend.
//
// Mirrors the native @hatch:window shape: a thin foreign class
// (`WindowCore`) holds the plugin's actual exports; the regular
// Wren `Window` class wraps a single canvas handle and is what
// game code touches. Same public method names as the native
// variant, so portable code reads the same on both targets.

/// Low-level foreign surface: the plugin's actual exports.
/// Game code goes through [Window]; this exists only to back it.
#!native = "wlift_window"
foreign class WindowCore {
  /// Auto-create a fresh `<canvas>` (default) or attach to an
  /// existing element when `descriptor["canvas"]` is set to its
  /// DOM id. Returns the registry handle, or `-1` on failure.
  ///
  /// Descriptor keys:
  ///
  /// - `"canvas"`: String, DOM id of an existing `<canvas>`.
  ///   When set, `"parent"` / `"width"` / `"height"` are
  ///   ignored (the page owns the element's layout).
  /// - `"title"`: String, default `"wlift"`.
  /// - `"width"`: Num, default 800 (fresh-canvas only).
  /// - `"height"`: Num, default 600 (fresh-canvas only).
  /// - `"parent"`: String, CSS id of the host element to
  ///   append a fresh canvas to (default `"stage"`).
  /// - `"resizable"`: Bool, default `true` (currently unused).
  ///
  /// @param {Map} descriptor
  /// @returns {Num}
  #!symbol = "wlift_window_create"
  foreign static create(descriptor)

  /// Release the canvas at `handle`.
  /// @param {Num} handle
  #!symbol = "wlift_window_destroy"
  foreign static destroy(handle)

  /// No-op on web (events arrive async); kept for native parity.
  /// @param {Num} handle
  #!symbol = "wlift_window_pump"
  foreign static pump(handle)

  /// True when the host has signalled the canvas should close.
  /// @param {Num} handle
  /// @returns {Bool}
  #!symbol = "wlift_window_close_requested"
  foreign static closeRequested(handle)

  /// Latest canvas size as `{"width": Num, "height": Num}`.
  /// @param {Num} handle
  /// @returns {Map}
  #!symbol = "wlift_window_size"
  foreign static size(handle)

  /// Drain pending DOM events as a list of Maps. Mouse events
  /// carry `type`, `x`, `y`, `button`; keyboard events carry
  /// `type`, `key`.
  /// @param {Num} handle
  /// @returns {List}
  #!symbol = "wlift_window_drain_events"
  foreign static drainEvents(handle)
}

/// Public Window class. `Window.create({...})` returns an
/// instance you keep around; instance methods drive the
/// underlying canvas.
///
/// ## Example
///
/// ```wren
/// import "@hatch:window" for Window
/// import "@hatch:gpu"    for Gpu
///
/// var win    = Window.create({"width": 1280, "height": 720})
/// var device = Gpu.requestDevice({})
/// var surf   = device.createSurface(win.handle)
///
/// while (!win.closeRequested) {
///   for (event in win.pollEvents) System.print(event)
///   // ... render ...
/// }
/// ```
class Window {
  /// Open a new window or attach to an existing canvas. See
  /// [WindowCore.create] for the descriptor shape.
  ///
  /// @param {Map} descriptor
  /// @returns {Window}
  static create(descriptor) {
    if (!(descriptor is Map)) descriptor = {}
    var id = WindowCore.create(descriptor)
    if (id < 0) Fiber.abort("Window.create: WebGPU canvas allocation failed")
    return Window.new_(id)
  }

  /// Open a new window with default options.
  /// @returns {Window}
  static create() { create({}) }

  /// Attach to an existing `<canvas id="...">` the page already
  /// owns. Convenience over
  /// `Window.create({"canvas": id, ...})`.
  ///
  /// @param {String} elementId
  /// @returns {Window}
  static attach(elementId) { create({ "canvas": elementId }) }

  construct new_(id) { _id = id }

  /// Foreign-handle id (internal).
  /// @returns {Num}
  id     { _id }

  /// Raw handle the GPU side consumes. On web it's a Num
  /// (canvas registry index); on native it's a
  /// `raw_window_handle` Map. Both are accepted by
  /// [Device.createSurface].
  /// @returns {Object}
  handle { _id }

  /// Latest canvas size as `{"width": Num, "height": Num}`.
  /// @returns {Map}
  size { WindowCore.size(_id) }

  /// True when the host has signalled the window should close.
  /// @returns {Bool}
  closeRequested { WindowCore.closeRequested(_id) }

  /// Drain pending DOM events as a list of Maps. See
  /// [WindowCore.drainEvents] for the event-shape contract.
  /// @returns {List}
  pollEvents { WindowCore.drainEvents(_id) }

  /// Pump the OS event loop. No-op on web; kept for native parity.
  pump() { WindowCore.pump(_id) }

  /// Release the window. Idempotent.
  destroy {
    WindowCore.destroy(_id)
    _id = -1
  }

  toString { "Window(%(_id))" }
}
