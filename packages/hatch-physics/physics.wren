// @hatch:physics — rapier-backed physics for the WrenLift game
// framework. World2D and World3D in the same import; identical
// API shape with the only divergence being dimensional types
// (`[x, y]` vs `[x, y, z]`).
//
//   import "@hatch:physics" for World2D, Collider2D
//
//   var world = World2D.new({"gravity": [0, -9.81]})
//   var ground = world.spawnStatic({
//     "position": [0, -5],
//     "shape":    Collider2D.box(50, 0.5)
//   })
//   var ball = world.spawnDynamic({
//     "position": [0, 5],
//     "shape":    Collider2D.ball(0.5),
//     "mass":     1.0,
//     "shape":    Collider2D.ball(0.5, {"restitution": 0.9})
//   })
//
//   while (running) {
//     world.step(g.dt)
//     var p = world.position(ball)
//     // hand p[0], p[1] to your sprite / camera
//   }
//
// v0 covers: rigid bodies (dynamic / static / kinematic),
// primitive colliders (ball / box / capsule), restitution +
// friction tuning, gravity, force/impulse, position +
// linearVelocity reads + writes, despawn.
//
// Out of scope for v0: rotation read/write, raycasts, joints,
// sensors, contact event streams, kinematic-target motion.
// Rapier supports all of them; we wrap them as the framework
// matures.

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
  #!symbol = "wlift_physics_world3d_linear_velocity"
  foreign static world3dLinearVelocity(worldId, bodyId)
  #!symbol = "wlift_physics_world3d_set_linear_velocity"
  foreign static world3dSetLinearVelocity(worldId, bodyId, x, y, z)
  #!symbol = "wlift_physics_world3d_apply_impulse"
  foreign static world3dApplyImpulse(worldId, bodyId, x, y, z)
  #!symbol = "wlift_physics_world3d_apply_force"
  foreign static world3dApplyForce(worldId, bodyId, x, y, z)
}

/// -- 2D ----------------------------------------------------------

class World2D {
  static new(descriptor) { World2D.new_(PhysicsCore.world2dCreate(descriptor)) }
  static new() { World2D.new({}) }

  construct new_(id) { _id = id }

  id { _id }

  step(dt) { PhysicsCore.world2dStep(_id, dt) }

  /// Body spawn — descriptor keys:
  ///   "position":       [x, y]              (default [0, 0])
  ///   "linearVelocity": [x, y]              (default [0, 0])
  ///   "shape":          Collider2D Map      (required)
  ///   "mass":           Num                 (additional mass for dynamic bodies)
  spawnDynamic(descriptor)   { PhysicsCore.world2dSpawnDynamic(_id, descriptor) }
  spawnStatic(descriptor)    { PhysicsCore.world2dSpawnStatic(_id, descriptor) }
  spawnKinematic(descriptor) { PhysicsCore.world2dSpawnKinematic(_id, descriptor) }
  despawn(bodyId)            { PhysicsCore.world2dDespawn(_id, bodyId) }

  /// Read-back helpers — Lists for cheap [x, y] returns.
  position(bodyId)       { PhysicsCore.world2dPosition(_id, bodyId) }
  linearVelocity(bodyId) { PhysicsCore.world2dLinearVelocity(_id, bodyId) }

  /// Write-back / forces.
  setLinearVelocity(bodyId, x, y) { PhysicsCore.world2dSetLinearVelocity(_id, bodyId, x, y) }
  applyImpulse(bodyId, x, y)      { PhysicsCore.world2dApplyImpulse(_id, bodyId, x, y) }
  applyForce(bodyId, x, y)        { PhysicsCore.world2dApplyForce(_id, bodyId, x, y) }

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
  linearVelocity(bodyId) { PhysicsCore.world3dLinearVelocity(_id, bodyId) }

  setLinearVelocity(bodyId, x, y, z) { PhysicsCore.world3dSetLinearVelocity(_id, bodyId, x, y, z) }
  applyImpulse(bodyId, x, y, z)      { PhysicsCore.world3dApplyImpulse(_id, bodyId, x, y, z) }
  applyForce(bodyId, x, y, z)        { PhysicsCore.world3dApplyForce(_id, bodyId, x, y, z) }

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
