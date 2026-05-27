# `@hatch:fsm` — Harel statecharts for Wren

A general-purpose finite-state-machine library shaped after Harel statecharts. Standalone package: usable anywhere (game state, UI flow, network reconnect, dialogue trees), not just game.

Modeled after **XState**'s semantics with **Godot's signal-based observation pattern**. Same vocabulary throughout: states, transitions, events, guards, actions, context, parallel regions, history, final states. API surface is a **closure-based builder** that composes with `@hatch:events`, so observers, action wiring, input binding, and serialization all reuse machinery the runtime already ships.

Two principles:

1. **Validation collapses into the API.** Each builder method's signature *is* its type check; each closure scope *is* a structural rule. No external schema, no walk-validator. Errors abort at the user's stack frame, not at a JSON path.
2. **Observation through `@hatch:events`.** `StateChart` is an `EventEmitter`. Anyone can subscribe to transitions, state entries, state exits, the wildcard channel. Anyone can publish events into the chart by binding an emitter. No bespoke hook API.

## Why statecharts, not plain FSMs

A flat FSM with N states and M events has up to N×M transitions. For anything non-trivial that's a mess: a "pause" event from any of 12 gameplay states means 12 identical transitions. Harel's three big additions fix this:

1. **Hierarchy.** "When in `playing` and `pause` fires, go to `paused`." Defined once at the parent state; every nested state inherits it. The `paused → resume` transition restores via a history state, no bookkeeping in user code.
2. **Parallel regions.** "Player is `moving` AND `aiming` simultaneously, each its own state machine." A character's locomotion FSM and weapon FSM run in parallel without composing into a combinatorial product.
3. **First-class observation.** Anything outside the FSM can react to state changes without the FSM knowing — sound, particles, analytics, save snapshots, network sync, debug overlays all subscribe to the same signals. Adding a new consumer never touches the FSM definition.

Plus guards (conditional transitions), entry/exit actions (lifecycle hooks per state), and a context object (data the machine carries that handlers can mutate). Everything modern game engines mean when they say "state machine."

## Canonical API: closure builder

```wren
import "@hatch:fsm" for StateChart

var fsm = StateChart.build {|chart|
  chart.id("player")
  chart.context({ "hp": 100, "stamina": 50 })

  chart.state("ground") {|s|
    s.initial("idle")
    s.on("jump", "air")              // shorthand: event → target

    s.state("idle") {|i|
      i.on("walk", "walking")
    }
    s.state("walking") {|w|
      w.on("stop", "idle")
      w.on("run", "running")
    }
    s.state("running") {|r|
      r.entry {|ctx, _| ctx["stamina"] = ctx["stamina"] - 1 }
      r.on("stop", "walking")
      r.on("tire") {|t|              // full form: guard + action + target
        t.when {|ctx, _| ctx["stamina"] <= 0 }
        t.does {|ctx, _| ctx["stamina"] = 0 }
        t.go("walking")
      }
    }
  }

  chart.state("air") {|s|
    s.entry {|ctx, _| ctx["jumps"] = (ctx["jumps"] || 0) + 1 }
    s.on("land", "ground")
  }

  chart.parallel("hud") {|h|
    h.state("score")  {|x| x.on("pointGained", "$self") }
    h.state("health") {|x| x.on("damage",      "$self") }
  }

  chart.state("dead") {|d|
    d.final()
  }
}

fsm.start()
fsm.send("walk")              // ground.idle → ground.walking
fsm.send("jump")              // → air (jump declared at ground; bubbles up)
fsm.send("land")              // → ground.idle (re-enters via initial)
fsm.send({"type": "hit", "damage": 20})

fsm.matches("ground.walking") // bool — exact match
fsm.matches("ground")         // bool — true for any substate too
fsm.activeStates              // List<String> — fully-qualified ids
fsm.context["hp"]             // Num
```

### Builder vs map: one source of truth

The builder is the canonical entry point. A `StateChart.fromMap(spec)` adapter exists for cases where the FSM definition arrives as data (hot-reloadable JSON, save files, asset-driven AI configs):

```wren
var fsm = StateChart.fromMap({
  "id": "player",
  "initial": "ground",
  "states": { ... }
})
```

