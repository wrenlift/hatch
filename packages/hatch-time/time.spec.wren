import "./time"        for Time, Clock
import "@hatch:test"   for Test
import "@hatch:assert" for Expect

Test.describe("Clock.unix / Clock.mono") {
  Test.it("unix is a positive number") {
    Expect.that(Clock.unix > 0).toBe(true)
  }
  Test.it("mono returns non-decreasing values") {
    var a = Clock.mono
    var b = Clock.mono
    Expect.that(b >= a).toBe(true)
  }
  Test.it("mono advances after sleep") {
    var a = Clock.mono
    Clock.sleep(0.01)
    var b = Clock.mono
    Expect.that(b - a >= 0.01).toBe(true)
  }
}

Test.describe("Clock.sleep") {
  Test.it("rejects negative seconds") {
    var e = Fiber.new { Clock.sleep(-1) }.try()
    Expect.that(e).toContain("non-negative")
  }
  Test.it("sleepMs scales to seconds") {
    var a = Clock.mono
    Clock.sleepMs(10)
    var b = Clock.mono
    Expect.that(b - a >= 0.01).toBe(true)
  }
}

Test.describe("Clock.elapsed") {
  Test.it("returns the block's duration") {
    var e = Clock.elapsed { Clock.sleep(0.02) }
    Expect.that(e >= 0.02).toBe(true)
  }
  Test.it("non-Fn aborts") {
    var e = Fiber.new { Clock.elapsed("hi") }.try()
    Expect.that(e).toContain("expected a Fn")
  }
}

Test.describe("Time.fromUnix — UTC decomposition") {
  Test.it("2026-04-20 00:00:00 UTC = 1776643200") {
    // 20563 days × 86400 s/day = 1,776,643,200
    var t = Time.fromUnix(1776643200)
    Expect.that(t.year).toBe(2026)
    Expect.that(t.month).toBe(4)
    Expect.that(t.day).toBe(20)
    Expect.that(t.hour).toBe(0)
    Expect.that(t.minute).toBe(0)
    Expect.that(t.second).toBe(0)
  }
  Test.it("decomposes mid-day timestamps") {
    // 1776643200 + 3 h 15 m 30 s = 1776654930
    var t = Time.fromUnix(1776654930)
    Expect.that(t.hour).toBe(3)
    Expect.that(t.minute).toBe(15)
    Expect.that(t.second).toBe(30)
  }
  Test.it("negative unix seconds decompose pre-epoch") {
    var t = Time.fromUnix(-1)
    Expect.that(t.year).toBe(1969)
    Expect.that(t.month).toBe(12)
    Expect.that(t.day).toBe(31)
    Expect.that(t.hour).toBe(23)
    Expect.that(t.minute).toBe(59)
    Expect.that(t.second).toBe(59)
  }
  Test.it("weekday: Thu = 3 for 1970-01-01") {
    var t = Time.fromUnix(0)
    Expect.that(t.weekday).toBe(3)
  }
  Test.it("non-number input aborts") {
    var e = Fiber.new { Time.fromUnix("bad") }.try()
    Expect.that(e).toContain("expected a number")
  }
}

Test.describe("Time.now") {
  Test.it("is close to Clock.unix") {
    var a = Clock.unix
    var t = Time.now
    var b = Clock.unix
    Expect.that(t.unix >= a).toBe(true)
    Expect.that(t.unix <= b).toBe(true)
  }
}

Test.describe("Time formatting") {
  Test.it("iso renders RFC 3339") {
    var t = Time.fromUnix(1776643200)
    Expect.that(t.iso).toBe("2026-04-20T00:00:00Z")
  }
  Test.it("format applies token substitution") {
    var t = Time.fromUnix(1776643200)
    Expect.that(t.format("YYYY-MM-DD")).toBe("2026-04-20")
    Expect.that(t.format("HH:mm:ss")).toBe("00:00:00")
  }
  Test.it("format pads single-digit components") {
    var t = Time.fromUnix(0)   // 1970-01-01 00:00:00
    Expect.that(t.format("YYYY-MM-DD")).toBe("1970-01-01")
  }
  Test.it("toString getter returns iso") {
    var t = Time.fromUnix(1776643200)
    Expect.that(t.toString).toBe("2026-04-20T00:00:00Z")
  }
}

Test.run()
