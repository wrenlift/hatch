// @hatch:game/animation — tweens, clips, AnimationPlayer, FSM binding.

import "./animation"   for Tween, Tweens, Clip, AnimationPlayer, Behaviors
import "./actions"     for Actions
import "@hatch:events" for EventEmitter
import "@hatch:fsm"    for StateChart
import "@hatch:test"   for Test
import "@hatch:assert" for Expect

Test.describe("Tween basic interpolation") {
  Test.it("linear tween hits midpoint at 50% time") {
    Tweens.cancelAll()
    var last = 0
    Tweens.add(Tween.new({
      "from":     0,
      "to":       10,
      "duration": 1.0,
      "onUpdate": Fn.new {|v| last = v }
    }))
    Tweens.update(0.5)
    // Floating-point comparison: ±0.0001.
    Expect.that((last - 5).abs < 0.0001).toBe(true)
  }

  Test.it("non-looping tween finishes after duration and fires onComplete") {
    Tweens.cancelAll()
    var last = 0
    var completed = false
    Tweens.add(Tween.new({
      "from":       0,
      "to":         1,
      "duration":   0.5,
      "onUpdate":   Fn.new {|v| last = v },
      "onComplete": Fn.new { completed = true }
    }))
    Tweens.update(0.6)
    Expect.that(last).toBe(1)
    Expect.that(completed).toBe(true)
    Expect.that(Tweens.count).toBe(0)
  }

  Test.it("looping tween wraps around and stays scheduled") {
    Tweens.cancelAll()
    var samples = []
    Tweens.add(Tween.new({
      "from":     0,
      "to":       1,
      "duration": 0.5,
      "loop":     true,
      "onUpdate": Fn.new {|v| samples.add(v) }
    }))
    Tweens.update(0.25)            // halfway through lap 1
    Tweens.update(0.5)             // wraps into lap 2
    Expect.that(samples.count).toBe(2)
    Expect.that(Tweens.count).toBe(1)
    Tweens.cancelAll()
  }

  Test.it("delay defers updates until elapsed > delay") {
    Tweens.cancelAll()
    var fires = 0
    Tweens.add(Tween.new({
      "from":     0,
      "to":       1,
      "duration": 0.5,
      "delay":    0.5,
      "onUpdate": Fn.new {|v| fires = fires + 1 }
    }))
    Tweens.update(0.3)             // still in delay window
    Expect.that(fires).toBe(0)
    Tweens.update(0.4)             // delay elapsed, tween steps
    Expect.that(fires > 0).toBe(true)
    Tweens.cancelAll()
  }

  Test.it("rejects non-Map opts") {
    Expect.that(Fn.new { Tween.new("oops") }).toAbort()
  }
}

Test.describe("Tween easing") {
  Test.it("outCubic curves above linear in the first half") {
    Tweens.cancelAll()
    var lin = 0
    var eased = 0
    Tweens.add(Tween.new({
      "from": 0, "to": 1, "duration": 1.0,
      "onUpdate": Fn.new {|v| lin = v }
    }))
    Tweens.add(Tween.new({
      "from": 0, "to": 1, "duration": 1.0,
      "easing": "outCubic",
      "onUpdate": Fn.new {|v| eased = v }
    }))
    Tweens.update(0.25)
    // outCubic(0.25) ≈ 0.578; linear(0.25) = 0.25
    Expect.that(eased > lin).toBe(true)
    Tweens.cancelAll()
  }

  Test.it("Fn easing is honoured") {
    Tweens.cancelAll()
    var last = 0
    // Custom step function: 0 until t == 1, then 1.
    var step = Fn.new {|t| t >= 1 ? 1 : 0 }
    Tweens.add(Tween.new({
      "from": 0, "to": 10, "duration": 1.0,
      "easing": step,
      "onUpdate": Fn.new {|v| last = v }
    }))
    Tweens.update(0.5)
    Expect.that(last).toBe(0)
    Tweens.cancelAll()
  }

  Test.it("unknown easing string aborts") {
    Tweens.cancelAll()
    var t = Tween.new({
      "from": 0, "to": 1, "duration": 1.0,
      "easing": "easeOutNothing",
      "onUpdate": Fn.new {|v| }
    })
    Tweens.add(t)
    Expect.that(Fn.new { Tweens.update(0.5) }).toAbort()
    Tweens.cancelAll()
  }
}

