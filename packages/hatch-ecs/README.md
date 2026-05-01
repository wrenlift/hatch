A pure-Wren entity-component-system. `World` for storage, `Query` for filtered iteration, `Bundle` for one-call spawns, typed `Resources` and `Events<T>`, deferred `Commands` for mid-loop mutation, parent/child hierarchy via `setParent`, `onAdd` / `onRemove` lifecycle hooks, and a `Schedule` with `before` / `after` ordering for system dispatch. Composes with `@hatch:game`'s frame loop and runs anywhere Wren runs.

## Overview

Storage is `Map<ComponentClass, Map<id, instance>>` — class-keyed pools, monotonic ids. That trades archetype-iteration speed for an API small enough to keep in your head, and stays plenty fast at the few-thousand-entity scale most 2D and mid-size 3D games sit at.

```wren
import "@hatch:ecs" for World, Schedule

class Position { construct new(x, y) { _x = x; _y = y } x { _x } y { _y } x=(v) { _x = v } y=(v) { _y = v } }
class Velocity { construct new(x, y) { _x = x; _y = y } x { _x } y { _y } }
class Sprite   { construct new(img)  { _img = img }    image { _img } }

var world = World.new()
var hero  = world.spawnWith([
  Position.new(100, 100),
  Velocity.new(50, 0),
  Sprite.new(heroTexture)
])

var schedule = Schedule.new()
schedule.add("physics") {|w, ctx|
  for (e in w.query.with(Position).with(Velocity).iterate) {
    var p = w.get(e, Position)
    var v = w.get(e, Velocity)
    p.x = p.x + v.x * ctx["dt"]
    p.y = p.y + v.y * ctx["dt"]
  }
}
schedule.add("render") {|w, ctx| /* draw sprites */ }
schedule.after("render", "physics")

schedule.run(world, { "dt": 1 / 60 })
```

## Cross-cutting pieces

`Resources` are typed singletons attached to the world — input state, the current camera, an asset db. `Events<T>` is a per-type broadcast buffer: producers push during one system, consumers drain during the next, and `world.flushEvents` clears at the end of the frame. `Commands` is the deferred-mutation escape hatch — record `spawn` / `despawn` / `attach` calls during a query body, then apply them with `world.applyCommands(cmds)` once iteration completes.

`world.onAdd(Class) {|w, e, c| ... }` and `world.onRemove(Class) {|w, e| ... }` fire on component lifecycle. Use them for animation triggers, audio, or to maintain spatial indexes.

> **Tip — query during, mutate after**
> Spawning or despawning entities mid-iteration invalidates the active query. Use `Commands` to record changes inside the loop, then `world.applyCommands(cmds)` once. Same shape as Bevy's deferred command buffer.

## Compatibility

Wren 0.4 + WrenLift runtime 0.1 or newer. Pure-Wren — no native dependencies. Optional integration with `@hatch:game` for the frame loop and with `@hatch:gpu` for GPU-resource components.
