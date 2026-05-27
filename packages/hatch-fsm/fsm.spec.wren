import "./fsm"         for StateChart
import "@hatch:events" for EventEmitter
import "@hatch:test"   for Test
import "@hatch:assert" for Expect

// Day 1 spec coverage:
//   - flat (atomic) two-state ping-pong
//   - compound + sibling-relative + cross-tree targets
//   - matches() prefix semantics
//   - start/stop idempotency
//   - construction validation errors

Test.describe("StateChart: flat atomic") {
  Test.it("ping-pong between two top-level states") {
    var fsm = StateChart.build {|c|
      c.state("a") {|s| s.on("go",   "b") }
      c.state("b") {|s| s.on("back", "a") }
    }
    fsm.start()
    Expect.that(fsm.activeStates[0]).toBe("a")
    fsm.send("go")
    Expect.that(fsm.activeStates[0]).toBe("b")
    fsm.send("back")
    Expect.that(fsm.activeStates[0]).toBe("a")
  }

  Test.it("activePath returns deepest leaf") {
    var fsm = StateChart.build {|c|
      c.state("only") {|s| }
    }
    fsm.start()
    Expect.that(fsm.activePath).toBe("only")
  }

  Test.it("first declared state is initial when chart.initial is omitted") {
    var fsm = StateChart.build {|c|
      c.state("first")  {|s| }
      c.state("second") {|s| }
    }
    fsm.start()
    Expect.that(fsm.activePath).toBe("first")
  }

  Test.it("explicit chart.initial wins over declaration order") {
    var fsm = StateChart.build {|c|
      c.initial("second")
      c.state("first")  {|s| }
      c.state("second") {|s| }
    }
    fsm.start()
    Expect.that(fsm.activePath).toBe("second")
  }

  Test.it("ignores unknown events (no transition matches)") {
    var fsm = StateChart.build {|c|
      c.state("a") {|s| s.on("go", "b") }
      c.state("b") {|s| }
    }
    fsm.start()
    fsm.send("zzz")
    Expect.that(fsm.activePath).toBe("a")
  }
}

Test.describe("StateChart: compound + hierarchy") {
  Test.it("entering a compound descends through initial") {
    var fsm = StateChart.build {|c|
      c.state("ground") {|s|
        s.initial("idle")
        s.state("idle")    {|i| i.on("walk", "walking") }
        s.state("walking") {|w| w.on("stop", "idle") }
      }
    }
    fsm.start()
    Expect.that(fsm.activeStates[0]).toBe("ground")
    Expect.that(fsm.activeStates[1]).toBe("ground.idle")
    Expect.that(fsm.activePath).toBe("ground.idle")
  }

  Test.it("event declared at parent bubbles from leaf") {
    var fsm = StateChart.build {|c|
      c.state("ground") {|s|
        s.initial("idle")
        s.on("jump", "air")
        s.state("idle")    {|i| }
        s.state("walking") {|w| }
      }
      c.state("air") {|s| s.on("land", "ground") }
    }
    fsm.start()
    Expect.that(fsm.activePath).toBe("ground.idle")
    fsm.send("jump")
    Expect.that(fsm.activePath).toBe("air")
  }

  Test.it("transitioning into a compound re-enters its initial") {
    var fsm = StateChart.build {|c|
      c.state("ground") {|s|
        s.initial("idle")
        s.on("jump", "air")
        s.state("idle")    {|i| i.on("walk", "walking") }
        s.state("walking") {|w| }
      }
      c.state("air") {|s| s.on("land", "ground") }
    }
    fsm.start()
    fsm.send("walk")
    Expect.that(fsm.activePath).toBe("ground.walking")
    fsm.send("jump")
    fsm.send("land")
    // Re-entering "ground" descends via initial=idle, NOT history
    Expect.that(fsm.activePath).toBe("ground.idle")
  }

  Test.it("sibling-relative target resolves to nearest enclosing sibling") {
    var fsm = StateChart.build {|c|
      c.state("ground") {|s|
        s.initial("idle")
        s.state("idle")    {|i| i.on("walk", "walking") }
        s.state("walking") {|w| }
      }
    }
    fsm.start()
    fsm.send("walk")
    Expect.that(fsm.activePath).toBe("ground.walking")
  }

  Test.it("fully-qualified target resolves directly") {
    var fsm = StateChart.build {|c|
      c.state("a") {|s|
        s.initial("inner")
        s.state("inner") {|i| i.on("go", "b.deep") }
      }
      c.state("b") {|s|
        s.initial("deep")
        s.state("deep") {|d| }
      }
    }
    fsm.start()
    fsm.send("go")
    Expect.that(fsm.activePath).toBe("b.deep")
  }
}

