// Wren-side wrapper for wlift_window_web. Exposes a single
// `Window` static class. The mirror native package
// (@hatch:window) declares the same class against
// wlift_window's exports, so this file's Wren shape carries
// across targets.

#!native = "wlift_window"
foreign class Window {
  // Returns the window handle (Num), or `-1` on failure.
  // `descriptor` keys: "width" Num, "height" Num,
  // "title" String, "parent" String (CSS id, default "stage").
  #!symbol = "wlift_window_create"
  foreign static create_(descriptor)

  #!symbol = "wlift_window_destroy"
  foreign static destroy_(handle)

  // No-op on web (events arrive async); kept for native parity.
  #!symbol = "wlift_window_pump"
  foreign static pump_(handle)

  #!symbol = "wlift_window_close_requested"
  foreign static closeRequested_(handle)

  // Returns `{"width": Num, "height": Num}`.
  #!symbol = "wlift_window_size"
  foreign static size_(handle)

  // Returns a List of event Maps. Mouse: type, x, y, button.
  // Keyboard: type, key.
  #!symbol = "wlift_window_drain_events"
  foreign static drainEvents_(handle)
}