`fromMap` constructs via the same builder internally, so all validation, error messages, and behavior are identical. There's exactly one path through validation; you can't end up with a fsm-from-map that the builder would have rejected.

## How the builder enforces type safety and structural rules

Every "type safe" guarantee folds into one of three places, all at construction time. The compiled chart, once `finish()` returns, is immutable in structure.

### 1. Typed args at each call

Each builder method validates its arguments at the call site. The state's own name is in scope of the error message, so the user always sees which state's builder failed:

```wren
class StateBuilder {
  initial(target) {
    if (!(target is String)) {
      Fiber.abort("state(%(_name)).initial: expected String, got %(target.type)")
    }
    _initial = target
  }

  on(event, target) {                       // shorthand transition
    if (!(event is String)) {
      Fiber.abort("state(%(_name)).on: event must be String")
    }
    if (!(target is String)) {
      Fiber.abort("state(%(_name)).on(%(event)): target must be String")
    }
    _transitions.add(Transition.new(event, target, null, []))
  }

  on(event, blockFn) {                      // builder-form transition
    if (!(blockFn is Fn)) {
      Fiber.abort("state(%(_name)).on(%(event)): 2nd arg must be Fn or String")
    }
    var tb = TransitionBuilder.new(_name, event)
    blockFn.call(tb)
    _transitions.add(tb.finish())
  }

  entry(fn) {
    if (!(fn is Fn)) Fiber.abort("state(%(_name)).entry: expected Fn")
    _entry.add(fn)
  }
}
```

Wren is dynamic, so "type check" means an `is` test plus an explicit abort with a path-tagged message. No reflection, no introspection — the builder's own state carries the path.

### 2. Structural rules as builder mode

The builder is itself a small FSM of what's allowed next. Calling `final()` flips a flag; subsequent `state()` calls error before the user can build something nonsensical:

```wren
state(name, fn) {
  if (_kind == "final")    Fiber.abort("state(%(_name)).final cannot contain substate '%(name)'")
  if (_kind == null)       _kind = "compound"      // implied
  if (_kind == "parallel") Fiber.abort("state(%(_name)) is parallel — substates declared via .parallel only")
  var sub = StateBuilder.new(name, this)
  fn.call(sub)
  _states[name] = sub.finish()
}

final() {
  if (_states.count > 0)      Fiber.abort("state(%(_name)).final: already has substates")
  if (_transitions.count > 0) Fiber.abort("state(%(_name)).final: already has transitions")
  _kind = "final"
}
```

You can't *trick* the builder into invalid configurations — every method that would break an invariant aborts at the offending call.

### 3. Cross-reference resolution at `finish()`

Forward references (`s.on("jump", "air")` *before* `chart.state("air")`) are fine because target resolution waits until the outermost `build` closure returns. One walk over the accumulated tree:

```wren
finish() {
  var ids = {}
  collectIds_(_root, "", ids)

  walk_(_root, "") {|node, path|
    // Compound with substates must declare initial
    if (node.kind == "compound" && node.states.count > 0 && node.initial == null) {
      Fiber.abort("StateChart: compound state '%(path)' has substates but no initial")
    }
    // Initial must point at a substate
    if (node.initial != null && !node.states.containsKey(node.initial)) {
      Fiber.abort("StateChart: '%(path).initial' = '%(node.initial)' is not a substate")
    }
    // Parallel needs ≥2 regions
    if (node.kind == "parallel" && node.states.count < 2) {
      Fiber.abort("StateChart: parallel state '%(path)' has %(node.states.count) substate(s), need ≥2")
    }
    // Transitions must target a real state
    for (t in node.transitions) {
      if (t.target == null || t.target == "$self") continue
      if (!ids.containsKey(resolve_(t.target, path))) {
        Fiber.abort("StateChart: '%(path).on.%(t.event)' targets unknown state '%(t.target)'")
      }
    }
    // History refs only valid for compound parents
    // ... etc.
  }
  return CompiledChart.new(_root, ids)
}
```

This is the only walk-shaped validation. Everything else is gated at the method call.

### What remains as runtime enforcement

A few invariants are only knowable at run time, not at construction. `send()` wraps them:

