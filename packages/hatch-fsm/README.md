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

## What's here today (v0.1.0 / day-2)

- Atomic + compound states
- Sibling-relative + fully-qualified transition targets
- `start` / `stop` / `send` / `matches` / `activeStates` / `activePath`
- Mutable `context` map carried by the chart
- Construction-time validation with path-tagged error messages
- Re-entrant `send` queues into microsteps
- **Signal channels** via `@hatch:events`:
  `fsm.on("transition")`, `fsm.on("enter:<path>")`, `fsm.on("exit:<path>")`,
  `fsm.on("unhandled")`, `fsm.on("*")` wildcard; `once` / `off` / `offAll` inherited
- **`bindEvents(emitter, [names])`** to forward selected events from any
  `EventEmitter` (input handlers, ECS world events, network bus) into `send`
- **`fsm.tree`** ASCII pretty-printer with active-state markers + transition
  annotations; `toString` getter delegates

Observation example:
```wren
fsm.on("transition") {|from, to, evt| log.info("%(from) → %(to) via %(evt)") }
fsm.on("enter:ground.running") {|ctx, evt| sfx.startLoop("footsteps") }
fsm.on("exit:ground.running")  {|ctx, evt| sfx.stopLoop("footsteps")  }
fsm.on("*") {|name, a, b| inspector.record(name, a, b) }
```

Coming in later versions: parallel regions, history (shallow + deep),
final states + `done` emission, guards on transitions, entry/exit/transition
actions, `fromMap(spec)` adapter.

Design rationale, semantics, and roadmap: see
[`docs/hatch-fsm-design.md`](../../docs/hatch-fsm-design.md).

## Build + run tests

```sh
hatch test packages/hatch-fsm
```
