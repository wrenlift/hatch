// @hatch:game/weather acceptance tests. Wind sampling
// determinism, base-direction contribution, gust decorrelation,
// and the in-place apply helper.

import "./weather"    for Wind, Weather
import "@hatch:test"   for Test
import "@hatch:assert" for Expect

// GPU stand-ins. Weather.rain / Weather.snow only need
// device.createBuffer + a Texture-shaped opaque so they can
// hand them to ParticleSystem3D.
class MockBuf {
  construct new() {}
  writeFloats(off, data) {}
  destroy {}
}
class MockDev {
  construct new() {}
  createBuffer(desc) { MockBuf.new() }
}
class MockTex {
  construct new(id) { _id = id }
  id { _id }
}

Test.describe("Wind.sample") {
  Test.it("is deterministic in (opts, x, y, z, t)") {
    var opts = { "baseX": 1, "gust": 0.5, "scale": 0.1, "seed": 1 }
    var a = Wind.sample(opts, 2.5, 0, 1.5, 10.0)
    var b = Wind.sample(opts, 2.5, 0, 1.5, 10.0)
    Expect.that(a[0]).toBe(b[0])
    Expect.that(a[1]).toBe(b[1])
    Expect.that(a[2]).toBe(b[2])
  }

  Test.it("zero gust reduces to the base direction × baseStrength") {
    var opts = {
      "baseX": 2, "baseY": 0, "baseZ": 1,
      "baseStrength": 3,
      "gust": 0
    }
    var w = Wind.sample(opts, 100, 0, 50, 0)
    Expect.that(w[0]).toBe(6)
    Expect.that(w[1]).toBe(0)
    Expect.that(w[2]).toBe(3)
  }

  Test.it("evolves over time when timeScale > 0") {
    var opts = { "gust": 1, "scale": 0.05, "timeScale": 0.5, "seed": 7 }
    var a = Wind.sample(opts, 0, 0, 0, 0)
    var b = Wind.sample(opts, 0, 0, 0, 5)
    // At least one component should differ once the noise field
    // has scrubbed forward — the field is band-limited so equal
    // returns are mathematically possible but vanishingly unlikely.
    Expect.that(a[0] == b[0] && a[1] == b[1] && a[2] == b[2]).toBe(false)
  }

  Test.it("decorrelates the three turbulence channels") {
    // Sampling at the origin with timeScale = 0 and identical
    // offsets would yield (n, n, n) if the three components used
    // the same simplex call. They don't — the (x, y, z) offsets
    // in the noise space differ.
    var opts = { "baseStrength": 0, "gust": 1, "scale": 0.1, "seed": 13 }
    var w = Wind.sample(opts, 0, 0, 0, 0)
    Expect.that(w[0] == w[1] && w[1] == w[2]).toBe(false)
  }

  Test.it("different seeds produce different fields at the same point") {
    var a = Wind.sample({ "baseStrength": 0, "gust": 1, "seed": 1 }, 0, 0, 0, 0)
    var b = Wind.sample({ "baseStrength": 0, "gust": 1, "seed": 9999 }, 0, 0, 0, 0)
    Expect.that(a[0] == b[0]).toBe(false)
  }
}

Test.describe("Wind.apply") {
  Test.it("integrates the wind vector × dt into the velocity in place") {
    var opts = { "baseX": 1, "baseStrength": 4, "gust": 0 }
    var v = [0, 0, 0]
    Wind.apply(opts, 0, 0, 0, 0, 0.5, v)
    // Base wind = (4, 0, 0), dt = 0.5 → +2 on vx.
    Expect.that(v[0]).toBe(2)
    Expect.that(v[1]).toBe(0)
    Expect.that(v[2]).toBe(0)
    // A second tick accumulates.
    Wind.apply(opts, 0, 0, 0, 0, 0.5, v)
    Expect.that(v[0]).toBe(4)
  }

  Test.it("returns the same List it mutated, for chaining") {
    var v = [1, 2, 3]
    var returned = Wind.apply({ "baseStrength": 0, "gust": 0 }, 0, 0, 0, 0, 1, v)
    Expect.that(returned == v).toBe(true)
  }
}

Test.describe("Weather.rain") {
  Test.it("aborts when opts.texture is missing") {
    var dev = MockDev.new()
    var e = Fiber.new { Weather.rain(dev, {}) }.try()
    Expect.that(e).toContain("texture")
  }

  Test.it("builds a ParticleSystem3D at the requested capacity") {
    var dev = MockDev.new()
    var sys = Weather.rain(dev, {
      "texture":  MockTex.new(1),
      "capacity": 256
    })
    Expect.that(sys.capacity).toBe(256)
    Expect.that(sys.isPlaying).toBe(true)
  }
}

Test.describe("Weather.snow") {
  Test.it("uses larger default capacity than rain") {
    var dev = MockDev.new()
    var rain = Weather.rain(dev, {"texture": MockTex.new(1)})
    var snow = Weather.snow(dev, {"texture": MockTex.new(2)})
    Expect.that(snow.capacity > rain.capacity).toBe(true)
  }

  Test.it("opts.intensity is honoured") {
    var dev = MockDev.new()
    var sys = Weather.snow(dev, {
      "texture":   MockTex.new(1),
      "intensity": 1
    })
    Expect.that(sys.liveCount).toBe(0)
    sys.update(1.0)
    // emissionRate = 1 → one spawn per second.
    Expect.that(sys.liveCount).toBe(1)
  }
}

Test.describe("Weather.fog") {
  Test.it("returns a Fog with overridden density / colour") {
    var fog = Weather.fog({
      "density": 0.05,
      "color":   [0.5, 0.6, 0.7]
    })
    Expect.that(fog.density).toBe(0.05)
    Expect.that(fog.color[0]).toBe(0.5)
  }

  Test.it("opts == null falls back to plain Fog defaults") {
    var fog = Weather.fog(null)
    // Default density per fog.wren is 0.020.
    Expect.that(fog.density).toBe(0.020)
  }
}

Test.run()
