import "./io"         for Buffer, Reader, Writer, BufferReader, BufferWriter, StringReader
import "@hatch:test"   for Test
import "@hatch:assert" for Expect

// --- Buffer -----------------------------------------------------

Test.describe("Buffer construction") {
  Test.it("new creates an empty buffer") {
    var b = Buffer.new()
    Expect.that(b.count).toBe(0)
    Expect.that(b.isEmpty).toBe(true)
  }
  Test.it("ofSize(n) creates n zero bytes") {
    var b = Buffer.ofSize(4)
    Expect.that(b.count).toBe(4)
    Expect.that(b.byteAt(0)).toBe(0)
    Expect.that(b.byteAt(3)).toBe(0)
  }
  Test.it("fromString encodes UTF-8 bytes") {
    var b = Buffer.fromString("hi")
    Expect.that(b.count).toBe(2)
    Expect.that(b.byteAt(0)).toBe(0x68)
    Expect.that(b.byteAt(1)).toBe(0x69)
  }
  Test.it("fromString handles multi-byte UTF-8") {
    // "é" is 0xC3 0xA9 in UTF-8.
    var b = Buffer.fromString("é")
    Expect.that(b.count).toBe(2)
    Expect.that(b.byteAt(0)).toBe(0xC3)
    Expect.that(b.byteAt(1)).toBe(0xA9)
  }
  Test.it("UTF-8 round-trip via fromBytes + toString") {
    var b = Buffer.fromBytes([0xC3, 0xA9])
    Expect.that(b.toString).toBe("é")
  }
  Test.it("fromBytes copies a list") {
    var b = Buffer.fromBytes([1, 2, 3])
    Expect.that(b.count).toBe(3)
    Expect.that(b.byteAt(0)).toBe(1)
  }
  Test.it("fromBytes rejects out-of-range values") {
    var e = Fiber.new { Buffer.fromBytes([1, 256, 3]) }.try()
    Expect.that(e).toContain("integers in 0..=255")
  }
}

Test.describe("Buffer mutation") {
  Test.it("append with string") {
    var b = Buffer.fromString("hello")
    b.append(" world")
    Expect.that(b.toString).toBe("hello world")
  }
  Test.it("append with buffer") {
    var b = Buffer.fromString("hello")
    b.append(Buffer.fromString(" world"))
    Expect.that(b.toString).toBe("hello world")
  }
  Test.it("append with list") {
    var b = Buffer.fromString("ab")
    b.append([0x63, 0x64])
    Expect.that(b.toString).toBe("abcd")
  }
  Test.it("setByteAt overwrites") {
    var b = Buffer.fromString("hello")
    b.setByteAt(0, 0x48)  // "H"
    Expect.that(b.toString).toBe("Hello")
  }
  Test.it("clear empties the buffer") {
    var b = Buffer.fromString("hello")
    b.clear
    Expect.that(b.count).toBe(0)
  }
}

Test.describe("Buffer views") {
  Test.it("slice(start, end) extracts a sub-buffer") {
    var b = Buffer.fromString("hello world")
    Expect.that(b.slice(6, 11).toString).toBe("world")
  }
  Test.it("slice(start) runs to the end") {
    var b = Buffer.fromString("hello")
    Expect.that(b.slice(2).toString).toBe("llo")
  }
  Test.it("slice supports negative indices") {
    var b = Buffer.fromString("hello")
    Expect.that(b.slice(-3, -1).toString).toBe("ll")
  }
  Test.it("indexOf finds a byte") {
    var b = Buffer.fromString("hi there")
    Expect.that(b.indexOf(0x20)).toBe(2)  // space
    Expect.that(b.indexOf(0x00)).toBe(-1)
  }
  Test.it("startsWith / endsWith") {
    var b = Buffer.fromString("hello world")
    Expect.that(b.startsWith("hello")).toBe(true)
    Expect.that(b.startsWith("world")).toBe(false)
    Expect.that(b.endsWith("world")).toBe(true)
    Expect.that(b.endsWith("hello")).toBe(false)
  }
  Test.it("toList returns a copy") {
    var b = Buffer.fromString("ab")
    var l = b.toList
    Expect.that(l.count).toBe(2)
    l[0] = 99
    // Mutation of the copy doesn't affect the buffer.
    Expect.that(b.byteAt(0)).toBe(0x61)
  }
}