```wren
send(event) {
  // Re-entrant send (an action calls send() during a step): queue, don't recurse.
  if (_processing) { _pending.add(event); return }
  _processing = true
  var f = Fiber.new {
    step_(event)
    while (_pending.count > 0) step_(_pending.removeAt(0))
  }
  f.try()
  _processing = false
  if (f.error != null) Fiber.abort(f.error)
}

evalGuard_(t, event) {
  if (t.guard == null) return true
  var result = t.guard.call(_context, event)
  if (!(result is Bool)) {
    Fiber.abort("StateChart: guard at '%(t.sourcePath).on.%(t.event)' returned %(result.type), expected Bool")
  }
  return result
}

runAction_(action, event, where) {
  var f = Fiber.new { action.call(_context, event) }
  f.try()
  if (f.error != null) Fiber.abort("StateChart: action %(where) threw: %(f.error)")
}
```

The runtime layer is small because the builder already prevented most ill-formed cases.

## `@hatch:events` integration

`StateChart is EventEmitter`. The same `on` / `once` / `off` / `offAll` / `emit` surface from `@hatch:events` is inherited. The chart publishes well-defined channels:

| Channel | When | Args |
|---|---|---|
| `transition` | any event accepted, before active config updates | `from, to, event` |
| `enter:<full.path>` | a state is entered | `context, event` |
| `exit:<full.path>` | a state is exited | `context, event` |
| `enter:*` / `exit:*` | matches any enter/exit | `(same)` |
| `done` | a final state is reached, or every parallel region hits final | `path` |
| `unhandled` | an event was sent but no transition matched | `event` |
| `*` | every event the chart raises | `name, ...args` |

```wren
fsm.on("transition") {|from, to, event|
  log.info("%(from) → %(to) via %(event)")
}

fsm.on("enter:ground.running") {|ctx, event| sfx.startLoop("footsteps") }
fsm.on("exit:ground.running")  {|ctx, _|     sfx.stopLoop("footsteps")  }

fsm.on("done") {|path| game.advanceLevel() }

fsm.on("*") {|name, args| inspector.record(name, args) }   // wildcard for tooling
```

### Symmetric input — `bindEvents(emitter)`

The chart accepts an external `EventEmitter` as an event source. Anything emitted on it is forwarded to `send()`:

```wren
import "@hatch:events" for EventEmitter

var input = EventEmitter.new()
fsm.bindEvents(input)

// Anywhere in the codebase:
input.emit("jump")                          // → fsm.send("jump")
input.emit("hit", {"damage": 20})           // → fsm.send({"type": "hit", "damage": 20})
```

This is how `@hatch:input`'s action mapper (parity plan P3) feeds the FSM without either side knowing the other exists. Same shape for `world.events` (ECS), network handlers, timer callbacks.

`bindEvents(emitter, filter)` accepts an optional filter `Fn` so a single emitter feeds multiple FSMs differently:

```wren
fsm.bindEvents(world.events, Fn.new {|evt| evt is PlayerInputEvent })
```

### Inline actions vs signal subscribers

Both inline builder actions and external signal subscribers run on the same events. They differ in coupling:

| | Inline (`entry` / `exit` / `does`) | Signal subscriber (`fsm.on(...)`) |
|---|---|---|
| Defined where | inside the builder, with the state | anywhere — main.wren, a component, a system |
| Tied to the FSM definition | yes | no |
| Order within a step | always runs first | runs after inline actions |
| Multiplicity | one per state (or a list) | unbounded subscribers |
| Removable at runtime | no | `off()` / `disconnect()` |

**Rule of thumb:** inline actions for structural behavior (context mutations, follow-up `send`s); signal subscribers for external observation (sound, particles, analytics, save snapshots, debug overlays). If two pieces of code are doing the same kind of work, the inline path belongs in a signal subscriber elsewhere.

### Order of operations during a step

When `send(evt)` fires a transition:

1. Resolve which transitions match the event, evaluate guards in declared order, pick the first that passes
2. Compute the exit set (every active leaf up to the LCA of source and target)
3. **Inline exit actions** run, deepest first
4. **`exit:<path>` signals** emit, deepest first
5. **Inline transition action** runs
6. **`transition` signal** emits
7. Active config updates; history caches recorded
8. Compute the entry set (LCA down to the target, expanded via `initial` / parallel regions)
9. **Inline entry actions** run, shallowest first
10. **`enter:<path>` signals** emit, shallowest first
11. Wildcard `*` channel emits for each of the above
12. Drain queued re-entrant `send`s as microsteps

