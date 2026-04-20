import "./path"        for Path
import "@hatch:test"   for Test
import "@hatch:assert" for Expect

Test.describe("join") {
  Test.it("two plain segments") {
    Expect.that(Path.join("foo", "bar")).toBe("foo/bar")
  }
  Test.it("second arg absolute wins") {
    Expect.that(Path.join("foo", "/abs")).toBe("/abs")
  }
  Test.it("no double separator when first ends in /") {
    Expect.that(Path.join("foo/", "bar")).toBe("foo/bar")
  }
  Test.it("empty segments ignored") {
    Expect.that(Path.join("foo", "")).toBe("foo")
    Expect.that(Path.join("", "bar")).toBe("bar")
  }
  Test.it("list form concatenates") {
    Expect.that(Path.join(["a", "b", "c.txt"])).toBe("a/b/c.txt")
  }
  Test.it("list form drops empty elements") {
    Expect.that(Path.join(["a", "", "b"])).toBe("a/b")
  }
  Test.it("list form single element") {
    Expect.that(Path.join(["only"])).toBe("only")
  }
  Test.it("list form empty yields empty") {
    Expect.that(Path.join([])).toBe("")
  }
}

Test.describe("parent") {
  Test.it("normal path") {
    Expect.that(Path.parent("/a/b/c.txt")).toBe("/a/b")
  }
  Test.it("single component") {
    Expect.that(Path.parent("foo")).toBe("")
  }
  Test.it("root stays root") {
    Expect.that(Path.parent("/")).toBe("/")
  }
  Test.it("trailing slash ignored") {
    Expect.that(Path.parent("/a/b/")).toBe("/a")
  }
  Test.it("absolute single component") {
    Expect.that(Path.parent("/x")).toBe("/")
  }
}

Test.describe("basename") {
  Test.it("normal") {
    Expect.that(Path.basename("/a/b/c.txt")).toBe("c.txt")
  }
  Test.it("no slashes") {
    Expect.that(Path.basename("only")).toBe("only")
  }
  Test.it("trailing slash stripped first") {
    Expect.that(Path.basename("foo/bar/")).toBe("bar")
  }
  Test.it("root yields empty") {
    Expect.that(Path.basename("/")).toBe("")
  }
}

Test.describe("stem / extname") {
  Test.it("simple extension") {
    Expect.that(Path.extname("foo.txt")).toBe(".txt")
    Expect.that(Path.stem("foo.txt")).toBe("foo")
  }
  Test.it("double extension uses the final dot") {
    Expect.that(Path.extname("foo.tar.gz")).toBe(".gz")
    Expect.that(Path.stem("foo.tar.gz")).toBe("foo.tar")
  }
  Test.it("no extension") {
    Expect.that(Path.extname("README")).toBe("")
    Expect.that(Path.stem("README")).toBe("README")
  }
  Test.it("dotfile without extension") {
    Expect.that(Path.extname(".bashrc")).toBe("")
    Expect.that(Path.stem(".bashrc")).toBe(".bashrc")
  }
  Test.it("extension stops at directory boundary") {
    Expect.that(Path.extname("dir.with.dots/file")).toBe("")
    Expect.that(Path.stem("dir.with.dots/file")).toBe("file")
  }
}

Test.describe("isAbsolute / isRelative") {
  Test.it("absolute") {
    Expect.that(Path.isAbsolute("/foo")).toBe(true)
    Expect.that(Path.isRelative("/foo")).toBe(false)
  }
  Test.it("relative") {
    Expect.that(Path.isAbsolute("foo/bar")).toBe(false)
    Expect.that(Path.isRelative("foo/bar")).toBe(true)
  }
  Test.it("empty is relative") {
    Expect.that(Path.isAbsolute("")).toBe(false)
  }
}

Test.describe("normalize") {
  Test.it("collapses double slashes") {
    Expect.that(Path.normalize("foo//bar")).toBe("foo/bar")
  }
  Test.it("drops . segments") {
    Expect.that(Path.normalize("foo/./bar")).toBe("foo/bar")
  }
  Test.it("resolves ..") {
    Expect.that(Path.normalize("foo/bar/../baz")).toBe("foo/baz")
  }
  Test.it("preserves leading .. in relative paths") {
    Expect.that(Path.normalize("../foo")).toBe("../foo")
    Expect.that(Path.normalize("../../foo")).toBe("../../foo")
  }
  Test.it("absolute path .. stops at root") {
    Expect.that(Path.normalize("/foo/../..")).toBe("/")
  }
  Test.it("empty becomes .") {
    Expect.that(Path.normalize("")).toBe(".")
  }
  Test.it("root stays root") {
    Expect.that(Path.normalize("/")).toBe("/")
  }
}

Test.describe("split") {
  Test.it("relative path") {
    Expect.that(Path.split("a/b/c")).toEqual(["a", "b", "c"])
  }
  Test.it("absolute path keeps leading empty") {
    var parts = Path.split("/a/b")
    Expect.that(parts[0]).toBe("")
    Expect.that(parts[1]).toBe("a")
    Expect.that(parts[2]).toBe("b")
  }
  Test.it("empty yields empty list") {
    Expect.that(Path.split("")).toEqual([])
  }
}

Test.describe("errors") {
  Test.it("non-string to join") {
    var e = Fiber.new { Path.join(42, "foo") }.try()
    Expect.that(e).toContain("must be strings")
  }
  Test.it("non-string in list") {
    var e = Fiber.new { Path.join(["foo", 42]) }.try()
    Expect.that(e).toContain("list elements must be strings")
  }
}

Test.run()