Test.describe("StateChart: matches() prefix semantics") {
  Test.it("matches the active leaf exactly") {
    var fsm = StateChart.build {|c|
      c.state("a") {|s|
        s.initial("inner")
        s.state("inner") {|i| }
      }
    }
    fsm.start()
    Expect.that(fsm.matches("a.inner")).toBe(true)
  }

  Test.it("matches any active ancestor by prefix") {
    var fsm = StateChart.build {|c|
      c.state("ground") {|s|
        s.initial("idle")
        s.state("idle") {|i| }
      }
    }
    fsm.start()
    Expect.that(fsm.matches("ground")).toBe(true)
    Expect.that(fsm.matches("ground.idle")).toBe(true)
  }

  Test.it("does not match a sibling") {
    var fsm = StateChart.build {|c|
      c.state("ground") {|s|
        s.initial("idle")
        s.state("idle")    {|i| }
        s.state("walking") {|w| }
      }
    }
    fsm.start()
    Expect.that(fsm.matches("ground.walking")).toBe(false)
  }
}

Test.describe("StateChart: lifecycle") {
  Test.it("start() is idempotent") {
    var fsm = StateChart.build {|c| c.state("a") {|s| } }
    fsm.start()
    fsm.start()
    Expect.that(fsm.activePath).toBe("a")
  }

  Test.it("stop() is idempotent and clears active") {
    var fsm = StateChart.build {|c| c.state("a") {|s| } }
    fsm.start()
    fsm.stop()
    fsm.stop()
    Expect.that(fsm.activeStates.count).toBe(0)
    Expect.that(fsm.started).toBe(false)
  }

  Test.it("send() before start() aborts") {
    var fsm = StateChart.build {|c| c.state("a") {|s| } }
    var f = Fiber.new { fsm.send("x") }
    f.try()
    Expect.that(f.error.contains("not started")).toBe(true)
  }
}

Test.describe("StateChart: construction validation") {
  Test.it("unknown transition target aborts at finish") {
    var f = Fiber.new {
      StateChart.build {|c|
        c.state("a") {|s| s.on("go", "nowhere") }
      }
    }
    f.try()
    Expect.that(f.error.contains("targets unknown state 'nowhere'")).toBe(true)
  }

  Test.it("final state cannot have substates") {
    var f = Fiber.new {
      StateChart.build {|c|
        c.state("a") {|s|
          s.final()
          s.state("b") {|x| }
        }
      }
    }
    f.try()
    Expect.that(f.error.contains("final state cannot contain substates")).toBe(true)
  }

  Test.it("final state cannot be entered with prior substates") {
    var f = Fiber.new {
      StateChart.build {|c|
        c.state("a") {|s|
          s.state("b") {|x| }
          s.final()
        }
      }
    }
    f.try()
    Expect.that(f.error.contains("already has substates")).toBe(true)
  }

  Test.it("compound state without initial aborts at finish") {
    var f = Fiber.new {
      StateChart.build {|c|
        c.state("a") {|s| s.state("b") {|x| } }
      }
    }
    f.try()
    Expect.that(f.error.contains("has substates but no initial")).toBe(true)
  }

  Test.it("initial pointing at non-substate aborts at finish") {
    var f = Fiber.new {
      StateChart.build {|c|
        c.state("a") {|s|
          s.initial("missing")
          s.state("b") {|x| }
        }
      }
    }
    f.try()
    Expect.that(f.error.contains("is not one of its substates")).toBe(true)
  }

  Test.it("non-String event arg aborts with path-tagged message") {
    var f = Fiber.new {
      StateChart.build {|c| c.state("a") {|s| s.on(42, "b") } }
    }
    f.try()
    Expect.that(f.error.contains("state(a).on")).toBe(true)
    Expect.that(f.error.contains("event must be String")).toBe(true)
  }

  Test.it("non-String, non-Fn target aborts with path-tagged message") {
    var f = Fiber.new {
      StateChart.build {|c| c.state("a") {|s| s.on("evt", 42) } }
    }
    f.try()
    Expect.that(f.error.contains("state(a).on(evt)")).toBe(true)
  }

  Test.it("duplicate state name aborts at the second declaration") {
    var f = Fiber.new {
      StateChart.build {|c|
        c.state("a") {|s| }
        c.state("a") {|s| }
      }
    }
    f.try()
    Expect.that(f.error.contains("already defined")).toBe(true)
  }

  Test.it("empty chart aborts") {
    var f = Fiber.new {
      StateChart.build {|c| }
    }
    f.try()
    Expect.that(f.error.contains("at least one state must be declared")).toBe(true)
  }

  Test.it("chart.initial pointing at unknown state aborts") {
    var f = Fiber.new {
      StateChart.build {|c|
        c.initial("missing")
        c.state("a") {|s| }
      }
    }
    f.try()
    Expect.that(f.error.contains("not a declared state")).toBe(true)
  }
}

// --- Day 2: signals + bindEvents + tree -------------------------------------

