// @hatch:gpu — Lod.select3 boundary behaviour.
//
// Distance-based LOD: returns 0 / 1 / 2 against two ascending
// squared thresholds. The just-below / at / just-above cases pin
// the comparison operator (strict `<`) so a future refactor can't
// silently swap it for `<=` and shift every bucket boundary.

import "./gpu" for Camera3D, Frustum, Lod
import "@hatch:math"   for Vec3
import "@hatch:time"   for Clock
import "@hatch:test"   for Test
import "@hatch:assert" for Expect

Test.describe("Lod.select3") {
  Test.it("returns 0 when squared distance is below t0sq") {
    // Camera at origin, instance at (3, 0, 0) → distance² = 9.
    // t0sq = 16 (t0 = 4) → 9 < 16 → 0.
    Expect.that(Lod.select3(0, 0, 0, 3, 0, 0, 16, 64)).toBe(0)
  }

  Test.it("returns 1 when t0sq <= squared distance < t1sq") {
    // Camera at origin, instance at (5, 0, 0) → distance² = 25.
    // t0sq = 16, t1sq = 100 → 16 ≤ 25 < 100 → 1.
    Expect.that(Lod.select3(0, 0, 0, 5, 0, 0, 16, 100)).toBe(1)
  }

  Test.it("returns 2 when squared distance >= t1sq") {
    // Camera at origin, instance at (12, 0, 0) → distance² = 144.
    // t1sq = 100 → 144 ≥ 100 → 2.
    Expect.that(Lod.select3(0, 0, 0, 12, 0, 0, 16, 100)).toBe(2)
  }

  Test.it("handles a non-origin camera") {
    // Camera at (10, 0, 0), instance at (10, 5, 0) → distance² = 25.
    Expect.that(Lod.select3(10, 0, 0, 10, 5, 0, 16, 100)).toBe(1)
    Expect.that(Lod.select3(10, 0, 0, 10, 5, 0, 36, 100)).toBe(0)
  }

  Test.it("treats the t0sq boundary as exclusive (distance² == t0sq → bucket 1)") {
    // distance² = 25, t0sq = 25 → not strictly < → bucket 1.
    Expect.that(Lod.select3(0, 0, 0, 3, 4, 0, 25, 100)).toBe(1)
  }

  Test.it("treats the t1sq boundary as exclusive (distance² == t1sq → bucket 2)") {
    // distance² = 100, t1sq = 100 → not strictly < → bucket 2.
    Expect.that(Lod.select3(0, 0, 0, 6, 8, 0, 16, 100)).toBe(2)
  }

  Test.it("is symmetric across all three axes") {
    // distance² should be invariant under axis permutation.
    var a = Lod.select3(0, 0, 0, 3, 4, 5, 25, 100)   // d² = 50
    var b = Lod.select3(0, 0, 0, 5, 3, 4, 25, 100)
    var c = Lod.select3(0, 0, 0, 4, 5, 3, 25, 100)
    Expect.that(a).toBe(1)
    Expect.that(b).toBe(1)
    Expect.that(c).toBe(1)
  }
}

Test.describe("Lod + Frustum cull exit-gate") {
  Test.it("buckets a 10k cube grid into close / mid / far + culled") {
    // 100×100 grid spanning ±150 world units, camera high and back
    // — typical isometric framing. Composed: frustum cull first,
    // then LOD on the survivors. The bucket counts characterise
    // the win at the procedural-world target's scale.
    var n = 10000
    var perRow = 100
    var spacing = 3
    var origin = -((perRow - 1) * spacing) / 2

    var xs = Float32Array.new(n)
    var ys = Float32Array.new(n)
    var zs = Float32Array.new(n)
    for (i in 0...n) {
      var col = (i % perRow).floor
      var row = (i / perRow).floor
      xs[i] = origin + col * spacing
      ys[i] = 0
      zs[i] = origin + row * spacing
    }

    var eye = Vec3.new(0, 30, 60)
    var camera = Camera3D.perspective(60, 1.0, 0.1, 200)
    camera.lookAt(eye, Vec3.zero, Vec3.unitY)

    // LOD thresholds: close < 40, mid < 90, beyond is far.
    // Squared form skips a sqrt per cube.
    var t0sq = 40 * 40
    var t1sq = 90 * 90

    // Warmup so JIT lands on the inner loop.
    {
      var planes = camera.frustumPlanes
      var ex = eye.x
      var ey = eye.y
      var ez = eye.z
      var c0 = 0
      var c1 = 0
      var c2 = 0
      var culled = 0
      for (i in 0...n) {
        if (Frustum.sphereVisible(planes, xs[i], ys[i], zs[i], 0.8)) {
          var bucket = Lod.select3(ex, ey, ez, xs[i], ys[i], zs[i], t0sq, t1sq)
          if (bucket == 0) {
            c0 = c0 + 1
          } else if (bucket == 1) {
            c1 = c1 + 1
          } else {
            c2 = c2 + 1
          }
        } else {
          culled = culled + 1
        }
      }
    }

    var runs = 5
    var totalMs = 0
    var close = 0
    var mid = 0
    var far = 0
    var culled = 0
    for (r in 0...runs) {
      var t0 = Clock.mono * 1000
      var planes = camera.frustumPlanes
      var ex = eye.x
      var ey = eye.y
      var ez = eye.z
      close = 0
      mid = 0
      far = 0
      culled = 0
      for (i in 0...n) {
        if (Frustum.sphereVisible(planes, xs[i], ys[i], zs[i], 0.8)) {
          var bucket = Lod.select3(ex, ey, ez, xs[i], ys[i], zs[i], t0sq, t1sq)
          if (bucket == 0) {
            close = close + 1
          } else if (bucket == 1) {
            mid = mid + 1
          } else {
            far = far + 1
          }
        } else {
          culled = culled + 1
        }
      }
      var t1 = Clock.mono * 1000
      totalMs = totalMs + (t1 - t0)
    }

    System.print("[bench] %(n) cubes: %(close) close / %(mid) mid / %(far) far / %(culled) culled (runs=%(runs))")
    System.print("[bench] cull+lod walk mean: %(totalMs / runs) ms")

    Expect.that(close + mid + far + culled).toBe(n)
    Expect.that(close > 0).toBe(true)
    Expect.that(mid > 0).toBe(true)
    Expect.that(culled > 0).toBe(true)
  }
}

Test.run()
