/// `@hatch:path` — filesystem path manipulation.
///
/// ```wren
/// import "@hatch:path" for Path
///
/// Path.join("foo", "bar", "baz.txt")     // "foo/bar/baz.txt"
/// Path.join(["foo", "bar"])              // "foo/bar"
/// Path.parent("foo/bar/baz.txt")         // "foo/bar"
/// Path.basename("foo/bar/baz.txt")       // "baz.txt"
/// Path.stem("foo/bar/baz.txt")           // "baz"
/// Path.extname("foo/bar/baz.txt")        // ".txt"
/// Path.normalize("foo//./bar/../x")      // "foo/x"
/// Path.isAbsolute("/a/b")                // true
/// Path.split("foo/bar/baz")              // ["foo", "bar", "baz"]
/// ```
///
/// Unix-style paths only (`/` separator, no drive letters).
/// Windows paths would need OS detection via FFI, which lives in
/// `@hatch:os`; until that lands, consumers on Windows should use
/// forward slashes explicitly or post-process the result.
///
/// All operations are pure string manipulation — nothing touches
/// the filesystem here. That belongs in `@hatch:fs`.

class Path {
  static SEP { "/" }

  // -- join ------------------------------------------------------------------

  /// Two-arg form: the common case. `a/b/c` chains as
  /// `Path.join(Path.join("a", "b"), "c")`.
  static join(a, b) {
    if (!(a is String) || !(b is String)) {
      Fiber.abort("Path.join: arguments must be strings")
    }
    if (b == "") return a
    if (a == "") return b
    // An absolute `b` wins — it "resets" the path the same way
    // `cd /tmp; cd /home` ends up at `/home`.
    if (isAbsolute(b)) return b
    if (endsWithSep_(a)) return a + b
    return a + SEP + b
  }

  /// List form: `Path.join(["a", "b", "c"])`. Empty entries are
  /// skipped so callers can pass conditional segments without
  /// pre-filtering.
  static join(parts) {
    if (parts is String) return parts
    if (!(parts is List)) {
      Fiber.abort("Path.join: expected a list or two strings")
    }
    var result = ""
    var first = true
    var i = 0
    while (i < parts.count) {
      var p = parts[i]
      if (!(p is String)) {
        Fiber.abort("Path.join: list elements must be strings (got %(p.type))")
      }
      i = i + 1
      if (p == "") continue
      if (first) {
        result = p
        first = false
      } else {
        result = join(result, p)
      }
    }
    return result
  }

  // -- split / components ----------------------------------------------------

  /// Split on `/`, preserving the absolute-path "" first element so
  /// `split("/a/b")[0] == ""` and `split("a/b")[0] == "a"`.
  static split(path) {
    if (!(path is String)) Fiber.abort("Path.split: expected a string")
    if (path == "") return []
    return path.split(SEP)
  }

  // -- parent / basename / stem / extname ------------------------------------

  /// Directory portion. `"/a/b/c"` → `"/a/b"`, `"c"` → `""`,
  /// `"/"` → `"/"`.
  static parent(path) {
    if (!(path is String)) Fiber.abort("Path.parent: expected a string")
    if (path == "") return ""
    var stripped = stripTrailingSep_(path)
    if (stripped == "") return SEP         // was just separators
    var idx = lastIndexOf_(stripped, SEP)
    if (idx < 0) return ""
    if (idx == 0) return SEP               // "/x" → "/"
    return stripped[0...idx]
  }

  /// Final path component. `"/a/b/c.txt"` → `"c.txt"`,
  /// `"/"` → `""`, `"foo"` → `"foo"`.
  static basename(path) {
    if (!(path is String)) Fiber.abort("Path.basename: expected a string")
    var stripped = stripTrailingSep_(path)
    if (stripped == "") return ""
    var idx = lastIndexOf_(stripped, SEP)
    if (idx < 0) return stripped
    return stripped[(idx + 1)...stripped.count]
  }

  /// basename without the extension. `"foo/bar.txt"` → `"bar"`.
  /// Leading-dot files without a further `.` keep their full name
  /// (`".bashrc"` → `".bashrc"`).
  static stem(path) {
    var base = basename(path)
    if (base == "") return ""
    var ext = extname(base)
    if (ext == "") return base
    return base[0...(base.count - ext.count)]
  }

  /// Extension including the leading dot. `"foo.tar.gz"` → `".gz"`,
  /// `"README"` → `""`, `".bashrc"` → `""` (leading dot alone is not
  /// an extension).
  static extname(path) {
    var base = basename(path)
    var idx = lastIndexOf_(base, ".")
    // No dot, or leading dot with no other — no extension.
    if (idx <= 0) return ""
    return base[idx...base.count]
  }

  /// -- absolute / relative ---------------------------------------------------

  static isAbsolute(path) {
    if (!(path is String)) Fiber.abort("Path.isAbsolute: expected a string")
    if (path.count == 0) return false
    return path[0] == SEP
  }

  static isRelative(path) { !isAbsolute(path) }

  // -- normalize -------------------------------------------------------------

  /// Collapse `a/./b` → `a/b`, `a//b` → `a/b`, and resolve `..`
  /// against the preceding segment. Absolute paths stay absolute;
  /// relative paths that ascend above the start keep the leading
  /// `..` segments (we can't resolve past the root of a relative
  /// path without touching the filesystem).
  static normalize(path) {
    if (!(path is String)) Fiber.abort("Path.normalize: expected a string")
    if (path == "") return "."
    var absolute = isAbsolute(path)
    var segments = []
    var start = absolute ? 1 : 0
    var i = start
    var seg_start = start
    while (i < path.count) {
      if (path[i] == SEP) {
        if (i > seg_start) segments.add(path[seg_start...i])
        i = i + 1
        seg_start = i
      } else {
        i = i + 1
      }
    }
    if (seg_start < path.count) segments.add(path[seg_start...path.count])

    // Walked via while+index so `continue` doesn't corrupt the
    // iterator (see QUIRKS.md: for-in `continue` binding bug).
    var out = []
    var si = 0
    while (si < segments.count) {
      var s = segments[si]
      si = si + 1
      if (s == "" || s == ".") continue
      if (s == "..") {
        // Pop the previous segment unless there isn't one we can
        // legitimately drop (i.e. preserve leading `..` in relative
        // paths; absolute paths silently stop at `/`).
        if (out.count > 0 && out[out.count - 1] != "..") {
          out = out[0...(out.count - 1)]
          continue
        }
        if (absolute) continue
      }
      out.add(s)
    }

    if (out.count == 0) return absolute ? SEP : "."
    var body = out.join(SEP)
    return absolute ? SEP + body : body
  }

  // -- internals -------------------------------------------------------------

  static endsWithSep_(s) {
    if (s.count == 0) return false
    return s[s.count - 1] == SEP
  }

  // Drop all trailing `/`s except on the root itself.
  static stripTrailingSep_(s) {
    if (s == "") return ""
    var i = s.count
    while (i > 1 && s[i - 1] == SEP) i = i - 1
    return s[0...i]
  }

  // Wren's String lacks `lastIndexOf` — scan manually.
  static lastIndexOf_(s, needle) {
    var i = s.count - 1
    while (i >= 0) {
      if (s[i] == needle) return i
      i = i - 1
    }
    return -1
  }
}
