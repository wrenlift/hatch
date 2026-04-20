import "./os"          for Os
import "@hatch:test"   for Test
import "@hatch:assert" for Expect

Test.describe("platform") {
  Test.it("returns a non-empty string") {
    Expect.that(Os.platform is String).toBe(true)
    Expect.that(Os.platform.count > 0).toBe(true)
  }
  Test.it("arch is non-empty") {
    Expect.that(Os.arch.count > 0).toBe(true)
  }
  Test.it("isUnix xor isWindows") {
    // Exactly one of the two should be true on any real platform.
    var u = Os.isUnix
    var w = Os.isWindows
    Expect.that(u != w).toBe(true)
  }
}

Test.describe("env") {
  Test.it("env(name) returns the value or null") {
    Os.setEnv("HATCH_SPEC_TEST", "abc")
    Expect.that(Os.env("HATCH_SPEC_TEST")).toBe("abc")
    Os.unsetEnv("HATCH_SPEC_TEST")
    Expect.that(Os.env("HATCH_SPEC_TEST")).toBe(null)
  }
  Test.it("env(name, default) falls back on absent") {
    Expect.that(Os.env("HATCH_DEFINITELY_UNSET", "fallback")).toBe("fallback")
    Os.setEnv("HATCH_SPEC_PRESENT", "present")
    Expect.that(Os.env("HATCH_SPEC_PRESENT", "fallback")).toBe("present")
    Os.unsetEnv("HATCH_SPEC_PRESENT")
  }
  Test.it("envMap contains set values") {
    Os.setEnv("HATCH_MAP_KEY", "map_val")
    var m = Os.envMap
    Expect.that(m is Map).toBe(true)
    Expect.that(m["HATCH_MAP_KEY"]).toBe("map_val")
    Os.unsetEnv("HATCH_MAP_KEY")
  }
}

Test.describe("args") {
  Test.it("args has at least the program name") {
    Expect.that(Os.args is List).toBe(true)
    Expect.that(Os.args.count > 0).toBe(true)
  }
  Test.it("argv is args without the program name") {
    Expect.that(Os.argv.count).toBe(Os.args.count - 1)
  }
}

Test.describe("tty") {
  Test.it("fd constants line up with POSIX") {
    Expect.that(Os.STDIN).toBe(0)
    Expect.that(Os.STDOUT).toBe(1)
    Expect.that(Os.STDERR).toBe(2)
  }
  Test.it("isatty returns a Bool") {
    // We don't know the test environment — just verify the shape.
    var v = Os.isatty(Os.STDOUT)
    Expect.that(v == true || v == false).toBe(true)
  }
  Test.it("isatty on an invalid fd aborts") {
    var e = Fiber.new { Os.isatty(42) }.try()
    Expect.that(e).toContain("0 (stdin)")
  }
}

Test.run()
