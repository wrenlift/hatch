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
//   //   "headers" : Map<String, String>
//   //   "query"   : Map<String, String|Num>  — appended to URL
//   //   "body"    : String                    — raw body
//   //   "json"    : any                       — serialised + sets
//   //                                           Content-Type
//   //   "timeout" : Num seconds
//
//   // Response shape
//   res.status                 // 200
//   res.ok                     // 200 <= status < 300
//   res.body                   // String (response text)
//   res.json                   // parsed via @hatch:json
//   res.headers                // Map<String, String>, lower-cased keys
//   res.header("content-type") // convenience lookup
//
// Transport errors (DNS, connect, TLS, timeout) abort the fiber
// — wrap in `Fiber.new { ... }.try()` to catch.

import "http"        for HttpCore
import "@hatch:json" for JSON
import "@hatch:url"  for Url

class Response {
  construct new_(status, headers, body) {
    _status  = status
    _headers = headers
    _body    = body
  }

  status  { _status }
  body    { _body }
  headers { _headers }

  ok { _status >= 200 && _status < 300 }

  header(name) {
    var key = Response.lower_(name)
    return _headers.containsKey(key) ? _headers[key] : null
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

    // Assemble query string onto the URL, if any.
    var finalUrl = url
    if (options.containsKey("query")) {
      var q = options["query"]
      if (!(q is Map)) Fiber.abort("Http.request: query must be a Map")
      var encoded = Url.encodeQuery(q)
      if (encoded != "") {
        finalUrl = url.contains("?") ? url + "&" + encoded : url + "?" + encoded
      }
    }

    // Headers start from the caller's map (or empty), then we
    // layer content-type / body-related fields on top.
    var headers = {}
    if (options.containsKey("headers")) {
      var h = options["headers"]
      if (!(h is Map)) Fiber.abort("Http.request: headers must be a Map")
      for (entry in h) {
        headers[entry.key] = "%(entry.value)"
      }
    }

    var body = null
    if (options.containsKey("json")) {
      body = JSON.encode(options["json"])
      if (!headers.containsKey("Content-Type") && !headers.containsKey("content-type")) {
        headers["Content-Type"] = "application/json"
      }
    } else if (options.containsKey("body")) {
      var raw = options["body"]
      if (!(raw is String)) Fiber.abort("Http.request: body must be a string")
      body = raw
    }

    var timeout = null
    if (options.containsKey("timeout")) {
      timeout = options["timeout"]
    }

    var raw = HttpCore.request(method, finalUrl, headers, body, timeout)
    return Response.new_(raw["status"], raw["headers"], raw["body"])
  }
}
