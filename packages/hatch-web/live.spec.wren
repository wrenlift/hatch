import "./live"        for Scheduler_, Channel, Sse, SseStream
import "@hatch:test"   for Test
import "@hatch:assert" for Expect

// --- Scheduler_ -----------------------------------------------

Test.describe("Scheduler_") {
  Test.it("runs a single non-yielding fiber to completion") {
    var s = Scheduler_.new()
    var log = []
    s.spawn(Fn.new { log.add("a") })
    while (!s.isEmpty) s.tick
    Expect.that(log).toEqual(["a"])
  }

  Test.it("count reflects fiber population") {
    var s = Scheduler_.new()
    Expect.that(s.count).toBe(0)
    s.spawn(Fn.new { return 42 })
    s.spawn(Fn.new { return 99 })
    Expect.that(s.count).toBe(2)
    while (!s.isEmpty) s.tick
    Expect.that(s.count).toBe(0)
  }

  Test.it("drops fibers that abort") {
    var s = Scheduler_.new()
    s.spawn(Fn.new { Fiber.abort("boom") })
    s.spawn(Fn.new { return 42 })
    while (!s.isEmpty) s.tick
    Expect.that(s.isEmpty).toBe(true)
  }

  // NOTE: round-robin with Fiber.yield is exercised by the chat
  // demo — wren_lift currently doesn't resume a nested inner
  // fiber once its outer fiber (the test body) is running, so a
  // cooperative scheduler test inside Test.it can't verify yield/
  // resume semantics here. Fix tracked in the scheduler/live.wren
  // docstring.
}

// --- Channel --------------------------------------------------
//
// These tests deliberately avoid spawning fibers inside Test.it's
// own fiber body — wren_lift's nested-fiber resume semantics are
// currently broken (Fiber.yield() inside an inner fiber doesn't
// hand control back to the inner fiber's .try() caller when that
// caller is itself running inside an outer fiber). The server's
// listen() runs at top level so the Scheduler works there; the
// tests here verify Channel's data plumbing without the nested
// fiber hop. End-to-end fiber tests live in the chat demo.

Test.describe("Channel") {
  Test.it("deliver_ queues a message for later receive") {
    var ch = Channel.new("test")
    var sub = ch.subscribe
    sub.deliver_("hello")
    // Calling receive when the queue is pre-filled returns
    // immediately without ever hitting Fiber.yield().
    Expect.that(sub.receive).toBe("hello")
  }

  Test.it("fans out to multiple subscribers") {
    var ch = Channel.new("fanout")
    var a = ch.subscribe
    var b = ch.subscribe
    ch.broadcast("ping")
    Expect.that(a.receive).toBe("ping")
    Expect.that(b.receive).toBe("ping")
  }

  Test.it("subscriber sees messages in order") {
    var ch = Channel.new("ordered")
    var sub = ch.subscribe
    ch.broadcast("one")
    ch.broadcast("two")
    ch.broadcast("three")
    Expect.that(sub.receive).toBe("one")
    Expect.that(sub.receive).toBe("two")
    Expect.that(sub.receive).toBe("three")
  }

  Test.it("close removes the subscriber") {
    var ch = Channel.new("x")
    var sub = ch.subscribe
    Expect.that(ch.subscriberCount).toBe(1)
    sub.close
    Expect.that(ch.subscriberCount).toBe(0)
  }

  Test.it("closed subscriber receives null") {
    var ch = Channel.new("y")
    var sub = ch.subscribe
    sub.close
    Expect.that(sub.receive).toBe(null)
  }

  Test.it("broadcast to empty channel is a no-op") {
    var ch = Channel.new("empty")
    ch.broadcast("unheard")
    Expect.that(ch.subscriberCount).toBe(0)
  }
}

// --- Sse frame builder ----------------------------------------

Test.describe("Sse.frame") {
  Test.it("String payload becomes a data line") {
    var f = Sse.frame("hello")
    Expect.that(f).toBe("data: hello\n\n")
  }

  Test.it("comment starts with :") {
    var f = Sse.frame(":ping")
    Expect.that(f).toBe(":ping\n\n")
  }

  Test.it("multi-line data is split into data: per line") {
    var f = Sse.frame("line1\nline2\nline3")
    Expect.that(f).toContain("data: line1")
    Expect.that(f).toContain("data: line2")
    Expect.that(f).toContain("data: line3")
  }

  Test.it("Map payload with event + data") {
    var f = Sse.frame({"event": "message", "data": "hi"})
    Expect.that(f).toContain("event: message")
    Expect.that(f).toContain("data: hi")
    Expect.that(f.endsWith("\n\n")).toBe(true)
  }

  Test.it("Map payload with id + retry") {
    var f = Sse.frame({"event": "tick", "data": "1", "id": 42, "retry": 3000})
    Expect.that(f).toContain("id: 42")
    Expect.that(f).toContain("retry: 3000")
  }
}

Test.describe("Sse.stream") {
  Test.it("returns an SseStream carrying the writer") {
    var fn = Fn.new {|emit| emit.call("x") }
    var s = Sse.stream(fn)
    Expect.that(s is SseStream).toBe(true)
    Expect.that(s.writer).toBe(fn)
  }
}

Test.run()