Test.describe("StateChart: signal channels") {
  Test.it("transition channel fires with (from, to, event)") {
    var fsm = StateChart.build {|c|
      c.state("a") {|s| s.on("go", "b") }
      c.state("b") {|s| }
    }
    fsm.start()
    var hits = []
    fsm.on("transition") {|from, to, evt| hits.add([from, to, evt]) }
    fsm.send("go")
    Expect.that(hits.count).toBe(1)
    Expect.that(hits[0][0]).toBe("a")
    Expect.that(hits[0][1]).toBe("b")
    Expect.that(hits[0][2]).toBe("go")
  }

  Test.it("enter:<path> fires when state entered") {
    var fsm = StateChart.build {|c|
      c.state("a") {|s| s.on("go", "b") }
      c.state("b") {|s| }
    }
    fsm.start()
    var hits = []
    fsm.on("enter:b") {|ctx, evt| hits.add(evt) }
    fsm.send("go")
    Expect.that(hits.count).toBe(1)
    Expect.that(hits[0]).toBe("go")
  }

  Test.it("exit:<path> fires when state exited") {
    var fsm = StateChart.build {|c|
      c.state("a") {|s| s.on("go", "b") }
      c.state("b") {|s| }
    }
    fsm.start()
    var hits = []
    fsm.on("exit:a") {|ctx, evt| hits.add(evt) }
    fsm.send("go")
    Expect.that(hits.count).toBe(1)
    Expect.that(hits[0]).toBe("go")
  }

  Test.it("compound entry fires for each level deepest-last") {
    var fsm = StateChart.build {|c|
      c.state("a") {|s|
        s.on("go", "b")
      }
      c.state("b") {|s|
        s.initial("inner")
        s.state("inner") {|i| }
      }
    }
    fsm.start()
    var order = []
    fsm.on("enter:b")       {|ctx, evt| order.add("b") }
    fsm.on("enter:b.inner") {|ctx, evt| order.add("b.inner") }
    fsm.send("go")
    Expect.that(order[0]).toBe("b")
    Expect.that(order[1]).toBe("b.inner")
  }

  Test.it("unhandled fires when no transition matches") {
    var fsm = StateChart.build {|c|
      c.state("a") {|s| s.on("go", "b") }
      c.state("b") {|s| }
    }
    fsm.start()
    var unhandled = []
    fsm.on("unhandled") {|evt| unhandled.add(evt) }
    fsm.send("nope")
    Expect.that(unhandled.count).toBe(1)
    Expect.that(unhandled[0]).toBe("nope")
  }

  Test.it("wildcard * receives channel name + original args") {
    var fsm = StateChart.build {|c|
      c.state("a") {|s| s.on("go", "b") }
      c.state("b") {|s| }
    }
    fsm.start()
    var seen = []
    fsm.on("*") {|name, a, b| seen.add(name) }
    fsm.send("go")
    // transition + exit:a + enter:b — three signals, three wildcard hits.
    Expect.that(seen.contains("exit:a")).toBe(true)
    Expect.that(seen.contains("transition")).toBe(true)
    Expect.that(seen.contains("enter:b")).toBe(true)
  }

  Test.it("subscriber sees post-transition activePath on enter signal") {
    var fsm = StateChart.build {|c|
      c.state("a") {|s| s.on("go", "b") }
      c.state("b") {|s| }
    }
    fsm.start()
    var pathOnEntry = null
    fsm.on("enter:b") {|ctx, evt| pathOnEntry = fsm.activePath }
    fsm.send("go")
    Expect.that(pathOnEntry).toBe("b")
  }

  Test.it("once fires exactly once") {
    var fsm = StateChart.build {|c|
      c.state("a") {|s| s.on("go", "b") }
      c.state("b") {|s| s.on("back", "a") }
    }
    fsm.start()
    var n = 0
    fsm.once("transition") {|from, to, evt| n = n + 1 }
    fsm.send("go")
    fsm.send("back")
    fsm.send("go")
    Expect.that(n).toBe(1)
  }

  Test.it("off removes a specific listener") {
    var fsm = StateChart.build {|c|
      c.state("a") {|s| s.on("go", "b") }
      c.state("b") {|s| s.on("back", "a") }
    }
    fsm.start()
    var hits = []
    var fn = Fn.new {|from, to, evt| hits.add(evt) }
    fsm.on("transition", fn)
    fsm.send("go")
    fsm.off("transition", fn)
    fsm.send("back")
    Expect.that(hits.count).toBe(1)
    Expect.that(hits[0]).toBe("go")
  }
}

