// @hatch:csv — RFC 4180 CSV parsing + serialization.
//
//   import "@hatch:csv" for Csv
//
//   // Simplest form: rows as List<List<String>>.
//   var rows = Csv.parse("a,b,c\n1,2,3\n4,5,6")
//   rows[0][0]                  // "a"
//   rows[1][2]                  // "3"
//
//   // With a header row: rows as List<Map<String, String>>.
//   var people = Csv.parse(
//     "name,age\nalice,30\nbob,25",
//     {"header": true}
//   )
//   people[0]["name"]           // "alice"
//   people[1]["age"]            // "25"
//
//   // Encode a list of maps (keys become the header row).
//   Csv.encode(
//     [{"name": "alice", "age": 30}, {"name": "bob", "age": 25}],
//     {"header": true}
//   )
//   // name,age\r\nalice,30\r\nbob,25\r\n
//
//   // Encode a list of lists (no header).
//   Csv.encode([["x", "y"], [1, 2]])
//   // x,y\r\n1,2\r\n
//
// Options:
//
//   delimiter   — column separator (default `,`). One character.
//   quote       — quoting character (default `"`). One character.
//   header      — parse: treat first row as column names, return
//                         List<Map>. default false.
//               — encode: include a header row derived from the
//                         first record's keys (Map rows) or the
//                         caller's explicit `columns` option.
//                         default false.
//   columns     — encode: explicit column order (List<String>). If
//                 omitted for Map rows, keys of the first record
//                 are used; order isn't guaranteed across Wren
//                 Map implementations so specify this when the
//                 layout matters.
//   lineEnding  — encode: "\r\n" (RFC 4180, default) or "\n".
//
// Values on encode:
//   * Strings pass through (with quoting when they contain the
//     delimiter, quote char, or newline).
//   * Num/Bool/null convert via `.toString`; null → empty cell.
//   * Anything else aborts.
//
// Parse is forgiving about line endings — `\r\n`, `\n`, and bare
// `\r` all terminate a row.

class Csv {
  // --- parse -----------------------------------------------------------

  static parse(text) { parse(text, null) }
  static parse(text, options) {
    if (!(text is String)) Fiber.abort("Csv.parse: text must be a string")
    if (options != null && !(options is Map)) {
      Fiber.abort("Csv.parse: options must be a Map")
    }
    var opts     = options == null ? {} : options
    var delim    = opts.containsKey("delimiter") ? opts["delimiter"] : ","
    var quote    = opts.containsKey("quote")     ? opts["quote"]     : "\""
    var header   = opts.containsKey("header")    ? opts["header"]    : false

    if (!(delim is String) || delim.count != 1) {
      Fiber.abort("Csv.parse: delimiter must be a one-character string")
    }
    if (!(quote is String) || quote.count != 1) {
      Fiber.abort("Csv.parse: quote must be a one-character string")
    }

    var rows = Parser_.parse_(text, delim, quote)

    if (!header) return rows
    if (rows.count == 0) return []

    var headers = rows[0]
    var out = []
    var i = 1
    while (i < rows.count) {
      var row = rows[i]
      var m = {}
      var j = 0
      while (j < headers.count) {
        m[headers[j]] = j < row.count ? row[j] : ""
        j = j + 1
      }
      out.add(m)
      i = i + 1
    }
    return out
  }

  // --- encode ----------------------------------------------------------

  static encode(rows) { encode(rows, null) }
  static encode(rows, options) {
    if (!(rows is List)) Fiber.abort("Csv.encode: rows must be a list")
    if (options != null && !(options is Map)) {
      Fiber.abort("Csv.encode: options must be a Map")
    }
    var opts    = options == null ? {} : options
    var delim   = opts.containsKey("delimiter")  ? opts["delimiter"]  : ","
    var quote   = opts.containsKey("quote")      ? opts["quote"]      : "\""
    var header  = opts.containsKey("header")     ? opts["header"]     : false
    var eol     = opts.containsKey("lineEnding") ? opts["lineEnding"] : "\r\n"
    var columns = opts.containsKey("columns")    ? opts["columns"]    : null

    if (!(delim is String) || delim.count != 1) {
      Fiber.abort("Csv.encode: delimiter must be a one-character string")
    }
    if (!(quote is String) || quote.count != 1) {
      Fiber.abort("Csv.encode: quote must be a one-character string")
    }
    if (eol != "\r\n" && eol != "\n") {
      Fiber.abort("Csv.encode: lineEnding must be \"\\r\\n\" or \"\\n\"")
    }
    if (columns != null && !(columns is List)) {
      Fiber.abort("Csv.encode: columns must be a list of strings")
    }

    if (rows.count == 0) return ""

    // Normalize every row to a List of strings, in a stable
    // column order derived either from the caller's `columns`,
    // the first Map row's keys, or positional for List rows.
    var cols = columns
    var firstIsMap = rows[0] is Map
    if (cols == null && firstIsMap) {
      cols = []
      for (entry in rows[0]) cols.add(entry.key)
    }

    var out = []
    if (header && firstIsMap) {
      out.add(Encoder_.encodeRow_(cols, delim, quote))
      out.add(eol)
    } else if (header && !firstIsMap) {
      Fiber.abort("Csv.encode: header=true requires Map rows or explicit columns")
    }

    var i = 0
    while (i < rows.count) {
      var r = rows[i]
      var cells
      if (r is Map) {
        if (cols == null) Fiber.abort("Csv.encode: Map rows require columns")
        cells = []
        var k = 0
        while (k < cols.count) {
          cells.add(r.containsKey(cols[k]) ? r[cols[k]] : null)
          k = k + 1
        }
      } else if (r is List) {
        cells = r
      } else {
        Fiber.abort("Csv.encode: each row must be a List or Map")
      }
      out.add(Encoder_.encodeRow_(cells, delim, quote))
      out.add(eol)
      i = i + 1
    }
    return out.join("")
  }
}

