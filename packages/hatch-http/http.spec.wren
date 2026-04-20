import "./http"        for Http, Response
import "@hatch:test"   for Test
import "@hatch:assert" for Expect
import "@hatch:json"   for JSON

// --- Offline: Response shape ----------------------------------

Test.describe("Response") {
  Test.it("ok() true for 2xx") {
    var r = Response.new_(200, {"content-type": ["text/plain"]}, "hi")
    Expect.that(r.ok).toBe(true)
  }
  Test.it("ok() false for 4xx / 5xx") {
    Expect.that(Response.new_(404, {}, "").ok).toBe(false)
    Expect.that(Response.new_(500, {}, "").ok).toBe(false)
  }
  Test.it("header() returns first value, case-insensitive") {
    var r = Response.new_(200, {"content-type": ["text/plain"]}, "")
    Expect.that(r.header("Content-Type")).toBe("text/plain")
    Expect.that(r.header("CONTENT-TYPE")).toBe("text/plain")
    Expect.that(r.header("missing")).toBe(null)
  }
  Test.it("headers() returns the full list, case-insensitive") {
    var r = Response.new_(200, {"set-cookie": ["a=1", "b=2"]}, "")
    Expect.that(r.headers("Set-Cookie")).toEqual(["a=1", "b=2"])
    Expect.that(r.headers("Missing")).toEqual([])
  }
  Test.it("json parses the body") {
    var r = Response.new_(200, {}, "{\"a\":1}")
    Expect.that(r.json["a"]).toBe(1)
  }
}

// --- Offline: header validation --------------------------------

Test.describe("header validation") {
  Test.it("invalid header name aborts with a clean message") {
    var e = Fiber.new {
      Http.get("https://example.com", {"headers": {"bad name": "x"}})
    }.try()
    Expect.that(e).toContain("invalid header name")
    Expect.that(e).toContain("bad name")
  }
  Test.it("CRLF in header value aborts") {
    var e = Fiber.new {
      Http.get("https://example.com", {"headers": {"X-Bad": "x\r\ny"}})
    }.try()
    Expect.that(e).toContain("invalid header value")
  }
  Test.it("non-list, non-string value aborts") {
    var e = Fiber.new {
      Http.get("https://example.com", {"headers": {"X-N": 42}})
    }.try()
    Expect.that(e).toContain("string or list")
  }
  Test.it("body + json raises a usage error") {
    var e = Fiber.new {
      Http.post("https://example.com", {"body": "x", "json": {}})
    }.try()
    Expect.that(e).toContain("at most one")
  }
}

// --- Online: hits httpbin.org. Skipped if HATCH_OFFLINE is set.

import "os" for OS

var online = OS.env("HATCH_OFFLINE") == null

