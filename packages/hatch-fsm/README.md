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

## What's here today (v0.1.0 / day-3)

- Atomic + compound states
- **Parallel regions** (`chart.parallel(name) {|p| p.state(...) }`) —
  each region ticks independently; transitions out of any region exit the
  whole parallel
- **History pseudo-targets** — `playing.$history` (shallow, last immediate
  substate) and `playing.$historyDeep` (deep, last full leaf), falling back
  to the compound's `initial` when no history has been recorded
- **Final states** — `s.final()` marks a leaf; entering one emits `done`
  with the compound parent's path; for parallel ancestors, `done` fires
  only when EVERY region's leaf is final
- Sibling-relative + fully-qualified transition targets
- `start` / `stop` / `send` / `matches` / `activeStates` / `activePath`
- Mutable `context` map carried by the chart
- Construction-time validation with path-tagged error messages
- Re-entrant `send` queues into microsteps
- **Signal channels** via `@hatch:events`:
  `fsm.on("transition")`, `fsm.on("enter:<path>")`, `fsm.on("exit:<path>")`,
  `fsm.on("unhandled")`, `fsm.on("done")`, `fsm.on("*")` wildcard;
  `once` / `off` / `offAll` inherited
- **`bindEvents(emitter, [names])`** to forward selected events from any
  `EventEmitter` (input handlers, ECS world events, network bus) into `send`
- **`fsm.tree`** ASCII pretty-printer with active-state markers + transition
  annotations; `toString` getter delegates

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

Coming in later versions: guards on transitions, entry/exit/transition
actions, `fromMap(spec)` adapter.

Design rationale, semantics, and roadmap: see
[`docs/hatch-fsm-design.md`](../../docs/hatch-fsm-design.md).

## Build + run tests

```sh
hatch test packages/hatch-fsm
```
