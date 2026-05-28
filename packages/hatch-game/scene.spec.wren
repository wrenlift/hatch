// @hatch:game scene module — Transform + propagation specs.

import "./scene"        for
  Transform,
  GlobalTransform,
  MeshRenderer,
  RigidBody,
  Collider,
  PhysicsSystem3D,
  PhysicsSystem2D,
  AudioSource,
  AudioListener,
  DirectionalLight,
  PointLight,
  SpotLight,
  AmbientLight,
  TransformPropagation,
  SceneRenderer3D
import "@hatch:math"    for Vec3, Mat4, Quat
import "@hatch:ecs"     for World
import "@hatch:test"    for Test
import "@hatch:assert"  for Expect

Test.describe("Transform") {
  Test.it("identity defaults to zero position, identity rotation, unit scale") {
    var t = Transform.new()
    Expect.that(t.position.x).toBe(0)
    Expect.that(t.position.y).toBe(0)
    Expect.that(t.position.z).toBe(0)
    Expect.that(t.scale.x).toBe(1)
    Expect.that(t.scale.y).toBe(1)
    Expect.that(t.scale.z).toBe(1)
    Expect.that(t.localMatrix.approxEq(Mat4.identity)).toBe(true)
  }

  Test.it("translation-only composes into Mat4.translation") {
    var t = Transform.translation(3, -2, 5)
    var m = t.localMatrix
    Expect.that(m.approxEq(Mat4.translation(3, -2, 5))).toBe(true)
  }

  Test.it("setting a component re-builds the local matrix on next read") {
    var t = Transform.new()
    var first = t.localMatrix
    Expect.that(first.approxEq(Mat4.identity)).toBe(true)
    t.position = Vec3.new(10, 0, 0)
    var second = t.localMatrix
    Expect.that(second.approxEq(Mat4.translation(10, 0, 0))).toBe(true)
  }

  Test.it("local matrix order is T * R * S") {
    var t = Transform.new()
    t.position = Vec3.new(1, 0, 0)
    t.scale    = Vec3.new(2, 2, 2)
    var p = t.localMatrix.transformPoint(Vec3.new(1, 0, 0))
    // (1,0,0) under scale 2 → (2,0,0); then translate +1 → (3,0,0).
    Expect.that((p.x - 3).abs < 0.000001).toBe(true)
    Expect.that(p.y.abs < 0.000001).toBe(true)
    Expect.that(p.z.abs < 0.000001).toBe(true)
  }

  Test.it("rotation round-trips through Quat.toMat4") {
    var q = Quat.fromAxisAngle(Vec3.unitY, 1.5708) // ~90deg about Y
    var t = Transform.new()
    t.rotation = q
    var v = t.localMatrix.transformPoint(Vec3.new(1, 0, 0))
    // +X under +90° about Y → -Z in a right-handed frame.
    Expect.that(v.x.abs < 0.001).toBe(true)
    Expect.that(v.y.abs < 0.001).toBe(true)
    Expect.that((v.z + 1).abs < 0.001).toBe(true)
  }
}

