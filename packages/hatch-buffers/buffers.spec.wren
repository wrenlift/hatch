import "@hatch:test"   for Test
import "@hatch:assert" for Expect
import "@hatch:crypto" for Aes
import "@hatch:zip"    for Zip

// --- ByteArray construction ------------------------------------

Test.describe("ByteArray construction") {
  Test.it("new(n) is zero-initialized") {
    var b = ByteArray.new(8)
    Expect.that(b.count).toBe(8)
    Expect.that(b.byteLength).toBe(8)
    var i = 0
    while (i < 8) {
      Expect.that(b[i]).toBe(0)
      i = i + 1
    }
  }
  Test.it("new(0) is empty") {
    var b = ByteArray.new(0)
    Expect.that(b.count).toBe(0)
  }
  Test.it("fromList copies values") {
    var b = ByteArray.fromList([10, 20, 30, 255])
    Expect.that(b.count).toBe(4)
    Expect.that(b[0]).toBe(10)
    Expect.that(b[3]).toBe(255)
  }
  Test.it("fromList rejects non-integer bytes") {
    var e = Fiber.new { ByteArray.fromList([1, 2, 300]) }.try()
    Expect.that(e).toContain("0..=255")
  }
  Test.it("fromString copies UTF-8 bytes") {
    var b = ByteArray.fromString("hi!")
    Expect.that(b.count).toBe(3)
    Expect.that(b[0]).toBe(0x68) // h
    Expect.that(b[2]).toBe(0x21) // !
  }
  Test.it("negative count aborts") {
    var e = Fiber.new { ByteArray.new(-1) }.try()
    Expect.that(e).toContain("non-negative")
  }
}

// --- ByteArray accessors ---------------------------------------

Test.describe("ByteArray accessors") {
  Test.it("subscript get/set round-trip") {
    var b = ByteArray.new(4)
    b[0] = 100
    b[1] = 200
    Expect.that(b[0]).toBe(100)
    Expect.that(b[1]).toBe(200)
    Expect.that(b[2]).toBe(0)
  }
  Test.it("negative index addresses from the end") {
    var b = ByteArray.fromList([1, 2, 3, 4])
    Expect.that(b[-1]).toBe(4)
    Expect.that(b[-4]).toBe(1)
  }
  Test.it("iterates in order") {
    var b = ByteArray.fromList([5, 10, 15, 20])
    var total = 0
    for (x in b) total = total + x
    Expect.that(total).toBe(50)
  }
  Test.it("toList round-trip") {
    var b = ByteArray.fromList([1, 2, 3])
    var l = b.toList
    Expect.that(l is List).toBe(true)
    Expect.that(l.count).toBe(3)
    Expect.that(l[0]).toBe(1)
  }
  Test.it("toString reports class and count") {
    Expect.that(ByteArray.new(7).toString).toContain("ByteArray(7)")
  }
}

// --- Float32Array ----------------------------------------------

Test.describe("Float32Array") {
  Test.it("new(n) is zero-initialized") {
    var f = Float32Array.new(4)
    Expect.that(f.count).toBe(4)
    Expect.that(f.byteLength).toBe(16)
    var i = 0
    while (i < 4) {
      Expect.that(f[i]).toBe(0)
      i = i + 1
    }
  }
  Test.it("subscript get/set (with f32 precision)") {
    var f = Float32Array.new(3)
    f[0] = -2.5
    f[1] = 0.5
    Expect.that(f[0]).toBe(-2.5)
    Expect.that(f[1]).toBe(0.5)
  }
  Test.it("fromList round-trip") {
    var f = Float32Array.fromList([1.0, 2.0, 3.0, 4.0])
    var sum = 0
    for (x in f) sum = sum + x
    Expect.that(sum).toBe(10)
  }
  Test.it("is Sequence") {
    Expect.that(Float32Array.new(1) is Sequence).toBe(true)
  }
}

// --- Float64Array ----------------------------------------------

Test.describe("Float64Array") {
  Test.it("preserves full f64 precision") {
    var f = Float64Array.new(1)
    f[0] = 0.1 + 0.2   // 0.30000000000000004 in f64
    // f32 would round this to 0.3 exactly; f64 should keep the
    // extra bits. We check against the same expression rather
    // than a literal so the test isn't fragile.
    Expect.that(f[0] == 0.1 + 0.2).toBe(true)
  }
  Test.it("byteLength = count * 8") {
    Expect.that(Float64Array.new(5).byteLength).toBe(40)
  }
  Test.it("iteration") {
    var f = Float64Array.fromList([10, 20, 30])
    var total = 0
    for (x in f) total = total + x
    Expect.that(total).toBe(60)
  }
}

// --- Interop: typed buffers into the byte APIs -----------------
//
// Every stdlib module that used to take `String | List<Num>` now
// also accepts `ByteArray` for the "bytes" argument — no List
// round-trip needed.

Test.describe("ByteArray interop with @hatch:crypto") {
  Test.it("AES-GCM encrypt/decrypt with ByteArray plaintext") {
    var key = ByteArray.fromList(Aes.key)
    var nonce = ByteArray.fromList(Aes.nonce)
    var pt = ByteArray.fromString("hello typed arrays")
    var ct = Aes.encrypt(key, nonce, pt)
    var rt = Aes.decrypt(key, nonce, ct)
    Expect.that(rt.count).toBe(pt.count)
    var i = 0
    while (i < pt.count) {
      Expect.that(rt[i]).toBe(pt[i])
      i = i + 1
    }
  }
}

Test.describe("ByteArray interop with @hatch:zip") {
  Test.it("Zip.write accepts ByteArray entry body") {
    var body = ByteArray.fromString("typed content")
    var arc = Zip.write({ "file.txt": body })
    // arc is List<Num> (stdlib hasn't been fully migrated yet),
    // but the *input* side accepted a ByteArray — that's the win.
    var pt = Zip.read(arc, "file.txt")
    Expect.that(pt.count).toBe(body.count)
    Expect.that(pt[0]).toBe(body[0])
  }
}

// --- Type relationships ----------------------------------------

Test.describe("TypedArray type tags") {
  Test.it("each class is distinct") {
    Expect.that(ByteArray.new(1) is ByteArray).toBe(true)
    Expect.that(ByteArray.new(1) is Float32Array).toBe(false)
    Expect.that(Float32Array.new(1) is Float32Array).toBe(true)
    Expect.that(Float64Array.new(1) is Float64Array).toBe(true)
  }
  Test.it("all three are Sequence") {
    Expect.that(ByteArray.new(1) is Sequence).toBe(true)
    Expect.that(Float32Array.new(1) is Sequence).toBe(true)
    Expect.that(Float64Array.new(1) is Sequence).toBe(true)
  }
}

Test.run()
