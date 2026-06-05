// @hatch:gpu — `Renderer3D.writeInstanceXYZ` foliage fast path.
// Hardware-free spec: asserts the 32-float instance slot matches
// the equivalent `writeInstance(.., Mat4.translation × rotationY ×
// scale)` so the GPU sees the same column-major matrix on either
// path. Catches sign-flip or transpose regressions during the
// foliage-shader work.

import "./gpu"        for Renderer3D
import "@hatch:math"  for Mat4
import "@hatch:test"  for Test
import "@hatch:assert" for Expect

Test.describe("Renderer3D.writeInstanceXYZ") {
  Test.it("packs the same 32-float slot as appendInstance(T*Ry*S)") {
    var x = 1.5
    var y = 2.0
    var z = -3.25
    var scale = 0.8
    var yaw = 0.7   // radians

    // Reference: build the Mat4 the long way and use appendInstance.
    var rotY = Mat4.rotationY(yaw)
    var scl  = Mat4.scale(scale, scale, scale)
    var trn  = Mat4.translation(x, y, z)
    var model = trn * (rotY * scl)
    var refSlot = []
    Renderer3D.appendInstance(refSlot, model)

    var fast = Float32Array.new(32)
    Renderer3D.writeInstanceXYZ(fast, 0, x, y, z, scale, yaw)

    // Model half (first 16 floats) — must match bit-for-bit up to
    // small float rounding (no math beyond sin/cos differs).
    for (i in 0...16) {
      var diff = (fast[i] - refSlot[i]).abs
      Expect.that(diff < 1e-5).toBe(true)
    }
    // Normal matrix half — `writeInstanceXYZ` drops scale (rot
    // only) because the VS renormalizes; `appendInstance(model)`
    // would carry the scale. Confirm the rotation entries match
    // by recomputing the scaleless reference.
    var refNorm = []
    Renderer3D.appendInstance(refNorm, trn * rotY)
    // Skip translation column (12..15) — we don't use it for normals.
    var rotCols = [16, 17, 18, 20, 21, 22, 24, 25, 26]
    for (idx in rotCols) {
      var refIdx = idx     // refNorm 16..31 is its own normal_mat half
      var diff = (fast[idx] - refNorm[refIdx]).abs
      Expect.that(diff < 1e-5).toBe(true)
    }
  }

  Test.it("yaw=0, scale=1 reduces to a pure translation") {
    var fast = Float32Array.new(32)
    Renderer3D.writeInstanceXYZ(fast, 0, 1, 2, 3, 1, 0)
    // Model col 0 = (1, 0, 0, 0), col 1 = (0, 1, 0, 0),
    // col 2 = (0, 0, 1, 0), col 3 = (1, 2, 3, 1).
    Expect.that(fast[0]).toBe(1)   // cos(0)
    Expect.that(fast[5]).toBe(1)
    Expect.that(fast[10]).toBe(1)
    Expect.that(fast[12]).toBe(1)
    Expect.that(fast[13]).toBe(2)
    Expect.that(fast[14]).toBe(3)
    Expect.that(fast[15]).toBe(1)
  }

  Test.it("slot offset lays subsequent instances at multiples of 32") {
    var fast = Float32Array.new(64)
    Renderer3D.writeInstanceXYZ(fast, 0, 1, 0, 0, 1, 0)
    Renderer3D.writeInstanceXYZ(fast, 1, 5, 0, 0, 1, 0)
    Expect.that(fast[12]).toBe(1)   // slot 0 x
    Expect.that(fast[44]).toBe(5)   // slot 1 x (offset 32 + 12)
  }
}

Test.run()
