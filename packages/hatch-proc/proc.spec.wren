import "./proc"        for Proc, Process, Pipeline, Result
import "@hatch:io"     for Buffer
import "@hatch:test"   for Test
import "@hatch:assert" for Expect

// --- exec: the one-liner path --------------------------------------

Test.describe("exec") {
  Test.it("echo captures stdout, exits 0") {
    var r = Proc.exec(["echo", "hello"])
    Expect.that(r.code).toBe(0)
    Expect.that(r.ok).toBe(true)
    Expect.that(r.stdout).toContain("hello")
  }
  Test.it("false exits 1") {
    var r = Proc.exec(["false"])
    Expect.that(r.code).toBe(1)
    Expect.that(r.ok).toBe(false)
  }
  Test.it("stdout/stderr split") {
    var r = Proc.exec(["sh", "-c", "echo OUT; echo ERR >&2"])
    Expect.that(r.stdout).toContain("OUT")
    Expect.that(r.stderr).toContain("ERR")
    Expect.that(r.stdout).not.toContain("ERR")
  }
  Test.it("cat echoes stdin bytes") {
    var r = Proc.exec(["cat"], {"stdin": "line1\nline2\n"})
    Expect.that(r.stdout).toBe("line1\nline2\n")
  }
  Test.it("cwd option") {
    var r = Proc.exec(["pwd"], {"cwd": "/tmp"})
    Expect.that(r.stdout).toContain("tmp")
  }
  Test.it("env option") {
    var r = Proc.exec(["sh", "-c", "echo $HATCH_SPEC"], {
      "env": {"HATCH_SPEC": "vvv"}
    })
    Expect.that(r.stdout).toContain("vvv")
  }
  Test.it("timeout kills long-running command") {
    var r = Proc.exec(["sleep", "5"], {"timeout": 0.1})
    Expect.that(r.timedOut).toBe(true)
    Expect.that(r.ok).toBe(false)
  }
}

// --- run: handle-based lifecycle -----------------------------------

Test.describe("run — lifecycle") {
  Test.it("returns a Process with a positive pid") {
    var p = Proc.run(["echo", "hi"])
    Expect.that(p is Process).toBe(true)
    Expect.that(p.pid > 0).toBe(true)
    p.wait
  }
  Test.it("alive is true while running, false after exit") {
    var p = Proc.run(["sleep", "0.2"])
    // alive right after spawn may race with immediate reap on
    // instant-exit programs; sleep 0.2 gives us a real window.
    Expect.that(p.alive).toBe(true)
    p.wait
    Expect.that(p.alive).toBe(false)
  }
  Test.it("wait returns the Result and is idempotent") {
    var p = Proc.run(["echo", "twice"])
    var r1 = p.wait
    var r2 = p.wait
    Expect.that(r1.code).toBe(0)
    Expect.that(r1.stdout).toContain("twice")
    Expect.that(r2.stdout).toBe(r1.stdout)
  }
  Test.it("tryWait is null while running, Result after wait") {
    var p = Proc.run(["sleep", "0.05"])
    // Immediately after spawn the child hasn't even started
    // running — tryWait must be null, not a Result.
    Expect.that(p.tryWait).toBeNull()
    // Block until done, then tryWait returns the cached Result.
    p.wait
    var r = p.tryWait
    Expect.that(r).not.toBeNull()
    Expect.that(r.code).toBe(0)
  }
  Test.it("kill terminates an in-flight process") {
    var p = Proc.run(["sleep", "60"])
    p.kill
    var r = p.wait
    // Signalled children report code=-1.
    Expect.that(r.code).toBe(-1)
    Expect.that(r.ok).toBe(false)
  }
}

// --- IPC -----------------------------------------------------------

Test.describe("run — IPC") {
  Test.it("writeStdin + closeStdin feeds cat") {
    var p = Proc.run(["cat"])
    p.writeStdin("one\n")
    p.writeStdin("two\n")
    p.closeStdin
    var r = p.wait
    Expect.that(r.stdout).toBe("one\ntwo\n")
  }
  Test.it("closeStdin without writes yields empty output") {
    var p = Proc.run(["cat"])
    p.closeStdin
    var r = p.wait
    Expect.that(r.stdout).toBe("")
  }
  Test.it("writeStdin on a closed pipe aborts") {
    var p = Proc.run(["cat"])
    p.closeStdin
    var e = Fiber.new { p.writeStdin("late\n") }.try()
    Expect.that(e).toContain("closed")
    p.wait
  }
  Test.it("writeStdin on non-String aborts") {
    var p = Proc.run(["cat"])
    var e = Fiber.new { p.writeStdin(42) }.try()
    Expect.that(e).toContain("must be a string")
    p.closeStdin
    p.wait
  }
}