Test.describe("TransformPropagation") {
  Test.it("single root entity propagates local into GlobalTransform") {
    var w = World.new()
    var e = w.spawn()
    w.attach(e, Transform.translation(5, 0, 0))

    TransformPropagation.run(w)

    var gt = w.get(e, GlobalTransform)
    Expect.that(gt == null).toBe(false)
    var p = gt.matrix.transformPoint(Vec3.zero)
    Expect.that(p.x).toBe(5)
  }

  Test.it("parent translation accumulates into child world position") {
    var w = World.new()
    var parent = w.spawn()
    var child  = w.spawn()
    w.attach(parent, Transform.translation(10, 0, 0))
    w.attach(child,  Transform.translation(0, 3, 0))
    w.setParent(child, parent)

    TransformPropagation.run(w)

    var gt = w.get(child, GlobalTransform)
    var p  = gt.matrix.transformPoint(Vec3.zero)
    Expect.that(p.x).toBe(10)
    Expect.that(p.y).toBe(3)
    Expect.that(p.z).toBe(0)
  }

  Test.it("siblings receive independent world matrices") {
    var w = World.new()
    var parent = w.spawn()
    var a = w.spawn()
    var b = w.spawn()
    w.attach(parent, Transform.translation(1, 0, 0))
    w.attach(a,      Transform.translation(0, 2, 0))
    w.attach(b,      Transform.translation(0, 0, 3))
    w.setParent(a, parent)
    w.setParent(b, parent)

    TransformPropagation.run(w)

    var pa = w.get(a, GlobalTransform).matrix.transformPoint(Vec3.zero)
    var pb = w.get(b, GlobalTransform).matrix.transformPoint(Vec3.zero)
    Expect.that(pa.x).toBe(1)
    Expect.that(pa.y).toBe(2)
    Expect.that(pa.z).toBe(0)
    Expect.that(pb.x).toBe(1)
    Expect.that(pb.y).toBe(0)
    Expect.that(pb.z).toBe(3)
  }

  Test.it("3-deep chain composes left-to-right") {
    var w = World.new()
    var a = w.spawn()
    var b = w.spawn()
    var c = w.spawn()
    w.attach(a, Transform.translation(1, 0, 0))
    w.attach(b, Transform.translation(0, 1, 0))
    w.attach(c, Transform.translation(0, 0, 1))
    w.setParent(b, a)
    w.setParent(c, b)

    TransformPropagation.run(w)

    var pc = w.get(c, GlobalTransform).matrix.transformPoint(Vec3.zero)
    Expect.that(pc.x).toBe(1)
    Expect.that(pc.y).toBe(1)
    Expect.that(pc.z).toBe(1)
  }

  Test.it("re-running picks up post-update local changes") {
    var w = World.new()
    var parent = w.spawn()
    var child  = w.spawn()
    var tp = Transform.translation(0, 0, 0)
    w.attach(parent, tp)
    w.attach(child,  Transform.translation(1, 0, 0))
    w.setParent(child, parent)

    TransformPropagation.run(w)
    var first = w.get(child, GlobalTransform).matrix.transformPoint(Vec3.zero)
    Expect.that(first.x).toBe(1)

    tp.position = Vec3.new(10, 0, 0)
    TransformPropagation.run(w)
    var second = w.get(child, GlobalTransform).matrix.transformPoint(Vec3.zero)
    Expect.that(second.x).toBe(11)
  }

  Test.it("unparented entity walks as a root the next frame") {
    var w = World.new()
    var parent = w.spawn()
    var child  = w.spawn()
    w.attach(parent, Transform.translation(10, 0, 0))
    w.attach(child,  Transform.translation(0, 0, 0))
    w.setParent(child, parent)
    TransformPropagation.run(w)
    var p1 = w.get(child, GlobalTransform).matrix.transformPoint(Vec3.zero)
    Expect.that(p1.x).toBe(10)

    w.unparent(child)
    TransformPropagation.run(w)
    var p2 = w.get(child, GlobalTransform).matrix.transformPoint(Vec3.zero)
    Expect.that(p2.x).toBe(0)
  }

  Test.it("entity without Transform skips the world matrix but still walks descendants") {
    var w = World.new()
    var root   = w.spawn()
    var middle = w.spawn()
    var leaf   = w.spawn()
    w.attach(root, Transform.translation(7, 0, 0))
    // `middle` has no Transform — should pass parent's world through.
    w.attach(leaf, Transform.translation(0, 2, 0))
    w.setParent(middle, root)
    w.setParent(leaf,   middle)

    TransformPropagation.run(w)

    var p = w.get(leaf, GlobalTransform).matrix.transformPoint(Vec3.zero)
    Expect.that(p.x).toBe(7)
    Expect.that(p.y).toBe(2)
  }

  Test.it("GlobalTransform is reused on subsequent runs, not re-attached") {
    var w = World.new()
    var e = w.spawn()
    w.attach(e, Transform.translation(1, 0, 0))
    TransformPropagation.run(w)
    var gt1 = w.get(e, GlobalTransform)
    TransformPropagation.run(w)
    var gt2 = w.get(e, GlobalTransform)
    Expect.that(gt1 == gt2).toBe(true)
  }
}