if (online) {
  Test.describe("GET / query / headers") {
    Test.it("reflects query params") {
      var r = Http.get("https://httpbin.org/get", {
        "query": {"a": 1, "b": "two"},
        "timeout": 15
      })
      Expect.that(r.status).toBe(200)
      var args = r.json["args"]
      Expect.that(args["a"]).toBe("1")
      Expect.that(args["b"]).toBe("two")
    }
    Test.it("reflects custom headers") {
      var r = Http.get("https://httpbin.org/headers", {
        "headers": {"X-Hatch": "yes"},
        "timeout": 15
      })
      Expect.that(r.status).toBe(200)
      Expect.that(r.json["headers"]["X-Hatch"]).toBe("yes")
    }
    Test.it("multi-value header comma-joins on the wire") {
      var r = Http.get("https://httpbin.org/headers", {
        "headers": {"Accept": ["application/json", "text/plain"]},
        "timeout": 15
      })
      Expect.that(r.json["headers"]["Accept"])
        .toBe("application/json, text/plain")
    }
  }

  Test.describe("POST bodies") {
    Test.it("json body: serialises and echoes") {
      var r = Http.post("https://httpbin.org/post", {
        "json": {"name": "alice", "n": 3},
        "timeout": 15
      })
      Expect.that(r.status).toBe(200)
      var echoed = r.json["json"]
      Expect.that(echoed["name"]).toBe("alice")
      Expect.that(echoed["n"]).toBe(3)
    }
    Test.it("json body sets Content-Type automatically") {
      var r = Http.post("https://httpbin.org/post", {
        "json": {},
        "timeout": 15
      })
      Expect.that(r.json["headers"]["Content-Type"]).toContain("application/json")
    }
    Test.it("form body urlencodes and sets Content-Type") {
      var r = Http.post("https://httpbin.org/post", {
        "form": {"name": "alice", "age": "30"},
        "timeout": 15
      })
      var form = r.json["form"]
      Expect.that(form["name"]).toBe("alice")
      Expect.that(form["age"]).toBe("30")
      Expect.that(r.json["headers"]["Content-Type"])
        .toContain("application/x-www-form-urlencoded")
    }
    Test.it("raw body passes through verbatim") {
      var r = Http.post("https://httpbin.org/post", {
        "body": "raw text!",
        "headers": {"Content-Type": "text/plain"},
        "timeout": 15
      })
      Expect.that(r.json["data"]).toContain("raw text!")
    }
  }

  Test.describe("auth shortcuts") {
    Test.it("bearer adds Authorization: Bearer") {
      var r = Http.get("https://httpbin.org/bearer", {
        "bearer": "abc123",
        "timeout": 15
      })
      Expect.that(r.status).toBe(200)
      Expect.that(r.json["token"]).toBe("abc123")
    }
    Test.it("basicAuth base64s user:pass") {
      var r = Http.get("https://httpbin.org/basic-auth/alice/secret", {
        "basicAuth": ["alice", "secret"],
        "timeout": 15
      })
      Expect.that(r.status).toBe(200)
      Expect.that(r.json["authenticated"]).toBe(true)
    }
  }

  Test.describe("user-agent + accept") {
    Test.it("userAgent overrides the default") {
      var r = Http.get("https://httpbin.org/user-agent", {
        "userAgent": "hatch-http-test/1.0",
        "timeout": 15
      })
      Expect.that(r.json["user-agent"]).toBe("hatch-http-test/1.0")
    }
    Test.it("accept shortcut sets Accept header") {
      var r = Http.get("https://httpbin.org/headers", {
        "accept": "application/xml",
        "timeout": 15
      })
      Expect.that(r.json["headers"]["Accept"]).toBe("application/xml")
    }
  }

  Test.describe("response") {
    Test.it("404 non-error: status exposed, ok false") {
      var r = Http.get("https://httpbin.org/status/404", {"timeout": 15})
      Expect.that(r.status).toBe(404)
      Expect.that(r.ok).toBe(false)
    }
    Test.it("multi-value response header preserves every value") {
      var r = Http.get(
        "https://httpbin.org/response-headers?X-Custom=one&X-Custom=two",
        {"timeout": 15}
      )
      Expect.that(r.headers("X-Custom")).toEqual(["one", "two"])
    }
  }

  Test.describe("streaming") {
    Test.it("stream exposes status + headers immediately; body reads lazily") {
      var sr = Http.getStream("https://httpbin.org/get", {"timeout": 15})
      Expect.that(sr.status).toBe(200)
      // Headers are populated before we touch the body.
      Expect.that(sr.header("content-type")).toContain("application/json")
      // Drain the body via the Reader. Full payload should
      // round-trip back into a parseable JSON string.
      var body = sr.body.readAll.toString
      var parsed = JSON.parse(body)
      Expect.that(parsed["url"]).toContain("/get")
    }
    Test.it("close before EOF is safe") {
      var sr = Http.getStream("https://httpbin.org/get", {"timeout": 15})
      Expect.that(sr.status).toBe(200)
      // Read a tiny slice and close without draining.
      var chunk = sr.body.read(4)
      Expect.that(chunk.count > 0).toBe(true)
      sr.close
      sr.close   // idempotent
    }
    Test.it("chunked SSE-ish endpoint yields lines as they arrive") {
      // httpbin /stream/N sends N JSON objects, one per line.
      var sr = Http.getStream("https://httpbin.org/stream/3", {"timeout": 15})
      var lines = []
      var line = sr.body.readLine
      while (line != null) {
        lines.add(line)
        line = sr.body.readLine
      }
      Expect.that(lines.count).toBe(3)
    }
  }

}

Test.run()
