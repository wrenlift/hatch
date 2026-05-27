import "./fsm"         for StateChart
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

Test.run()