Inline actions see the *before* config. Signal subscribers see the *after* config and can safely query `fsm.activePath`.

## Hierarchy semantics

Events propagate from each active leaf up the ancestor chain. The first state with a matching handler wins. So `chart.state("air").on("emergency_land", "ground")` is reachable from any nested state inside `air` without redeclaration.

## Parallel regions

A parallel state contains ≥2 regions that tick independently. Each region has its own initial; entering the parallel state enters every region simultaneously. `fsm.activeStates` returns one leaf per region.

```wren
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
```

`fsm.send("move")` advances `locomotion` without touching `weapon`.

## History states

```wren
s.on("resume", "playing.$history")       // shallow
s.on("resume", "playing.$historyDeep")   // deep
```

Entering a `paused` state records the source's last active substate(s). The `$history` resolver expands to the recorded id when the transition fires. Uninitialized history falls back to the compound's `initial`.

## Final states

`d.final()` marks a state as terminal — no transitions out, no substates. When a final state is entered, the chart emits `done` with the state's path. For parallel regions, `done` emits only when *every* region has reached final.

## Self-transitions

```wren
s.on("tick", "$self")                // explicit
s.on("noChange") {|t| t.does(action) } // implicit — no target = self
```

A self-transition still runs entry/exit on the state, which is useful for resetting timers or replaying entry animations. To run actions without exiting/re-entering, use an internal transition (`t.internal()` in the transition builder).

## Implementation sketch

Pure Wren. No native plugin. Internal model:

- **`StateNode`** — id, parent, children, initial substate, kind (`atomic` | `compound` | `parallel` | `final`), event handlers, entry/exit action lists
- **`Transition`** — source path, event, target path (or null), guard fn, action fns, internal flag
- **`CompiledChart`** — root node + id table; immutable after `finish()`
- **`StateChart`** — owns a `CompiledChart`, an active config (Set<path>), a context Map, a history cache (per compound parent), an `EventEmitter` substrate

`send(event)` runs the step described above. `start()` enters the root's initial chain. `stop()` exits everything in reverse.

Conservative LoC budget:
- Builder + validation: ~400 LoC
- Compile pass + walks: ~150 LoC
- Runtime step engine: ~250 LoC
- `EventEmitter` substrate: 0 (inherited)
- Map adapter (`fromMap`): ~100 LoC

Total ~900 LoC of Wren, plus tests.

## Integration consumers (parity plan)

All three downstream consumers from the parity plan collapse to "subscribe to FSM signals." No per-consumer integration API.

### Animator (P5)

```wren
class Animator {
  construct new(skeleton, fsm) {
    _skeleton = skeleton
    _fsm = fsm
    _clips = {}
    fsm.on("enter:*") {|ctx, evt|
      var clip = _clips[fsm.activePath]
      if (clip != null) _skeleton.crossfade(clip, 0.2)
    }
  }
  bindClip(statePath, clipName) { _clips[statePath] = clipName }
}
```

### Game flow controller (P7)

```wren
var gameFSM = StateChart.build {|c|
  c.initial("loading")
  c.state("loading") {|s| s.on("ready", "menu") }
  c.state("menu")    {|s| s.on("play",  "playing") }
  c.state("playing") {|s|
    s.on("pause", "paused")
    s.on("die",   "gameOver")
  }
  c.state("paused")  {|s| s.on("resume", "playing.$historyDeep") }
  c.state("gameOver") {|s| s.on("restart", "playing") }
}

gameFSM.on("enter:paused")  {| _, _ | game.freezeTime() }
gameFSM.on("exit:paused")   {| _, _ | game.resumeTime() }
gameFSM.on("enter:gameOver"){| _, _ | ui.show("GameOver") }
```

### AI behavior

