// @hatch:assets acceptance tests.
//
// Walks the canonical happy paths: open + index, hash equality
// across paths with identical content, get/text/bytes
// round-trips, mtime-driven refresh detection, content-aware
// subscribe-and-fire (mtime touch with no content change is
// silent; actual edit fires the subscriber).

import "./assets"      for Assets, Asset
import "@hatch:fs"     for Fs
import "@hatch:test"   for Test
import "@hatch:assert" for Expect

// Shared scratch dir. Each Test.it block gets a fresh subtree
// under it so we don't have to repeat the boilerplate.
var SCRATCH = Fs.tmpDir + "/hatch-assets-spec"
Fs.mkdirs(SCRATCH)

var seedRoot_ = Fn.new {|name|
  var dir = SCRATCH + "/" + name
  if (Fs.isDir(dir)) Fs.removeTree(dir)
  Fs.mkdirs(dir)
  return dir
}

Test.describe("Assets.open") {
  Test.it("indexes every file under the root and hashes contents") {
    var root = seedRoot_.call("open-basic")
    Fs.writeText(root + "/a.txt",          "alpha")
    Fs.writeText(root + "/b.txt",          "beta")
    Fs.mkdirs(root + "/sub")
    Fs.writeText(root + "/sub/c.txt",      "alpha")  // same content as a.txt

    var db = Assets.open(root)
    Expect.that(db.count).toBe(3)

    Expect.that(db.has("a.txt")).toBe(true)
    Expect.that(db.has("b.txt")).toBe(true)
    Expect.that(db.has("sub/c.txt")).toBe(true)

    // Content-addressable identity: equal bytes → equal hash.
    Expect.that(db.hash("a.txt")).toBe(db.hash("sub/c.txt"))
    Expect.that(db.hash("a.txt") == db.hash("b.txt")).toBe(false)
  }

  Test.it("text and bytes round-trip from disk") {
    var root = seedRoot_.call("rw")
    Fs.writeText(root + "/note.txt", "hello, world")
    var db = Assets.open(root)

    Expect.that(db.text("note.txt")).toBe("hello, world")
    var b = db.bytes("note.txt")
    Expect.that(b.count).toBe(12)
    Expect.that(b[0]).toBe(104)  // 'h'
  }

  Test.it("get on a missing path aborts with a clear error") {
    var root = seedRoot_.call("missing")
    var db = Assets.open(root)
    var e = Fiber.new { db.get("nope.txt") }.try()
    Expect.that(e).toContain("not found")
  }
}

Test.describe("Assets refresh + subscribers") {
  Test.it("get re-hashes when the file's mtime advances") {
    var root = seedRoot_.call("refresh")
    var path = root + "/v.txt"
    Fs.writeText(path, "v1")
    var db = Assets.open(root)

    var h1 = db.hash("v.txt")
    Expect.that(db.text("v.txt")).toBe("v1")

    // Sleep would be nicer; instead nudge mtime forward by
    // re-writing with a different payload. The mtime delta is
    // observable on every filesystem we run on.
    Fs.writeText(path, "v2-different-content")
    var h2 = db.hash("v.txt")
    Expect.that(h2 == h1).toBe(false)
    Expect.that(db.text("v.txt")).toBe("v2-different-content")
  }

  Test.it("on(path) fires the subscriber on actual content changes") {
    var root = seedRoot_.call("subs")
    Fs.writeText(root + "/cfg.json", "{ \"version\": 1 }")

    var db = Assets.open(root)
    var hits = []
    db.on("cfg.json") {|asset| hits.add(asset.hash) }

    // Direct on() registration doesn't fire on first-attach; the
    // user reads the initial state manually via db.get if needed.
    Expect.that(hits.count).toBe(0)

    // Simulate the SIGUSR1 path: rewrite then call the same
    // handler the runtime would, so the spec doesn't need a real
    // signal trip.
    Fs.writeText(root + "/cfg.json", "{ \"version\": 2 }")
    db.handleFileChange_(db.get("cfg.json").absolute)
    Expect.that(hits.count).toBe(1)

    // Mtime-only touch (same bytes) is silent — the SHA-256
    // didn't move, no subscriber fires.
    Fs.writeText(root + "/cfg.json", "{ \"version\": 2 }")
    db.handleFileChange_(db.get("cfg.json").absolute)
    Expect.that(hits.count).toBe(1)

    // Real change again.
    Fs.writeText(root + "/cfg.json", "{ \"version\": 3 }")
    db.handleFileChange_(db.get("cfg.json").absolute)
    Expect.that(hits.count).toBe(2)
  }

  Test.it("off(path, fn) unsubscribes a specific callback") {
    var root = seedRoot_.call("off")
    Fs.writeText(root + "/x", "0")
    var db = Assets.open(root)

    var hits = 0
    var fn = Fn.new {|asset| hits = hits + 1 }
    db.on("x", fn)

    Fs.writeText(root + "/x", "1")
    db.handleFileChange_(db.get("x").absolute)
    Expect.that(hits).toBe(1)

    Expect.that(db.off("x", fn)).toBe(true)
    Fs.writeText(root + "/x", "2")
    db.handleFileChange_(db.get("x").absolute)
    Expect.that(hits).toBe(1)
  }
}

Test.run()
