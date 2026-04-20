// @hatch:regex — compiled regular expressions.
//
//   import "@hatch:regex" for Regex
//
//   // Compile once, reuse.
//   var email = Regex.compile("(\\w+)@(\\w+\\.\\w+)")
//
//   email.isMatch("ping@host.io")              // true
//   email.find("ping@host.io").text            // "ping@host.io"
//   email.find("ping@host.io").groups          // ["ping@host.io", "ping", "host.io"]
//
//   // Flags as a second arg: i, m, s, U, x.
//   Regex.compile("hello", "i").isMatch("HELLO")   // true
//
//   // Replace — $1, $2, $name, $$ available in the replacement.
//   Regex.compile("(\\w+)").replaceAll("hi bob", "<$1>")  // "<hi> <bob>"
//
//   // Split.
//   Regex.compile(",\\s*").split("a, b ,c,   d")          // ["a", "b", "c", "d"]
//
//   // Escape user input before embedding in a pattern.
//   Regex.escape("1.0")       // "1\.0"
//
// `Regex` instances hold a numeric id into a runtime registry. The
// runtime keeps the compiled automaton alive until `regex.free` is
// called (or the VM exits). For short scripts you can leak — for
// long-running servers that build lots of patterns, call `free`
// when done.
//
// Backed by the `regex` crate (linear-time NFA, Unicode-aware).
// Pattern syntax: docs.rs/regex/latest/regex/#syntax — it's a
// Perl-ish dialect without backreferences or lookaround.

import "regex" for RegexCore

class Match {
  construct new_(map) {
    _map = map
  }

  text     { _map["text"] }
  start    { _map["start"] }
  end      { _map["end"] }
  groups   { _map["groups"] }
  named    { _map["named"] }

  group(i) { _map["groups"][i] }
  group(name) {
    if (name is String) return _map["named"][name]
    return _map["groups"][name]
  }

  toString { "Match(%(text) @[%(start)..%(end)])" }
}

class Regex {
  // Compile a pattern string. `flags` is an optional string
  // containing any combination of: i m s U x.
  construct new_(id, pattern) {
    _id = id
    _pattern = pattern
  }

  static compile(pattern)        { compile(pattern, null) }
  static compile(pattern, flags) {
    if (!(pattern is String)) Fiber.abort("Regex.compile: pattern must be a string")
    if (flags != null && !(flags is String)) {
      Fiber.abort("Regex.compile: flags must be a string or null")
    }
    var id = RegexCore.compile(pattern, flags)
    return Regex.new_(id, pattern)
  }

  // `Regex.escape(text)` — returns a pattern that matches `text`
  // literally. Useful for embedding user-supplied strings.
  static escape(text) {
    if (!(text is String)) Fiber.abort("Regex.escape: text must be a string")
    return RegexCore.escape(text)
  }

  id      { _id }
  pattern { _pattern }

  // Free the underlying compiled automaton. Safe to call twice.
  // Any further use of this Regex will abort.
  free {
    if (_id == null) return
    RegexCore.free(_id)
    _id = null
  }

  isMatch(haystack) {
    checkAlive_()
    if (!(haystack is String)) Fiber.abort("Regex.isMatch: haystack must be a string")
    return RegexCore.isMatch(_id, haystack)
  }

  // First match as a `Match`, or null.
  find(haystack) {
    checkAlive_()
    if (!(haystack is String)) Fiber.abort("Regex.find: haystack must be a string")
    var raw = RegexCore.find(_id, haystack)
    if (raw == null) return null
    return Match.new_(raw)
  }

  // All matches, left-to-right. Returns `List<Match>` (possibly
  // empty).
  findAll(haystack) {
    checkAlive_()
    if (!(haystack is String)) Fiber.abort("Regex.findAll: haystack must be a string")
    var list = RegexCore.findAll(_id, haystack)
    var out = []
    var i = 0
    while (i < list.count) {
      out.add(Match.new_(list[i]))
      i = i + 1
    }
    return out
  }

  // Replace the FIRST match. Replacement may reference captures
  // with $1 / $name / $$ (literal $).
  replace(haystack, replacement) {
    checkAlive_()
    if (!(haystack is String)) Fiber.abort("Regex.replace: haystack must be a string")
    if (!(replacement is String)) Fiber.abort("Regex.replace: replacement must be a string")
    return RegexCore.replace(_id, haystack, replacement)
  }

  // Replace ALL matches.
  replaceAll(haystack, replacement) {
    checkAlive_()
    if (!(haystack is String)) Fiber.abort("Regex.replaceAll: haystack must be a string")
    if (!(replacement is String)) Fiber.abort("Regex.replaceAll: replacement must be a string")
    return RegexCore.replaceAll(_id, haystack, replacement)
  }

  // Split `haystack` on every match.
  split(haystack) {
    checkAlive_()
    if (!(haystack is String)) Fiber.abort("Regex.split: haystack must be a string")
    return RegexCore.split(_id, haystack)
  }

  // Split with a max piece count. `n = 0` → no limit.
  splitN(haystack, n) {
    checkAlive_()
    if (!(haystack is String)) Fiber.abort("Regex.splitN: haystack must be a string")
    if (!(n is Num)) Fiber.abort("Regex.splitN: n must be a number")
    return RegexCore.splitN(_id, haystack, n)
  }

  toString { "Regex(%(_pattern))" }

  checkAlive_() {
    if (_id == null) Fiber.abort("Regex: use after free")
  }
}
