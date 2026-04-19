// @hatch:assert — fluent assertions for `*.spec.wren` files.
//
// Usage:
//
//   import "@hatch:assert" for Expect
//
//   Expect.that(1 + 1).toBe(2)
//   Expect.that([1, 2, 3]).toEqual([1, 2, 3])
//   Expect.that(null).toBeNull()
//   Expect.that(42).not.toBeNull()
//   Expect.that(Fn.new { boom() }).toAbort()
//
// Each failing assertion aborts the enclosing fiber with a message
// the test runner (`@hatch:test`, landing next) captures and
// attributes to the offending `it` block. Used bare, a failed
// assertion crashes the spec file with the same message — enough
// signal for a standalone `wlift foo.spec.wren` run.

class Assertion {
  construct new(actual) {
    _actual = actual
    _inverted = false
  }

  // Flip the expected outcome of the next matcher. Chained, so
  // `Expect.that(x).not.toBeNull()` reads naturally.
  not {
    _inverted = true
    return this
  }

  // -- Equality ------------------------------------------------------------

  // Reference equality via `==`. Two different list instances that
  // happen to hold the same elements are *not* equal here — use
  // `toEqual` for structural comparison.
  toBe(expected) {
    check_(_actual == expected, "toBe", expected)
  }

  // Structural equality. Lists and maps compare element-by-element;
  // everything else falls back to `==`.
  toEqual(expected) {
    check_(deepEquals_(_actual, expected), "toEqual", expected)
  }

  // -- Nullability ---------------------------------------------------------

  toBeNull() {
    check_(_actual == null, "toBeNull", null)
  }

  // -- Truthiness ----------------------------------------------------------
  //
  // Wren's truthiness: only `false` and `null` are falsy. Everything
  // else (including 0 and "") is truthy. Matchers mirror that.

  toBeTruthy() {
    check_(_actual != null && _actual != false, "toBeTruthy", null)
  }

  toBeFalsy() {
    check_(_actual == null || _actual == false, "toBeFalsy", null)
  }

  // -- Ordering ------------------------------------------------------------

  toBeGreaterThan(other) {
    check_(_actual > other, "toBeGreaterThan", other)
  }

  toBeGreaterThanOrEqual(other) {
    check_(_actual >= other, "toBeGreaterThanOrEqual", other)
  }

  toBeLessThan(other) {
    check_(_actual < other, "toBeLessThan", other)
  }

  toBeLessThanOrEqual(other) {
    check_(_actual <= other, "toBeLessThanOrEqual", other)
  }

  // -- Collections ---------------------------------------------------------

  // `contains(item)` on a List walks the list; on a String, it's
  // substring containment; on a Map, it checks key presence.
  toContain(item) {
    var ok
    if (_actual is List) {
      ok = _actual.contains(item)
    } else if (_actual is String) {
      ok = _actual.contains(item)
    } else if (_actual is Map) {
      ok = _actual.containsKey(item)
    } else {
      Fiber.abort("toContain: %(typeName_(_actual)) isn't searchable")
    }
    check_(ok, "toContain", item)
  }

  // Types — classes only; scalars go through `toBe` / `toBeTruthy`.
  toBeInstanceOf(klass) {
    check_(_actual is klass, "toBeInstanceOf", klass)
  }

  // -- Aborts --------------------------------------------------------------

  // Pass a zero-arg Fn. The matcher runs it inside a fresh fiber
  // and checks `fiber.error` — distinct from `try()`'s return value
  // since a successful fiber returns the expression result (which
  // could equal null, which would look like "no error"). Use
  // `toAbortWith` to also pin the abort message.
  toAbort() {
    if (!(_actual is Fn)) Fiber.abort("toAbort: actual must be a Fn")
    var fib = Fiber.new(_actual)
    fib.try()
    check_(fib.error != null, "toAbort", null)
  }

  toAbortWith(message) {
    if (!(_actual is Fn)) Fiber.abort("toAbortWith: actual must be a Fn")
    var fib = Fiber.new(_actual)
    fib.try()
    var ok = fib.error != null && fib.error == message
    check_(ok, "toAbortWith", message)
  }

  // -- Internals -----------------------------------------------------------

  check_(ok, matcher, expected) {
    var passed = _inverted ? !ok : ok
    if (passed) return
    // Reset for safety: the Fiber.abort below stops execution, but
    // leaving the flipped flag hanging would be a landmine if
    // future code ever caught and resumed.
    _inverted = false
    var neg = _inverted ? "not " : (expected == null && matcher != "toBe" ? "" : "")
    var shown = _inverted ? "not " : ""
    Fiber.abort(
      "assertion failed: " +
      "expected %(format_(_actual)) " +
      "%(shown)%(matcher)" +
      (expected == null ? "" : " %(format_(expected))")
    )
  }

  deepEquals_(a, b) {
    // Route compound types before touching `==`: Wren's List and
    // Map don't define `==`, so falling through would throw rather
    // than returning false. Check types first, recurse structurally.
    if (a is List) return b is List && listEquals_(a, b)
    if (a is Map) return b is Map && mapEquals_(a, b)
    // If `a` isn't a compound type but `b` is, they can't be equal.
    if (b is List || b is Map) return false
    // Scalars (Num / String / Bool / Null) and user classes with a
    // meaningful `==` override use regular equality.
    return a == b
  }

  listEquals_(a, b) {
    if (a.count != b.count) return false
    for (i in 0...a.count) {
      if (!deepEquals_(a[i], b[i])) return false
    }
    return true
  }

  mapEquals_(a, b) {
    if (a.count != b.count) return false
    for (key in a.keys) {
      if (!b.containsKey(key)) return false
      if (!deepEquals_(a[key], b[key])) return false
    }
    return true
  }

  // Stringify values for assertion messages so the output reads
  // naturally. Strings get quoted; everything else uses `toString`.
  format_(v) {
    if (v is String) return "\"%(v)\""
    if (v == null) return "null"
    return v.toString
  }

  typeName_(v) {
    if (v is List) return "List"
    if (v is Map) return "Map"
    if (v is String) return "String"
    if (v is Num) return "Num"
    if (v is Bool) return "Bool"
    if (v == null) return "Null"
    return "value"
  }
}

// The single entry point specs touch. Deliberately terse —
// `Expect.that(x).toBe(y)` reads as plain English.
class Expect {
  static that(actual) { Assertion.new(actual) }
}
