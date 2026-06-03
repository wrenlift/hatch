// `@hatch:game` ECS-shaped components and systems for camera,
// sprite, and animation — the Phase 2 surface from
// `hatch/docs/game-engine-parity-plan.md`. Layered over `@hatch:ecs`
// queries with `@hatch:gpu` and the rest of `@hatch:game` as the
// data backends.
//
// The components are deliberately thin — they hold references to
// the heavier primitives in `@hatch:gpu` (`Camera3D`, `Camera2D`,
// `Sprite`) and the in-package `AnimationPlayer` / `AudioSource`
// without duplicating their state. Each system is a static
// `run(world, …)` entry point called once per frame.
//
// ## Quick start
//
// ```wren
// import "@hatch:ecs"  for World
// import "@hatch:game" for
//   Transform, ActiveCamera, SpriteRenderer, Animator,
//   CameraSystem, SpriteRenderSystem, AnimationSystem, AudioSystem
// import "@hatch:gpu"  for Camera3D, Sprite
//
// var world = World.new()
// var cam   = world.spawn()
// world.attach(cam, Camera3D.perspective(60, aspect, 0.1, 1000))
// world.attach(cam, ActiveCamera.new())
//
// var sprite = world.spawn()
// world.attach(sprite, Transform.new())
// world.attach(sprite, SpriteRenderer.new(playerSprite))
//
// // Per frame:
// var active = CameraSystem.active3D(world)   // queryable
// AnimationSystem.run(world, dt)
// SpriteRenderSystem.run(world, renderer)
// AudioSystem.run(world)
// ```
//
// Camera primitives keep their `@hatch:gpu` names (we don't shadow
// them); the marker tag `ActiveCamera` indicates which entity's
// camera the renderer consumes.

import "@hatch:gpu"  for Camera3D, Camera2D, Sprite
import "@hatch:math" for Vec3, Vec4
import "./scene"     for Transform, GlobalTransform, AudioSource, AudioListener

/// Marker component flagging the entity's `Camera3D` (or
/// `Camera2D`) as the renderer's primary view. Stateless — pure
/// tag for `world.query([ActiveCamera, Camera3D])`-style lookups.
/// Exactly one ActiveCamera per camera kind is the expected
/// invariant; if multiple entities carry the tag, the first one
/// returned by the world query wins.
///
/// ## Example
///
/// ```wren
/// var e = world.spawn()
/// world.attach(e, Camera3D.perspective(60, aspect, 0.1, 1000))
/// world.attach(e, ActiveCamera.new())
/// ```
class ActiveCamera {
  construct new() {}
}

/// Per-entity sprite draw. Pairs with a `Transform` (or
/// `GlobalTransform`); `SpriteRenderSystem.run(world, renderer)`
/// batches every visible `SpriteRenderer` through `Renderer2D`.
///
/// `tint` modulates the sampled texture colour. Defaults to white
/// (no tint). Set `visible = false` to hide without removing the
/// component.
class SpriteRenderer {
  /// @param {Sprite} sprite. The drawable from `@hatch:gpu`.
  ///   Duck-typed — anything with `x=`, `y=`, `setTint`, `draw`
  ///   satisfies the system.
  construct new(sprite) {
    if (sprite == null) Fiber.abort("SpriteRenderer.new: sprite must be non-null")
    _sprite  = sprite
    _visible = true
    _tint    = Vec4.new(1, 1, 1, 1)
  }

  sprite       { _sprite }
  sprite=(v)   { _sprite = v }
  visible      { _visible }
  visible=(v)  { _visible = v }
  tint         { _tint }
  tint=(v) {
    if (!(v is Vec4)) Fiber.abort("SpriteRenderer.tint=: must be a Vec4")
    _tint = v
  }
}

/// Drives an `AnimationPlayer` on a per-frame `update(dt * speed)`
/// tick. The component IS the player wrapper; game code reads back
/// through `animator.player.current` after
/// `AnimationSystem.run(world, dt)` to fold the sampled tracks into
/// transforms / shader uniforms / whatever.
///
/// `speed` is a multiplier — `1.0` is real time, `0.5` half speed,
/// negative values play backwards. `paused = true` suspends the
/// tick without resetting state.
class Animator {
  /// @param {AnimationPlayer} player.
  construct new(player) {
    if (player == null) Fiber.abort("Animator.new: player must be non-null")
    _player = player
    _speed  = 1
    _paused = false
  }

