// `@hatch:json`. JSON parser and serializer.
//
// ```wren
// import "@hatch:json" for JSON
//
// JSON.parse("[1, 2, 3]")            // [1, 2, 3]
// JSON.parse("{\"a\": true}")        // {a: true}
// JSON.encode({"x": [1, 2]})         // "{\"x\":[1,2]}"
// JSON.encode({"x": 1}, 2)           // pretty-printed with indent=2
// ```
//
// ## Type mapping
//
// | JSON           | Wren                |
// |----------------|---------------------|
// | `null`         | `null`              |
// | `true`/`false` | `Bool`              |
// | number         | `Num`               |
// | string         | `String`            |
// | array          | `List`              |
// | object         | `Map` (string keys) |
//
// Custom types: define `toJson()` on your class and it becomes
// encodable. The method returns any JSON-encodable value, typically
// a `Map` of fields. Nested custom objects work too; the encoder
// recurses on the returned value.
//
// ```wren
// class Point {
//   construct new(x, y) {
//     _x = x
//     _y = y
//   }
//   toJson() { {"x": _x, "y": _y} }
// }
// JSON.encode(Point.new(1, 2))      // {"x":1,"y":2}
// ```
//
// Malformed input aborts the fiber with a message pointing at the
// offending byte offset. Callers that want fallible parsing can
// wrap the call in `Fiber.new { JSON.parse(text) }.try()`.
//
// (An attribute-driven `#json`-on-getters approach was prototyped
// but runs into a separate dispatch quirk (see `QUIRKS.md`) and
// will land once that's unblocked.)

/// JSON parser and serializer.
///
/// Type mapping (JSON to/from Wren):
///
/// | JSON              | Wren                 |
/// |-------------------|----------------------|
/// | `null`            | `Null`               |
/// | `true` / `false`  | `Bool`               |
/// | number            | `Num`                |
/// | string            | `String`             |
/// | array             | `List`               |
/// | object            | `Map` (string keys)  |
///
/// ## Example
///
/// ```wren
/// import "@hatch:json" for JSON
///
/// JSON.parse("[1, 2, 3]")            // [1, 2, 3]
/// JSON.parse("{\"a\": true}")        // {a: true}
/// JSON.encode({"x": [1, 2]})         // "{\"x\":[1,2]}"
/// JSON.encode({"x": 1}, 2)           // pretty-printed, indent=2
/// ```
///
/// Custom types: define `toJson()` on your class and it becomes
/// encodable; the method returns any JSON-encodable value
/// (typically a `Map`). The encoder recurses on the returned
/// value, so nested custom objects work.
class JSON {
  /// Parse a JSON string into the matching Wren value
  /// (`Null` / `Bool` / `Num` / `String` / `List` / `Map`).
  /// Aborts the fiber on malformed input, with the byte offset
  /// of the failing token.
  ///
  /// @param {String} text
  /// @returns {Object}
  static parse(text) {
    var p = Parser_.new(text)
    p.skipWs_
    var value = p.parseValue_
    p.skipWs_
    if (!p.atEnd_) Fiber.abort("JSON: trailing data at offset %(p.offset_)")
    return value
  }

  /// Compact encode. Emits no whitespace between tokens.
  ///
  /// @param {Object} value
  /// @returns {String}
  static encode(value) {
    var out = []
    Encoder_.write(out, value, null, 0)
    return out.join("")
  }

  /// Pretty-printed encode. `indent` is the number of spaces
  /// per level; pass `0` for compact-with-newlines, `2` or `4`
  /// for typical human-readable output.
  ///
  /// @param {Object} value
  /// @param {Num} indent
  /// @returns {String}
  static encode(value, indent) {
    if (!(indent is Num) || indent < 0) {
      Fiber.abort("JSON.encode: indent must be a non-negative number")
    }
    var out = []
    Encoder_.write(out, value, indent, 0)
    return out.join("")
  }
}

// --- Parser -----------------------------------------------------------------

class Parser_ {
  construct new(text) {
    if (!(text is String)) Fiber.abort("JSON.parse: expected a string")
    _s = text
    _i = 0
    _n = text.count
  }

