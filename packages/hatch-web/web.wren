// @hatch:web — server-rendered, htmx-native web framework.
//
// The shape:
//
//   import "@hatch:web" for App
//   import "@hatch:template" for Template
//
//   var tpl = Template.parse("<h1>Hello {{ name }}</h1>")
//   var app = App.new()
//   app.get("/")            {|req| req.render(tpl, { "name": "world" }) }
//   app.get("/hi/:who")     {|req| "Hi %(req.param("who"))!" }
//   app.listen("127.0.0.1:3000")
//
// Routes receive a Request and may return:
//   * a String             — 200 text/html body
//   * a Response           — full control
//   * an HxResponse        — @hatch:template builder
//   * null                 — 204 No Content
//
// Middleware is a Fn taking (req, next): next.call(req) forwards,
// anything else short-circuits. Middleware run outermost-first,
// handler innermost.
//
// HTTP/1.1 cleartext on top of @hatch:socket — no TLS, no h2,
// no WebSockets yet. Content-Length bodies only (chunked TE
// comes later). One request per connection (no keep-alive) to
// keep the Phase 1 parser honest; pipelining/keep-alive next.

import "@hatch:socket"   for TcpListener
import "@hatch:template" for Hx, HxResponse, Template
import "@hatch:hash"     for Hash
import "@hatch:json"     for JSON
import "@hatch:crypto"   for Crypto
import "@hatch:fs"       for Fs
import "./css"           for Css, Style, Stylesheet

// ── Request ─────────────────────────────────────────────────────────────
//
// Immutable view of one HTTP/1.1 request. Path params populate
// after the router matches, so `param("id")` works inside the
// handler without re-parsing. Query string is parsed lazily on
// first access.

class Request {
  construct new_(method, path, query, headers, body, remote) {
    _method     = method
    _path       = path
    _rawQuery   = query
    _headers    = headers
    _body       = body
    _remote     = remote
    _params     = {}     // filled by Router
    _queryCache = null
    _formCache  = null
    _hxCache    = null
    _session    = null   // filled by Session middleware
    _flash      = null   // incoming flash (read-only for handler)
    _flashNext  = null   // outgoing flash (written by handler via setFlash)
    _fragSheet  = null   // fragment-scoped Stylesheet (lazy)
    _globalSheet = null  // reference to app's global sheet (set by App.handle)
  }

  method    { _method }
  path      { _path }
  headers   { _headers }
  body      { _body }       // String
  remote    { _remote }     // peer addr or null
  params    { _params }
  rawQuery  { _rawQuery }
  session   { _session }
  flash     { _flash }
  flashNext { _flashNext }

  session=(s)   { _session = s }
  flash=(f)     { _flash = f }
  flashNext=(f) { _flashNext = f }

  // Add a one-shot flash visible to the next request.
  //
  //   req.setFlash("notice", "Saved!")
  //   return Response.redirect("/")
  setFlash(key, value) {
    if (_flashNext == null) _flashNext = {}
    _flashNext[key] = value
  }

  // Fragment-scoped stylesheet. Lazily created on first access.
  // Styles added here are injected inline with the fragment's
  // HTML, so htmx swaps bring them along without leaking globally.
  //
  //   var btn = Css.tw("bg-blue-500 text-white px-4 py-2 rounded")
  //   req.style(btn)                               // register
  //   return "<button class='%(btn.className)'>ok</button>"
  fragmentSheet {
    if (_fragSheet == null) _fragSheet = Stylesheet.new()
    return _fragSheet
  }

  // Register a Style (or multiple) on the request-scoped sheet.
  // Returns the first Style for chainable use at the call site.
  style(s) {
    fragmentSheet.add(s)
    return s
  }

  // Internal — App.handle sets this so render() can include the
  // app's global CSS alongside the fragment CSS.
  globalSheet=(s) { _globalSheet = s }
  globalSheet    { _globalSheet }

  // Route parameters captured by the router (/posts/:id → req.param("id")).
  param(name) { _params.containsKey(name) ? _params[name] : null }

  // Parsed `?a=1&b=2` query as a Map. Repeated keys: last-one-wins
  // (good enough for Phase 1; `queryAll` can come later).
  query {
    if (_queryCache != null) return _queryCache
    _queryCache = Http_.parseForm(_rawQuery)
    return _queryCache
  }

  // application/x-www-form-urlencoded body parsed into a Map.
  // Triggered explicitly — we don't want to silently eat the body
  // for JSON/multipart requests.
  form {
    if (_formCache != null) return _formCache
    _formCache = Http_.parseForm(_body == null ? "" : _body)
    return _formCache
  }

