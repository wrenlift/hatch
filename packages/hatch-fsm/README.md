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

## What's here today (v0.1.0 / day-1 scope)

- Atomic + compound states
- Sibling-relative + fully-qualified transition targets
- `start` / `stop` / `send` / `matches` / `activeStates` / `activePath`
- Mutable `context` map carried by the chart
- Construction-time validation with path-tagged error messages
- Re-entrant `send` queues into microsteps

Coming in later versions: parallel regions, history (shallow + deep),
final states + `done` emission, guards on transitions, entry/exit/transition
actions, EventEmitter integration (`fsm.on("transition")`, `fsm.on("enter:<path>")`),
`bindEvents(emitter)`, `fromMap(spec)` adapter.

Design rationale, semantics, and roadmap: see
[`docs/hatch-fsm-design.md`](../../docs/hatch-fsm-design.md).

## Build + run tests

```sh
hatch test packages/hatch-fsm
```