  player       { _player }
  speed        { _speed }
  speed=(v) {
    if (!(v is Num)) Fiber.abort("Animator.speed=: must be a Num")
    _speed = v
  }
  paused       { _paused }
  paused=(v)   { _paused = v }
}

/// Query helpers for resolving the renderer's active camera from
/// the ECS world. `active3D` / `active2D` return the first
/// `Camera3D` / `Camera2D` whose entity also carries `ActiveCamera`,
/// or `null` if no entity is so marked. Callers fall back to a
/// stand-in (origin-looking identity) when the query returns null.
class CameraSystem {
  /// Returns the active `Camera3D`, or `null`.
  /// @param {World} world
  static active3D(world) {
    for (e in world.query([ActiveCamera, Camera3D])) {
      return world.get(e, Camera3D)
    }
    return null
  }

  /// Returns the active `Camera2D`, or `null`.
  /// @param {World} world
  static active2D(world) {
    for (e in world.query([ActiveCamera, Camera2D])) {
      return world.get(e, Camera2D)
    }
    return null
  }
}

/// Per-frame system that batches every visible `SpriteRenderer`
/// through `Renderer2D`. Each entity's `GlobalTransform` (preferred)
/// or `Transform` (fallback) gives world position.
///
/// The renderer is the caller's `Renderer2D` instance — typically
/// `g.renderer2D` inside a `Game.draw` block. Caller is responsible
/// for `renderer.beginPass(pass)` / `endPass` framing.
class SpriteRenderSystem {
  /// @param {World} world
  /// @param {Renderer2D} renderer
  static run(world, renderer) {
    for (e in world.query(SpriteRenderer)) {
      var sr = world.get(e, SpriteRenderer)
      if (!sr.visible) continue
      var gt = world.get(e, GlobalTransform)
      var t  = gt != null ? gt : world.get(e, Transform)
      var pos = t == null ? Vec3.zero : SpriteRenderSystem.posOf_(t)
      // Write transform position + tint into the sprite's pose
      // before draw — sprites are per-entity, so we're not
      // mutating shared state.
      sr.sprite.x = pos.x
      sr.sprite.y = pos.y
      sr.sprite.setTint(sr.tint.x, sr.tint.y, sr.tint.z, sr.tint.w)
      sr.sprite.draw(renderer)
    }
  }

  static posOf_(transform) {
    if (transform is GlobalTransform) {
      return transform.matrix.transformPoint(Vec3.zero)
    }
    return transform.position
  }
}

/// Per-frame tick of every `Animator`. Advances each player's
/// timeline by `dt * speed`, skipping paused ones. Game code reads
/// the sampled tracks via `animator.player.current` after the run.
class AnimationSystem {
  /// @param {World} world
  /// @param {Num} dt. Seconds since last tick.
  static run(world, dt) {
    for (e in world.query(Animator)) {
      var a = world.get(e, Animator)
      if (a.paused) continue
      a.player.update(dt * a.speed)
    }
  }
}

/// Per-frame tick of every `AudioSource`. Walks spatial sources and
/// updates their voice positions from `GlobalTransform`; the
/// listener pose is read from the first entity carrying both
/// `AudioListener` and `GlobalTransform`. Non-spatial sources are
/// left to the audio engine's own playback state — this system
/// only touches the spatial path.
///
/// Per-voice spatial pan + distance attenuation lands when
/// `@hatch:audio` ships the positional mixer surface (Phase 9).
/// Until then this system exposes `lastListenerPos` and
/// `lastSpatialCount` hooks for debug observability.
class AudioSystem {
  /// @param {World} world
  static run(world) {
    // Resolve listener pose first — most sources need it for
    // pan / attenuation. Falls back to origin when no listener
    // is configured (mono mix).
    var listenerPos = Vec3.zero
    for (e in world.query(AudioListener)) {
      var gt = world.get(e, GlobalTransform)
      if (gt != null) listenerPos = gt.matrix.transformPoint(Vec3.zero)
      break
    }

    _lastListenerPos = listenerPos
    _lastSpatialCount = 0
    for (e in world.query(AudioSource)) {
      var src = world.get(e, AudioSource)
      if (!src.spatial) continue
      _lastSpatialCount = _lastSpatialCount + 1
    }
  }

  /// Most-recent listener position from the last `run`.
  static lastListenerPos { _lastListenerPos }

  /// Most-recent spatial-source count from the last `run`.
  static lastSpatialCount { _lastSpatialCount }
}