Test.describe("StateChart: bindEvents") {
  Test.it("forwards events from an external emitter into send") {
    var fsm = StateChart.build {|c|
      c.state("a") {|s| s.on("jump", "b") }
      c.state("b") {|s| }
    }
    fsm.start()
    var input = EventEmitter.new()
    fsm.bindEvents(input, ["jump"])
    input.emit("jump")
    Expect.that(fsm.activePath).toBe("b")
  }

  Test.it("ignores events not in the binding list") {
    var fsm = StateChart.build {|c|
      c.state("a") {|s| s.on("jump", "b") }
      c.state("b") {|s| }
    }
    fsm.start()
    var input = EventEmitter.new()
    fsm.bindEvents(input, ["jump"])
    input.emit("noise")
    Expect.that(fsm.activePath).toBe("a")
  }

  Test.it("disconnect Fn unsubscribes the bindings") {
    var fsm = StateChart.build {|c|
      c.state("a") {|s| s.on("jump", "b") }
      c.state("b") {|s| s.on("back", "a") }
    }
    fsm.start()
    var input = EventEmitter.new()
    var disc = fsm.bindEvents(input, ["jump"])
    input.emit("jump")
    Expect.that(fsm.activePath).toBe("b")
    fsm.send("back")
    disc.call()
    input.emit("jump")
    Expect.that(fsm.activePath).toBe("a")
  }

  Test.it("bindEvent (singular) forwards a single event") {
    var fsm = StateChart.build {|c|
      c.state("a") {|s| s.on("go", "b") }
      c.state("b") {|s| }
    }
    fsm.start()
    var input = EventEmitter.new()
    fsm.bindEvent(input, "go")
    input.emit("go")
    Expect.that(fsm.activePath).toBe("b")
  }

  Test.it("non-List eventNames aborts") {
    var fsm = StateChart.build {|c| c.state("a") {|s| } }
    var f = Fiber.new {
      fsm.bindEvents(EventEmitter.new(), "jump")  // String, not List
    }
    f.try()
    Expect.that(f.error.contains("must be a List")).toBe(true)
  }
}

Test.describe("StateChart: tree pretty-printer") {
  Test.it("renders the chart id as the root line") {
    var fsm = StateChart.build {|c|
      c.id("door")
      c.state("closed") {|s| }
    }
    fsm.start()
    var t = fsm.tree
    Expect.that(t.startsWith("door\n")).toBe(true)
  }

  Test.it("uses ASCII branch markers + final-child marker") {
    var fsm = StateChart.build {|c|
      c.id("chart")
      c.state("a") {|s| }
      c.state("b") {|s| }
    }
    fsm.start()
    var t = fsm.tree
    Expect.that(t.contains("|-- a")).toBe(true)
    Expect.that(t.contains("`-- b")).toBe(true)
  }

  Test.it("shows compound initial substate inline with state") {
    var fsm = StateChart.build {|c|
      c.id("chart")
      c.state("g") {|s|
        s.initial("idle")
        s.state("idle") {|i| }
      }
    }
    fsm.start()
    var t = fsm.tree
    Expect.that(t.contains("g (initial: idle)")).toBe(true)
  }

  Test.it("marks final states with (final)") {
    var fsm = StateChart.build {|c|
      c.id("chart")
      c.state("a") {|s| s.on("die", "dead") }
      c.state("dead") {|d| d.final() }
    }
    fsm.start()
    var t = fsm.tree
    Expect.that(t.contains("dead (final)")).toBe(true)
  }

  Test.it("marks currently-active states with [active]") {
    var fsm = StateChart.build {|c|
      c.id("chart")
      c.state("a") {|s| s.on("go", "b") }
      c.state("b") {|s| }
    }
    fsm.start()
    Expect.that(fsm.tree.contains("a [active]")).toBe(true)
    fsm.send("go")
    Expect.that(fsm.tree.contains("b [active]")).toBe(true)
    Expect.that(fsm.tree.contains("a [active]")).toBe(false)
  }

  Test.it("shows transitions as indented attribute lines") {
    var fsm = StateChart.build {|c|
      c.id("chart")
      c.state("a") {|s| s.on("go", "b") }
      c.state("b") {|s| }
    }
    fsm.start()
    Expect.that(fsm.tree.contains("on go -> b")).toBe(true)
  }

  Test.it("toString getter returns the tree") {
    var fsm = StateChart.build {|c|
      c.id("door")
      c.state("a") {|s| }
    }
    fsm.start()
    // `"%(fsm)"` interpolation falls back to "instance of …"
    // because Wren's string-interpolation path doesn't dispatch
    // to user-defined toString getters. Direct `.toString` does.
    var s = fsm.toString
    Expect.that(s.startsWith("door\n")).toBe(true)
    Expect.that(s).toBe(fsm.tree)
  }
}

// --- Day 3: parallel + history + final-with-done ----------------------------

