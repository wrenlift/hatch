// @hatch:hud — immediate-mode HUD overlay. Specs cover the
// font / measurement / button-hit-test logic; GPU-side draws
// (the real drawSpriteTinted calls) are exercised by a running
// game.

import "./hud"         for HUD, HUDPanel, BuiltinFont
import "@hatch:test"   for Test
import "@hatch:assert" for Expect

// ── Mocks ──────────────────────────────────────────────────────

class MockTexture {
  construct new() {}
  id { 0 }
}

class MockDevice {
  construct new() {}
  createTexture(desc) { MockTexture.new() }
  writeTexture(tex, bytes, desc) {}
}

class MockInput {
  construct new() {
    _mx = 0
    _my = 0
    _justPressed = {}
    _justReleased = {}
    _down = {}
  }
  mouseX             { _mx }
  mouseY             { _my }
  mouseDown(b)       { _down.containsKey(b) }
  mouseJustPressed(b)  { _justPressed.containsKey(b) }
  mouseJustReleased(b) { _justReleased.containsKey(b) }

  // Gamepad surface — minimal stub. Real `Input` exposes the same
  // shape from @hatch:game; HUD only reads these getters when a
  // gamepad event arrives so the mouse-only tests can return
  // false/empty without surprises.
  gamepadJustPressed(code)  { _gpPressed != null && _gpPressed.containsKey(code) }
  gamepadJustReleased(code) { _gpReleased != null && _gpReleased.containsKey(code) }
  gamepadDown(code)         { _gpDown != null && _gpDown.containsKey(code) }
  gamepadAxisMap            { _gpAxis }

  // Test helpers.
  pressGamepad(code) {
    if (_gpPressed == null) _gpPressed = {}
    if (_gpDown == null) _gpDown = {}
    _gpPressed[code] = true
    _gpDown[code] = true
  }
  releaseGamepad(code) {
    if (_gpReleased == null) _gpReleased = {}
    _gpReleased[code] = true
    if (_gpDown != null) _gpDown.remove(code)
  }
  setAxis(code, value) {
    if (_gpAxis == null) _gpAxis = {}
    _gpAxis[code] = value
  }

  moveTo(x, y) {
    _mx = x
    _my = y
  }
  pressLeft {
    _down["left"] = true
    _justPressed["left"] = true
  }
  releaseLeft {
    _down.remove("left")
    _justReleased["left"] = true
  }
  beginFrame {
    _justPressed = {}
    _justReleased = {}
    if (_gpPressed  != null) _gpPressed  = {}
    if (_gpReleased != null) _gpReleased = {}
  }
}

class MockGameState {
  construct new() {
    _device = MockDevice.new()
    _input  = MockInput.new()
  }
  device { _device }
  input  { _input }
  mockInput { _input }   // for spec convenience
}

class MockRenderer {
  construct new() { _calls = [] }
  calls { _calls }
  resetCalls() { _calls = [] }
  drawSprite(tex, x, y, w, h) {
    _calls.add({ "x": x, "y": y, "w": w, "h": h, "r": 1, "g": 1, "b": 1, "a": 1 })
  }
  drawSpriteTinted(tex, x, y, w, h, r, g, b, a) {
    _calls.add({ "x": x, "y": y, "w": w, "h": h, "r": r, "g": g, "b": b, "a": a })
  }
}

// ── BuiltinFont ────────────────────────────────────────────────

