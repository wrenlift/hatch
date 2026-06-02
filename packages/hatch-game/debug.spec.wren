// @hatch:game/debug — FrameTimer + DebugOverlay.

import "./debug"        for FrameTimer, DebugOverlay
import "@hatch:test"    for Test
import "@hatch:assert"  for Expect

Test.describe("FrameTimer") {
  Test.it("count grows up to capacity, then saturates") {
    var t = FrameTimer.new(5)
    Expect.that(t.count).toBe(0)
    var i = 0
    while (i < 10) {
      t.tick(0.016)
      i = i + 1
    }
    Expect.that(t.count).toBe(5)
    Expect.that(t.capacity).toBe(5)
  }

  Test.it("avg + fps reflect the rolling window") {
    var t = FrameTimer.new(4)
    t.tick(0.020)
    t.tick(0.020)
    t.tick(0.020)
    t.tick(0.020)
    Expect.that(t.avg).toBe(0.020)
    Expect.that(t.avgMs).toBe(20)
    Expect.that(t.fps).toBe(50)
  }

  Test.it("lowFps drops below avg fps when a spike is present") {
    var t = FrameTimer.new(100)
    // 99 fast frames (60fps) + one slow spike (10fps).
    var i = 0
    while (i < 99) {
      t.tick(0.0166)
      i = i + 1
    }
    t.tick(0.1)   // a 100ms spike → 10fps
    // 1% low pulls in the worst sample; should be ~10fps, well
    // below the ~60fps average.
    Expect.that(t.lowFps < t.fps).toBe(true)
    Expect.that(t.lowFps < 15).toBe(true)
  }

  Test.it("reset clears accumulated samples") {
    var t = FrameTimer.new()
    t.tick(0.016)
    t.tick(0.016)
    Expect.that(t.count).toBe(2)
    t.reset
    Expect.that(t.count).toBe(0)
    Expect.that(t.fps).toBe(0)
  }

  Test.it("aborts on bogus capacity") {
    var e = Fiber.new { FrameTimer.new(0) }.try()
    Expect.that(e).toContain("capacity")
  }
}

// HUD stand-in that records the labels + rects the overlay drew.
class MockHud_ {
  construct new() {
    _labels = []
    _rects  = []
  }
  label(text, x, y, scale, color) { _labels.add(text) }
  rect(x, y, w, h, color)         { _rects.add([x, y, w, h]) }
  labels { _labels }
  rects  { _rects }
}

Test.describe("DebugOverlay") {
  Test.it("draws FPS + ms + 1% lines + named counters") {
    var o = DebugOverlay.new()
    o.tick(0.016)
    o.setCounter("entities", 42)
    o.setCounter("draws", 7)
    var hud = MockHud_.new()
    o.draw(hud, 10, 10)
    // 3 base lines (FPS / ms / 1%) + 2 counters.
    Expect.that(hud.labels.count).toBe(5)
    Expect.that(hud.rects.count).toBe(1)
    // Last two labels should mention the counter names.
    var labelText = hud.labels.join(" ")
    Expect.that(labelText.contains("entities")).toBe(true)
    Expect.that(labelText.contains("draws")).toBe(true)
  }

  Test.it("isEnabled = false suppresses draw output") {
    var o = DebugOverlay.new()
    o.isEnabled = false
    var hud = MockHud_.new()
    o.draw(hud, 10, 10)
    Expect.that(hud.labels.count).toBe(0)
    Expect.that(hud.rects.count).toBe(0)
  }

  Test.it("counter() returns 0 for unset names") {
    var o = DebugOverlay.new()
    Expect.that(o.counter("missing")).toBe(0)
    o.setCounter("set", 5)
    Expect.that(o.counter("set")).toBe(5)
    o.clearCounters()
    Expect.that(o.counter("set")).toBe(0)
  }
}

Test.run()
