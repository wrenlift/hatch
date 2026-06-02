// cascade-shadows — work out 4 cascade splits across a 0.1..200m
// view range with the standard PSSM λ = 0.5 blend, then build
// the light-space VP for each cascade so a depth-pass renderer
// can bind one per cascade.

import "@hatch:gpu"  for CascadeShadows, PointShadow
import "@hatch:math" for Vec3

var splits = CascadeShadows.splits(0.1, 200, 4, 0.5)
System.print("PSSM splits (near=0.1, far=200, n=4, λ=0.5):")
for (i in 0...splits.count) {
  System.print("  splits[%(i)] = %(splits[i]) m")
}

// Synthetic camera basis. Real callers compose this from
// Camera3D.eye / forward / right / up / fovY / aspect.
var camera = {
  "eye":     Vec3.new(0, 5, 20),
  "forward": Vec3.new(0, -0.2, -1),
  "right":   Vec3.new(1, 0, 0),
  "up":      Vec3.new(0, 1, 0),
  "aspect":  16.0 / 9.0,
  "fovY":    1.05      // ~60°
}
var lightDir = Vec3.new(-0.5, -1, -0.3)

System.print("\nPer-cascade light-space VP (first row of each Mat4):")
var i = 0
while (i < splits.count - 1) {
  var m = CascadeShadows.cascadeMatrix(camera, lightDir, splits[i], splits[i + 1])
  System.print("  cascade %(i) [near=%(splits[i]), far=%(splits[i + 1])]: " +
               "row0 = [%(m.at(0, 0)), %(m.at(0, 1)), %(m.at(0, 2)), %(m.at(0, 3))]")
  i = i + 1
}

// Cubemap point-shadow faces — 6 view-projections, one per cube
// face, that a point light renders depth into.
var faces = PointShadow.facesFor(Vec3.new(10, 8, 0), 0.1, 50)
System.print("\nPoint light at (10, 8, 0): %(faces.count) cube-face matrices ready.")