Test.describe("BuiltinFont") {
  Test.it("cellWidth / cellHeight / spacing are constant") {
    Expect.that(BuiltinFont.cellWidth).toBe(5)
    Expect.that(BuiltinFont.cellHeight).toBe(7)
    Expect.that(BuiltinFont.spacing).toBe(1)
  }

  Test.it("returns the 7-row bitmask for known glyphs") {
    var a = BuiltinFont.glyph("A")
    Expect.that(a.count).toBe(7)
    // 'A' row 3 is the crossbar: 5-wide XXXXX = 31.
    Expect.that(a[3]).toBe(31)
  }

  Test.it("falls back to space for unknown glyphs") {
    var unk = BuiltinFont.glyph("ÿ")    // not in the font table
    var space = BuiltinFont.glyph(" ")
    Expect.that(unk[0]).toBe(space[0])
    Expect.that(unk[3]).toBe(space[3])
  }

  Test.it("space is all zero rows") {
    var s = BuiltinFont.glyph(" ")
    var i = 0
    var allZero = true
    while (i < s.count) {
      if (s[i] != 0) allZero = false
      i = i + 1
    }
    Expect.that(allZero).toBe(true)
  }

  Test.it("digit 1 has a centred vertical stroke (col 2 set in most rows)") {
    var one = BuiltinFont.glyph("1")
    // bit 2 set = col 2 (centre)
    Expect.that(((one[2] / 4).floor % 2) == 1).toBe(true)
    Expect.that(((one[3] / 4).floor % 2) == 1).toBe(true)
    Expect.that(((one[4] / 4).floor % 2) == 1).toBe(true)
  }
}

// ── HUD.measure ────────────────────────────────────────────────

Test.describe("HUD.measure") {
  Test.it("empty string measures to [0, 0]") {
    var s = HUD.measure("", 1)
    Expect.that(s[0]).toBe(0)
    Expect.that(s[1]).toBe(0)
  }

  Test.it("scale 1: one char = cell width (no trailing spacing)") {
    var s = HUD.measure("A", 1)
    Expect.that(s[0]).toBe(BuiltinFont.cellWidth)
    Expect.that(s[1]).toBe(BuiltinFont.cellHeight)
  }

  Test.it("multiple chars include inter-glyph spacing but not after the last") {
    var s = HUD.measure("AB", 1)
    // 2 glyphs * (5 + 1) - 1 = 11
    Expect.that(s[0]).toBe(11)
  }

  Test.it("scale multiplies both axes uniformly") {
    var s1 = HUD.measure("HELLO", 1)
    var s3 = HUD.measure("HELLO", 3)
    Expect.that(s3[0]).toBe(s1[0] * 3)
    Expect.that(s3[1]).toBe(s1[1] * 3)
  }
}

// ── HUD.rect / HUD.label routing ───────────────────────────────

Test.describe("HUD.rect") {
  Test.it("queues one drawSpriteTinted with the tint color") {
    var g = MockGameState.new()
    var hud = HUD.new(g)
    var r = MockRenderer.new()
    hud.beginFrame(g, r)
    hud.rect(10, 20, 100, 50, [0.5, 0.6, 0.7, 0.8])
    hud.endFrame
    Expect.that(r.calls.count).toBe(1)
    Expect.that(r.calls[0]["x"]).toBe(10)
    Expect.that(r.calls[0]["y"]).toBe(20)
    Expect.that(r.calls[0]["w"]).toBe(100)
    Expect.that(r.calls[0]["h"]).toBe(50)
    Expect.that(r.calls[0]["r"]).toBe(0.5)
    Expect.that(r.calls[0]["a"]).toBe(0.8)
  }

  Test.it("aborts when called outside a frame") {
    var g = MockGameState.new()
    var hud = HUD.new(g)
    Expect.that(Fn.new { hud.rect(0, 0, 10, 10, [1, 1, 1, 1]) }).toAbort()
  }
}

Test.describe("HUD.border") {
  Test.it("emits four edge rectangles") {
    var g = MockGameState.new()
    var hud = HUD.new(g)
    var r = MockRenderer.new()
    hud.beginFrame(g, r)
    hud.border(0, 0, 100, 50, 2, [1, 0, 0, 1])
    hud.endFrame
    Expect.that(r.calls.count).toBe(4)
  }
}

