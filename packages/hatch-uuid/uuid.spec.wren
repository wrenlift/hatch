import "./uuid"        for Uuid
import "@hatch:test"   for Test
import "@hatch:assert" for Expect

// --- Basic generation -------------------------------------------

Test.describe("generation") {
  Test.it("v4 produces valid UUIDs") {
    var u = Uuid.v4
    Expect.that(u is String).toBe(true)
    Expect.that(Uuid.isValid(u)).toBe(true)
    Expect.that(Uuid.version(u)).toBe(4)
  }
  Test.it("v4 is random — two calls differ") {
    var a = Uuid.v4
    var b = Uuid.v4
    Expect.that(a != b).toBe(true)
  }
  Test.it("v7 produces valid UUIDs") {
    var u = Uuid.v7
    Expect.that(Uuid.isValid(u)).toBe(true)
    Expect.that(Uuid.version(u)).toBe(7)
  }
  Test.it("v7 is time-ordered — byte sort tracks creation order") {
    // v7 encodes a unix_ts_ms in the leading 48 bits. Compare the
    // first 6 bytes directly; Wren's String doesn't have <= but
    // List<Num> lets us do it byte by byte.
    var a = Uuid.toBytes(Uuid.v7)
    var b = Uuid.toBytes(Uuid.v7)
    var i = 0
    var decided = false
    while (i < 6 && !decided) {
      if (a[i] != b[i]) decided = true
      if (!decided) i = i + 1
    }
    // Either the first 6 bytes are identical (same millisecond) or
    // b's first differing byte is >= a's.
    if (decided) Expect.that(b[i] >= a[i]).toBe(true)
  }
  Test.it("nil is all-zero") {
    Expect.that(Uuid.nil).toBe("00000000-0000-0000-0000-000000000000")
  }
}

// --- v5 determinism ---------------------------------------------

Test.describe("v5") {
  Test.it("same inputs produce same output") {
    var a = Uuid.v5("dns", "example.com")
    var b = Uuid.v5("dns", "example.com")
    Expect.that(a).toBe(b)
    Expect.that(Uuid.version(a)).toBe(5)
  }
  Test.it("different names produce different outputs") {
    var a = Uuid.v5("dns", "example.com")
    var b = Uuid.v5("dns", "other.com")
    Expect.that(a != b).toBe(true)
  }
  Test.it("different namespaces produce different outputs") {
    var a = Uuid.v5("dns", "example.com")
    var b = Uuid.v5("url", "example.com")
    Expect.that(a != b).toBe(true)
  }
  Test.it("accepts namespace constants") {
    var a = Uuid.v5(Uuid.NS_DNS, "example.com")
    var b = Uuid.v5("dns", "example.com")
    Expect.that(a).toBe(b)
  }
  Test.it("RFC 4122 test vector") {
    // v5(NS_DNS, "www.example.com") is one of the canonical test vectors.
    var u = Uuid.v5("dns", "www.example.com")
    Expect.that(u).toBe("2ed6657d-e927-568b-95e1-2665a8aea6a2")
  }
}

// --- Parsing ----------------------------------------------------

Test.describe("parse + isValid") {
  Test.it("parse normalises to hyphenated lowercase") {
    var u = Uuid.parse("550E8400-E29B-41D4-A716-446655440000")
    Expect.that(u).toBe("550e8400-e29b-41d4-a716-446655440000")
  }
  Test.it("parse accepts hyphenless form") {
    var u = Uuid.parse("550e8400e29b41d4a716446655440000")
    Expect.that(u).toBe("550e8400-e29b-41d4-a716-446655440000")
  }
  Test.it("parse accepts braces form") {
    var u = Uuid.parse("{550e8400-e29b-41d4-a716-446655440000}")
    Expect.that(u).toBe("550e8400-e29b-41d4-a716-446655440000")
  }
  Test.it("parse returns null on garbage") {
    Expect.that(Uuid.parse("not-a-uuid")).toBeNull()
    Expect.that(Uuid.parse("")).toBeNull()
    Expect.that(Uuid.parse("550e8400")).toBeNull()
  }
  Test.it("isValid matches parse's behaviour") {
    Expect.that(Uuid.isValid("550e8400-e29b-41d4-a716-446655440000")).toBe(true)
    Expect.that(Uuid.isValid("NOPE")).toBe(false)
  }
  Test.it("version reports 1-7") {
    Expect.that(Uuid.version(Uuid.v4)).toBe(4)
    Expect.that(Uuid.version(Uuid.v7)).toBe(7)
    Expect.that(Uuid.version("invalid")).toBeNull()
  }
}

// --- Byte conversion --------------------------------------------

Test.describe("bytes") {
  Test.it("toBytes returns 16 bytes") {
    var bs = Uuid.toBytes("550e8400-e29b-41d4-a716-446655440000")
    Expect.that(bs.count).toBe(16)
    Expect.that(bs[0]).toBe(0x55)
    Expect.that(bs[1]).toBe(0x0e)
    Expect.that(bs[15]).toBe(0x00)
  }
  Test.it("fromBytes is the inverse of toBytes") {
    var original = "550e8400-e29b-41d4-a716-446655440000"
    var bs = Uuid.toBytes(original)
    Expect.that(Uuid.fromBytes(bs)).toBe(original)
  }
  Test.it("round-trip for random UUIDs") {
    var a = Uuid.v4
    var bs = Uuid.toBytes(a)
    Expect.that(Uuid.fromBytes(bs)).toBe(a)
  }
  Test.it("fromBytes rejects wrong length") {
    var e = Fiber.new { Uuid.fromBytes([0, 1, 2]) }.try()
    Expect.that(e).toContain("expected 16 bytes")
  }
  Test.it("fromBytes rejects out-of-range bytes") {
    var buf = []
    var i = 0
    while (i < 16) {
      buf.add(0)
      i = i + 1
    }
    buf[0] = 256
    var e = Fiber.new { Uuid.fromBytes(buf) }.try()
    Expect.that(e).toContain("integers in 0..=255")
  }
  Test.it("toBytes rejects malformed input") {
    var e = Fiber.new { Uuid.toBytes("garbage") }.try()
    Expect.that(e).toContain("invalid UUID")
  }
}

// --- Validation -------------------------------------------------

Test.describe("validation") {
  Test.it("parse with non-string aborts") {
    var e = Fiber.new { Uuid.parse(42) }.try()
    Expect.that(e).toContain("must be a string")
  }
  Test.it("v5 with non-string args aborts") {
    var e = Fiber.new { Uuid.v5(42, "x") }.try()
    Expect.that(e).toContain("must be a string")
  }
  Test.it("v5 rejects bogus namespace") {
    var e = Fiber.new { Uuid.v5("not-a-namespace", "x") }.try()
    Expect.that(e).toContain("namespace")
  }
  Test.it("fromBytes with non-list aborts") {
    var e = Fiber.new { Uuid.fromBytes("not a list") }.try()
    Expect.that(e).toContain("must be a list")
  }
}

Test.run()
