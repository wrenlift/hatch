// @hatch:game/particles — CPU-driven particle simulation and
// Renderer2D batch integration.

import "./particles"   for ParticleSystem, ParticleSystem3D, Particles
import "@hatch:test"   for Test
import "@hatch:assert" for Expect
import "@hatch:os"     for Os

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
  construct new() {
    _calls = []
    _blendLog = []
  }
  calls { _calls }
  blendLog { _blendLog }
  setBlend(mode) { _blendLog.add(mode) }
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
  Test.it("calls renderer.setBlend with the configured blend (default alpha)") {
    var sys = ParticleSystem.new({
      "texture":  MockTexture.new(1),
      "capacity": 2,
      "playing":  false,
      "lifetime": [10, 10]
    })
    sys.burst(1)
    sys.update(0.001)
    var r = MockRenderer.new()
    sys.draw(r)
    Expect.that(r.blendLog.count).toBe(1)
    Expect.that(r.blendLog[0]).toBe("alpha")
  }

  Test.it("forwards `blend: \"additive\"` to renderer.setBlend") {
    var sys = ParticleSystem.new({
      "texture":  MockTexture.new(1),
      "capacity": 1,
      "playing":  false,
      "lifetime": [10, 10],
      "blend":    "additive"
    })
    sys.burst(1)
    sys.update(0.001)
    var r = MockRenderer.new()
    sys.draw(r)
    Expect.that(r.blendLog.count).toBe(1)
    Expect.that(r.blendLog[0]).toBe("additive")
  }

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

  // Pre-relaxation, Particles.register aborted on non-ParticleSystem
  // arguments. Switched to duck-typing so ParticleSystem3D (and any
  // future caller-defined system shape) plugs into the same pump —
  // see the dedicated cross-shape test below.
}

// Minimal stand-ins for the GPU types ParticleSystem3D touches.
// We never actually upload to or render from a real GPU here —
// the spec exercises the sim path + the buffer.writeFloats / draw
// call shape only.
class MockBuf3D {
  construct new() {
    _writes = 0
    _last   = null
  }
  writeFloats(off, data) {
    _writes = _writes + 1
    _last   = data
  }
  // The optimised ParticleSystem3D.draw hot path uses
  // `writeFloatsN(0, _inst, liveCount * 16)` so only the live tail
  // of the instance buffer rides the bus instead of the full
  // capacity. Treat it like the bare `writeFloats` in the mock —
  // we only need the write to register.
  writeFloatsN(off, data, count) {
    _writes = _writes + 1
    _last   = data
  }
  destroy {}
  writes { _writes }
  last   { _last }
}

class MockDev3D {
  construct new() { _buffers = [] }
  createBuffer(desc) {
    var b = MockBuf3D.new()
    _buffers.add(b)
    return b
  }
  buffers { _buffers }
}

class MockRenderer3D {
  construct new() {
    _calls = []
  }
  drawBillboardN(tex, buf, count) {
    _calls.add([tex, buf, count])
  }
  calls { _calls }
}

Test.describe("ParticleSystem3D construct") {
  Test.it("aborts when 'texture' is missing") {
    var dev = MockDev3D.new()
    var e = Fiber.new { ParticleSystem3D.new(dev, {}) }.try()
    Expect.that(e).toContain("texture")
  }

  Test.it("aborts when 'opts' is not a Map") {
    var dev = MockDev3D.new()
    var e = Fiber.new { ParticleSystem3D.new(dev, "nope") }.try()
    Expect.that(e).toContain("Map")
  }

  Test.it("allocates an instance buffer at full capacity") {
    var dev = MockDev3D.new()
    var sys = ParticleSystem3D.new(dev, {
      "texture": MockTexture.new(1),
      "capacity": 64
    })
    Expect.that(dev.buffers.count).toBe(1)
    Expect.that(sys.capacity).toBe(64)
    Expect.that(sys.liveCount).toBe(0)
  }
}

