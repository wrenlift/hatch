# `@hatch:fsm`

Harel statecharts for Wren. Hierarchical and parallel states, history,
guards, entry/exit/transition actions, context, signal-based observation.
Pure Wren.

```wren
import "@hatch:fsm" for StateChart

var fsm = StateChart.build {|chart|
  chart.id("door")
  chart.state("closed") {|s| s.on("open",  "open")   }
  chart.state("open")   {|s| s.on("close", "closed") }
}

fsm.start()
fsm.send("open")             // "closed" → "open"
fsm.matches("open")          // true
fsm.activeStates             // ["open"]
```

Compound states:

```wren
var fsm = StateChart.build {|chart|
  chart.state("ground") {|s|
    s.initial("idle")
    s.on("jump", "air")                       // declared once; fires from any nested state
    s.state("idle")    {|i| i.on("walk", "walking") }
    s.state("walking") {|w| w.on("stop", "idle")    }
  }
  chart.state("air") {|s| s.on("land", "ground") }   // re-enters ground via its initial
}
fsm.start()                  // ["ground", "ground.idle"]
fsm.send("walk")             // ["ground", "ground.walking"]
fsm.send("jump")             // ["air"]
fsm.send("land")             // ["ground", "ground.idle"]
fsm.matches("ground")        // true while any ground.* is active
```

## What's here today (v0.1.0 / day-4)

- Atomic + compound + **parallel** states
- **Entry / exit / transition actions** — `s.entry {|ctx, evt| ...}`,
  `s.exit {|ctx, evt| ...}`, `t.does {|ctx, evt| ...}`; mutate context
  freely
- **Guards** — `s.on("evt") {|t| t.when {|ctx, evt| ...}.go("target") }`;
  multiple branches per event, first matching guard wins
- **Internal transitions** — `t.internal()` runs the action without
  exit/re-entry
- **History pseudo-targets** — `playing.$history` and
  `playing.$historyDeep`
- **Final states** + `done` emission
- **`fromMap(spec)`** — data-driven adapter that drives the same builder
  internally
- Construction-time validation with path-tagged error messages
- Re-entrant `send` queues into microsteps
- **Signal channels** via `@hatch:events`:
  `transition` / `enter:<path>` / `exit:<path>` / `unhandled` / `done` /
  `*` wildcard
- **`bindEvents(emitter, [names])`** to forward external events into `send`
- **`fsm.tree`** ASCII pretty-printer; `toString` getter delegates

Observation example:
```wren
fsm.on("transition") {|from, to, evt| log.info("%(from) → %(to) via %(evt)") }
fsm.on("enter:ground.running") {|ctx, evt| sfx.startLoop("footsteps") }
fsm.on("exit:ground.running")  {|ctx, evt| sfx.stopLoop("footsteps")  }
fsm.on("done")                 {|path|     log.info("done %(path)") }
fsm.on("*") {|name, a, b| inspector.record(name, a, b) }
```

Pause/resume with history:
```wren
chart.state("playing") {|s|
  s.initial("level1")
  s.state("level1") {|l| l.on("pause", "paused") }
  s.state("level2") {|l| l.on("pause", "paused") }
}
chart.state("paused") {|p|
  p.on("resume", "playing.$history")   // restores last-active level
}
```

Guards + actions:
```wren
chart.state("idle") {|s|
  s.on("attack") {|t|
    t.when {|ctx, evt| ctx["stamina"] >= 10 }
    t.does {|ctx, evt| ctx["stamina"] = ctx["stamina"] - 10 }
    t.go("attacking")
  }
  s.on("attack") {|t| t.go("tooTired") }   // fallback if guard fails
}
```

Data-driven (`fromMap`):
```wren
var fsm = StateChart.fromMap({
  "id": "player",
  "initial": "ground",
  "context": { "hp": 100 },
  "states": {
    "ground": {
      "initial": "idle",
      "states": {
        "idle":    { "on": { "walk": "walking" } },
        "walking": { "on": { "stop": "idle" } }
      },
      "on": { "jump": "air" }
    },
    "air":  { "on": { "land": "ground" } },
    "dead": { "type": "final" }
  }
})
```

Design rationale, semantics, and roadmap: see
[`docs/hatch-fsm-design.md`](../../docs/hatch-fsm-design.md).

End-to-end example showing compound states, history-based pause/resume,
guards, internal transitions, finals + `done`, and signal observers:
[`examples/fsm-game-flow/`](../../examples/fsm-game-flow/).

```sh
hatch run examples/fsm-game-flow
```

## Build + run tests

```sh
hatch test packages/hatch-fsm
```
