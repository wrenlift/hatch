import "./toml"        for Toml
import "@hatch:test"   for Test
import "@hatch:assert" for Expect

// --- parse ------------------------------------------------------

Test.describe("parse scalars") {
  Test.it("string") {
    var c = Toml.parse("name = \"hatch\"")
    Expect.that(c["name"]).toBe("hatch")
  }
  Test.it("integer") {
    var c = Toml.parse("port = 8080")
    Expect.that(c["port"]).toBe(8080)
  }
  Test.it("float") {
    var c = Toml.parse("ratio = 1.5")
    Expect.that(c["ratio"]).toBe(1.5)
  }
  Test.it("boolean") {
    var c = Toml.parse("enabled = true\nverbose = false")
    Expect.that(c["enabled"]).toBe(true)
    Expect.that(c["verbose"]).toBe(false)
  }
  Test.it("datetime becomes ISO string") {
    var c = Toml.parse("created = 2026-04-20T12:34:56Z")
    Expect.that(c["created"]).toContain("2026-04-20")
  }
}

Test.describe("parse arrays") {
  Test.it("homogeneous integer array") {
    var c = Toml.parse("ports = [8080, 8081, 8082]")
    Expect.that(c["ports"][0]).toBe(8080)
    Expect.that(c["ports"][2]).toBe(8082)
  }
  Test.it("string array") {
    var c = Toml.parse("hosts = [\"a\", \"b\", \"c\"]")
    Expect.that(c["hosts"].count).toBe(3)
    Expect.that(c["hosts"][1]).toBe("b")
  }
  Test.it("nested array") {
    var c = Toml.parse("pairs = [[1, 2], [3, 4]]")
    Expect.that(c["pairs"][0][0]).toBe(1)
    Expect.that(c["pairs"][1][1]).toBe(4)
  }
}

Test.describe("parse tables") {
  Test.it("section header") {
    var src = "
[server]
host = \"localhost\"
port = 8080
"
    var c = Toml.parse(src)
    Expect.that(c["server"]["host"]).toBe("localhost")
    Expect.that(c["server"]["port"]).toBe(8080)
  }
  Test.it("nested section") {
    var src = "
[server.tls]
cert = \"a.pem\"
"
    var c = Toml.parse(src)
    Expect.that(c["server"]["tls"]["cert"]).toBe("a.pem")
  }
  Test.it("inline table") {
    var c = Toml.parse("db = {host = \"x\", port = 5432}")
    Expect.that(c["db"]["host"]).toBe("x")
    Expect.that(c["db"]["port"]).toBe(5432)
  }
}

Test.describe("parse errors") {
  Test.it("malformed input aborts") {
    var e = Fiber.new { Toml.parse("name = ") }.try()
    Expect.that(e).toContain("Toml.parse")
  }
  Test.it("non-string text aborts") {
    var e = Fiber.new { Toml.parse(42) }.try()
    Expect.that(e).toContain("must be a string")
  }
}

// --- encode -----------------------------------------------------

Test.describe("encode") {
  Test.it("flat map of scalars") {
    var s = Toml.encode({"name": "app", "port": 8080, "enabled": true})
    // Order isn't guaranteed by Wren Map iteration, so we check
    // each expected line shows up.
    Expect.that(s).toContain("name = \"app\"")
    Expect.that(s).toContain("port = 8080")
    Expect.that(s).toContain("enabled = true")
  }
  Test.it("nested map emits a [section] header") {
    var s = Toml.encode({"db": {"host": "x", "port": 5432}})
    Expect.that(s).toContain("[db]")
    Expect.that(s).toContain("host = \"x\"")
    Expect.that(s).toContain("port = 5432")
  }
  Test.it("array of scalars") {
    var s = Toml.encode({"ports": [80, 443]})
    Expect.that(s).toContain("ports = [")
    Expect.that(s).toContain("80")
    Expect.that(s).toContain("443")
  }
  Test.it("float round-trips as float") {
    var s = Toml.encode({"r": 1.5})
    Expect.that(s).toContain("r = 1.5")
  }
}

Test.describe("encode errors") {
  Test.it("non-map top level aborts") {
    var e = Fiber.new { Toml.encode([1, 2, 3]) }.try()
    Expect.that(e).toContain("must be a Map")
  }
  Test.it("NaN aborts") {
    // 0/0 produces NaN in Wren.
    var nan = 0 / 0
    var e = Fiber.new { Toml.encode({"x": nan}) }.try()
    Expect.that(e).toContain("NaN")
  }
  Test.it("null rejected") {
    var e = Fiber.new { Toml.encode({"x": null}) }.try()
    Expect.that(e).toContain("null")
  }
  Test.it("non-string map key rejected") {
    var e = Fiber.new { Toml.encode({42: "v"}) }.try()
    Expect.that(e).toContain("keys must be strings")
  }
}

// --- round-trip -------------------------------------------------

Test.describe("round-trip") {
  Test.it("parse(encode(x)) == x for simple maps") {
    var original = {"name": "app", "port": 8080, "ratio": 1.5, "on": true}
    var encoded = Toml.encode(original)
    var reparsed = Toml.parse(encoded)
    Expect.that(reparsed["name"]).toBe("app")
    Expect.that(reparsed["port"]).toBe(8080)
    Expect.that(reparsed["ratio"]).toBe(1.5)
    Expect.that(reparsed["on"]).toBe(true)
  }
  Test.it("nested tables round-trip") {
    var original = {"db": {"host": "x", "port": 5432}}
    var reparsed = Toml.parse(Toml.encode(original))
    Expect.that(reparsed["db"]["host"]).toBe("x")
    Expect.that(reparsed["db"]["port"]).toBe(5432)
  }
}

Test.run()