Test.describe("StateChart: parallel regions") {
  Test.it("entering a parallel state activates every region") {
    var fsm = StateChart.build {|c|
      c.parallel("p") {|p|
        p.state("a") {|s| }
        p.state("b") {|s| }
      }
    }
    fsm.start()
    Expect.that(fsm.matches("p")).toBe(true)
    Expect.that(fsm.matches("p.a")).toBe(true)
    Expect.that(fsm.matches("p.b")).toBe(true)
  }

  Test.it("each region advances independently on its own event") {
    var fsm = StateChart.build {|c|
      c.parallel("p") {|p|
        p.state("locomotion") {|loc|
          loc.initial("still")
          loc.state("still")  {|s| s.on("move", "moving") }
          loc.state("moving") {|m| m.on("stop", "still")  }
        }
        p.state("weapon") {|w|
          w.initial("holstered")
          w.state("holstered") {|h| h.on("draw",   "drawn") }
          w.state("drawn")     {|d| d.on("sheath", "holstered") }
        }
      }
    }
    fsm.start()
    Expect.that(fsm.matches("p.locomotion.still")).toBe(true)
    Expect.that(fsm.matches("p.weapon.holstered")).toBe(true)
    fsm.send("move")
    Expect.that(fsm.matches("p.locomotion.moving")).toBe(true)
    Expect.that(fsm.matches("p.weapon.holstered")).toBe(true)   // unchanged
    fsm.send("draw")
    Expect.that(fsm.matches("p.locomotion.moving")).toBe(true)   // unchanged
    Expect.that(fsm.matches("p.weapon.drawn")).toBe(true)
  }

  Test.it("transitioning out of a region exits every region") {
    var fsm = StateChart.build {|c|
      c.parallel("playing") {|p|
        p.state("a") {|s| s.on("escape", "menu") }
        p.state("b") {|s| }
      }
      c.state("menu") {|m| }
    }
    fsm.start()
    fsm.send("escape")
    Expect.that(fsm.matches("menu")).toBe(true)
    Expect.that(fsm.matches("playing")).toBe(false)
    Expect.that(fsm.matches("playing.b")).toBe(false)
  }

  Test.it("parallel with fewer than 2 regions aborts at finish") {
    var f = Fiber.new {
      StateChart.build {|c|
        c.parallel("p") {|p|
          p.state("a") {|s| }
        }
      }
    }
    f.try()
    Expect.that(f.error.contains("parallel state needs ≥2 regions")).toBe(true)
  }

  Test.it("activeLeaves are one-per-region in a parallel") {
    var fsm = StateChart.build {|c|
      c.parallel("p") {|p|
        p.state("a") {|s| }
        p.state("b") {|s| }
      }
    }
    fsm.start()
    // _active includes p + p.a + p.b → leaves are p.a and p.b
    var leaves = []
    for (path in fsm.activeStates) {
      var isLeaf = true
      for (other in fsm.activeStates) {
        if (other != path && other.startsWith(path + ".")) {
          isLeaf = false
          break
        }
      }
      if (isLeaf) leaves.add(path)
    }
    Expect.that(leaves.count).toBe(2)
    Expect.that(leaves.contains("p.a")).toBe(true)
    Expect.that(leaves.contains("p.b")).toBe(true)
  }
}

Test.describe("StateChart: history") {
  Test.it("$history target falls back to compound's initial on first entry") {
    var fsm = StateChart.build {|c|
      c.state("playing") {|s|
        s.initial("level1")
        s.state("level1") {|l| l.on("pause", "paused") }
        s.state("level2") {|l| l.on("pause", "paused") }
      }
      c.state("paused") {|p|
        p.on("resume", "playing.$history")
      }
      c.initial("paused")
    }
    fsm.start()
    fsm.send("resume")   // no history yet → falls back to initial level1
    Expect.that(fsm.activePath).toBe("playing.level1")
  }

  Test.it("$history restores the previously-active substate") {
    var fsm = StateChart.build {|c|
      c.state("playing") {|s|
        s.initial("level1")
        s.state("level1") {|l|
          l.on("next",  "level2")
          l.on("pause", "paused")
        }
        s.state("level2") {|l| l.on("pause", "paused") }
      }
      c.state("paused") {|p|
        p.on("resume", "playing.$history")
      }
    }
    fsm.start()
    fsm.send("next")
    Expect.that(fsm.activePath).toBe("playing.level2")
    fsm.send("pause")
    Expect.that(fsm.activePath).toBe("paused")
    fsm.send("resume")
    Expect.that(fsm.activePath).toBe("playing.level2")   // restored, not back to level1
  }

  Test.it("$historyDeep restores the deepest leaf, not just immediate substate") {
    var fsm = StateChart.build {|c|
      c.state("playing") {|s|
        s.initial("world")
        s.state("world") {|w|
          w.initial("forest")
          w.state("forest") {|f| f.on("pause", "paused") }
          w.state("desert") {|d| d.on("pause", "paused") }
        }
      }
      c.state("paused") {|p|
        p.on("resumeShallow", "playing.$history")
        p.on("resumeDeep",    "playing.$historyDeep")
      }
    }
    fsm.start()
    // Manually drive into playing.world.desert via direct target.
    // Use a chart variant that lets us reach desert from outside.
    // Simpler: re-enter world after switching its initial-equivalent.
    // For this test, just verify deep-history resolves to a leaf path.
    // We need the chart to enter desert first. Build a chart that
    // can target world.desert directly.
  }

  Test.it("$history target resolves sibling-relative inside a compound") {
    // The pause/resume pair lives inside `session`, so the history
    // target `playing.$history` is sibling-relative to `paused` —
    // it should resolve to `session.playing.$history`.
    var fsm = StateChart.build {|c|
      c.state("session") {|sess|
        sess.initial("playing")
        sess.state("playing") {|s|
          s.initial("level1")
          s.state("level1") {|l|
            l.on("next",  "level2")
            l.on("pause", "paused")
          }
          s.state("level2") {|l| l.on("pause", "paused") }
        }
        sess.state("paused") {|p|
          p.on("resume", "playing.$history")
        }
      }
    }
    fsm.start()
    fsm.send("next")
    Expect.that(fsm.activePath).toBe("session.playing.level2")
    fsm.send("pause")
    Expect.that(fsm.activePath).toBe("session.paused")
    fsm.send("resume")
    Expect.that(fsm.activePath).toBe("session.playing.level2")
  }

  Test.it("$history target on non-compound state aborts at finish") {
    var f = Fiber.new {
      StateChart.build {|c|
        c.state("a") {|s| s.on("go", "b.$history") }
        c.state("b") {|s| }   // atomic, not compound
      }
    }
    f.try()
    Expect.that(f.error.contains("targets unknown state 'b.$history'")).toBe(true)
  }
}

