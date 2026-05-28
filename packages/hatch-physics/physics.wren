// `@hatch:physics`: rapier-backed physics for the WrenLift game
// framework. `World2D` and `World3D` ship in the same import and
// share an identical API shape. The only divergence is dimensional
// types (`[x, y]` vs `[x, y, z]`).
//
// ```wren
// import "@hatch:physics" for World2D, Collider2D
//
// var world = World2D.new({"gravity": [0, -9.81]})
// var ground = world.spawnStatic({
//   "position": [0, -5],
//   "shape":    Collider2D.box(50, 0.5)
// })
// var ball = world.spawnDynamic({
//   "position": [0, 5],
//   "shape":    Collider2D.ball(0.5),
//   "mass":     1.0,
//   "shape":    Collider2D.ball(0.5, {"restitution": 0.9})
// })
//
// while (running) {
//   world.step(g.dt)
//   var p = world.position(ball)
//   // hand p[0], p[1] to your sprite / camera
// }
// ```
//
// v0 covers: rigid bodies (dynamic / static / kinematic),
// primitive colliders (ball / box / capsule), restitution +
// friction tuning, gravity, force/impulse, position +
// linearVelocity reads + writes, despawn.
//
// Planned (rapier supports all of them; we wrap them as the
// framework matures): rotation read / write, raycasts, joints,
// sensors, contact event streams, kinematic-target motion.

#!native = "wlift_physics"
foreign class PhysicsCore {
  // -- 2D --------------------------------------------------------
  #!symbol = "wlift_physics_world2d_create"
  foreign static world2dCreate(descriptor)
  #!symbol = "wlift_physics_world2d_destroy"
  foreign static world2dDestroy(id)
  #!symbol = "wlift_physics_world2d_step"
  foreign static world2dStep(id, dt)
  #!symbol = "wlift_physics_world2d_spawn_dynamic"
  foreign static world2dSpawnDynamic(worldId, descriptor)
  #!symbol = "wlift_physics_world2d_spawn_static"
  foreign static world2dSpawnStatic(worldId, descriptor)
  #!symbol = "wlift_physics_world2d_spawn_kinematic"
  foreign static world2dSpawnKinematic(worldId, descriptor)
  #!symbol = "wlift_physics_world2d_despawn"
  foreign static world2dDespawn(worldId, bodyId)
  #!symbol = "wlift_physics_world2d_position"
  foreign static world2dPosition(worldId, bodyId)
  #!symbol = "wlift_physics_world2d_rotation"
  foreign static world2dRotation(worldId, bodyId)
  #!symbol = "wlift_physics_world2d_linear_velocity"
  foreign static world2dLinearVelocity(worldId, bodyId)
  #!symbol = "wlift_physics_world2d_set_linear_velocity"
  foreign static world2dSetLinearVelocity(worldId, bodyId, x, y)
  #!symbol = "wlift_physics_world2d_apply_impulse"
  foreign static world2dApplyImpulse(worldId, bodyId, x, y)
  #!symbol = "wlift_physics_world2d_apply_force"
  foreign static world2dApplyForce(worldId, bodyId, x, y)

  // -- 3D --------------------------------------------------------
  #!symbol = "wlift_physics_world3d_create"
  foreign static world3dCreate(descriptor)
  #!symbol = "wlift_physics_world3d_destroy"
  foreign static world3dDestroy(id)
  #!symbol = "wlift_physics_world3d_step"
  foreign static world3dStep(id, dt)
  #!symbol = "wlift_physics_world3d_spawn_dynamic"
  foreign static world3dSpawnDynamic(worldId, descriptor)
  #!symbol = "wlift_physics_world3d_spawn_static"
  foreign static world3dSpawnStatic(worldId, descriptor)
  #!symbol = "wlift_physics_world3d_spawn_kinematic"
  foreign static world3dSpawnKinematic(worldId, descriptor)
  #!symbol = "wlift_physics_world3d_despawn"
  foreign static world3dDespawn(worldId, bodyId)
  #!symbol = "wlift_physics_world3d_position"
  foreign static world3dPosition(worldId, bodyId)
  #!symbol = "wlift_physics_world3d_position_into"
  foreign static world3dPositionInto(worldId, bodyId, out, offset)
  #!symbol = "wlift_physics_world3d_rotation"
  foreign static world3dRotation(worldId, bodyId)
  #!symbol = "wlift_physics_world3d_rotation_into"
  foreign static world3dRotationInto(worldId, bodyId, out, offset)
  #!symbol = "wlift_physics_world3d_linear_velocity"
  foreign static world3dLinearVelocity(worldId, bodyId)
  #!symbol = "wlift_physics_world3d_set_linear_velocity"
  foreign static world3dSetLinearVelocity(worldId, bodyId, x, y, z)
  #!symbol = "wlift_physics_world3d_apply_impulse"
  foreign static world3dApplyImpulse(worldId, bodyId, x, y, z)
  #!symbol = "wlift_physics_world3d_apply_force"
  foreign static world3dApplyForce(worldId, bodyId, x, y, z)

  // -- Raycasts + contact events (Phase 4) ----------------------
  #!symbol = "wlift_physics_world3d_cast_ray"
  foreign static world3dCastRay(worldId, ox, oy, oz, dx, dy, dz, maxToi, solid)
  #!symbol = "wlift_physics_world2d_cast_ray"
  foreign static world2dCastRay(worldId, ox, oy, dx, dy, maxToi, solid)
  #!symbol = "wlift_physics_world3d_drain_contact_events"
  foreign static world3dDrainContactEvents(worldId)
  #!symbol = "wlift_physics_world2d_drain_contact_events"
  foreign static world2dDrainContactEvents(worldId)
}