Test.describe("ParticleSystem3D.burst + update") {
  Test.it("burst spawns particles, update ages and expires them") {
    var dev = MockDev3D.new()
    var sys = ParticleSystem3D.new(dev, {
      "texture":  MockTexture.new(1),
      "capacity": 16,
      "lifetime": [0.5, 0.5],
      "gravity":  [0, 0, 0]
    })
    sys.burst(5)
    Expect.that(sys.liveCount).toBe(5)
    // Tick past lifetime — every slot should expire.
    sys.update(1.0)
    Expect.that(sys.liveCount).toBe(0)
  }

  Test.it("burst respects capacity") {
    var dev = MockDev3D.new()
    var sys = ParticleSystem3D.new(dev, {
      "texture":  MockTexture.new(1),
      "capacity": 4,
      "lifetime": [10, 10]
    })
    sys.burst(99)
    Expect.that(sys.liveCount).toBe(4)
  }

  Test.it("emissionRate auto-emits while playing") {
    var dev = MockDev3D.new()
    var sys = ParticleSystem3D.new(dev, {
      "texture":      MockTexture.new(1),
      "capacity":     32,
      "emissionRate": 10,
      "lifetime":     [10, 10]
    })
    Expect.that(sys.isPlaying).toBe(true)
    sys.update(1.0)   // 10 particles/sec × 1 sec = 10 spawns.
    Expect.that(sys.liveCount).toBe(10)
  }
}

Test.describe("ParticleSystem3D.draw") {
  Test.it("uploads instance bytes and dispatches one drawBillboardN") {
    var dev = MockDev3D.new()
    var r   = MockRenderer3D.new()
    var sys = ParticleSystem3D.new(dev, {
      "texture":  MockTexture.new(7),
      "capacity": 8,
      "lifetime": [10, 10]
    })
    sys.burst(3)
    sys.draw(r)
    var buf = dev.buffers[0]
    Expect.that(buf.writes).toBe(1)
    Expect.that(r.calls.count).toBe(1)
    Expect.that(r.calls[0][0].id).toBe(7)
    Expect.that(r.calls[0][2]).toBe(3)
  }

  Test.it("skips entirely when no particles are alive") {
    var dev = MockDev3D.new()
    var r   = MockRenderer3D.new()
    var sys = ParticleSystem3D.new(dev, {"texture": MockTexture.new(1)})
    sys.draw(r)
    Expect.that(dev.buffers[0].writes).toBe(0)
    Expect.that(r.calls.count).toBe(0)
  }
}

