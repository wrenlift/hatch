// Self-spec for @hatch:assert. Runs via `hatch test` once that
// lands; meanwhile, the smoke-test script in the package dir
// concatenates this with `assert.wren` so it runs under `wlift`.
//
// Each failing assertion aborts the fiber. If execution reaches
// the final `System.print`, every check passed.

import "./assert" for Expect

// -- Equality --------------------------------------------------------------

Expect.that(1 + 1).toBe(2)
Expect.that("hello").toBe("hello")
Expect.that(null).toBe(null)
Expect.that(3).not.toBe(4)

// -- Structural equality (lists + maps) ------------------------------------

Expect.that([1, 2, 3]).toEqual([1, 2, 3])
Expect.that([1, 2]).not.toEqual([1, 2, 3])
Expect.that({"a": 1}).toEqual({"a": 1})
Expect.that({"a": 1}).not.toEqual({"a": 2})
Expect.that([[1, 2], [3, 4]]).toEqual([[1, 2], [3, 4]])

// -- Nullability + truthiness ----------------------------------------------

Expect.that(null).toBeNull()
Expect.that(42).not.toBeNull()
Expect.that(1).toBeTruthy()
Expect.that("anything").toBeTruthy()
Expect.that(0).toBeTruthy()            // Wren: only false/null are falsy
Expect.that("").toBeTruthy()
Expect.that(false).toBeFalsy()
Expect.that(null).toBeFalsy()
Expect.that(0).not.toBeFalsy()

// -- Ordering ---------------------------------------------------------------

Expect.that(5).toBeGreaterThan(3)
Expect.that(5).toBeGreaterThanOrEqual(5)
Expect.that(3).toBeLessThan(5)
Expect.that(3).toBeLessThanOrEqual(3)
Expect.that(3).not.toBeGreaterThan(5)

// -- Containment ------------------------------------------------------------

Expect.that([1, 2, 3]).toContain(2)
Expect.that([1, 2, 3]).not.toContain(99)
Expect.that("hello world").toContain("world")
Expect.that({"a": 1, "b": 2}).toContain("a")
Expect.that({"a": 1}).not.toContain("nope")

// -- Type checks -----------------------------------------------------------

Expect.that([1, 2]).toBeInstanceOf(List)
Expect.that("x").toBeInstanceOf(String)
Expect.that(42).not.toBeInstanceOf(String)

// -- Failure mode ----------------------------------------------------------
//
// Failing assertions abort the enclosing fiber; matcher internals are
// covered by running assertions inside a fiber and inspecting the result.

var failed = Fiber.new { Expect.that(1).toBe(2) }.try()
Expect.that(failed).not.toBeNull()
Expect.that(failed).toContain("toBe")

var passed = Fiber.new { Expect.that(42).not.toBeNull() }.try()
Expect.that(passed).toBeNull()

// -- toAbort / toAbortWith --------------------------------------------------

Expect.that(Fn.new { Fiber.abort("nope") }).toAbort()
Expect.that(Fn.new { Fiber.abort("specific") }).toAbortWith("specific")
Expect.that(Fn.new { 42 }).not.toAbort()

System.print("@hatch:assert - all specs passed")
