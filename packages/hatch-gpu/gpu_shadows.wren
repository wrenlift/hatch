// @hatch:gpu/gpu_shadows — shadow primitives beyond the single
// directional-light path that `Renderer3D.enableShadows` ships.
//
// Today this file carries the CPU math the GPU side needs to grow
// CSM (Cascaded Shadow Maps) and cubemap point shadows. The actual
// pipeline + WGSL changes land alongside in the same module once
// the GPU-debug session batches the texture-array work; until
// then, callers can already drive cascade splits and per-face
// view matrices from these helpers — useful for prototyping the
// data path against the existing single-cascade renderer.
//
// References: Lloyd et al. 2006 "Logarithmic Perspective Shadow
// Maps"; the practical "PSSM" hybrid that ships in most engines
// blends a uniform split and a logarithmic split via a tuning
// constant λ ∈ [0, 1].

import "@hatch:math" for Vec3, Mat4

/// Cascaded shadow-map cascade-split math. Returns the near /
/// far planes for each cascade along the view direction; the
/// caller turns these into per-cascade orthographic frusta +
/// light-space view-projection matrices, then renders the scene
/// once per cascade with the correct viewport into a texture
/// array.
///
/// Two helpers ship:
///
///   - [splits] gives the split distances for `n` cascades
///     blending a uniform and a logarithmic distribution via
///     `lambda` ∈ `[0, 1]` (0 = uniform, 1 = pure log; 0.5 is
///     the canonical PSSM compromise).
///
///   - [cascadeMatrix] composes one cascade's light-space VP
///     given the view-space [near, far] slice, the light
///     direction, and the camera basis. Builds an orthographic
///     box tight to the view-frustum slice for high texel
///     density on near geometry.
class CascadeShadows {
  /// Compute split distances along the view direction. Returns a
  /// `List<Num>` of length `n + 1` such that cascade `i` covers
  /// `[result[i], result[i + 1]]`.
  ///
  /// `lambda = 0` → uniform splits (constant world-space slab
  /// width). `lambda = 1` → logarithmic splits (constant
  /// shadow-map-density bias toward the camera). `lambda = 0.5`
  /// is the PSSM convention.
  ///
  /// @param {Num} near. Camera near plane.
  /// @param {Num} far.  Camera far plane.
  /// @param {Num} n.    Cascade count (>= 1, typically 3 or 4).
  /// @param {Num} lambda. 0..1 blend factor.
  /// @returns {List<Num>}
  static splits(near, far, n, lambda) {
    if (n < 1) Fiber.abort("CascadeShadows.splits: n must be >= 1")
    if (near <= 0) Fiber.abort("CascadeShadows.splits: near must be > 0 for log splits")
    if (far <= near) Fiber.abort("CascadeShadows.splits: far must exceed near")
    var ratio = far / near
    var range = far - near
    var out = List.filled(n + 1, 0)
    out[0] = near
    var i = 1
    while (i < n) {
      var p = i / n
      // Logarithmic split (constant ratio per cascade).
      var logSplit = near * ratio.pow(p)
      // Uniform split (constant width per cascade).
      var uniSplit = near + range * p
      out[i] = lambda * logSplit + (1 - lambda) * uniSplit
      i = i + 1
    }
    out[n] = far
    return out
  }

