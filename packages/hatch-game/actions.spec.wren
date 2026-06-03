// @hatch:game/actions — semantic input + FSM-bindable emitter.

import "./actions"     for Actions
import "@hatch:fsm"    for StateChart
import "@hatch:test"   for Test
import "@hatch:assert" for Expect

// Hand-rolled mock of the Input class — same surface
// (`isDown` / `mouseDown` / `justPressed` etc.) but driven from
// a per-frame "currently-down" set the test fixture mutates.
// Avoids needing a real winit / browser to drive these.
class MockInput {
  construct new() {
    _keys  = {}
    _mouse = {}
  }
  pressKey(k)     { _keys[k]  = true }
  releaseKey(k)   { _keys.remove(k) }
  pressMouse(b)   { _mouse[b] = true }
  releaseMouse(b) { _mouse.remove(b) }

  isDown(k)          { _keys.containsKey(k) }
  mouseDown(b)       { _mouse.containsKey(b) }
  // Action evaluation never touches the rest of Input's surface
  // (justPressed / mouseJustPressed are derived per-action), so
  // we stub them as no-ops here to keep the mock small.
}

Test.describe("Actions.define + polled queries") {
  Test.it("isDown / justPressed / justReleased follow the underlying input") {
    Actions.reset()
    Actions.define("jump", ["Space"])
    var input = MockInput.new()

    // Idle frame.
    Actions.update_(input)
    Expect.that(Actions.isDown("jump")).toBe(false)
    Expect.that(Actions.justPressed("jump")).toBe(false)
    Expect.that(Actions.justReleased("jump")).toBe(false)

    // Hold the binding.
    input.pressKey("Space")
    Actions.update_(input)
    Expect.that(Actions.isDown("jump")).toBe(true)
    Expect.that(Actions.justPressed("jump")).toBe(true)

    // Next frame still held but no edge.
    Actions.update_(input)
    Expect.that(Actions.isDown("jump")).toBe(true)
    Expect.that(Actions.justPressed("jump")).toBe(false)

    // Release.
    input.releaseKey("Space")
    Actions.update_(input)
    Expect.that(Actions.isDown("jump")).toBe(false)
    Expect.that(Actions.justReleased("jump")).toBe(true)
  }

  Test.it("multi-binding ORs sources (key OR mouse fires the action)") {
    Actions.reset()
    Actions.define("attack", ["KeyJ", "MouseLeft"])
    var input = MockInput.new()

    input.pressMouse("left")
    Actions.update_(input)
    Expect.that(Actions.justPressed("attack")).toBe(true)
    input.releaseMouse("left")
    Actions.update_(input)

    input.pressKey("KeyJ")
    Actions.update_(input)
    Expect.that(Actions.justPressed("attack")).toBe(true)
  }

  Test.it("value() returns 0 or 1 for button bindings") {
    Actions.reset()
    Actions.define("forward", ["KeyW"])
    var input = MockInput.new()
    Actions.update_(input)
    Expect.that(Actions.value("forward")).toBe(0)
    input.pressKey("KeyW")
    Actions.update_(input)
    Expect.that(Actions.value("forward")).toBe(1)
  }

  Test.it("unknown action name returns falsy defaults, never aborts") {
    Actions.reset()
    Expect.that(Actions.isDown("does-not-exist")).toBe(false)
    Expect.that(Actions.justPressed("does-not-exist")).toBe(false)
    Expect.that(Actions.value("does-not-exist")).toBe(0)
  }

  Test.it("gamepad bindings are accepted but inactive (return 0) without an axisMap") {
    Actions.reset()
    Actions.define("aim_right", ["GamepadAxisRX+"])
    var input = MockInput.new()
    Actions.update_(input)
    Expect.that(Actions.value("aim_right")).toBe(0)
  }

  Test.it("gamepad full-axis binding returns the raw axisMap value") {
    Actions.reset()
    Actions.define("aim_x", ["GamepadAxisLX"])
    var input = MockInput.new()
    Actions.update_(input, { "GamepadAxisLX": 0.4 })
    Expect.that(Actions.value("aim_x")).toBe(0.4)
    Actions.update_(input, { "GamepadAxisLX": -0.6 })
    Expect.that(Actions.value("aim_x")).toBe(-0.6)
  }

  Test.it("gamepad half-axis '+' returns only positive half rectified to 0..1") {
    Actions.reset()
    Actions.define("forward", ["GamepadAxisLY+"])
    var input = MockInput.new()
    // Negative half: no contribution.
    Actions.update_(input, { "GamepadAxisLY": -0.7 })
    Expect.that(Actions.value("forward")).toBe(0)
    // Positive half: passes through.
    Actions.update_(input, { "GamepadAxisLY": 0.6 })
    Expect.that(Actions.value("forward")).toBe(0.6)
  }

  Test.it("gamepad half-axis '-' returns only negative half rectified to 0..1") {
    Actions.reset()
    Actions.define("back", ["GamepadAxisLY-"])
    var input = MockInput.new()
    Actions.update_(input, { "GamepadAxisLY": 0.8 })
    Expect.that(Actions.value("back")).toBe(0)
    Actions.update_(input, { "GamepadAxisLY": -0.5 })
    Expect.that(Actions.value("back")).toBe(0.5)
  }
}

