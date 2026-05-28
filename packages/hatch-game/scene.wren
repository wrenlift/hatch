// `@hatch:game` scene module: Transform + GlobalTransform +
// TransformPropagation. The minimum hierarchy layer Renderer3D
// and physics consume. Transform itself is ECS-agnostic — it's
// just a class — and the propagation system bridges it with
// `@hatch:ecs`'s built-in `Parent` / `Children` components.
//
// Layout: T * R * S, right-handed. World = parent.world * local.

import "@hatch:math" for Vec3, Mat4, Quat
import "@hatch:ecs"  for Parent, Children

// Reference forward axis for a directional / spot light entity:
// rotating this by the entity's Transform.rotation gives the
// light's "direction it travels in" vector. Right-handed: the
// camera looks down -Z, so a freshly-built Transform points in
// the same direction.
var LIGHT_FORWARD_ = Vec3.new(0, 0, -1)

/// Local-space TRS placement: position (`Vec3`), rotation (`Quat`),
/// scale (`Vec3`). The local matrix is computed lazily on first
/// read and re-computed whenever a setter fires; the cached value
/// stays valid until then.
///
/// ## Example
///
/// ```wren
/// var t = Transform.new()
/// t.position = Vec3.new(1, 2, 3)
/// t.rotation = Quat.fromAxisAngle(Vec3.unitY, 0.5)
/// var m = t.localMatrix
/// ```
class Transform {
  /// Identity transform: zero translation, identity rotation,
  /// unit scale. Mutate via the `position` / `rotation` / `scale`
  /// setters once constructed.
  construct new() {
    _position = Vec3.zero
    _rotation = Quat.identity
    _scale    = Vec3.one
    _dirty    = true
    _local    = null
  }

  /// Construct from explicit components. Any argument can be
  /// `null` to take the identity default for that slot.
  ///
  /// @param {Vec3} position. World-frame translation. `null` →
  ///   `Vec3.zero`.
  /// @param {Quat} rotation. Unit quaternion. `null` →
  ///   `Quat.identity`.
  /// @param {Vec3} scale. Per-axis scale. `null` → `Vec3.one`.
  construct new(position, rotation, scale) {
    _position = position == null ? Vec3.zero    : position
    _rotation = rotation == null ? Quat.identity : rotation
    _scale    = scale    == null ? Vec3.one     : scale
    _dirty    = true
    _local    = null
  }

  /// Identity placement: zero translation, identity rotation,
  /// unit scale. Convenience for `Transform.new()`; same shape,
  /// reads better at call sites that emphasise the default.
  static identity { Transform.new() }

  /// Pure-translation placement. Quick path for scene roots and
  /// static props.
  static translation(x, y, z) {
    var t = Transform.new()
    t.position = Vec3.new(x, y, z)
    return t
  }

  position    { _position }
  position=(v) {
    _position = v
    _dirty = true
  }

  rotation    { _rotation }
  rotation=(q) {
    _rotation = q
    _dirty = true
  }

  scale     { _scale }
  scale=(v) {
    _scale = v
    _dirty = true
  }

  /// Locally-cached `Mat4` for `T * R * S`. Re-computes only when
  /// one of the components has changed since the last read.
  localMatrix {
    if (_dirty || _local == null) {
      var t = Mat4.translation(_position.x, _position.y, _position.z)
      var r = _rotation.toMat4
      var s = Mat4.scale(_scale.x, _scale.y, _scale.z)
      _local = t * r * s
      _dirty = false
    }
    return _local
  }

  /// Explicit invalidation hook for callers that mutate one of
  /// the components in place rather than via the setter (e.g.
  /// `t.position.x = ...` when `Vec3` is mutable). Cheap; the
  /// matrix re-builds on the next `localMatrix` read.
  invalidate { _dirty = true }

  toString { "Transform(p=%(_position), r=%(_rotation), s=%(_scale))" }
}

/// Propagated world-space `Mat4`. Written by `TransformPropagation`
/// once per frame; consumers (Renderer3D, physics sync, audio
/// listener placement) read `matrix` and treat it as read-only.
///
/// A user normally never constructs one of these — the propagation
/// system attaches it on first run. Storing the matrix on a
/// dedicated component keeps the read path branch-free (no "did
/// this entity get propagated yet?" check) and makes ECS queries
/// trivial: `world.query(GlobalTransform)`.
class GlobalTransform {
  /// Internal — the propagation system constructs these on first
  /// walk; user code only reads `matrix`.
  ///
  /// @param {Mat4} matrix. The seed world-space matrix.
  construct new_(matrix) { _matrix = matrix }

