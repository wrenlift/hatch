import "./random"      for Rand
import "@hatch:test"   for Test
import "@hatch:assert" for Expect

// --- scalar draws ----------------------------------------------

Test.describe("float") {
  Test.it("zero-arg returns [0, 1)") {
    var i = 0
    while (i < 20) {
      var x = Rand.float
      Expect.that(x >= 0).toBe(true)
      Expect.that(x < 1).toBe(true)
      i = i + 1
    }
  }
  Test.it("one-arg caps the range") {
    var i = 0
    while (i < 20) {
      var x = Rand.float(5)
      Expect.that(x >= 0).toBe(true)
      Expect.that(x < 5).toBe(true)
      i = i + 1
    }
  }
  Test.it("two-arg bounds the range") {
    var i = 0
    while (i < 20) {
      var x = Rand.float(10, 20)
      Expect.that(x >= 10).toBe(true)
      Expect.that(x < 20).toBe(true)
      i = i + 1
    }
  }
}

Test.describe("int") {
  Test.it("one-arg returns [0, n)") {
    var i = 0
    while (i < 30) {
      var n = Rand.int(10)
      Expect.that(n >= 0).toBe(true)
      Expect.that(n < 10).toBe(true)
      i = i + 1
    }
  }
  Test.it("two-arg returns [a, b)") {
    var i = 0
    while (i < 30) {
      var n = Rand.int(5, 15)
      Expect.that(n >= 5).toBe(true)
      Expect.that(n < 15).toBe(true)
      i = i + 1
    }
  }
}

Test.describe("bool") {
  Test.it("returns a Bool") {
    var b = Rand.bool
    Expect.that(b is Bool).toBe(true)
  }
  Test.it("covers both values over many draws") {
    Rand.seed = 1   // deterministic so this test doesn't flake
    var t = 0
    var f = 0
    var i = 0
    while (i < 200) {
      if (Rand.bool) {
        t = t + 1
      } else {
        f = f + 1
      }
      i = i + 1
    }
    // Both branches must have fired at least once — vanishingly
    // unlikely to fail for a uniform PRNG given a fixed seed.
    Expect.that(t > 0).toBe(true)
    Expect.that(f > 0).toBe(true)
  }
}

// --- collection helpers ----------------------------------------

Test.describe("sample") {
  Test.it("one element from a list") {
    var list = ["a", "b", "c", "d"]
    var v = Rand.sample(list)
    Expect.that(list.contains(v)).toBe(true)
  }
  Test.it("k elements, distinct, preserves membership") {
    var list = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
    var pick = Rand.sample(list, 3)
    Expect.that(pick.count).toBe(3)
    // Every returned element must be from the source list.
    var i = 0
    while (i < pick.count) {
      Expect.that(list.contains(pick[i])).toBe(true)
      i = i + 1
    }
    // Distinct check.
    var seen = {}
    i = 0
    while (i < pick.count) {
      Expect.that(seen.containsKey(pick[i])).toBe(false)
      seen[pick[i]] = true
      i = i + 1
    }
  }
}

Test.describe("shuffle") {
  Test.it("preserves elements and length") {
    Rand.seed = 7
    var list = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
    var sum_before = 0
    var i = 0
    while (i < list.count) {
      sum_before = sum_before + list[i]
      i = i + 1
    }
    Rand.shuffle(list)
    Expect.that(list.count).toBe(10)
    var sum_after = 0
    i = 0
    while (i < list.count) {
      sum_after = sum_after + list[i]
      i = i + 1
    }
    Expect.that(sum_after).toBe(sum_before)
  }
  Test.it("mutates in place") {
    Rand.seed = 1
    var list = [1, 2, 3, 4, 5, 6, 7, 8]
    Rand.shuffle(list)
    // For a well-mixed shuffle seeded at 1, at least ONE position
    // is almost certainly different from identity. (False-flake
    // probability: 1/40320.)
    var same = true
    var i = 0
    while (i < list.count) {
      if (list[i] != i + 1) {
        same = false
      }
      i = i + 1
    }
    Expect.that(same).toBe(false)
  }
}

// --- determinism -----------------------------------------------

Test.describe("seed") {
  Test.it("same seed yields the same sequence") {
    Rand.seed = 123
    var a = [Rand.int(1000), Rand.int(1000), Rand.int(1000)]
    Rand.seed = 123
    var b = [Rand.int(1000), Rand.int(1000), Rand.int(1000)]
    Expect.that(a[0]).toBe(b[0])
    Expect.that(a[1]).toBe(b[1])
    Expect.that(a[2]).toBe(b[2])
  }
  Test.it("non-number seed aborts") {
    var e = Fiber.new { Rand.seed = "oops" }.try()
    Expect.that(e).toContain("must be a number")
  }
}

Test.describe("stream") {
  Test.it("independent seeded streams reproduce their own sequence") {
    var a1 = Rand.stream(42)
    var a2 = Rand.stream(42)
    Expect.that(a1.int(1000000)).toBe(a2.int(1000000))
    Expect.that(a1.int(1000000)).toBe(a2.int(1000000))
  }
  Test.it("stream is independent from the default") {
    Rand.seed = 99
    var before = Rand.int(1000000)
    // Touching a stream musn't affect the shared default.
    var s = Rand.stream(1)
    s.int(1000000)
    s.int(1000000)
    Rand.seed = 99
    var after = Rand.int(1000000)
    Expect.that(after).toBe(before)
  }
}

Test.run()
