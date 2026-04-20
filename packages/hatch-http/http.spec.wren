import "./http"        for Http, Response
import "@hatch:test"   for Test
import "@hatch:assert" for Expect

// --- Offline: Response shape ----------------------------------

Test.describe("Response") {
  Test.it("ok() true for 2xx") {
    var r = Response.new_(200, {"content-type": "text/plain"}, "hi")
    Expect.that(r.ok).toBe(true)
  }
  Test.it("ok() false for 4xx / 5xx") {
    Expect.that(Response.new_(404, {}, "").ok).toBe(false)
    Expect.that(Response.new_(500, {}, "").ok).toBe(false)
  }
  Test.it("header() lookups are case-insensitive") {
    var r = Response.new_(200, {"content-type": "text/plain"}, "")
    Expect.that(r.header("Content-Type")).toBe("text/plain")
    Expect.that(r.header("CONTENT-TYPE")).toBe("text/plain")
    Expect.that(r.header("missing")).toBe(null)
  }
  Test.it("json parses the body") {
    var r = Response.new_(200, {}, "{\"a\":1}")
    Expect.that(r.json["a"]).toBe(1)
  }
}

// --- Online: hits httpbin.org. Skipped if env var HATCH_OFFLINE
// is set (lets CI run without network). ----------------------

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
  }

  Test.describe("POST json body") {
    Test.it("serialises and echoes a JSON payload") {
      var r = Http.post("https://httpbin.org/post", {
        "json": {"name": "alice", "n": 3},
        "timeout": 15
      })
      Expect.that(r.status).toBe(200)
      var echoed = r.json["json"]
      Expect.that(echoed["name"]).toBe("alice")
      Expect.that(echoed["n"]).toBe(3)
    }
    Test.it("sets Content-Type: application/json automatically") {
      var r = Http.post("https://httpbin.org/post", {
        "json": {},
        "timeout": 15
      })
      var got = r.json["headers"]["Content-Type"]
      Expect.that(got).toContain("application/json")
    }
  }

  Test.describe("status codes") {
    Test.it("exposes 404 without aborting") {
      var r = Http.get("https://httpbin.org/status/404", {"timeout": 15})
      Expect.that(r.status).toBe(404)
      Expect.that(r.ok).toBe(false)
    }
  }
}

Test.run()