// --- Parser -----------------------------------------------------------------

class Parser_ {
  static parse_(text, delim, quote) {
    var rows = []
    var row  = []
    var field = []                  // buffer of characters for the current field
    var n = text.count
    var i = 0
    // In-quote state: the current field started with the quote
    // character; stay inside until we see a matching close.
    var inQuote = false
    // `fieldDirty` distinguishes "row has zero cells, trailing
    // newline" from "row had one empty cell". The CSV ABNF treats
    // a trailing newline as end-of-row, not a phantom empty cell.
    var fieldDirty = false

    while (i < n) {
      var c = text[i]

      if (inQuote) {
        if (c == quote) {
          // Quote inside quote: either an escaped quote (`""`) or
          // the end of the field.
          if (i + 1 < n && text[i + 1] == quote) {
            field.add(quote)
            i = i + 2
          } else {
            inQuote = false
            i = i + 1
          }
        } else {
          field.add(c)
          i = i + 1
        }
      } else {
        if (c == quote) {
          // Opening quote. Standard CSV requires this to be the
          // first char of the field; we allow lax placement and
          // just toggle the flag — saves bailing on slightly
          // non-standard input.
          inQuote = true
          fieldDirty = true
          i = i + 1
        } else if (c == delim) {
          row.add(field.join(""))
          field.clear()
          fieldDirty = false
          i = i + 1
          // A trailing delimiter means "one more empty field
          // follows" — we don't clear `fieldDirty` here (well we
          // did above, but we want the NEXT field to be
          // materialised). Easiest: flip it right back.
          fieldDirty = true
        } else if (c == "\r" || c == "\n") {
          // End of row. Honour CRLF, LF, or bare CR.
          if (fieldDirty || row.count > 0) {
            row.add(field.join(""))
          }
          field.clear()
          fieldDirty = false
          if (row.count > 0) rows.add(row)
          row = []
          i = i + 1
          // Swallow the LF half of a CRLF.
          if (c == "\r" && i < n && text[i] == "\n") i = i + 1
        } else {
          field.add(c)
          fieldDirty = true
          i = i + 1
        }
      }
    }

    // Trailing field at EOF (no terminating newline).
    if (inQuote) Fiber.abort("Csv.parse: unterminated quoted field at offset %(i)")
    if (fieldDirty || row.count > 0) {
      row.add(field.join(""))
      rows.add(row)
    }
    return rows
  }
}

// --- Encoder ----------------------------------------------------------------

class Encoder_ {
  static encodeRow_(cells, delim, quote) {
    var out = []
    var i = 0
    while (i < cells.count) {
      if (i > 0) out.add(delim)
      out.add(encodeCell_(cells[i], delim, quote))
      i = i + 1
    }
    return out.join("")
  }

  static encodeCell_(v, delim, quote) {
    if (v == null) return ""
    var s
    if (v is String) {
      s = v
    } else if (v is Num || v is Bool) {
      s = v.toString
    } else {
      Fiber.abort("Csv.encode: cell values must be String, Num, Bool, or null")
    }

    // Quote-wrap when the cell contains the delimiter, the quote
    // char, CR, or LF. Doubles any embedded quote char per RFC 4180.
    var needsQuote = s.contains(delim) || s.contains(quote) ||
                     s.contains("\r") || s.contains("\n")
    if (!needsQuote) return s

    var esc = s.replace(quote, quote + quote)
    return quote + esc + quote
  }
}
