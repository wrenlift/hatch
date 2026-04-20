// @hatch:http — synchronous HTTP client.
//
//   import "@hatch:http" for Http
//
//   // One-shot verb helpers
//   var res = Http.get("https://api.example.com/users")
//   var res = Http.post("https://api.example.com/users", {
//     "json": {"name": "alice"}
//   })
//   var res = Http.delete(url)
//   var res = Http.put(url, {"body": "raw text"})
//   var res = Http.patch(url, {"json": {"done": true}})
//
//   // Generic: Http.request(method, url, options)
//   //
//   // Options map accepts:
//   //   "headers" : Map<String, String | List<String>>
//   //   "query"   : Map<String, String|Num>  — appended to URL
//   //   "body"    : String                    — raw body
//   //   "json"    : any                       — JSON.encode + sets
//   //                                           Content-Type
//   //   "form"    : Map                       — urlencoded body +
//   //                                           Content-Type
//   //   "bearer"  : String                    — Authorization: Bearer …
//   //   "basicAuth": [user, password]          — Authorization: Basic …
//   //   "userAgent": String                    — overrides default
//   //   "accept"  : String                    — shortcut for Accept header
//   //   "timeout" : Num seconds               — default 30
//
//   // Response shape
//   res.status                 // 200
//   res.ok                     // 200 <= status < 300
//   res.body                   // String (response text)
//   res.json                   // parsed via @hatch:json
//   res.header("content-type") // first value, case-insensitive
//   res.headers("set-cookie")  // List<String>, case-insensitive
//   res.headerMap              // raw Map<String, List<String>>
//
// Transport errors (DNS, connect, TLS, timeout) and malformed
// headers abort the fiber — wrap in `Fiber.new { ... }.try()` to
// catch. Native-code panics from transitive Rust deps likewise
// surface as fiber aborts, not process exits.

import "http"        for HttpCore
import "hash"        for HashCore
import "@hatch:json" for JSON
import "@hatch:url"  for Url

class Response {
  construct new_(status, headers, body) {
    _status  = status
    _headers = headers          // Map<String, List<String>>, lower-cased keys
    _body    = body
  }

  status  { _status }
  body    { _body }

  // Raw headers map: lower-cased keys → List<String> of values.
  // Multi-value headers like `Set-Cookie` survive intact here
  // (a naive Map<String, String> would collapse them).
  headerMap { _headers }

  ok { _status >= 200 && _status < 300 }

  // First value for the given header, case-insensitive. Returns
  // null when absent. This matches the "just tell me the
  // content-type" use case every HTTP client needs.
  header(name) {
    var key = Response.lower_(name)
    if (!_headers.containsKey(key)) return null
    var list = _headers[key]
    return list.count == 0 ? null : list[0]
  }

  // All values for the given header, preserving order. Returns
  // an empty list when absent.
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

  // --- Generic request --------------------------------------------------

  static request(method, url, options) {
    if (!(method is String)) Fiber.abort("Http.request: method must be a string")
    if (!(url is String)) Fiber.abort("Http.request: url must be a string")
    if (options != null && !(options is Map)) {
      Fiber.abort("Http.request: options must be a Map")
    }
    if (options == null) options = {}

    // --- URL with query string ----------------------------------------
    var finalUrl = url
    if (options.containsKey("query")) {
      var q = options["query"]
      if (!(q is Map)) Fiber.abort("Http.request: query must be a Map")
      var encoded = Url.encodeQuery(q)
      if (encoded != "") {
        finalUrl = url.contains("?") ? url + "&" + encoded : url + "?" + encoded
      }
    }

    // --- Headers (seeded from caller's, then conveniences layered on) ---
    var headers = {}
    if (options.containsKey("headers")) {
      var h = options["headers"]
      if (!(h is Map)) Fiber.abort("Http.request: headers must be a Map")
      for (entry in h) headers[entry.key] = entry.value
    }

    if (options.containsKey("userAgent")) {
      headers["User-Agent"] = options["userAgent"]
    }
    if (options.containsKey("accept")) {
      headers["Accept"] = options["accept"]
    }
    if (options.containsKey("bearer")) {
      headers["Authorization"] = "Bearer " + options["bearer"]
    }
    if (options.containsKey("basicAuth")) {
      var auth = options["basicAuth"]
      if (!(auth is List) || auth.count != 2) {
        Fiber.abort("Http.request: basicAuth must be [username, password]")
      }
      var pair = auth[0] + ":" + auth[1]
      headers["Authorization"] = "Basic " + HashCore.base64Encode(pair)
    }

    // --- Body (json / form / raw) -------------------------------------
    var body = null

    var payloads = 0
    if (options.containsKey("json")) payloads = payloads + 1
    if (options.containsKey("form")) payloads = payloads + 1
    if (options.containsKey("body")) payloads = payloads + 1
    if (payloads > 1) {
      Fiber.abort("Http.request: use at most one of body / json / form")
    }

    if (options.containsKey("json")) {
      body = JSON.encode(options["json"])
      Http.setIfAbsent_(headers, "Content-Type", "application/json")
    } else if (options.containsKey("form")) {
      var f = options["form"]
      if (!(f is Map)) Fiber.abort("Http.request: form must be a Map")
      body = Url.encodeQuery(f)
      Http.setIfAbsent_(headers, "Content-Type", "application/x-www-form-urlencoded")
    } else if (options.containsKey("body")) {
      var raw = options["body"]
      if (!(raw is String)) Fiber.abort("Http.request: body must be a string")
      body = raw
    }

    var timeout = options.containsKey("timeout") ? options["timeout"] : null

    var raw = HttpCore.request(method, finalUrl, headers, body, timeout)
    return Response.new_(raw["status"], raw["headers"], raw["body"])
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