  /// World-space `Mat4`. Identity if the entity has no `Transform`
  /// or hasn't been propagated yet (the propagation system
  /// allocates the component on first walk; before then there's
  /// nothing to read).
  matrix    { _matrix }
  matrix=(m) { _matrix = m }

  toString { "GlobalTransform(%(_matrix))" }
}

/// ECS-side bind between an entity and its drawable: a
/// `@hatch:gpu` `Mesh` + the `Material` it draws with. The
/// renderer reads `(Transform, MeshRenderer)` (or the propagated
/// `GlobalTransform` once `TransformPropagation` has run) and
/// records one draw per match.
///
/// ## Example
///
/// ```wren
/// var e = world.spawn()
/// world.attach(e, Transform.new())
/// world.attach(e, MeshRenderer.new(cubeMesh, redMaterial))
/// ```
class MeshRenderer {
  /// Bind `mesh` + `material` to this entity. `visible` defaults
  /// to `true`; flip via the `visible=` setter to cull without
  /// detaching the component.
  ///
  /// @param {Mesh} mesh. `@hatch:gpu` `Mesh` handle to draw.
  /// @param {Material} material. `@hatch:gpu` `Material` used for
  ///   shading.
  construct new(mesh, material) {
    _mesh = mesh
    _material = material
    _visible = true
  }

  /// The `@hatch:gpu` `Mesh` handle to draw.
  mesh        { _mesh }
  mesh=(m)    { _mesh = m }

  /// The `@hatch:gpu` `Material` describing how to shade `mesh`.
  material    { _material }
  material=(m) { _material = m }

  /// Cull flag. When false the renderer skips this entity for the
  /// frame; the Transform / GlobalTransform components stay
  /// up-to-date so flipping back is free.
  visible     { _visible }
  visible=(v) { _visible = v }

  toString { "MeshRenderer(mesh=%(_mesh), material=%(_material))" }
}

/// Physics body component. Plain data — the bridge to a real
/// physics simulation (`PhysicsSystem3D` / `PhysicsSystem2D`)
/// reads the kind / mass / spawn metadata, calls the world's
/// `spawnDynamic` / `spawnStatic` / `spawnKinematic`, and stashes
/// the returned `bodyId` here for the sync-back pass.
///
/// `kind` is one of `"dynamic"` (gravity + force + collision
/// response), `"static"` (immovable, infinite mass), or
/// `"kinematic"` (animated by gameplay, collides with dynamics
/// but isn't pushed by them).
///
/// ## Example
///
/// ```wren
/// var ball = world.spawn()
/// world.attach(ball, Transform.translation(0, 5, 0))
/// world.attach(ball, RigidBody.new("dynamic", 1.0))
/// world.attach(ball, Collider.new(Collider3D.ball(0.5)))
/// ```
class RigidBody {
  /// Default: dynamic, mass 1.0, no initial linear velocity.
  construct new() {
    _kind = "dynamic"
    _mass = 1.0
    _linearVelocity = null
    _bodyId = null
  }

  /// Explicit kind only.
  ///
  /// @param {String} kind. `"dynamic"` / `"static"` / `"kinematic"`.
  construct new(kind) {
    _kind = kind
    _mass = 1.0
    _linearVelocity = null
    _bodyId = null
  }

  /// Explicit kind + mass.
  ///
  /// @param {String} kind. `"dynamic"` / `"static"` / `"kinematic"`.
  /// @param {Num} mass. Body mass in kg. Ignored for static bodies.
  construct new(kind, mass) {
    _kind = kind
    _mass = mass
    _linearVelocity = null
    _bodyId = null
  }

  /// `"dynamic"` / `"static"` / `"kinematic"`.
  /// @returns {String}
  kind     { _kind }
  kind=(v) { _kind = v }

  /// Body mass in kg. Static bodies treat this as infinite.
  /// @returns {Num}
  mass     { _mass }
  mass=(v) { _mass = v }

  /// Optional initial linear velocity. Set before the body is
  /// first spawned to start moving at frame 0; mutations after
  /// spawn are ignored (use the physics world's
  /// `setLinearVelocity(bodyId, ...)` to change at runtime).
  ///
  /// @returns {Vec3|Null}
  linearVelocity     { _linearVelocity }
  linearVelocity=(v) { _linearVelocity = v }

