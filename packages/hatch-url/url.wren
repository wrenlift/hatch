/// @hatch:url — URL parser, builder, and percent-encoder.
///
///   import "@hatch:url" for Url
///
///   // Parse → value type with named parts
///   var u = Url.parse("https://user:pass@example.com:8080/path?q=s&x=1#frag")
///   u.scheme     // "https"
///   u.host       // "example.com"
///   u.port       // 8080   (Num, or null)
///   u.username   // "user"
///   u.password   // "pass"
///   u.path       // "/path"
///   u.query      // "q=s&x=1"
///   u.queryMap   // {"q": "s", "x": "1"}
///   u.fragment   // "frag"
///
///   u.toString   // round-trips back to the canonical form
///
///   // Percent-encode / decode a component.
///   Url.encode("a b/c")            // "a%20b%2Fc"
///   Url.decode("a%20b%2Fc")        // "a b/c"
///
///   // Encode / decode a `key=value&key=value` query string.
///   Url.encodeQuery({"a": 1, "b": "two"})   // "a=1&b=two"
///   Url.decodeQuery("a=1&b=two")             // {"a": "1", "b": "two"}
///
/// Scope: "good-enough" URL handling for HTTP requests and link
/// generation. Follows RFC 3986 loosely — no IRI (punycode IDN)
/// support, no relative-URL resolution. Pure Wren, no native
/// deps.

class Url {
  construct new() {
    _scheme   = null
    _username = null
    _password = null
    _host     = null
    _port     = null
    _path     = ""
    _query    = null
    _fragment = null
  }

  // --- Parsing --------------------------------------------------------

  /// Parse a string into a Url. Aborts the fiber on malformed
  /// input (missing scheme, bad port, etc.). Callers who want
  /// fallible parsing wrap in `Fiber.new { Url.parse(s) }.try()`.
  static parse(str) {
    if (!(str is String)) Fiber.abort("Url.parse: expected a string")
    if (str == "") Fiber.abort("Url.parse: empty input")
    var u = Url.new()
    var i = 0
    var n = str.count

    // Scheme: chars up to ':'.
    var colon = indexOf_(str, ":", 0)
    if (colon < 0) Fiber.abort("Url.parse: missing ':' after scheme")
    u.scheme = str[0...colon]
    i = colon + 1

    // Expect "//" for the authority component. We require it —
    // schemes like `mailto:` without `//` aren't in scope for v0.1.
    if (i + 1 >= n || str[i] != "/" || str[i + 1] != "/") {
      Fiber.abort("Url.parse: expected '//' after scheme")
    }
    i = i + 2

    // Find the end of the authority: next '/', '?', '#', or EOL.
    var auth_end = findAny_(str, ["/", "?", "#"], i)
    if (auth_end < 0) auth_end = n
    var authority = str[i...auth_end]
    i = auth_end

    // userinfo? split on '@' (last one, since the userinfo itself
    // may contain colons but not '@').
    var at = lastIndexOf_(authority, "@")
    if (at >= 0) {
      var userinfo = authority[0...at]
      var colon_ui = indexOf_(userinfo, ":", 0)
      if (colon_ui >= 0) {
        u.username = decode(userinfo[0...colon_ui])
        u.password = decode(userinfo[(colon_ui + 1)...userinfo.count])
      } else {
        u.username = decode(userinfo)
      }
      authority = authority[(at + 1)...authority.count]
    }

    // host + port. Port is the bit after the LAST colon, but
    // `[ipv6]:port` needs bracket-aware splitting. We don't do
    // IPv6 literals in v0.1 — if the host starts with `[`, we
    // pass it through verbatim and refuse to split a port.
    if (authority.count > 0 && authority[0] == "[") {
      var close = indexOf_(authority, "]", 0)
      if (close < 0) Fiber.abort("Url.parse: unclosed IPv6 bracket")
      u.host = authority[0...(close + 1)]
      if (close + 1 < authority.count) {
        if (authority[close + 1] != ":") {
          Fiber.abort("Url.parse: expected ':' after IPv6 literal")
        }
        u.port = parsePort_(authority[(close + 2)...authority.count])
      }
    } else {
      var ph = lastIndexOf_(authority, ":")
      if (ph >= 0) {
        u.host = authority[0...ph]
        u.port = parsePort_(authority[(ph + 1)...authority.count])
      } else {
        u.host = authority
      }
    }

    // path: starts at '/' and runs to '?' or '#' or EOL.
    if (i < n && str[i] == "/") {
      var p_end = findAny_(str, ["?", "#"], i)
      if (p_end < 0) p_end = n
      u.path = str[i...p_end]
      i = p_end
    }

    // query
    if (i < n && str[i] == "?") {
      i = i + 1
      var q_end = indexOf_(str, "#", i)
      if (q_end < 0) q_end = n
      u.query = str[i...q_end]
      i = q_end
    }

    // fragment
    if (i < n && str[i] == "#") {
      u.fragment = decode(str[(i + 1)...n])
    }

    return u
  }