Test.describe("Light components") {
  Test.it("DirectionalLight defaults to white at intensity 1") {
    var l = DirectionalLight.new()
    Expect.that(l.color.x).toBe(1)
    Expect.that(l.color.y).toBe(1)
    Expect.that(l.color.z).toBe(1)
    Expect.that(l.intensity).toBe(1.0)
  }

  Test.it("DirectionalLight accepts explicit color + intensity") {
    var l = DirectionalLight.new(Vec3.new(1.0, 0.95, 0.85), 3.0)
    Expect.that(l.color.y).toBe(0.95)
    Expect.that(l.intensity).toBe(3.0)
  }

  Test.it("PointLight defaults to unbounded range") {
    var l = PointLight.new()
    Expect.that(l.range).toBe(0.0)
    Expect.that(l.intensity).toBe(1.0)
  }

  Test.it("PointLight setters mutate") {
    var l = PointLight.new()
    l.range = 12.0
    l.intensity = 4.5
    Expect.that(l.range).toBe(12.0)
    Expect.that(l.intensity).toBe(4.5)
  }

  Test.it("SpotLight stores inner + outer cone half-angles") {
    var l = SpotLight.new(Vec3.new(1, 1, 1), 5.0, 20.0, 0.4, 0.7)
    Expect.that(l.innerConeAngle).toBe(0.4)
    Expect.that(l.outerConeAngle).toBe(0.7)
    Expect.that(l.range).toBe(20.0)
  }

  Test.it("AmbientLight defaults to dim white") {
    var a = AmbientLight.new()
    Expect.that(a.intensity).toBe(0.1)
    Expect.that(a.color.x).toBe(1)
  }

  Test.it("Lights attach as ECS components to plain entities") {
    var w = World.new()
    var sun = w.spawn()
    var sunLight = DirectionalLight.new(Vec3.new(1, 0.95, 0.85), 3.0)
    w.attach(sun, sunLight)
    Expect.that(w.get(sun, DirectionalLight)).toBe(sunLight)
    Expect.that(w.query(DirectionalLight).count).toBe(1)
  }
}

// Mock Renderer3D — captures every API call SceneRenderer3D
// makes against it. The actual GPU-backed renderer is untestable
// without hardware; this stub exercises the bridge logic
// (light extraction, world-space position derivation, mesh draw
// dispatch).
class MockRenderer3D_ {
  construct new() {
    _calls = []
  }
  calls { _calls }

  beginFrame(pass, camera) { _calls.add(["beginFrame", camera]) }
  setAmbient(color, intensity) { _calls.add(["setAmbient", color, intensity]) }
  addDirectional(dir, color, intensity) {
    _calls.add(["addDirectional", dir, color, intensity])
  }
  addPoint(pos, color, intensity, range) {
    _calls.add(["addPoint", pos, color, intensity, range])
  }
  addSpot(pos, dir, color, intensity, range, innerCos, outerCos) {
    _calls.add(["addSpot", pos, dir, color, intensity, range, innerCos, outerCos])
  }
  draw(mesh, material, model) {
    _calls.add(["draw", mesh, material, model])
  }
}

// Mock Mesh / Material — opaque tokens for assertion identity.
class MockMesh_     { construct new(label) { _label = label } label { _label } }
class MockMaterial_ { construct new(label) { _label = label } label { _label } }

