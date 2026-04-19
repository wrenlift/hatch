// Self-spec for @hatch:assert, driven by the @hatch:test runner.

import "./assert" for Expect
import "@hatch:test" for Test

Test.describe("equality") {
  Test.it("toBe on primitives") {
    Expect.that(1 + 1).toBe(2)
    Expect.that("hello").toBe("hello")
    Expect.that(null).toBe(null)
    Expect.that(3).not.toBe(4)
  }
  Test.it("toEqual compares lists structurally") {
    Expect.that([1, 2, 3]).toEqual([1, 2, 3])
    Expect.that([1, 2]).not.toEqual([1, 2, 3])
  }
  Test.it("toEqual compares maps structurally") {
    Expect.that({"a": 1}).toEqual({"a": 1})
    Expect.that({"a": 1}).not.toEqual({"a": 2})
  }
  Test.it("toEqual recurses into nested lists") {
    Expect.that([[1, 2], [3, 4]]).toEqual([[1, 2], [3, 4]])
  }
}

Test.describe("nullability and truthiness") {
  Test.it("toBeNull") {
    Expect.that(null).toBeNull()
    Expect.that(42).not.toBeNull()
  }
  Test.it("toBeTruthy treats only null + false as falsy") {
    Expect.that(1).toBeTruthy()
    Expect.that("anything").toBeTruthy()
    Expect.that(0).toBeTruthy()
    Expect.that("").toBeTruthy()
  }
  Test.it("toBeFalsy") {
    Expect.that(false).toBeFalsy()
    Expect.that(null).toBeFalsy()
    Expect.that(0).not.toBeFalsy()
  }
}

Test.describe("ordering") {
  Test.it("toBeGreaterThan / OrEqual") {
    Expect.that(5).toBeGreaterThan(3)
    Expect.that(5).toBeGreaterThanOrEqual(5)
    Expect.that(3).not.toBeGreaterThan(5)
  }
  Test.it("toBeLessThan / OrEqual") {
    Expect.that(3).toBeLessThan(5)
    Expect.that(3).toBeLessThanOrEqual(3)
  }
}

Test.describe("containment") {
  Test.it("toContain on a list") {
    Expect.that([1, 2, 3]).toContain(2)
    Expect.that([1, 2, 3]).not.toContain(99)
  }
  Test.it("toContain on a string does substring search") {
    Expect.that("hello world").toContain("world")
  }
  Test.it("toContain on a map checks keys") {
    Expect.that({"a": 1, "b": 2}).toContain("a")
    Expect.that({"a": 1}).not.toContain("nope")
  }
}

Test.describe("type checks") {
  Test.it("toBeInstanceOf") {
    Expect.that([1, 2]).toBeInstanceOf(List)
    Expect.that("x").toBeInstanceOf(String)
    Expect.that(42).not.toBeInstanceOf(String)
  }
}

Test.describe("abort matchers") {
  Test.it("toAbort catches Fiber.abort") {
    Expect.that(Fn.new { Fiber.abort("nope") }).toAbort()
    Expect.that(Fn.new { 42 }).not.toAbort()
  }
  Test.it("toAbortWith pins the abort message") {
    Expect.that(Fn.new { Fiber.abort("specific") }).toAbortWith("specific")
  }
}

Test.run()
