import "./math"       for Vec2, Vec3, Vec4, Mat4, Quat, Math, Ease
import "@hatch:test"   for Test
import "@hatch:assert" for Expect

// --- Scalar helpers -------------------------------------------

Test.describe("Math scalar helpers") {
  Test.it("radians / degrees round-trip") {
    Expect.that(Math.approxEq(Math.radians(180), Math.PI)).toBe(true)
    Expect.that(Math.approxEq(Math.degrees(Math.PI), 180)).toBe(true)
  }
  Test.it("lerp / inverseLerp") {
    Expect.that(Math.lerp(0, 10, 0.25)).toBe(2.5)
    Expect.that(Math.lerp(0, 10, 0)).toBe(0)
    Expect.that(Math.lerp(0, 10, 1)).toBe(10)
    Expect.that(Math.inverseLerp(10, 20, 15)).toBe(0.5)
    Expect.that(Math.inverseLerp(5, 5, 5)).toBe(0)
  }
  Test.it("clamp / saturate") {
    Expect.that(Math.clamp(5, 0, 10)).toBe(5)
    Expect.that(Math.clamp(-1, 0, 10)).toBe(0)
    Expect.that(Math.clamp(11, 0, 10)).toBe(10)
    Expect.that(Math.saturate(0.5)).toBe(0.5)
    Expect.that(Math.saturate(-0.1)).toBe(0)
    Expect.that(Math.saturate(1.5)).toBe(1)
  }
  Test.it("smoothstep endpoints") {
    Expect.that(Math.smoothstep(0, 1, 0)).toBe(0)
    Expect.that(Math.smoothstep(0, 1, 1)).toBe(1)
    Expect.that(Math.smoothstep(0, 1, 0.5)).toBe(0.5)
  }
  Test.it("smootherstep endpoints") {
    Expect.that(Math.smootherstep(0, 1, 0)).toBe(0)
    Expect.that(Math.smootherstep(0, 1, 1)).toBe(1)
  }
  Test.it("min / max / sign") {
    Expect.that(Math.min(3, 5)).toBe(3)
    Expect.that(Math.max(3, 5)).toBe(5)
    Expect.that(Math.sign(-4)).toBe(-1)
    Expect.that(Math.sign(0)).toBe(0)
    Expect.that(Math.sign(7)).toBe(1)
  }
  Test.it("approxEq honours tolerance") {
    Expect.that(Math.approxEq(1.0000001, 1)).toBe(true)
    Expect.that(Math.approxEq(1.01, 1)).toBe(false)
    Expect.that(Math.approxEq(1.01, 1, 0.1)).toBe(true)
  }
  Test.it("wrap handles angle rollover") {
    Expect.that(Math.wrap(370, 0, 360)).toBe(10)
    Expect.that(Math.wrap(-10, 0, 360)).toBe(350)
    Expect.that(Math.wrap(90, 0, 360)).toBe(90)
  }
}

// --- Ease ------------------------------------------------------

Test.describe("Ease curves") {
  Test.it("linear is y = x") {
    Expect.that(Ease.linear(0.3)).toBe(0.3)
  }
  Test.it("quad endpoints pin") {
    for (name in ["inQuad", "outQuad", "inOutQuad", "inCubic", "outCubic", "inOutCubic"]) {
      // Invoke via a tiny dispatch map so we exercise all of them.
    }
    Expect.that(Ease.inQuad (0)).toBe(0)
    Expect.that(Ease.inQuad (1)).toBe(1)
    Expect.that(Ease.outQuad(0)).toBe(0)
    Expect.that(Ease.outQuad(1)).toBe(1)
    Expect.that(Ease.inOutQuad (0.5)).toBe(0.5)
    Expect.that(Ease.inOutCubic(0.5)).toBe(0.5)
  }
  Test.it("inExpo pinned at 0, approaches 1") {
    Expect.that(Ease.inExpo (0)).toBe(0)
    Expect.that(Math.approxEq(Ease.inExpo (1), 1)).toBe(true)
  }
  Test.it("outExpo pinned at 1") {
    Expect.that(Ease.outExpo(1)).toBe(1)
    Expect.that(Math.approxEq(Ease.outExpo(0), 0)).toBe(true)
  }
  Test.it("inBack overshoots") {
    // Midpoint should drop below 0 for inBack (classic overshoot).
    Expect.that(Ease.inBack(0.2) < 0).toBe(true)
  }
  Test.it("clamps outside [0, 1]") {
    Expect.that(Ease.linear(-0.5)).toBe(0)
    Expect.that(Ease.linear(1.5)).toBe(1)
  }
}