Test.describe("Buffer equality") {
  Test.it("equal buffers compare ==") {
    var a = Buffer.fromString("hello")
    var b = Buffer.fromString("hello")
    Expect.that(a == b).toBe(true)
  }
  Test.it("different buffers compare !=") {
    var a = Buffer.fromString("hello")
    var b = Buffer.fromString("world")
    Expect.that(a == b).toBe(false)
  }
  Test.it("non-buffer on RHS compares false") {
    var a = Buffer.fromString("hi")
    Expect.that(a == "hi").toBe(false)
  }
}

// --- BufferReader -----------------------------------------------

Test.describe("BufferReader") {
  Test.it("read(n) returns up to n bytes") {
    var r = BufferReader.new(Buffer.fromString("hello"))
    Expect.that(r.read(3).toString).toBe("hel")
    Expect.that(r.read(3).toString).toBe("lo")
  }
  Test.it("read at EOF returns empty buffer") {
    var r = BufferReader.new(Buffer.fromString("hi"))
    r.read(2)
    Expect.that(r.read(10).count).toBe(0)
  }
  Test.it("readAll reads to EOF") {
    var r = BufferReader.new(Buffer.fromString("hello world"))
    Expect.that(r.readAll.toString).toBe("hello world")
  }
  Test.it("readAll after partial read drains remainder") {
    var r = BufferReader.new(Buffer.fromString("hello world"))
    r.read(5)
    Expect.that(r.readAll.toString).toBe(" world")
  }
  Test.it("readString shortcut") {
    var r = BufferReader.new(Buffer.fromString("abc"))
    Expect.that(r.readString).toBe("abc")
  }
  Test.it("readLine splits on \\n") {
    var r = BufferReader.new(Buffer.fromString("line1\nline2\nline3"))
    Expect.that(r.readLine).toBe("line1")
    Expect.that(r.readLine).toBe("line2")
    Expect.that(r.readLine).toBe("line3")
    Expect.that(r.readLine).toBeNull()
  }
  Test.it("readLine strips \\r\\n") {
    var r = BufferReader.new(Buffer.fromString("win\r\nunix\n"))
    Expect.that(r.readLine).toBe("win")
    Expect.that(r.readLine).toBe("unix")
  }
  Test.it("readLine handles blank lines") {
    var r = BufferReader.new(Buffer.fromString("a\n\nb\n"))
    Expect.that(r.readLine).toBe("a")
    Expect.that(r.readLine).toBe("")
    Expect.that(r.readLine).toBe("b")
  }
}

// --- StringReader -----------------------------------------------

Test.describe("StringReader") {
  Test.it("reads a string's bytes") {
    var r = StringReader.new("hello")
    Expect.that(r.readAll.toString).toBe("hello")
  }
  Test.it("rejects non-string") {
    var e = Fiber.new { StringReader.new(42) }.try()
    Expect.that(e).toContain("expected a string")
  }
}

// --- BufferWriter -----------------------------------------------

Test.describe("BufferWriter") {
  Test.it("write(string) appends bytes") {
    var w = BufferWriter.new()
    w.write("hello")
    Expect.that(w.buffer.toString).toBe("hello")
  }
  Test.it("write(buffer) appends bytes") {
    var w = BufferWriter.new()
    w.write(Buffer.fromString("hi"))
    w.write(Buffer.fromString(" there"))
    Expect.that(w.buffer.toString).toBe("hi there")
  }
  Test.it("write(list) appends bytes") {
    var w = BufferWriter.new()
    w.write([0x41, 0x42, 0x43])
    Expect.that(w.buffer.toString).toBe("ABC")
  }
  Test.it("writeLine appends line with newline") {
    var w = BufferWriter.new()
    w.writeLine("first")
    w.writeLine("second")
    Expect.that(w.buffer.toString).toBe("first\nsecond\n")
  }
  Test.it("write on closed aborts") {
    var w = BufferWriter.new()
    w.close
    var e = Fiber.new { w.write("x") }.try()
    Expect.that(e).toContain("closed")
  }
  Test.it("double close is a no-op") {
    var w = BufferWriter.new()
    w.close
    w.close
    Expect.that(w.isClosed).toBe(true)
  }
}

