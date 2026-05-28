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
fsm.activePath               // "open"  (deepest leaf as a single string)
```

## State kinds

Kinds are inferred from the builder calls; you never write the kind
explicitly except for `final()`.

| Kind | Declared via | Behaviour |
|---|---|---|
| **atomic**   | `chart.state("x") {\|s\| ... }` with no substates | Leaf. Appears in `activeStates` by itself. |
| **compound** | `chart.state("x") {\|s\| s.initial("…"); s.state("…") {…}; … }` | Has substates + `initial`. Entering descends through the initial; transitions on the parent bubble from any nested leaf. |
| **parallel** | `chart.parallel("x") {\|p\| p.state("regionA") {…}; p.state("regionB") {…}; … }` | Each child `.state(...)` is an independent region (compound or atomic). Entering activates every region; exiting exits all. Needs ≥ 2 regions. |
| **final**    | `chart.state("dead") {\|s\| s.final() }` | Terminal. No substates, no outgoing transitions. Entering emits `done` on the compound parent, and on a surrounding parallel once every region has finished. |

### Compound

```wren
var fsm = StateChart.build {|chart|
  chart.state("ground") {|s|
    s.initial("idle")
    s.on("jump", "air")                          // declared once; fires from any nested state
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

### Parallel

Two regions advance independently on their own events. `playing.locomotion`
and `playing.weapon` are both compound; entering `playing` enters both.

```wren
var fsm = StateChart.build {|chart|
  chart.parallel("playing") {|p|
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
fsm.matches("playing.locomotion.still")     // true
fsm.matches("playing.weapon.holstered")     // true
fsm.send("move")
fsm.matches("playing.locomotion.moving")    // true   (weapon unchanged)
fsm.send("draw")
fsm.matches("playing.weapon.drawn")         // true   (locomotion unchanged)
```

A transition that targets a state *outside* the parallel exits every region:

```wren
chart.parallel("playing") {|p|
  p.state("a") {|s| s.on("escape", "menu") }     // routes "escape" out
  p.state("b") {|s| }
}
chart.state("menu") {|m| }
// fsm.send("escape")  → playing.a and playing.b both exit; active becomes ["menu"]
```

### Final + `done`

```wren
var fsm = StateChart.build {|chart|
  chart.state("game") {|g|
    g.initial("playing")
    g.state("playing") {|p| p.on("die", "dead") }
    g.state("dead")    {|d| d.final() }
  }
}
fsm.on("done") {|path| log.info("done %(path)") }
fsm.start()
fsm.send("die")        // emits done "game"
```

Inside a parallel state, `done` emits once per compound region reaching
final, then once more for the parallel itself when every region is final.

## Common usage

### Context + actions

`chart.context({...})` seeds a per-chart Map. Entry / exit / transition
actions receive `(ctx, event)` and may mutate `ctx` freely; guards (below)
read it.

```wren
var fsm = StateChart.build {|chart|
  chart.context({ "score": 0, "lives": 3 })
  chart.state("playing") {|s|
    s.entry {|ctx, evt| ctx["score"] = 0 }
    s.on("hit") {|t|
      t.does {|ctx, evt| ctx["lives"] = ctx["lives"] - 1 }
      t.go("playing")                                          // self-transition; re-runs entry
    }
    s.on("score") {|t| t.does {|ctx, evt| ctx["score"] = ctx["score"] + 100 } }
  }
}
fsm.start()
fsm.send("score")
fsm.context["score"]   // 100
```

### Guards

`s.on("evt") {|t| ... }` opens a transition builder. `t.when` adds a guard;
`t.does` adds a transition action; `t.go` names the target. Multiple
branches per event become first-match-wins:

```wren
chart.state("idle") {|s|
  s.on("attack") {|t|
    t.when {|ctx, evt| ctx["stamina"] >= 10 }
    t.does {|ctx, evt| ctx["stamina"] = ctx["stamina"] - 10 }
    t.go("attacking")
  }
  s.on("attack") {|t| t.go("tooTired") }   // fallback when the guard fails
}
```

### Internal transitions

`t.internal()` runs the transition action without exiting + re-entering the
source state — useful for counters and side-effects that shouldn't re-fire
`entry` / `exit`:

```wren
s.on("damage") {|t|
  t.internal()
  t.does {|ctx, evt| ctx["hp"] = ctx["hp"] - 10 }
}
```

### History pseudo-targets

`.$history` resumes the previously-active substate of a compound;
`.$historyDeep` resumes the deepest leaf. First entry falls back to the
compound's `initial`.

```wren
chart.state("playing") {|s|
  s.initial("level1")
  s.state("level1") {|l| l.on("pause", "paused") }
  s.state("level2") {|l| l.on("pause", "paused") }
}
chart.state("paused") {|p|
  p.on("resume", "playing.$history")    // restores the last-active level
}
```

### Signal channels

Subscribe via `@hatch:events`-style `on` channels:

```wren
fsm.on("transition") {|from, to, evt|       log.info("%(from) → %(to) via %(evt)") }
fsm.on("enter:ground.running") {|ctx, evt|  sfx.startLoop("footsteps") }
fsm.on("exit:ground.running")  {|ctx, evt|  sfx.stopLoop("footsteps")  }
fsm.on("unhandled") {|evt|                  log.warn("no transition for %(evt)") }
fsm.on("done")      {|path|                 log.info("done %(path)") }
fsm.on("*")         {|name, a, b|           inspector.record(name, a, b) }
```

### `bindEvents` — forward an emitter into `send`

```wren
var input = EventEmitter.new()
var disconnect = fsm.bindEvents(input, ["jump", "land", "attack"])
input.emit("jump")        // same as fsm.send("jump")
disconnect.call()         // tears the bindings down
```

### Data-driven (`fromMap`)

Drives the same builder internally; useful for JSON-defined charts.

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

### Pretty-print

```wren
System.print(fsm.tree)
// door
// ├── closed   on open → open
// └── open     on close → closed [active]
```

## What's here today (v0.1.0)

- Atomic + compound + **parallel** states
- **Final states** + `done` emission
- **Entry / exit / transition actions** — `s.entry {|ctx, evt| ...}`,
  `s.exit {|ctx, evt| ...}`, `t.does {|ctx, evt| ...}`; mutate context freely
- **Guards** — `s.on("evt") {|t| t.when {|ctx, evt| ...}.go("target") }`;
  multiple branches per event, first matching guard wins
- **Internal transitions** — `t.internal()` runs the action without
  exit/re-entry
- **History pseudo-targets** — `playing.$history` and `playing.$historyDeep`
- **`fromMap(spec)`** — data-driven adapter that drives the same builder
  internally
- Construction-time validation with path-tagged error messages
- Re-entrant `send` queues into microsteps
- **Signal channels** via `@hatch:events`:
  `transition` / `enter:<path>` / `exit:<path>` / `unhandled` / `done` /
  `*` wildcard
- **`bindEvents(emitter, [names])`** to forward external events into `send`
- **`fsm.tree`** ASCII pretty-printer; `toString` getter delegates

End-to-end example showing compound states, history-based pause/resume,
guards, internal transitions, finals + `done`, and signal observers:
[examples/fsm-game-flow/](https://github.com/wrenlift/hatch/tree/main/examples/fsm-game-flow).

```sh
hatch run examples/fsm-game-flow
```

## Build + run tests

```sh
hatch test packages/hatch-fsm
```
