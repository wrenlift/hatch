// Game flow controller example.
//
// Shows the chart shape a real game's top-level lifecycle fits
// cleanly into — loading, then a `session` compound holding menu,
// gameplay (with pause/resume), and the win/lose/quit finals —
// as a single statechart with hierarchical states, history for
// resume, and signal-based observation for UI / SFX / analytics
// wiring.

import "@hatch:fsm" for StateChart

var fsm = StateChart.build {|c|
  c.id("game")
  c.context({
    "score":  0,
    "lives":  3,
    "level":  1
  })

  c.state("loading") {|s|
    s.entry {|ctx, evt| System.print("[loading] preparing assets...") }
    s.on("ready", "session")
  }

  // A `session` compound holds the actual game session. Wrapping
  // menu / playing / paused / victory / gameOver / exit inside it
  // gives them a single parent — entering any of the finals
  // emits `done` for `session`, which the UI can hook to roll the
  // credits, return to title, etc.
  c.state("session") {|sess|
    sess.initial("menu")

    sess.state("menu") {|s|
      s.entry {|ctx, evt| System.print("[menu] press play to start") }
      s.on("play", "playing")
      s.on("quit", "exit")
    }

    // Compound: holds level state + supports pause/resume via
    // history so "resume" returns to the same level we left.
    sess.state("playing") {|s|
      s.initial("level1")
      s.entry {|ctx, evt| System.print("[playing] entered (level=%(ctx["level"]))") }
      s.exit  {|ctx, evt| System.print("[playing] suspended") }

      s.state("level1") {|l|
        l.entry {|ctx, evt|
          ctx["level"] = 1
          System.print("[level1] go go go")
        }
        l.on("complete", "level2")
        l.on("die") {|t|
          t.does {|ctx, evt| ctx["lives"] = ctx["lives"] - 1 }
          t.when {|ctx, evt| ctx["lives"] > 1 }
          t.go("level1")   // self-transition: replay
        }
        l.on("die", "gameOver")   // fallback when lives <= 1
      }
      s.state("level2") {|l|
        l.entry {|ctx, evt|
          ctx["level"] = 2
          System.print("[level2] now harder")
        }
        l.on("complete", "victory")
        l.on("die") {|t|
          t.does {|ctx, evt| ctx["lives"] = ctx["lives"] - 1 }
          t.when {|ctx, evt| ctx["lives"] > 1 }
          t.go("level2")
        }
        l.on("die", "gameOver")
      }

      // Score events are handled at the compound level so they
      // work from either substate without duplication.
      s.on("score") {|t|
        t.does {|ctx, evt| ctx["score"] = ctx["score"] + 100 }
        t.internal()
      }

      s.on("pause", "paused")
    }

    sess.state("paused") {|s|
      s.entry {|ctx, evt| System.print("[paused] freeze") }
      s.exit  {|ctx, evt| System.print("[paused] resume") }
      // History restores the substate we left — resume goes back
      // to level1 or level2 depending on where we paused.
      s.on("resume", "playing.$history")
    }

    sess.state("victory") {|s|
      s.entry {|ctx, evt|
        System.print("[victory] final score=%(ctx["score"])")
      }
      s.final()
    }

    sess.state("gameOver") {|s|
      s.entry {|ctx, evt|
        System.print("[gameOver] score=%(ctx["score"]) lives=%(ctx["lives"])")
      }
      s.final()
    }

    sess.state("exit") {|s| s.final() }
  }

  c.initial("loading")
}

System.print("=== chart structure ===")
System.print(fsm.tree)

// Wire signal-based observers. The chart definition above never
// mentions sound effects, UI, or analytics — they're added here
// as decoupled subscribers.
fsm.on("transition") {|from, to, evt|
  System.print("    [sfx]  transition %(from) -> %(to) via %(evt)")
}
fsm.on("done") {|path|
  System.print("    [ui]   chart done: %(path)")
}
fsm.on("unhandled") {|evt|
  System.print("    [warn] unhandled event: %(evt)")
}

fsm.start()
System.print("=== after start, active = %(fsm.activeStates) ===")

System.print("\n=== walkthrough ===")
fsm.send("ready")
fsm.send("play")
fsm.send("score")    // internal — bumps score, stays in level1
fsm.send("score")
fsm.send("complete") // -> level2
fsm.send("score")
fsm.send("pause")
fsm.send("zzz")      // unhandled
fsm.send("resume")   // history brings us back to level2
fsm.send("complete") // -> victory (final) — emits done for session

System.print("=== final state ===")
System.print("  active:  %(fsm.activeStates)")
System.print("  score:   %(fsm.context["score"])")
System.print("  lives:   %(fsm.context["lives"])")
System.print("  level:   %(fsm.context["level"])")

System.print("\n=== final tree ===")
System.print(fsm.tree)
