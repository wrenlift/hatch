// @hatch:spatial acceptance tests. ClusterGrid + Octree
// invariants: insert / move / remove maintain the entity set,
// radius / AABB queries return exactly the entities inside the
// volume (no false positives, no misses), early-out via `false`
// return short-circuits the walk.

import "./spatial"   for ClusterGrid, Octree
import "@hatch:test"   for Test
import "@hatch:assert" for Expect

Test.describe("ClusterGrid.insert + count + remove") {
  Test.it("count tracks insert / remove") {
    var g = ClusterGrid.new(-10, -10, -10, 10, 10, 10, 2)
    Expect.that(g.count).toBe(0)
    g.insert(1, 0, 0, 0)
    g.insert(2, 3, 3, 3)
    Expect.that(g.count).toBe(2)
    g.remove(1)
    Expect.that(g.count).toBe(1)
    g.remove(99)        // unknown id — no-op
    Expect.that(g.count).toBe(1)
  }

  Test.it("aborts on duplicate id") {
    var g = ClusterGrid.new(-10, -10, -10, 10, 10, 10, 2)
    g.insert(1, 0, 0, 0)
    var e = Fiber.new { g.insert(1, 5, 5, 5) }.try()
    Expect.that(e).toContain("already present")
  }
}

Test.describe("ClusterGrid.queryRadius") {
  Test.it("returns every entity inside the radius and no others") {
    var g = ClusterGrid.new(-10, -10, -10, 10, 10, 10, 2)
    g.insert(1, 0, 0, 0)
    g.insert(2, 1, 0, 0)
    g.insert(3, 5, 0, 0)
    g.insert(4, -8, 0, 0)
    var hits = []
    g.queryRadius(0, 0, 0, 2.0) {|id, x, y, z| hits.add(id) }
    Expect.that(hits.count).toBe(2)
    Expect.that(hits.contains(1)).toBe(true)
    Expect.that(hits.contains(2)).toBe(true)
  }

  Test.it("respects the spherical distance, not the AABB") {
    var g = ClusterGrid.new(-10, -10, -10, 10, 10, 10, 2)
    g.insert(1, 1.4, 1.4, 0)    // distance ≈ 1.98 < 2.0 → in
    g.insert(2, 1.5, 1.5, 0)    // distance ≈ 2.12 > 2.0 → out
    var hits = []
    g.queryRadius(0, 0, 0, 2.0) {|id, x, y, z| hits.add(id) }
    Expect.that(hits.count).toBe(1)
    Expect.that(hits[0]).toBe(1)
  }

  Test.it("returning false short-circuits the walk") {
    var g = ClusterGrid.new(-10, -10, -10, 10, 10, 10, 5)
    for (i in 0...20) g.insert(i, 0, 0, 0)
    var seen = 0
    g.queryRadius(0, 0, 0, 1.0) {|id, x, y, z|
      seen = seen + 1
      seen >= 3 ? false : true
    }
    Expect.that(seen).toBe(3)
  }
}

Test.describe("ClusterGrid.queryAabb") {
  Test.it("returns entities inside the AABB") {
    var g = ClusterGrid.new(-10, -10, -10, 10, 10, 10, 2)
    g.insert(1, 0, 0, 0)
    g.insert(2, 3, 3, 3)
    g.insert(3, 6, 0, 0)
    var hits = []
    g.queryAabb(-1, -1, -1, 4, 4, 4) {|id, x, y, z| hits.add(id) }
    Expect.that(hits.count).toBe(2)
    Expect.that(hits.contains(1)).toBe(true)
    Expect.that(hits.contains(2)).toBe(true)
  }
}

Test.describe("ClusterGrid.move") {
  Test.it("re-buckets when crossing a cell boundary") {
    var g = ClusterGrid.new(-10, -10, -10, 10, 10, 10, 2)
    g.insert(1, 0, 0, 0)
    var before = []
    g.queryRadius(0, 0, 0, 0.5) {|id, x, y, z| before.add(id) }
    Expect.that(before.count).toBe(1)

    g.move(1, 6, 6, 6)

    var afterOld = []
    g.queryRadius(0, 0, 0, 0.5) {|id, x, y, z| afterOld.add(id) }
    Expect.that(afterOld.count).toBe(0)
    var afterNew = []
    g.queryRadius(6, 6, 6, 0.5) {|id, x, y, z| afterNew.add(id) }
    Expect.that(afterNew.count).toBe(1)
  }

  Test.it("aborts on an unknown id") {
    var g = ClusterGrid.new(-10, -10, -10, 10, 10, 10, 2)
    var e = Fiber.new { g.move(99, 0, 0, 0) }.try()
    Expect.that(e).toContain("unknown id")
  }
}