  offset_ { _i }
  atEnd_  { _i >= _n }

  // Skip spaces / tabs / CR / LF between tokens.
  skipWs_ {
    while (_i < _n) {
      var c = _s[_i]
      if (c == " " || c == "\t" || c == "\n" || c == "\r") {
        _i = _i + 1
      } else {
        break
      }
    }
  }

  parseValue_ {
    skipWs_
    if (atEnd_) Fiber.abort("JSON: unexpected end of input")
    var c = _s[_i]
    if (c == "{") return parseObject_
    if (c == "[") return parseArray_
    if (c == "\"") return parseString_
    if (c == "t" || c == "f") return parseBool_
    if (c == "n") return parseNull_
    // Numbers start with `-` or a digit.
    if (c == "-" || isDigit_(c)) return parseNumber_
    Fiber.abort("JSON: unexpected character %(c) at offset %(_i)")
  }

  // Wren's String class only defines `==` (no ordering operators),
  // so character range checks go through the raw byte.
  isDigit_(c) {
    var b = c.bytes
    return b.count == 1 && b[0] >= 48 && b[0] <= 57       // "0".."9"
  }

  isHex_(c) {
    var b = c.bytes
    if (b.count != 1) return false
    var n = b[0]
    if (n >= 48 && n <= 57) return true                   // 0-9
    if (n >= 65 && n <= 70) return true                   // A-F
    if (n >= 97 && n <= 102) return true                  // a-f
    return false
  }

  parseObject_ {
    _i = _i + 1                              // consume "{"
    var map = {}
    skipWs_
    if (!atEnd_ && _s[_i] == "}") {
      _i = _i + 1
      return map
    }
    while (true) {
      skipWs_
      if (atEnd_ || _s[_i] != "\"") {
        Fiber.abort("JSON: expected string key at offset %(_i)")
      }
      var key = parseString_
      skipWs_
      if (atEnd_ || _s[_i] != ":") {
        Fiber.abort("JSON: expected ':' at offset %(_i)")
      }
      _i = _i + 1                            // consume ":"
      var value = parseValue_
      map[key] = value
      skipWs_
      if (atEnd_) Fiber.abort("JSON: unterminated object")
      var next = _s[_i]
      if (next == ",") {
        _i = _i + 1
        continue
      }
      if (next == "}") {
        _i = _i + 1
        return map
      }
      Fiber.abort("JSON: expected ',' or '}' at offset %(_i)")
    }
  }

  parseArray_ {
    _i = _i + 1                              // consume "["
    var list = []
    skipWs_
    if (!atEnd_ && _s[_i] == "]") {
      _i = _i + 1
      return list
    }
    while (true) {
      var value = parseValue_
      list.add(value)
      skipWs_
      if (atEnd_) Fiber.abort("JSON: unterminated array")
      var next = _s[_i]
      if (next == ",") {
        _i = _i + 1
        continue
      }
      if (next == "]") {
        _i = _i + 1
        return list
      }
      Fiber.abort("JSON: expected ',' or ']' at offset %(_i)")
    }
  }

  // Parse a quoted string, resolving \-escapes. JSON mandates "..."
  // quoting; we reject single quotes to keep parse errors strict.
  parseString_ {
    if (_s[_i] != "\"") Fiber.abort("JSON: expected string at offset %(_i)")
    _i = _i + 1
    var parts = []
    var start = _i
    while (_i < _n) {
      var c = _s[_i]
      if (c == "\"") {
        if (_i > start) parts.add(_s[start..._i])
        _i = _i + 1
        return parts.join("")
      }
      if (c == "\\") {
        if (_i > start) parts.add(_s[start..._i])
        _i = _i + 1
        if (_i >= _n) Fiber.abort("JSON: unterminated escape")
        var esc = _s[_i]
        if (esc == "\"") {
          parts.add("\"")
        } else if (esc == "\\") {
          parts.add("\\")
        } else if (esc == "/") {
          parts.add("/")
        } else if (esc == "n") {
          parts.add("\n")
        } else if (esc == "t") {
          parts.add("\t")
        } else if (esc == "r") {
          parts.add("\r")
        } else if (esc == "b") {
          parts.add("\b")
        } else if (esc == "f") {
          parts.add("\f")
        } else if (esc == "u") {
          parts.add(parseUnicodeEscape_)
        } else {
          Fiber.abort("JSON: invalid escape \\%(esc) at offset %(_i)")
        }
        _i = _i + 1
        start = _i
        continue
      }
      _i = _i + 1
    }
    Fiber.abort("JSON: unterminated string")
  }

