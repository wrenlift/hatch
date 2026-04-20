import "./json"        for JSON
import "@hatch:test"   for Test
import "@hatch:assert" for Expect

Test.describe("parse: primitives") {
  Test.it("null") {
    Expect.that(JSON.parse("null")).toBe(null)
  }
  Test.it("true / false") {
    Expect.that(JSON.parse("true")).toBe(true)
    Expect.that(JSON.parse("false")).toBe(false)
  }
  Test.it("integers") {
    Expect.that(JSON.parse("0")).toBe(0)
    Expect.that(JSON.parse("42")).toBe(42)
    Expect.that(JSON.parse("-7")).toBe(-7)
  }
  Test.it("floats + exponents") {
    Expect.that(JSON.parse("3.14")).toBe(3.14)
    Expect.that(JSON.parse("-0.5")).toBe(-0.5)
    Expect.that(JSON.parse("1e3")).toBe(1000)
    Expect.that(JSON.parse("2.5e-2")).toBe(0.025)
  }
  Test.it("strings") {
    Expect.that(JSON.parse("\"hello\"")).toBe("hello")
    Expect.that(JSON.parse("\"\"")).toBe("")
  }
  Test.it("string escapes") {
    Expect.that(JSON.parse("\"\\n\"")).toBe("\n")
    Expect.that(JSON.parse("\"\\t\"")).toBe("\t")
    Expect.that(JSON.parse("\"\\\"\"")).toBe("\"")
    Expect.that(JSON.parse("\"\\\\\"")).toBe("\\")
    Expect.that(JSON.parse("\"a\\nb\"")).toBe("a\nb")
  }
  Test.it("unicode escape (ASCII range)") {
    Expect.that(JSON.parse("\"\\u0041\"")).toBe("A")
  }
}

Test.describe("parse: arrays") {
  Test.it("empty") {
    Expect.that(JSON.parse("[]")).toEqual([])
  }
  Test.it("flat") {
    Expect.that(JSON.parse("[1, 2, 3]")).toEqual([1, 2, 3])
  }
  Test.it("mixed types") {
    Expect.that(JSON.parse("[1, \"a\", true, null]")).toEqual([1, "a", true, null])
  }
  Test.it("nested") {
    Expect.that(JSON.parse("[[1,2],[3,4]]")).toEqual([[1, 2], [3, 4]])
  }
  Test.it("whitespace tolerant") {
    Expect.that(JSON.parse("  [\n  1 , 2\n]\n")).toEqual([1, 2])
  }
}

Test.describe("parse: objects") {
  Test.it("empty") {
    var m = JSON.parse("{}")
    Expect.that(m is Map).toBeTruthy()
    Expect.that(m.count).toBe(0)
  }
  Test.it("single pair") {
    var m = JSON.parse("{\"a\": 1}")
    Expect.that(m["a"]).toBe(1)
  }
  Test.it("multiple pairs") {
    var m = JSON.parse("{\"a\": 1, \"b\": \"two\", \"c\": null}")
    Expect.that(m["a"]).toBe(1)
    Expect.that(m["b"]).toBe("two")
    Expect.that(m["c"]).toBe(null)
  }
  Test.it("nested") {
    var m = JSON.parse("{\"outer\": {\"inner\": [1, 2]}}")
    Expect.that(m["outer"]["inner"]).toEqual([1, 2])
  }
}

