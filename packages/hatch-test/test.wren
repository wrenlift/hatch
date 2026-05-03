/// `@hatch:test`: a small test runner for `*.spec.wren` files.
///
/// ```wren
/// import "@hatch:test"   for Test
/// import "@hatch:assert" for Expect
///
/// Test.describe("List") {
///   Test.it("indexes from zero") {
///     Expect.that([1, 2][0]).toBe(1)
///   }
///   Test.it("reports count") {
///     Expect.that([1, 2].count).toBe(2)
///   }
/// }
///
/// Test.run()
/// ```
///
/// `describe` records a group name; `it` records a single test
/// case under the current group. `run()` iterates registered
/// cases, runs each inside a fresh fiber, captures any abort as
/// a failure, and prints a summary. Exits non-zero on any
/// failure so `hatch test` (and plain `wlift foo.spec.wren`)
/// both propagate the result.
///
/// Two configuration knobs, both static, both honoured by
/// `Test.run()`:
///
/// * `Test.filter = "..."` — substring matched against every
///   case's `<group> > <name>` label. Non-matching cases are
///   skipped. Empty (the default) disables filtering.
/// * `Test.reporter = "json"` — emit one JSON-Lines event per
///   case-start / pass / fail / skip plus a trailing summary,
///   instead of the human-readable text summary. The JSON
///   reporter is what `hatch test --json` consumes; plain
///   `wlift foo.spec.wren` defaults to the text reporter.
///
/// The text reporter prints one `Ok:`/`Fail:` line per case
/// with the elapsed time and a status glyph, plus a summary at
/// the bottom with the total elapsed across all cases.
/// Colourised through `@hatch:fmt`; flip `Fmt.enabled = false`
/// from a bootstrap if you're piping into a non-TTY consumer
/// that can't handle ANSI.
///
/// Deliberately small surface beyond those two: no before /
/// after hooks, no async, no skip markers in source. First-wave
/// packages need only "did this work?". Heavier runner features
/// land if and when they earn their keep.

import "@hatch:fmt" for Fmt

class Test {
  // --- Registration ------------------------------------------------------

  /// `describe(name) { body }` in Wren calls `describe(name, Fn.new { body })`.
  /// The body runs during registration; `Test.it` calls inside it
  /// record cases against the current group name.
  static describe(name, body) {
    if (!(body is Fn)) Fiber.abort("Test.describe expects a block body")
    var prev = currentGroup_
    __currentGroup = name
    body.call()
    __currentGroup = prev
  }

  static it(name, body) {
    if (!(body is Fn)) Fiber.abort("Test.it expects a block body")
    cases_.add([currentGroup_, name, body])
  }

  // --- Configuration -----------------------------------------------------

  static filter { __filter == null ? "" : __filter }
  static filter=(value) { __filter = (value == null) ? "" : value }

  static reporter { __reporter == null ? "text" : __reporter }
  static reporter=(value) {
    if (value != "text" && value != "json") {
      Fiber.abort("Test.reporter accepts \"text\" or \"json\"")
    }
    __reporter = value
  }

  // --- Execution ---------------------------------------------------------