  /// Internal — physics body handle. `null` until
  /// `PhysicsSystem3D.step` registers the body with the world.
  /// Consumers read this to call physics-world methods directly
  /// (apply force, set velocity, raycast filter, etc.).
  ///
  /// @returns {Num|Null}
  bodyId        { _bodyId }
  bodyId_=(id)  { _bodyId = id }

  toString { "RigidBody(kind=%(_kind), mass=%(_mass), bodyId=%(_bodyId))" }
}

/// Collision shape component. Wraps a descriptor from
/// `@hatch:physics`'s `Collider3D` / `Collider2D` static
/// builders (a `Map` describing the kind + dimensions +
/// material parameters like restitution / friction).
///
/// ## Example
///
/// ```wren
/// world.attach(ball, Collider.new(Collider3D.ball(0.5, {
///   "restitution": 0.6, "friction": 0.1
/// })))
/// ```
class Collider {
  /// Build from a shape descriptor.
  ///
  /// @param {Map} shape. The `Collider3D.X` / `Collider2D.X`
  ///   Map; opaque to this class.
  construct new(shape) {
    _shape = shape
  }

  /// The shape descriptor passed at construction. The physics
  /// bridge forwards this verbatim to `world.spawnX(descriptor)`.
  /// @returns {Map}
  shape     { _shape }
  shape=(s) { _shape = s }

  toString { "Collider(%(_shape))" }
}

/// Frame-once bridge between an ECS world and a 3D physics
/// world (anything with the `@hatch:physics.World3D` shape:
/// `.spawnDynamic` / `.spawnStatic` / `.spawnKinematic` /
/// `.step(dt)` / `.position(bodyId)`). Duck-typed on those
/// methods — `@hatch:game` doesn't depend on `@hatch:physics`.
///
/// Call order:
///
/// ```wren
/// update(g) {
///   PhysicsSystem3D.step(_world, _physics, g.dt)
///   TransformPropagation.run(_world)
/// }
/// ```
///
/// `step` does three things, in order:
/// 1. For every `(RigidBody, Collider, Transform)` entity whose
///    `RigidBody.bodyId` is still null, spawn a body in the
///    physics world (`dynamic` / `static` / `kinematic` based on
///    `RigidBody.kind`) seeded from `Transform.position` +
///    `RigidBody.linearVelocity`. Store the returned `bodyId`.
/// 2. Advance the physics world by `dt`.
/// 3. For every entity with a registered `bodyId` and a
///    non-static `RigidBody`, read `physicsWorld.position(bodyId)`
///    and write it back into the entity's `Transform.position`.
class PhysicsSystem3D {
  /// Drive one physics tick.
  ///
  /// @param {World} world. ECS world.
  /// @param {Object} physicsWorld. A `@hatch:physics.World3D` (or
  ///   anything with `.spawnDynamic` / `.spawnStatic` /
  ///   `.spawnKinematic` / `.step(dt)` / `.position(bodyId)`).
  /// @param {Num} dt. Frame delta in seconds.
  static step(world, physicsWorld, dt) {
    // 1. Spawn unregistered bodies.
    for (e in world.query(RigidBody)) {
      var rb = world.get(e, RigidBody)
      if (rb.bodyId != null) continue
      var col = world.get(e, Collider)
      var t   = world.get(e, Transform)
      if (col == null || t == null) continue
      var desc = {
        "shape":    col.shape,
        "position": [t.position.x, t.position.y, t.position.z],
        "mass":     rb.mass,
      }
      if (rb.linearVelocity != null) {
        var v = rb.linearVelocity
        desc["linearVelocity"] = [v.x, v.y, v.z]
      }
      var bodyId = spawnBody3d_(physicsWorld, rb.kind, desc)
      rb.bodyId_ = bodyId
    }

    // 2. Advance simulation.
    physicsWorld.step(dt)

    // 3. Read positions back into Transforms.
    for (e in world.query(RigidBody)) {
      var rb = world.get(e, RigidBody)
      if (rb.bodyId == null) continue
      if (rb.kind == "static") continue
      var t = world.get(e, Transform)
      if (t == null) continue
      var pos = physicsWorld.position(rb.bodyId)
      t.position = Vec3.new(pos[0], pos[1], pos[2])
    }
  }