Test.describe("parse: errors") {
  Test.it("trailing data") {
    var e = Fiber.new { JSON.parse("1 2") }.try()
    Expect.that(e).toContain("trailing data")
  }
  Test.it("empty input") {
    var e = Fiber.new { JSON.parse("") }.try()
    Expect.that(e).toContain("unexpected end")
  }
  Test.it("unterminated string") {
    var e = Fiber.new { JSON.parse("\"oops") }.try()
    Expect.that(e).toContain("unterminated string")
  }
  Test.it("missing colon") {
    var e = Fiber.new { JSON.parse("{\"a\" 1}") }.try()
    Expect.that(e).toContain("':'")
  }
  Test.it("missing closing brace") {
    var e = Fiber.new { JSON.parse("{\"a\": 1") }.try()
    Expect.that(e).toContain("unterminated object")
  }
  Test.it("bad literal") {
    var e = Fiber.new { JSON.parse("tru") }.try()
    Expect.that(e).toContain("invalid literal")
  }
  Test.it("non-string input") {
    var e = Fiber.new { JSON.parse(42) }.try()
    Expect.that(e).toContain("expected a string")
  }
}

Test.describe("encode: primitives") {
  Test.it("null / true / false") {
    Expect.that(JSON.encode(null)).toBe("null")
    Expect.that(JSON.encode(true)).toBe("true")
    Expect.that(JSON.encode(false)).toBe("false")
  }
  Test.it("integers render without .0") {
    Expect.that(JSON.encode(0)).toBe("0")
    Expect.that(JSON.encode(42)).toBe("42")
    Expect.that(JSON.encode(-7)).toBe("-7")
  }
  Test.it("floats keep their precision") {
    Expect.that(JSON.encode(3.14)).toBe("3.14")
  }
  Test.it("strings are quoted") {
    Expect.that(JSON.encode("hi")).toBe("\"hi\"")
  }
  Test.it("string escapes") {
    Expect.that(JSON.encode("a\nb")).toBe("\"a\\nb\"")
    Expect.that(JSON.encode("\"quoted\"")).toBe("\"\\\"quoted\\\"\"")
    Expect.that(JSON.encode("back\\slash")).toBe("\"back\\\\slash\"")
  }
}

Test.describe("encode: arrays") {
  Test.it("empty") {
    Expect.that(JSON.encode([])).toBe("[]")
  }
  Test.it("flat") {
    Expect.that(JSON.encode([1, 2, 3])).toBe("[1,2,3]")
  }
  Test.it("nested") {
    Expect.that(JSON.encode([[1, 2], [3]])).toBe("[[1,2],[3]]")
  }
}

Test.describe("encode: objects") {
  Test.it("empty") {
    Expect.that(JSON.encode({})).toBe("{}")
  }
  Test.it("single pair") {
    Expect.that(JSON.encode({"a": 1})).toBe("{\"a\":1}")
  }
}

Test.describe("encode: errors") {
  Test.it("NaN is rejected") {
    var e = Fiber.new { JSON.encode(0/0) }.try()
    Expect.that(e).toContain("NaN")
  }
  Test.it("non-string map keys are rejected") {
    var e = Fiber.new { JSON.encode({1: "a"}) }.try()
    Expect.that(e).toContain("map keys must be strings")
  }
}

Test.describe("roundtrip") {
  Test.it("primitives roundtrip") {
    Expect.that(JSON.parse(JSON.encode(null))).toBe(null)
    Expect.that(JSON.parse(JSON.encode(true))).toBe(true)
    Expect.that(JSON.parse(JSON.encode(42))).toBe(42)
    Expect.that(JSON.parse(JSON.encode("hi"))).toBe("hi")
  }
  Test.it("nested structures roundtrip") {
    var v = [1, "two", [3, 4], null]
    Expect.that(JSON.parse(JSON.encode(v))).toEqual(v)
  }
}

Test.describe("encode: pretty-print") {
  Test.it("indent=2 uses two-space padding") {
    var s = JSON.encode([1, 2], 2)
    Expect.that(s).toBe("[\n  1,\n  2\n]")
  }
  Test.it("nested indents compound") {
    var s = JSON.encode([[1]], 2)
    Expect.that(s).toBe("[\n  [\n    1\n  ]\n]")
  }
  Test.it("negative indent is rejected") {
    var e = Fiber.new { JSON.encode([1], -1) }.try()
    Expect.that(e).toContain("non-negative")
  }
}

Test.run()
