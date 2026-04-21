import "./csv"         for Csv
import "@hatch:test"   for Test
import "@hatch:assert" for Expect

// --- parse: scalar cells ---------------------------------------

Test.describe("parse: plain rows") {
  Test.it("single row, no newline") {
    var r = Csv.parse("a,b,c")
    Expect.that(r.count).toBe(1)
    Expect.that(r[0][0]).toBe("a")
    Expect.that(r[0][2]).toBe("c")
  }
  Test.it("multiple rows, LF-terminated") {
    var r = Csv.parse("a,b\n1,2\n3,4")
    Expect.that(r.count).toBe(3)
    Expect.that(r[1][0]).toBe("1")
    Expect.that(r[2][1]).toBe("4")
  }
  Test.it("CRLF line endings") {
    var r = Csv.parse("a,b\r\n1,2\r\n")
    Expect.that(r.count).toBe(2)
    Expect.that(r[1][1]).toBe("2")
  }
  Test.it("bare CR line endings") {
    var r = Csv.parse("a,b\r1,2")
    Expect.that(r.count).toBe(2)
  }
  Test.it("empty cells preserved") {
    var r = Csv.parse("a,,c")
    Expect.that(r[0].count).toBe(3)
    Expect.that(r[0][0]).toBe("a")
    Expect.that(r[0][1]).toBe("")
    Expect.that(r[0][2]).toBe("c")
  }
  Test.it("trailing empty cell") {
    var r = Csv.parse("a,b,")
    Expect.that(r[0].count).toBe(3)
    Expect.that(r[0][2]).toBe("")
  }
  Test.it("trailing newline doesn't produce an empty row") {
    var r = Csv.parse("a,b\n1,2\n")
    Expect.that(r.count).toBe(2)
  }
  Test.it("empty input returns empty list") {
    Expect.that(Csv.parse("").count).toBe(0)
  }
}

// --- parse: quoting --------------------------------------------

Test.describe("parse: quoted cells") {
  Test.it("simple quoted cell") {
    var r = Csv.parse("\"hello\",world")
    Expect.that(r[0][0]).toBe("hello")
    Expect.that(r[0][1]).toBe("world")
  }
  Test.it("quoted cell with delimiter") {
    var r = Csv.parse("\"a,b\",c")
    Expect.that(r[0][0]).toBe("a,b")
    Expect.that(r[0][1]).toBe("c")
  }
  Test.it("quoted cell with embedded newline") {
    var r = Csv.parse("\"line1\nline2\",x")
    Expect.that(r[0][0]).toBe("line1\nline2")
    Expect.that(r[0][1]).toBe("x")
  }
  Test.it("escaped quote inside quoted cell") {
    var r = Csv.parse("\"he said \"\"hi\"\"\",x")
    Expect.that(r[0][0]).toBe("he said \"hi\"")
  }
  Test.it("unterminated quoted cell aborts") {
    var e = Fiber.new { Csv.parse("\"oops,x") }.try()
    Expect.that(e).toContain("unterminated")
  }
}

// --- parse: header ---------------------------------------------

Test.describe("parse: header") {
  Test.it("header=true yields maps") {
    var r = Csv.parse("name,age\nalice,30\nbob,25", {"header": true})
    Expect.that(r.count).toBe(2)
    Expect.that(r[0]["name"]).toBe("alice")
    Expect.that(r[0]["age"]).toBe("30")
    Expect.that(r[1]["name"]).toBe("bob")
  }
  Test.it("header=true with only a header row → []") {
    var r = Csv.parse("name,age", {"header": true})
    Expect.that(r.count).toBe(0)
  }
  Test.it("short row pads missing cells with empty string") {
    var r = Csv.parse("a,b,c\n1", {"header": true})
    Expect.that(r[0]["a"]).toBe("1")
    Expect.that(r[0]["b"]).toBe("")
    Expect.that(r[0]["c"]).toBe("")
  }
}

// --- parse: options --------------------------------------------

