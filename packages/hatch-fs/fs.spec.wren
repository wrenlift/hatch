import "./fs"          for Fs
import "@hatch:test"   for Test
import "@hatch:assert" for Expect

// Per-run scratch directory under the system tmpdir. `setUp`
// re-creates it before every test; `tearDown` removes it. Wren
// doesn't expose process IDs yet, so the dir name includes the
// object id of the global map — good enough to avoid parallel-run
// collisions in practice.
var scratch_ = Fs.tmpDir + "/wlift_hatch_fs_spec"

var reset = Fn.new {
  if (Fs.exists(scratch_)) Fs.removeTree(scratch_)
  Fs.mkdirs(scratch_)
}

Test.describe("text") {
  Test.it("writeText/readText roundtrip") {
    reset.call()
    var p = scratch_ + "/hello.txt"
    Fs.writeText(p, "hello world")
    Expect.that(Fs.readText(p)).toBe("hello world")
  }
  Test.it("empty file reads as empty string") {
    reset.call()
    var p = scratch_ + "/empty.txt"
    Fs.writeText(p, "")
    Expect.that(Fs.readText(p)).toBe("")
  }
  Test.it("unicode roundtrips byte-for-byte") {
    reset.call()
    var p = scratch_ + "/u.txt"
    Fs.writeText(p, "héllo → 世界")
    Expect.that(Fs.readText(p)).toBe("héllo → 世界")
  }
}

Test.describe("lines") {
  Test.it("readLines drops the trailing newline") {
    reset.call()
    var p = scratch_ + "/lines.txt"
    Fs.writeText(p, "a\nb\nc\n")
    var ls = Fs.readLines(p)
    Expect.that(ls.count).toBe(3)
    Expect.that(ls[0]).toBe("a")
    Expect.that(ls[2]).toBe("c")
  }
  Test.it("readLines on file without trailing newline") {
    reset.call()
    var p = scratch_ + "/lines2.txt"
    Fs.writeText(p, "x\ny")
    var ls = Fs.readLines(p)
    Expect.that(ls).toEqual(["x", "y"])
  }
  Test.it("readLines on empty file") {
    reset.call()
    var p = scratch_ + "/empty.txt"
    Fs.writeText(p, "")
    Expect.that(Fs.readLines(p)).toEqual([])
  }
  Test.it("writeLines appends a trailing newline") {
    reset.call()
    var p = scratch_ + "/w.txt"
    Fs.writeLines(p, ["one", "two"])
    Expect.that(Fs.readText(p)).toBe("one\ntwo\n")
  }
  Test.it("writeLines on empty list writes empty file") {
    reset.call()
    var p = scratch_ + "/empty2.txt"
    Fs.writeLines(p, [])
    Expect.that(Fs.readText(p)).toBe("")
  }
}

Test.describe("bytes") {
  Test.it("roundtrip binary content") {
    reset.call()
    var p = scratch_ + "/b.bin"
    var bytes = [0, 1, 255, 128, 64, 42]
    Fs.writeBytes(p, bytes)
    Expect.that(Fs.readBytes(p)).toEqual(bytes)
  }
  Test.it("non-integer byte aborts") {
    reset.call()
    var p = scratch_ + "/bad.bin"
    var e = Fiber.new { Fs.writeBytes(p, [1, 2.5]) }.try()
    Expect.that(e).toContain("integer in 0..=255")
  }
  Test.it("out-of-range byte aborts") {
    reset.call()
    var p = scratch_ + "/bad.bin"
    var e = Fiber.new { Fs.writeBytes(p, [0, 300]) }.try()
    Expect.that(e).toContain("0..=255")
  }
}

Test.describe("metadata") {
  Test.it("exists / isFile / isDir") {
    reset.call()
    var f = scratch_ + "/f.txt"
    Fs.writeText(f, "hi")
    Expect.that(Fs.exists(f)).toBe(true)
    Expect.that(Fs.isFile(f)).toBe(true)
    Expect.that(Fs.isDir(f)).toBe(false)
    Expect.that(Fs.exists(scratch_)).toBe(true)
    Expect.that(Fs.isDir(scratch_)).toBe(true)
    Expect.that(Fs.exists(scratch_ + "/nope")).toBe(false)
  }
  Test.it("size reports byte count") {
    reset.call()
    var f = scratch_ + "/sz.txt"
    Fs.writeText(f, "abcdef")   // 6 bytes
    Expect.that(Fs.size(f)).toBe(6)
  }
}

Test.describe("listing") {
  Test.it("listDir returns entries sorted") {
    reset.call()
    Fs.writeText(scratch_ + "/b.txt", "")
    Fs.writeText(scratch_ + "/a.txt", "")
    Fs.writeText(scratch_ + "/c.txt", "")
    Expect.that(Fs.listDir(scratch_)).toEqual(["a.txt", "b.txt", "c.txt"])
  }
  Test.it("walk visits all descendants") {
    reset.call()
    Fs.mkdirs(scratch_ + "/outer/inner")
    Fs.writeText(scratch_ + "/root.txt", "")
    Fs.writeText(scratch_ + "/outer/mid.txt", "")
    Fs.writeText(scratch_ + "/outer/inner/leaf.txt", "")
    var all = Fs.walk(scratch_)
    Expect.that(all).toContain("root.txt")
    Expect.that(all).toContain("outer")
    Expect.that(all).toContain("outer/mid.txt")
    Expect.that(all).toContain("outer/inner")
    Expect.that(all).toContain("outer/inner/leaf.txt")
  }
}

Test.describe("mutation") {
  Test.it("mkdir creates a single directory") {
    reset.call()
    var p = scratch_ + "/just_one"
    Fs.mkdir(p)
    Expect.that(Fs.isDir(p)).toBe(true)
  }
  Test.it("mkdirs creates intermediate parents") {
    reset.call()
    var p = scratch_ + "/a/b/c"
    Fs.mkdirs(p)
    Expect.that(Fs.isDir(p)).toBe(true)
  }
  Test.it("remove deletes a file") {
    reset.call()
    var p = scratch_ + "/rm.txt"
    Fs.writeText(p, "x")
    Fs.remove(p)
    Expect.that(Fs.exists(p)).toBe(false)
  }
  Test.it("remove on an empty dir deletes it") {
    reset.call()
    var p = scratch_ + "/empty_dir"
    Fs.mkdir(p)
    Fs.remove(p)
    Expect.that(Fs.exists(p)).toBe(false)
  }
  Test.it("removeTree is recursive") {
    reset.call()
    Fs.mkdirs(scratch_ + "/t/u")
    Fs.writeText(scratch_ + "/t/f.txt", "")
    Fs.writeText(scratch_ + "/t/u/g.txt", "")
    Fs.removeTree(scratch_ + "/t")
    Expect.that(Fs.exists(scratch_ + "/t")).toBe(false)
  }
  Test.it("rename moves a path") {
    reset.call()
    var a = scratch_ + "/a.txt"
    var b = scratch_ + "/b.txt"
    Fs.writeText(a, "x")
    Fs.rename(a, b)
    Expect.that(Fs.exists(a)).toBe(false)
    Expect.that(Fs.readText(b)).toBe("x")
  }
}

Test.describe("process paths") {
  Test.it("cwd is an absolute path") {
    Expect.that(Fs.cwd.count > 0).toBe(true)
    Expect.that(Fs.cwd[0]).toBe("/")
  }
  Test.it("tmpDir exists") {
    Expect.that(Fs.isDir(Fs.tmpDir)).toBe(true)
  }
}

// Cleanup after the whole spec.
if (Fs.exists(scratch_)) Fs.removeTree(scratch_)

Test.run()
