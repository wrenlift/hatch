// @hatch:game/foliage acceptance tests. Determinism, bounds
// validation, jitter clamping, and the density-threshold filter.

import "./foliage"    for Foliage
import "@hatch:test"   for Test
import "@hatch:assert" for Expect

Test.describe("Foliage.scatter input guards") {
  Test.it("aborts when bounds are missing") {
    var e = Fiber.new {
      Foliage.scatter({ "spacing": 1 })
    }.try()
    Expect.that(e).toContain("bounds")
  }

  Test.it("aborts on inverted bounds") {
    var e = Fiber.new {
      Foliage.scatter({ "bounds": [10, 0, 0, 10] })
    }.try()
    Expect.that(e).toContain("max must exceed min")
  }

  Test.it("aborts on non-positive spacing") {
    var e = Fiber.new {
      Foliage.scatter({ "bounds": [0, 0, 10, 10], "spacing": 0 })
    }.try()
    Expect.that(e).toContain("spacing")
  }
}

Test.describe("Foliage.scatter coverage + determinism") {
  Test.it("emits exactly one candidate per grid cell when no threshold is set") {
    var r = Foliage.scatter({
      "bounds":  [0, 0, 10, 10],
      "spacing": 1,
      "jitter":  0
    })
    // 10×10 grid → 100 cells. Without a threshold every cell
    // contributes.
    Expect.that(r["count"]).toBe(100)
  }

  Test.it("places candidates inside bounds when jitter is zero") {
    var r = Foliage.scatter({
      "bounds":  [0, 0, 4, 4],
      "spacing": 1,
      "jitter":  0
    })
    for (i in 0...r["count"]) {
      var x = r["xs"][i]
      var z = r["zs"][i]
      Expect.that(x >= 0 && x <= 4).toBe(true)
      Expect.that(z >= 0 && z <= 4).toBe(true)
    }
  }

  Test.it("is deterministic in (opts, seed)") {
    var opts = { "bounds": [0, 0, 8, 8], "spacing": 1, "jitter": 0.4, "seed": 1337 }
    var a = Foliage.scatter(opts)
    var b = Foliage.scatter(opts)
    Expect.that(a["count"]).toBe(b["count"])
    for (i in 0...a["count"]) {
      Expect.that(a["xs"][i]).toBe(b["xs"][i])
      Expect.that(a["zs"][i]).toBe(b["zs"][i])
    }
  }

  Test.it("different seeds produce different placements") {
    var base = { "bounds": [0, 0, 8, 8], "spacing": 1, "jitter": 0.4 }
    base["seed"] = 1
    var a = Foliage.scatter(base)
    base["seed"] = 9999
    var b = Foliage.scatter(base)
    Expect.that(a["xs"][0] == b["xs"][0]).toBe(false)
  }
}

Test.describe("Foliage.scatter threshold") {
  Test.it("an always-zero threshold drops every candidate") {
    var r = Foliage.scatter({
      "bounds":  [0, 0, 8, 8],
      "spacing": 1,
      "threshold": Fn.new {|x, z| 0 }
    })
    Expect.that(r["count"]).toBe(0)
  }

  Test.it("an always-one threshold keeps every candidate") {
    var r = Foliage.scatter({
      "bounds":  [0, 0, 8, 8],
      "spacing": 1,
      "threshold": Fn.new {|x, z| 1 }
    })
    Expect.that(r["count"]).toBe(64)
  }

  Test.it("density gradient modulates coverage") {
    // Density = x / 8: linear ramp 0..1 across the bounds. Higher
    // x → more accepted candidates. Verify the right half wins.
    var r = Foliage.scatter({
      "bounds":  [0, 0, 8, 8],
      "spacing": 1,
      "seed":    42,
      "threshold": Fn.new {|x, z| x / 8 }
    })
    var leftCount = 0
    var rightCount = 0
    for (i in 0...r["count"]) {
      var x = r["xs"][i]
      if (x < 4) {
        leftCount = leftCount + 1
      } else {
        rightCount = rightCount + 1
      }
    }
    Expect.that(rightCount > leftCount).toBe(true)
  }
}

Test.describe("Foliage.scatter scale") {
  Test.it("walks a 256-cell grid without bogging") {
    var r = Foliage.scatter({
      "bounds":  [0, 0, 32, 32],
      "spacing": 2,
      "jitter":  0.5,
      "seed":    1
    })
    Expect.that(r["count"]).toBe(256)
  }
}

Test.describe("Foliage.poisson") {
  Test.it("returns points all at least r apart") {
    var out = Foliage.poisson({
      "bounds": [0, 0, 50, 50],
      "r":      4,
      "seed":   1234
    })
    Expect.that(out["count"] > 5).toBe(true)
    var n = out["count"]
    var xs = out["xs"]
    var zs = out["zs"]
    var minSq = 4 * 4
    var ok = true
    var i = 0
    while (i < n && ok) {
      var j = i + 1
      while (j < n && ok) {
        var dx = xs[i] - xs[j]
        var dz = zs[i] - zs[j]
        if (dx * dx + dz * dz < minSq - 0.0001) ok = false
        j = j + 1
      }
      i = i + 1
    }
    Expect.that(ok).toBe(true)
  }

  Test.it("deterministic for the same seed") {
    var a = Foliage.poisson({"bounds": [0, 0, 20, 20], "r": 2, "seed": 42})
    var b = Foliage.poisson({"bounds": [0, 0, 20, 20], "r": 2, "seed": 42})
    Expect.that(a["count"]).toBe(b["count"])
    var i = 0
    while (i < a["count"]) {
      Expect.that(a["xs"][i]).toBe(b["xs"][i])
      Expect.that(a["zs"][i]).toBe(b["zs"][i])
      i = i + 1
    }
  }

  Test.it("aborts on missing required options") {
    var e1 = Fiber.new { Foliage.poisson({"r": 2}) }.try()
    Expect.that(e1).toContain("bounds")
    var e2 = Fiber.new { Foliage.poisson({"bounds": [0, 0, 10, 10]}) }.try()
    Expect.that(e2).toContain("opts.r")
  }
}

Test.describe("Foliage.fromHeightmap") {
  Test.it("drops samples outside the slope window") {
    var hm = Float32Array.new(16 * 16)
    var out = Foliage.fromHeightmap({
      "bounds":    [0, 0, 50, 50],
      "r":         3,
      "heightmap": hm,
      "width":     16,
      "height":    16,
      "worldSize": [50, 50],
      "slopeMin":  0.1
    })
    Expect.that(out["count"]).toBe(0)
  }

  Test.it("keeps samples on a gradient heightmap") {
    var hm = Float32Array.new(16 * 16)
    var j = 0
    while (j < 16) {
      var i = 0
      while (i < 16) {
        hm[j * 16 + i] = i * 0.5
        i = i + 1
      }
      j = j + 1
    }
    var out = Foliage.fromHeightmap({
      "bounds":    [0, 0, 50, 50],
      "r":         5,
      "heightmap": hm,
      "width":     16,
      "height":    16,
      "worldSize": [50, 50],
      "slopeMin":  0.1,
      "slopeMax":  10,
      "seed":      77
    })
    Expect.that(out["count"] > 0).toBe(true)
  }
}

Test.run()