Test.describe("SceneRenderer3D ECS bridge") {
  Test.it("issues beginFrame + setAmbient + draws for every visible MeshRenderer") {
    var w = World.new()
    var amb = w.spawn()
    w.attach(amb, AmbientLight.new(Vec3.new(1, 1, 1), 0.5))

    var cube = w.spawn()
    var mesh = MockMesh_.new("cube")
    var mat  = MockMaterial_.new("red")
    w.attach(cube, Transform.translation(2, 0, 0))
    w.attach(cube, MeshRenderer.new(mesh, mat))

    TransformPropagation.run(w)

    var renderer = MockRenderer3D_.new()
    SceneRenderer3D.run(w, null, renderer, null)

    var calls = renderer.calls
    Expect.that(calls[0][0]).toBe("beginFrame")
    Expect.that(calls[1][0]).toBe("setAmbient")
    // Find the draw entry.
    var sawDraw = false
    for (c in calls) {
      if (c[0] == "draw") {
        sawDraw = true
        Expect.that(c[1]).toBe(mesh)
        Expect.that(c[2]).toBe(mat)
      }
    }
    Expect.that(sawDraw).toBe(true)
  }

  Test.it("skips MeshRenderer entities with visible = false") {
    var w = World.new()
    var hidden = w.spawn()
    w.attach(hidden, Transform.identity)
    var mr = MeshRenderer.new(MockMesh_.new("hidden"), MockMaterial_.new("any"))
    mr.visible = false
    w.attach(hidden, mr)

    TransformPropagation.run(w)

    var renderer = MockRenderer3D_.new()
    SceneRenderer3D.run(w, null, renderer, null)

    var drawCount = 0
    for (c in renderer.calls) {
      if (c[0] == "draw") drawCount = drawCount + 1
    }
    Expect.that(drawCount).toBe(0)
  }

  Test.it("derives PointLight world position from GlobalTransform") {
    var w = World.new()
    var lamp = w.spawn()
    w.attach(lamp, Transform.translation(0, 3, 0))
    w.attach(lamp, PointLight.new(Vec3.new(1, 0.8, 0.5), 5.0, 10.0))

    TransformPropagation.run(w)

    var renderer = MockRenderer3D_.new()
    SceneRenderer3D.run(w, null, renderer, null)

    var pointCall = null
    for (c in renderer.calls) {
      if (c[0] == "addPoint") pointCall = c
    }
    Expect.that(pointCall == null).toBe(false)
    var pos = pointCall[1]
    Expect.that(pos.x).toBe(0)
    Expect.that(pos.y).toBe(3)
    Expect.that(pos.z).toBe(0)
    Expect.that(pointCall[3]).toBe(5.0)   // intensity
    Expect.that(pointCall[4]).toBe(10.0)  // range
  }

  Test.it("derives DirectionalLight forward axis from Transform.rotation") {
    var w = World.new()
    var sun = w.spawn()
    // Identity rotation → forward is (0, 0, -1).
    w.attach(sun, Transform.identity)
    w.attach(sun, DirectionalLight.new(Vec3.new(1, 1, 1), 2.0))

    TransformPropagation.run(w)

    var renderer = MockRenderer3D_.new()
    SceneRenderer3D.run(w, null, renderer, null)

    var dirCall = null
    for (c in renderer.calls) {
      if (c[0] == "addDirectional") dirCall = c
    }
    Expect.that(dirCall == null).toBe(false)
    var dir = dirCall[1]
    Expect.that(dir.x.abs < 0.001).toBe(true)
    Expect.that(dir.y.abs < 0.001).toBe(true)
    Expect.that((dir.z + 1).abs < 0.001).toBe(true)
  }
}

// Per-dimension mock physics worlds for the PhysicsSystem3D /
// PhysicsSystem2D bridge specs. Each mock records every API call
// + lets the spec drive the reported positions / orientations
// back into the ECS Transforms. Split per dimension because the
// bridges read rotation in different shapes (3D: [w,x,y,z]; 2D:
// scalar angle).
class MockPhysicsWorld3D_ {
  construct new() {
    _calls   = []
    _nextId  = 1
    _bodies  = {}    // bodyId → { kind, desc, position, rotation }
  }
  calls  { _calls }

  spawnDynamic(desc)   { spawn_("dynamic",   desc) }
  spawnStatic(desc)    { spawn_("static",    desc) }
  spawnKinematic(desc) { spawn_("kinematic", desc) }

