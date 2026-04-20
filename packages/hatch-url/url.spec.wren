import "./url"         for Url
import "@hatch:test"   for Test
import "@hatch:assert" for Expect

Test.describe("parse: full URL") {
  Test.it("captures every component") {
    var u = Url.parse("https://user:pass@example.com:8080/api/v1?q=s&n=10#top")
    Expect.that(u.scheme).toBe("https")
    Expect.that(u.username).toBe("user")
    Expect.that(u.password).toBe("pass")
    Expect.that(u.host).toBe("example.com")
    Expect.that(u.port).toBe(8080)
    Expect.that(u.path).toBe("/api/v1")
    Expect.that(u.query).toBe("q=s&n=10")
    Expect.that(u.fragment).toBe("top")
  }
  Test.it("minimal scheme+host URL") {
    var u = Url.parse("https://example.com")
    Expect.that(u.scheme).toBe("https")
    Expect.that(u.host).toBe("example.com")
    Expect.that(u.path).toBe("")
    Expect.that(u.query).toBe(null)
    Expect.that(u.fragment).toBe(null)
  }
  Test.it("path-only URL") {
    var u = Url.parse("https://example.com/foo")
    Expect.that(u.path).toBe("/foo")
  }
  Test.it("userinfo without password") {
    var u = Url.parse("ssh://alice@server.io")
    Expect.that(u.username).toBe("alice")
    Expect.that(u.password).toBe(null)
  }
}

Test.describe("parse: errors") {
  Test.it("empty string aborts") {
    var e = Fiber.new { Url.parse("") }.try()
    Expect.that(e).toContain("empty")
  }
  Test.it("missing scheme aborts") {
    var e = Fiber.new { Url.parse("example.com/foo") }.try()
    Expect.that(e).toContain("missing")
  }
  Test.it("bad port aborts") {
    var e = Fiber.new { Url.parse("http://host:notaport/") }.try()
    Expect.that(e).toContain("port")
  }
}

Test.describe("queryMap") {
  Test.it("builds a map from the query string") {
    var u = Url.parse("https://x/y?a=1&b=two&c=three")
    var m = u.queryMap
    Expect.that(m["a"]).toBe("1")
    Expect.that(m["b"]).toBe("two")
    Expect.that(m["c"]).toBe("three")
  }
  Test.it("handles key-without-value") {
    var u = Url.parse("https://x/y?flag&a=1")
    Expect.that(u.queryMap["flag"]).toBe("")
    Expect.that(u.queryMap["a"]).toBe("1")
  }
  Test.it("empty queryMap on missing query") {
    var u = Url.parse("https://x/y")
    Expect.that(u.queryMap.count).toBe(0)
  }
}

Test.describe("toString roundtrip") {
  Test.it("simple URL roundtrips") {
    var s = "https://example.com/api"
    Expect.that(Url.parse(s).toString).toBe(s)
  }
  Test.it("full URL roundtrips") {
    var s = "https://user:pass@example.com:8080/api?q=s#f"
    // Encode applies to username/password, which were decoded on
    // parse; they're plain ASCII here so the roundtrip is clean.
    Expect.that(Url.parse(s).toString).toBe(s)
  }
}

Test.describe("encode / decode") {
  Test.it("encode percent-escapes reserved chars") {
    Expect.that(Url.encode("a b/c")).toBe("a%20b%2Fc")
    Expect.that(Url.encode("?=&")).toBe("%3F%3D%26")
  }
  Test.it("encode leaves unreserved alone") {
    Expect.that(Url.encode("abcXYZ123-._~")).toBe("abcXYZ123-._~")
  }
  Test.it("decode reverses encode") {
    Expect.that(Url.decode("a%20b%2Fc")).toBe("a b/c")
    Expect.that(Url.decode("%3F%3D%26")).toBe("?=&")
  }
  Test.it("decode treats '+' as space") {
    Expect.that(Url.decode("a+b")).toBe("a b")
  }
  Test.it("decode handles UTF-8 roundtrip") {
    var s = "héllo"
    Expect.that(Url.decode(Url.encode(s))).toBe(s)
  }
  Test.it("decode rejects truncated escape") {
    var e = Fiber.new { Url.decode("a%2") }.try()
    Expect.that(e).toContain("truncated")
  }
}

Test.describe("query encoding") {
  Test.it("decodeQuery parses k=v pairs") {
    var m = Url.decodeQuery("a=1&b=two")
    Expect.that(m["a"]).toBe("1")
    Expect.that(m["b"]).toBe("two")
  }
  Test.it("decodeQuery decodes percent-escaped values") {
    var m = Url.decodeQuery("q=hello%20world")
    Expect.that(m["q"]).toBe("hello world")
  }
  Test.it("encodeQuery escapes both keys and values") {
    // Map iteration order isn't guaranteed; check that each pair
    // appears rather than the exact string.
    var s = Url.encodeQuery({"a b": "x y"})
    Expect.that(s).toContain("a%20b=x%20y")
  }
  Test.it("empty input → empty output") {
    Expect.that(Url.decodeQuery("").count).toBe(0)
    Expect.that(Url.encodeQuery({})).toBe("")
  }
}

Test.run()