// --- Chaining ------------------------------------------------------

Test.describe("chaining") {
  Test.it("stdinFrom threads one process's stdout into another's stdin") {
    var src = Proc.run(["printf", "alpha\nbeta\ngamma\n"])
    var sink = Proc.run(["wc", "-l"], {"stdinFrom": src})
    var r = sink.wait
    src.wait
    // printf produces 3 lines; wc -l prints a count that contains "3"
    Expect.that(r.stdout).toContain("3")
  }
  Test.it("Pipeline.of builds a multi-stage pipe") {
    var pipe = Pipeline.of([
      ["printf", "apple\nbanana\ncherry\n"],
      ["grep", "an"],
      ["wc", "-l"]
    ])
    var r = pipe.wait
    // "banana" is the only line containing "an"
    Expect.that(r.stdout).toContain("1")
  }
  Test.it("pipelines fail gracefully when a stage exits non-zero") {
    var pipe = Pipeline.of([
      ["printf", "no-match-anywhere\n"],
      ["grep", "needle"],   // grep exits 1 on no match
      ["wc", "-l"]
    ])
    var r = pipe.wait
    // wc still runs, counts zero lines.
    Expect.that(r.stdout).toContain("0")
  }
}

// --- shell / check -------------------------------------------------

Test.describe("shell + check") {
  Test.it("shell runs pipelines via sh -c") {
    var r = Proc.shell("echo abc | tr a-z A-Z")
    Expect.that(r.stdout).toContain("ABC")
  }
  Test.it("check returns the Result on success") {
    var r = Proc.check(["echo", "ok"])
    Expect.that(r.stdout).toContain("ok")
  }
  Test.it("check aborts on non-zero exit") {
    var e = Fiber.new { Proc.check(["false"]) }.try()
    Expect.that(e).toContain("exited 1")
  }
  Test.it("check aborts on timeout") {
    var e = Fiber.new {
      Proc.check(["sleep", "5"], {"timeout": 0.1})
    }.try()
    Expect.that(e).toContain("timed out")
  }
}

// --- Validation ----------------------------------------------------

Test.describe("validation") {
  Test.it("empty argv aborts") {
    var e = Fiber.new { Proc.run([]) }.try()
    Expect.that(e).toContain("program name")
  }
  Test.it("non-string argv entry aborts") {
    var e = Fiber.new { Proc.run(["echo", 42]) }.try()
    Expect.that(e).toContain("must be a string")
  }
  Test.it("unknown program aborts with a spawn error") {
    var e = Fiber.new {
      Proc.run(["definitely-not-a-program-xyz"])
    }.try()
    Expect.that(e).toContain("spawn")
  }
  Test.it("stdinFrom must be a Process") {
    var e = Fiber.new {
      Proc.run(["cat"], {"stdinFrom": "not a process"})
    }.try()
    Expect.that(e).toContain("must be a Process")
  }
}

// --- Streaming (Reader / Writer via @hatch:io) ----------------

Test.describe("streaming stdout") {
  Test.it("stdoutReader yields lines as they're produced") {
    var p = Proc.run(["printf", "a\nb\nc\n"])
    var r = p.stdoutReader
    var lines = []
    var line = r.readLine
    while (line != null) {
      lines.add(line)
      line = r.readLine
    }
    p.wait
    Expect.that(lines.count).toBe(3)
    Expect.that(lines[0]).toBe("a")
    Expect.that(lines[1]).toBe("b")
    Expect.that(lines[2]).toBe("c")
  }
  Test.it("streamed bytes still show up in the final Result") {
    var p = Proc.run(["printf", "hello world"])
    var r = p.stdoutReader
    var buf = r.readAll
    Expect.that(buf.toString).toBe("hello world")
    var res = p.wait
    Expect.that(res.stdout).toBe("hello world")
  }
  Test.it("stderrReader drains stderr") {
    var p = Proc.run(["sh", "-c", "echo boom >&2"])
    var r = p.stderrReader
    var buf = r.readAll
    p.wait
    Expect.that(buf.toString).toContain("boom")
  }
}

Test.describe("streaming stdin") {
  Test.it("stdinWriter feeds bytes into a live process") {
    var p = Proc.run(["cat"])
    var w = p.stdinWriter
    w.write("hello")
    w.write(" ")
    w.write(Buffer.fromBytes([0x77, 0x6f, 0x72, 0x6c, 0x64]))  // "world"
    w.close
    var r = p.wait
    Expect.that(r.stdout).toBe("hello world")
  }
}

Test.run()