  spawn_(kind, desc) {
    var id = _nextId
    _nextId = _nextId + 1
    _bodies[id] = {
      "kind":     kind,
      "desc":     desc,
      "position": desc["position"],
      "rotation": [1, 0, 0, 0],   // identity quaternion
    }
    _calls.add(["spawn" + kind.replace("d", "D").replace("s", "S").replace("k", "K"), id, desc])
    return id
  }

  step(dt) { _calls.add(["step", dt]) }
  position(bodyId) { _bodies[bodyId]["position"] }
  rotation(bodyId) { _bodies[bodyId]["rotation"] }

  // Non-allocating writeback variants that match the foreign
  // shape on the physics plugin. Each writes its components into
  // a caller-provided `Float32Array` at the given element offset.
  positionInto(bodyId, out, offset) {
    var p = _bodies[bodyId]["position"]
    out[offset]     = p[0]
    out[offset + 1] = p[1]
    out[offset + 2] = p[2]
  }
  rotationInto(bodyId, out, offset) {
    var r = _bodies[bodyId]["rotation"]
    out[offset]     = r[0]
    out[offset + 1] = r[1]
    out[offset + 2] = r[2]
    out[offset + 3] = r[3]
  }

  setPosition_(bodyId, list) { _bodies[bodyId]["position"] = list }
  setRotation_(bodyId, list) { _bodies[bodyId]["rotation"] = list }
}

class MockPhysicsWorld2D_ {
  construct new() {
    _calls  = []
    _nextId = 1
    _bodies = {}
  }
  calls { _calls }

  spawnDynamic(desc) {
    var id = _nextId
    _nextId = _nextId + 1
    _bodies[id] = { "kind": "dynamic", "desc": desc, "position": desc["position"], "rotation": 0.0 }
    _calls.add(["spawnDynamic", id, desc])
    return id
  }
  spawnStatic(desc) {
    var id = _nextId
    _nextId = _nextId + 1
    _bodies[id] = { "kind": "static", "desc": desc, "position": desc["position"], "rotation": 0.0 }
    _calls.add(["spawnStatic", id, desc])
    return id
  }
  spawnKinematic(desc) {
    var id = _nextId
    _nextId = _nextId + 1
    _bodies[id] = { "kind": "kinematic", "desc": desc, "position": desc["position"], "rotation": 0.0 }
    _calls.add(["spawnKinematic", id, desc])
    return id
  }

  step(dt) { _calls.add(["step", dt]) }
  position(bodyId) { _bodies[bodyId]["position"] }
  rotation(bodyId) { _bodies[bodyId]["rotation"] }

  setPosition_(bodyId, list) { _bodies[bodyId]["position"] = list }
  setRotation_(bodyId, angle) { _bodies[bodyId]["rotation"] = angle }
}

Test.describe("RigidBody + Collider components") {
  Test.it("RigidBody defaults to dynamic, mass 1.0, no body id") {
    var rb = RigidBody.new()
    Expect.that(rb.kind).toBe("dynamic")
    Expect.that(rb.mass).toBe(1.0)
    Expect.that(rb.bodyId).toBe(null)
    Expect.that(rb.linearVelocity).toBe(null)
  }

  Test.it("RigidBody accepts kind + mass via ctors") {
    var rb1 = RigidBody.new("static")
    Expect.that(rb1.kind).toBe("static")
    Expect.that(rb1.mass).toBe(1.0)

    var rb2 = RigidBody.new("kinematic", 50.0)
    Expect.that(rb2.kind).toBe("kinematic")
    Expect.that(rb2.mass).toBe(50.0)
  }

  Test.it("Collider stores the shape descriptor verbatim") {
    var shape = { "kind": "ball", "radius": 0.5, "restitution": 0.6 }
    var c = Collider.new(shape)
    Expect.that(c.shape).toBe(shape)
    Expect.that(c.shape["restitution"]).toBe(0.6)
  }
}

