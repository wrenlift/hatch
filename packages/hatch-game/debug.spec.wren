// @hatch:game/debug — FrameTimer + DebugOverlay + EntityInspector
// + PhysicsDebugDraw + InputRecorder / InputReplayer.

import "./debug"   for
  FrameTimer,
  DebugOverlay,
  EntityInspector,
  PhysicsDebugDraw,
  InputRecorder,
  InputReplayer
import "./scene"        for Transform, Collider
import "@hatch:ecs"     for World
import "@hatch:test"    for Test
import "@hatch:assert"  for Expect
import "@hatch:math"    for Vec3

// Lightweight HUD stub — records calls instead of drawing. Lets
// the spec verify a system invoked the right primitives without
// pulling in a real GPU.
class FakeHud {
  construct new() { _calls = [] }
  calls { _calls }
  rect(x, y, w, h, color) {
    _calls.add({ "op": "rect", "x": x, "y": y, "w": w, "h": h, "color": color })
  }
  border(x, y, w, h, thickness, color) {
    _calls.add({ "op": "border", "x": x, "y": y, "w": w, "h": h, "color": color })
  }
  label(text, x, y, scale, color) {
    _calls.add({ "op": "label", "text": text, "x": x, "y": y, "color": color })
  }
}

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

Test.describe("EntityInspector") {
  Test.it("starts hidden") {
    var i = EntityInspector.new()
    Expect.that(i.visible).toBe(false)
  }

  Test.it("toggle flips visible") {
    var i = EntityInspector.new()
    i.toggle
    Expect.that(i.visible).toBe(true)
    i.toggle
    Expect.that(i.visible).toBe(false)
  }

  Test.it("tick does nothing when hidden") {
    var i = EntityInspector.new()
    var w = World.new()
    var e = w.spawn()
    w.attach(e, Transform.new())
    i.tick(w)
    Expect.that(i.selectedEntity).toBe(null)
  }

  Test.it("tick snapshots entities when visible") {
    var i = EntityInspector.new()
    i.visible = true
    var w = World.new()
    var e = w.spawn()
    w.attach(e, Transform.new())
    i.tick(w)
    Expect.that(i.selectedEntity).toBe(e)
  }

  Test.it("scrollUp / scrollDown clamp at the ends") {
    var i = EntityInspector.new()
    i.visible = true
    var w = World.new()
    var a = w.spawn()
    var b = w.spawn()
    w.attach(a, Transform.new())
    w.attach(b, Transform.new())
    i.tick(w)
    var first = i.selectedEntity
    i.scrollUp  // already at top
    Expect.that(i.selectedEntity).toBe(first)
    i.scrollDown
    Expect.that(i.selectedEntity != first).toBe(true)
    i.scrollDown  // clamps at bottom
    Expect.that(i.selectedEntity != first).toBe(true)
  }

  Test.it("draw returns 0 when hidden, > 0 when visible") {
    var i = EntityInspector.new()
    var w = World.new()
    var e = w.spawn()
    w.attach(e, Transform.new())
    Expect.that(i.draw(FakeHud.new(), 0, 0)).toBe(0)
    i.visible = true
    i.tick(w)
    Expect.that(i.draw(FakeHud.new(), 0, 0) > 0).toBe(true)
  }
}

Test.describe("PhysicsDebugDraw") {
  Test.it("emits a border per box collider") {
    var w = World.new()
    var e = w.spawn()
    var t = Transform.new()
    t.position = Vec3.new(10, 20, 0)
    w.attach(e, t)
    w.attach(e, Collider.new({ "kind": "box", "halfWidth": 5, "halfHeight": 3 }))
    var hud = FakeHud.new()
    PhysicsDebugDraw.run(w, hud, Fn.new {|wx, wy| [wx, wy] })
    var borders = []
    for (c in hud.calls) {
      if (c["op"] == "border") borders.add(c)
    }
    Expect.that(borders.count).toBe(1)
    Expect.that(borders[0]["x"]).toBe(5)
    Expect.that(borders[0]["y"]).toBe(17)
    Expect.that(borders[0]["w"]).toBe(10)
    Expect.that(borders[0]["h"]).toBe(6)
  }

  Test.it("emits border + cross-hatch for ball colliders") {
    var w = World.new()
    var e = w.spawn()
    var t = Transform.new()
    t.position = Vec3.new(0, 0, 0)
    w.attach(e, t)
    w.attach(e, Collider.new({ "kind": "ball", "radius": 4 }))
    var hud = FakeHud.new()
    PhysicsDebugDraw.run(w, hud, Fn.new {|wx, wy| [wx, wy] })
    var borders = 0
    var rects = 0
    for (c in hud.calls) {
      if (c["op"] == "border") borders = borders + 1
      if (c["op"] == "rect")   rects   = rects   + 1
    }
    Expect.that(borders).toBe(1)
    Expect.that(rects).toBe(2)  // horizontal + vertical cross-hatch
  }

  Test.it("skips entities without colliders") {
    var w = World.new()
    var e = w.spawn()
    w.attach(e, Transform.new())
    var hud = FakeHud.new()
    PhysicsDebugDraw.run(w, hud, Fn.new {|wx, wy| [wx, wy] })
    Expect.that(hud.calls.count).toBe(0)
  }

  Test.it("skips unknown shape kinds") {
    var w = World.new()
    var e = w.spawn()
    w.attach(e, Transform.new())
    w.attach(e, Collider.new({ "kind": "polygon" }))
    var hud = FakeHud.new()
    PhysicsDebugDraw.run(w, hud, Fn.new {|wx, wy| [wx, wy] })
    Expect.that(hud.calls.count).toBe(0)
  }
}

Test.describe("InputRecorder / InputReplayer") {
  Test.it("records and exposes frame snapshots in order") {
    var r = InputRecorder.new()
    r.record({ "keys": ["Space"] })
    r.record({ "keys": ["KeyA"] })
    Expect.that(r.count).toBe(2)
    Expect.that(r.frames[0]["keys"][0]).toBe("Space")
  }

  Test.it("reset clears the recording") {
    var r = InputRecorder.new()
    r.record({})
    r.reset
    Expect.that(r.count).toBe(0)
  }

  Test.it("replayer walks frames in order") {
    var p = InputReplayer.new([{ "f": 1 }, { "f": 2 }, { "f": 3 }])
    Expect.that(p.hasNext).toBe(true)
    Expect.that(p.next["f"]).toBe(1)
    Expect.that(p.next["f"]).toBe(2)
    Expect.that(p.next["f"]).toBe(3)
    Expect.that(p.hasNext).toBe(false)
    Expect.that(p.next).toBe(null)
  }

  Test.it("replayer reset rewinds to start") {
    var p = InputReplayer.new([{ "f": 1 }, { "f": 2 }])
    p.next
    p.next
    p.reset
    Expect.that(p.cursor).toBe(0)
    Expect.that(p.next["f"]).toBe(1)
  }

  Test.it("replayer aborts on null frames argument") {
    var fiber = Fiber.new { InputReplayer.new(null) }
    Expect.that(fiber.try() is String).toBe(true)
  }
}

Test.run()