  // After seeing \u, consume 4 hex digits and return the UTF-8
  // encoding of the resulting codepoint. Supports the BMP; surrogate
  // pairs are not paired up (they round-trip byte-for-byte through
  // parse/encode but won't collapse to a single codepoint).
  parseUnicodeEscape_ {
    if (_i + 4 >= _n) Fiber.abort("JSON: truncated \\u escape")
    var hex = _s[(_i + 1)...(_i + 5)]
    _i = _i + 4
    var code = hexToNum_(hex)
    return codepointToUtf8_(code)
  }

  hexToNum_(hex) {
    var total = 0
    var i = 0
    while (i < hex.count) {
      var b = hex[i].bytes[0]
      var d
      if (b >= 48 && b <= 57) {            // 0-9
        d = b - 48
      } else if (b >= 97 && b <= 102) {    // a-f
        d = b - 87
      } else if (b >= 65 && b <= 70) {     // A-F
        d = b - 55
      } else {
        Fiber.abort("JSON: bad hex digit %(hex[i])")
      }
      total = total * 16 + d
      i = i + 1
    }
    return total
  }

  codepointToUtf8_(cp) {
    if (cp < 0x80) {
      return String.fromCodePoint(cp)
    }
    // Fall back to the core helper for the full BMP (up to 0xFFFF);
    // Wren handles multi-byte encoding internally.
    return String.fromCodePoint(cp)
  }

  parseNumber_ {
    var start = _i
    if (_s[_i] == "-") _i = _i + 1
    while (_i < _n && isDigit_(_s[_i])) _i = _i + 1
    if (_i < _n && _s[_i] == ".") {
      _i = _i + 1
      while (_i < _n && isDigit_(_s[_i])) _i = _i + 1
    }
    if (_i < _n && (_s[_i] == "e" || _s[_i] == "E")) {
      _i = _i + 1
      if (_i < _n && (_s[_i] == "+" || _s[_i] == "-")) _i = _i + 1
      while (_i < _n && isDigit_(_s[_i])) _i = _i + 1
    }
    var slice = _s[start..._i]
    var n = Num.fromString(slice)
    if (n == null) Fiber.abort("JSON: invalid number %(slice)")
    return n
  }

  parseBool_ {
    if (matches_("true")) return true
    if (matches_("false")) return false
    Fiber.abort("JSON: invalid literal at offset %(_i)")
  }

  parseNull_ {
    if (matches_("null")) return null
    Fiber.abort("JSON: invalid literal at offset %(_i)")
  }

  matches_(keyword) {
    if (_i + keyword.count > _n) return false
    if (_s[_i..._i + keyword.count] != keyword) return false
    _i = _i + keyword.count
    return true
  }
}

// --- Encoder ----------------------------------------------------------------

class Encoder_ {
  /// Append the encoded form of `value` to `out`. `indent` is either
  /// null (compact) or a non-negative Num (pretty, that many spaces
  /// per level). `depth` is the current nesting depth.
  static write(out, value, indent, depth) {
    if (value == null) {
      out.add("null")
      return
    }
    if (value == true) {
      out.add("true")
      return
    }
    if (value == false) {
      out.add("false")
      return
    }
    if (value is Num) {
      writeNum_(out, value)
      return
    }
    if (value is String) {
      writeString_(out, value)
      return
    }
    if (value is List) {
      writeList_(out, value, indent, depth)
      return
    }
    if (value is Map) {
      writeMap_(out, value, indent, depth)
      return
    }
    // Custom type: try `toJson()` and recurse on its return value.
    var cls = value.type
    var probed = Fiber.new { value.toJson() }
    var ret = probed.try()
    if (probed.error == null) {
      if (ret == value) {
        Fiber.abort(
          "JSON.encode: %(cls.name).toJson() returned itself"
        )
      }
      write(out, ret, indent, depth)
      return
    }
    Fiber.abort(
      "JSON.encode: don't know how to encode %(cls.name) " +
      "(define toJson() on the class)"
    )
  }