  static parsePort_(s) {
    if (s == "") Fiber.abort("Url.parse: empty port")
    var n = Num.fromString(s)
    if (n == null) Fiber.abort("Url.parse: invalid port %(s)")
    if (n.truncate != n || n < 0 || n > 65535) {
      Fiber.abort("Url.parse: port out of range %(s)")
    }
    return n.truncate
  }

  // --- Accessors ------------------------------------------------------

  scheme        { _scheme }
  scheme=(v)    { _scheme = v }
  username      { _username }
  username=(v)  { _username = v }
  password      { _password }
  password=(v)  { _password = v }
  host          { _host }
  host=(v)      { _host = v }
  port          { _port }
  port=(v)      { _port = v }
  path          { _path }
  path=(v)      { _path = v }
  query         { _query }
  query=(v)     { _query = v }
  fragment      { _fragment }
  fragment=(v)  { _fragment = v }

  /// Parsed query string as a Map<String, String>. Repeated keys
  /// keep the last value — callers who need multi-valued params
  /// should parse `query` themselves.
  queryMap {
    if (_query == null) return {}
    return Url.decodeQuery(_query)
  }

  // --- Rendering ------------------------------------------------------

  toString {
    if (_scheme == null || _host == null) {
      Fiber.abort("Url.toString: scheme and host are required")
    }
    var s = _scheme + "://"
    if (_username != null) {
      s = s + Url.encode(_username)
      if (_password != null) s = s + ":" + Url.encode(_password)
      s = s + "@"
    }
    s = s + _host
    if (_port != null) s = s + ":" + "%(_port)"
    s = s + (_path == null ? "" : _path)
    if (_query != null) s = s + "?" + _query
    if (_fragment != null) s = s + "#" + Url.encode(_fragment)
    return s
  }

  toJson() { toString }

  // --- Percent-encoding ----------------------------------------------

  /// Unreserved per RFC 3986: ALPHA / DIGIT / "-" / "." / "_" / "~"
  /// Everything else → %XX uppercase hex.
  static encode(s) {
    if (!(s is String)) Fiber.abort("Url.encode: expected a string")
    if (s == "") return ""
    var out = []
    var i = 0
    var n = s.count
    while (i < n) {
      var c = s[i]
      if (isUnreserved_(c)) {
        out.add(c)
      } else {
        // UTF-8 bytes of this char, each percent-escaped.
        var bytes = c.bytes
        var j = 0
        while (j < bytes.count) {
          out.add("%")
          out.add(Url.hexByte_(bytes[j]))
          j = j + 1
        }
      }
      i = i + 1
    }
    return out.join("")
  }

  static decode(s) {
    if (!(s is String)) Fiber.abort("Url.decode: expected a string")
    if (s == "") return ""
    // Decode into a byte buffer first, then interpret as UTF-8 by
    // round-tripping through a String concat — preserves multi-byte
    // sequences emitted by `encode`.
    var bytes = []
    var i = 0
    var n = s.count
    while (i < n) {
      var c = s[i]
      if (c == "%") {
        if (i + 2 >= n) Fiber.abort("Url.decode: truncated %-escape")
        var b = Url.hexPairToByte_(s[i + 1], s[i + 2])
        bytes.add(b)
        i = i + 3
      } else if (c == "+") {
        // The classic form-encoded convention: "+" means " ".
        // RFC 3986 doesn't specify this, but every browser and
        // server reads it that way, so matching is the
        // least-surprise option.
        bytes.add(32)
        i = i + 1
      } else {
        var bs = c.bytes
        var j = 0
        while (j < bs.count) {
          bytes.add(bs[j])
          j = j + 1
        }
        i = i + 1
      }
    }
    return Url.bytesToString_(bytes)
  }

  // --- Query helpers --------------------------------------------------

  /// Encode a Map into a `k1=v1&k2=v2` string. Values that aren't
  /// strings are stringified via interpolation.
  static encodeQuery(map) {
    if (!(map is Map)) Fiber.abort("Url.encodeQuery: expected a Map")
    var parts = []
    for (entry in map) {
      var k = Url.encode("%(entry.key)")
      var v = Url.encode("%(entry.value)")
      parts.add(k + "=" + v)
    }
    return parts.join("&")
  }

