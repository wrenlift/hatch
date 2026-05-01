// `@hatch:window` — entry module that re-exports the right
// window-provider backend for the bundle target.
//
// | File                 | Backend                                                                                                                                  |
// |----------------------|------------------------------------------------------------------------------------------------------------------------------------------|
// | `window_native.wren` | winit-backed cdylib (macOS / Linux / Windows). `Window` class wraps a polled event loop, exposes a raw-window-handle `Map` `@hatch:gpu`'s `Surface` accepts. |
// | `window_web.wren`    | DOM-canvas backed wasm plugin (browser). `Window` static class creates a canvas under `#stage` (or document body) and queues mouse / keyboard events. |
//
// Same package, target-conditional re-exports. Bundler picks the
// matching `[native_libs]` entry per `--bundle-target`.

#!native
import "window_native" for WindowCore, Window

#!wasm
import "window_web" for WindowCore, Window