  // Single header value (case-insensitive). Returns null if absent.
  header(name) {
    var wanted = Http_.lower(name)
    for (k in _headers.keys) {
      if (Http_.lower(k) == wanted) return _headers[k]
    }
    return null
  }

  // htmx request context — `request`, `boosted`, `target`,
  // `trigger`, `triggerName`, `currentUrl`. Cached.
  hx {
    if (_hxCache != null) return _hxCache
    _hxCache = Hx.context(_headers)
    return _hxCache
  }

  // Convenience — most handlers just want to know "is this htmx?"
  isHx { hx["request"] == true }

  // Render a Template against a context. Content-negotiates:
  // if the request is htmx, we let the template expose `hx` so
  // it can pick a fragment; otherwise it renders the full page.
  // Accepts either a Template or a template name (when the app
  // carries a TemplateRegistry — not wired yet in Phase 1).
  //
  // CSS: both sheets are threaded into the context so the
  // template can include them in the right spot. Full-page
  // responses get both (global in <head>, fragment in <body>);
  // htmx-fragment responses get fragment-only (the global
  // sheet is already on the page). Handlers that don't register
  // any Styles just see empty strings.
  render(tpl, context) {
    var ctx = context == null ? {} : context
    ctx["#hx"] = hx
    var isHtmx = hx["request"] == true
    var fragCss = _fragSheet == null ? "" : _fragSheet.styleTag
    var globalCss = ""
    if (!isHtmx && _globalSheet != null) {
      globalCss = _globalSheet.styleTag
    }
    ctx["#css"]       = fragCss
    ctx["#cssGlobal"] = globalCss
    var body = tpl.render(ctx)
    var resp = Response.new(200).html(body)
    return resp
  }
  render(tpl) { render(tpl, null) }

  // Helper to promote this into a mutable Params map. Router uses it.
  setParam_(k, v) { _params[k] = v }
}

// ── Response ────────────────────────────────────────────────────────────
//
// Mutable builder. Methods chain. An HxResponse returned from a
// handler is "just" a Response carrying the body + hx headers,
// so the two are interchangeable at the edge.

class Response {
  construct new() { init_(200, {}, "") }
  construct new(status) { init_(status, {}, "") }
  construct new(status, body) { init_(status, {}, body) }

  init_(status, headers, body) {
    _status = status
    _headers = headers
    _body = body
    _cookies = []      // list of raw Set-Cookie values
  }

  status { _status }
  body { _body }
  headers { _headers }
  cookies_ { _cookies }

  status=(s) { _status = s }
  body=(b) {
    _body = b
    this
  }

  header(name, value) {
    _headers[name] = value
    return this
  }

  // Set-Cookie — supports the common attributes. Multiple calls
  // stack (you can set multiple cookies on one response).
  cookie(name, value) { cookie(name, value, {}) }
  cookie(name, value, opts) {
    var raw = name + "=" + value
    if (opts.containsKey("path"))     raw = raw + "; Path=" + opts["path"]
    if (opts.containsKey("domain"))   raw = raw + "; Domain=" + opts["domain"]
    if (opts.containsKey("maxAge"))   raw = raw + "; Max-Age=" + opts["maxAge"].toString
    if (opts.containsKey("expires"))  raw = raw + "; Expires=" + opts["expires"]
    if (opts.containsKey("httpOnly")) raw = raw + "; HttpOnly"
    if (opts.containsKey("secure"))   raw = raw + "; Secure"
    if (opts.containsKey("sameSite")) raw = raw + "; SameSite=" + opts["sameSite"]
    _cookies.add(raw)
    return this
  }

  // Convenience setters.
  html(s) {
    _headers["Content-Type"] = "text/html; charset=utf-8"
    _body = s
    return this
  }
  text(s) {
    _headers["Content-Type"] = "text/plain; charset=utf-8"
    _body = s
    return this
  }
  json(s) {
    _headers["Content-Type"] = "application/json"
    _body = s
    return this
  }

  static redirect(url)          { redirect(url, 302) }
  static redirect(url, status)  {
    var r = Response.new(status)
    r.header("Location", url)
    r.body = ""
    return r
  }

  // Coerce any handler return into a Response.
  static coerce(value) {
    if (value is Response) return value
    if (value is HxResponse) {
      var r = Response.new(200)
      r.html(value.body)
      for (k in value.headers.keys) r.header(k, value.headers[k])
      return r
    }
    if (value is String) return Response.new(200).html(value)
    if (value == null)   return Response.new(204)
    return Response.new(200).text(value.toString)
  }
}