  static spawnBody3d_(physicsWorld, kind, desc) {
    if (kind == "static")    return physicsWorld.spawnStatic(desc)
    if (kind == "kinematic") return physicsWorld.spawnKinematic(desc)
    return physicsWorld.spawnDynamic(desc)
  }
}

/// 2D twin of [PhysicsSystem3D]. Pulls only the X / Y axes from
/// `Transform.position` and writes the same pair back. Z stays
/// untouched, so 2D entities can still parent under 3D scene
/// hierarchies (Z is treated as a depth hint).
class PhysicsSystem2D {
  /// Drive one 2D physics tick.
  ///
  /// @param {World} world. ECS world.
  /// @param {Object} physicsWorld. A `@hatch:physics.World2D`.
  /// @param {Num} dt. Frame delta in seconds.
  static step(world, physicsWorld, dt) {
    for (e in world.query(RigidBody)) {
      var rb = world.get(e, RigidBody)
      if (rb.bodyId != null) continue
      var col = world.get(e, Collider)
      var t   = world.get(e, Transform)
      if (col == null || t == null) continue
      var desc = {
        "shape":    col.shape,
        "position": [t.position.x, t.position.y],
        "mass":     rb.mass,
      }
      if (rb.linearVelocity != null) {
        var v = rb.linearVelocity
        desc["linearVelocity"] = [v.x, v.y]
      }
      var bodyId = spawnBody2d_(physicsWorld, rb.kind, desc)
      rb.bodyId_ = bodyId
    }

    physicsWorld.step(dt)

    for (e in world.query(RigidBody)) {
      var rb = world.get(e, RigidBody)
      if (rb.bodyId == null) continue
      if (rb.kind == "static") continue
      var t = world.get(e, Transform)
      if (t == null) continue
      var pos = physicsWorld.position(rb.bodyId)
      t.position = Vec3.new(pos[0], pos[1], t.position.z)
    }
  }

  static spawnBody2d_(physicsWorld, kind, desc) {
    if (kind == "static")    return physicsWorld.spawnStatic(desc)
    if (kind == "kinematic") return physicsWorld.spawnKinematic(desc)
    return physicsWorld.spawnDynamic(desc)
  }
}

/// Audio-source component. Stores the `@hatch:audio.Sound`
/// handle + per-source playback parameters. `spatial = true`
/// flags the source as 3D-positional — when the audio plugin
/// grows pan + distance attenuation (Phase 9 in the parity
/// plan), an audio system will read the entity's
/// `GlobalTransform` to derive the listener-relative position.
///
/// Until then the source acts as a data carrier; gameplay code
/// triggers playback via `Audio.play(source.sound, {"volume":
/// source.volume, "loop": source.loop})`.
class AudioSource {
  /// Default: full-volume, non-looping, 2D one-shot. Set
  /// `sound` after construction via the setter.
  construct new() {
    _sound = null
    _volume = 1.0
    _loop = false
    _spatial = false
  }

  /// Explicit one-shot.
  ///
  /// @param {Sound} sound. `@hatch:audio.Sound` handle.
  construct new(sound) {
    _sound = sound
    _volume = 1.0
    _loop = false
    _spatial = false
  }

  sound      { _sound }
  sound=(s)  { _sound = s }

  /// Linear gain, 0..1. Default 1.0.
  /// @returns {Num}
  volume     { _volume }
  volume=(v) { _volume = v }

  /// Loop the source. Default `false`.
  /// @returns {Bool}
  loop       { _loop }
  loop=(v)   { _loop = v }

  /// When true, the source's world position (`GlobalTransform`
  /// translation) feeds the spatial audio mixer. The current
  /// audio plugin treats this as a hint only; full positional
  /// audio lands when the mixer grows pan + distance attenuation.
  /// @returns {Bool}
  spatial     { _spatial }
  spatial=(v) { _spatial = v }

  toString { "AudioSource(sound=%(_sound), vol=%(_volume), loop=%(_loop))" }
}

/// Audio-listener marker. Place one on the camera entity (or
/// wherever the player's ears are). The eventual spatial-audio
/// integration reads the entity's `GlobalTransform` translation
/// + forward axis to position the 3D mixer's listener.
///
/// Multiple listeners are valid; the first one queried wins.
class AudioListener {
  /// Default: listener with the unit-gain master attenuation.
  construct new() {
    _gain = 1.0
  }

  /// Master gain applied to every spatial source heard through
  /// this listener.
  /// @returns {Num}
  gain     { _gain }
  gain=(v) { _gain = v }

