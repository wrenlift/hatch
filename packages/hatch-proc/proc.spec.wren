import "./proc"        for Proc, Result
import "@hatch:test"   for Test
import "@hatch:assert" for Expect

Test.describe("run: basics") {
  Test.it("echo captures stdout + exits 0") {
    var r = Proc.run(["echo", "hello"])
    Expect.that(r.code).toBe(0)
    Expect.that(r.ok).toBe(true)
    Expect.that(r.stdout).toContain("hello")
  }
  Test.it("false exits 1") {
    var r = Proc.run(["false"])
    Expect.that(r.code).toBe(1)
    Expect.that(r.ok).toBe(false)
  }
  Test.it("stderr captured separately from stdout") {
    var r = Proc.run(["sh", "-c", "echo OUT; echo ERR >&2"])
    Expect.that(r.stdout).toContain("OUT")
    Expect.that(r.stderr).toContain("ERR")
    Expect.that(r.stdout).not.toContain("ERR")
  }
}

Test.describe("stdin") {
  Test.it("cat echoes piped stdin") {
    var r = Proc.run(["cat"], {"stdin": "line1\nline2\n"})
    Expect.that(r.stdout).toBe("line1\nline2\n")
  }
  Test.it("wc -l counts lines from stdin") {
    var r = Proc.run(["wc", "-l"], {"stdin": "a\nb\nc\n"})
    Expect.that(r.stdout.contains("3")).toBe(true)
  }
}

Test.describe("cwd") {
  Test.it("pwd reflects the cwd option") {
    var r = Proc.run(["pwd"], {"cwd": "/tmp"})
    // macOS returns /private/tmp for /tmp due to the symlink.
    Expect.that(r.stdout.contains("tmp")).toBe(true)
  }
}

Test.describe("env") {
  Test.it("child sees env vars we pass in") {
    var r = Proc.run(["sh", "-c", "echo $HATCH_PROC_SPEC"], {
      "env": {"HATCH_PROC_SPEC": "vvv"}
    })
    Expect.that(r.stdout).toContain("vvv")
  }
}

Test.describe("timeout") {
  Test.it("sleep 5 with 0.1 timeout → timedOut, ok=false") {
    var r = Proc.run(["sleep", "5"], {"timeout": 0.1})
    Expect.that(r.timedOut).toBe(true)
    Expect.that(r.ok).toBe(false)
  }
  Test.it("fast command under a wide timeout completes normally") {
    var r = Proc.run(["echo", "quick"], {"timeout": 10})
    Expect.that(r.timedOut).toBe(false)
    Expect.that(r.ok).toBe(true)
  }
}

Test.describe("shell") {
  Test.it("pipes work via sh -c") {
    var r = Proc.shell("echo abc | tr a-z A-Z")
    Expect.that(r.stdout).toContain("ABC")
  }
}

Test.describe("check") {
  Test.it("returns Result on success") {
    var r = Proc.check(["echo", "ok"])
    Expect.that(r.stdout).toContain("ok")
  }
  Test.it("aborts on non-zero exit") {
    var e = Fiber.new { Proc.check(["false"]) }.try()
    Expect.that(e).toContain("exited 1")
  }
  Test.it("aborts on timeout with a clear message") {
    var e = Fiber.new {
      Proc.check(["sleep", "5"], {"timeout": 0.1})
    }.try()
    Expect.that(e).toContain("timed out")
  }
}

Test.describe("argv validation") {
  Test.it("empty argv aborts") {
    var e = Fiber.new { Proc.run([]) }.try()
    Expect.that(e).toContain("program name")
  }
  Test.it("non-string argv entry aborts") {
    var e = Fiber.new { Proc.run(["echo", 42]) }.try()
    Expect.that(e).toContain("must be a string")
  }
  Test.it("non-existent program aborts with a spawn error") {
    var e = Fiber.new { Proc.run(["definitely-not-a-program-xyz"]) }.try()
    Expect.that(e).toContain("spawn")
  }
}

Test.run()