Test.describe("Actions rebinding") {
  Test.it("bind() replaces the binding list in place") {
    Actions.reset()
    Actions.define("jump", ["Space"])
    Expect.that(Actions.bindings("jump")[0]).toBe("Space")

    Actions.bind("jump", ["KeyJ"])
    Expect.that(Actions.bindings("jump").count).toBe(1)
    Expect.that(Actions.bindings("jump")[0]).toBe("KeyJ")

    var input = MockInput.new()
    input.pressKey("Space")
    Actions.update_(input)
    Expect.that(Actions.isDown("jump")).toBe(false)
    input.pressKey("KeyJ")
    Actions.update_(input)
    Expect.that(Actions.isDown("jump")).toBe(true)
  }

  Test.it("addBinding() appends without dropping existing entries") {
    Actions.reset()
    Actions.define("jump", ["Space"])
    Actions.addBinding("jump", "KeyJ")
    Expect.that(Actions.bindings("jump").count).toBe(2)
  }

  Test.it("clearBindings() empties the list but keeps the action registered") {
    Actions.reset()
    Actions.define("jump", ["Space"])
    Actions.clearBindings("jump")
    Expect.that(Actions.bindings("jump").count).toBe(0)
    Expect.that(Actions.isDown("jump")).toBe(false)
  }

  Test.it("remove() drops the action entirely") {
    Actions.reset()
    Actions.define("jump", ["Space"])
    Actions.remove("jump")
    Expect.that(Actions.bindings("jump").count).toBe(0)
  }
}

Test.describe("Actions event stream") {
  Test.it("emits the bare action name on press, '<name>.released' on release") {
    Actions.reset()
    Actions.define("jump", ["Space"])
    var calls = []
    Actions.on("jump") { calls.add("press") }
    Actions.onReleased("jump") { calls.add("release") }

    var input = MockInput.new()
    input.pressKey("Space")
    Actions.update_(input)
    Expect.that(calls.count).toBe(1)
    Expect.that(calls[0]).toBe("press")

    input.releaseKey("Space")
    Actions.update_(input)
    Expect.that(calls.count).toBe(2)
    Expect.that(calls[1]).toBe("release")
  }

  Test.it("only fires the press event once per edge (not every held frame)") {
    Actions.reset()
    Actions.define("jump", ["Space"])
    var n = 0
    Actions.on("jump") { n = n + 1 }

    var input = MockInput.new()
    input.pressKey("Space")
    Actions.update_(input)   // edge
    Actions.update_(input)   // still held — no second emit
    Actions.update_(input)
    Expect.that(n).toBe(1)
  }
}

Test.describe("Actions × StateChart") {
  Test.it("a chart bound to Actions.emitter transitions on the action's press event") {
    Actions.reset()
    Actions.define("jump", ["Space"])

    var chart = StateChart.build {|c|
      c.id("player")
      c.initial("ground")
      c.state("ground") {|s| s.on("jump", "air") }
      c.state("air")    {|s| s.on("land", "ground") }
    }
    chart.bindEvents(Actions.emitter, ["jump"])
    chart.start()

    Expect.that(chart.matches("ground")).toBe(true)

    var input = MockInput.new()
    input.pressKey("Space")
    Actions.update_(input)

    Expect.that(chart.matches("air")).toBe(true)
  }

  Test.it("release events ride a '<name>.released' channel that doesn't fire on press") {
    Actions.reset()
    Actions.define("attack", ["KeyJ"])

    var chart = StateChart.build {|c|
      c.id("p")
      c.initial("idle")
      c.state("idle")      {|s| s.on("attack", "attacking") }
      c.state("attacking") {|s| s.on("attack.released", "idle") }
    }
    chart.bindEvents(Actions.emitter, ["attack", "attack.released"])
    chart.start()

    var input = MockInput.new()
    input.pressKey("KeyJ")
    Actions.update_(input)
    Expect.that(chart.matches("attacking")).toBe(true)

    input.releaseKey("KeyJ")
    Actions.update_(input)
    Expect.that(chart.matches("idle")).toBe(true)
  }
}

Test.run()