  toString { "AudioListener(gain=%(_gain))" }
}

/// Directional light component. The light has no spatial position;
/// it shines in a fixed direction across the whole world. Direction
/// comes from the entity's local `Transform` — the forward axis
/// (`Quat * -Vec3.unitZ`) is treated as the direction the light
/// travels in (sun-to-ground). Place the entity anywhere; only its
/// rotation matters.
///
/// ## Example
///
/// ```wren
/// var sun = world.spawn()
/// var t = Transform.new()
/// t.rotation = Quat.fromAxisAngle(Vec3.unitX, -0.6)   // tilt downward
/// world.attach(sun, t)
/// world.attach(sun, DirectionalLight.new(Vec3.new(1, 0.95, 0.85), 3.0))
/// ```
class DirectionalLight {
  /// Default light: white, intensity 1.0.
  construct new() {
    _color = Vec3.new(1, 1, 1)
    _intensity = 1.0
  }

  /// Explicit color + intensity.
  ///
  /// @param {Vec3} color. Linear-space RGB (0..1 per channel). For
  ///   sRGB inputs (`#FFEACC` etc.) convert before constructing.
  /// @param {Num} intensity. Multiplier applied to `color` in the
  ///   shader. Physically a luminous flux scaling.
  construct new(color, intensity) {
    _color = color
    _intensity = intensity
  }

  /// Linear-space RGB. Same axis order as `Vec3`.
  /// @returns {Vec3}
  color       { _color }
  color=(c)   { _color = c }

  /// Scalar multiplier applied to `color`. Conventionally 1.0 for
  /// the sun on a sunny day, 0.1–0.5 for fill lights, 5–20 for
  /// strong area lights.
  /// @returns {Num}
  intensity     { _intensity }
  intensity=(v) { _intensity = v }

  toString { "DirectionalLight(color=%(_color), i=%(_intensity))" }
}

/// Point light component. Emits in every direction from the
/// entity's world-space position (`GlobalTransform.matrix` extracts
/// the translation column). Falloff is inverse-square; `range`
/// caps the falloff so distant lights drop to zero instead of
/// trailing off forever.
///
/// ## Example
///
/// ```wren
/// var lamp = world.spawn()
/// world.attach(lamp, Transform.new(Vec3.new(0, 3, 0), null, null))
/// world.attach(lamp, PointLight.new(Vec3.new(1.0, 0.7, 0.4), 8.0, 12.0))
/// ```
class PointLight {
  /// Default: white, intensity 1, unlimited range.
  construct new() {
    _color = Vec3.new(1, 1, 1)
    _intensity = 1.0
    _range = 0.0
  }

  /// Explicit color + intensity + range.
  ///
  /// @param {Vec3} color. Linear-space RGB.
  /// @param {Num} intensity. Multiplier applied to `color`.
  /// @param {Num} range. Maximum reach in world units. `0` means
  ///   unbounded (pure inverse-square only). Non-zero values fade
  ///   to zero over the last 10% of `range`.
  construct new(color, intensity, range) {
    _color = color
    _intensity = intensity
    _range = range
  }

  color         { _color }
  color=(c)     { _color = c }

  intensity     { _intensity }
  intensity=(v) { _intensity = v }

  /// Falloff cap in world units. `0` for unbounded; positive for
  /// a soft cutoff that helps the renderer skip distant lights.
  /// @returns {Num}
  range         { _range }
  range=(v)     { _range = v }

  toString { "PointLight(color=%(_color), i=%(_intensity), range=%(_range))" }
}

/// Spot light component. Emits from a position in a cone aligned
/// with the entity's forward axis (`Quat * -Vec3.unitZ`). Falloff
/// is inverse-square (capped by `range`) plus a smooth cone
/// transition between `innerConeAngle` and `outerConeAngle`.
///
/// ## Example
///
/// ```wren
/// var flashlight = world.spawn()
/// world.attach(flashlight, Transform.new(Vec3.new(0, 0, 5), aim, null))
/// world.attach(flashlight, SpotLight.new(Vec3.new(1, 1, 1), 15.0, 20.0, 0.4, 0.7))
/// ```
class SpotLight {
  /// Default: white, intensity 1, 10° inner / 25° outer, unlimited range.
  construct new() {
    _color = Vec3.new(1, 1, 1)
    _intensity = 1.0
    _range = 0.0
    _innerConeAngle = 0.17     // ~10°
    _outerConeAngle = 0.44     // ~25°
  }

