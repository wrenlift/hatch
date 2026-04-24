import "./web"         for App, Router, Request, Response
import "@hatch:test"   for Test
import "@hatch:assert" for Expect

// --- helpers --------------------------------------------------

var fakeReq = Fn.new {|method, path|
  Request.new_(method, path, "", {}, "", null)
}

var fakeReqWithQuery = Fn.new {|method, path, query|
  Request.new_(method, path, query, {}, "", null)
}

// --- Router matching ------------------------------------------

Test.describe("Router") {
  Test.it("matches a literal path") {
    var app = App.new()
    app.get("/") {|req| "home" }
    var r = app.handle(fakeReq.call("GET", "/"))
    Expect.that(r.status).toBe(200)
    Expect.that(r.body).toContain("home")
  }

  Test.it("captures a single :param") {
    var app = App.new()
    app.get("/posts/:id") {|req| "post=" + req.param("id") }
    var r = app.handle(fakeReq.call("GET", "/posts/42"))
    Expect.that(r.body).toContain("post=42")
  }

  Test.it("captures multiple params") {
    var app = App.new()
    app.get("/u/:user/posts/:id") {|req|
      req.param("user") + "/" + req.param("id")
    }
    var r = app.handle(fakeReq.call("GET", "/u/ann/posts/7"))
    Expect.that(r.body).toContain("ann/7")
  }

  Test.it("method filter") {
    var app = App.new()
    app.get("/") {|req| "G" }
    app.post("/") {|req| "P" }
    Expect.that(app.handle(fakeReq.call("GET", "/")).body).toContain("G")
    Expect.that(app.handle(fakeReq.call("POST", "/")).body).toContain("P")
  }

  Test.it("404 on miss") {
    var app = App.new()
    app.get("/a") {|req| "a" }
    var r = app.handle(fakeReq.call("GET", "/b"))
    Expect.that(r.status).toBe(404)
  }

  Test.it("mount subrouter under prefix") {
    var api = Router.new_("/api")
    api.get("/users") {|req| "users" }
    api.get("/users/:id") {|req| "user=" + req.param("id") }
    var app = App.new()
    app.mount(api)
    Expect.that(app.handle(fakeReq.call("GET", "/api/users")).body).toContain("users")
    Expect.that(app.handle(fakeReq.call("GET", "/api/users/9")).body).toContain("user=9")
  }
}

// --- Request helpers ------------------------------------------

Test.describe("Request") {
  Test.it("parses query string lazily") {
    var req = fakeReqWithQuery.call("GET", "/search", "q=hello&page=2")
    Expect.that(req.query["q"]).toBe("hello")
    Expect.that(req.query["page"]).toBe("2")
  }

  Test.it("url-decodes query values") {
    var req = fakeReqWithQuery.call("GET", "/", "name=ann%20smith&tag=%23one")
    Expect.that(req.query["name"]).toBe("ann smith")
    Expect.that(req.query["tag"]).toBe("#one")
  }

  Test.it("case-insensitive header lookup") {
    var req = Request.new_("GET", "/", "", {"X-Custom": "yep"}, "", null)
    Expect.that(req.header("x-custom")).toBe("yep")
    Expect.that(req.header("X-CUSTOM")).toBe("yep")
    Expect.that(req.header("missing")).toBe(null)
  }

  Test.it("detects htmx request") {
    var req = Request.new_("GET", "/", "", {"HX-Request": "true"}, "", null)
    Expect.that(req.isHx).toBe(true)
    Expect.that(req.hx["request"]).toBe(true)
  }

  Test.it("parses form body") {
    var req = Request.new_("POST", "/", "", {}, "name=ann&age=30", null)
    Expect.that(req.form["name"]).toBe("ann")
    Expect.that(req.form["age"]).toBe("30")
  }
}

// --- Response builder -----------------------------------------

Test.describe("Response") {
  Test.it("defaults to 200") {
    var r = Response.new()
    Expect.that(r.status).toBe(200)
  }

  Test.it("html() sets content-type + body") {
    var r = Response.new().html("<p>hi</p>")
    Expect.that(r.headers["Content-Type"]).toContain("text/html")
    Expect.that(r.body).toBe("<p>hi</p>")
  }

  Test.it("redirect() emits Location + 302") {
    var r = Response.redirect("/login")
    Expect.that(r.status).toBe(302)
    Expect.that(r.headers["Location"]).toBe("/login")
  }

  Test.it("cookie() stacks Set-Cookie") {
    var r = Response.new().cookie("sid", "abc", {"httpOnly": true, "path": "/"})
    r.cookie("theme", "dark", {})
    Expect.that(r.cookies_.count).toBe(2)
    Expect.that(r.cookies_[0]).toContain("sid=abc")
    Expect.that(r.cookies_[0]).toContain("HttpOnly")
    Expect.that(r.cookies_[1]).toContain("theme=dark")
  }

  Test.it("coerce String → 200 html") {
    var r = Response.coerce("hello")
    Expect.that(r.status).toBe(200)
    Expect.that(r.body).toBe("hello")
  }

  Test.it("coerce null → 204") {
    Expect.that(Response.coerce(null).status).toBe(204)
  }
}

// --- Middleware pipeline --------------------------------------

Test.describe("middleware") {
  Test.it("runs outermost-first and short-circuits") {
    var app = App.new()
    var log = []
    app.use(Fn.new {|req, next|
      log.add("before-1")
      var r = next.call(req)
      log.add("after-1")
      return r
    })
    app.use(Fn.new {|req, next|
      log.add("before-2")
      var r = next.call(req)
      log.add("after-2")
      return r
    })
    app.get("/") {|req|
      log.add("handler")
      return "ok"
    }
    app.handle(fakeReq.call("GET", "/"))
    Expect.that(log).toEqual(["before-1", "before-2", "handler", "after-2", "after-1"])
  }

  Test.it("middleware can short-circuit") {
    var app = App.new()
    app.use(Fn.new {|req, next| Response.new(401).text("nope") })
    app.get("/") {|req| "secret" }
    var r = app.handle(fakeReq.call("GET", "/"))
    Expect.that(r.status).toBe(401)
    Expect.that(r.body).toBe("nope")
  }

  Test.it("errors in handler land at error() hook") {
    var app = App.new()
    app.error(Fn.new {|req, err| Response.new(500).text("oops:%(err)") })
    app.get("/") {|req| Fiber.abort("boom") }
    var r = app.handle(fakeReq.call("GET", "/"))
    Expect.that(r.status).toBe(500)
    Expect.that(r.body).toContain("oops:boom")
  }
}

Test.run()