/// -- 2D ----------------------------------------------------------

class World2D {
  static new(descriptor) { World2D.new_(PhysicsCore.world2dCreate(descriptor)) }
  static new() { World2D.new({}) }

  construct new_(id) { _id = id }

  id { _id }

  step(dt) { PhysicsCore.world2dStep(_id, dt) }

  /// Body spawn descriptor keys:
  ///
  /// | Key              | Type             | Notes                                  |
  /// |------------------|------------------|----------------------------------------|
  /// | `position`       | `[x, y]`         | Default `[0, 0]`.                      |
  /// | `linearVelocity` | `[x, y]`         | Default `[0, 0]`.                      |
  /// | `shape`          | `Collider2D` Map | Required.                              |
  /// | `mass`           | `Num`            | Additional mass for dynamic bodies.    |
  spawnDynamic(descriptor)   { PhysicsCore.world2dSpawnDynamic(_id, descriptor) }
  spawnStatic(descriptor)    { PhysicsCore.world2dSpawnStatic(_id, descriptor) }
  spawnKinematic(descriptor) { PhysicsCore.world2dSpawnKinematic(_id, descriptor) }
  despawn(bodyId)            { PhysicsCore.world2dDespawn(_id, bodyId) }

  /// Read-back helpers. Returns Lists for cheap `[x, y]` results.
  position(bodyId)       { PhysicsCore.world2dPosition(_id, bodyId) }
  /// Body orientation as a `Num` — the angle in radians around
  /// the implicit Z axis. Positive values rotate
  /// counter-clockwise in screen space.
  /// @returns {Num}
  rotation(bodyId)       { PhysicsCore.world2dRotation(_id, bodyId) }
  linearVelocity(bodyId) { PhysicsCore.world2dLinearVelocity(_id, bodyId) }

  /// Write-back / forces.
  setLinearVelocity(bodyId, x, y) { PhysicsCore.world2dSetLinearVelocity(_id, bodyId, x, y) }
  applyImpulse(bodyId, x, y)      { PhysicsCore.world2dApplyImpulse(_id, bodyId, x, y) }
  applyForce(bodyId, x, y)        { PhysicsCore.world2dApplyForce(_id, bodyId, x, y) }

