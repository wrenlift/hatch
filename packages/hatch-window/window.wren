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

#!native = "wlift_window"
foreign class WindowCore {
  #!symbol = "wlift_window_create"
  foreign static create(descriptor)

  #!symbol = "wlift_window_destroy"
  foreign static destroy(id)

  #!symbol = "wlift_window_pump"
  foreign static pump()

  #!symbol = "wlift_window_close_requested"
  foreign static closeRequested(id)

  #!symbol = "wlift_window_size"
  foreign static size(id)

  #!symbol = "wlift_window_drain_events"
  foreign static drainEvents(id)

  #!symbol = "wlift_window_handle"
  foreign static handle(id)
}

class Window {
  // Open a new window. Descriptor (all optional):
  //   "title":     String  ("wlift")
  //   "width":     Num     (1280)
  //   "height":    Num     (720)
  //   "resizable": Bool    (true)
  static create(descriptor) {
    if (!(descriptor is Map)) descriptor = {}
    var id = WindowCore.create(descriptor)
    return Window.new_(id)
  }
  static create() { create({}) }

  construct new_(id) { _id = id }

  id { _id }

  // Size as a Map { "width", "height" }. Reflects the latest OS
  // size; resize events fired through pollEvents track the same
  // value frame-by-frame.
  size { WindowCore.size(_id) }

  // True once the user has requested the window close (clicked
  // the close box, hit cmd-W, etc.). Once true it stays true.
  closeRequested { WindowCore.closeRequested(_id) }

  // Drain pending OS events as a List of Maps:
  //
  //   {"type": "close"}
  //   {"type": "resize",     "width": Num, "height": Num}
  //   {"type": "keyDown",    "code": String}
  //   {"type": "keyUp",      "code": String}
  //   {"type": "mouseMoved", "x": Num, "y": Num}
  //   {"type": "mouseDown",  "button": "left"|"right"|"middle"|"other"}
  //   {"type": "mouseUp",    "button": "..."}
  //
  // Calling pollEvents implicitly pumps winit, so a typical game
  // loop just reads from this list once per frame.
  pollEvents { WindowCore.drainEvents(_id) }

  // Drive winit without draining events — useful when you want
  // to keep a window responsive while doing async work.
  pump() { WindowCore.pump() }

  // Raw window handle as the platform-tagged Map @hatch:gpu's
  // `Device.createSurface` accepts. Custom embedders that
  // produce the same shape are interchangeable here — that's
  // the whole point of the BYO-window contract.
  handle { WindowCore.handle(_id) }

  destroy {
    WindowCore.destroy(_id)
    _id = -1
  }

  toString { "Window(%(_id))" }
}
