import "./log"         for Log
import "@hatch:test"   for Test
import "@hatch:assert" for Expect

// Static state on Log means every test has to start from a known
// baseline. Factor that out so individual cases don't carry the
// reset boilerplate.
var reset = Fn.new {
  Log.level = Log.INFO
  Log.color = false
  Log.prefix = ""
  Log.writer = Fn.new { |line| }   // swallow output during tests
}

// Capture helper: installs a writer that appends lines to `buf`.
var capture = Fn.new { |buf|
  Log.writer = Fn.new { |line| buf.add(line) }
}

Test.describe("levels") {
  Test.it("default level is INFO (debug hidden)") {
    reset.call()
    var buf = []
    capture.call(buf)
    Log.debug("dbg")
    Log.info("inf")
    Expect.that(buf.count).toBe(1)
    Expect.that(buf[0]).toContain("inf")
  }
  Test.it("setting level lower shows debug") {
    reset.call()
    Log.level = Log.DEBUG
    var buf = []
    capture.call(buf)
    Log.debug("dbg")
    Expect.that(buf.count).toBe(1)
  }
  Test.it("setting level higher hides info/warn") {
    reset.call()
    Log.level = Log.ERROR
    var buf = []
    capture.call(buf)
    Log.info("a")
    Log.warn("b")
    Log.error("c")
    Expect.that(buf.count).toBe(1)
    Expect.that(buf[0]).toContain("c")
  }
  Test.it("invalid level aborts") {
    var e = Fiber.new { Log.level = 99 }.try()
    Expect.that(e).toContain("DEBUG")
  }
}

Test.describe("formatting") {
  Test.it("tag prefixes the message") {
    reset.call()
    var buf = []
    capture.call(buf)
    Log.info("hello")
    Expect.that(buf[0]).toContain("INFO")
    Expect.that(buf[0]).toContain("hello")
  }
  Test.it("prefix sits between tag and message") {
    reset.call()
    Log.prefix = "[api] "
    var buf = []
    capture.call(buf)
    Log.info("ok")
    Expect.that(buf[0]).toContain("[api] ok")
  }
  Test.it("color = false strips ANSI codes") {
    reset.call()
    var buf = []
    capture.call(buf)
    Log.info("x")
    Expect.that(buf[0]).toContain("INFO")
    Expect.that(buf[0].contains("\e[")).toBe(false)
  }
  Test.it("color = true wraps the tag in ANSI") {
    reset.call()
    Log.color = true
    var buf = []
    capture.call(buf)
    Log.error("boom")
    Expect.that(buf[0].contains("\e[")).toBe(true)
  }
}

Test.describe("writer") {
  Test.it("custom writer receives each line") {
    reset.call()
    var buf = []
    capture.call(buf)
    Log.info("a")
    Log.info("b")
    Log.info("c")
    Expect.that(buf.count).toBe(3)
  }
  Test.it("invalid writer aborts") {
    var e = Fiber.new { Log.writer = "not a fn" }.try()
    Expect.that(e).toContain("must be a Fn")
  }
}

Test.run()