  /// Cast a ray from `(ox, oy)` along `(dx, dy)`. Returns the
  /// first hit as a Map `{ bodyId, point: [x, y], normal: [x, y],
  /// toi }` or `null` if nothing was hit within `maxToi`.
  /// `solid` defaults to `true` — when the ray starts *inside*
  /// a shape, a solid hit returns `toi = 0` so the caller knows
  /// the origin is intersecting; pass `false` to keep marching
  /// until the ray exits the shape (sensor-style sweeps).
  ///
  /// `point` and `normal` are 2-element Lists; the underlying
  /// plugin emits the 3-element shape `World3D` uses with the
  /// `z` slot zeroed for parity, but only the first two
  /// elements are meaningful in 2D.
  ///
  /// @param  {Num}    ox
  /// @param  {Num}    oy
  /// @param  {Num}    dx
  /// @param  {Num}    dy
  /// @param  {Num}    maxToi   max distance to march
  /// @param  {Bool}   solid    optional, default `true`
  /// @returns {Map?}
  castRay(ox, oy, dx, dy, maxToi)        { castRay(ox, oy, dx, dy, maxToi, true) }
  castRay(ox, oy, dx, dy, maxToi, solid) {
    return PhysicsCore.world2dCastRay(_id, ox, oy, dx, dy, maxToi, solid)
  }

  /// Drain every contact event captured during the most recent
  /// `step`. Returns a List of `{ a, b, started }` Maps where
  /// `a` and `b` are body IDs and `started` is `true` for
  /// touch-start, `false` for touch-stop. The internal buffer
  /// is cleared on each call — re-call after the next `step`
  /// to read the next batch.
  ///
  /// @returns {List<Map>}
  drainContactEvents { PhysicsCore.world2dDrainContactEvents(_id) }

  destroy {
    PhysicsCore.world2dDestroy(_id)
    _id = -1
  }
}

/// Collider descriptors. Each helper returns a plain Map ready to
/// drop into `spawnDynamic({"shape": ..., ...})`. `options` (Map,
/// optional) carries `restitution` (0..=1) and `friction`.
class Collider2D {
  static ball(radius)               { ball(radius, {}) }
  static ball(radius, options)      { Collider2D.merge_({"kind": "ball", "radius": radius}, options) }
  static box(halfWidth, halfHeight) { box(halfWidth, halfHeight, {}) }
  static box(halfWidth, halfHeight, options) {
    return Collider2D.merge_({
      "kind": "box", "halfWidth": halfWidth, "halfHeight": halfHeight
    }, options)
  }
  static capsule(halfHeight, radius)          { capsule(halfHeight, radius, {}) }
  static capsule(halfHeight, radius, options) {
    return Collider2D.merge_({
      "kind": "capsule", "halfHeight": halfHeight, "radius": radius
    }, options)
  }

  static merge_(base, options) {
    if (!(options is Map)) return base
    for (k in options.keys) base[k] = options[k]
    return base
  }
}

/// -- 3D ----------------------------------------------------------

class World3D {
  static new(descriptor) { World3D.new_(PhysicsCore.world3dCreate(descriptor)) }
  static new() { World3D.new({}) }

  construct new_(id) { _id = id }

  id { _id }

  step(dt) { PhysicsCore.world3dStep(_id, dt) }

  spawnDynamic(descriptor)   { PhysicsCore.world3dSpawnDynamic(_id, descriptor) }
  spawnStatic(descriptor)    { PhysicsCore.world3dSpawnStatic(_id, descriptor) }
  spawnKinematic(descriptor) { PhysicsCore.world3dSpawnKinematic(_id, descriptor) }
  despawn(bodyId)            { PhysicsCore.world3dDespawn(_id, bodyId) }

