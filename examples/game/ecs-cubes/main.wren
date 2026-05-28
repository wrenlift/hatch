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

    _eye    = Vec3.new(0, 14, 22)
    _target = Vec3.new(0, 2, 0)
    _fovYDeg = 55
    var aspect = g.width / g.height
    _camera = Camera3D.perspective(_fovYDeg, aspect, 0.1, 200)
    _camera.lookAt(_eye, _target, Vec3.new(0, 1, 0))

    // Shared cube mesh — every entity reuses the same vertex /
    // index buffers, so N cubes = N draws but 1 GPU upload.
    _cubeMesh   = Mesh.cube(g.device, 0.5)
    var groundMesh = Mesh.plane(g.device, 40)
    // Pre-built materials shared across every cube. Renderer3D
    // caches a GPU bind group per Material identity (UBO + 5
    // TextureViews + 1 sampler binding) — allocating a fresh
    // Material per cube leaves a pinned cache entry behind every
    // time, so a thousand spawns leaks a thousand bind groups.
    // Sharing five palette materials caps the cache at five.
    _materials = [
      buildCubeMaterial_(Vec4.new(0.92, 0.45, 0.50, 1.0)),
      buildCubeMaterial_(Vec4.new(0.45, 0.85, 0.62, 1.0)),
      buildCubeMaterial_(Vec4.new(0.45, 0.62, 0.95, 1.0)),
      buildCubeMaterial_(Vec4.new(0.95, 0.85, 0.45, 1.0)),
      buildCubeMaterial_(Vec4.new(0.80, 0.55, 0.95, 1.0)),
    ]
    // FIFO of dynamic cube entity ids — bounded so the simulation
    // stays smooth as the user spams clicks.
    _cubes      = []
    _cubeLimit  = 20
    _frameCounter = 0

    // Lights: brighter ambient + key sun + fill light. The
    // renderer collects them off the world via SceneRenderer3D's
    // per-frame walk. Without the fill light, sides facing away
    // from the sun went pitch dark — direct-light NoL = 0 plus
    // a dim ambient floor doesn't survive ACES tonemapping.
    var ambient = _world.spawn()
    _world.attach(ambient, AmbientLight.new(Vec3.new(0.55, 0.60, 0.70), 1.2))

    // Key light — warm sun coming down + forward.
    var sun = _world.spawn()
    var sunT = Transform.new()
    sunT.rotation = Quat.fromAxisAngle(Vec3.unitX, -0.7)
    _world.attach(sun, sunT)
    _world.attach(sun, DirectionalLight.new(Vec3.new(1.0, 0.95, 0.85), 4.0))

    // Fill light — cooler tone from camera-right, almost flat,
    // so the back/side faces of dynamic cubes register against
    // the dark backdrop.
    var fill = _world.spawn()
    var fillT = Transform.new()
    fillT.rotation = Quat.fromAxisAngle(Vec3.unitY, 1.2) * Quat.fromAxisAngle(Vec3.unitX, -0.3)
    _world.attach(fill, fillT)
    _world.attach(fill, DirectionalLight.new(Vec3.new(0.55, 0.70, 0.95), 1.5))

    // Static ground plane — Transform + MeshRenderer for the
    // visual, RigidBody + Collider for collision.
    var ground = _world.spawn()
    _world.attach(ground, Transform.translation(0, -0.05, 0))
    _world.attach(ground, MeshRenderer.new(groundMesh, groundMaterial_()))
    _world.attach(ground, RigidBody.new("static"))
    _world.attach(ground, Collider.new(Collider3D.box(40, 0.05, 40, {
      "restitution": 0.4, "friction": 0.9
    })))

    // Triage scene — three cubes. Used to isolate whether the
    // host's per-frame allocation pattern explodes regardless of
    // entity count; if memory still climbs with three, the leak
    // is in the per-frame plumbing (queue write, command record,
    // GC marking) rather than scaling with cube count.
    var i = 0
    while (i < 3) {
      spawnCubeAt_(Rand.float(-4, 4), Rand.float(6, 12), Rand.float(-4, 4))
      i = i + 1
    }
  }

  resize(g, w, h) {
    _camera.setPerspective(_fovYDeg, w / h, 0.1, 200)
  }

  update(g) {
    if (g.input.justPressed("Escape")) g.requestQuit
    if (g.input.mouseJustPressed("left")) dropCubeAtCursor_(g)

    // Clamp dt to dodge giant single-step blow-ups when the tab
    // un-pauses or the first frame's wall-time is wonky.
    var dt = g.dt
    if (dt > 1.0 / 30) dt = 1.0 / 30

    PhysicsSystem3D.step(_world, _physics, dt)
    TransformPropagation.run(_world)

    // Triage: nudge the GC every 30 frames (~2x per sec) so
    // short-lived per-frame allocations don't get promoted to
    // old gen. If the leak is host-side (wgpu / Metal driver),
    // this is a no-op; if it's Wren-side, this should keep RSS
    // flat under steady idle.
    _frameCounter = _frameCounter + 1
    if (_frameCounter >= 30) {
      _frameCounter = 0
      System.gc()
    }
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

  // Build one of the cube's shared palette materials. Stored
  // once at setup; every cube references whichever one the
  // palette picks for it.
  buildCubeMaterial_(albedo) {
    var m = Material.new(albedo)
    m.roughnessFactor = 0.55
    m.metallicFactor  = 0.1
    return m
  }

  // Spawn one dynamic cube entity at (x, y, z) with a randomly
  // picked palette material. Appends to `_cubes` (a FIFO) and
  // evicts the oldest cube when `_cubeLimit` is exceeded so the
  // sim stays smooth under sustained clicking.
  spawnCubeAt_(x, y, z) {
    var e = _world.spawn()
    _world.attach(e, Transform.translation(x, y, z))
    _world.attach(e, MeshRenderer.new(_cubeMesh, _materials[Rand.int(_materials.count)]))

    var rb = RigidBody.new("dynamic", 1.0)
    rb.linearVelocity = Vec3.new(Rand.float(-1, 1), 0, Rand.float(-1, 1))
    _world.attach(e, rb)
    _world.attach(e, Collider.new(Collider3D.box(0.5, 0.5, 0.5, {
      "restitution": 0.35, "friction": 0.6
    })))

    _cubes.add(e)
    if (_cubes.count > _cubeLimit) {
      var oldest = _cubes.removeAt(0)
      var oldRb = _world.get(oldest, RigidBody)
      if (oldRb != null && oldRb.bodyId != null) _physics.despawn(oldRb.bodyId)
      _world.despawn(oldest)
    }
    return e
  }

  // Spawn a cube at the cursor's 3D position — the screen point
  // is unprojected through the camera's focal plane (the plane
  // through `_target` perpendicular to the view direction), so
  // dragging the cursor up the screen lifts the spawn point and
  // dragging it down drops it closer to the ground. Cubes that
  // would spawn underground get clamped to half their height
  // above the floor so they don't tunnel through the collider.
  dropCubeAtCursor_(g) {
    var hit = cursorInFocalPlane_(g)
    if (hit == null) return
    var y = hit.y
    if (y < 0.5) y = 0.5
    spawnCubeAt_(hit.x, y, hit.z)
  }

  // Build a world-space ray through the cursor + intersect with
  // the plane through `_target` whose normal is the camera's
  // forward axis. Skips `Mat4.inverse` (not yet exposed by
  // @hatch:math) by working in the camera basis directly.
  cursorInFocalPlane_(g) {
    // NDC: x ∈ [-1, 1], y flipped so screen-top maps to +Y.
    var ndcX = (g.input.mouseX / g.width)  * 2 - 1
    var ndcY = 1 - (g.input.mouseY / g.height) * 2
    var aspect = g.width / g.height
    // Frustum half-extents at unit distance from the camera.
    var halfV = ((_fovYDeg * 0.017453292519943295) / 2).tan   // π/180
    var halfH = halfV * aspect

    // Camera basis. Forward = target - eye, right = forward × up,
    // up = right × forward.
    var fwd   = (_target - _eye).normalized
    var right = fwd.cross(Vec3.new(0, 1, 0)).normalized
    var up    = right.cross(fwd)

    // Ray direction in world space.
    var dir = (fwd + right * (ndcX * halfH) + up * (ndcY * halfV)).normalized

    // Intersect with the plane through `_target` whose normal is
    // `fwd`. t = ((target - eye) · fwd) / (dir · fwd).
    var denom = dir.dot(fwd)
    if (denom.abs < 0.0001) return null
    var t = (_target - _eye).dot(fwd) / denom
    if (t < 0) return null
    return _eye + dir * t
  }
}

Game.run(EcsCubes)
