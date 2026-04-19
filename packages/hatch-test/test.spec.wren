// Self-spec for @hatch:test. Drives the runner against its own
// describe / it / run primitives. Bootstrap-heavy because we can't
// use `Test.it` to verify `Test.it` without first running it —
// so the outer assertions are bare Fiber + if statements, and then
// the final pass exercises the runner normally.

import "./test" for Test
import "../hatch-assert/assert" for Expect

// --- Bootstrap: exercise registration + run() without feeding
// them back into themselves --------------------------------------

// Describe + it record cases.
Test.describe("counting") {
  Test.it("one") { Expect.that(1).toBe(1) }
  Test.it("two") { Expect.that(2).toBe(2) }
}
Expect.that(Test.cases_.count).toBe(2)
Expect.that(Test.cases_[0][0]).toBe("counting")
Expect.that(Test.cases_[0][1]).toBe("one")

// Nested describes restore the outer group name on exit.
Test.describe("outer") {
  Test.describe("inner") {
    Test.it("nested case") { Expect.that(true).toBeTruthy() }
  }
  Test.it("post-nested case") { Expect.that(true).toBeTruthy() }
}
// case 2 was recorded under "inner"
Expect.that(Test.cases_[2][0]).toBe("inner")
// case 3 was recorded back under "outer" — nested describe
// restored the previous group
Expect.that(Test.cases_[3][0]).toBe("outer")

// Non-Fn arguments abort cleanly. The abort happens directly from
// `Test.it` — nesting it inside a `describe` body triggers a known
// runtime bug (see QUIRKS.md: "fiber abort through an intermediate
// closure call corrupts caller state"), so exercise it bare.
var aborted = Fiber.new { Test.it("x", "not a fn") }.try()
Expect.that(aborted).not.toBeNull()

// run() on an all-passing set succeeds and clears state.
// The pre-bootstrap cases we registered above are still there, so
// wipe them first to isolate this run.
Test.cases_.clear()
Test.describe("arith") {
  Test.it("adds") { Expect.that(1 + 1).toBe(2) }
  Test.it("multiplies") { Expect.that(3 * 4).toBe(12) }
}
var runErr = Fiber.new { Test.run() }.try()
Expect.that(runErr).toBeNull()

// run() on a set with a failing case aborts non-null.
Test.describe("broken") {
  Test.it("two equals three") { Expect.that(2).toBe(3) }
}
var failErr = Fiber.new { Test.run() }.try()
Expect.that(failErr).not.toBeNull()
Expect.that(failErr).toContain("test failure")

// --- Final sanity pass: run the runner on a tiny suite and make
// sure exit is clean. These cases don't mutate `Test.cases_`
// during the run — that was already covered by the bootstrap
// section above. --------------------------------------------------

Test.cases_.clear()
Test.describe("@hatch:test self") {
  Test.it("addition is self-consistent") {
    Expect.that(1 + 1).toBe(2)
  }
  Test.it("lists round-trip") {
    Expect.that([1, 2, 3].count).toBe(3)
  }
}
Test.run()
