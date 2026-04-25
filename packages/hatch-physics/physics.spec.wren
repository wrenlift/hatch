// @hatch:physics acceptance.
//
// Headless: build a world, drop a dynamic body in gravity, step
// 30 frames at 60 FPS, watch it fall. No window / device / GPU
// dependency — physics stands on its own.

import "./physics"      for World2D, World3D, Collider2D, Collider3D
import "@hatch:test"    for Test
import "@hatch:assert"  for Expect

Test.describe("World2D") {
  Test.it("creates with a custom gravity") {
    var w = World2D.new({"gravity": [0, -5]})
    Expect.that(w is World2D).toBe(true)
    w.destroy
  }

  Test.it("dynamic ball falls under gravity") {
    var w = World2D.new({"gravity": [0, -10]})
    var body = w.spawnDynamic({
      "position": [0, 0],
      "shape":    Collider2D.ball(0.5)
    })
    var p0 = w.position(body)
    Expect.that(p0[1]).toBe(0)

    var dt = 1.0 / 60
    var i = 0
    while (i < 30) {
      w.step(dt)
      i = i + 1
    }
    var p = w.position(body)
    // After 0.5s in 10 m/s² gravity, y ≈ -1.25 m. Allow slack
    // for solver behaviour.
    Expect.that(p[1] < -0.5).toBe(true)
    w.destroy
  }

  Test.it("static ground stops a falling ball") {
    var w = World2D.new({"gravity": [0, -10]})
    w.spawnStatic({
      "position": [0, -5],
      "shape":    Collider2D.box(50, 0.5)
    })
    var ball = w.spawnDynamic({
      "position": [0, 5],
      "shape":    Collider2D.ball(0.5)
    })

    var dt = 1.0 / 60
    var i = 0
    while (i < 120) {
      w.step(dt)
      i = i + 1
    }
    var p = w.position(ball)
    // Ball should have come to rest somewhere on or above the ground.
    Expect.that(p[1] > -6).toBe(true)
    Expect.that(p[1] < 5).toBe(true)
    w.destroy
  }

  Test.it("applyImpulse changes linear velocity") {
    var w = World2D.new({"gravity": [0, 0]})
    var ball = w.spawnDynamic({
      "position": [0, 0],
      "shape":    Collider2D.ball(0.5),
      "mass":     1
    })
    w.applyImpulse(ball, 5, 0)
    w.step(1.0 / 60)
    var v = w.linearVelocity(ball)
    Expect.that(v[0] > 0).toBe(true)
    w.destroy
  }
}

Test.describe("World3D") {
  Test.it("dynamic ball falls along Y axis") {
    var w = World3D.new({"gravity": [0, -9.81, 0]})
    var ball = w.spawnDynamic({
      "position": [0, 0, 0],
      "shape":    Collider3D.ball(0.5)
    })
    var i = 0
    while (i < 30) {
      w.step(1.0 / 60)
      i = i + 1
    }
    var p = w.position(ball)
    Expect.that(p[1] < 0).toBe(true)
    Expect.that(p[0]).toBe(0)
    Expect.that(p[2]).toBe(0)
    w.destroy
  }

  Test.it("box collider accepts halfX/halfY/halfZ") {
    var w = World3D.new()
    var b = w.spawnStatic({
      "position": [0, 0, 0],
      "shape":    Collider3D.box(1, 0.5, 2)
    })
    Expect.that(b > 0).toBe(true)
    w.destroy
  }
}

Test.run()
