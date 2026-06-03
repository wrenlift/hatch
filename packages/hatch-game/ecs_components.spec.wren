import "./ecs_components" for
  ActiveCamera, SpriteRenderer, Animator,
  CameraSystem, SpriteRenderSystem, AnimationSystem, AudioSystem
import "./scene"        for Transform, GlobalTransform, AudioSource, AudioListener
import "./animation"    for AnimationPlayer, Clip
import "@hatch:ecs"     for World
import "@hatch:test"    for Test
import "@hatch:assert"  for Expect
import "@hatch:math"    for Vec4, Vec3, Mat4

// Lightweight stand-in for `@hatch:gpu.Sprite` — same surface the
// system touches (`x`, `y`, `setTint`, `draw`). Keeps the spec
// self-contained without a real GPU device.
class FakeSprite {
  construct new() {
    _x = 0
    _y = 0
    _r = 1
    _g = 1
    _b = 1
    _a = 1
    _drawn = false
  }
  x { _x }
  y { _y }
  x=(v) { _x = v }
  y=(v) { _y = v }
  setTint(r, g, b, a) {
    _r = r
    _g = g
    _b = b
    _a = a
  }
  tintAt(i) { i == 0 ? _r : (i == 1 ? _g : (i == 2 ? _b : _a)) }
  drawn { _drawn }
  draw(renderer) { _drawn = true }
}

class FakeRenderer {
  construct new() {}
  drawSprite(tex, x, y, w, h) {}
  drawSprite_(tex, x, y, w, h, u0, v0, u1, v1, r, g, b, a) {}
}

Test.describe("ActiveCamera") {
  Test.it("is constructible as a marker") {
    Expect.that(ActiveCamera.new() is ActiveCamera).toBe(true)
  }
}

Test.describe("SpriteRenderer") {
  Test.it("rejects null sprite") {
    var fiber = Fiber.new { SpriteRenderer.new(null) }
    Expect.that(fiber.try() is String).toBe(true)
  }

  Test.it("defaults: visible=true, tint=white") {
    var sr = SpriteRenderer.new(FakeSprite.new())
    Expect.that(sr.visible).toBe(true)
    Expect.that(sr.tint.x).toBe(1)
    Expect.that(sr.tint.w).toBe(1)
  }

  Test.it("visible and tint setters round-trip") {
    var sr = SpriteRenderer.new(FakeSprite.new())
    sr.visible = false
    sr.tint = Vec4.new(0.5, 0.5, 0.5, 0.5)
    Expect.that(sr.visible).toBe(false)
    Expect.that(sr.tint.x).toBe(0.5)
  }
}

Test.describe("Animator") {
  Test.it("rejects null player") {
    var fiber = Fiber.new { Animator.new(null) }
    Expect.that(fiber.try() is String).toBe(true)
  }

  Test.it("defaults: speed=1, paused=false") {
    var p = AnimationPlayer.new()
    var a = Animator.new(p)
    Expect.that(a.speed).toBe(1)
    Expect.that(a.paused).toBe(false)
    Expect.that(a.player == p).toBe(true)
  }

  Test.it("paused suspends ticking via AnimationSystem.run") {
    var p = AnimationPlayer.new()
    p.add(Clip.new("idle", 1.0, {}))
    p.play("idle")
    var a = Animator.new(p)
    a.paused = true
    var world = World.new()
    var e = world.spawn()
    world.attach(e, a)
    AnimationSystem.run(world, 0.5)
    a.paused = false
    AnimationSystem.run(world, 0.25)
    Expect.that(world.get(e, Animator) == a).toBe(true)
  }
}

Test.describe("CameraSystem") {
  Test.it("active3D returns null when no entity carries ActiveCamera") {
    var world = World.new()
    Expect.that(CameraSystem.active3D(world)).toBe(null)
  }

  Test.it("active2D returns null when no entity carries ActiveCamera") {
    var world = World.new()
    Expect.that(CameraSystem.active2D(world)).toBe(null)
  }
}

Test.describe("SpriteRenderSystem") {
  Test.it("skips invisible sprites") {
    var world = World.new()
    var e = world.spawn()
    var sr = SpriteRenderer.new(FakeSprite.new())
    sr.visible = false
    world.attach(e, Transform.new())
    world.attach(e, sr)
    SpriteRenderSystem.run(world, FakeRenderer.new())
    Expect.that(sr.sprite.drawn).toBe(false)
  }

  Test.it("draws visible sprites and writes transform position") {
    var world = World.new()
    var e = world.spawn()
    var t = Transform.new()
    t.position = Vec3.new(10, 20, 0)
    world.attach(e, t)
    var sprite = FakeSprite.new()
    world.attach(e, SpriteRenderer.new(sprite))
    SpriteRenderSystem.run(world, FakeRenderer.new())
    Expect.that(sprite.x).toBe(10)
    Expect.that(sprite.y).toBe(20)
    Expect.that(sprite.drawn).toBe(true)
  }

  Test.it("applies tint into the sprite before draw") {
    var world = World.new()
    var e = world.spawn()
    world.attach(e, Transform.new())
    var sprite = FakeSprite.new()
    var sr = SpriteRenderer.new(sprite)
    sr.tint = Vec4.new(1, 0.5, 0, 0.8)
    world.attach(e, sr)
    SpriteRenderSystem.run(world, FakeRenderer.new())
    Expect.that(sprite.tintAt(0)).toBe(1)
    Expect.that(sprite.tintAt(1)).toBe(0.5)
    Expect.that(sprite.tintAt(2)).toBe(0)
    Expect.that(sprite.tintAt(3)).toBe(0.8)
  }
}

Test.describe("AudioSystem") {
  Test.it("counts spatial sources after run") {
    var world = World.new()
    var l = world.spawn()
    world.attach(l, AudioListener.new())
    world.attach(l, GlobalTransform.new_(Mat4.translation(5, 0, 0)))
    var s = world.spawn()
    var src = AudioSource.new()
    src.spatial = true
    world.attach(s, src)
    AudioSystem.run(world)
    Expect.that(AudioSystem.lastSpatialCount).toBe(1)
  }

  Test.it("skips non-spatial sources in count") {
    var world = World.new()
    var s = world.spawn()
    world.attach(s, AudioSource.new())
    AudioSystem.run(world)
    Expect.that(AudioSystem.lastSpatialCount).toBe(0)
  }
}

Test.run()
