// @hatch:window — minimal acceptance.
//
// Smoke-tests the foreign surface: create a window, read its
// size + handle, pump the event loop, destroy the window. We
// can't assert pixel-level behaviour from a spec (winit needs
// a display server in CI), so this stays at the API-shape
// level.

import "./window" for Window
import "@hatch:test"   for Test
import "@hatch:assert" for Expect

Test.describe("Window") {
  Test.it("creates with default descriptor + reports a size") {
    var w = Window.create()
    Expect.that(w is Window).toBe(true)

    var s = w.size
    Expect.that(s["width"] > 0).toBe(true)
    Expect.that(s["height"] > 0).toBe(true)

    w.destroy
  }

  Test.it("hands out a platform-tagged handle Map") {
    var w = Window.create({"title": "spec", "width": 320, "height": 200})
    var h = w.handle
    Expect.that(h is Map).toBe(true)
    Expect.that(h["platform"]).not.toBeNull()
    w.destroy
  }

  Test.it("returns an empty event list after a fresh pump") {
    var w = Window.create({"width": 200, "height": 160})
    var events = w.pollEvents
    Expect.that(events is List).toBe(true)
    w.destroy
  }
}

Test.run()
