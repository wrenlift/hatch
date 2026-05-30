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

Test.run()