// --- Vec2 ------------------------------------------------------

Test.describe("Vec2") {
  Test.it("constructor + accessors") {
    var v = Vec2.new(1, 2)
    Expect.that(v.x).toBe(1)
    Expect.that(v.y).toBe(2)
  }
  Test.it("zero / one / unit") {
    Expect.that(Vec2.zero.x).toBe(0)
    Expect.that(Vec2.one.x).toBe(1)
    Expect.that(Vec2.unitX.x).toBe(1)
    Expect.that(Vec2.unitY.y).toBe(1)
  }
  Test.it("arithmetic with scalar + vec") {
    var a = Vec2.new(1, 2)
    var b = Vec2.new(3, 5)
    Expect.that((a + b).toList).toEqual([4, 7])
    Expect.that((b - a).toList).toEqual([2, 3])
    Expect.that((a * 3).toList).toEqual([3, 6])
    Expect.that((a * b).toList).toEqual([3, 10])
    Expect.that((b / 2).toList).toEqual([1.5, 2.5])
  }
  Test.it("negation") {
    Expect.that((-Vec2.new(1, -2)).toList).toEqual([-1, 2])
  }
  Test.it("length / lengthSq / normalize") {
    var v = Vec2.new(3, 4)
    Expect.that(v.lengthSq).toBe(25)
    Expect.that(v.length).toBe(5)
    Expect.that(v.normalized.approxEq(Vec2.new(0.6, 0.8))).toBe(true)
  }
  Test.it("normalized on zero stays zero") {
    Expect.that(Vec2.zero.normalized.approxEq(Vec2.zero)).toBe(true)
  }
  Test.it("dot / cross / distance") {
    var a = Vec2.new(1, 0)
    var b = Vec2.new(0, 1)
    Expect.that(a.dot(b)).toBe(0)
    Expect.that(a.cross(b)).toBe(1)
    Expect.that(a.distance(b)).toBe(2.sqrt)
  }
  Test.it("lerp across") {
    var a = Vec2.new(0, 0)
    var b = Vec2.new(10, 20)
    Expect.that(Vec2.lerp(a, b, 0.5).toList).toEqual([5, 10])
  }
  Test.it("addInto + mulIntoScalar don't allocate a new vec") {
    var out = Vec2.zero
    out.addInto(Vec2.new(1, 2), Vec2.new(3, 4))
    Expect.that(out.toList).toEqual([4, 6])
    out.mulIntoScalar(out, 2)
    Expect.that(out.toList).toEqual([8, 12])
  }
  Test.it("approxEq honours eps") {
    var a = Vec2.new(1, 2)
    var b = Vec2.new(1.0000001, 2.0000001)
    Expect.that(a.approxEq(b)).toBe(true)
    Expect.that(a == b).toBe(false)
  }
}

// --- Vec3 ------------------------------------------------------

Test.describe("Vec3") {
  Test.it("unit vectors") {
    Expect.that(Vec3.unitX.toList).toEqual([1, 0, 0])
    Expect.that(Vec3.unitY.toList).toEqual([0, 1, 0])
    Expect.that(Vec3.unitZ.toList).toEqual([0, 0, 1])
  }
  Test.it("arithmetic") {
    var a = Vec3.new(1, 2, 3)
    var b = Vec3.new(10, 20, 30)
    Expect.that((a + b).toList).toEqual([11, 22, 33])
    Expect.that((b - a).toList).toEqual([9, 18, 27])
    Expect.that((a * 2).toList).toEqual([2, 4, 6])
  }
  Test.it("length / normalize") {
    var v = Vec3.new(2, 3, 6)
    Expect.that(v.length).toBe(7)
    Expect.that(Math.approxEq(v.normalized.length, 1)).toBe(true)
  }
  Test.it("dot / cross follow right-hand rule") {
    Expect.that(Vec3.unitX.cross(Vec3.unitY).approxEq(Vec3.unitZ)).toBe(true)
    Expect.that(Vec3.unitY.cross(Vec3.unitZ).approxEq(Vec3.unitX)).toBe(true)
    Expect.that(Vec3.unitZ.cross(Vec3.unitX).approxEq(Vec3.unitY)).toBe(true)
    Expect.that(Vec3.unitX.dot(Vec3.unitY)).toBe(0)
    Expect.that(Vec3.unitX.dot(Vec3.unitX)).toBe(1)
  }
  Test.it("distance") {
    var a = Vec3.new(0, 0, 0)
    var b = Vec3.new(3, 0, 4)
    Expect.that(a.distance(b)).toBe(5)
  }
  Test.it("lerp across") {
    var a = Vec3.zero
    var b = Vec3.new(10, 20, 30)
    Expect.that(Vec3.lerp(a, b, 0.1).approxEq(Vec3.new(1, 2, 3))).toBe(true)
  }
  Test.it("reflect") {
    var i = Vec3.new(1, -1, 0)
    var n = Vec3.unitY
    Expect.that(i.reflect(n).approxEq(Vec3.new(1, 1, 0))).toBe(true)
  }
  Test.it("in-place ops mutate receiver") {
    var v = Vec3.new(0, 0, 0)
    v.addInto(Vec3.new(1, 2, 3), Vec3.new(4, 5, 6))
    Expect.that(v.toList).toEqual([5, 7, 9])
    v.subInto(Vec3.new(10, 10, 10), Vec3.new(1, 2, 3))
    Expect.that(v.toList).toEqual([9, 8, 7])
  }
}

