import "./events"      for Signal, EventEmitter
import "@hatch:test"   for Test
import "@hatch:assert" for Expect

// --- Signal ------------------------------------------------------

Test.describe("Signal basics") {
  Test.it("connect + emit fires listener") {
    var sig = Signal.new()
    var hits = []
    sig.connect {|x| hits.add(x) }
    sig.emit(42)
    Expect.that(hits.count).toBe(1)
    Expect.that(hits[0]).toBe(42)
  }
  Test.it("multiple listeners fire in order") {
    var sig = Signal.new()
    var hits = []
    sig.connect { hits.add("a") }
    sig.connect { hits.add("b") }
    sig.connect { hits.add("c") }
    sig.emit()
    Expect.that(hits[0]).toBe("a")
    Expect.that(hits[1]).toBe("b")
    Expect.that(hits[2]).toBe("c")
  }
  Test.it("emit supports 0, 1, 2, 3 args") {
    var sig = Signal.new()
    var got = null
    sig.connect {|a, b, c| got = [a, b, c] }
    sig.emit("x", "y", "z")
    Expect.that(got[0]).toBe("x")
    Expect.that(got[1]).toBe("y")
    Expect.that(got[2]).toBe("z")
  }
  Test.it("emitMany unpacks a list") {
    var sig = Signal.new()
    var got = null
    sig.connect {|a, b| got = [a, b] }
    sig.emitMany([1, 2])
    Expect.that(got[0]).toBe(1)
    Expect.that(got[1]).toBe(2)
  }
  Test.it("name is stored for debugging") {
    var sig = Signal.new("onExit")
    Expect.that(sig.name).toBe("onExit")
    Expect.that(sig.toString).toContain("onExit")
  }
}

Test.describe("Signal disconnect") {
  Test.it("disconnect by Fn reference") {
    var sig = Signal.new()
    var hits = 0
    var fn = Fn.new { hits = hits + 1 }
    sig.connect(fn)
    sig.emit()
    sig.disconnect(fn)
    sig.emit()
    Expect.that(hits).toBe(1)
  }
  Test.it("connect returns a disconnect closure") {
    var sig = Signal.new()
    var hits = 0
    var dc = sig.connect { hits = hits + 1 }
    sig.emit()
    dc.call()
    sig.emit()
    Expect.that(hits).toBe(1)
  }
  Test.it("disconnectAll removes every listener") {
    var sig = Signal.new()
    sig.connect {}
    sig.connect {}
    sig.disconnectAll
    Expect.that(sig.listenerCount).toBe(0)
    sig.emit()   // no-op, doesn't abort
  }
  Test.it("disconnect of unknown Fn is a no-op") {
    var sig = Signal.new()
    sig.disconnect(Fn.new {})   // no abort
  }
}

Test.describe("Signal connectOnce") {
  Test.it("connectOnce fires exactly once") {
    var sig = Signal.new()
    var hits = 0
    sig.connectOnce { hits = hits + 1 }
    sig.emit()
    sig.emit()
    sig.emit()
    Expect.that(hits).toBe(1)
    Expect.that(sig.listenerCount).toBe(0)
  }
  Test.it("connectOnce + connect co-exist") {
    var sig = Signal.new()
    var once = 0
    var many = 0
    sig.connectOnce { once = once + 1 }
    sig.connect { many = many + 1 }
    sig.emit()
    sig.emit()
    Expect.that(once).toBe(1)
    Expect.that(many).toBe(2)
  }
}

Test.describe("Signal re-entrancy safety") {
  Test.it("listener disconnecting itself doesn't skip later listeners") {
    var sig = Signal.new()
    var hits = []
    var dc = null
    dc = sig.connect {
      hits.add("self")
      dc.call()         // disconnect during emit
    }
    sig.connect { hits.add("other") }
    sig.emit()
    Expect.that(hits.count).toBe(2)
    Expect.that(hits[0]).toBe("self")
    Expect.that(hits[1]).toBe("other")
  }
  Test.it("adding a listener during emit doesn't fire on the current pass") {
    var sig = Signal.new()
    var hits = []
    sig.connect {
      hits.add("first")
      sig.connect { hits.add("added-during-emit") }
    }
    sig.emit()
    Expect.that(hits.count).toBe(1)
    // Next emit sees the new listener.
    sig.emit()
    Expect.that(hits.count).toBe(3)
  }
}

// --- EventEmitter ------------------------------------------------

