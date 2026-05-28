// @hatch:game scene module — Transform + propagation specs.

import "./scene"        for
  Transform,
  GlobalTransform,
  DirectionalLight,
  PointLight,
  SpotLight,
  AmbientLight,
  TransformPropagation
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

Test.run()
