// `@hatch:http`. Synchronous HTTP client with TLS, streaming
// bodies, and fiber-cooperative reads.
//
// ```wren
// import "@hatch:http" for Http
//
// // One-shot verb helpers
// var res = Http.get("https://api.example.com/users")
// var res = Http.post("https://api.example.com/users", {
//   "json": {"name": "alice"}
// })
// var res = Http.delete(url)
// var res = Http.put(url, {"body": "raw text"})
// var res = Http.patch(url, {"json": {"done": true}})
// ```
//
// ## Generic dispatch
//
// `Http.request(method, url, options)` underneath the verb
// helpers accepts:
//
// | Option       | Type                              | Notes                                                |
// |--------------|-----------------------------------|------------------------------------------------------|
// | `headers`    | `Map<String, String \| List>`     | Case-insensitive keys.                               |
// | `query`      | `Map<String, String \| Num>`      | Appended to the URL.                                 |
// | `body`       | `String`                          | Raw bytes.                                           |
// | `json`       | `any`                             | `JSON.encode`-d, sets `Content-Type`.                |
// | `form`       | `Map`                             | URL-encoded body, sets `Content-Type`.               |
// | `bearer`     | `String`                          | Sets `Authorization: Bearer ...`.                    |
// | `basicAuth`  | `[user, password]`                | Sets `Authorization: Basic ...`.                     |
// | `userAgent`  | `String`                          | Overrides the default UA.                            |
// | `accept`     | `String`                          | Shortcut for the `Accept` header.                    |
// | `timeout`    | `Num`                             | Seconds. Default `30`.                               |
//
// ## Response shape
//
// ```wren
// res.status                 // 200
// res.ok                     // 200 <= status < 300
// res.body                   // String (response text)
// res.json                   // parsed via @hatch:json
// res.header("content-type") // first value, case-insensitive
// res.headers("set-cookie")  // List<String>, case-insensitive
// res.headerMap              // raw Map<String, List<String>>
// ```
//
// Transport errors (DNS, connect, TLS, timeout) and malformed
// headers abort the fiber. Wrap in `Fiber.new { ... }.try()` to
// catch them. Native-code panics from transitive Rust deps
// likewise surface as fiber aborts, not process exits.

import "http"        for HttpCore
import "hash"        for HashCore
import "@hatch:json" for JSON
import "@hatch:url"  for Url
import "@hatch:io"   for Reader

class Response {
  construct new_(status, headers, body) {
    _status  = status
    _headers = headers          // Map<String, List<String>>, lower-cased keys
    _body    = body
  }

  status  { _status }
  body    { _body }

  /// Raw headers map. Lower-cased keys map to `List<String>` of
  /// values. Multi-value headers like `Set-Cookie` survive intact
  /// here (a naive `Map<String, String>` would collapse them).
  headerMap { _headers }

  ok { _status >= 200 && _status < 300 }

  /// First value for the given header, case-insensitive. Returns
  /// null when absent. This matches the "just tell me the
  /// content-type" use case every HTTP client needs.
  header(name) {
    var key = Response.lower_(name)
    if (!_headers.containsKey(key)) return null
    var list = _headers[key]
    return list.count == 0 ? null : list[0]
  }

  /// All values for the given header, preserving order. Returns
  /// an empty list when absent.
  headers(name) {
    var key = Response.lower_(name)
    return _headers.containsKey(key) ? _headers[key] : []
  }

  json {
    if (_parsed == null) {
      _parsed = JSON.parse(_body)
    }
    return _parsed
  }

  toString { "Response(%(_status))" }

  static lower_(s) {
    var out = []
    var i = 0
    while (i < s.count) {
      var c = s[i]
      var b = c.bytes
      if (b.count == 1 && b[0] >= 65 && b[0] <= 90) {
        out.add(String.fromCodePoint(b[0] + 32))
      } else {
        out.add(c)
      }
      i = i + 1
    }
    return out.join("")
  }
}

/// Streaming response. Status and headers are known up front; the
/// body is a `Reader` to drain at the caller's own pace. Use for
/// big downloads, SSE feeds, chunked endpoints, and anything where
/// pulling the whole body into memory is wrong.
///
/// ```wren
/// var r = Http.stream("GET", "https://example.com/big-file")
/// r.status               // 200
/// r.header("content-type")
/// var line = r.body.readLine
/// while (line != null) {
///   // ...
///   line = r.body.readLine
/// }
/// r.close                // frees the underlying connection; idempotent
/// ```
class StreamingResponse {
  construct new_(id, status, headers) {
    _id      = id
    _status  = status
    _headers = headers
    _closed  = false
    var sid = id
    _body = Reader.withFn {|max| HttpCore.streamReadBytes(sid, max) }
    _body.setCloseFn_ { HttpCore.streamClose(sid) }
    _bodyAsync = null   // lazily built
  }

  status    { _status }
  headerMap { _headers }
  body      { _body }

  /// Fiber-cooperative body reader. Returns the same bytes as
  /// `body`, but polls via `HttpCore.tryStreamReadBytes` and
  /// yields on "would block" so sibling fibers can run in
  /// parallel. Consuming `body` and `bodyAsync` at the same time
  /// interleaves reads. Pick one.
  bodyAsync {
    if (_bodyAsync == null) {
      var sid = _id
      _bodyAsync = Reader.withTryFn {|max| HttpCore.tryStreamReadBytes(sid, max) }
      _bodyAsync.setCloseFn_ { HttpCore.streamClose(sid) }
    }
    return _bodyAsync
  }

  ok { _status >= 200 && _status < 300 }

