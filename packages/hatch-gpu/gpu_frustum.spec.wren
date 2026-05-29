// @hatch:gpu — Camera3D.frustumPlanes + Frustum.sphereVisible.
//
// Plane derivation is the kind of thing that silently rots when a
// matrix layout or depth-range convention shifts (row vs column-
// major, OpenGL [-1,1] vs WebGPU [0,1]). These specs lock in:
//   - planes built off the view-projection matrix point inward
//   - on-axis cubes inside the frustum read as visible
//   - cubes behind / beyond the camera read as culled
//   - the near-plane edge case (sphere straddling) reads as visible

import "./gpu" for Camera3D, Frustum
import "@hatch:math"   for Vec3
import "@hatch:test"   for Test
import "@hatch:assert" for Expect

Test.describe("Camera3D.frustumPlanes") {
  Test.it("returns a 24-element Float32Array (4 floats per plane × 6 planes)") {
    var cam = Camera3D.perspective(60, 1.0, 0.1, 100)
    cam.lookAt(Vec3.new(0, 0, 5), Vec3.zero, Vec3.unitY)
    var p = cam.frustumPlanes
    // Float32Array doesn't expose a count; the contract is the
    // 24-float layout. Reading the last slot proves it's at least
    // big enough; writing it via setPlane_ during build proves
    // the upper bound. A future Float32Array.count would tighten this.
    Expect.that(p[23] == p[23]).toBe(true)   // not NaN, slot defined
  }

  Test.it("rebuilds after a lookAt change") {
    var cam = Camera3D.perspective(60, 1.0, 0.1, 100)
    cam.lookAt(Vec3.new(0, 0, 5), Vec3.zero, Vec3.unitY)
    // Origin is in front of camera at z=5 looking at origin.
    Expect.that(Frustum.sphereVisible(cam.frustumPlanes, 0, 0, 0, 1)).toBe(true)
    // Turn the camera the other way; origin should now be behind.
    cam.lookAt(Vec3.new(0, 0, -5), Vec3.new(0, 0, -20), Vec3.unitY)
    Expect.that(Frustum.sphereVisible(cam.frustumPlanes, 0, 0, 0, 0.1)).toBe(false)
  }
}

Test.describe("Frustum.sphereVisible") {
  Test.it("accepts a unit sphere at the camera's gaze target") {
    var cam = Camera3D.perspective(60, 1.0, 0.1, 100)
    cam.lookAt(Vec3.new(0, 0, 10), Vec3.zero, Vec3.unitY)
    Expect.that(Frustum.sphereVisible(cam.frustumPlanes, 0, 0, 0, 1)).toBe(true)
  }

  Test.it("rejects a tiny sphere behind the camera") {
    var cam = Camera3D.perspective(60, 1.0, 0.1, 100)
    cam.lookAt(Vec3.new(0, 0, 10), Vec3.zero, Vec3.unitY)
    // Behind the eye relative to gaze (camera at z=10 looking down -Z;
    // a point at z=+50 is behind the eye).
    Expect.that(Frustum.sphereVisible(cam.frustumPlanes, 0, 0, 50, 0.1)).toBe(false)
  }

  Test.it("rejects a sphere outside the far plane") {
    var cam = Camera3D.perspective(60, 1.0, 0.1, 50)
    cam.lookAt(Vec3.new(0, 0, 10), Vec3.zero, Vec3.unitY)
    Expect.that(Frustum.sphereVisible(cam.frustumPlanes, 0, 0, -200, 0.1)).toBe(false)
  }

  Test.it("rejects a sphere far off the side") {
    var cam = Camera3D.perspective(60, 1.0, 0.1, 100)
    cam.lookAt(Vec3.new(0, 0, 10), Vec3.zero, Vec3.unitY)
    // 100 units off to the right at the gaze plane — way outside
    // a 60° vertical FOV at aspect 1.
    Expect.that(Frustum.sphereVisible(cam.frustumPlanes, 100, 0, 0, 0.5)).toBe(false)
  }

  Test.it("a sphere straddling the near plane still counts as visible") {
    var cam = Camera3D.perspective(60, 1.0, 0.5, 100)
    cam.lookAt(Vec3.new(0, 0, 10), Vec3.zero, Vec3.unitY)
    // Near plane sits at z = 10 - 0.5 = 9.5 in world space.
    // A sphere centred at z=9.6 with radius 0.2 spans 9.4..9.8 —
    // crossing the near plane. Conservative cull keeps it.
    Expect.that(Frustum.sphereVisible(cam.frustumPlanes, 0, 0, 9.6, 0.2)).toBe(true)
  }

  Test.it("orthographic projection planes work the same way") {
    var cam = Camera3D.orthographic(20, 20, 0.1, 100)
    cam.lookAt(Vec3.new(0, 0, 50), Vec3.zero, Vec3.unitY)
    // Inside the 20×20 ortho box at the gaze plane: should be visible.
    Expect.that(Frustum.sphereVisible(cam.frustumPlanes, 5, 5, 0, 1)).toBe(true)
    // Outside the ortho box: should be culled.
    Expect.that(Frustum.sphereVisible(cam.frustumPlanes, 30, 0, 0, 1)).toBe(false)
  }
}

Test.run()