Test.describe("PhysicsSystem3D bridge") {
  Test.it("spawns the right kind for each RigidBody.kind") {
    var w = World.new()
    var pw = MockPhysicsWorld3D_.new()

    var d = w.spawn()
    w.attach(d, Transform.translation(1, 2, 3))
    w.attach(d, RigidBody.new("dynamic", 5.0))
    w.attach(d, Collider.new({ "kind": "ball", "radius": 0.5 }))

    var s = w.spawn()
    w.attach(s, Transform.translation(0, 0, 0))
    w.attach(s, RigidBody.new("static"))
    w.attach(s, Collider.new({ "kind": "box", "halfX": 5, "halfY": 0.1, "halfZ": 5 }))

    var k = w.spawn()
    w.attach(k, Transform.translation(10, 0, 0))
    w.attach(k, RigidBody.new("kinematic", 2.0))
    w.attach(k, Collider.new({ "kind": "capsule", "halfHeight": 1.0, "radius": 0.3 }))

    PhysicsSystem3D.step(w, pw, 1.0 / 60)

    var kinds = []
    for (c in pw.calls) {
      if (c[0] == "spawnDynamic" || c[0] == "spawnStatic" || c[0] == "spawnKinematic") {
        kinds.add(c[0])
      }
    }
    Expect.that(kinds.contains("spawnDynamic")).toBe(true)
    Expect.that(kinds.contains("spawnStatic")).toBe(true)
    Expect.that(kinds.contains("spawnKinematic")).toBe(true)
  }

  Test.it("seeds spawn position from Transform.position") {
    var w = World.new()
    var pw = MockPhysicsWorld3D_.new()
    var e = w.spawn()
    w.attach(e, Transform.translation(7, -3, 11))
    w.attach(e, RigidBody.new())
    w.attach(e, Collider.new({ "kind": "ball", "radius": 1.0 }))

    PhysicsSystem3D.step(w, pw, 1.0 / 60)

    var spawnCall = pw.calls[0]
    var pos = spawnCall[2]["position"]
    Expect.that(pos[0]).toBe(7)
    Expect.that(pos[1]).toBe(-3)
    Expect.that(pos[2]).toBe(11)
  }

  Test.it("forwards optional linearVelocity") {
    var w = World.new()
    var pw = MockPhysicsWorld3D_.new()
    var e = w.spawn()
    w.attach(e, Transform.identity)
    var rb = RigidBody.new()
    rb.linearVelocity = Vec3.new(2, 4, -1)
    w.attach(e, rb)
    w.attach(e, Collider.new({ "kind": "ball", "radius": 0.5 }))

    PhysicsSystem3D.step(w, pw, 1.0 / 60)

    var v = pw.calls[0][2]["linearVelocity"]
    Expect.that(v[0]).toBe(2)
    Expect.that(v[1]).toBe(4)
    Expect.that(v[2]).toBe(-1)
  }

  Test.it("stamps RigidBody.bodyId after spawn") {
    var w = World.new()
    var pw = MockPhysicsWorld3D_.new()
    var e = w.spawn()
    var rb = RigidBody.new()
    w.attach(e, Transform.identity)
    w.attach(e, rb)
    w.attach(e, Collider.new({ "kind": "ball", "radius": 0.5 }))
    Expect.that(rb.bodyId).toBe(null)

    PhysicsSystem3D.step(w, pw, 1.0 / 60)
    Expect.that(rb.bodyId).toBe(1)

    // Second step shouldn't re-spawn — already has a bodyId.
    PhysicsSystem3D.step(w, pw, 1.0 / 60)
    var spawnCount = 0
    for (c in pw.calls) {
      if (c[0] == "spawnDynamic") spawnCount = spawnCount + 1
    }
    Expect.that(spawnCount).toBe(1)
  }

  Test.it("writes simulated position back into Transform.position") {
    var w = World.new()
    var pw = MockPhysicsWorld3D_.new()
    var e = w.spawn()
    var t = Transform.translation(0, 10, 0)
    var rb = RigidBody.new()
    w.attach(e, t)
    w.attach(e, rb)
    w.attach(e, Collider.new({ "kind": "ball", "radius": 0.5 }))

    PhysicsSystem3D.step(w, pw, 1.0 / 60)
    // Pretend gravity dropped the ball a bit.
    pw.setPosition_(rb.bodyId, [0, 9.5, 0])
    PhysicsSystem3D.step(w, pw, 1.0 / 60)

    Expect.that(t.position.y).toBe(9.5)
  }

  Test.it("doesn't write back static bodies") {
    var w = World.new()
    var pw = MockPhysicsWorld3D_.new()
    var e = w.spawn()
    var t = Transform.translation(0, 0, 0)
    var rb = RigidBody.new("static")
    w.attach(e, t)
    w.attach(e, rb)
    w.attach(e, Collider.new({ "kind": "box", "halfX": 5, "halfY": 0.1, "halfZ": 5 }))

    PhysicsSystem3D.step(w, pw, 1.0 / 60)
    pw.setPosition_(rb.bodyId, [99, 99, 99])
    PhysicsSystem3D.step(w, pw, 1.0 / 60)

    Expect.that(t.position.x).toBe(0)
    Expect.that(t.position.y).toBe(0)
    Expect.that(t.position.z).toBe(0)
  }

  Test.it("skips entities missing Transform or Collider") {
    var w = World.new()
    var pw = MockPhysicsWorld3D_.new()
    var e = w.spawn()
    w.attach(e, RigidBody.new())   // no Transform / Collider

    PhysicsSystem3D.step(w, pw, 1.0 / 60)

    var spawnCount = 0
    for (c in pw.calls) {
      if (c[0] == "spawnDynamic") spawnCount = spawnCount + 1
    }
    Expect.that(spawnCount).toBe(0)
  }
}

