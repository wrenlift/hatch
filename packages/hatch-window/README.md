Window and input for any WrenLift app. `winit` on native, page-attached canvas on web; same `Window.create({...})` call, same `pollEvents` / `closeRequested` / `size` surface across targets. Bring-your-own canvas via `Window.attach(elementId)` on web.

## Overview

Open a window once at startup, pump events at the top of each frame, and query `closeRequested` to decide when to exit. The handle exposed by `Window.handle` is the same platform-tagged `Map` any other embedder produces. Replacing this package with a hand-rolled one is a Wren-level contract, not a plugin one.

```wren
import "@hatch:window" for Window
import "@hatch:gpu"    for Gpu

var win = Window.create({ "title": "Demo", "width": 1280, "height": 720 })
var dev = Gpu.requestDevice()

var surf = dev.createSurface(win.handle)
surf.configure({ "width": 1280, "height": 720 })

while (!win.closeRequested) {
  for (event in win.pollEvents) {
    if (event["type"] == "resize") {
      surf.configure({ "width": event["width"], "height": event["height"] })
    }
  }

  var frame = surf.acquire()
  // ... render to frame.view ...
  frame.present
}
```

`win.pollEvents` returns an iterable of event `Map`s, one per OS event since the last poll. Event types include `keyDown` / `keyUp` (with `code`), `mouseDown` / `mouseUp` (with `button`), `mouseMove`, `resize`, and `close`.

## Web target

On `#!wasm` builds the package re-exports `window_web.wren`, which creates a `<canvas>` under `#stage` (or the document body if no `#stage` element exists). Bring-your-own canvas via `Window.attach(elementId)`:

```wren
#!wasm
var win = Window.attach("game-canvas")
```

Resize events fire when the underlying element's `clientWidth` / `clientHeight` change (e.g. via CSS); the handler should re-configure the GPU surface to match.

> **Note: handle shape is the contract**
> A custom embedder that wants to host WrenLift code in its own window only needs to produce the same handle `Map` from its `Window.handle` getter. The shape is `{"kind": "wayland" | "x11" | "win32" | "appkit" | "web", ...}` with platform-specific fields. See the source for the exact key set.

## Compatibility

Wren 0.4 with WrenLift runtime 0.1 or newer. Native uses `winit`; web uses the DOM.
