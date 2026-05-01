A tiny test runner for `*.spec.wren` files. `Test.describe(name) { body }` registers a group, `Test.it(name) { body }` records a case, `Test.run()` iterates them all and aborts the fiber on any failure so `hatch test` (and plain `wlift foo.spec.wren`) both propagate the right exit code. Pairs with `@hatch:assert` for fluent matchers.

## Overview

The shape mirrors Mocha / Jest — describe-it pairs, no decorators, no test classes. The runner runs each case inside a fresh `Fiber.new` and captures any abort as a failure, so a test crashing doesn't take subsequent ones with it.

```wren
import "@hatch:test"   for Test
import "@hatch:assert" for Expect

Test.describe("List") {
  Test.it("indexes from zero") {
    Expect.that([1, 2][0]).toBe(1)
  }

  Test.it("reports count") {
    Expect.that([1, 2].count).toBe(2)
  }
}

Test.run()
```

`describe` is optional — calls to `Test.it` outside any group register against a `null` group label, which still renders cleanly in the output. Calls to `describe` can nest if you call `Test.describe` again from inside a body.

## Output and exit codes

`Test.run()` prints `FAIL` lines for each failure (group + name plus the assertion message), then a summary line. On at least one failure it aborts the calling fiber with `"%(n) test failure(s)"`, which surfaces as a non-zero exit when the spec is the program's top fiber.

```
FAIL  List > reports count
      assertion failed: expected 2 toBe 3
ok: 1/2 passed
```

> **Note — small on purpose**
> No `beforeEach` / `afterEach`, no `skip`, no async. The first-wave packages just need "did this work?" — heavier runner features land when they earn their keep. If you want shared setup, build a helper that returns the wired-up object and call it from each `Test.it`.

## Compatibility

Wren 0.4 + WrenLift runtime 0.1 or newer. Pure-Wren — no native dependencies. Pair with `@hatch:assert` for matchers; both packages are tiny and don't pull in anything else.
