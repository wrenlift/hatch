// ECS Cubes — Phase 2 exit-gate demo for the game-parity plan.
//
//   wlift main.wren
//
// 100 cubes raining onto a ground plane. Every entity is a pure
// composition of ECS components — game code never touches a Mat4
// directly. Three systems close the loop:
//
//   PhysicsSystem3D.step(world, physics, dt)   // rapier advance + writeback
//   TransformPropagation.run(world)            // Transform → GlobalTransform
//   SceneRenderer3D.run(world, camera, ...)    // (GT, MeshRenderer) → draws
//
// The renderer queries the same ECS world the physics step
// mutates; lights live as `(Transform, DirectionalLight)` /
// `AmbientLight` entities and the bridge collects them per frame.

import "@hatch:game"    for Game, Transform, MeshRenderer, RigidBody, Collider,
                            PhysicsSystem3D, TransformPropagation, SceneRenderer3D,
                            DirectionalLight, AmbientLight
import "@hatch:gpu"     for Renderer3D, Camera3D, Mesh, Material
import "@hatch:ecs"     for World
import "@hatch:math"    for Vec3, Vec4, Quat
import "@hatch:physics" for World3D, Collider3D
import "@hatch:random"  for Rand

class EcsCubes is Game {
  construct new() {}

  config { {
    "title":      "ECS Cubes",
    "width":      1280,
    "height":     720,
    "clearColor": [0.05, 0.07, 0.12, 1.0],
    "depth":      true,
  } }

  setup(g) {
    _world    = World.new()
    _physics  = World3D.new()
    _renderer = Renderer3D.new(g.device, g.surfaceFormat, g.depthFormat)

    var aspect = g.width / g.height
    _camera = Camera3D.perspective(55, aspect, 0.1, 200)
    _camera.lookAt(Vec3.new(0, 14, 22), Vec3.new(0, 2, 0), Vec3.new(0, 1, 0))

    // Shared cube mesh — every entity reuses the same vertex /
    // index buffers, so 100 cubes = 100 draws but 1 GPU upload.
    var cubeMesh   = Mesh.cube(g.device, 0.5)
    var groundMesh = Mesh.plane(g.device, 40)

    // Lights: one ambient + one sun. The renderer collects them
    // off the world via SceneRenderer3D's per-frame walk.
    var ambient = _world.spawn()
    _world.attach(ambient, AmbientLight.new(Vec3.new(0.4, 0.45, 0.55), 0.4))

    var sun = _world.spawn()
    var sunT = Transform.new()
    sunT.rotation = Quat.fromAxisAngle(Vec3.unitX, -0.7)   // tilt downward
    _world.attach(sun, sunT)
    _world.attach(sun, DirectionalLight.new(Vec3.new(1.0, 0.95, 0.85), 3.5))

    // Static ground plane — Transform + MeshRenderer for the
    // visual, RigidBody + Collider for collision.
    var ground = _world.spawn()
    _world.attach(ground, Transform.translation(0, -0.05, 0))
    _world.attach(ground, MeshRenderer.new(groundMesh, groundMaterial_()))
    _world.attach(ground, RigidBody.new("static"))
    _world.attach(ground, Collider.new(Collider3D.box(40, 0.05, 40, {
      "restitution": 0.4, "friction": 0.9
    })))

    // 100 dynamic cubes. Random initial position + small spin via
    // Transform.rotation (physics doesn't propagate rotation yet,
    // so this stays static across the sim — fine for the demo).
    var palette = [
      Vec4.new(0.92, 0.45, 0.50, 1.0),
      Vec4.new(0.45, 0.85, 0.62, 1.0),
      Vec4.new(0.45, 0.62, 0.95, 1.0),
      Vec4.new(0.95, 0.85, 0.45, 1.0),
      Vec4.new(0.80, 0.55, 0.95, 1.0),
    ]
    var i = 0
    while (i < 100) {
      var e = _world.spawn()
      var x = Rand.float(-8, 8)
      var y = Rand.float(8, 24)
      var z = Rand.float(-8, 8)
      _world.attach(e, Transform.translation(x, y, z))

      var mat = Material.new(palette[i % palette.count])
      mat.roughnessFactor = 0.55
      mat.metallicFactor  = 0.1
      _world.attach(e, MeshRenderer.new(cubeMesh, mat))

      var rb = RigidBody.new("dynamic", 1.0)
      rb.linearVelocity = Vec3.new(Rand.float(-1, 1), 0, Rand.float(-1, 1))
      _world.attach(e, rb)
      _world.attach(e, Collider.new(Collider3D.box(0.5, 0.5, 0.5, {
        "restitution": 0.35, "friction": 0.6
      })))
      i = i + 1
    }
  }

  resize(g, w, h) {
    _camera.setPerspective(55, w / h, 0.1, 200)
  }

  update(g) {
    if (g.input.justPressed("Escape")) g.requestQuit

    // Clamp dt to dodge giant single-step blow-ups when the tab
    // un-pauses or the first frame's wall-time is wonky.
    var dt = g.dt
    if (dt > 1.0 / 30) dt = 1.0 / 30

    PhysicsSystem3D.step(_world, _physics, dt)
    TransformPropagation.run(_world)
  }

  draw(g) {
    SceneRenderer3D.run(_world, _camera, _renderer, g.pass)
  }

  // Ground material — desaturated dielectric, slightly rough.
  groundMaterial_() {
    var m = Material.new(Vec4.new(0.30, 0.32, 0.35, 1.0))
    m.roughnessFactor = 0.85
    m.metallicFactor  = 0.0
    return m
  }
}

Game.run(EcsCubes)