// ── Router ──────────────────────────────────────────────────────────────
//
// Linear scan of registered routes. Path compilation splits on /
// and records which segments are `:params`. Matching is O(routes
// × avg-segments) — good enough up to hundreds of routes; a
// radix tree can come later without changing the API.

class Route_ {
  construct new_(method, pattern, handler) {
    _method  = method
    _segs    = Route_.compile_(pattern)
    _handler = handler
  }

  static compile_(pattern) {
    // "/posts/:id/edit" → [["lit","posts"], ["param","id"], ["lit","edit"]]
    var raw = pattern.split("/")
    var segs = []
    for (s in raw) {
      if (s != null && s != "") {
        if (s.startsWith(":")) {
          segs.add(["param", s[1..(s.count - 1)]])
        } else if (s == "*") {
          segs.add(["wild", null])
        } else {
          segs.add(["lit", s])
        }
      }
    }
    return segs
  }

  match_(method, path) {
    if (_method != "*" && _method != method) return null
    var raw = path.split("/")
    var parts = []
    for (s in raw) { if (s != "") parts.add(s) }
    var params = {}
    var i = 0
    while (i < _segs.count) {
      var seg = _segs[i]
      var kind = seg[0]
      if (kind == "wild") return params                 // rest matches
      if (i >= parts.count) return null
      if (kind == "lit") {
        if (parts[i] != seg[1]) return null
      } else {
        params[seg[1]] = parts[i]
      }
      i = i + 1
    }
    if (parts.count != _segs.count) return null
    return params
  }

  method  { _method }
  handler { _handler }
}

class Router {
  construct new() {
    _routes = []
    _prefix = ""
  }

  // For sub-routers. Prefix is prepended to every registration.
  construct new_(prefix) {
    _routes = []
    _prefix = prefix
  }

  routes { _routes }

  get(path, fn)    { add_("GET",    path, fn) }
  post(path, fn)   { add_("POST",   path, fn) }
  put(path, fn)    { add_("PUT",    path, fn) }
  patch(path, fn)  { add_("PATCH",  path, fn) }
  delete(path, fn) { add_("DELETE", path, fn) }
  any(path, fn)    { add_("*",      path, fn) }

  // Mount a sub-router at a prefix.
  //
  //   var admin = Router.new_("/admin")
  //   admin.get("/users") {|req| ... }
  //   app.mount(admin)
  mount(subRouter) {
    for (r in subRouter.routes) _routes.add(r)
  }

  add_(method, path, fn) {
    var full = _prefix + path
    _routes.add(Route_.new_(method, full, fn))
    return this
  }

  // Returns [handler, params] on match, null on miss.
  resolve(method, path) {
    for (r in _routes) {
      var params = r.match_(method, path)
      if (params != null) return [r.handler, params]
    }
    return null
  }
}

// ── Middleware pipeline ─────────────────────────────────────────────────
//
// Each middleware is a Fn(req, next) → anything-coercible-to-Response.
// `next.call(req)` invokes the rest of the chain. Short-circuit by
// returning without calling next.

class Pipeline_ {
  construct new_(stack, terminal) {
    _stack = stack
    _terminal = terminal
  }

  run(req) { step_(req, 0) }

  step_(req, i) {
    var stack    = _stack
    var terminal = _terminal
    var self     = this
    if (i >= stack.count) return terminal.call(req)
    var mw = stack[i]
    var next = Fn.new {|r| self.step_(r, i + 1) }
    return mw.call(req, next)
  }
}

// ── App ─────────────────────────────────────────────────────────────────

class App {
  construct new() {
    _router = Router.new()
    _middleware = []
    _globalSheet = Stylesheet.new()
    _notFound = Fn.new {|req|
      var r = Response.new(404)
      r.html("<h1>404 Not Found</h1><p>%(req.method) %(req.path)</p>")
      return r
    }
    _errorHandler = Fn.new {|req, err|
      var r = Response.new(500)
      r.html("<h1>500 Internal Server Error</h1><pre>%(err)</pre>")
      return r
    }
  }

  // App-wide stylesheet. Styles registered here are injected into
  // the <head> of every full-page response via `req.render`, deduped
  // by class name. htmx fragment responses skip it (the page already
  // has it; repeating would bloat the swap payload).
  //
  //   var base = Css.tw("font-sans text-gray-900 leading-normal")
  //   app.globalCss(base)
  globalCss(style) {
    _globalSheet.add(style)
    return this
  }
  globalSheet { _globalSheet }

  // Routing delegates to the built-in router.
  get(path, fn) {
    _router.get(path, fn)
    return this
  }
  post(path, fn) {
    _router.post(path, fn)
    return this
  }
  put(path, fn) {
    _router.put(path, fn)
    return this
  }
  patch(path, fn) {
    _router.patch(path, fn)
    return this
  }
  delete(path, fn) {
    _router.delete(path, fn)
    return this
  }
  any(path, fn) {
    _router.any(path, fn)
    return this
  }
  mount(r) {
    _router.mount(r)
    return this
  }

