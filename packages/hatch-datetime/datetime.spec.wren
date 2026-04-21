import "./datetime"    for DateTime, Duration
import "@hatch:test"   for Test
import "@hatch:assert" for Expect

// --- Duration --------------------------------------------------

Test.describe("Duration") {
  Test.it("seconds constructor round-trip") {
    var d = Duration.seconds(90)
    Expect.that(d.seconds).toBe(90)
    Expect.that(d.minutes).toBe(1.5)
  }
  Test.it("unit conversions") {
    Expect.that(Duration.minutes(2).seconds).toBe(120)
    Expect.that(Duration.hours(1).minutes).toBe(60)
    Expect.that(Duration.days(1).hours).toBe(24)
  }
  Test.it("arithmetic") {
    var sum = Duration.minutes(1) + Duration.seconds(30)
    Expect.that(sum.seconds).toBe(90)
    var diff = Duration.hours(1) - Duration.minutes(30)
    Expect.that(diff.minutes).toBe(30)
    var scaled = Duration.seconds(10) * 3
    Expect.that(scaled.seconds).toBe(30)
  }
  Test.it("comparisons") {
    Expect.that(Duration.seconds(60) == Duration.minutes(1)).toBe(true)
    Expect.that(Duration.minutes(1) < Duration.hours(1)).toBe(true)
    Expect.that(Duration.days(2) > Duration.days(1)).toBe(true)
  }
  Test.it("toString picks a readable unit") {
    Expect.that(Duration.seconds(5).toString).toContain("s")
    Expect.that(Duration.minutes(2).toString).toContain("m")
    Expect.that(Duration.hours(3).toString).toContain("h")
    Expect.that(Duration.days(7).toString).toContain("d")
  }
}

// --- DateTime: construction / parse ----------------------------

Test.describe("DateTime factories") {
  Test.it("utc(y, m, d)") {
    var dt = DateTime.utc(2026, 4, 21)
    Expect.that(dt.year).toBe(2026)
    Expect.that(dt.month).toBe(4)
    Expect.that(dt.day).toBe(21)
    Expect.that(dt.hour).toBe(0)
    Expect.that(dt.offsetMinutes).toBe(0)
  }
  Test.it("utc(y, m, d, h, mi, s)") {
    var dt = DateTime.utc(2026, 4, 21, 15, 30, 45)
    Expect.that(dt.hour).toBe(15)
    Expect.that(dt.minute).toBe(30)
    Expect.that(dt.second).toBe(45)
  }
  Test.it("fromUnix(n) is UTC") {
    var dt = DateTime.fromUnix(0)
    Expect.that(dt.year).toBe(1970)
    Expect.that(dt.month).toBe(1)
    Expect.that(dt.day).toBe(1)
    Expect.that(dt.offsetMinutes).toBe(0)
  }
  Test.it("fromUnix(n, offset) keeps the instant, shifts display") {
    var dt = DateTime.fromUnix(0, 60)    // UTC 1970-01-01 00:00, displayed at +01:00
    Expect.that(dt.unix).toBe(0)
    Expect.that(dt.hour).toBe(1)
    Expect.that(dt.offsetMinutes).toBe(60)
  }
}

Test.describe("DateTime.parse") {
  Test.it("bare date") {
    var dt = DateTime.parse("2026-04-21")
    Expect.that(dt.year).toBe(2026)
    Expect.that(dt.day).toBe(21)
    Expect.that(dt.hour).toBe(0)
  }
  Test.it("full RFC 3339 with Z") {
    var dt = DateTime.parse("2026-04-21T15:30:45Z")
    Expect.that(dt.hour).toBe(15)
    Expect.that(dt.offsetMinutes).toBe(0)
  }
  Test.it("positive offset") {
    var dt = DateTime.parse("2026-04-21T15:30:45+02:00")
    Expect.that(dt.hour).toBe(15)
    Expect.that(dt.offsetMinutes).toBe(120)
    // UTC instant is 2 hours earlier than the local face value.
    Expect.that(dt.toUtc.hour).toBe(13)
  }
  Test.it("negative offset") {
    var dt = DateTime.parse("2026-04-21T15:30:45-08:00")
    Expect.that(dt.offsetMinutes).toBe(-480)
    Expect.that(dt.toUtc.hour).toBe(23)    // 15:30 + 8h = 23:30 UTC
  }
  Test.it("compact offset without colon") {
    var dt = DateTime.parse("2026-04-21T15:30:45+0200")
    Expect.that(dt.offsetMinutes).toBe(120)
  }
  Test.it("fractional seconds are silently dropped") {
    var dt = DateTime.parse("2026-04-21T15:30:45.123Z")
    Expect.that(dt.second).toBe(45)
  }
  Test.it("space separator is accepted") {
    var dt = DateTime.parse("2026-04-21 15:30:45Z")
    Expect.that(dt.hour).toBe(15)
  }
  Test.it("malformed input aborts") {
    var e = Fiber.new { DateTime.parse("not a date") }.try()
    Expect.that(e).toContain("DateTime.parse")
  }
}

