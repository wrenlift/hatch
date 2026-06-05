// @hatch:game/gpu_particles — wind field + curl-noise uniforms +
// 1M-particle exit-gate gate.

import "./gpu_particles" for GpuParticleSystem3D
import "@hatch:test"     for Test
import "@hatch:assert"   for Expect
import "@hatch:os"       for Os

// Captures the last `writeFloats` payload so spec cases can assert
// the params UBO layout (wind direction / strength / noise slots).
class MockBuf {
  construct new() {
    _writes = 0
    _lastWriteFloats   = null
    _lastWriteFloatsN  = null
  }
  writeFloats(off, data) {
    _writes = _writes + 1
    _lastWriteFloats = []
    for (v in data) _lastWriteFloats.add(v)
  }
  writeFloatsN(off, data, count) {
    _lastWriteFloatsN = count
  }
  destroy {}
  writes { _writes }
  lastWriteFloats  { _lastWriteFloats }
  lastWriteFloatsN { _lastWriteFloatsN }
}

class MockShader {
  construct new() {}
}

class MockBindGroupLayout {
  construct new() {}
}

class MockPipelineLayout {
  construct new() {}
}

class MockComputePipeline {
  construct new() {}
}

class MockBindGroup {
  construct new() {}
}

class MockComputePass {
  construct new() {
    _pipeline = null
    _bg       = null
    _groups   = 0
    _ended    = false
  }
  setPipeline(p)    { _pipeline = p }
  setBindGroup(s, b) { _bg = b }
  dispatchWorkgroups(g) { _groups = g }
  end {
    _ended = true
  }
  groups   { _groups }
  ended    { _ended }
}

class MockEncoder {
  construct new() { _pass = null }
  beginComputePass() {
    var p = MockComputePass.new()
    _pass = p
    return p
  }
  pass { _pass }
}

class MockDev {
  construct new() { _params = null }
  createBuffer(desc) {
    var b = MockBuf.new()
    // Track the params UBO specifically by its label so we can
    // assert it received the right layout — the state + render
    // buffers also pass through this same constructor.
    if (desc["label"] == "gpu-particles3d-params") _params = b
    return b
  }
  createShaderModule(desc) { MockShader.new() }
  createBindGroupLayout(desc) { MockBindGroupLayout.new() }
  createPipelineLayout(desc)  { MockPipelineLayout.new() }
  createComputePipeline(desc) { MockComputePipeline.new() }
  createBindGroup(desc)       { MockBindGroup.new() }
  paramsBuf { _params }
}

class MockTex {
  construct new(id) { _id = id }
  id { _id }
}

Test.describe("GpuParticleSystem3D construct") {
  Test.it("defaults wind strength to 0 (no force applied)") {
    var dev = MockDev.new()
    var sys = GpuParticleSystem3D.new(dev, {
      "texture":  MockTex.new(1),
      "capacity": 64
    })
    var enc = MockEncoder.new()
    sys.compute(enc)
    var p = dev.paramsBuf.lastWriteFloats
    Expect.that(p.count).toBe(28)
    // wind_dir_strength at slots 20-23.
    Expect.that(p[23]).toBe(0)
    // wind_noise.amplitude at slot 26.
    Expect.that(p[26]).toBe(0)
  }

  Test.it("accepts wind / windNoise opts") {
    var dev = MockDev.new()
    var sys = GpuParticleSystem3D.new(dev, {
      "texture":      MockTex.new(1),
      "capacity":     16,
      "wind":         [1.5, 0, -0.5],
      "windStrength": 3.0,
      "windNoise": {
        "scale":     0.25,
        "timeScale": 0.5,
        "amplitude": 1.0,
        "align":     0.5
      }
    })
    var enc = MockEncoder.new()
    sys.compute(enc)
    var p = dev.paramsBuf.lastWriteFloats
    Expect.that(p[20]).toBe(1.5)
    Expect.that(p[22]).toBe(-0.5)
    Expect.that(p[23]).toBe(3.0)
    Expect.that(p[24]).toBe(0.25)
    Expect.that(p[25]).toBe(0.5)
    Expect.that(p[26]).toBe(1.0)
    Expect.that(p[27]).toBe(0.5)
  }
}