  position(bodyId)       { PhysicsCore.world3dPosition(_id, bodyId) }
  /// Non-allocating position read — write the body's (x, y, z)
  /// into `out` (a `Float32Array`) starting at element `offset`.
  /// Use this in hot per-frame paths to dodge the `List<Num>`
  /// alloc that `position(bodyId)` returns. Three f32s written
  /// per call.
  ///
  /// @param {Num} bodyId
  /// @param {Float32Array} out
  /// @param {Num} offset. Element index (not byte offset).
  positionInto(bodyId, out, offset) {
    PhysicsCore.world3dPositionInto(_id, bodyId, out, offset)
  }
  /// Body orientation as a `List<Num>` in scalar-first quaternion
  /// layout: `[w, x, y, z]`. Construct a `@hatch:math.Quat` from
  /// it directly: `Quat.new(q[0], q[1], q[2], q[3])`.
  /// @returns {List<Num>}
  rotation(bodyId)       { PhysicsCore.world3dRotation(_id, bodyId) }
  /// Non-allocating rotation read — same shape as `positionInto`,
  /// writes 4 f32s in (w, x, y, z) scalar-first order.
  ///
  /// @param {Num} bodyId
  /// @param {Float32Array} out
  /// @param {Num} offset. Element index (not byte offset).
  rotationInto(bodyId, out, offset) {
    PhysicsCore.world3dRotationInto(_id, bodyId, out, offset)
  }
  linearVelocity(bodyId) { PhysicsCore.world3dLinearVelocity(_id, bodyId) }

  setLinearVelocity(bodyId, x, y, z) { PhysicsCore.world3dSetLinearVelocity(_id, bodyId, x, y, z) }
  applyImpulse(bodyId, x, y, z)      { PhysicsCore.world3dApplyImpulse(_id, bodyId, x, y, z) }
  applyForce(bodyId, x, y, z)        { PhysicsCore.world3dApplyForce(_id, bodyId, x, y, z) }

  /// Cast a ray from `(ox, oy, oz)` along `(dx, dy, dz)`.
  /// Returns the first hit as a Map
  /// `{ bodyId, point: [x, y, z], normal: [x, y, z], toi }`
  /// or `null` if nothing was hit within `maxToi`. `solid`
  /// defaults to `true` (see `World2D.castRay` for the
  /// solid-vs-hollow distinction).
  ///
  /// Useful for projectile hit detection, line-of-sight checks,
  /// reticle picking, footstep audio surface detection, and the
  /// "click-to-place" pattern in editors.
  ///
  /// @param  {Num}    ox
  /// @param  {Num}    oy
  /// @param  {Num}    oz
  /// @param  {Num}    dx
  /// @param  {Num}    dy
  /// @param  {Num}    dz
  /// @param  {Num}    maxToi
  /// @param  {Bool}   solid    optional, default `true`
  /// @returns {Map?}
  castRay(ox, oy, oz, dx, dy, dz, maxToi)        { castRay(ox, oy, oz, dx, dy, dz, maxToi, true) }
  castRay(ox, oy, oz, dx, dy, dz, maxToi, solid) {
    return PhysicsCore.world3dCastRay(_id, ox, oy, oz, dx, dy, dz, maxToi, solid)
  }

  /// Same as `World2D.drainContactEvents` — see that docstring
  /// for lifecycle. Returns body-ID-keyed pairs (`a`, `b`) and
  /// the touch-start / touch-stop flag (`started`).
  ///
  /// @returns {List<Map>}
  drainContactEvents { PhysicsCore.world3dDrainContactEvents(_id) }

  destroy {
    PhysicsCore.world3dDestroy(_id)
    _id = -1
  }
}

class Collider3D {
  static ball(radius)             { ball(radius, {}) }
  static ball(radius, options)    { Collider3D.merge_({"kind": "ball", "radius": radius}, options) }
  static box(halfX, halfY, halfZ) { box(halfX, halfY, halfZ, {}) }
  static box(halfX, halfY, halfZ, options) {
    return Collider3D.merge_({
      "kind": "box", "halfX": halfX, "halfY": halfY, "halfZ": halfZ
    }, options)
  }
  static capsule(halfHeight, radius)          { capsule(halfHeight, radius, {}) }
  static capsule(halfHeight, radius, options) {
    return Collider3D.merge_({
      "kind": "capsule", "halfHeight": halfHeight, "radius": radius
    }, options)
  }

  static merge_(base, options) {
    if (!(options is Map)) return base
    for (k in options.keys) base[k] = options[k]
    return base
  }
}
