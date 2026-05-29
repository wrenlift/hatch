// @hatch:game/particles — CPU-driven particle simulation and
// Renderer2D batch integration.

import "./particles"   for ParticleSystem, Particles
import "@hatch:test"   for Test
import "@hatch:assert" for Expect

// A test "texture" — only `.id` is read by the spec for the
// renderer mock's texture-switch check. The real `Texture` from
// `@hatch:gpu` has the same field.
class MockTexture {
  construct new(id) { _id = id }
  id { _id }
}

// Captures every drawSpriteTinted call so specs can assert
// position / size / color land where expected.
class MockRenderer {
  construct new() { _calls = [] }
  calls { _calls }
  drawSprite(tex, x, y, w, h) {
    _calls.add({
      "tex": tex, "x": x, "y": y, "w": w, "h": h,
      "r": 1, "g": 1, "b": 1, "a": 1
    })
  }
  drawSpriteTinted(tex, x, y, w, h, r, g, b, a) {
    _calls.add({
      "tex": tex, "x": x, "y": y, "w": w, "h": h,
      "r": r, "g": g, "b": b, "a": a
    })
  }
}

Test.describe("ParticleSystem construct") {
  Test.it("requires a texture") {
    Expect.that(Fn.new { ParticleSystem.new({}) }).toAbort()
  }

  Test.it("rejects non-Map opts") {
    Expect.that(Fn.new { ParticleSystem.new("oops") }).toAbort()
  }

  Test.it("defaults are applied for missing keys") {
    var sys = ParticleSystem.new({ "texture": MockTexture.new(1) })
    Expect.that(sys.capacity).toBe(200)
    Expect.that(sys.liveCount).toBe(0)
    Expect.that(sys.playing).toBe(true)
  }

  Test.it("playing=false disables auto-emission") {
    var sys = ParticleSystem.new({
      "texture": MockTexture.new(1),
      "playing": false,
      "emissionRate": 1000
    })
    sys.update(0.1)
    Expect.that(sys.liveCount).toBe(0)
  }
}

Test.describe("ParticleSystem.burst") {
  Test.it("spawns up to N particles") {
    var sys = ParticleSystem.new({
      "texture": MockTexture.new(1),
      "capacity": 10,
      "playing": false,
      "lifetime": [10, 10]
    })
    var spawned = sys.burst(5)
    Expect.that(spawned).toBe(5)
    sys.update(0.001)
    Expect.that(sys.liveCount).toBe(5)
  }

  Test.it("caps at remaining capacity") {
    var sys = ParticleSystem.new({
      "texture": MockTexture.new(1),
      "capacity": 3,
      "playing": false,
      "lifetime": [10, 10]
    })
    var spawned = sys.burst(99)
    Expect.that(spawned).toBe(3)
  }
}

Test.describe("ParticleSystem.update") {
  Test.it("ages and kills particles after lifetime expires") {
    var sys = ParticleSystem.new({
      "texture":  MockTexture.new(1),
      "capacity": 5,
      "playing":  false,
      "lifetime": [0.5, 0.5]
    })
    sys.burst(3)
    sys.update(0.01)
    Expect.that(sys.liveCount).toBe(3)
    // Drain past the lifetime — all particles should die.
    sys.update(1.0)
    Expect.that(sys.liveCount).toBe(0)
  }

  Test.it("auto-emitter respects emissionRate") {
    var sys = ParticleSystem.new({
      "texture":      MockTexture.new(1),
      "capacity":     100,
      "emissionRate": 10,     // 10/sec
      "lifetime":     [10, 10] // long enough that nothing dies
    })
    sys.update(1.0)
    // Allow ±1 slack for accumulator rounding at the second
    // boundary — emission accumulator may queue ten or nine new
    // ones depending on the order ops fall out of the loop.
    var n = sys.liveCount
    Expect.that(n >= 9 && n <= 11).toBe(true)
  }

  Test.it("integrates gravity into velocity") {
    var sys = ParticleSystem.new({
      "texture":  MockTexture.new(1),
      "capacity": 1,
      "playing":  false,
      "lifetime": [10, 10],
      "position": [0, 0],
      "velocity": [[0, 0], [0, 0]],
      "gravity":  [0, 100]
    })
    sys.burst(1)
    sys.update(1.0)
    var r = MockRenderer.new()
    sys.draw(r)
    // Semi-implicit Euler: velocity is updated *before* the
    // position integration each step, so after a 1.0s tick with
    // g=100 from rest the result is v=100, then y = 0 + v*dt = 100
    // (not the kinematic 0.5*g*t² = 50). Centered draw subtracts
    // half the default size: 100 - 8/2 = 96.
    Expect.that(r.calls.count).toBe(1)
    Expect.that(r.calls[0]["y"]).toBe(96)
  }

  Test.it("stop() halts emission but lets existing particles tick") {
    var sys = ParticleSystem.new({
      "texture":      MockTexture.new(1),
      "capacity":     50,
      "emissionRate": 50,
      "lifetime":     [10, 10]
    })
    sys.update(0.2)             // ~10 alive
    var before = sys.liveCount
    Expect.that(before > 0).toBe(true)
    sys.stop
    sys.update(0.2)             // no new emissions
    Expect.that(sys.liveCount).toBe(before)
    sys.start
    sys.update(0.2)             // emissions resume
    Expect.that(sys.liveCount > before).toBe(true)
  }
}