Test.describe("HUD.label") {
  Test.it("emits one sprite per 'on' pixel in each glyph") {
    var g = MockGameState.new()
    var hud = HUD.new(g)
    var r = MockRenderer.new()
    hud.beginFrame(g, r)
    // Letter 'I' rows = [14, 4, 4, 4, 4, 4, 14] — bit counts:
    //   14 = 0b01110 → 3 pixels
    //   4  = 0b00100 → 1 pixel
    //   final 14 → 3 pixels
    //   middle 5 rows × 1 pixel = 5
    //   total = 3 + 5 + 3 = 11
    hud.label("I", 0, 0, 1)
    hud.endFrame
    Expect.that(r.calls.count).toBe(11)
  }

  Test.it("scale multiplies the per-pixel sprite size") {
    var g = MockGameState.new()
    var hud = HUD.new(g)
    var r = MockRenderer.new()
    hud.beginFrame(g, r)
    hud.label("I", 0, 0, 3)
    hud.endFrame
    // Every sprite should be 3×3 instead of 1×1.
    Expect.that(r.calls[0]["w"]).toBe(3)
    Expect.that(r.calls[0]["h"]).toBe(3)
  }

  Test.it("folds lowercase to uppercase before glyph lookup") {
    var g = MockGameState.new()
    var hud = HUD.new(g)
    var rA = MockRenderer.new()
    var ra = MockRenderer.new()
    hud.beginFrame(g, rA)
    hud.label("A", 0, 0, 1)
    hud.endFrame
    hud.beginFrame(g, ra)
    hud.label("a", 0, 0, 1)
    hud.endFrame
    Expect.that(rA.calls.count).toBe(ra.calls.count)
  }

  Test.it("custom color tints every emitted sprite") {
    var g = MockGameState.new()
    var hud = HUD.new(g)
    var r = MockRenderer.new()
    hud.beginFrame(g, r)
    hud.label("X", 0, 0, 1, [1, 0, 0, 1])
    hud.endFrame
    var i = 0
    var allRed = true
    while (i < r.calls.count) {
      if (r.calls[i]["r"] != 1) allRed = false
      if (r.calls[i]["g"] != 0) allRed = false
      if (r.calls[i]["a"] != 1) allRed = false
      i = i + 1
    }
    Expect.that(allRed).toBe(true)
  }
}

// ── HUD.button ─────────────────────────────────────────────────

Test.describe("HUD.button hit-testing") {
  Test.it("returns false when mouse hasn't clicked") {
    var g = MockGameState.new()
    var hud = HUD.new(g)
    var r = MockRenderer.new()
    g.mockInput.moveTo(50, 50)
    hud.beginFrame(g, r)
    var clicked = hud.button("OK", 20, 20, 100, 40)
    hud.endFrame
    Expect.that(clicked).toBe(false)
  }

  Test.it("returns true on press-then-release inside the button") {
    var g = MockGameState.new()
    var hud = HUD.new(g)
    var r = MockRenderer.new()

    // Frame 1: mouse inside, mouseDown.
    g.mockInput.moveTo(50, 30)
    g.mockInput.beginFrame
    g.mockInput.pressLeft
    hud.beginFrame(g, r)
    var c1 = hud.button("OK", 20, 20, 100, 40)
    hud.endFrame
    Expect.that(c1).toBe(false)

    // Frame 2: mouse still inside, mouseUp.
    g.mockInput.beginFrame
    g.mockInput.releaseLeft
    hud.beginFrame(g, r)
    var c2 = hud.button("OK", 20, 20, 100, 40)
    hud.endFrame
    Expect.that(c2).toBe(true)
  }

  Test.it("returns false if release happens outside the button") {
    var g = MockGameState.new()
    var hud = HUD.new(g)
    var r = MockRenderer.new()

    // Frame 1: mouse inside, mouseDown.
    g.mockInput.moveTo(50, 30)
    g.mockInput.beginFrame
    g.mockInput.pressLeft
    hud.beginFrame(g, r)
    hud.button("OK", 20, 20, 100, 40)
    hud.endFrame

    // Frame 2: mouse moved outside, mouseUp.
    g.mockInput.moveTo(500, 500)
    g.mockInput.beginFrame
    g.mockInput.releaseLeft
    hud.beginFrame(g, r)
    var c2 = hud.button("OK", 20, 20, 100, 40)
    hud.endFrame
    Expect.that(c2).toBe(false)
  }

  Test.it("right-edge exclusive: mouse exactly on x+w isn't hovering") {
    var g = MockGameState.new()
    var hud = HUD.new(g)
    var r = MockRenderer.new()

    g.mockInput.moveTo(120, 25)        // x+w = 120 (exclusive)
    g.mockInput.beginFrame
    g.mockInput.pressLeft
    hud.beginFrame(g, r)
    var c1 = hud.button("OK", 20, 20, 100, 40)
    hud.endFrame

    g.mockInput.beginFrame
    g.mockInput.releaseLeft
    hud.beginFrame(g, r)
    var c2 = hud.button("OK", 20, 20, 100, 40)
    hud.endFrame

    // Press wasn't registered as hovering → release returns false.
    Expect.that(c1).toBe(false)
    Expect.that(c2).toBe(false)
  }
}