```wren
var enemy = StateChart.build {|c|
  c.initial("patrol")
  c.state("patrol") {|s|
    s.entry {|ctx, _| ctx["target"] = ctx["nextWaypoint"].call() }
    s.on("seePlayer", "chase")
  }
  c.state("chase") {|s|
    s.on("inRange",   "attack")
    s.on("lostPlayer", "patrol")
  }
  c.state("attack") {|s|
    s.on("outOfRange", "chase")
    s.on("died",       "dead")
  }
  c.state("dead") {|s| s.final() }
}

// External wiring: sound, animation, save snapshot
enemy.on("transition") {|from, to, evt| log.debug("AI %(from)→%(to)") }
enemy.on("enter:attack") {| _, _ | sfx.play("warcry") }
```

The "AI navigation" stretch goal in the parity plan covers pathing (navmesh, A*). Statechart-shaped AI lifts out of stretch; pathing stays deferred.

### Save / load (P8)

Saving an FSM is two pieces: the active state config + the context Map. The compiled structure lives in code.

```wren
var snapshot = fsm.snapshot              // {"active": [...], "context": {...}}
File.write("save.json", JSON.encode(snapshot))

// On load:
var saved = JSON.parse(File.read("save.json"))
fsm.restore(saved)
```

Context Map serialization works for primitives + `List` + `Map` + nested-of-same. Document the limitation (no Texture/Fn refs in context across save).

### Debug overlay (P10)

Subscribe to the `*` channel; render to the inspector:

```wren
fsm.on("*") {|name, args| inspector.record(fsm.id, name, args) }
```

F10 toggles a per-FSM panel showing current state config, transition history, last-seen events.

## Phase placement (recap)

Phase **0b** in the parity plan. Pure Wren, no plugin, 1-week budget. Runs in parallel with `@hatch:math` (0a). Land before phase 1 so animator (P5), game flow (P7), AI behavior, save/load (P8), and debug overlay (P10) all have it available.

## Tests

Statecharts have well-defined semantics — easy to spec heavily.

- **Hierarchy:** events bubble; parent handler fires when leaf doesn't catch
- **Initial:** entering a compound state walks `initial` recursively
- **Parallel:** regions advance independently; both regions' entries fire on enter; `done` waits for all regions
- **Guards:** first matching wins; non-bool return aborts with the transition path
- **Actions:** order is inline-exit (deepest first) → exit signals → transition action → transition signal → active update → inline-entry (shallowest first) → enter signals → wildcards
- **History:** shallow vs deep; uninitialized history falls back to `initial`
- **Final:** cannot transition out; parent-of-parallel emits `done` when all children final
- **Self-transition with `target: null` or `"$self"`:** actions run, no state change; internal transition skips entry/exit
- **Context mutation through actions** is visible to subsequent guards in the same microstep batch
- **Re-entrant `send`** during a step queues, doesn't recurse
- **`EventEmitter` contract:** `on`/`once`/`off`/`offAll`/`emit` behave identically to `@hatch:events` baseline
- **`bindEvents` filter:** only matching events forward
- **Builder structural checks:** every error path has its own test (`final` with substate, `parallel` with one region, compound without `initial`, unknown target, non-Fn entry, etc.)

Borrow XState's SCXML-conformant test corpus shape — they have a public test suite we can transliterate.

## Open questions

1. **Async actions / invoked services?**
   XState v5 supports actor model — an entry action can `invoke` a service (promise / fiber) and transition on its completion. We probably don't need it for v1; defer until a real consumer asks. A blocking `Clock.sleep` inside an entry action is the escape hatch.

2. **Internal vs external transitions in the shorthand?**
   `s.on("evt", "target")` is always external (exits + re-enters source). The builder form `s.on("evt") {|t| t.internal().does(...) }` selects internal. Document this — surprising default if you don't know SCXML.

3. **Context serialization across save/load.**
   Works for `Map` / `List` / primitive trees. Won't round-trip `Texture` / `Fn` / `*mut`. Document the limitation; later: a `@serializable` opt-in marker per component class.

4. **Wildcard event handler vs wildcard channel.**
   `*` exists as a signal channel (subscribe to "every event the FSM raises"). XState also has a wildcard *transition* (`s.on("*", target)` — fires on any event that wouldn't otherwise match). Ship the channel; defer the transition unless a real consumer wants it.

5. **Replayability.**
   Capture every `send` and the resulting transition path; replay deterministically given the same compiled chart. Useful for debugging non-trivial AI. Builds on the debug overlay (P10).
