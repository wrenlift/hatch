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

Test.run()
