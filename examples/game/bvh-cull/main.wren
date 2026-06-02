// bvh-cull — build a BVH over a 10×10 grid of AABBs, run a
// camera-frustum cull, print which ones the renderer would draw.
// One representative-AABB per cell; the grid sits on the XZ plane
// at y = 0.

import "@hatch:spatial" for BVH
import "@hatch:gpu"     for Camera3D, Frustum
import "@hatch:math"    for Vec3

var items = []
for (j in 0...10) {
  for (i in 0...10) {
    var x = i * 2 - 9
    var z = j * 2 - 9
    items.add([j * 10 + i, x - 0.4, -0.4, z - 0.4, x + 0.4, 0.4, z + 0.4])
  }
}
var bvh = BVH.new(items)
System.print("BVH built — %(bvh.count) items.")

// Camera at (0, 8, 12) looking back at the origin. The default
// 60° fovY × 1.0 aspect frames a generous slice of the grid.
var cam = Camera3D.perspective(60, 1.0, 0.1, 100)
cam.lookAt(Vec3.new(0, 8, 12), Vec3.zero, Vec3.unitY)

var visible = List.filled(100, 0)
var n = Frustum.cull(bvh, cam, visible)
System.print("Frustum.cull → %(n) of %(bvh.count) items visible:")
for (i in 0...n) System.write("  %(visible[i])")
System.print("")

// Sanity: the camera's behind, so id 0 at (-9, -9) and id 99 at
// (+9, +9) should both fall inside; far edges (+y / -y outside
// the XZ plane) don't have anything because we built a flat grid.