// ── HUDPanel ───────────────────────────────────────────────────

Test.describe("HUDPanel slider") {
  Test.it("mutates obj[key] when the track is clicked + dragged") {
    var g = MockGameState.new()
    var r = MockRenderer.new()
    var hud = HUD.new(g)
    var panel = HUDPanel.new(hud, { "x": 0, "y": 0, "width": 240 })
    var state = { "amp": 0.0 }

    // Mouse at the *middle* of the slider track. With width 240,
    // pad 8, labelW 80, pad 8: trackX = 0 + 8 + 80 + 8 = 96;
    // trackW = 0 + 240 - 8 - 96 = 136. Midpoint = 96 + 68 = 164.
    // Slider row sits at y = PAD_ (8) of the first row (no title).
    g.mockInput.moveTo(164, 18)
    g.mockInput.pressLeft
    hud.beginFrame(g, r)
    panel.beginFrame()
    panel.slider("amp", state, "amp", 0.0, 1.0)
    hud.endFrame

    // 50%% of [0, 1] → 0.5.
    Expect.that(state["amp"] > 0.45 && state["amp"] < 0.55).toBe(true)

    // Drag to the right edge: should clamp to max.
    g.mockInput.beginFrame
    g.mockInput.moveTo(9999, 18)
    hud.beginFrame(g, r)
    panel.beginFrame()
    panel.slider("amp", state, "amp", 0.0, 1.0)
    hud.endFrame
    Expect.that(state["amp"]).toBe(1.0)

    // Release outside the track: subsequent frames stop mutating
    // because the active-slider state cleared.
    g.mockInput.beginFrame
    g.mockInput.releaseLeft
    g.mockInput.moveTo(-1, -1)
    hud.beginFrame(g, r)
    panel.beginFrame()
    panel.slider("amp", state, "amp", 0.0, 1.0)
    hud.endFrame
    Expect.that(state["amp"]).toBe(1.0)
  }
}

Test.describe("HUDPanel toggle") {
  Test.it("flips obj[key] on click") {
    var g = MockGameState.new()
    var r = MockRenderer.new()
    var hud = HUD.new(g)
    var panel = HUDPanel.new(hud, { "x": 0, "y": 0, "width": 200 })
    var state = { "shadows": false }

    g.mockInput.moveTo(100, 18)   // anywhere inside the row
    g.mockInput.pressLeft
    hud.beginFrame(g, r)
    panel.beginFrame()
    panel.toggle("shadows", state, "shadows")
    hud.endFrame
    Expect.that(state["shadows"]).toBe(true)

    // Second press flips it back.
    g.mockInput.beginFrame
    g.mockInput.releaseLeft
    g.mockInput.beginFrame
    g.mockInput.pressLeft
    hud.beginFrame(g, r)
    panel.beginFrame()
    panel.toggle("shadows", state, "shadows")
    hud.endFrame
    Expect.that(state["shadows"]).toBe(false)
  }
}

Test.describe("HUDPanel button") {
  Test.it("invokes the callback on a click cycle") {
    var g = MockGameState.new()
    var r = MockRenderer.new()
    var hud = HUD.new(g)
    var panel = HUDPanel.new(hud, { "x": 0, "y": 0, "width": 200 })
    var pressed = [false]

    g.mockInput.moveTo(100, 18)
    g.mockInput.pressLeft
    hud.beginFrame(g, r)
    panel.beginFrame()
    panel.button("reset", Fn.new { pressed[0] = true })
    hud.endFrame
    // Press alone doesn't fire — needs the matching release.
    Expect.that(pressed[0]).toBe(false)

    g.mockInput.beginFrame
    g.mockInput.releaseLeft
    hud.beginFrame(g, r)
    panel.beginFrame()
    panel.button("reset", Fn.new { pressed[0] = true })
    hud.endFrame
    Expect.that(pressed[0]).toBe(true)
  }
}

