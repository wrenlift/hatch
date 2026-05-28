// `@hatch:game` scene module: Transform + GlobalTransform +
// TransformPropagation. The minimum hierarchy layer Renderer3D
// and physics consume. Transform itself is ECS-agnostic — it's
// just a class — and the propagation system bridges it with
// `@hatch:ecs`'s built-in `Parent` / `Children` components.
//
// Layout: T * R * S, right-handed. World = parent.world * local.

import "@hatch:math" for Vec3, Mat4, Quat
import "@hatch:ecs"  for Parent, Children

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
