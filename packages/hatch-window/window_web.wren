// @hatch:window — web backend.
//
// Mirrors the native @hatch:window shape: a thin foreign class
// (`WindowCore`) holds the plugin's actual exports; the regular
// Wren `Window` class wraps a single canvas handle and is what
// game code touches. Same public method names as the native
// variant, so portable code reads the same on both targets.

#!native = "wlift_window"
foreign class WindowCore {
  // Auto-create a fresh `<canvas>` (default) or attach to an
  // existing element when the descriptor's `"canvas"` key holds
  // its DOM id. Returns the registry handle (Num), or `-1` on
  // failure.
  //
  // Descriptor keys:
  //   "canvas":    String  — DOM id of an existing `<canvas>`.
  //                          When set, "parent" / "width" /
  //                          "height" are ignored (the page owns
  //                          the element's layout).
  //   "title":     String  (default "wlift")
  //   "width":     Num     (default 800)   — fresh-canvas only
  //   "height":    Num     (default 600)   — fresh-canvas only
  //   "parent":    String  (default "stage") — CSS id of the host
  //                                            element to append
  //                                            a fresh canvas to.
  //   "resizable": Bool    (default true)  — currently unused.
  #!symbol = "wlift_window_create"
  foreign static create(descriptor)

  #!symbol = "wlift_window_destroy"
  foreign static destroy(handle)

  // No-op on web (events arrive async); kept for native parity.
  #!symbol = "wlift_window_pump"
  foreign static pump(handle)

  #!symbol = "wlift_window_close_requested"
  foreign static closeRequested(handle)

  // Returns `{"width": Num, "height": Num}`.
  #!symbol = "wlift_window_size"
  foreign static size(handle)

  // Returns a List of event Maps. Mouse: type, x, y, button.
  // Keyboard: type, key.
  #!symbol = "wlift_window_drain_events"
  foreign static drainEvents(handle)
}

// Public Window class. Same shape as gpu_native.wren's `Window`:
// `Window.create({...})` returns an instance you keep around;
// instance methods drive the underlying canvas.
//
//   import "@hatch:window" for Window
//   import "@hatch:gpu"    for Gpu
//
//   var win    = Window.create({"width": 1280, "height": 720})
//   var device = Gpu.requestDevice({})
//   var surf   = device.createSurface(win.handle)
//
//   while (!win.closeRequested) {
//     for (event in win.pollEvents) System.print(event)
//     // ... render ...
//   }
class Window {
  static create(descriptor) {
    if (!(descriptor is Map)) descriptor = {}
    var id = WindowCore.create(descriptor)
    if (id < 0) Fiber.abort("Window.create: WebGPU canvas allocation failed")
    return Window.new_(id)
  }
  static create() { create({}) }

  // Attach to an existing `<canvas id="...">` the page already
  // owns. Convenience over `Window.create({"canvas": id, ...})`.
  static attach(elementId) { create({ "canvas": elementId }) }

  construct new_(id) { _id = id }

  id     { _id }

  // Raw handle the GPU side consumes. On web it's a Num (canvas
  // registry index); on native it's a raw_window_handle Map. Both
  // are accepted by `Device.createSurface`.
  handle { _id }

  // Latest canvas size — `{"width": Num, "height": Num}`.
  size { WindowCore.size(_id) }

  closeRequested { WindowCore.closeRequested(_id) }

  // Drain pending DOM events as a List of Maps. See
  // gpu_native.wren's Window for the event-shape contract.
  pollEvents { WindowCore.drainEvents(_id) }

  pump() { WindowCore.pump(_id) }

  destroy {
    WindowCore.destroy(_id)
    _id = -1
  }

  toString { "Window(%(_id))" }
}