// --- Subclassing Reader -----------------------------------------

class CountReader is Reader {
  construct new(start, end) {
    super()
    _n = start
    _end = end
  }
  readRaw_(max) {
    if (_n > _end) return null
    var bytes = [0x30 + _n, 0x0A]
    _n = _n + 1
    return bytes
  }
}

Test.describe("subclassing Reader across modules") {
  Test.it("custom Reader subclass works end-to-end") {
    var r = CountReader.new(1, 3)
    Expect.that(r.readLine).toBe("1")
    Expect.that(r.readLine).toBe("2")
    Expect.that(r.readLine).toBe("3")
    Expect.that(r.readLine).toBeNull()
  }
}

// --- Custom readers via callback --------------------------------

Test.describe("Reader.withFn") {
  Test.it("callback-driven Reader works end-to-end") {
    var n = 1
    var end = 3
    var r = Reader.withFn {|max|
      if (n > end) return null
      var bytes = [0x30 + n, 0x0A]
      n = n + 1
      return bytes
    }
    Expect.that(r.readLine).toBe("1")
    Expect.that(r.readLine).toBe("2")
    Expect.that(r.readLine).toBe("3")
    Expect.that(r.readLine).toBeNull()
  }
  Test.it("readAll drains a callback-driven Reader") {
    var items = [[0x61, 0x62], [0x63], null]
    var i = 0
    var r = Reader.withFn {|max|
      var v = items[i]
      i = i + 1
      return v
    }
    Expect.that(r.readAll.toString).toBe("abc")
  }
}

Test.describe("Writer.withFn") {
  Test.it("callback-driven Writer captures writes") {
    var captured = []
    var w = Writer.withFn {|bytes|
      var i = 0
      while (i < bytes.count) {
        captured.add(bytes[i])
        i = i + 1
      }
    }
    w.write("hello")
    Expect.that(captured.count).toBe(5)
    Expect.that(captured[0]).toBe(0x68)
  }
}

// --- AsyncReader (Reader.withTryFn + Fiber.yield) ---------------
//
// `withTryFn` yields to the enclosing fiber on "would block". To
// drive such a reader to completion you need an outer loop that
// keeps calling `.call()` until `isDone` — a scheduler, or a
// simple drain loop in tests. @hatch:events' `Scheduler.runAll`
// is the production-facing helper; here we drive manually to
// keep @hatch:io standalone.

var driveFiber_ = Fn.new {|fib|
  var last = null
  while (!fib.isDone) last = fib.call()
  return last
}

Test.describe("Reader.withTryFn") {
  Test.it("skips WouldBlock results by yielding; returns bytes") {
    var tick = 0
    var r = Reader.withTryFn {|max|
      tick = tick + 1
      if (tick == 1) return []           // WouldBlock on first try
      if (tick == 2) return [0x68, 0x69] // "hi" on second
      return null
    }
    var fib = Fiber.new { r.readAll.toString }
    var result = driveFiber_.call(fib)
    Expect.that(result).toBe("hi")
    Expect.that(tick).toBeGreaterThan(2)
  }
  Test.it("null still means EOF with no yields needed") {
    var r = Reader.withTryFn {|max| null }
    var fib = Fiber.new { r.readAll }
    var out = driveFiber_.call(fib)
    Expect.that(out.count).toBe(0)
  }
  Test.it("readLine yields until newline arrives") {
    var items = [[], [0x61], [0x62, 0x0A], [0x63, 0x0A], null]
    var i = 0
    var r = Reader.withTryFn {|max|
      var v = items[i]
      i = i + 1
      return v
    }
    var lines = []
    var fib = Fiber.new {
      var line = r.readLine
      while (line != null) {
        lines.add(line)
        line = r.readLine
      }
    }
    driveFiber_.call(fib)
    Expect.that(lines[0]).toBe("ab")
    Expect.that(lines[1]).toBe("c")
  }
}

Test.run()