Test.describe("PhysicsSystem2D bridge") {
  Test.it("seeds 2D position from Transform.position xy") {
    var w = World.new()
    var pw = MockPhysicsWorld2D_.new()
    var e = w.spawn()
    w.attach(e, Transform.translation(3, 4, 99))  // z ignored
    w.attach(e, RigidBody.new())
    w.attach(e, Collider.new({ "kind": "ball", "radius": 0.5 }))

    PhysicsSystem2D.step(w, pw, 1.0 / 60)

    var pos = pw.calls[0][2]["position"]
    Expect.that(pos.count).toBe(2)
    Expect.that(pos[0]).toBe(3)
    Expect.that(pos[1]).toBe(4)
  }

  Test.it("preserves Transform.position.z across writeback") {
    var w = World.new()
    var pw = MockPhysicsWorld2D_.new()
    var e = w.spawn()
    var t = Transform.translation(0, 0, 5)   // z = depth hint
    var rb = RigidBody.new()
    w.attach(e, t)
    w.attach(e, rb)
    w.attach(e, Collider.new({ "kind": "ball", "radius": 0.5 }))

    PhysicsSystem2D.step(w, pw, 1.0 / 60)
    pw.setPosition_(rb.bodyId, [10, 20])
    PhysicsSystem2D.step(w, pw, 1.0 / 60)

    Expect.that(t.position.x).toBe(10)
    Expect.that(t.position.y).toBe(20)
    Expect.that(t.position.z).toBe(5)   // untouched
  }
}

Test.describe("Audio components") {
  Test.it("AudioSource defaults to no sound, full volume, non-looping") {
    var src = AudioSource.new()
    Expect.that(src.sound).toBe(null)
    Expect.that(src.volume).toBe(1.0)
    Expect.that(src.loop).toBe(false)
    Expect.that(src.spatial).toBe(false)
  }

  Test.it("AudioSource setters mutate") {
    var src = AudioSource.new()
    src.volume = 0.6
    src.loop = true
    src.spatial = true
    Expect.that(src.volume).toBe(0.6)
    Expect.that(src.loop).toBe(true)
    Expect.that(src.spatial).toBe(true)
  }

  Test.it("AudioListener attaches as an ECS component with gain") {
    var w = World.new()
    var cam = w.spawn()
    var listener = AudioListener.new()
    listener.gain = 0.8
    w.attach(cam, listener)
    Expect.that(w.get(cam, AudioListener)).toBe(listener)
    Expect.that(w.get(cam, AudioListener).gain).toBe(0.8)
  }
}

Test.run()