  // Register a middleware. Runs outermost-first.
  use(fn) {
    _middleware.add(fn)
    return this
  }

  // Custom 404 / error handlers.
  notFound(fn) {
    _notFound = fn
    return this
  }
  error(fn) {
    _errorHandler = fn
    return this
  }

  // Dispatch a parsed Request through the middleware pipeline and
  // router. Exposed so tests can drive it without a socket.
  handle(req) {
    // Hoist fields into locals — closures below must not rely on
    // field access, because a Fiber boundary or an Fn.new-created
    // closure won't have the enclosing `this` bound.
    var router   = _router
    var notFound = _notFound
    var errorFn  = _errorHandler
    var stack    = _middleware

    req.globalSheet = _globalSheet

    var terminal = Fn.new {|r|
      var match = router.resolve(r.method, r.path)
      if (match == null) return notFound.call(r)
      var handler = match[0]
      var params  = match[1]
      for (k in params.keys) r.setParam_(k, params[k])
      var result = handler.call(r)
      return Response.coerce(result)
    }
    var pipe = Pipeline_.new_(stack, terminal)
    var fiber = Fiber.new { Response.coerce(pipe.run(req)) }
    var out = fiber.try()
    if (fiber.error != null) return Response.coerce(errorFn.call(req, fiber.error))
    return out
  }

  // Bind + accept loop. `addr` looks like "127.0.0.1:3000" or
  // "0.0.0.0:8080". Blocks until the listener is closed. Phase 1
  // handles one connection at a time — enough to prove the shape;
  // concurrency via fibers is Phase 2.
  listen(addr) {
    var listener = TcpListener.bind(addr)
    System.print("@hatch:web listening on http://%(addr)")
    while (true) {
      var conn = listener.accept
      if (conn == null) break
      serve_(conn)
    }
  }

  serve_(conn) {
    var parsed = Http_.readRequest(conn)
    if (parsed == null) {
      conn.close
      return
    }
    var req = parsed
    var resp = handle(req)
    Http_.writeResponse(conn, resp)
    conn.close
  }
}

// ── HTTP/1.1 wire protocol ─────────────────────────────────────────────
//
// Minimal parser + serializer. Reads request line + headers +
// Content-Length body. Chunked transfer-encoding, pipelining,
// keep-alive, TLS, and WebSocket upgrade are all Phase 2+.

class Http_ {
  // Entry point — reads one request off a TcpStream, returns a
  // Request or null (malformed / EOF before request line).
  static readRequest(conn) {
    var buf = ByteBuf_.new(conn)
    var line = buf.readLine
    if (line == null || line == "") return null

    // Request line: METHOD SP PATH SP HTTP/1.1
    var parts = line.split(" ")
    if (parts.count < 3) return null
    var method = parts[0]
    var target = parts[1]

    var headers = {}
    while (true) {
      var h = buf.readLine
      if (h == null) return null
      if (h == "") break
      var colon = Http_.indexOf(h, ":")
      if (colon < 0) continue
      var name  = h[0..(colon - 1)]
      var value = colon + 1 < h.count ? h[(colon + 1)..(h.count - 1)] : ""
      headers[name] = Http_.trim(value)
    }

    var path = target
    var query = ""
    var qIdx = Http_.indexOf(target, "?")
    if (qIdx >= 0) {
      path  = target[0..(qIdx - 1)]
      query = qIdx + 1 < target.count ? target[(qIdx + 1)..(target.count - 1)] : ""
    }

    // Body (Content-Length only for now).
    var body = ""
    var clen = 0
    for (k in headers.keys) {
      if (Http_.lower(k) == "content-length") {
        clen = Num.fromString(Http_.trim(headers[k]))
        if (clen == null) clen = 0
      }
    }
    if (clen > 0) body = buf.read(clen)

    return Request.new_(method, path, query, headers, body, null)
  }

  // Serialize a Response onto the socket.
  static writeResponse(conn, resp) {
    var status  = resp.status
    var reason  = Http_.reason(status)
    var body    = resp.body
    var bodyLen = body == null ? 0 : body.bytes.count

    // Default Content-Type if the handler didn't set one.
    if (!resp.headers.containsKey("Content-Type")) {
      resp.headers["Content-Type"] = "text/html; charset=utf-8"
    }
    resp.headers["Content-Length"] = bodyLen.toString
    resp.headers["Connection"]     = "close"

    var out = "HTTP/1.1 %(status) %(reason)\r\n"
    for (k in resp.headers.keys) out = out + "%(k): %(resp.headers[k])\r\n"
    for (c in resp.cookies_)      out = out + "Set-Cookie: %(c)\r\n"
    out = out + "\r\n"
    conn.write(out)
    if (bodyLen > 0) conn.write(body)
  }