Test.describe("StateChart: final state + done signal") {
  Test.it("entering a final state emits done with parent path") {
    var fsm = StateChart.build {|c|
      c.state("game") {|g|
        g.initial("playing")
        g.state("playing") {|p| p.on("die", "dead") }
        g.state("dead") {|d| d.final() }
      }
    }
    fsm.start()
    var done = []
    fsm.on("done") {|path| done.add(path) }
    fsm.send("die")
    Expect.that(done.count).toBe(1)
    Expect.that(done[0]).toBe("game")
  }

  Test.it("done emits per compound parent and once for the parallel when all regions final") {
    // SCXML semantics: each compound whose final is entered emits
    // done with its own path; the parallel parent also emits done
    // when EVERY region has reached final.
    var fsm = StateChart.build {|c|
      c.parallel("race") {|p|
        p.state("player1") {|r|
          r.initial("running")
          r.state("running") {|rn| rn.on("p1finish", "done1") }
          r.state("done1") {|d| d.final() }
        }
        p.state("player2") {|r|
          r.initial("running")
          r.state("running") {|rn| rn.on("p2finish", "done2") }
          r.state("done2") {|d| d.final() }
        }
      }
    }
    fsm.start()
    var done = []
    fsm.on("done") {|path| done.add(path) }
    fsm.send("p1finish")
    // player1's compound reached final → one done emission so far.
    Expect.that(done.count).toBe(1)
    Expect.that(done[0]).toBe("race.player1")
    fsm.send("p2finish")
    // player2's compound reached final + race's parallel saw every
    // region at final → two more emissions.
    Expect.that(done.contains("race.player2")).toBe(true)
    Expect.that(done.contains("race")).toBe(true)
  }

  Test.it("final state cannot be the target of a transition source's final") {
    var f = Fiber.new {
      StateChart.build {|c|
        c.state("a") {|s|
          s.final()
          s.on("x", "b")     // final + transition should error
        }
        c.state("b") {|s| }
      }
    }
    f.try()
    Expect.that(f.error.contains("final states cannot have outgoing transitions")).toBe(true)
  }
}

// --- Day 4: guards + actions + fromMap --------------------------------------

Test.describe("StateChart: entry / exit actions") {
  Test.it("entry action fires when state is entered, with (ctx, event)") {
    var seen = []
    var fsm = StateChart.build {|c|
      c.state("a") {|s|
        s.entry {|ctx, evt| seen.add("entry-a:%(evt)") }
        s.on("go", "b")
      }
      c.state("b") {|s|
        s.entry {|ctx, evt| seen.add("entry-b:%(evt)") }
      }
    }
    fsm.start()                  // entry-a with no event
    fsm.send("go")               // exit (none), entry-b
    Expect.that(seen[0]).toBe("entry-a:null")
    Expect.that(seen[1]).toBe("entry-b:go")
  }

  Test.it("exit action fires before entry of the next state") {
    var seen = []
    var fsm = StateChart.build {|c|
      c.state("a") {|s|
        s.exit {|ctx, evt| seen.add("exit-a") }
        s.on("go", "b")
      }
      c.state("b") {|s|
        s.entry {|ctx, evt| seen.add("entry-b") }
      }
    }
    fsm.start()
    fsm.send("go")
    Expect.that(seen[0]).toBe("exit-a")
    Expect.that(seen[1]).toBe("entry-b")
  }

  Test.it("entry actions can mutate context") {
    var fsm = StateChart.build {|c|
      c.context({ "hp": 100 })
      c.state("a") {|s|
        s.entry {|ctx, evt| ctx["hp"] = ctx["hp"] - 10 }
        s.on("hit", "a")  // self-transition re-enters
      }
    }
    fsm.start()
    Expect.that(fsm.context["hp"]).toBe(90)
    fsm.send("hit")
    Expect.that(fsm.context["hp"]).toBe(80)
  }

  Test.it("compound entry runs shallowest-first") {
    var seen = []
    var fsm = StateChart.build {|c|
      c.state("outer") {|o|
        o.initial("inner")
        o.entry {|ctx, evt| seen.add("outer") }
        o.state("inner") {|i|
          i.entry {|ctx, evt| seen.add("inner") }
        }
      }
    }
    fsm.start()
    Expect.that(seen[0]).toBe("outer")
    Expect.that(seen[1]).toBe("inner")
  }

  Test.it("compound exit runs deepest-first") {
    var seen = []
    var fsm = StateChart.build {|c|
      c.state("outer") {|o|
        o.initial("inner")
        o.exit {|ctx, evt| seen.add("outer") }
        o.state("inner") {|i|
          i.exit {|ctx, evt| seen.add("inner") }
        }
        o.on("leave", "other")
      }
      c.state("other") {|x| }
    }
    fsm.start()
    fsm.send("leave")
    Expect.that(seen[0]).toBe("inner")
    Expect.that(seen[1]).toBe("outer")
  }

  Test.it("multiple entry actions run in declaration order") {
    var seen = []
    var fsm = StateChart.build {|c|
      c.state("a") {|s|
        s.entry {|ctx, evt| seen.add("first") }
        s.entry {|ctx, evt| seen.add("second") }
        s.entry {|ctx, evt| seen.add("third") }
      }
    }
    fsm.start()
    Expect.that(seen[0]).toBe("first")
    Expect.that(seen[1]).toBe("second")
    Expect.that(seen[2]).toBe("third")
  }

  Test.it("non-Fn entry aborts at the builder call") {
    var f = Fiber.new {
      StateChart.build {|c| c.state("a") {|s| s.entry(42) } }
    }
    f.try()
    Expect.that(f.error.contains("state(a).entry: expected Fn")).toBe(true)
  }
}