  static writeNum_(out, n) {
    // JSON has no Infinity/NaN; aborting is more honest than
    // emitting invalid JSON that every downstream parser rejects.
    if (n != n) Fiber.abort("JSON.encode: NaN is not valid JSON")
    if (n > 1.0e308 || n < -1.0e308) {
      Fiber.abort("JSON.encode: Infinity is not valid JSON")
    }
    // Integer-valued floats render without ".0" so JSON consumers
    // see `42` rather than `42.0`.
    if (n.truncate == n && n.abs < 1.0e16) {
      out.add("%(n.truncate)")
    } else {
      out.add("%(n)")
    }
  }

  static writeString_(out, s) {
    out.add("\"")
    var i = 0
    var start = 0
    var n = s.count
    while (i < n) {
      var c = s[i]
      var esc = escapeChar_(c)
      if (esc != null) {
        if (i > start) out.add(s[start...i])
        out.add(esc)
        i = i + 1
        start = i
      } else {
        i = i + 1
      }
    }
    if (start < n) out.add(s[start...n])
    out.add("\"")
  }

  // Return the JSON-escaped form of a character, or null if it needs
  // no escaping.
  static escapeChar_(c) {
    if (c == "\"") return "\\\""
    if (c == "\\") return "\\\\"
    if (c == "\n") return "\\n"
    if (c == "\t") return "\\t"
    if (c == "\r") return "\\r"
    if (c == "\b") return "\\b"
    if (c == "\f") return "\\f"
    // Other control characters (U+0000..U+001F) need \u escapes.
    var b = c.bytes
    if (b.count == 1 && b[0] < 32) {
      return "\\u00%(hexPad_(b[0]))"
    }
    return null
  }

  static hexPad_(n) {
    var hex = "0123456789abcdef"
    return hex[(n >> 4) & 0xf] + hex[n & 0xf]
  }

  static writeList_(out, list, indent, depth) {
    if (list.count == 0) {
      out.add("[]")
      return
    }
    if (indent == null) {
      out.add("[")
      var first = true
      for (item in list) {
        if (first) {
          first = false
        } else {
          out.add(",")
        }
        write(out, item, null, depth + 1)
      }
      out.add("]")
    } else {
      out.add("[")
      out.add("\n")
      var pad = spaces_(indent * (depth + 1))
      var close_pad = spaces_(indent * depth)
      var first = true
      for (item in list) {
        if (first) {
          first = false
        } else {
          out.add(",\n")
        }
        out.add(pad)
        write(out, item, indent, depth + 1)
      }
      out.add("\n")
      out.add(close_pad)
      out.add("]")
    }
  }

  static writeMap_(out, map, indent, depth) {
    if (map.count == 0) {
      out.add("{}")
      return
    }
    if (indent == null) {
      out.add("{")
      var first = true
      for (entry in map) {
        if (first) {
          first = false
        } else {
          out.add(",")
        }
        writeString_(out, entryKey_(entry))
        out.add(":")
        write(out, entry.value, null, depth + 1)
      }
      out.add("}")
    } else {
      out.add("{")
      out.add("\n")
      var pad = spaces_(indent * (depth + 1))
      var close_pad = spaces_(indent * depth)
      var first = true
      for (entry in map) {
        if (first) {
          first = false
        } else {
          out.add(",\n")
        }
        out.add(pad)
        writeString_(out, entryKey_(entry))
        out.add(": ")
        write(out, entry.value, indent, depth + 1)
      }
      out.add("\n")
      out.add(close_pad)
      out.add("}")
    }
  }

  // Reject non-string keys here rather than producing invalid JSON.
  static entryKey_(entry) {
    var k = entry.key
    if (!(k is String)) {
      Fiber.abort("JSON.encode: map keys must be strings, got %(k.type)")
    }
    return k
  }

  static spaces_(n) {
    if (n <= 0) return ""
    return " " * n
  }
}