Test.describe("parse: custom delimiters") {
  Test.it("semicolon delimiter") {
    var r = Csv.parse("a;b;c\n1;2;3", {"delimiter": ";"})
    Expect.that(r[0][0]).toBe("a")
    Expect.that(r[1][2]).toBe("3")
  }
  Test.it("tab delimiter") {
    var r = Csv.parse("a\tb\n1\t2", {"delimiter": "\t"})
    Expect.that(r[0][1]).toBe("b")
    Expect.that(r[1][0]).toBe("1")
  }
  Test.it("single-quote as quote char") {
    var r = Csv.parse("'hi,there',x", {"quote": "'"})
    Expect.that(r[0][0]).toBe("hi,there")
  }
  Test.it("multi-char delimiter rejected") {
    var e = Fiber.new { Csv.parse("a,b", {"delimiter": "||"}) }.try()
    Expect.that(e).toContain("one-character")
  }
}

// --- encode ----------------------------------------------------

Test.describe("encode: List rows") {
  Test.it("plain rows, default CRLF") {
    var s = Csv.encode([["a", "b"], [1, 2]])
    Expect.that(s).toBe("a,b\r\n1,2\r\n")
  }
  Test.it("LF line ending option") {
    var s = Csv.encode([["a"], ["b"]], {"lineEnding": "\n"})
    Expect.that(s).toBe("a\nb\n")
  }
  Test.it("quotes cells containing delimiter") {
    var s = Csv.encode([["a,b", "c"]])
    Expect.that(s).toBe("\"a,b\",c\r\n")
  }
  Test.it("doubles embedded quote chars") {
    var s = Csv.encode([["he said \"hi\""]])
    Expect.that(s).toBe("\"he said \"\"hi\"\"\"\r\n")
  }
  Test.it("quotes cells containing newlines") {
    var s = Csv.encode([["line1\nline2"]])
    Expect.that(s).toBe("\"line1\nline2\"\r\n")
  }
  Test.it("null cell becomes empty") {
    var s = Csv.encode([["a", null, "b"]])
    Expect.that(s).toBe("a,,b\r\n")
  }
  Test.it("bool serialises as toString") {
    var s = Csv.encode([[true, false]])
    Expect.that(s).toBe("true,false\r\n")
  }
}

Test.describe("encode: Map rows + header") {
  Test.it("Map rows with explicit columns + header") {
    var s = Csv.encode([
      {"name": "alice", "age": 30},
      {"name": "bob",   "age": 25}
    ], {"header": true, "columns": ["name", "age"]})
    Expect.that(s).toContain("name,age")
    Expect.that(s).toContain("alice,30")
    Expect.that(s).toContain("bob,25")
  }
  Test.it("missing keys fill as empty cells") {
    var s = Csv.encode([
      {"a": 1, "b": 2},
      {"a": 3}
    ], {"columns": ["a", "b"]})
    Expect.that(s).toBe("1,2\r\n3,\r\n")
  }
  Test.it("header=true without columns derives from first map") {
    var s = Csv.encode([{"x": 1, "y": 2}], {"header": true})
    // Order isn't guaranteed across Wren Map iteration, so check
    // by cell presence rather than full equality.
    Expect.that(s).toContain("x")
    Expect.that(s).toContain("y")
    Expect.that(s).toContain("1")
    Expect.that(s).toContain("2")
  }
  Test.it("header=true on List rows aborts") {
    var e = Fiber.new {
      Csv.encode([[1, 2]], {"header": true})
    }.try()
    Expect.that(e).toContain("Map rows or explicit columns")
  }
}

// --- round-trip ------------------------------------------------

Test.describe("round-trip") {
  Test.it("List round-trip preserves cells") {
    var rows = [["a", "b,c"], ["1\n2", "3"]]
    var encoded = Csv.encode(rows)
    var decoded = Csv.parse(encoded)
    Expect.that(decoded[0][0]).toBe("a")
    Expect.that(decoded[0][1]).toBe("b,c")
    Expect.that(decoded[1][0]).toBe("1\n2")
    Expect.that(decoded[1][1]).toBe("3")
  }
}

// --- validation ------------------------------------------------

Test.describe("validation") {
  Test.it("parse non-string aborts") {
    var e = Fiber.new { Csv.parse(42) }.try()
    Expect.that(e).toContain("must be a string")
  }
  Test.it("encode non-list aborts") {
    var e = Fiber.new { Csv.encode("oops") }.try()
    Expect.that(e).toContain("must be a list")
  }
  Test.it("encode unsupported cell value aborts") {
    var e = Fiber.new { Csv.encode([[[1, 2]]]) }.try()
    Expect.that(e).toContain("cell values must be")
  }
}

Test.run()
