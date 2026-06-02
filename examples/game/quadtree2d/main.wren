// quadtree2d — drop 1000 deterministic 2D points across a 200×200
// square, then run a radius query and an AABB query against the
// tree. The 2D analogue of Octree from @hatch:spatial.

import "@hatch:spatial" for Quadtree2D

var q = Quadtree2D.new(-100, -100, 100, 100, 16)

// Simple LCG for repeatable placement — keeps the example free of
// platform-Random differences.
var state = 12345
var randomf = Fn.new {
  state = (state * 1664525 + 1013904223) % 4294967296
  return state / 4294967296
}

var i = 0
while (i < 1000) {
  var x = (randomf.call() - 0.5) * 200
  var y = (randomf.call() - 0.5) * 200
  q.insert(i, x, y)
  i = i + 1
}
System.print("Quadtree2D: %(q.count) points inserted.")

// Radius query around the origin — count + a few sample ids.
var nearby = 0
var samples = []
q.queryRadius(0, 0, 15) {|id, x, y|
  nearby = nearby + 1
  if (samples.count < 5) samples.add(id)
}
System.print("Within radius 15 of origin: %(nearby) points; first 5 ids = %(samples)")

// AABB query — clip-style box test.
var inBox = 0
q.queryAabb(-50, -50, -25, 25) {|id, x, y| inBox = inBox + 1 }
System.print("Inside the (-50, -50) → (-25, 25) box: %(inBox) points")
