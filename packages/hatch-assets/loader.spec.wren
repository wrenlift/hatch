// @hatch:assets/loader — frame-amortised AssetLoader. Specs cover
// queue + progress + completion + error paths without touching the
// filesystem; the queued closures are inline `Fn`s that compute
// fake assets synchronously.

import "./loader"      for AssetLoader
import "@hatch:test"   for Test
import "@hatch:assert" for Expect

Test.describe("AssetLoader construct") {
  Test.it("starts empty") {
    var l = AssetLoader.new()
    Expect.that(l.pending).toBe(0)
    Expect.that(l.done).toBe(0)
    Expect.that(l.running).toBe(false)
  }
}

Test.describe("AssetLoader.queue") {
  Test.it("queue order is preserved") {
    var l = AssetLoader.new()
    l.queue("a", Fn.new { 1 })
    l.queue("b", Fn.new { 2 })
    l.queue("c", Fn.new { 3 })
    Expect.that(l.pending).toBe(3)
  }

  Test.it("rejects non-String names") {
    var l = AssetLoader.new()
    Expect.that(Fn.new { l.queue(42, Fn.new { 1 }) }).toAbort()
  }

  Test.it("rejects non-Fn load closures") {
    var l = AssetLoader.new()
    Expect.that(Fn.new { l.queue("a", "not a fn") }).toAbort()
  }
}

Test.describe("AssetLoader.update") {
  Test.it("resolves one entry per call in queue order") {
    var l = AssetLoader.new()
    l.queue("a", Fn.new { 10 })
    l.queue("b", Fn.new { 20 })
    l.queue("c", Fn.new { 30 })
    l.start()
    Expect.that(l.running).toBe(true)

    l.update(0.016)
    Expect.that(l.loaded["a"]).toBe(10)
    Expect.that(l.done).toBe(1)
    Expect.that(l.pending).toBe(2)

    l.update(0.016)
    Expect.that(l.loaded["b"]).toBe(20)

    l.update(0.016)
    Expect.that(l.loaded["c"]).toBe(30)
    Expect.that(l.running).toBe(false)
  }

  Test.it("update is a no-op before start") {
    var l = AssetLoader.new()
    l.queue("a", Fn.new { 99 })
    l.update(0.016)
    Expect.that(l.done).toBe(0)
  }

  Test.it("fires onProgress per resolved entry with (fraction, done, total)") {
    var samples = []
    var l = AssetLoader.new()
    l.queue("a", Fn.new { 1 })
    l.queue("b", Fn.new { 2 })
    l.onProgress(Fn.new {|fraction, done, total|
      samples.add([fraction, done, total])
    })
    l.start()
    l.update(0.016)
    l.update(0.016)
    Expect.that(samples.count).toBe(2)
    Expect.that(samples[0][1]).toBe(1)
    Expect.that(samples[0][2]).toBe(2)
    Expect.that(samples[1][1]).toBe(2)
    Expect.that(samples[1][2]).toBe(2)
    // Last fraction is 1.0 (the queue is drained).
    Expect.that(samples[1][0]).toBe(1)
  }

  Test.it("fires onComplete once with the full loaded map") {
    var finalMap = null
    var fires = 0
    var l = AssetLoader.new()
    l.queue("x", Fn.new { "X" })
    l.queue("y", Fn.new { "Y" })
    l.onComplete(Fn.new {|loaded|
      finalMap = loaded
      fires = fires + 1
    })
    l.start()
    l.update(0.016)
    l.update(0.016)
    Expect.that(fires).toBe(1)
    Expect.that(finalMap["x"]).toBe("X")
    Expect.that(finalMap["y"]).toBe("Y")
    // Calling update again after completion shouldn't re-fire.
    l.update(0.016)
    Expect.that(fires).toBe(1)
  }

  Test.it("update before any queued items completes immediately") {
    var fires = 0
    var l = AssetLoader.new()
    l.onComplete(Fn.new {|loaded| fires = fires + 1 })
    l.start()
    l.update(0.016)
    Expect.that(fires).toBe(1)
    Expect.that(l.running).toBe(false)
  }
}

Test.describe("AssetLoader error handling") {
  Test.it("onError catches fiber aborts and continues") {
    var errors = []
    var l = AssetLoader.new()
    l.queue("ok",   Fn.new { 1 })
    l.queue("bad",  Fn.new { Fiber.abort("boom") })
    l.queue("ok2",  Fn.new { 2 })
    l.onError(Fn.new {|name, err| errors.add([name, err]) })
    l.start()
    l.update(0.016)
    l.update(0.016)   // bad — fires onError
    l.update(0.016)
    Expect.that(errors.count).toBe(1)
    Expect.that(errors[0][0]).toBe("bad")
    Expect.that(l.loaded["ok"]).toBe(1)
    Expect.that(l.loaded["ok2"]).toBe(2)
  }

  Test.it("propagates abort when no onError is registered") {
    var l = AssetLoader.new()
    l.queue("bad", Fn.new { Fiber.abort("boom") })
    l.start()
    Expect.that(Fn.new { l.update(0.016) }).toAbort()
  }
}

Test.describe("AssetLoader.pause / reset") {
  Test.it("pause halts queue draining; start resumes") {
    var l = AssetLoader.new()
    l.queue("a", Fn.new { 1 })
    l.queue("b", Fn.new { 2 })
    l.start()
    l.update(0.016)
    l.pause
    l.update(0.016)           // no-op
    Expect.that(l.done).toBe(1)
    l.start()                 // resumes; total recalculated
    l.update(0.016)
    Expect.that(l.done).toBe(2)
  }

  Test.it("reset clears everything") {
    var l = AssetLoader.new()
    l.queue("a", Fn.new { 1 })
    l.start()
    l.update(0.016)
    l.reset()
    Expect.that(l.done).toBe(0)
    Expect.that(l.pending).toBe(0)
    Expect.that(l.running).toBe(false)
  }
}

Test.run()