Test.describe("Tween chaining") {
  Test.it(".then runs next tween only after the first completes") {
    Tweens.cancelAll()
    var aValue = 0
    var bValue = 0
    var bStarted = false
    var a = Tween.new({
      "from": 0, "to": 1, "duration": 0.5,
      "onUpdate": Fn.new {|v| aValue = v }
    })
    var b = Tween.new({
      "from": 10, "to": 20, "duration": 0.5,
      "onUpdate": Fn.new {|v|
        bValue   = v
        bStarted = true
      }
    })
    Tweens.add(a.then(b))
    Tweens.update(0.25)
    Expect.that(bStarted).toBe(false)
    Tweens.update(0.5)            // a done; b queued for next tick
    Expect.that(aValue).toBe(1)
    Tweens.update(0.25)            // b starts
    Expect.that(bStarted).toBe(true)
    Tweens.cancelAll()
  }

  Test.it(".also runs siblings in parallel") {
    Tweens.cancelAll()
    var aSeen = 0
    var bSeen = 0
    var a = Tween.new({
      "from": 0, "to": 1, "duration": 1.0,
      "onUpdate": Fn.new {|v| aSeen = aSeen + 1 }
    })
    var b = Tween.new({
      "from": 10, "to": 20, "duration": 1.0,
      "onUpdate": Fn.new {|v| bSeen = bSeen + 1 }
    })
    Tweens.add(a.also(b))
    Tweens.update(0.1)
    Expect.that(aSeen > 0).toBe(true)
    Expect.that(bSeen > 0).toBe(true)
    Tweens.cancelAll()
  }
}

Test.describe("Clip.sample") {
  Test.it("returns the only keyframe value when a track has one entry") {
    var clip = Clip.new("x", 1.0, {
      "pos": [[0, 7]]
    })
    var s = clip.sample(0.5)
    Expect.that(s["pos"]).toBe(7)
  }

  Test.it("linearly interpolates between keyframes") {
    var clip = Clip.new("x", 1.0, {
      "alpha": [[0, 0], [1.0, 10]]
    })
    var s = clip.sample(0.5)
    Expect.that(s["alpha"]).toBe(5)
  }

  Test.it("clamps t outside duration to the bounds") {
    var clip = Clip.new("x", 1.0, {
      "alpha": [[0, 0], [1.0, 10]]
    })
    Expect.that(clip.sample(-1)["alpha"]).toBe(0)
    Expect.that(clip.sample(99)["alpha"]).toBe(10)
  }
}

Test.describe("AnimationPlayer") {
  Test.it("play() routes samples through onSample") {
    var seen = null
    var player = AnimationPlayer.new()
    player.add(Clip.new("walk", 1.0, {
      "leg": [[0, 0], [1.0, 90]]
    }))
    player.onSample(Fn.new {|tracks| seen = tracks })
    player.play("walk")
    player.update(0.5)
    Expect.that(seen["leg"]).toBe(45)
    Expect.that(player.current["leg"]).toBe(45)
  }

  Test.it("non-looping clip snaps to end + emits 'complete'") {
    var player = AnimationPlayer.new()
    player.add(Clip.new("once", 1.0, {
      "x": [[0, 0], [1.0, 10]]
    }))
    player.loop = false
    var done = null
    player.events.on("complete", Fn.new {|name| done = name })
    player.play("once")
    player.update(2.0)
    Expect.that(done).toBe("once")
    Expect.that(player.current["x"]).toBe(10)
  }

  Test.it("crossfade blends between source and target clips") {
    var player = AnimationPlayer.new()
    player.add(Clip.new("a", 1.0, { "v": [[0, 0],  [1.0, 0]] }))
    player.add(Clip.new("b", 1.0, { "v": [[0, 100],[1.0, 100]] }))
    player.play("a")
    player.update(0.01)
    Expect.that(player.current["v"]).toBe(0)
    player.crossfade("b", 1.0)
    player.update(0.5)
    var v = player.current["v"]
    Expect.that(v > 30 && v < 70).toBe(true)
  }

  Test.it("speed=2 advances twice as fast as wall-clock") {
    var seen = null
    var player = AnimationPlayer.new()
    player.add(Clip.new("walk", 1.0, {
      "leg": [[0, 0], [1.0, 100]]
    }))
    player.speed = 2
    player.onSample(Fn.new {|tracks| seen = tracks })
    player.play("walk")
    player.update(0.25)
    Expect.that(seen["leg"]).toBe(50)
  }
}