  // ── parsing helpers ───────────────────────────────────────────

  static parseForm(s) {
    var out = {}
    if (s == null || s.count == 0) return out
    var pairs = s.split("&")
    for (p in pairs) {
      if (p != "") {
        var eq = Http_.indexOf(p, "=")
        if (eq < 0) {
          out[Http_.urlDecode(p)] = ""
        } else {
          var k = Http_.urlDecode(p[0..(eq - 1)])
          var v = eq + 1 < p.count ? Http_.urlDecode(p[(eq + 1)..(p.count - 1)]) : ""
          out[k] = v
        }
      }
    }
    return out
  }

  static urlDecode(s) {
    var out = ""
    var i = 0
    while (i < s.count) {
      var c = s[i]
      if (c == "+") {
        out = out + " "
        i = i + 1
      } else if (c == "%" && i + 2 < s.count) {
        var hex = s[(i + 1)..(i + 2)]
        var n = Http_.hex(hex)
        if (n == null) {
          out = out + c
          i = i + 1
        } else {
          out = out + String.fromByte(n)
          i = i + 3
        }
      } else {
        out = out + c
        i = i + 1
      }
    }
    return out
  }

  static hex(s) {
    var n = 0
    var i = 0
    while (i < s.count) {
      var c = s[i]
      var b = c.bytes[0]
      var d = 0
      if (b >= 48 && b <= 57) d = b - 48
      else if (b >= 65 && b <= 70) d = b - 55
      else if (b >= 97 && b <= 102) d = b - 87
      else return null
      n = n * 16 + d
      i = i + 1
    }
    return n
  }

  static indexOf(s, ch) {
    var i = 0
    while (i < s.count) {
      if (s[i] == ch) return i
      i = i + 1
    }
    return -1
  }

  static trim(s) {
    if (s == null) return ""
    var start = 0
    var end = s.count
    while (start < end && (s[start] == " " || s[start] == "\t")) start = start + 1
    while (end > start && (s[end - 1] == " " || s[end - 1] == "\t")) end = end - 1
    if (start == 0 && end == s.count) return s
    return s[start..(end - 1)]
  }

  static lower(s) {
    if (s == null) return ""
    var out = ""
    var i = 0
    while (i < s.count) {
      var c = s[i]
      var b = c.bytes[0]
      if (b >= 65 && b <= 90) out = out + String.fromByte(b + 32)
      else out = out + c
      i = i + 1
    }
    return out
  }

  static reason(status) {
    if (status == 200) return "OK"
    if (status == 201) return "Created"
    if (status == 204) return "No Content"
    if (status == 301) return "Moved Permanently"
    if (status == 302) return "Found"
    if (status == 303) return "See Other"
    if (status == 304) return "Not Modified"
    if (status == 307) return "Temporary Redirect"
    if (status == 308) return "Permanent Redirect"
    if (status == 400) return "Bad Request"
    if (status == 401) return "Unauthorized"
    if (status == 403) return "Forbidden"
    if (status == 404) return "Not Found"
    if (status == 405) return "Method Not Allowed"
    if (status == 409) return "Conflict"
    if (status == 422) return "Unprocessable Entity"
    if (status == 500) return "Internal Server Error"
    return "Unknown"
  }
}

// ── Byte buffer over a TcpStream ────────────────────────────────────────
//
// TcpStream.read(max) returns List<Num>. We need line-oriented
// reads for the header section + exact-count reads for the body.
// Buffer incoming bytes and dole them out on demand.

class ByteBuf_ {
  construct new(conn) {
    _conn = conn
    _buf = []   // List<Num>
    _eof = false
  }

  // Read until CRLF, return the line without the CRLF.
  // Returns null on EOF with no pending data.
  readLine {
    while (true) {
      var idx = findCrlf_()
      if (idx >= 0) {
        var line = bytesToString_(0, idx)
        _buf = _buf[(idx + 2)..(_buf.count - 1)]
        return line
      }
      if (_eof) {
        if (_buf.count == 0) return null
        var line = bytesToString_(0, _buf.count)
        _buf = []
        return line
      }
      fill_()
    }
  }

  // Read exactly `n` bytes, return as String. Short read on EOF.
  read(n) {
    while (_buf.count < n && !_eof) fill_()
    var take = n > _buf.count ? _buf.count : n
    var s = bytesToString_(0, take)
    _buf = take >= _buf.count ? [] : _buf[take..(_buf.count - 1)]
    return s
  }