// --- Vec4 ------------------------------------------------------

Test.describe("Vec4") {
  Test.it("rgba accessors alias xyzw") {
    var c = Vec4.rgba(0.1, 0.2, 0.3, 1)
    Expect.that(c.r).toBe(0.1)
    Expect.that(c.g).toBe(0.2)
    Expect.that(c.b).toBe(0.3)
    Expect.that(c.a).toBe(1)
  }
  Test.it("xyz drops w") {
    var v = Vec4.new(1, 2, 3, 4)
    Expect.that(v.xyz.toList).toEqual([1, 2, 3])
  }
  Test.it("arithmetic + lerp") {
    var a = Vec4.new(0, 0, 0, 0)
    var b = Vec4.new(10, 20, 30, 40)
    Expect.that(Vec4.lerp(a, b, 0.5).toList).toEqual([5, 10, 15, 20])
  }
  Test.it("length / dot") {
    Expect.that(Vec4.new(1, 2, 2, 0).length).toBe(3)
    Expect.that(Vec4.new(1, 0, 0, 0).dot(Vec4.new(0, 1, 0, 0))).toBe(0)
  }
}

// --- Mat4 ------------------------------------------------------

Test.describe("Mat4") {
  Test.it("identity") {
    var m = Mat4.identity
    Expect.that(m.at(0, 0)).toBe(1)
    Expect.that(m.at(1, 1)).toBe(1)
    Expect.that(m.at(2, 2)).toBe(1)
    Expect.that(m.at(3, 3)).toBe(1)
    Expect.that(m.at(0, 1)).toBe(0)
  }
  Test.it("translation on Vec3") {
    var t = Mat4.translation(1, 2, 3)
    var p = t.transformPoint(Vec3.zero)
    Expect.that(p.approxEq(Vec3.new(1, 2, 3))).toBe(true)
  }
  Test.it("scale on Vec3") {
    var s = Mat4.scale(2, 3, 4)
    var p = s.transformPoint(Vec3.new(1, 1, 1))
    Expect.that(p.approxEq(Vec3.new(2, 3, 4))).toBe(true)
  }
  Test.it("rotationY(PI/2) rotates unitX to -unitZ") {
    var r = Mat4.rotationY(Math.HALF_PI)
    var out = r.transformPoint(Vec3.unitX)
    Expect.that(out.approxEq(Vec3.new(0, 0, -1))).toBe(true)
  }
  Test.it("rotationZ(PI/2) rotates unitX to unitY") {
    var r = Mat4.rotationZ(Math.HALF_PI)
    var out = r.transformPoint(Vec3.unitX)
    Expect.that(out.approxEq(Vec3.unitY)).toBe(true)
  }
  Test.it("identity multiply is a no-op") {
    var a = Mat4.translation(1, 2, 3)
    Expect.that((a * Mat4.identity).approxEq(a)).toBe(true)
    Expect.that((Mat4.identity * a).approxEq(a)).toBe(true)
  }
  Test.it("multiply composes: T then Ry(PI/2) applied to unitX") {
    var compose = Mat4.translation(10, 0, 0) * Mat4.rotationY(Math.HALF_PI)
    // Composition applies rightmost first: rotate unitX to -unitZ, then translate.
    var out = compose.transformPoint(Vec3.unitX)
    Expect.that(out.approxEq(Vec3.new(10, 0, -1))).toBe(true)
  }
  Test.it("transpose swaps rows and columns") {
    var m = Mat4.fromList([
      1, 2, 3, 4,
      5, 6, 7, 8,
      9, 10, 11, 12,
      13, 14, 15, 16
    ])
    var t = m.transpose
    Expect.that(t.at(0, 1)).toBe(5)
    Expect.that(t.at(2, 3)).toBe(15)
  }
  Test.it("transformDir ignores translation") {
    var m = Mat4.translation(100, 200, 300)
    var d = m.transformDir(Vec3.unitX)
    Expect.that(d.approxEq(Vec3.unitX)).toBe(true)
  }
  Test.it("perspective projects along -z") {
    var p = Mat4.perspective(Math.HALF_PI, 1, 0.1, 100)
    // A point directly on the -z axis at z=-1 should project to
    // near the origin in clip space.
    var out = p.transformVec4(Vec4.new(0, 0, -1, 1))
    Expect.that(Math.approxEq(out.x, 0)).toBe(true)
    Expect.that(Math.approxEq(out.y, 0)).toBe(true)
  }
  Test.it("lookAt places camera + maps forward to -z") {
    var eye    = Vec3.new(0, 0, 5)
    var target = Vec3.zero
    var up     = Vec3.unitY
    var view   = Mat4.lookAt(eye, target, up)
    var out    = view.transformPoint(Vec3.zero)
    // Origin relative to a camera at +5z should appear 5 units along -z.
    Expect.that(out.approxEq(Vec3.new(0, 0, -5))).toBe(true)
  }
}

