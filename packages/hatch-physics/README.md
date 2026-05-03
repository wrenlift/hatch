Rapier-backed rigid-body physics for the WrenLift game framework. `World2D` and `World3D` come from one import and share an identical API shape; the only divergence is dimensional types (`[x, y]` versus `[x, y, z]`). Bundles `rapier2d` and `rapier3d` in a single cdylib so games never have to choose between dimensions at the package level.

## Overview

Spawn dynamic bodies you simulate, static bodies you anchor to the world, or kinematic bodies whose position you drive directly. Step once per frame; read positions and velocities back out for rendering.

```wren
import "@hatch:physics" for World2D, Collider2D

var world = World2D.new({ "gravity": [0, -9.81] })

var ground = world.spawnStatic({
  "position": [0, -5],
  "shape":    Collider2D.box(50, 0.5)
})

var ball = world.spawnDynamic({
  "position": [0, 5],
  "mass":     1.0,
  "shape":    Collider2D.ball(0.5, { "restitution": 0.9 })
})

while (running) {
  world.step(g.dt)
  var p = world.position(ball)
  sprite.x = p[0]
  sprite.y = p[1]
}
```

`world.applyImpulse(body, fx, fy)` and `world.applyForce(body, fx, fy)` cover the usual gameplay nudges. `world.setLinearVelocity(body, vx, vy)` stamps a velocity directly. `world.despawn(body)` removes the body and its colliders.

`Collider2D` and `Collider3D` expose the primitive shapes (`ball(radius)`, `box(hx, hy[, hz])`, `capsule(halfHeight, radius)`), each accepting a per-shape options `Map` for restitution and friction tuning.

> **Note: what's not in this release**
> Rotation read/write, raycasts, joints, sensors, contact event streams, and kinematic-target motion are all planned. Rapier supports them all; the wrappers land as the framework matures. Simulations that need any of those today should drop down to the foreign API or pin to the version that ships them.

## Wiring into the frame loop

`@hatch:game` does not auto-step physics; keep that under your control. The conventional shape:

```wren
update(g) {
  _world.step(g.dt)
  // sync transforms from physics → ECS
}
```

Sub-stepping (calling `world.step(g.dt / n)` n times per frame) gives stability on stiff systems at the cost of CPU. Rapier itself is deterministic for fixed `dt`.

## Compatibility

Wren 0.4 with WrenLift runtime 0.1 or newer. Native only. `#!wasm` builds need a separate WebAssembly Rapier pipeline that has not shipped yet. Pair with `@hatch:game` and `@hatch:ecs` for entity-driven physics.