  findCrlf_() {
    var i = 0
    while (i + 1 < _buf.count) {
      if (_buf[i] == 13 && _buf[i + 1] == 10) return i
      i = i + 1
    }
    return -1
  }

  fill_() {
    var chunk = _conn.read(4096)
    if (chunk.count == 0) {
      _eof = true
      return
    }
    for (b in chunk) _buf.add(b)
  }

  bytesToString_(from, to) {
    // Exclusive `to`. Return a String reconstructed from bytes.
    var s = ""
    var i = from
    while (i < to) {
      s = s + String.fromByte(_buf[i])
      i = i + 1
    }
    return s
  }
}

// ── Static file serving ────────────────────────────────────────────────
//
//   app.use(Static.serve("/assets", "./public"))
//
// Serves GET/HEAD requests whose path starts with the URL prefix.
// Maps them to files under `root`. `..` in the path is rejected
// out of hand. On a miss, hands off to the next middleware so
// your dynamic routes still win for unknown paths — a 404 only
// comes from the router, not here.
//
// Content-Type is inferred from extension. A tiny MIME table
// covers the common web assets; unknown extensions fall back to
// application/octet-stream.

class Static {
  static serve(urlPrefix, root) {
    return Fn.new {|req, next|
      if (req.method != "GET" && req.method != "HEAD") return next.call(req)
      if (!req.path.startsWith(urlPrefix)) return next.call(req)
      var rel = req.path.count > urlPrefix.count ?
        req.path[urlPrefix.count..(req.path.count - 1)] : ""
      // Reject any segment that's "..", and strip leading slashes.
      if (Static.unsafe_(rel)) return Response.new(403).text("Forbidden")
      while (rel.count > 0 && rel[0] == "/") rel = rel[1..(rel.count - 1)]
      var full = Static.join_(root, rel)
      if (!Fs.exists(full) || !Fs.isFile(full)) return next.call(req)
      var bytes = Fs.readBytes(full)
      var r = Response.new(200)
      r.header("Content-Type", Static.mimeOf_(rel))
      r.header("Content-Length", bytes.count.toString)
      // Body stays as bytes — the writer accepts either String or
      // List<Num> via TcpStream.write.
      r.body = Static.bytesToString_(bytes)
      return r
    }
  }

  static unsafe_(rel) {
    if (rel == null) return false
    var parts = rel.split("/")
    for (p in parts) {
      if (p == "..") return true
    }
    return false
  }

  static join_(a, b) {
    if (a == "") return b
    if (b == "") return a
    if (a[a.count - 1] == "/") return a + b
    return a + "/" + b
  }

  static bytesToString_(bytes) {
    var s = ""
    var i = 0
    while (i < bytes.count) {
      s = s + String.fromByte(bytes[i])
      i = i + 1
    }
    return s
  }

  // Minimal MIME table — enough for HTML apps with htmx, CSS,
  // a few images, fonts. Anything missing falls back to
  // application/octet-stream which is always a safe default.
  static mimeOf_(path) {
    var dot = -1
    var i = path.count - 1
    while (i >= 0) {
      if (path[i] == ".") {
        dot = i
        i = -1
      } else {
        i = i - 1
      }
    }
    if (dot < 0) return "application/octet-stream"
    var ext = Http_.lower(path[(dot + 1)..(path.count - 1)])
    if (ext == "html" || ext == "htm") return "text/html; charset=utf-8"
    if (ext == "css")  return "text/css; charset=utf-8"
    if (ext == "js")   return "application/javascript; charset=utf-8"
    if (ext == "mjs")  return "application/javascript; charset=utf-8"
    if (ext == "json") return "application/json"
    if (ext == "svg")  return "image/svg+xml"
    if (ext == "png")  return "image/png"
    if (ext == "jpg" || ext == "jpeg") return "image/jpeg"
    if (ext == "gif")  return "image/gif"
    if (ext == "webp") return "image/webp"
    if (ext == "ico")  return "image/x-icon"
    if (ext == "woff") return "font/woff"
    if (ext == "woff2") return "font/woff2"
    if (ext == "ttf")  return "font/ttf"
    if (ext == "txt")  return "text/plain; charset=utf-8"
    if (ext == "xml")  return "application/xml"
    return "application/octet-stream"
  }
}