  /// Build the light-space view-projection for one cascade slice.
  ///
  /// `camera` keys: `eye` (Vec3), `forward` (Vec3, normalised),
  /// `right` (Vec3), `up` (Vec3), `aspect` (Num), `fovY` (Num
  /// radians). Compose these from your `Camera3D` once per
  /// frame.
  ///
  /// `lightDir` is the direction the light TRAVELS in (sun-to-
  /// ground); the matrix is built from the opposite vector
  /// looking back along the light's incoming ray.
  ///
  /// `sliceNear` / `sliceFar` come from [splits] for the cascade
  /// in question. Output is a `Mat4` suitable for the existing
  /// `Renderer3D` shadow-pass uniform.
  ///
  /// @param {Map} camera
  /// @param {Vec3} lightDir
  /// @param {Num}  sliceNear
  /// @param {Num}  sliceFar
  /// @returns {Mat4}
  static cascadeMatrix(camera, lightDir, sliceNear, sliceFar) {
    // 8 frustum-slice corners in world space.
    var eye = camera["eye"]
    var forward = camera["forward"]
    var right = camera["right"]
    var up = camera["up"]
    var fovY = camera["fovY"]
    var aspect = camera["aspect"]

    var tanHalfFovY = (fovY * 0.5).tan
    var hNear = sliceNear * tanHalfFovY
    var wNear = hNear * aspect
    var hFar  = sliceFar  * tanHalfFovY
    var wFar  = hFar * aspect

    var centerNear = Vec3.new(
      eye.x + forward.x * sliceNear,
      eye.y + forward.y * sliceNear,
      eye.z + forward.z * sliceNear)
    var centerFar  = Vec3.new(
      eye.x + forward.x * sliceFar,
      eye.y + forward.y * sliceFar,
      eye.z + forward.z * sliceFar)

    var corners = [
      // Near plane.
      cornerOffset_(centerNear, right, up, -wNear, -hNear),
      cornerOffset_(centerNear, right, up,  wNear, -hNear),
      cornerOffset_(centerNear, right, up, -wNear,  hNear),
      cornerOffset_(centerNear, right, up,  wNear,  hNear),
      // Far plane.
      cornerOffset_(centerFar,  right, up, -wFar,  -hFar),
      cornerOffset_(centerFar,  right, up,  wFar,  -hFar),
      cornerOffset_(centerFar,  right, up, -wFar,   hFar),
      cornerOffset_(centerFar,  right, up,  wFar,   hFar)
    ]

    // Build a light-space basis. `view` looks along the light
    // direction (so the light sees the scene "through" itself).
    // Use world-up unless the light direction is (anti)parallel
    // to it, in which case fall back to world-right so the cross
    // product stays non-degenerate.
    var ld = lightDir
    var len = (ld.x * ld.x + ld.y * ld.y + ld.z * ld.z).sqrt
    if (len <= 0) Fiber.abort("CascadeShadows.cascadeMatrix: lightDir must be non-zero")
    var lf = Vec3.new(ld.x / len, ld.y / len, ld.z / len)
    var worldUp = lf.y.abs > 0.999 ? Vec3.new(1, 0, 0) : Vec3.new(0, 1, 0)

    // Sphere-fit the slice — radius = distance from centre to
    // far-plane corner. Sphere-fit makes the cascade rotation-
    // invariant: rotating the camera doesn't grow / shrink the
    // shadow map's covered area, so texel size stays stable.
    var centre = Vec3.new(
      (centerNear.x + centerFar.x) * 0.5,
      (centerNear.y + centerFar.y) * 0.5,
      (centerNear.z + centerFar.z) * 0.5)
    var radius = 0
    var i = 0
    while (i < corners.count) {
      var c = corners[i]
      var dx = c.x - centre.x
      var dy = c.y - centre.y
      var dz = c.z - centre.z
      var d = (dx * dx + dy * dy + dz * dz).sqrt
      if (d > radius) radius = d
      i = i + 1
    }

    // View from above the slice centre along the light direction.
    var eyeBack = Vec3.new(
      centre.x - lf.x * radius,
      centre.y - lf.y * radius,
      centre.z - lf.z * radius)
    var view = Mat4.lookAt(eyeBack, centre, worldUp)
    // Tight ortho around the sphere — covers the slice's full
    // extent in screen-aligned axes. Near plane sits just before
    // `centre`, far plane just past it; the doubled radius gives
    // a stable depth range as the camera moves.
    var proj = Mat4.ortho(-radius, radius, -radius, radius, 0, radius * 2)
    return proj * view
  }

  // Private: world-space corner at (right * w, up * h) offset
  // from a frustum-slice centre.
  static cornerOffset_(centre, right, up, w, h) {
    return Vec3.new(
      centre.x + right.x * w + up.x * h,
      centre.y + right.y * w + up.y * h,
      centre.z + right.z * w + up.z * h)
  }
}

/// Cubemap-shadow-map face math for point lights. A point light
/// renders the scene depth six times — once per cube face. Each
/// face is a 90° perspective looking along ±X / ±Y / ±Z; the
/// caller builds the matrix list once at scene setup (or on
/// light move) and binds them to the six shadow passes.
///
/// ## Example
///
/// ```wren
/// var faces = PointShadow.facesFor(lightPos, 0.1, 50)
/// for (i in 0...6) {
///   renderer.beginShadowFace(faces[i], shadowCubemap.face(i))
///   scene.draw(renderer)
///   renderer.endShadowFace()
/// }
/// ```
class PointShadow {
  /// Build the 6 face view-projection matrices for a cube-map
  /// point shadow. Faces are ordered `+X, -X, +Y, -Y, +Z, -Z`
  /// — matches the GLES / WebGPU cube-face binding order.
  ///
  /// @param {Vec3} pos.  Light world-space position.
  /// @param {Num}  near.
  /// @param {Num}  far.
  /// @returns {List<Mat4>}
  static facesFor(pos, near, far) {
    // 90° fov, square aspect — exactly fills one cube face.
    var halfPi = 1.5707963267948966
    var proj = Mat4.perspective(halfPi, 1, near, far)
    // (target, up) per face. Up vectors are flipped on +Y / -Y
    // so the resulting matrix matches the canonical OpenGL /
    // WebGPU cube-map face orientation.
    var targets = [
      [Vec3.new(pos.x + 1, pos.y,     pos.z),     Vec3.new(0, -1, 0)],
      [Vec3.new(pos.x - 1, pos.y,     pos.z),     Vec3.new(0, -1, 0)],
      [Vec3.new(pos.x,     pos.y + 1, pos.z),     Vec3.new(0, 0, 1)],
      [Vec3.new(pos.x,     pos.y - 1, pos.z),     Vec3.new(0, 0, -1)],
      [Vec3.new(pos.x,     pos.y,     pos.z + 1), Vec3.new(0, -1, 0)],
      [Vec3.new(pos.x,     pos.y,     pos.z - 1), Vec3.new(0, -1, 0)]
    ]
    var out = []
    var i = 0
    while (i < 6) {
      var view = Mat4.lookAt(pos, targets[i][0], targets[i][1])
      out.add(proj * view)
      i = i + 1
    }
    return out
  }
}
