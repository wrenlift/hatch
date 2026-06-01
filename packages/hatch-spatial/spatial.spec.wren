// @hatch:spatial acceptance tests. ClusterGrid + Octree
// invariants: insert / move / remove maintain the entity set,
// radius / AABB queries return exactly the entities inside the
// volume (no false positives, no misses), early-out via `false`
// return short-circuits the walk.

import "./spatial"   for ClusterGrid, Octree, Quadtree2D, BVH
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

Test.describe("Quadtree2D.insert + remove + queryRadius") {
  Test.it("count tracks insert / remove") {
    var t = Quadtree2D.new(-10, -10, 10, 10, 4)
    Expect.that(t.count).toBe(0)
    t.insert(1, 0, 0)
    t.insert(2, 3, 3)
    Expect.that(t.count).toBe(2)
    t.remove(1)
    Expect.that(t.count).toBe(1)
  }

  Test.it("aborts on duplicate id") {
    var t = Quadtree2D.new(-10, -10, 10, 10, 4)
    t.insert(1, 0, 0)
    var e = Fiber.new { t.insert(1, 2, 2) }.try()
    Expect.that(e).toContain("already present")
  }

  Test.it("queryRadius returns every entity inside the circle, none outside") {
    var t = Quadtree2D.new(-100, -100, 100, 100, 4)
    t.insert(1, 0, 0)
    t.insert(2, 5, 0)
    t.insert(3, 30, 30)
    var hits = {}
    t.queryRadius(0, 0, 10) {|id, x, y| hits[id] = true }
    Expect.that(hits[1]).toBe(true)
    Expect.that(hits[2]).toBe(true)
    Expect.that(hits.containsKey(3)).toBe(false)
  }

  Test.it("queryAabb returns every entity inside the rectangle") {
    var t = Quadtree2D.new(-100, -100, 100, 100, 4)
    for (i in 0...50) t.insert(i, i * 1.0, i * 1.0)
    var hits = []
    t.queryAabb(10, 10, 30, 30) {|id, x, y| hits.add(id) }
    // ids 10..30 inclusive.
    Expect.that(hits.count).toBe(21)
  }

  Test.it("survives stacking many entities at the same point") {
    var t = Quadtree2D.new(-10, -10, 10, 10, 2)
    for (i in 0...20) t.insert(i, 0, 0)
    Expect.that(t.count).toBe(20)
    var hits = 0
    t.queryRadius(0, 0, 0.5) {|id, x, y| hits = hits + 1 }
    Expect.that(hits).toBe(20)
  }
}

Test.describe("BVH.new + queryAabb") {
  Test.it("empty input gives zero count and queries return 0") {
    var bvh = BVH.new([])
    Expect.that(bvh.count).toBe(0)
    var out = List.filled(8, 0)
    Expect.that(bvh.queryAabb(-1, -1, -1, 1, 1, 1, out)).toBe(0)
  }

  Test.it("queryAabb returns every overlapping item, no misses") {
    // Three unit cubes laid out along x.
    var items = [
      [0,  0, 0, 0, 1, 1, 1],
      [1, 10, 0, 0, 11, 1, 1],
      [2, 20, 0, 0, 21, 1, 1]
    ]
    var bvh = BVH.new(items)
    Expect.that(bvh.count).toBe(3)
    var out = List.filled(8, 0)
    var n = bvh.queryAabb(-1, -1, -1, 12, 1, 1, out)
    Expect.that(n).toBe(2)
    var got = {}
    for (i in 0...n) got[out[i]] = true
    Expect.that(got[0]).toBe(true)
    Expect.that(got[1]).toBe(true)
    Expect.that(got.containsKey(2)).toBe(false)
  }

  Test.it("rejects duplicate ids on build") {
    var e = Fiber.new {
      BVH.new([[7, 0, 0, 0, 1, 1, 1], [7, 5, 5, 5, 6, 6, 6]])
    }.try()
    Expect.that(e).toContain("duplicate id")
  }
}