// ── Signed-cookie session ──────────────────────────────────────────────
//
//   app.use(Session.cookie("my-secret"))
//
// Parses the `_session` cookie on the way in (verifies HMAC,
// decodes JSON) and attaches a mutable Map as `req.session`.
// On the way out, re-serializes + signs and writes a Set-Cookie.
//
// HMAC-SHA256 over the payload. Constant-time comparison on
// verify so an attacker can't probe for byte-wise matches.
// Tamper / bad signature / malformed cookie = empty session;
// we never trust a partially-valid cookie.
//
// Stateless by default — the whole session lives in the cookie.
// Fine for small sessions (user id, role, flash), bad for
// megabytes. Server-side stores come later.

class Session {
  static COOKIE_NAME_ { "_session" }

  static cookie(secret) { cookie(secret, {}) }
  static cookie(secret, opts) {
    var cookieName = opts.containsKey("name") ? opts["name"] : Session.COOKIE_NAME_
    var path       = opts.containsKey("path") ? opts["path"] : "/"
    var maxAge     = opts.containsKey("maxAge") ? opts["maxAge"] : null
    var httpOnly   = opts.containsKey("httpOnly") ? opts["httpOnly"] : true
    var secure     = opts.containsKey("secure") ? opts["secure"] : false
    var sameSite   = opts.containsKey("sameSite") ? opts["sameSite"] : "Lax"

    return Fn.new {|req, next|
      // Parse incoming cookie.
      var parsed = Session.parse_(req, cookieName, secret)
      req.session = parsed

      // Flash: hoist _flash out of the session so it's read-once.
      var flash = {}
      if (parsed.containsKey("_flash")) {
        var stored = parsed["_flash"]
        if (stored is Map) flash = stored
        parsed.remove("_flash")
      }
      req.flash = flash
      req.flashNext = {}

      var resp = next.call(req)
      resp = Response.coerce(resp)

      // Persist only newly-set flash (via req.setFlash) so the
      // incoming flash is truly one-shot.
      if (req.flashNext != null && req.flashNext.count > 0) {
        req.session["_flash"] = req.flashNext
      }

      // Write session cookie back.
      var payload = JSON.encode(req.session)
      var signed  = Session.sign_(secret, payload)
      var attrs = { "path": path, "sameSite": sameSite }
      if (maxAge != null) attrs["maxAge"] = maxAge
      if (httpOnly)        attrs["httpOnly"] = true
      if (secure)          attrs["secure"] = true
      resp.cookie(cookieName, signed, attrs)
      return resp
    }
  }

  static parse_(req, cookieName, secret) {
    var raw = Session.readCookie_(req, cookieName)
    if (raw == null) return {}
    var verified = Session.verify_(secret, raw)
    if (verified == null) return {}
    var parsed = null
    var fiber = Fiber.new { JSON.parse(verified) }
    var out = fiber.try()
    if (fiber.error != null) return {}
    parsed = out
    if (!(parsed is Map)) return {}
    return parsed
  }

  static readCookie_(req, name) {
    var header = req.header("Cookie")
    if (header == null) return null
    var parts = header.split(";")
    for (p in parts) {
      var trimmed = Http_.trim(p)
      var eq = Http_.indexOf(trimmed, "=")
      if (eq >= 0) {
        var k = trimmed[0..(eq - 1)]
        if (k == name) {
          if (eq + 1 < trimmed.count) return trimmed[(eq + 1)..(trimmed.count - 1)]
          return ""
        }
      }
    }
    return null
  }

  // Produce `<base64url-payload>.<hmac-hex>`. The payload is
  // base64-url-encoded so dots and semicolons inside can't
  // confuse the cookie parser.
  static sign_(secret, payload) {
    var encoded = Hash.base64UrlEncode(payload)
    var sig = Hash.hmacSha256(secret, encoded)
    return encoded + "." + sig
  }

  // Returns the decoded payload on success, null on tamper / malformed.
  static verify_(secret, signedCookie) {
    var dot = -1
    var i = signedCookie.count - 1
    while (i >= 0) {
      if (signedCookie[i] == ".") {
        dot = i
        i = -1
      } else {
        i = i - 1
      }
    }
    if (dot < 0) return null
    var encoded = signedCookie[0..(dot - 1)]
    var given   = signedCookie[(dot + 1)..(signedCookie.count - 1)]
    var expected = Hash.hmacSha256(secret, encoded)
    if (!Session.constantTimeEq_(given, expected)) return null
    var bytes = null
    var fiber = Fiber.new { Hash.base64UrlDecode(encoded) }
    var out = fiber.try()
    if (fiber.error != null) return null
    bytes = out
    var s = ""
    for (b in bytes) s = s + String.fromByte(b)
    return s
  }