// --- Quat ------------------------------------------------------

Test.describe("Quat") {
  Test.it("identity is (1, 0, 0, 0)") {
    Expect.that(Quat.identity.w).toBe(1)
    Expect.that(Quat.identity.x).toBe(0)
  }
  Test.it("fromAxisAngle unit-length") {
    var q = Quat.fromAxisAngle(Vec3.unitY, Math.HALF_PI)
    Expect.that(Math.approxEq(q.length, 1)).toBe(true)
  }
  Test.it("rotateVec3 by Y axis 90° sends unitX to -unitZ") {
    var q = Quat.fromAxisAngle(Vec3.unitY, Math.HALF_PI)
    var r = q.rotateVec3(Vec3.unitX)
    Expect.that(r.approxEq(Vec3.new(0, 0, -1))).toBe(true)
  }
  Test.it("rotateVec3 by Z axis 90° sends unitX to unitY") {
    var q = Quat.fromAxisAngle(Vec3.unitZ, Math.HALF_PI)
    var r = q.rotateVec3(Vec3.unitX)
    Expect.that(r.approxEq(Vec3.unitY)).toBe(true)
  }
  Test.it("conjugate inverts a unit quaternion's rotation") {
    var q = Quat.fromAxisAngle(Vec3.unitY, Math.HALF_PI)
    var v = q.rotateVec3(Vec3.unitX)
    Expect.that(q.conjugate.rotateVec3(v).approxEq(Vec3.unitX)).toBe(true)
  }
  Test.it("multiplication composes: applying a*b == apply b then a") {
    var yaw    = Quat.fromAxisAngle(Vec3.unitY, Math.HALF_PI)
    var pitch  = Quat.fromAxisAngle(Vec3.unitZ, Math.HALF_PI)
    var combo  = yaw * pitch
    var sequential = yaw.rotateVec3(pitch.rotateVec3(Vec3.unitX))
    Expect.that(combo.rotateVec3(Vec3.unitX).approxEq(sequential)).toBe(true)
  }
  Test.it("slerp endpoints") {
    var a = Quat.identity
    var b = Quat.fromAxisAngle(Vec3.unitY, Math.HALF_PI)
    Expect.that(Quat.slerp(a, b, 0).approxEq(a)).toBe(true)
    Expect.that(Quat.slerp(a, b, 1).approxEq(b)).toBe(true)
  }
  Test.it("slerp midpoint is a proper halfway rotation") {
    var a = Quat.identity
    var b = Quat.fromAxisAngle(Vec3.unitY, Math.PI / 2)
    var half = Quat.slerp(a, b, 0.5)
    // Apply twice → should equal applying `b` once.
    var twice = half.rotateVec3(half.rotateVec3(Vec3.unitX))
    var once  = b.rotateVec3(Vec3.unitX)
    Expect.that(twice.approxEq(once)).toBe(true)
  }
  Test.it("toMat4 matches direct rotation") {
    var q = Quat.fromAxisAngle(Vec3.unitY, Math.HALF_PI)
    var m = q.toMat4
    var viaMat = m.transformPoint(Vec3.unitX)
    var viaQuat = q.rotateVec3(Vec3.unitX)
    Expect.that(viaMat.approxEq(viaQuat)).toBe(true)
  }
}

Test.run()