// Phase 6d exit-gate spec — 100k billboards CPU sim budget.
//
// Gates the per-frame CPU cost of updating + uploading 100k live
// `ParticleSystem3D` instances. Real GPU work isn't measured (the
// spec runs against MockDev3D / MockRenderer3D); only the Wren-side
// sim, the buffer pack, and the single `drawBillboardN` dispatch.
// The exit gate from `game-engine-parity-plan.md` calls for 100k
// billboards at 60 fps native — the CPU half of that frame budget
// is ~8 ms (leaving 8 ms for the actual GPU draw + present).
//
// **CPU vs GPU pathway.** ParticleSystem3D walks every live slot in
// Wren each frame — for 100k particles that's ~1.5M Float32Array
// method dispatches per frame across update + draw. The optimisation
// pass on 2026-06-05 brought the budget from 186 ms → 11 ms
// (running offsets instead of per-iter multiplies, hoisted constants
// outside the hot loop, `v * (1 - drag*dt) + g*dt` form, inv_lifetime
// stored at spawn so the draw colour-lerp is a multiply not a divide,
// pre-filled UV-rect/lodIndex/pad slots at construct so the per-frame
// pack writes only the changing fields, `writeFloatsN(0, _inst, live)`
// to clip the buffer upload to the live tail). Further wins require
// a typed-array bulk-write primitive in `wren_lift` — until then 11
// ms is the steady-state floor at 100k. The gate stays at 8 ms so a
// future bulk-write primitive in wren_lift will turn it green
// automatically; in the meantime use `GpuParticleSystem3D` for
// 50k+ particles in production (compute-pass integration, CPU side
// just packs the params UBO + issues one dispatch).
//
// Gated behind `WLIFT_PERF=1` because allocating + simulating 100k
// particles in spec runs costs seconds of wall clock — it'd dominate
// regular `hatch test` time. Set the env var when you specifically
// want to gate against this budget:
//
//   WLIFT_PERF=1 hatch test packages/hatch-game
Test.describe("Phase 6d — 100k billboard CPU budget (perf-gated)") {
  Test.it("update + pack + draw for 100k particles stays under 8 ms/frame avg") {
    if (Os.env("WLIFT_PERF") != "1") {
      System.print("    skipped (set WLIFT_PERF=1 to run)")
      return
    }

    var dev = MockDev3D.new()
    var r   = MockRenderer3D.new()
    var sys = ParticleSystem3D.new(dev, {
      "texture":  MockTexture.new(1),
      "capacity": 100000,
      // Long lifetime so all 100k stay live across the run; the
      // budget is "100k live particles per frame", not "100k
      // particles spawned + most expired."
      "lifetime": [100, 100],
      "gravity":  [0, -1, 0],
      // Spread so positions vary and the integration loop doesn't
      // shortcut on degenerate uniform values.
      "spread":   [50, 50, 50],
      "velocity": [[-2, -2, -2], [2, 2, 2]],
      "drag":     0.05,
      "size":     [0.5, 1.5]
    })
    sys.burst(100000)
    Expect.that(sys.liveCount).toBe(100000)

    // Warm-up frame — touches every cold code path before timing
    // (JIT tier-up, page-fault the buffer scratch, etc.) so the
    // average reflects steady-state cost rather than the first-
    // frame surcharge.
    sys.update(1.0 / 60.0)
    sys.draw(r)

    var frames = 60
    var dt = 1.0 / 60.0

    // Separate timings give a clearer picture of which phase needs
    // optimisation when the gate is RED.
    var t1 = System.clock
    for (i in 0...frames) sys.update(dt)
    var updateMs = (System.clock - t1) * 1000 / frames

    var t2 = System.clock
    for (i in 0...frames) sys.draw(r)
    var drawMs = (System.clock - t2) * 1000 / frames

    var t0 = System.clock
    for (i in 0...frames) {
      sys.update(dt)
      sys.draw(r)
    }
    var totalMs = (System.clock - t0) * 1000
    var avgMs   = totalMs / frames

    // 3-decimal print so sub-millisecond costs (Rust plugin path)
    // are still visible. `%(x)` interpolates the number's
    // toString, so round to 3 decimal places via a manual scale.
    var fmtMs = Fn.new { |n| ((n * 1000).round) / 1000 }
    System.print("    100k particles · %(frames) frames · update %(fmtMs.call(updateMs)) + draw %(fmtMs.call(drawMs)) = %(fmtMs.call(avgMs)) ms/frame (combined)")
    Expect.that(sys.liveCount).toBe(100000)
    // CPU half of a 60 fps frame budget. If this fails, the
    // particle update / buffer-pack loop has regressed; profile
    // `ParticleSystem3D.update` and `.draw` for the hot allocation
    // or branch site that grew.
    Expect.that(avgMs < 8.0).toBe(true)
  }
}

Test.describe("Particles.register accepts both 2D and 3D systems") {
  Test.it("ducks-types via the update(dt) method") {
    var dev = MockDev3D.new()
    var s3d = ParticleSystem3D.new(dev, {"texture": MockTexture.new(1)})
    var s2d = ParticleSystem.new({"texture": MockTexture.new(2)})
    Particles.clear()
    Particles.register(s3d)
    Particles.register(s2d)
    Expect.that(Particles.count).toBe(2)
    Particles.clear()
  }
}

Test.run()