Test.describe("GpuParticleSystem3D.setWind / setWindNoise") {
  Test.it("setWind writes the four uniform slots in the params UBO") {
    var dev = MockDev.new()
    var sys = GpuParticleSystem3D.new(dev, {
      "texture":  MockTex.new(1),
      "capacity": 16
    })
    sys.setWind(0.5, 0, -0.25, 2.5)
    var enc = MockEncoder.new()
    sys.compute(enc)
    // Exact powers-of-two round-trip through f32 cleanly; uneven
    // decimals would surface FP precision noise.
    var p = dev.paramsBuf.lastWriteFloats
    Expect.that(p[20]).toBe(0.5)
    Expect.that(p[21]).toBe(0)
    Expect.that(p[22]).toBe(-0.25)
    Expect.that(p[23]).toBe(2.5)
  }

  Test.it("setWindNoise writes the curl-noise vec4 slot") {
    var dev = MockDev.new()
    var sys = GpuParticleSystem3D.new(dev, {
      "texture":  MockTex.new(1),
      "capacity": 16
    })
    sys.setWindNoise(0.5, 1.25, 0.5, 0.25)
    var enc = MockEncoder.new()
    sys.compute(enc)
    // Exact powers-of-two round-trip through f32 without precision
    // loss, which keeps the assertion simple.
    var p = dev.paramsBuf.lastWriteFloats
    Expect.that(p[24]).toBe(0.5)
    Expect.that(p[25]).toBe(1.25)
    Expect.that(p[26]).toBe(0.5)
    Expect.that(p[27]).toBe(0.25)
  }
}

// Phase 6e exit-gate — 1M-particle dispatch + params upload budget.
//
// GpuParticleSystem3D pushes per-particle integration onto the GPU
// (the compute pass at COMPUTE_WGSL_). CPU side per frame just:
// (a) advances the emission accumulator + (optionally) seeds a few
// fresh particle states, (b) packs a 28-float params UBO, (c) issues
// one dispatchWorkgroups. The CPU per-frame budget for that work
// should be well under 1 ms at 1M-particle capacity — the spec
// measures the steady-state cost (no spawning, no rendering)
// across 60 frames.
//
// Gated behind WLIFT_PERF=1 because the 1M-state-buffer allocation
// in the mock takes a few hundred ms even with no real GPU work.
Test.describe("Phase 6e — 1M particle CPU dispatch budget (perf-gated)") {
  Test.it("update + compute dispatch CPU cost stays under 1 ms/frame avg") {
    if (Os.env("WLIFT_PERF") != "1") {
      System.print("    skipped (set WLIFT_PERF=1 to run)")
      return
    }
    var dev = MockDev.new()
    var sys = GpuParticleSystem3D.new(dev, {
      "texture":      MockTex.new(1),
      "capacity":     1000000,
      "emissionRate": 0,
      "wind":         [1, 0, 0],
      "windStrength": 1.0,
      "windNoise": {
        "scale":     0.10,
        "timeScale": 0.50,
        "amplitude": 0.5,
        "align":     0.20
      }
    })

    // Warm-up.
    var enc0 = MockEncoder.new()
    sys.update(1.0 / 60.0)
    sys.compute(enc0)

    var frames = 60
    var dt = 1.0 / 60.0
    var t0 = System.clock
    for (i in 0...frames) {
      sys.update(dt)
      var enc = MockEncoder.new()
      sys.compute(enc)
    }
    var totalMs = (System.clock - t0) * 1000
    var avgMs   = totalMs / frames
    System.print("    1M particles · %(frames) frames · total %(totalMs.round) ms · avg %(avgMs.round) ms/frame (CPU)")
    Expect.that(avgMs < 1.0).toBe(true)
  }
}

Test.run()