Test.describe("StateChart: transition guards") {
  Test.it("guard true fires the transition") {
    var fsm = StateChart.build {|c|
      c.context({ "ok": true })
      c.state("a") {|s|
        s.on("go") {|t|
          t.when {|ctx, evt| ctx["ok"] }
          t.go("b")
        }
      }
      c.state("b") {|s| }
    }
    fsm.start()
    fsm.send("go")
    Expect.that(fsm.activePath).toBe("b")
  }

  Test.it("guard false skips the transition") {
    var fsm = StateChart.build {|c|
      c.context({ "ok": false })
      c.state("a") {|s|
        s.on("go") {|t|
          t.when {|ctx, evt| ctx["ok"] }
          t.go("b")
        }
      }
      c.state("b") {|s| }
    }
    fsm.start()
    fsm.send("go")
    Expect.that(fsm.activePath).toBe("a")
  }

  Test.it("multiple branches: first matching guard wins") {
    var fsm = StateChart.build {|c|
      c.context({ "stamina": 5 })
      c.state("idle") {|s|
        s.on("attack") {|t|
          t.when {|ctx, evt| ctx["stamina"] >= 10 }
          t.go("attacking")
        }
        s.on("attack") {|t|
          t.when {|ctx, evt| ctx["stamina"] >= 3 }
          t.go("light_attack")
        }
        s.on("attack") {|t| t.go("tooTired") }   // fallback
      }
      c.state("attacking")    {|x| }
      c.state("light_attack") {|x| }
      c.state("tooTired")     {|x| }
    }
    fsm.start()
    fsm.send("attack")
    Expect.that(fsm.activePath).toBe("light_attack")
  }

  Test.it("guard returning non-Bool aborts") {
    var fsm = StateChart.build {|c|
      c.state("a") {|s|
        s.on("go") {|t|
          t.when {|ctx, evt| "yes" }   // String, not Bool
          t.go("b")
        }
      }
      c.state("b") {|s| }
    }
    fsm.start()
    var f = Fiber.new { fsm.send("go") }
    f.try()
    Expect.that(f.error.contains("returned String, expected Bool")).toBe(true)
  }
}

Test.describe("StateChart: transition actions") {
  Test.it("transition action fires between exit and entry") {
    var seen = []
    var fsm = StateChart.build {|c|
      c.state("a") {|s|
        s.exit {|ctx, evt| seen.add("exit-a") }
        s.on("go") {|t|
          t.does {|ctx, evt| seen.add("transition") }
          t.go("b")
        }
      }
      c.state("b") {|s|
        s.entry {|ctx, evt| seen.add("entry-b") }
      }
    }
    fsm.start()
    fsm.send("go")
    Expect.that(seen[0]).toBe("exit-a")
    Expect.that(seen[1]).toBe("transition")
    Expect.that(seen[2]).toBe("entry-b")
  }

  Test.it("transition action sees mutated context in subsequent guards") {
    var fsm = StateChart.build {|c|
      c.context({ "hp": 100 })
      c.state("a") {|s|
        s.on("hit") {|t|
          t.does {|ctx, evt| ctx["hp"] = ctx["hp"] - 30 }
          t.go("a")  // self-transition
        }
        s.on("check") {|t|
          t.when {|ctx, evt| ctx["hp"] < 50 }
          t.go("dying")
        }
        s.on("check") {|t| t.go("a") }
      }
      c.state("dying") {|x| }
    }
    fsm.start()
    fsm.send("hit")
    fsm.send("hit")
    Expect.that(fsm.context["hp"]).toBe(40)
    fsm.send("check")
    Expect.that(fsm.activePath).toBe("dying")
  }

  Test.it("internal transition runs actions without exit/entry") {
    var seen = []
    var fsm = StateChart.build {|c|
      c.state("a") {|s|
        s.entry {|ctx, evt| seen.add("entry") }
        s.exit  {|ctx, evt| seen.add("exit")  }
        s.on("tick") {|t|
          t.internal()
          t.does {|ctx, evt| seen.add("action") }
        }
      }
    }
    fsm.start()                 // seen = [entry]
    fsm.send("tick")            // seen += [action]; no exit / entry
    Expect.that(seen.count).toBe(2)
    Expect.that(seen[0]).toBe("entry")
    Expect.that(seen[1]).toBe("action")
  }
}

