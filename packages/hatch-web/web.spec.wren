import "./web"         for App, Router, Request, Response, Session, Csrf, Static, Flash
import "./css"         for Css
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
    var r = Response.new(200)
    Expect.that(r.status).toBe(200)
  }

  Test.it("html() sets content-type + body") {
    var r = Response.new(200).html("<p>hi</p>")
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

// --- Session (signed cookie) ----------------------------------

Test.describe("Session") {
  Test.it("empty when no cookie present") {
    var app = App.new()
    app.use(Session.cookie("shh"))
    app.get("/") {|req|
      Expect.that(req.session is Map).toBe(true)
      Expect.that(req.session.count).toBe(0)
      return "ok"
    }
    app.handle(fakeReq.call("GET", "/"))
  }

  Test.it("round-trips across requests via Cookie header") {
    var secret = "top-secret"
    var app = App.new()
    app.use(Session.cookie(secret))
    app.get("/login") {|req|
      req.session["user"] = "ann"
      return "logged in"
    }
    app.get("/who") {|req|
      return req.session.containsKey("user") ? "hi %(req.session["user"])" : "anonymous"
    }

    // 1st request: login writes Set-Cookie.
    var resp = app.handle(fakeReq.call("GET", "/login"))
    Expect.that(resp.cookies_.count).toBe(1)
    Expect.that(resp.cookies_[0]).toContain("_session=")

    // Extract the cookie value (name=value before first semicolon).
    var raw = resp.cookies_[0]
    var semi = 0
    while (semi < raw.count && raw[semi] != ";") semi = semi + 1
    var cookieValue = raw[9..(semi - 1)] // after "_session="

    // 2nd request: carry the cookie, session should have `user`.
    var req2 = Request.new_("GET", "/who", "", {"Cookie": "_session=%(cookieValue)"}, "", null)
    var resp2 = app.handle(req2)
    Expect.that(resp2.body).toContain("hi ann")
  }

  Test.it("tampered cookie is rejected, session is empty") {
    var secret = "top-secret"
    var app = App.new()
    app.use(Session.cookie(secret))
    app.get("/who") {|req|
      return req.session.containsKey("user") ? "has-user" : "anon"
    }
    // Forge a cookie — payload but wrong signature.
    var forged = "eyJ1c2VyIjoiZXZlIn0.bogus-signature"
    var req = Request.new_("GET", "/who", "", {"Cookie": "_session=%(forged)"}, "", null)
    var resp = app.handle(req)
    Expect.that(resp.body).toContain("anon")
  }

  Test.it("different secret rejects old cookies") {
    var req = Request.new_("GET", "/", "", {}, "", null)
    // Sign with secret A.
    var signed = Session.sign_("A", "{\"foo\":1}")
    Expect.that(Session.verify_("A", signed)).toBe("{\"foo\":1}")
    Expect.that(Session.verify_("B", signed)).toBe(null)
  }
}

// --- Flash ----------------------------------------------------

Test.describe("Flash") {
  Test.it("survives exactly one redirect") {
    var secret = "flash-secret"
    var app = App.new()
    app.use(Session.cookie(secret))
    app.get("/login") {|req|
      req.setFlash("notice", "welcome")
      return Response.redirect("/home")
    }
    app.get("/home") {|req|
      var msg = req.flash.containsKey("notice") ? req.flash["notice"] : "(none)"
      return "flash=%(msg)"
    }

    // POST-like: sets flash.
    var r1 = app.handle(fakeReq.call("GET", "/login"))
    var raw = r1.cookies_[0]
    var semi = 0
    while (semi < raw.count && raw[semi] != ";") semi = semi + 1
    var cookieValue = raw[9..(semi - 1)]  // after "_session="

    // Follow redirect with cookie; flash should appear.
    var req2 = Request.new_("GET", "/home", "", {"Cookie": "_session=%(cookieValue)"}, "", null)
    var r2 = app.handle(req2)
    Expect.that(r2.body).toContain("flash=welcome")

    // Same session cookie on a THIRD request — flash should be gone.
    var raw2 = r2.cookies_[0]
    var semi2 = 0
    while (semi2 < raw2.count && raw2[semi2] != ";") semi2 = semi2 + 1
    var cv2 = raw2[9..(semi2 - 1)]
    var req3 = Request.new_("GET", "/home", "", {"Cookie": "_session=%(cv2)"}, "", null)
    var r3 = app.handle(req3)
    Expect.that(r3.body).toContain("flash=(none)")
  }
}

// --- CSRF -----------------------------------------------------

Test.describe("Csrf") {
  Test.it("GET requests pass through") {
    var app = App.new()
    app.use(Session.cookie("sec"))
    app.use(Csrf.middleware)
    app.get("/")  {|req| "ok" }
    var r = app.handle(fakeReq.call("GET", "/"))
    Expect.that(r.status).toBe(200)
  }

  Test.it("POST without token → 403") {
    var app = App.new()
    app.use(Session.cookie("sec"))
    app.use(Csrf.middleware)
    app.post("/submit") {|req| "accepted" }
    var r = app.handle(fakeReq.call("POST", "/submit"))
    Expect.that(r.status).toBe(403)
    Expect.that(r.body).toContain("CSRF")
  }

  Test.it("POST with matching form token passes") {
    var secret = "sec"
    var app = App.new()
    app.use(Session.cookie(secret))
    app.use(Csrf.middleware)
    app.get("/form")   {|req| Csrf.field(req) }  // prime a token
    app.post("/submit") {|req| "ok" }

    // Prime: get a session + token.
    var r1 = app.handle(fakeReq.call("GET", "/form"))
    // Dig out the token from the emitted hidden field.
    var body = r1.body
    var vIdx = 0
    var key = "value=\""
    while (vIdx + key.count < body.count && body[vIdx..(vIdx + key.count - 1)] != key) {
      vIdx = vIdx + 1
    }
    var start = vIdx + key.count
    var end = start
    while (end < body.count && body[end] != "\"") end = end + 1
    var token = body[start..(end - 1)]

    // Re-use the cookie from the first response.
    var raw = r1.cookies_[0]
    var semi = 0
    while (semi < raw.count && raw[semi] != ";") semi = semi + 1
    var cookieValue = raw[9..(semi - 1)]

    var req2 = Request.new_(
      "POST", "/submit", "",
      {"Cookie": "_session=%(cookieValue)", "Content-Type": "application/x-www-form-urlencoded"},
      "_csrf=%(token)&other=1",
      null)
    var r2 = app.handle(req2)
    Expect.that(r2.status).toBe(200)
    Expect.that(r2.body).toContain("ok")
  }
}

// --- Static ---------------------------------------------------

Test.describe("Static") {
  Test.it("rejects path traversal") {
    var app = App.new()
    app.use(Static.serve("/assets", "/tmp"))
    app.get("/") {|req| "fallback" }
    var r = app.handle(fakeReq.call("GET", "/assets/../etc/passwd"))
    Expect.that(r.status).toBe(403)
  }

  Test.it("passes unmatched prefix through") {
    var app = App.new()
    app.use(Static.serve("/assets", "/tmp"))
    app.get("/other") {|req| "dynamic" }
    var r = app.handle(fakeReq.call("GET", "/other"))
    Expect.that(r.status).toBe(200)
    Expect.that(r.body).toContain("dynamic")
  }

  Test.it("mime type inference") {
    Expect.that(Static.mimeOf_("style.css")).toContain("text/css")
    Expect.that(Static.mimeOf_("app.js")).toContain("javascript")
    Expect.that(Static.mimeOf_("page.html")).toContain("text/html")
    Expect.that(Static.mimeOf_("img.png")).toBe("image/png")
    Expect.that(Static.mimeOf_("unknown.xyz")).toBe("application/octet-stream")
    Expect.that(Static.mimeOf_("no-extension")).toBe("application/octet-stream")
  }
}

// --- Css integration ------------------------------------------

Test.describe("Css integration with Request/App") {
  Test.it("req.style(..) registers on fragment sheet") {
    var app = App.new()
    app.get("/") {|req|
      req.style(Css.tw("p-4"))
      req.style(Css.tw("text-red-500"))
      Expect.that(req.fragmentSheet.count).toBe(2)
      return "ok"
    }
    app.handle(fakeReq.call("GET", "/"))
  }

  Test.it("app.globalCss registers on app sheet") {
    var app = App.new()
    app.globalCss(Css.tw("font-bold"))
    app.globalCss(Css.tw("font-bold"))  // dedup
    Expect.that(app.globalSheet.count).toBe(1)
  }

  Test.it("globalSheet reaches request via handle()") {
    var app = App.new()
    app.globalCss(Css.tw("text-gray-900"))
    app.get("/") {|req|
      Expect.that(req.globalSheet).toBe(app.globalSheet)
      return "ok"
    }
    app.handle(fakeReq.call("GET", "/"))
  }
}

Test.run()