Test.describe("HUDPanel text + divider") {
  Test.it("text renders without aborting + accepts a Num value") {
    var g = MockGameState.new()
    var r = MockRenderer.new()
    var hud = HUD.new(g)
    var panel = HUDPanel.new(hud, { "x": 0, "y": 0, "width": 200 })
    hud.beginFrame(g, r)
    panel.beginFrame()
    panel.text("FPS", 60)
    panel.divider()
    panel.text("cubes", "1234")
    hud.endFrame
  }
}

Test.describe("HUD gamepad navigation") {
  Test.it("registers focusable widgets in draw order across frames") {
    var g = MockGameState.new()
    var r = MockRenderer.new()
    var hud = HUD.new(g)

    // First frame: draw three buttons, no focus stepped yet.
    hud.beginFrame(g, r)
    hud.button("A", 10, 10, 80, 40)
    hud.button("B", 10, 60, 80, 40)
    hud.button("C", 10, 110, 80, 40)

    // Reset MockInput edge state between frames, step focus once
    // (DPad down → first focusable). On the SECOND frame, focused
    // button should be "A".
    g.input.beginFrame
    g.input.pressGamepad("GamepadDPadDown")

    hud.beginFrame(g, r)
    var pressedA = hud.button("A", 10, 10, 80, 40)
    var pressedB = hud.button("B", 10, 60, 80, 40)
    var pressedC = hud.button("C", 10, 110, 80, 40)
    // No press happens until ButtonA fires — DPad only moves focus.
    Expect.that(pressedA).toBe(false)
    Expect.that(pressedB).toBe(false)
    Expect.that(pressedC).toBe(false)
  }

  Test.it("GamepadButtonA presses the focused widget") {
    var g = MockGameState.new()
    var r = MockRenderer.new()
    var hud = HUD.new(g)

    // Frame 1: register the focusable set.
    hud.beginFrame(g, r)
    hud.button("A", 10, 10, 80, 40)
    hud.button("B", 10, 60, 80, 40)

    // Step focus to "A" (DPad down once on the next beginFrame).
    g.input.beginFrame
    g.input.pressGamepad("GamepadDPadDown")
    hud.beginFrame(g, r)
    hud.button("A", 10, 10, 80, 40)
    hud.button("B", 10, 60, 80, 40)

    // Frame 3: press A while still focused on the first button.
    g.input.beginFrame
    g.input.pressGamepad("GamepadButtonA")
    hud.beginFrame(g, r)
    var pressedA = hud.button("A", 10, 10, 80, 40)
    var pressedB = hud.button("B", 10, 60, 80, 40)
    Expect.that(pressedA).toBe(true)
    Expect.that(pressedB).toBe(false)
  }

  Test.it("DPadUp wraps focus when going past the start") {
    var g = MockGameState.new()
    var r = MockRenderer.new()
    var hud = HUD.new(g)

    hud.beginFrame(g, r)
    hud.button("X", 0, 0, 1, 1)
    hud.button("Y", 0, 0, 1, 2)

    // Up from "no focus" should land on the LAST entry (wrap).
    g.input.beginFrame
    g.input.pressGamepad("GamepadDPadUp")
    hud.beginFrame(g, r)
    hud.button("X", 0, 0, 1, 1)
    hud.button("Y", 0, 0, 1, 2)
    g.input.beginFrame
    g.input.pressGamepad("GamepadButtonA")
    hud.beginFrame(g, r)
    var pX = hud.button("X", 0, 0, 1, 1)
    var pY = hud.button("Y", 0, 0, 1, 2)
    Expect.that(pX).toBe(false)
    Expect.that(pY).toBe(true)
  }
}

Test.run()