Test.describe("EventEmitter basics") {
  Test.it("on + emit fires listeners for that event only") {
    var bus = EventEmitter.new()
    var data = []
    var other = 0
    bus.on("data") {|c| data.add(c) }
    bus.on("other") { other = other + 1 }
    bus.emit("data", "chunk1")
    bus.emit("data", "chunk2")
    Expect.that(data.count).toBe(2)
    Expect.that(other).toBe(0)
  }
  Test.it("emit on an unknown event is a no-op") {
    var bus = EventEmitter.new()
    bus.emit("never-registered", "ignored")
  }
  Test.it("listenerCount reports per event") {
    var bus = EventEmitter.new()
    bus.on("a") {}
    bus.on("a") {}
    bus.on("b") {}
    Expect.that(bus.listenerCount("a")).toBe(2)
    Expect.that(bus.listenerCount("b")).toBe(1)
    Expect.that(bus.listenerCount("c")).toBe(0)
  }
  Test.it("eventNames lists active events") {
    var bus = EventEmitter.new()
    bus.on("a") {}
    bus.on("b") {}
    var names = bus.eventNames
    Expect.that(names.count).toBe(2)
  }
}

Test.describe("EventEmitter off") {
  Test.it("off by Fn reference") {
    var bus = EventEmitter.new()
    var hits = 0
    var fn = Fn.new { hits = hits + 1 }
    bus.on("t", fn)
    bus.emit("t")
    bus.off("t", fn)
    bus.emit("t")
    Expect.that(hits).toBe(1)
  }
  Test.it("on returns a disconnect closure") {
    var bus = EventEmitter.new()
    var hits = 0
    var dc = bus.on("t") { hits = hits + 1 }
    bus.emit("t")
    dc.call()
    bus.emit("t")
    Expect.that(hits).toBe(1)
  }
  Test.it("offAll(event) clears one event") {
    var bus = EventEmitter.new()
    bus.on("a") {}
    bus.on("a") {}
    bus.on("b") {}
    bus.offAll("a")
    Expect.that(bus.listenerCount("a")).toBe(0)
    Expect.that(bus.listenerCount("b")).toBe(1)
  }
  Test.it("offAll wipes everything") {
    var bus = EventEmitter.new()
    bus.on("a") {}
    bus.on("b") {}
    bus.offAll
    Expect.that(bus.eventNames.count).toBe(0)
  }
  Test.it("event with no listeners leaves the bookkeeping clean") {
    var bus = EventEmitter.new()
    var fn = Fn.new {}
    bus.on("a", fn)
    bus.off("a", fn)
    Expect.that(bus.eventNames.count).toBe(0)
  }
}

Test.describe("EventEmitter once") {
  Test.it("once fires exactly once") {
    var bus = EventEmitter.new()
    var hits = 0
    bus.once("done") { hits = hits + 1 }
    bus.emit("done")
    bus.emit("done")
    bus.emit("done")
    Expect.that(hits).toBe(1)
    Expect.that(bus.listenerCount("done")).toBe(0)
  }
  Test.it("off cancels a once listener before it fires") {
    var bus = EventEmitter.new()
    var hits = 0
    var fn = Fn.new { hits = hits + 1 }
    bus.once("e", fn)
    bus.off("e", fn)
    bus.emit("e")
    Expect.that(hits).toBe(0)
  }
}

Test.describe("EventEmitter argument arity") {
  Test.it("emit supports 0, 1, 2, 3 args") {
    var bus = EventEmitter.new()
    var got = null
    bus.on("three") {|a, b, c| got = [a, b, c] }
    bus.emit("three", "x", "y", "z")
    Expect.that(got[0]).toBe("x")
    Expect.that(got[2]).toBe("z")
  }
  Test.it("emitMany unpacks a list") {
    var bus = EventEmitter.new()
    var got = null
    bus.on("e") {|a, b| got = [a, b] }
    bus.emitMany("e", [10, 20])
    Expect.that(got[0]).toBe(10)
    Expect.that(got[1]).toBe(20)
  }
  Test.it("emitMany rejects >3 args") {
    var bus = EventEmitter.new()
    var e = Fiber.new { bus.emitMany("e", [1, 2, 3, 4]) }.try()
    Expect.that(e).toContain("supports up to 3 args")
  }
}

Test.describe("EventEmitter validation") {
  Test.it("on with non-string event aborts") {
    var bus = EventEmitter.new()
    var e = Fiber.new { bus.on(42, Fn.new {}) }.try()
    Expect.that(e).toContain("must be a string")
  }
  Test.it("on with non-Fn listener aborts") {
    var bus = EventEmitter.new()
    var e = Fiber.new { bus.on("x", 42) }.try()
    Expect.that(e).toContain("must be a Fn")
  }
}

Test.run()
