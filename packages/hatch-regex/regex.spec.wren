import "./regex"       for Regex, Match
import "@hatch:test"   for Test
import "@hatch:assert" for Expect

// --- compile / basic match --------------------------------------

Test.describe("compile + isMatch") {
  Test.it("simple literal matches") {
    var re = Regex.compile("hello")
    Expect.that(re.isMatch("say hello world")).toBe(true)
    Expect.that(re.isMatch("goodbye")).toBe(false)
  }
  Test.it("character class") {
    var re = Regex.compile("\\d+")
    Expect.that(re.isMatch("answer: 42")).toBe(true)
    Expect.that(re.isMatch("no digits")).toBe(false)
  }
  Test.it("anchors") {
    var start = Regex.compile("^foo")
    Expect.that(start.isMatch("foobar")).toBe(true)
    Expect.that(start.isMatch("barfoo")).toBe(false)
    var end = Regex.compile("bar$")
    Expect.that(end.isMatch("foobar")).toBe(true)
    Expect.that(end.isMatch("foobarbaz")).toBe(false)
  }
  Test.it("flags: case-insensitive") {
    var re = Regex.compile("hello", "i")
    Expect.that(re.isMatch("HELLO")).toBe(true)
    Expect.that(re.isMatch("HeLLo")).toBe(true)
  }
  Test.it("flags: dot matches newline") {
    var plain = Regex.compile("a.b")
    Expect.that(plain.isMatch("a\nb")).toBe(false)
    var dotall = Regex.compile("a.b", "s")
    Expect.that(dotall.isMatch("a\nb")).toBe(true)
  }
  Test.it("flags: multi-line") {
    // Default: ^ only matches start of whole input.
    var plain = Regex.compile("^bar")
    Expect.that(plain.isMatch("foo\nbar")).toBe(false)
    var multi = Regex.compile("^bar", "m")
    Expect.that(multi.isMatch("foo\nbar")).toBe(true)
  }
  Test.it("invalid pattern aborts") {
    var e = Fiber.new { Regex.compile("(unclosed") }.try()
    Expect.that(e).toContain("Regex.compile")
  }
  Test.it("unknown flag aborts") {
    var e = Fiber.new { Regex.compile("x", "q") }.try()
    Expect.that(e).toContain("unknown flag")
  }
}

// --- find / findAll / captures ----------------------------------

Test.describe("find + captures") {
  Test.it("find returns the first match") {
    var re = Regex.compile("\\d+")
    var m = re.find("x12 y34 z56")
    Expect.that(m is Match).toBe(true)
    Expect.that(m.text).toBe("12")
    Expect.that(m.start).toBe(1)
    Expect.that(m.end).toBe(3)
  }
  Test.it("find returns null when no match") {
    var re = Regex.compile("\\d+")
    Expect.that(re.find("no digits")).toBeNull()
  }
  Test.it("capture groups") {
    var re = Regex.compile("(\\w+)@(\\w+\\.\\w+)")
    var m = re.find("ping@host.io")
    Expect.that(m.groups.count).toBe(3)
    Expect.that(m.groups[0]).toBe("ping@host.io")
    Expect.that(m.groups[1]).toBe("ping")
    Expect.that(m.groups[2]).toBe("host.io")
  }
  Test.it("named groups") {
    var re = Regex.compile("(?P<user>\\w+)@(?P<host>\\w+\\.\\w+)")
    var m = re.find("ping@host.io")
    Expect.that(m.named["user"]).toBe("ping")
    Expect.that(m.named["host"]).toBe("host.io")
    // group(name) sugar.
    Expect.that(m.group("user")).toBe("ping")
  }
  Test.it("findAll collects every match") {
    var re = Regex.compile("\\d+")
    var ms = re.findAll("x12 y34 z56")
    Expect.that(ms.count).toBe(3)
    Expect.that(ms[0].text).toBe("12")
    Expect.that(ms[1].text).toBe("34")
    Expect.that(ms[2].text).toBe("56")
  }
  Test.it("findAll is empty when nothing matches") {
    var re = Regex.compile("\\d+")
    Expect.that(re.findAll("no digits").count).toBe(0)
  }
}