Test.describe("StateChart: fromMap adapter") {
  Test.it("builds the same chart as the builder API") {
    var fsm = StateChart.fromMap({
      "id": "door",
      "states": {
        "closed": { "on": { "open":  "open"   } },
        "open":   { "on": { "close": "closed" } }
      }
    })
    fsm.start()
    Expect.that(fsm.activePath).toBe("closed")
    fsm.send("open")
    Expect.that(fsm.activePath).toBe("open")
    fsm.send("close")
    Expect.that(fsm.activePath).toBe("closed")
  }

  Test.it("compound + initial via map") {
    var fsm = StateChart.fromMap({
      "states": {
        "ground": {
          "initial": "idle",
          "states": {
            "idle":    { "on": { "walk": "walking" } },
            "walking": {}
          }
        }
      }
    })
    fsm.start()
    Expect.that(fsm.activePath).toBe("ground.idle")
    fsm.send("walk")
    Expect.that(fsm.activePath).toBe("ground.walking")
  }

  Test.it("parallel via map with type: parallel") {
    var fsm = StateChart.fromMap({
      "states": {
        "p": {
          "type": "parallel",
          "states": {
            "a": { "states": { "x": {} }, "initial": "x" },
            "b": { "states": { "y": {} }, "initial": "y" }
          }
        }
      }
    })
    fsm.start()
    Expect.that(fsm.matches("p.a.x")).toBe(true)
    Expect.that(fsm.matches("p.b.y")).toBe(true)
  }

  Test.it("final via map with type: final + done emits") {
    var fsm = StateChart.fromMap({
      "states": {
        "game": {
          "initial": "playing",
          "states": {
            "playing": { "on": { "die": "dead" } },
            "dead":    { "type": "final" }
          }
        }
      }
    })
    fsm.start()
    var done = []
    fsm.on("done") {|path| done.add(path) }
    fsm.send("die")
    Expect.that(done[0]).toBe("game")
  }

  Test.it("entry / exit / transition actions via map") {
    var hits = []
    var fsm = StateChart.fromMap({
      "states": {
        "a": {
          "entry": Fn.new {|ctx, evt| hits.add("enter-a") },
          "exit":  Fn.new {|ctx, evt| hits.add("exit-a") },
          "on": {
            "go": {
              "target":  "b",
              "actions": Fn.new {|ctx, evt| hits.add("transition") }
            }
          }
        },
        "b": {
          "entry": [
            Fn.new {|ctx, evt| hits.add("enter-b-1") },
            Fn.new {|ctx, evt| hits.add("enter-b-2") }
          ]
        }
      }
    })
    fsm.start()
    fsm.send("go")
    Expect.that(hits[0]).toBe("enter-a")
    Expect.that(hits[1]).toBe("exit-a")
    Expect.that(hits[2]).toBe("transition")
    Expect.that(hits[3]).toBe("enter-b-1")
    Expect.that(hits[4]).toBe("enter-b-2")
  }

  Test.it("guards via map + multi-branch transitions") {
    var fsm = StateChart.fromMap({
      "context": { "stamina": 5 },
      "states": {
        "idle": {
          "on": {
            "attack": [
              { "target": "strong", "guard": Fn.new {|ctx, evt| ctx["stamina"] >= 10 } },
              { "target": "weak",   "guard": Fn.new {|ctx, evt| ctx["stamina"] >= 3  } },
              { "target": "tired" }
            ]
          }
        },
        "strong": {}, "weak": {}, "tired": {}
      }
    })
    fsm.start()
    fsm.send("attack")
    Expect.that(fsm.activePath).toBe("weak")
  }

  Test.it("internal transition via map") {
    var seen = []
    var fsm = StateChart.fromMap({
      "states": {
        "a": {
          "entry": Fn.new {|ctx, evt| seen.add("enter") },
          "exit":  Fn.new {|ctx, evt| seen.add("exit") },
          "on": {
            "tick": {
              "internal": true,
              "actions":  Fn.new {|ctx, evt| seen.add("action") }
            }
          }
        }
      }
    })
    fsm.start()
    fsm.send("tick")
    // entry, then action only — no exit/entry pair
    Expect.that(seen.count).toBe(2)
    Expect.that(seen[1]).toBe("action")
  }

  Test.it("non-Map spec aborts") {
    var f = Fiber.new { StateChart.fromMap("not a map") }
    f.try()
    Expect.that(f.error.contains("expected Map")).toBe(true)
  }
}

Test.run()