  /// Explicit cone.
  ///
  /// @param {Vec3} color. Linear-space RGB.
  /// @param {Num} intensity. Multiplier applied to `color`.
  /// @param {Num} range. `0` for unbounded.
  /// @param {Num} innerConeAngle. Half-angle in radians. Full
  ///   brightness inside this cone.
  /// @param {Num} outerConeAngle. Half-angle in radians. Falloff
  ///   smoothsteps between inner and outer; zero beyond outer.
  construct new(color, intensity, range, innerConeAngle, outerConeAngle) {
    _color = color
    _intensity = intensity
    _range = range
    _innerConeAngle = innerConeAngle
    _outerConeAngle = outerConeAngle
  }

  color         { _color }
  color=(c)     { _color = c }

  intensity     { _intensity }
  intensity=(v) { _intensity = v }

  range         { _range }
  range=(v)     { _range = v }

  /// Half-angle of the full-brightness inner cone, in radians.
  /// @returns {Num}
  innerConeAngle     { _innerConeAngle }
  innerConeAngle=(v) { _innerConeAngle = v }

  /// Half-angle of the falloff outer cone, in radians.
  /// @returns {Num}
  outerConeAngle     { _outerConeAngle }
  outerConeAngle=(v) { _outerConeAngle = v }

  toString {
    "SpotLight(color=%(_color), i=%(_intensity), cone=%(_innerConeAngle)..%(_outerConeAngle))"
  }
}

/// Scene-level ambient light. Attach to any entity (typically a
/// "scene root" you spawn at startup) and the renderer adds it as
/// a constant baseline term once per frame. Multiple
/// `AmbientLight`s in a world sum.
class AmbientLight {
  /// Default: dim neutral grey, intensity 0.1.
  construct new() {
    _color = Vec3.new(1, 1, 1)
    _intensity = 0.1
  }

  /// Explicit ambient.
  ///
  /// @param {Vec3} color. Linear-space RGB.
  /// @param {Num} intensity. Multiplier applied to `color`.
  construct new(color, intensity) {
    _color = color
    _intensity = intensity
  }

  color         { _color }
  color=(c)     { _color = c }

  intensity     { _intensity }
  intensity=(v) { _intensity = v }

  toString { "AmbientLight(color=%(_color), i=%(_intensity))" }
}

/// Frame-once walk over the ECS hierarchy that turns local
/// `Transform`s into propagated `GlobalTransform`s. Roots (any
/// entity with a `Transform` but no `Parent`) are walked first;
/// each child's `GlobalTransform.matrix` = `parent.world *
/// child.local`.
///
/// Idempotent: re-running within the same frame is safe and
/// reproduces the same output. Call once after game logic has
/// updated local transforms and before the renderer reads world
/// matrices.
///
/// ## Example
///
/// ```wren
/// // In Game.update, after game logic, before draw:
/// TransformPropagation.run(world)
/// ```
class TransformPropagation {
  /// Walk every entity with a `Transform`, write its propagated
  /// world matrix to a `GlobalTransform` companion.
  static run(world) {
    // Collect roots: any entity with Transform that doesn't carry
    // a Parent. Build the list eagerly so attaching new
    // GlobalTransform components inside the walk can't perturb
    // the iterator.
    var withTransform = world.query(Transform)
    var roots = []
    var i = 0
    while (i < withTransform.count) {
      var e = withTransform[i]
      if (world.get(e, Parent) == null) roots.add(e)
      i = i + 1
    }

    var r = 0
    while (r < roots.count) {
      walk_(world, roots[r], null)
      r = r + 1
    }
  }

  static walk_(world, entity, parentMatrix) {
    var t = world.get(entity, Transform)
    // An entity in the hierarchy without its own Transform can't
    // contribute a local frame, but its children may still be
    // anchored to the parent's world matrix — propagate the
    // parent's frame unchanged so descendants resolve correctly.
    var local = t == null ? Mat4.identity : t.localMatrix
    var world_ = parentMatrix == null ? local : parentMatrix * local

    var gt = world.get(entity, GlobalTransform)
    if (gt == null) {
      world.attach(entity, GlobalTransform.new_(world_))
    } else {
      gt.matrix = world_
    }

    // Recurse into children. `childrenOf` returns the live list
    // by reference; index-based loop avoids the for-in closure
    // capture issue and tolerates the list being appended to.
    var kids = world.childrenOf(entity)
    var i = 0
    while (i < kids.count) {
      walk_(world, kids[i], world_)
      i = i + 1
    }
  }
}