  header(name) {
    var key = Response.lower_(name)
    if (!_headers.containsKey(key)) return null
    var list = _headers[key]
    return list.count == 0 ? null : list[0]
  }

  headers(name) {
    var key = Response.lower_(name)
    return _headers.containsKey(key) ? _headers[key] : []
  }

  /// Release the underlying connection if the caller bails before
  /// EOF. Safe to call twice; draining the reader naturally will
  /// also free the stream on the runtime side.
  close {
    if (_closed) return
    _closed = true
    _body.close
  }

  toString { "StreamingResponse(%(_status))" }
}

class Http {
  // --- Verb helpers -----------------------------------------------------

  static get(url)               { request("GET",    url, {}) }
  static get(url, options)      { request("GET",    url, options) }
  static post(url, options)     { request("POST",   url, options) }
  static put(url, options)      { request("PUT",    url, options) }
  static patch(url, options)    { request("PATCH",  url, options) }
  static delete(url)            { request("DELETE", url, {}) }
  static delete(url, options)   { request("DELETE", url, options) }
  static head(url)              { request("HEAD",   url, {}) }

  // --- Generic request (buffered body) ---------------------------------

  static request(method, url, options) {
    var prep = Http.prepare_(method, url, options, "Http.request")
    var raw = HttpCore.request(prep[0], prep[1], prep[2], prep[3], prep[4])
    return Response.new_(raw["status"], raw["headers"], raw["body"])
  }

  // --- Streaming request (lazy body) -----------------------------------
  ///
  /// Same option shape as `request`. Returns a `StreamingResponse`
  /// whose `.body` is an `@hatch:io` Reader. Callers drain it line
  /// by line, chunk by chunk, or pipe it into a file or process.
  ///
  /// Close the response (`sr.close`) if you bail before EOF;
  /// otherwise reaching EOF frees the connection automatically.

  static stream(method, url)          { stream(method, url, {}) }
  static stream(method, url, options) {
    var prep = Http.prepare_(method, url, options, "Http.stream")
    var raw = HttpCore.stream(prep[0], prep[1], prep[2], prep[3], prep[4])
    return StreamingResponse.new_(raw["id"], raw["status"], raw["headers"])
  }

  /// Convenience: `Http.getStream(url)` / `Http.getStream(url, opts)`.
  static getStream(url)          { stream("GET", url, {}) }
  static getStream(url, options) { stream("GET", url, options) }

  // Internal. Normalises (method, url, options) into the tuple the
  // runtime layer expects.  Returns [method, finalUrl, headers,
  // body, timeout].  The same logic used to be inlined in
  // `request`; factored out so `stream` can share it without
  // copy-paste drift.
  static prepare_(method, url, options, label) {
    if (!(method is String)) Fiber.abort("%(label): method must be a string")
    if (!(url is String))    Fiber.abort("%(label): url must be a string")
    if (options != null && !(options is Map)) {
      Fiber.abort("%(label): options must be a Map")
    }
    if (options == null) options = {}

    var finalUrl = url
    if (options.containsKey("query")) {
      var q = options["query"]
      if (!(q is Map)) Fiber.abort("%(label): query must be a Map")
      var encoded = Url.encodeQuery(q)
      if (encoded != "") {
        finalUrl = url.contains("?") ? url + "&" + encoded : url + "?" + encoded
      }
    }

    var headers = {}
    if (options.containsKey("headers")) {
      var h = options["headers"]
      if (!(h is Map)) Fiber.abort("%(label): headers must be a Map")
      for (entry in h) headers[entry.key] = entry.value
    }

    if (options.containsKey("userAgent")) headers["User-Agent"] = options["userAgent"]
    if (options.containsKey("accept"))    headers["Accept"]     = options["accept"]
    if (options.containsKey("bearer")) {
      headers["Authorization"] = "Bearer " + options["bearer"]
    }
    if (options.containsKey("basicAuth")) {
      var auth = options["basicAuth"]
      if (!(auth is List) || auth.count != 2) {
        Fiber.abort("%(label): basicAuth must be [username, password]")
      }
      var pair = auth[0] + ":" + auth[1]
      headers["Authorization"] = "Basic " + HashCore.base64Encode(pair)
    }

    var body = null
    var payloads = 0
    if (options.containsKey("json")) payloads = payloads + 1
    if (options.containsKey("form")) payloads = payloads + 1
    if (options.containsKey("body")) payloads = payloads + 1
    if (payloads > 1) {
      Fiber.abort("%(label): use at most one of body / json / form")
    }

    if (options.containsKey("json")) {
      body = JSON.encode(options["json"])
      Http.setIfAbsent_(headers, "Content-Type", "application/json")
    } else if (options.containsKey("form")) {
      var f = options["form"]
      if (!(f is Map)) Fiber.abort("%(label): form must be a Map")
      body = Url.encodeQuery(f)
      Http.setIfAbsent_(headers, "Content-Type", "application/x-www-form-urlencoded")
    } else if (options.containsKey("body")) {
      var raw = options["body"]
      if (!(raw is String)) Fiber.abort("%(label): body must be a string")
      body = raw
    }

    var timeout = options.containsKey("timeout") ? options["timeout"] : null
    return [method, finalUrl, headers, body, timeout]
  }

  // Case-insensitive "set only if not already present".  Lets the
  // caller's own Content-Type / User-Agent win over our defaults.
  static setIfAbsent_(headers, name, value) {
    for (entry in headers) {
      if (Response.lower_(entry.key) == Response.lower_(name)) return
    }
    headers[name] = value
  }
}