// --- Round-trip & equality -------------------------------------

Test.describe("DateTime round-trip") {
  Test.it("iso → parse → iso is stable") {
    var a = DateTime.parse("2026-04-21T15:30:45+02:00")
    var b = DateTime.parse(a.iso)
    Expect.that(b.unix).toBe(a.unix)
    Expect.that(b.offsetMinutes).toBe(a.offsetMinutes)
  }
  Test.it("same instant, different offsets → equal") {
    var a = DateTime.parse("2026-01-01T12:00:00Z")
    var b = DateTime.parse("2026-01-01T13:00:00+01:00")
    Expect.that(a == b).toBe(true)
  }
  Test.it("diff reports the gap in seconds") {
    var a = DateTime.utc(2026, 1, 1, 12, 0, 0)
    var b = DateTime.utc(2026, 1, 1, 11, 0, 0)
    var d = a.diff(b)
    Expect.that(d.seconds).toBe(3600)
    Expect.that(d.hours).toBe(1)
  }
}

// --- Arithmetic ------------------------------------------------

Test.describe("DateTime arithmetic") {
  Test.it("add a Duration") {
    var dt = DateTime.utc(2026, 4, 21, 0, 0, 0)
    var later = dt.add(Duration.hours(3))
    Expect.that(later.hour).toBe(3)
    Expect.that(later.day).toBe(21)
  }
  Test.it("rollover across day boundary") {
    var dt = DateTime.utc(2026, 4, 21, 23, 30, 0)
    var later = dt.add(Duration.minutes(45))
    Expect.that(later.day).toBe(22)
    Expect.that(later.hour).toBe(0)
    Expect.that(later.minute).toBe(15)
  }
  Test.it("subtract Duration") {
    var dt = DateTime.utc(2026, 4, 21, 12, 0, 0)
    var earlier = dt.subtract(Duration.hours(2))
    Expect.that(earlier.hour).toBe(10)
  }
  Test.it("subtract DateTime → Duration") {
    var a = DateTime.utc(2026, 4, 22, 0, 0, 0)
    var b = DateTime.utc(2026, 4, 21, 0, 0, 0)
    var d = a.subtract(b)
    Expect.that(d is Duration).toBe(true)
    Expect.that(d.days).toBe(1)
  }
}

// --- Offsets ---------------------------------------------------

Test.describe("DateTime offsets") {
  Test.it("withOffset preserves instant") {
    var utc = DateTime.utc(2026, 4, 21, 12, 0, 0)
    var tokyo = utc.withOffset(540)           // +09:00
    Expect.that(tokyo.unix).toBe(utc.unix)
    Expect.that(tokyo.hour).toBe(21)
    Expect.that(tokyo.offsetMinutes).toBe(540)
  }
  Test.it("toUtc normalises the offset to 0") {
    var dt = DateTime.parse("2026-04-21T15:30:00+02:00")
    var u = dt.toUtc
    Expect.that(u.offsetMinutes).toBe(0)
    Expect.that(u.hour).toBe(13)
  }
  Test.it("non-integer offset aborts") {
    var e = Fiber.new {
      DateTime.fromUnix(0, 2.5)
    }.try()
    Expect.that(e).toContain("integer")
  }
}

// --- Formatting ------------------------------------------------

Test.describe("DateTime.format") {
  Test.it("full pattern") {
    var dt = DateTime.utc(2026, 4, 21, 15, 30, 45)
    Expect.that(dt.format("YYYY-MM-DD HH:mm:ss"))
      .toBe("2026-04-21 15:30:45")
  }
  Test.it("iso includes offset") {
    var dt = DateTime.fromUnix(0, 120)
    Expect.that(dt.iso).toContain("+02:00")
  }
  Test.it("UTC iso uses Z") {
    var dt = DateTime.utc(2026, 4, 21)
    Expect.that(dt.iso.contains("Z")).toBe(true)
  }
  Test.it("ZZ and Z tokens") {
    var dt = DateTime.fromUnix(0, 60)
    Expect.that(dt.format("HH ZZ")).toContain("+01:00")
    Expect.that(dt.format("HH Z")).toContain("+0100")
  }
}

// --- Comparisons -----------------------------------------------

Test.describe("DateTime comparisons") {
  Test.it("ordering by instant") {
    var a = DateTime.utc(2026, 4, 21, 10, 0, 0)
    var b = DateTime.utc(2026, 4, 21, 11, 0, 0)
    Expect.that(a < b).toBe(true)
    Expect.that(b > a).toBe(true)
    Expect.that(a != b).toBe(true)
    Expect.that(a <= a).toBe(true)
  }
}

Test.run()
