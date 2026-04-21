import "./zip"         for Zip
import "@hatch:test"   for Test
import "@hatch:assert" for Expect

// --- Round-trip: write then read -------------------------------

Test.describe("Zip.write + Zip.read round-trip") {
  Test.it("single entry (string body)") {
    var arc = Zip.write({ "hello.txt": "Hello, world!" })
    // Archive is List<Num> and starts with the local-file-header
    // magic: 'P','K',0x03,0x04.
    Expect.that(arc is List).toBe(true)
    Expect.that(arc[0]).toBe(0x50) // P
    Expect.that(arc[1]).toBe(0x4B) // K
    Expect.that(arc[2]).toBe(0x03)
    Expect.that(arc[3]).toBe(0x04)

    var pt = Zip.read(arc, "hello.txt")
    Expect.that(pt.count).toBe(13)
    Expect.that(pt[0]).toBe(0x48)   // H
    Expect.that(pt[12]).toBe(0x21)  // !
  }

  Test.it("binary body (List<Num>)") {
    var bytes = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
    var arc = Zip.write({ "raw.bin": bytes })
    var pt = Zip.read(arc, "raw.bin")
    Expect.that(pt.count).toBe(10)
    var i = 0
    while (i < 10) {
      Expect.that(pt[i]).toBe(i)
      i = i + 1
    }
  }

  Test.it("multiple entries") {
    var arc = Zip.write({
      "a.txt": "alpha",
      "b.txt": "beta",
      "c.txt": "gamma"
    })
    Expect.that(Zip.read(arc, "a.txt").count).toBe(5)
    Expect.that(Zip.read(arc, "b.txt").count).toBe(4)
    Expect.that(Zip.read(arc, "c.txt").count).toBe(5)
  }

  Test.it("List<[name, bytes]> form preserves order") {
    var arc = Zip.write([
      ["first.txt", "1"],
      ["second.txt", "22"],
      ["third.txt", "333"]
    ])
    var names = Zip.entries(arc)
    Expect.that(names[0]).toBe("first.txt")
    Expect.that(names[1]).toBe("second.txt")
    Expect.that(names[2]).toBe("third.txt")
  }
}

// --- Compression methods ---------------------------------------

Test.describe("Zip.write methods") {
  Test.it("store (uncompressed) round-trip") {
    var arc = Zip.write({ "file.txt": "hello store" }, "store")
    Expect.that(Zip.read(arc, "file.txt").count).toBe(11)
    var info = Zip.info(arc)
    Expect.that(info[0]["method"]).toBe("store")
  }

  Test.it("deflate round-trip") {
    // Repetitive input → deflate should actually compress it.
    var body = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    var arc = Zip.write({ "b.txt": body }, "deflate")
    Expect.that(Zip.read(arc, "b.txt").count).toBe(100)
    var info = Zip.info(arc)
    Expect.that(info[0]["method"]).toBe("deflate")
    // Compressed size should be noticeably smaller than source.
    Expect.that(info[0]["compressedSize"] < 50).toBe(true)
  }

  Test.it("zstd round-trip") {
    var arc = Zip.write({ "z.txt": "hello zstd zstd zstd" }, "zstd")
    Expect.that(Zip.read(arc, "z.txt").count).toBe(20)
    var info = Zip.info(arc)
    Expect.that(info[0]["method"]).toBe("zstd")
  }

  Test.it("unknown method aborts") {
    var e = Fiber.new { Zip.write({ "x": "y" }, "lzma") }.try()
    Expect.that(e).toContain("unknown compression method")
  }
}

// --- Inspection -------------------------------------------------

Test.describe("Zip.entries + Zip.info") {
  Test.it("entries lists names in archive order") {
    var arc = Zip.write([
      ["a", "1"],
      ["b", "2"],
      ["c", "3"]
    ])
    var names = Zip.entries(arc)
    Expect.that(names.count).toBe(3)
    Expect.that(names[0]).toBe("a")
    Expect.that(names[2]).toBe("c")
  }

  Test.it("info reports size and compressedSize") {
    var arc = Zip.write({ "hello.txt": "Hello, world!" })
    var info = Zip.info(arc)
    Expect.that(info.count).toBe(1)
    Expect.that(info[0]["name"]).toBe("hello.txt")
    Expect.that(info[0]["size"]).toBe(13)
    Expect.that(info[0]["isDir"]).toBe(false)
  }
}

// --- readAll ----------------------------------------------------

Test.describe("Zip.readAll") {
  Test.it("returns a Map<name → bytes>") {
    var arc = Zip.write({
      "a.txt": "alpha",
      "b.txt": "beta"
    })
    var all = Zip.readAll(arc)
    Expect.that(all is Map).toBe(true)
    Expect.that(all["a.txt"].count).toBe(5)
    Expect.that(all["b.txt"].count).toBe(4)
  }
}

// --- Missing entries -------------------------------------------

Test.describe("Zip.read misses") {
  Test.it("unknown name → null") {
    var arc = Zip.write({ "only.txt": "hi" })
    Expect.that(Zip.read(arc, "nope.txt")).toBeNull()
  }
}

// --- Validation -------------------------------------------------

Test.describe("Zip validation") {
  Test.it("malformed archive aborts") {
    var e = Fiber.new { Zip.entries([0, 0, 0, 0]) }.try()
    Expect.that(e).toContain("Zip.entries")
  }
  Test.it("bad archive type aborts") {
    var e = Fiber.new { Zip.entries("not-bytes") }.try()
    Expect.that(e).toContain("list of bytes")
  }
}

Test.run()