Test.describe("ClusterGrid scale") {
  Test.it("queries 1000 points within an expected radius bucket") {
    var g = ClusterGrid.new(-100, -100, -100, 100, 100, 100, 4)
    var seed = 12345
    var rng = Fn.new { |s|
      // Deterministic LCG so the count is identical across runs.
      var n = (s * 1103515245 + 12345) % 2147483648
      return n
    }
    var s = seed
    for (i in 0...1000) {
      s = rng.call(s)
      var x = (s % 200) - 100
      s = rng.call(s)
      var y = (s % 200) - 100
      s = rng.call(s)
      var z = (s % 200) - 100
      g.insert(i, x, y, z)
    }
    Expect.that(g.count).toBe(1000)

    var hits = 0
    g.queryRadius(0, 0, 0, 50.0) {|id, x, y, z| hits = hits + 1 }
    // Volume of a 50-radius sphere ≈ 523600; volume of the
    // 200³ uniform box = 8 000 000. Hit rate ≈ 6.5 %% → ~65
    // entities. Loose bounds to keep the seed-dependent count
    // from flaking.
    Expect.that(hits > 30).toBe(true)
    Expect.that(hits < 120).toBe(true)
  }
}

Test.describe("Octree.insert + count + remove") {
  Test.it("count tracks insert / remove") {
    var t = Octree.new(-10, -10, -10, 10, 10, 10, 4)
    Expect.that(t.count).toBe(0)
    t.insert(1, 0, 0, 0)
    t.insert(2, 3, 3, 3)
    Expect.that(t.count).toBe(2)
    t.remove(1)
    Expect.that(t.count).toBe(1)
  }

  Test.it("aborts on duplicate id") {
    var t = Octree.new(-10, -10, -10, 10, 10, 10, 4)
    t.insert(1, 0, 0, 0)
    var e = Fiber.new { t.insert(1, 5, 5, 5) }.try()
    Expect.that(e).toContain("already present")
  }
}

Test.describe("Octree.queryRadius") {
  Test.it("returns entities inside the sphere, even after subdivision") {
    // maxPerLeaf = 2 forces subdivision early so the recursive
    // descent path is exercised.
    var t = Octree.new(-10, -10, -10, 10, 10, 10, 2)
    t.insert(1, 0, 0, 0)
    t.insert(2, 1, 0, 0)
    t.insert(3, -1, 0, 0)
    t.insert(4, 0, 1, 0)
    t.insert(5, 0, -1, 0)
    t.insert(6, 5, 5, 5)
    var hits = []
    t.queryRadius(0, 0, 0, 1.5) {|id, x, y, z| hits.add(id) }
    Expect.that(hits.count).toBe(5)
    Expect.that(hits.contains(6)).toBe(false)
  }

  Test.it("returning false short-circuits the walk") {
    var t = Octree.new(-10, -10, -10, 10, 10, 10, 2)
    for (i in 0...20) t.insert(i, 0, 0, 0)
    var seen = 0
    t.queryRadius(0, 0, 0, 1.0) {|id, x, y, z|
      seen = seen + 1
      seen >= 3 ? false : true
    }
    Expect.that(seen).toBe(3)
  }
}

Test.describe("Octree.queryAabb") {
  Test.it("returns entities inside the AABB, even after subdivision") {
    var t = Octree.new(-10, -10, -10, 10, 10, 10, 2)
    t.insert(1, 0, 0, 0)
    t.insert(2, 2, 2, 2)
    t.insert(3, 5, 5, 5)
    t.insert(4, -3, -3, -3)
    var hits = []
    t.queryAabb(-1, -1, -1, 3, 3, 3) {|id, x, y, z| hits.add(id) }
    Expect.that(hits.count).toBe(2)
    Expect.that(hits.contains(1)).toBe(true)
    Expect.that(hits.contains(2)).toBe(true)
  }
}

Test.describe("Octree subdivision invariant") {
  Test.it("survives stacking many entities at the same point") {
    var t = Octree.new(-10, -10, -10, 10, 10, 10, 2)
    // All entities co-located at the origin would loop forever in
    // a naive subdivide; the implementation must bound recursion
    // when entities are degenerate. We just want the build + count
    // + query to finish without aborting.
    for (i in 0...20) t.insert(i, 0, 0, 0)
    Expect.that(t.count).toBe(20)
    var hits = 0
    t.queryRadius(0, 0, 0, 0.5) {|id, x, y, z| hits = hits + 1 }
    Expect.that(hits).toBe(20)
  }
}

Test.run()
