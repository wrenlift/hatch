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
  /// Internally walks the UTF-8 byte buffer to avoid the per-char
  /// allocation a String-indexed parser pays — `s[i]` returns a
  /// fresh 1-char String + `== "{"` allocates the rhs literal +
  /// `.bytes` allocates a ByteArray; on a 1 MB input the
  /// accumulated overhead measured at tens of seconds. ByteArray
  /// indexing returns a Num (no allocation), so comparisons and
  /// whitespace skipping run at memory speed.
  ///
  /// Callers that already hold a `ByteArray` (e.g. straight from
  /// `FS.readBytes` or `Assets.bytes`) should prefer
  /// [JSON.parseBytes] — it skips the String→ByteArray copy entirely.
  ///
  /// @param {String} text
  /// @returns {Object}
  static parse(text) {
    if (!(text is String)) Fiber.abort("JSON.parse: expected a string")
    return JSON.parseBytes(ByteArray.fromString(text))
  }

  /// Parse a JSON document straight from a UTF-8 `ByteArray`. The
  /// fast path — readers that get bytes from disk or the network
  /// avoid an intermediate `String` allocation. Otherwise identical
  /// to [parse]: same Wren-side value tree, same error positions.
  ///
  /// @param {ByteArray} bytes
  /// @returns {Object}
  static parseBytes(bytes) {
    var p = Parser_.newBytes_(bytes)
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

// Byte values that drive every comparison in the parser. Inlined
// at every call site by the JIT; kept as named constants for
// readability and to avoid magic numbers in the dispatch table.
//
//   SPC=32  HT=9   LF=10  CR=13
//   "=34  \=92   /=47   :=58   ,=44
//   {=123 }=125  [=91   ]=93
//   -=45  +=43   .=46   0=48 .. 9=57
//   a=97  b=98   e=101  f=102  l=108  n=110  r=114  s=115  t=116  u=117
//   A-F=65..70

class Parser_ {
  construct new(text) {
    if (!(text is String)) Fiber.abort("JSON.parse: expected a string")
    _b = ByteArray.fromString(text)
    _i = 0
    _n = _b.count
  }

  // Fast-path ctor — caller already has the UTF-8 bytes.
  construct newBytes_(bytes) {
    _b = bytes
    _i = 0
    _n = bytes.count
  }

  offset_ { _i }
  atEnd_  { _i >= _n }

  // Skip spaces / tabs / CR / LF between tokens. Byte comparisons,
  // no allocation per char.
  skipWs_ {
    while (_i < _n) {
      var c = _b[_i]
      if (c == 32 || c == 9 || c == 10 || c == 13) {
        _i = _i + 1
      } else {
        break
      }
    }
  }

  parseValue_ {
    skipWs_
    if (atEnd_) Fiber.abort("JSON: unexpected end of input")
    var c = _b[_i]
    if (c == 123) return parseObject_            // "{"
    if (c == 91)  return parseArray_             // "["
    if (c == 34)  return parseString_            // "\""
    if (c == 116 || c == 102) return parseBool_  // "t" / "f"
    if (c == 110) return parseNull_              // "n"
    if (c == 45 || (c >= 48 && c <= 57)) return parseNumber_   // "-" or digit
    Fiber.abort("JSON: unexpected byte %(c) at offset %(_i)")
  }

  // Raw-byte digit check. Reads ByteArray directly so no
  // intermediate one-char String allocation.
  isDigitByte_(b) { b >= 48 && b <= 57 }

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
    if (!atEnd_ && _b[_i] == 125) {          // "}"
      _i = _i + 1
      return map
    }
    while (true) {
      skipWs_
      if (atEnd_ || _b[_i] != 34) {          // "\""
        Fiber.abort("JSON: expected string key at offset %(_i)")
      }
      // String.intern dedupes N copies of "name" / repeated keys
      // down to one ObjString + one map-bucket — load-bearing on
      // the AOT site where JSON keys repeat heavily per request.
      var key = parseString_.intern
      skipWs_
      if (atEnd_ || _b[_i] != 58) {          // ":"
        Fiber.abort("JSON: expected ':' at offset %(_i)")
      }
      _i = _i + 1                            // consume ":"
      var value = parseValue_
      map[key] = value
      skipWs_
      if (atEnd_) Fiber.abort("JSON: unterminated object")
      var next = _b[_i]
      if (next == 44) {                      // ","
        _i = _i + 1
        continue
      }
      if (next == 125) {                     // "}"
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
    if (!atEnd_ && _b[_i] == 93) {           // "]"
      _i = _i + 1
      return list
    }
    while (true) {
      var value = parseValue_
      list.add(value)
      skipWs_
      if (atEnd_) Fiber.abort("JSON: unterminated array")
      var next = _b[_i]
      if (next == 44) {                      // ","
        _i = _i + 1
        continue
      }
      if (next == 93) {                      // "]"
        _i = _i + 1
        return list
      }
      Fiber.abort("JSON: expected ',' or ']' at offset %(_i)")
    }
  }

  // Parse a quoted string, resolving \-escapes. JSON mandates "..."
  // quoting; we reject single quotes to keep parse errors strict.
  parseString_ {
    if (_b[_i] != 34) Fiber.abort("JSON: expected string at offset %(_i)")
    _i = _i + 1
    // Fast path: no escapes. Scan for the closing quote or the first
    // backslash; if we hit the quote first, slice the whole span in
    // one `utf8Slice` FFI call. This is the common case in gltf,
    // where every value is "Bone_001"-style ASCII with no escapes.
    var start = _i
    while (_i < _n) {
      var c = _b[_i]
      if (c == 34) {                       // "\""
        var s = _b.utf8Slice(start, _i - start)
        _i = _i + 1
        return s
      }
      if (c == 92) break                    // "\\" — drop to slow path
      _i = _i + 1
    }
    if (_i >= _n) Fiber.abort("JSON: unterminated string")

    // Slow path: at least one escape. Accumulate the existing run
    // first, then process escapes one at a time.
    var parts = []
    if (_i > start) parts.add(_b.utf8Slice(start, _i - start))
    while (_i < _n) {
      var c = _b[_i]
      if (c == 34) {                       // "\""
        _i = _i + 1
        return parts.join("")
      }
      if (c == 92) {                       // "\\"
        _i = _i + 1
        if (_i >= _n) Fiber.abort("JSON: unterminated escape")
        var esc = _b[_i]
        if (esc == 34) {                   // \"
          parts.add("\"")
        } else if (esc == 92) {            // \\
          parts.add("\\")
        } else if (esc == 47) {            // \/
          parts.add("/")
        } else if (esc == 110) {           // \n
          parts.add("\n")
        } else if (esc == 116) {           // \t
          parts.add("\t")
        } else if (esc == 114) {           // \r
          parts.add("\r")
        } else if (esc == 98) {            // \b
          parts.add("\b")
        } else if (esc == 102) {           // \f
          parts.add("\f")
        } else if (esc == 117) {           // \u
          parts.add(parseUnicodeEscape_)
        } else {
          Fiber.abort("JSON: invalid escape \\%(esc) at offset %(_i)")
        }
        _i = _i + 1
        // Run-coalesce: scan unbroken to the next escape or quote
        // and accumulate that span in one slice.
        var rstart = _i
        while (_i < _n) {
          var d = _b[_i]
          if (d == 34 || d == 92) break
          _i = _i + 1
        }
        if (_i > rstart) parts.add(_b.utf8Slice(rstart, _i - rstart))
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
    // Decode the 4 hex bytes inline. Avoid asking for a Wren String
    // slice + re-walk; one byte at a time is fewer allocations.
    var code = 0
    var j = 1
    while (j <= 4) {
      var b = _b[_i + j]
      var d
      if (b >= 48 && b <= 57) {            // 0-9
        d = b - 48
      } else if (b >= 97 && b <= 102) {    // a-f
        d = b - 87
      } else if (b >= 65 && b <= 70) {     // A-F
        d = b - 55
      } else {
        Fiber.abort("JSON: bad hex digit at offset %(_i + j)")
      }
      code = code * 16 + d
      j = j + 1
    }
    _i = _i + 4
    return String.fromCodePoint(code)
  }

  parseNumber_ {
    var start = _i
    if (_b[_i] == 45) _i = _i + 1               // "-"
    while (_i < _n && isDigitByte_(_b[_i])) _i = _i + 1
    if (_i < _n && _b[_i] == 46) {              // "."
      _i = _i + 1
      while (_i < _n && isDigitByte_(_b[_i])) _i = _i + 1
    }
    if (_i < _n && (_b[_i] == 101 || _b[_i] == 69)) {   // "e" / "E"
      _i = _i + 1
      if (_i < _n && (_b[_i] == 43 || _b[_i] == 45)) _i = _i + 1  // "+" / "-"
      while (_i < _n && isDigitByte_(_b[_i])) _i = _i + 1
    }
    var slice = _b.utf8Slice(start, _i - start)
    var n = Num.fromString(slice)
    if (n == null) Fiber.abort("JSON: invalid number %(slice)")
    return n
  }

  parseBool_ {
    // "true"  → t r u e   bytes 116, 114, 117, 101
    if (_i + 4 <= _n &&
        _b[_i] == 116 && _b[_i + 1] == 114 &&
        _b[_i + 2] == 117 && _b[_i + 3] == 101) {
      _i = _i + 4
      return true
    }
    // "false" → f a l s e   bytes 102, 97, 108, 115, 101
    if (_i + 5 <= _n &&
        _b[_i] == 102 && _b[_i + 1] == 97  &&
        _b[_i + 2] == 108 && _b[_i + 3] == 115 &&
        _b[_i + 4] == 101) {
      _i = _i + 5
      return false
    }
    Fiber.abort("JSON: invalid literal at offset %(_i)")
  }

  parseNull_ {
    // "null" → n u l l   bytes 110, 117, 108, 108
    if (_i + 4 <= _n &&
        _b[_i] == 110 && _b[_i + 1] == 117 &&
        _b[_i + 2] == 108 && _b[_i + 3] == 108) {
      _i = _i + 4
      return null
    }
    Fiber.abort("JSON: invalid literal at offset %(_i)")
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
    //
    // The probe uses the list-as-box pattern instead of capturing
    // `fiber.try()`'s return — `Fiber.try()`'s clean-return slot
    // reads back as stale memory under both the interpreter and the
    // tiered JIT (see auto-memory note), so a hook that returns a
    // freshly-constructed value (string interpolation, map literal)
    // surfaces as `null` here and the encoder serialises the literal
    // string "null". Writing through `box[0]` lifts the value out of
    // the fiber-return slot path entirely.
    var cls = value.type
    var box = [null]
    var probed = Fiber.new { box[0] = value.toJson() }
    probed.try()
    if (probed.error == null) {
      var ret = box[0]
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