  // Compare strings in constant time: always walk the full min-
  // length, OR the differences into an accumulator. Length
  // mismatch is an immediate mismatch but that's a safe leak
  // (the length of your signature was never secret).
  static constantTimeEq_(a, b) {
    if (a.count != b.count) return false
    var diff = 0
    var i = 0
    while (i < a.count) {
      var ba = a[i].bytes[0]
      var bb = b[i].bytes[0]
      var d = ba ^ bb
      diff = diff | d
      i = i + 1
    }
    return diff == 0
  }
}

// ── CSRF protection ────────────────────────────────────────────────────
//
//   app.use(Session.cookie("..."))   // required — CSRF lives in session
//   app.use(Csrf.middleware)
//
// On any request with a session, ensures `session["_csrf"]` is
// populated with a fresh random token. Exposes it at
// `req.csrfToken` so templates / handlers can embed it.
//
// For state-changing methods (POST / PUT / PATCH / DELETE), the
// middleware demands a matching token in either the form body
// (field "_csrf") or the "X-CSRF-Token" header. Missing or
// mismatched → 403. SameSite=Lax on the session cookie covers
// most of the CSRF risk already; this is defense in depth.

class Csrf {
  static TOKEN_BYTES_ { 32 }

  // Convenience: returns the middleware Fn so `app.use(Csrf.middleware)`
  // reads naturally.
  static middleware { middlewareWith({}) }

  static middlewareWith(opts) {
    var headerName = opts.containsKey("header") ? opts["header"] : "X-CSRF-Token"
    var fieldName  = opts.containsKey("field")  ? opts["field"]  : "_csrf"
    var unsafe = ["POST", "PUT", "PATCH", "DELETE"]

    return Fn.new {|req, next|
      if (req.session == null) {
        Fiber.abort("Csrf.middleware: no session on request — mount Session.cookie first")
      }
      // Ensure a token exists for this session.
      var token = null
      if (req.session.containsKey("_csrf")) {
        token = req.session["_csrf"]
      } else {
        token = Csrf.newToken_()
        req.session["_csrf"] = token
      }
      req.setParam_("__csrf", token)  // expose via req.param("__csrf")

      var needs = false
      for (m in unsafe) {
        if (req.method == m) needs = true
      }
      if (needs && !Csrf.isHx_(req)) {
        var provided = null
        var h = req.header(headerName)
        if (h != null) provided = h
        if (provided == null && (req.method == "POST" || req.method == "PUT")) {
          var f = req.form
          if (f.containsKey(fieldName)) provided = f[fieldName]
        }
        if (provided == null || !Session.constantTimeEq_(provided, token)) {
          return Response.new(403).text("CSRF token mismatch")
        }
      }
      return next.call(req)
    }
  }

  // htmx AJAX requests opt out of the form-field dance — they
  // set the header instead. This is the escape hatch so routes
  // that accept fragment POSTs don't need to inject a hidden
  // input into every hx-post element.
  static isHx_(req) {
    if (!req.isHx) return false
    var h = req.header("X-CSRF-Token")
    if (h == null) return false
    return Session.constantTimeEq_(h, req.session["_csrf"])
  }

  static newToken_() {
    var bytes = Crypto.bytes(Csrf.TOKEN_BYTES_)
    return Hash.base64UrlEncode(bytes)
  }

  // Render a hidden form input carrying the token. Handlers
  // can interpolate `Csrf.field(req)` into an HTML string or
  // pass it through a template variable.
  static field(req) {
    var t = ""
    if (req.session != null && req.session.containsKey("_csrf")) {
      t = req.session["_csrf"]
    }
    return "<input type=\"hidden\" name=\"_csrf\" value=\"" + t + "\">"
  }

  // Token accessor — useful when you want to emit it via a
  // <meta> tag for htmx's hx-headers config.
  static token(req) {
    if (req.session == null) return null
    return req.session.containsKey("_csrf") ? req.session["_csrf"] : null
  }
}

// ── Flash messages ─────────────────────────────────────────────────────
//
//   // in handler
//   req.flash["notice"] = "Signed in as %(user.name)"
//   return Response.redirect("/")
//
//   // in template
//   {% if flash.containsKey("notice") %}
//     <div class="flash">{{ flash["notice"] }}</div>
//   {% endif %}
//
// The Session middleware already hoists `_flash` out of the
// session on the way in and stashes anything written during the
// handler back under `_flash` on the way out, so a one-shot
// notice survives exactly one redirect and then evaporates.

class Flash {
  // Shortcut for injecting `flash` into a render context.
  // Templates reference `flash["notice"]`, `flash["error"]`, etc.
  static bind(req, ctx) {
    var c = ctx == null ? {} : ctx
    c["flash"] = req.flash == null ? {} : req.flash
    return c
  }
}