Test.describe("AnimationPlayer.bindStateChart") {
  Test.it("plays the mapped clip on chart transition") {
    var player = AnimationPlayer.new()
    player.add(Clip.new("idle", 1.0, { "leg": [[0, 0], [1.0, 0]]  }))
    player.add(Clip.new("run",  1.0, { "leg": [[0, 0], [1.0, 90]] }))

    var chart = StateChart.build {|c|
      c.id("player")
      c.initial("ground")
      c.state("ground") {|s| s.on("go", "running") }
      c.state("running") {|s| s.on("stop", "ground") }
    }

    // fade=0 — snap so the next update samples the new clip cleanly.
    player.bindStateChart(chart, { "ground": "idle", "running": "run" }, 0)
    chart.start()
    chart.send("go")
    player.update(0.5)
    Expect.that(player.current["leg"]).toBe(45)

    chart.send("stop")
    player.update(0.5)
    Expect.that(player.current["leg"]).toBe(0)
  }
}

Test.describe("Behaviors.wire (facade)") {
  Test.it("requires a chart") {
    Expect.that(Fn.new { Behaviors.wire({}) }).toAbort()
  }

  Test.it("rejects non-Map opts") {
    Expect.that(Fn.new { Behaviors.wire("nope") }).toAbort()
  }

  Test.it("forwards actions from a custom emitter into the chart") {
    var em = EventEmitter.new()
    var chart = StateChart.build {|c|
      c.id("door")
      c.initial("closed")
      c.state("closed") {|s| s.on("open", "open") }
      c.state("open")   {|s| s.on("close", "closed") }
    }
    Behaviors.wire({
      "chart":   chart,
      "actions": ["open", "close"],
      "emitter": em
    })
    chart.start()
    em.emit("open")
    Expect.that(chart.activeStates.contains("open")).toBe(true)
    em.emit("close")
    Expect.that(chart.activeStates.contains("closed")).toBe(true)
  }

  Test.it("only-player wire still swaps clips on chart transition") {
    var chart = StateChart.build {|c|
      c.id("anim")
      c.initial("a")
      c.state("a") {|s| s.on("go", "b") }
      c.state("b") {|s|}
    }
    var player = AnimationPlayer.new()
    player.add(Clip.new("clipA", 1.0, { "v": [[0, 0], [1.0, 0]]  }))
    player.add(Clip.new("clipB", 1.0, { "v": [[0, 9], [1.0, 9]]  }))

    Behaviors.wire({
      "chart":  chart,
      "player": player,
      "clips":  { "a": "clipA", "b": "clipB" },
      "fade":   0
    })
    chart.start()
    // Force first sample so we get clipA's value.
    player.play("clipA")
    player.update(0.1)
    Expect.that(player.current["v"]).toBe(0)
    chart.send("go")
    player.update(0.1)
    Expect.that(player.current["v"]).toBe(9)
  }

  Test.it("player without clips aborts (catches the typo case)") {
    var chart = StateChart.build {|c|
      c.id("a")
      c.initial("x")
      c.state("x") {|s|}
    }
    var player = AnimationPlayer.new()
    Expect.that(Fn.new {
      Behaviors.wire({ "chart": chart, "player": player })
    }).toAbort()
  }

  Test.it("full wire: Actions → chart → player in one call") {
    Actions.reset()
    Actions.define("run", ["KeyR"])

    var chart = StateChart.build {|c|
      c.id("p")
      c.initial("idle")
      c.state("idle")    {|s| s.on("run",  "running") }
      c.state("running") {|s| s.on("stop", "idle")    }
    }
    var player = AnimationPlayer.new()
    player.add(Clip.new("idle", 1.0, { "leg": [[0, 0], [1.0, 0]]   }))
    player.add(Clip.new("run",  1.0, { "leg": [[0, 0], [1.0, 100]] }))

    Behaviors.wire({
      "chart":   chart,
      "player":  player,
      "actions": ["run", "stop"],
      "clips":   { "idle": "idle", "running": "run" },
      "fade":    0
    })
    chart.start()

    // Emit the "run" event directly on Actions.emitter (the
    // default emitter the facade picks up). Drives chart →
    // crossfade in one hop, no intermediate glue.
    Actions.emitter.emit("run")
    player.update(0.5)
    Expect.that(player.current["leg"]).toBe(50)
  }
}

Test.run()