  static decodeQuery(s) {
    if (!(s is String)) Fiber.abort("Url.decodeQuery: expected a string")
    var out = {}
    if (s == "") return out
    var pairs = s.split("&")
    var i = 0
    while (i < pairs.count) {
      var pair = pairs[i]
      i = i + 1
      if (pair == "") continue
      var eq = Url.indexOf_(pair, "=", 0)
      var k
      var v
      if (eq < 0) {
        k = decode(pair)
        v = ""
      } else {
        k = decode(pair[0...eq])
        v = decode(pair[(eq + 1)...pair.count])
      }
      out[k] = v
    }
    return out
  }

  // --- Internals ------------------------------------------------------

  static isUnreserved_(c) {
    var b = c.bytes
    if (b.count != 1) return false
    var n = b[0]
    if (n >= 48 && n <= 57) return true    // 0-9
    if (n >= 65 && n <= 90) return true    // A-Z
    if (n >= 97 && n <= 122) return true   // a-z
    if (n == 45 || n == 46 || n == 95 || n == 126) return true  // - . _ ~
    return false
  }

  // Left-padded lowercase-hex rendering of a single byte.
  // Upper-case hex per RFC 3986 §2.1.
  static hexByte_(n) {
    var hex = "0123456789ABCDEF"
    return hex[(n >> 4) & 0xf] + hex[n & 0xf]
  }

  static hexPairToByte_(hi, lo) {
    return Url.hexDigit_(hi) * 16 + Url.hexDigit_(lo)
  }

  static hexDigit_(c) {
    var b = c.bytes[0]
    if (b >= 48 && b <= 57) return b - 48
    if (b >= 65 && b <= 70) return b - 55
    if (b >= 97 && b <= 102) return b - 87
    Fiber.abort("Url.decode: bad hex digit %(c)")
  }

  // Assemble a List<Num> (each 0..=255) into a String. Wren's
  // String has no "fromBytes" constructor, so we build one
  // character at a time via `String.fromCodePoint` for ASCII and
  // fall back to a best-effort UTF-8 interpretation for higher
  // bytes by letting the codepoint round-trip.
  static bytesToString_(bytes) {
    // Pure-Wren UTF-8 decoding for the BMP — the common case
    // for HTTP paths and query strings. Astral-plane codepoints
    // are passed through one byte at a time.
    var i = 0
    var n = bytes.count
    var parts = []
    while (i < n) {
      var b = bytes[i]
      if (b < 0x80) {
        parts.add(String.fromCodePoint(b))
        i = i + 1
      } else if (b < 0xc0) {
        // Stray continuation byte — pass through as-is so we
        // don't silently lose data.
        parts.add(String.fromCodePoint(b))
        i = i + 1
      } else if (b < 0xe0 && i + 1 < n) {
        var cp = ((b & 0x1f) << 6) | (bytes[i + 1] & 0x3f)
        parts.add(String.fromCodePoint(cp))
        i = i + 2
      } else if (b < 0xf0 && i + 2 < n) {
        var cp = ((b & 0x0f) << 12) | ((bytes[i + 1] & 0x3f) << 6) | (bytes[i + 2] & 0x3f)
        parts.add(String.fromCodePoint(cp))
        i = i + 3
      } else if (i + 3 < n) {
        var cp = ((b & 0x07) << 18) | ((bytes[i + 1] & 0x3f) << 12) |
                 ((bytes[i + 2] & 0x3f) << 6) | (bytes[i + 3] & 0x3f)
        parts.add(String.fromCodePoint(cp))
        i = i + 4
      } else {
        parts.add(String.fromCodePoint(b))
        i = i + 1
      }
    }
    return parts.join("")
  }

  static indexOf_(s, needle, from) {
    var i = from
    while (i < s.count) {
      if (s[i] == needle) return i
      i = i + 1
    }
    return -1
  }

  static lastIndexOf_(s, needle) {
    var i = s.count - 1
    while (i >= 0) {
      if (s[i] == needle) return i
      i = i - 1
    }
    return -1
  }

  // First position of any of `needles` at or after `from`.
  static findAny_(s, needles, from) {
    var best = -1
    var i = 0
    while (i < needles.count) {
      var idx = Url.indexOf_(s, needles[i], from)
      if (idx >= 0 && (best < 0 || idx < best)) best = idx
      i = i + 1
    }
    return best
  }
}