Test.describe("ParticleSystem.draw") {
  Test.it("queues one drawSpriteTinted per live particle") {
    var sys = ParticleSystem.new({
      "texture":  MockTexture.new(7),
      "capacity": 10,
      "playing":  false,
      "lifetime": [10, 10]
    })
    sys.burst(4)
    sys.update(0.001)
    var r = MockRenderer.new()
    sys.draw(r)
    Expect.that(r.calls.count).toBe(4)
    Expect.that(r.calls[0]["tex"].id).toBe(7)
  }

  Test.it("interpolates color over particle lifetime") {
    var sys = ParticleSystem.new({
      "texture":  MockTexture.new(1),
      "capacity": 1,
      "playing":  false,
      "lifetime": [1.0, 1.0],
      "color":    [[1, 1, 1, 1], [0, 0, 0, 0]]
    })
    sys.burst(1)

    // Start state.
    sys.update(0.001)
    var r0 = MockRenderer.new()
    sys.draw(r0)
    Expect.that(r0.calls[0]["a"] > 0.99).toBe(true)

    // Halfway through life.
    sys.update(0.5)
    var r1 = MockRenderer.new()
    sys.draw(r1)
    var halfA = r1.calls[0]["a"]
    Expect.that(halfA > 0.4 && halfA < 0.6).toBe(true)
  }

  Test.it("dead particles are skipped") {
    var sys = ParticleSystem.new({
      "texture":  MockTexture.new(1),
      "capacity": 5,
      "playing":  false,
      "lifetime": [0.1, 0.1]
    })
    sys.burst(5)
    sys.update(0.05)
    var r0 = MockRenderer.new()
    sys.draw(r0)
    Expect.that(r0.calls.count).toBe(5)
    sys.update(1.0)
    var r1 = MockRenderer.new()
    sys.draw(r1)
    Expect.that(r1.calls.count).toBe(0)
  }
}

Test.describe("Particles registry") {
  Test.it("registered system gets ticked by Particles.update") {
    Particles.clear()
    var sys = ParticleSystem.new({
      "texture":      MockTexture.new(1),
      "capacity":     10,
      "emissionRate": 100,
      "lifetime":     [10, 10]
    })
    Particles.register(sys)
    Expect.that(Particles.count).toBe(1)
    Particles.update(0.1)
    Expect.that(sys.liveCount > 0).toBe(true)
    Particles.clear()
  }

  Test.it("register is idempotent") {
    Particles.clear()
    var sys = ParticleSystem.new({ "texture": MockTexture.new(1) })
    Particles.register(sys)
    Particles.register(sys)
    Expect.that(Particles.count).toBe(1)
    Particles.clear()
  }

  Test.it("unregister stops ticking") {
    Particles.clear()
    var sys = ParticleSystem.new({
      "texture":      MockTexture.new(1),
      "capacity":     10,
      "emissionRate": 50,
      "lifetime":     [10, 10]
    })
    Particles.register(sys)
    Particles.update(0.1)
    var before = sys.liveCount
    Particles.unregister(sys)
    Particles.update(0.1)
    Expect.that(sys.liveCount).toBe(before)
    Particles.clear()
  }

  Test.it("rejects non-ParticleSystem") {
    Expect.that(Fn.new { Particles.register("oops") }).toAbort()
  }
}

Test.run()