  /// Run every registered case the filter allows. Prints a
  /// summary in the active reporter shape; aborts the fiber
  /// with a non-null error on any failure so the exit code
  /// reflects the result.
  static run() {
    var startClock = System.clock
    var passed = 0
    var failed = 0
    var skipped = 0
    var failures = []
    var f = filter
    var r = reporter

    for (entry in cases_) {
      var group = entry[0]
      var name = entry[1]
      var body = entry[2]
      var label = group == null ? name : "%(group) > %(name)"

      if (f != "" && !label.contains(f)) {
        skipped = skipped + 1
        if (r == "json") emitEvent_("skip", group, name, null, null)
        continue
      }

      if (r == "json") emitEvent_("start", group, name, null, null)
      var caseStart = System.clock
      var fib = Fiber.new(body)
      fib.try()
      var elapsedMs = (System.clock - caseStart) * 1000

      if (fib.error == null) {
        passed = passed + 1
        if (r == "json") {
          emitEvent_("pass", group, name, null, elapsedMs)
        } else {
          System.print(
            Fmt.green("Ok:") + " " +
            "\"%(label)\"" + " " +
            Fmt.dim(formatMs_(elapsedMs)) + " " +
            Fmt.green("✓")
          )
        }
      } else {
        failed = failed + 1
        failures.add([group, name, fib.error])
        if (r == "json") {
          emitEvent_("fail", group, name, fib.error, elapsedMs)
        } else {
          System.print(
            Fmt.bold(Fmt.red("Fail:")) + " " +
            "\"%(label)\"" + " " +
            Fmt.dim(formatMs_(elapsedMs)) + " " +
            Fmt.red("✗")
          )
          System.print("      %(fib.error)")
        }
      }
    }

    var totalElapsedMs = (System.clock - startClock) * 1000

    if (r == "json") {
      emitSummary_(passed, failed, skipped, totalElapsedMs)
    } else {
      var total = passed + failed
      var totalStr = formatMs_(totalElapsedMs)
      System.print("")
      if (failed == 0) {
        System.print(
          Fmt.green("ok:") + " " +
          "%(passed)/%(total) passed" + " " +
          Fmt.dim("(%(totalStr))")
        )
      } else {
        System.print(
          Fmt.bold(Fmt.red("FAILED:")) + " " +
          "%(passed)/%(total) passed, %(failed) failed" + " " +
          Fmt.dim("(%(totalStr))")
        )
      }
    }

    // Reset case + group state so repeat calls in the same
    // process start fresh. Filter and reporter stay sticky —
    // a script that flipped them mid-run shouldn't have to
    // reapply across hot reloads.
    __cases = null
    __currentGroup = null

    if (failed > 0) Fiber.abort("%(failed) test failure(s)")
  }

  // --- Internals ---------------------------------------------------------

  static cases_ {
    if (__cases == null) __cases = []
    return __cases
  }

  static currentGroup_ {
    return __currentGroup
  }

  /// Hand-rolled JSON-Lines emit. Avoids a transitive
  /// `@hatch:json` pin so `@hatch:test` stays self-contained;
  /// the shape is small enough that a 30-line encoder is the
  /// pragmatic choice over a dep edge.
  static emitEvent_(kind, group, name, message, durationMs) {
    var buf = "{\"event\":" + jsonString_(kind)
    if (group != null) buf = buf + ",\"group\":" + jsonString_(group)
    buf = buf + ",\"name\":" + jsonString_(name)
    if (message != null) buf = buf + ",\"message\":" + jsonString_(message.toString)
    if (durationMs != null) buf = buf + ",\"duration_ms\":" + durationMs.toString
    buf = buf + "}"
    System.print(buf)
  }

  static emitSummary_(passed, failed, skipped, durationMs) {
    System.print(
      "{\"event\":\"summary\"" +
      ",\"passed\":" + passed.toString +
      ",\"failed\":" + failed.toString +
      ",\"skipped\":" + skipped.toString +
      ",\"duration_ms\":" + durationMs.toString +
      "}"
    )
  }

  /// Format a millisecond Num for the text reporter — two
  /// decimals max so `0.02384185791015625` reads as `0.02ms`
  /// without distracting precision noise. Drops decimals
  /// entirely past 100 ms (`1234.5` → `1235ms`) since
  /// sub-millisecond detail stops mattering at that scale.
  static formatMs_(ms) {
    if (ms >= 100) return "%(ms.round)ms"
    var s = ms.toString
    var dot = s.indexOf(".")
    if (dot < 0) return "%(s)ms"
    var end = dot + 3
    if (end > s.count) end = s.count
    return "%(s[0...end])ms"
  }

  /// Quote and escape a Wren string into a JSON string literal.
  /// Handles the four control chars JSON requires escapes for
  /// plus the `"` and `\` body escapes. Anything else passes
  /// through — we don't try to emit `\uXXXX` for non-ASCII
  /// since Wren strings are UTF-8 and JSON parsers accept
  /// UTF-8 byte sequences inside string literals.
  static jsonString_(s) {
    var out = "\""
    for (c in s) {
      if (c == "\"") {
        out = out + "\\\""
      } else if (c == "\\") {
        out = out + "\\\\"
      } else if (c == "\n") {
        out = out + "\\n"
      } else if (c == "\r") {
        out = out + "\\r"
      } else if (c == "\t") {
        out = out + "\\t"
      } else {
        out = out + c
      }
    }
    return out + "\""
  }
}