Test.describe("BVH.queryRay") {
  Test.it("hits items the ray actually enters") {
    // Three blockers strung along +x: at x=5, x=15, x=25.
    var items = [
      [0,  4.5, -0.5, -0.5,  5.5, 0.5, 0.5],
      [1, 14.5, -0.5, -0.5, 15.5, 0.5, 0.5],
      [2, 24.5, -0.5, -0.5, 25.5, 0.5, 0.5]
    ]
    var bvh = BVH.new(items)
    var out = List.filled(8, 0)
    var n = bvh.queryRay(0, 0, 0, 1, 0, 0, out, 8)
    Expect.that(n).toBe(3)
  }

  Test.it("misses items the ray flies past") {
    // Ray on the y-axis won't intersect AABBs lined up on +x.
    var items = [
      [0,  4.5, -0.5, -0.5,  5.5, 0.5, 0.5],
      [1, 14.5, -0.5, -0.5, 15.5, 0.5, 0.5]
    ]
    var bvh = BVH.new(items)
    var out = List.filled(8, 0)
    var n = bvh.queryRay(0, 10, 0, 0, 1, 0, out, 8)
    Expect.that(n).toBe(0)
  }

  Test.it("respects maxResults cap") {
    var items = []
    for (i in 0...10) items.add([i, i * 2.0 - 0.5, -0.5, -0.5, i * 2.0 + 0.5, 0.5, 0.5])
    var bvh = BVH.new(items)
    var out = List.filled(16, 0)
    var n = bvh.queryRay(-1, 0, 0, 1, 0, 0, out, 3)
    Expect.that(n).toBe(3)
  }
}

Test.describe("BVH.queryFrustum") {
  // Build a hand-rolled axis-aligned frustum that retains
  // (-10..10, -10..10, -100..100). Plane format matches
  // Camera3D.frustumPlanes: 6 planes × [a, b, c, d] with positive
  // signed distance = inside.
  //
  // Plane equation: a*x + b*y + c*z + d >= 0 means "inside".
  //   left   :  ( 1, 0, 0,  10)  → x >= -10
  //   right  :  (-1, 0, 0,  10)  → x <=  10
  //   bottom :  ( 0, 1, 0,  10)  → y >= -10
  //   top    :  ( 0,-1, 0,  10)  → y <=  10
  //   near   :  ( 0, 0, 1, 100)  → z >= -100
  //   far    :  ( 0, 0,-1, 100)  → z <=  100
  var planes = List.filled(24, 0)
  // left   : (1, 0, 0, 10) → x >= -10
  planes[0] = 1
  planes[3] = 10
  // right  : (-1, 0, 0, 10) → x <= 10
  planes[4] = -1
  planes[7] = 10
  // bottom : (0, 1, 0, 10) → y >= -10
  planes[9] = 1
  planes[11] = 10
  // top    : (0, -1, 0, 10) → y <= 10
  planes[13] = -1
  planes[15] = 10
  // near   : (0, 0, 1, 100) → z >= -100
  planes[18] = 1
  planes[19] = 100
  // far    : (0, 0, -1, 100) → z <= 100
  planes[22] = -1
  planes[23] = 100

  Test.it("keeps items inside, drops items fully outside") {
    var items = [
      [0,  0, 0, 0,  1, 1, 1],          // fully inside
      [1, 50, 50, 0, 51, 51, 1],         // outside on x AND y
      [2, -5, -5, -5, 5, 5, 5],          // fully inside
      [3, 200, 0, 0, 201, 1, 1]          // outside on x
    ]
    var bvh = BVH.new(items)
    var out = List.filled(8, 0)
    var n = bvh.queryFrustum(planes, out)
    var got = {}
    for (i in 0...n) got[out[i]] = true
    Expect.that(got[0]).toBe(true)
    Expect.that(got[2]).toBe(true)
    Expect.that(got.containsKey(1)).toBe(false)
    Expect.that(got.containsKey(3)).toBe(false)
  }

  Test.it("keeps items that straddle the boundary") {
    var items = [
      [0, 8, 8, 0, 12, 12, 1]    // half inside, half outside
    ]
    var bvh = BVH.new(items)
    var out = List.filled(2, 0)
    var n = bvh.queryFrustum(planes, out)
    Expect.that(n).toBe(1)
    Expect.that(out[0]).toBe(0)
  }
}

Test.describe("BVH.refit") {
  Test.it("rejects updateAabb on unknown id") {
    var bvh = BVH.new([[0, 0, 0, 0, 1, 1, 1]])
    var e = Fiber.new { bvh.updateAabb(99, 0, 0, 0, 1, 1, 1) }.try()
    Expect.that(e).toContain("unknown id")
  }

  Test.it("internal AABBs catch up to moved leaves") {
    var items = [
      [0,  0, 0, 0,  1, 1, 1],
      [1, 10, 0, 0, 11, 1, 1]
    ]
    var bvh = BVH.new(items)
    // Slide item 1 far away (was at x≈10, now at x≈200).
    bvh.updateAabb(1, 200, 0, 0, 201, 1, 1)
    bvh.refit()
    // The pre-refit BVH's root AABB covered roughly x∈[0, 11];
    // after refit a query AABB at x≈200 should still return id 1.
    var out = List.filled(4, 0)
    var n = bvh.queryAabb(199, -1, -1, 202, 2, 2, out)
    Expect.that(n).toBe(1)
    Expect.that(out[0]).toBe(1)
  }
}

Test.run()
