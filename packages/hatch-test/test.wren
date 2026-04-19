// @hatch:test — tiny test runner for `*.spec.wren` files.
//
// Usage:
//
//   import "@hatch:test"   for Test
//   import "@hatch:assert" for Expect
//
//   Test.describe("List") {
//     Test.it("indexes from zero") {
//       Expect.that([1, 2][0]).toBe(1)
//     }
//     Test.it("reports count") {
//       Expect.that([1, 2].count).toBe(2)
//     }
//   }
//
//   Test.run()
//
// `describe` records a group name; `it` records a single test case
// under the current group. `run()` iterates registered cases, runs
// each inside a fresh fiber, captures any abort as a failure, and
// prints a summary. Exits non-zero on any failure so `hatch test`
// (and plain `wlift foo.spec.wren`) both propagate the result.
//
// Deliberately small surface: no before/after hooks, no async, no
// skip markers. First-wave packages just need "did this work?" —
// the heavier runner features land if/when they earn their keep.

class Test {
  // --- Registration ------------------------------------------------------

  // `describe(name) { body }` in Wren calls `describe(name, Fn.new { body })`.
  // The body runs during registration; `Test.it` calls inside it
  // record cases against the current group name.
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

  // --- Execution ---------------------------------------------------------

  // Run every registered case. Prints a summary; aborts the fiber
  // with a non-null error on any failure so the exit code reflects
  // the result.
  static run() {
    var passed = 0
    var failed = 0
    var failures = []

    for (entry in cases_) {
      var group = entry[0]
      var name = entry[1]
      var body = entry[2]

      var fib = Fiber.new(body)
      fib.try()

      if (fib.error == null) {
        passed = passed + 1
      } else {
        failed = failed + 1
        failures.add([group, name, fib.error])
      }
    }

    for (f in failures) {
      var label = f[0] == null ? f[1] : "%(f[0]) > %(f[1])"
      System.print("FAIL  %(label)")
      System.print("      %(f[2])")
    }
    var total = passed + failed
    if (failed == 0) {
      System.print("ok: %(passed)/%(total) passed")
    } else {
      System.print("FAILED: %(passed)/%(total) passed, %(failed) failed")
    }

    // Reset so repeat calls in the same process start fresh —
    // matters when specs are re-imported (e.g. hot reload).
    __cases = null
    __currentGroup = null

    if (failed > 0) Fiber.abort("%(failed) test failure(s)")
  }

  // --- Internals ---------------------------------------------------------

  // Lazy init for the global registries: Wren doesn't let us
  // declare a static field with an initializer, so we gate behind
  // getters that populate on first touch.

  static cases_ {
    if (__cases == null) __cases = []
    return __cases
  }

  static currentGroup_ {
    return __currentGroup
  }
}