/// ECS-to-`Renderer3D` bridge. Walks an `@hatch:ecs.World` once
/// per frame, extracting:
///
/// - **Lights** — `(Transform | GlobalTransform, AmbientLight |
///   DirectionalLight | PointLight | SpotLight)` entities. The
///   spatial light kinds (Point / Spot) pull world-space position
///   from `GlobalTransform`; the directional kinds (Directional /
///   Spot) derive their forward axis from the entity's
///   `Transform.rotation` applied to `(0, 0, -1)`. `AmbientLight`s
///   sum into a single ambient term.
/// - **Drawables** — `(GlobalTransform, MeshRenderer)` entities.
///   Each visible match becomes one `renderer.draw(mesh, material,
///   worldMatrix)` call.
///
/// Caller responsibility:
/// 1. Run `TransformPropagation.run(world)` first so every entity
///    has an up-to-date `GlobalTransform`.
/// 2. Call `SceneRenderer3D.run(world, camera, renderer, pass)`
///    inside the render pass.
///
/// ## Example
///
/// ```wren
/// draw(g) {
///   TransformPropagation.run(_world)
///   SceneRenderer3D.run(_world, _camera, _renderer, g.pass)
/// }
/// ```
///
/// `Game.run` clears the pass when the closure returns; the
/// bridge itself doesn't `endFrame` on the renderer (the next
/// frame's `beginFrame` resets state).
class SceneRenderer3D {
  /// Drive `renderer` from `world`'s entities for one frame.
  ///
  /// @param {World} world. ECS world with propagated
  ///   `GlobalTransform`s.
  /// @param {Camera3D} camera. View + projection source.
  /// @param {Renderer3D} renderer. Target renderer.
  /// @param {RenderPass} pass. Active render pass.
  static run(world, camera, renderer, pass) {
    renderer.beginFrame(pass, camera)

    // -- Lights --------------------------------------------------

    var ambColor = Vec3.zero
    var ambSum = 0
    for (e in world.query(AmbientLight)) {
      var a = world.get(e, AmbientLight)
      ambColor = Vec3.new(
        ambColor.x + a.color.x * a.intensity,
        ambColor.y + a.color.y * a.intensity,
        ambColor.z + a.color.z * a.intensity)
      ambSum = ambSum + 1
    }
    // Ambient API expects (color, intensity) — fold the
    // intensity multiplier into the colour and pass 1.0 so
    // multiple AmbientLights accumulate cleanly.
    renderer.setAmbient(ambColor, ambSum > 0 ? 1.0 : 0.0)

    for (e in world.query(DirectionalLight)) {
      var light = world.get(e, DirectionalLight)
      var t = world.get(e, Transform)
      var dir = (t == null) ? LIGHT_FORWARD_ : t.rotation.rotateVec3(LIGHT_FORWARD_)
      renderer.addDirectional(dir, light.color, light.intensity)
    }

    for (e in world.query(PointLight)) {
      var light = world.get(e, PointLight)
      var gt = world.get(e, GlobalTransform)
      var pos = (gt == null) ? Vec3.zero : gt.matrix.transformPoint(Vec3.zero)
      renderer.addPoint(pos, light.color, light.intensity, light.range)
    }

    for (e in world.query(SpotLight)) {
      var light = world.get(e, SpotLight)
      var gt = world.get(e, GlobalTransform)
      var t  = world.get(e, Transform)
      var pos = (gt == null) ? Vec3.zero : gt.matrix.transformPoint(Vec3.zero)
      var dir = (t == null) ? LIGHT_FORWARD_ : t.rotation.rotateVec3(LIGHT_FORWARD_)
      renderer.addSpot(pos, dir, light.color, light.intensity, light.range, light.innerConeAngle, light.outerConeAngle)
    }

    // -- Drawables -----------------------------------------------

    for (e in world.query(MeshRenderer)) {
      var mr = world.get(e, MeshRenderer)
      if (!mr.visible) continue
      if (mr.mesh == null) continue
      var gt = world.get(e, GlobalTransform)
      var model = (gt == null) ? Mat4.identity : gt.matrix
      renderer.draw(mr.mesh, mr.material, model)
    }
  }
}