// --- replace ----------------------------------------------------

Test.describe("replace") {
  Test.it("replace replaces only the first match") {
    var re = Regex.compile("x")
    Expect.that(re.replace("xxxx", "y")).toBe("yxxx")
  }
  Test.it("replaceAll replaces every match") {
    var re = Regex.compile("x")
    Expect.that(re.replaceAll("xxxx", "y")).toBe("yyyy")
  }
  Test.it("replacement references capture groups") {
    var re = Regex.compile("(\\w+)=(\\w+)")
    Expect.that(re.replace("k=v", "$2=$1")).toBe("v=k")
  }
  Test.it("replacement with literal $ uses $$") {
    var re = Regex.compile("\\d+")
    Expect.that(re.replace("price 42", "$$ \\$")).toBe("price $ \\$")
  }
  Test.it("replacement references named groups") {
    var re = Regex.compile("(?P<k>\\w+)=(?P<v>\\w+)")
    Expect.that(re.replace("name=ada", "$v:$k")).toBe("ada:name")
  }
}

// --- split ------------------------------------------------------

Test.describe("split") {
  Test.it("split on simple delimiter") {
    var re = Regex.compile(",")
    var parts = re.split("a,b,c")
    Expect.that(parts.count).toBe(3)
    Expect.that(parts[0]).toBe("a")
    Expect.that(parts[1]).toBe("b")
    Expect.that(parts[2]).toBe("c")
  }
  Test.it("split on whitespace run") {
    var re = Regex.compile("\\s+")
    var parts = re.split("alpha  beta\tgamma")
    Expect.that(parts.count).toBe(3)
    Expect.that(parts[0]).toBe("alpha")
    Expect.that(parts[1]).toBe("beta")
    Expect.that(parts[2]).toBe("gamma")
  }
  Test.it("splitN caps the result count") {
    var re = Regex.compile(",")
    var parts = re.splitN("a,b,c,d,e", 3)
    Expect.that(parts.count).toBe(3)
    Expect.that(parts[0]).toBe("a")
    Expect.that(parts[1]).toBe("b")
    Expect.that(parts[2]).toBe("c,d,e")
  }
}

// --- escape -----------------------------------------------------

Test.describe("escape") {
  Test.it("escapes regex metacharacters") {
    var pat = Regex.escape("1.0 (beta)")
    // Whatever the exact form, using it as a pattern should
    // match only the literal string.
    var re = Regex.compile(pat)
    Expect.that(re.isMatch("version 1.0 (beta) ships")).toBe(true)
    Expect.that(re.isMatch("1x0 beta")).toBe(false)
  }
}

// --- free + lifecycle -------------------------------------------

Test.describe("lifecycle") {
  Test.it("free then use aborts") {
    var re = Regex.compile("x")
    re.free
    var e = Fiber.new { re.isMatch("xy") }.try()
    Expect.that(e).toContain("use after free")
  }
  Test.it("double free is a no-op") {
    var re = Regex.compile("x")
    re.free
    re.free   // should not abort
  }
  Test.it("pattern accessor reports original pattern") {
    var re = Regex.compile("a+b")
    Expect.that(re.pattern).toBe("a+b")
  }
}

// --- validation -------------------------------------------------

Test.describe("validation") {
  Test.it("compile with non-string pattern aborts") {
    var e = Fiber.new { Regex.compile(42) }.try()
    Expect.that(e).toContain("must be a string")
  }
  Test.it("isMatch with non-string haystack aborts") {
    var re = Regex.compile("x")
    var e = Fiber.new { re.isMatch(42) }.try()
    Expect.that(e).toContain("must be a string")
  }
}

Test.run()
