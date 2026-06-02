// @hatch:game/water — water-surface primitives. Two helpers
// today:
//
//   Water.makePlane(device, opts)
//     Subdivided horizontal mesh, vertex layout matching
//     Renderer3D. The subdivision matters — flat shading wants 1
//     quad, but vertex displacement in a custom WGSL shader needs
//     vertices to displace, so we expose subdivision as an opt
//     and ship 32 per side as the default sweet spot.
//
//   Water.waveHeight(opts, x, z, t)
//     Scalar height value for a sum of noise-driven waves at
//     world (x, z) and time t. Deterministic in inputs + seed; the
//     same shape feeds GPU shaders (sample at vertex position in
//     the VS) and CPU consumers (raycast-against-water for buoyant
//     props).
//
// A custom water material — refraction, foam, specular highlights
// — is a planned follow-up; the mesh + height sampler unblock the
// "I want a lake visible from the camera" case today.

import "@hatch:gpu"   for Mesh
import "@hatch:noise" for Noise

/// Static namespace for water-surface meshes and wave sampling.
class Water {
  /// Build a subdivided horizontal plane Mesh centred on
  /// `(opts.x, opts.y, opts.z)`.
  ///
  /// `opts` keys:
  ///   - `"size"` (Num, default 100) — total side length in world
  ///     units (the mesh is square).
  ///   - `"subdivisions"` (Num, default 32) — vertex count per
  ///     side; the resulting mesh has `(subdivisions + 1)^2`
  ///     vertices and `6 × subdivisions^2` indices. Bump this when
  ///     the displacement shader needs more samples (longer waves,
  ///     finer detail).
  ///   - `"y"` (Num, default 0) — vertical position of the plane.
  ///   - `"originX"` / `"originZ"` (Num, default centred) — shift
  ///     the corner instead of centring; useful for tiling
  ///     chunks against a Terrain footprint.
  ///   - `"uvScale"` (Num, default 1) — u = (i / N) * uvScale;
  ///     set above 1 to tile a normal map across the surface.
  ///
  /// Vertex layout matches Renderer3D's (pos.xyz, normal.xyz, uv.xy);
  /// normals point +Y because the mesh is flat. A displacement
  /// shader can rewrite per-vertex normals from the height
  /// gradient.
  ///
  /// @param {Device} device
  /// @param {Map} opts
  /// @returns {Mesh}
  static makePlane(device, opts) {
    var size = opts.containsKey("size") ? opts["size"] : 100
    var subs = opts.containsKey("subdivisions") ? opts["subdivisions"] : 32
    if (subs < 1) Fiber.abort("Water.makePlane: subdivisions must be >= 1.")
    var y = opts.containsKey("y") ? opts["y"] : 0
    var originX = opts.containsKey("originX") ? opts["originX"] : -size / 2
    var originZ = opts.containsKey("originZ") ? opts["originZ"] : -size / 2
    var uvScale = opts.containsKey("uvScale") ? opts["uvScale"] : 1

    var step = size / subs
    var n = subs + 1
    var inv = uvScale / subs

    var vertices = []
    for (j in 0...n) {
      var z = originZ + j * step
      for (i in 0...n) {
        var x = originX + i * step
        vertices.add(x)
        vertices.add(y)
        vertices.add(z)
        vertices.add(0)
        vertices.add(1)
        vertices.add(0)
        vertices.add(i * inv)
        vertices.add(j * inv)
      }
    }

    var indices = []
    for (j in 0...subs) {
      for (i in 0...subs) {
        var a = j * n + i
        var b = a + 1
        var c = a + n
        var d = c + 1
        indices.add(a)
        indices.add(c)
        indices.add(b)
        indices.add(b)
        indices.add(c)
        indices.add(d)
      }
    }
    return Mesh.fromArrays(device, vertices, indices)
  }

  /// Sum-of-octaves wave height at world `(x, z)` and time `t`.
  ///
  /// Uses `Noise.simplex3` with `z` repurposed as a 2D position
  /// component and `t * timeScale` as the third axis, so the
  /// wave field genuinely evolves over time rather than just
  /// scrolling.
  ///
  /// `opts` keys:
  ///   - `"amplitude"` (Num, default 0.5) — peak displacement;
  ///     a 2-unit ocean swell wants ~1.0, a kiddie pool wants 0.05.
  ///   - `"scale"` (Num, default 0.1) — spatial frequency. Larger
  ///     → tighter wavelength.
  ///   - `"timeScale"` (Num, default 0.5) — temporal evolution
  ///     rate.
  ///   - `"octaves"` (Num, default 3) — sum that many simplex3
  ///     samples with doubling frequency + halving amplitude per
  ///     octave; classic fBm shape.
  ///   - `"seed"` (Num, default 0).
  ///
  /// Designed to feed either a CPU buoyancy raycast or a vertex
  /// shader (sample at the post-displacement world point of each
  /// vertex). The output is amplitude-bounded by the configured
  /// `amplitude` × harmonic series, never beyond.
  ///
  /// @param {Map} opts
  /// @param {Num} x
  /// @param {Num} z
  /// @param {Num} t
  /// @returns {Num}
  static waveHeight(opts, x, z, t) {
    var amplitude = opts.containsKey("amplitude") ? opts["amplitude"] : 0.5
    var scale     = opts.containsKey("scale")     ? opts["scale"]     : 0.1
    var timeScale = opts.containsKey("timeScale") ? opts["timeScale"] : 0.5
    var octaves   = opts.containsKey("octaves")   ? opts["octaves"]   : 3
    var seed      = opts.containsKey("seed")      ? opts["seed"]      : 0
    if (octaves < 1 || octaves > 8) {
      Fiber.abort("Water.waveHeight: octaves must be in 1..8.")
    }

    var acc = 0
    var amp = amplitude
    var freq = scale
    var st = t * timeScale
    var i = 0
    while (i < octaves) {
      acc = acc + amp * Noise.simplex3(x * freq, z * freq, st * freq, seed + i)
      amp = amp * 0.5
      freq = freq * 2
      i = i + 1
    }
    return acc
  }
}

/// Self-contained render pipeline for animated water surfaces.
/// Vertex shader displaces each vertex via a sum-of-sines wave
/// field and re-derives the normal from the height gradient; the
/// fragment stage blends a base water colour with a sky colour
/// via a Schlick fresnel term and adds Blinn-Phong specular for
/// the sun-on-crests sparkle.
///
/// The pipeline owns its scene UBO + bind group; it does not share
/// state with `Renderer3D`. Calls go:
///
///   var water = WaterPipeline.new(g.device, g.surfaceFormat, g.depthFormat)
///   water.setSun(Vec3.new(-0.3, -1.0, -0.4), Vec3.new(1.0, 0.95, 0.85), 3.0)
///   ...
///   water.beginFrame(g.pass, camera, g.time)
///   water.draw(waterMesh, modelMat4)
///   water.endFrame()
///
/// The same `waveHeight` formula on the CPU side and inside this
/// pipeline's WGSL keeps buoyancy queries lined up with the
/// visible surface — sample `Water.waveHeight(opts, x, z, t)` with
/// the same `opts` values you pass into `setWave_` for matching
/// bits in both.
class WaterPipeline {
  // -- WGSL ------------------------------------------------------

  static SHADER_WGSL_ {
    return "
      struct SceneUniforms {
        vp:           mat4x4<f32>,
        camera_pos:   vec4<f32>,
        sun_dir:      vec4<f32>,   // xyz = direction, w = intensity
        sun_color:    vec4<f32>,
        ambient:      vec4<f32>,
        time_amp_scale: vec4<f32>, // x=time, y=amplitude, z=scale, w=timeScale
        colors:       vec4<f32>,   // r,g,b = base colour;  a = alpha
        sky:          vec4<f32>,   // r,g,b = sky colour;   a = fresnel pow
        flow:         vec4<f32>,   // xy = unit flow direction in xz plane,
                                   // z = unused, w = strength
        foam:         vec4<f32>,   // r,g,b = crest foam colour, a = threshold
                                   //   as a fraction of the wave amplitude
        shore:        vec4<f32>,   // x=near, y=far, z=band (world m),
                                   //   w=enable (1=on, 0=off)
        fog_color:    vec4<f32>,   // r,g,b = fog tint; w = curve mode
                                   //   (0 linear, 1 exp²)
        fog_params:   vec4<f32>,   // x=start, y=end, z=density,
                                   //   w=1/(end-start)
        ripple:       vec4<f32>,   // x=strength (0=off), y=density,
                                   //   z=lifetime (s), w=speed (m/s)
        ripple_scale: vec4<f32>,   // x=cellSize (m) — controls
                                   //   per-sqm ring count + radius;
                                   //   yzw reserved
      };
      struct DrawUniforms {
        model: mat4x4<f32>,
      };
      @group(0) @binding(0) var<uniform> scene: SceneUniforms;
      @group(0) @binding(1) var depth_tex: texture_depth_2d;
      @group(0) @binding(2) var depth_samp: sampler;
      @group(0) @binding(3) var reflection_tex: texture_2d<f32>;
      @group(0) @binding(4) var reflection_samp: sampler;
      @group(1) @binding(0) var<uniform> draw_u: DrawUniforms;

      // Tiny hash for the wave field. We don't include the full
      // fbm2 helper (defined later) so wave_height stays callable
      // from the vertex shader without forward-decl gymnastics —
      // this 3-octave value-noise is plenty for the envelope.
      fn wh_hash(p: vec2<f32>) -> f32 {
        let q = fract(p * vec2<f32>(123.34, 234.45));
        let r = q + dot(q, q + 34.56);
        return fract(r.x * r.y);
      }
      fn wh_vnoise(p: vec2<f32>) -> f32 {
        let i = floor(p);
        let f = fract(p);
        let u = f * f * (3.0 - 2.0 * f);
        let a = wh_hash(i);
        let b = wh_hash(i + vec2<f32>(1.0, 0.0));
        let c = wh_hash(i + vec2<f32>(0.0, 1.0));
        let d = wh_hash(i + vec2<f32>(1.0, 1.0));
        return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
      }
      fn wh_fbm(p: vec2<f32>) -> f32 {
        var v: f32 = 0.0;
        var amp: f32 = 0.55;
        var pp: vec2<f32> = p;
        for (var i: i32 = 0; i < 3; i = i + 1) {
          v = v + amp * wh_vnoise(pp);
          amp = amp * 0.5;
          pp = pp * 2.07;
        }
        return v;
      }

      // Multi-octave sine swell + fbm-driven amplitude envelope.
      // Five sines at golden-angle headings give the underlying
      // chop; an fbm sample at very low frequency in world XZ
      // scales the local amplitude into irregular calm/rough
      // patches. The fbm breaks the lattice that a fixed sine sum
      // otherwise paints into the foam threshold, so the surface
      // no longer reads as a periodic field of fish-scale crests.
      fn wave_height(x: f32, z: f32) -> f32 {
        let a   = scene.time_amp_scale.y;
        let s   = scene.time_amp_scale.z;
        let ts  = scene.time_amp_scale.w;
        let t   = scene.time_amp_scale.x;
        let fp  = (x * scene.flow.x + z * scene.flow.y) * scene.flow.w;
        let p   = t * ts;

        // Slow fbm envelope. The world-space frequency (0.02)
        // matches a wavelength of ~50m, so the envelope reads as
        // macro structure (wave groups), not noise. Time evolution
        // makes the groups travel and reshape.
        let env_p = vec2<f32>(x, z) * 0.020 + vec2<f32>(t * 0.06, -t * 0.04);
        let env   = wh_fbm(env_p);
        let amp_mod = mix(0.25, 1.65, env);
        let al = a * amp_mod;

        let d0 = vec2<f32>( 1.000,  0.000);
        let d1 = vec2<f32>(-0.737,  0.676);
        let d2 = vec2<f32>( 0.087, -0.996);
        let d3 = vec2<f32>( 0.620,  0.785);
        let d4 = vec2<f32>(-0.998, -0.064);
        var h: f32 = 0.0;
        h = h + al * 1.00 * sin((d0.x*x + d0.y*z) * s * 1.00 + p * 1.00 + 0.00 + fp);
        h = h + al * 0.62 * sin((d1.x*x + d1.y*z) * s * 1.73 + p * 1.21 + 1.31 + fp);
        h = h + al * 0.43 * sin((d2.x*x + d2.y*z) * s * 2.31 + p * 0.83 + 2.59 + fp);
        h = h + al * 0.28 * sin((d3.x*x + d3.y*z) * s * 3.07 + p * 1.47 + 0.74 + fp);
        h = h + al * 0.17 * sin((d4.x*x + d4.y*z) * s * 4.13 + p * 0.71 + 2.07 + fp);
        return h;
      }

      struct VsIn  {
        @location(0) pos:    vec3<f32>,
        @location(1) normal: vec3<f32>,
        @location(2) uv:     vec2<f32>,
      };
      struct VsOut {
        @builtin(position) clip:    vec4<f32>,
        @location(0)       world:   vec3<f32>,
        @location(1)       normal:  vec3<f32>,
        @location(2)       uv:      vec2<f32>,
        @location(3)       wave_h:  f32,
      };

      @vertex
      fn vs_main(in: VsIn) -> VsOut {
        let local = (draw_u.model * vec4<f32>(in.pos, 1.0)).xyz;
        let h = wave_height(local.x, local.z);
        let displaced = vec3<f32>(local.x, local.y + h, local.z);

        // Gradient via finite differences in WORLD space, so the
        // normal stays consistent under model translation.
        let eps = 0.5;
        let hdx = wave_height(local.x + eps, local.z);
        let hdz = wave_height(local.x, local.z + eps);
        let dhdx = (hdx - h) / eps;
        let dhdz = (hdz - h) / eps;
        let n = normalize(vec3<f32>(-dhdx, 1.0, -dhdz));

        let clip_pos = scene.vp * vec4<f32>(displaced, 1.0);

        var o: VsOut;
        o.clip    = clip_pos;
        o.world   = displaced;
        o.normal  = n;
        o.uv      = in.uv;
        o.wave_h  = h;
        return o;
      }

      // Convert a WebGPU [0, 1] clip-space depth back to view-space
      // distance (positive metres away from the camera) using the
      // configured near/far planes.
      fn linearize_depth(z01: f32, near: f32, far: f32) -> f32 {
        return (near * far) / (far - z01 * (far - near));
      }

      // Cheap value-noise + 4-octave fbm in world space. Drives the
      // organic blob pattern of shore foam — irregular branching
      // patches like sea foam settling on wet sand.
      fn hash21(p: vec2<f32>) -> f32 {
        let q = fract(p * vec2<f32>(123.34, 234.45));
        let s = q + dot(q, q + 34.56);
        return fract(s.x * s.y);
      }
      fn value_noise(p: vec2<f32>) -> f32 {
        let i = floor(p);
        let f = fract(p);
        let u = f * f * (3.0 - 2.0 * f);
        let a = hash21(i);
        let b = hash21(i + vec2<f32>(1.0, 0.0));
        let c = hash21(i + vec2<f32>(0.0, 1.0));
        let d = hash21(i + vec2<f32>(1.0, 1.0));
        return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
      }
      fn fbm2(p: vec2<f32>) -> f32 {
        var v: f32 = 0.0;
        var amp: f32 = 0.5;
        var pp: vec2<f32> = p;
        for (var i: i32 = 0; i < 4; i = i + 1) {
          v = v + amp * value_noise(pp);
          amp = amp * 0.5;
          pp = pp * 2.07;
        }
        return v;
      }

      // Procedural rain-ripple field. Each cell in a 0.6 m grid
      // either fires a ring (if its hash exceeds (1 - density)) or
      // stays quiet. Firing cells emit a cosine-cross-section ring
      // that expands outward from a hash-derived in-cell centre,
      // with the ring fading over `lifetime` and resetting on a
      // hash-offset phase so neighbouring cells fire out of step.
      fn ripple_pulse(d: f32, age: f32, lifetime: f32, speed: f32) -> f32 {
        let radius = age * speed;
        let band   = abs(d - radius);
        let half_w = 0.05;
        let ring   = exp(-(band * band) / (half_w * half_w));
        let fade   = 1.0 - clamp(age / lifetime, 0.0, 1.0);
        return ring * fade;
      }

      // Sum ripple contributions from a 3×3 neighbourhood of cells
      // around `world_xz`. Each cell only fires if its hash lands
      // inside the density band; cells that don't fire contribute
      // zero (the hottest hot path when rain is off).
      fn ripple_height(world_xz: vec2<f32>, t: f32, density: f32,
                       lifetime: f32, speed: f32, cell_size: f32) -> f32 {
        let p  = world_xz / cell_size;
        let pi = floor(p);
        var sum: f32 = 0.0;
        for (var dy: i32 = -1; dy <= 1; dy = dy + 1) {
          for (var dx: i32 = -1; dx <= 1; dx = dx + 1) {
            let cell = pi + vec2<f32>(f32(dx), f32(dy));
            let h    = wh_hash(cell);
            if (h < 1.0 - density) { continue; }
            let h2     = wh_hash(cell + vec2<f32>(13.7, 41.3));
            let center = (cell + vec2<f32>(h, h2)) * cell_size;
            let d      = distance(world_xz, center);
            // Per-cell phase offset means the 9 cells in the window
            // don't all fire at the same time; the surface shows a
            // shifting field of expanding rings instead of a pulse.
            let raw    = t + h * 17.31;
            let age    = raw - floor(raw / lifetime) * lifetime;
            sum = sum + ripple_pulse(d, age, lifetime, speed);
          }
        }
        return sum;
      }

      @fragment
      fn fs_main(in: VsOut) -> @location(0) vec4<f32> {
        // Subtle high-frequency normal perturbation. Strength is
        // kept low so the bump adds micro-relief to the specular /
        // fresnel response without showing as visible streaks on
        // the surface (which is what aggressive bump did).
        let t       = scene.time_amp_scale.x;
        let drift1  = vec2<f32>( 0.20,  0.13) * t;
        let bump_p  = in.world.xz * 0.9 + drift1;
        let bump_eps = 0.15;
        let bump_strength = 0.08;
        let nx = fbm2(bump_p + vec2<f32>(bump_eps, 0.0)) - fbm2(bump_p - vec2<f32>(bump_eps, 0.0));
        let nz = fbm2(bump_p + vec2<f32>(0.0, bump_eps)) - fbm2(bump_p - vec2<f32>(0.0, bump_eps));
        var bump = vec3<f32>(-nx * bump_strength, 0.0, -nz * bump_strength);

        // Rain ripples — gated entirely off when strength ≤ 0 so
        // dry-weather frames pay zero ripple cost. `cell_size` ties
        // the ring count + radius to the surface scale (small cells
        // for ocean, larger for ponds).
        let r_str = scene.ripple.x;
        if (r_str > 0.001) {
          let r_density = scene.ripple.y;
          let r_life    = scene.ripple.z;
          let r_speed   = scene.ripple.w;
          let r_cell    = max(scene.ripple_scale.x, 0.05);
          let r_eps     = max(r_cell * 0.07, 0.015);
          let rdx = ripple_height(in.world.xz + vec2<f32>(r_eps, 0.0), t, r_density, r_life, r_speed, r_cell)
                  - ripple_height(in.world.xz - vec2<f32>(r_eps, 0.0), t, r_density, r_life, r_speed, r_cell);
          let rdz = ripple_height(in.world.xz + vec2<f32>(0.0, r_eps), t, r_density, r_life, r_speed, r_cell)
                  - ripple_height(in.world.xz - vec2<f32>(0.0, r_eps), t, r_density, r_life, r_speed, r_cell);
          bump = bump + vec3<f32>(-rdx, 0.0, -rdz) * r_str;
        }
        let N = normalize(normalize(in.normal) + bump);
        let V = normalize(scene.camera_pos.xyz - in.world);
        let NdotV = max(dot(N, V), 0.0);

        // Schlick fresnel. The sky.a slot tunes the falloff
        // exponent so callers can dial in a near-constant base
        // colour (low exponent) or a strong horizon glow at
        // grazing angles (high exponent).
        let fres = pow(1.0 - NdotV, scene.sky.a);
        let base = scene.colors.rgb;
        // Reflection texture is sampled when `flow.z >= 0.5`
        // (caller has actually rendered into it). Otherwise fall
        // back to mixing toward the sky colour — uninitialised
        // reflection bytes are zero, and reading those at grazing
        // angles pulls the body to black, which is why this branch
        // exists.
        var refl_color = scene.sky.rgb;
        if (scene.flow.z >= 0.5) {
          let fb_size = vec2<f32>(textureDimensions(reflection_tex, 0));
          let scr_uv  = vec2<f32>(in.clip.x / fb_size.x, in.clip.y / fb_size.y);
          let distort = vec2<f32>(N.x, N.z) * 0.04;
          let refl_uv = clamp(scr_uv + distort, vec2<f32>(0.001, 0.001), vec2<f32>(0.999, 0.999));
          refl_color  = textureSampleLevel(reflection_tex, reflection_samp, refl_uv, 0.0).rgb;
        }
        let body = mix(base, refl_color, fres);

        // Lambert + Blinn-Phong specular. Two-lobe highlight — a
        // sharp pinpoint (exponent 256) on top of a wider sheen
        // (exponent 32). The procedural normal bump above scatters
        // the sharp lobe into glints that read as sun reflecting
        // off the chop. Schlick fresnel further boosts the lobes
        // at grazing angles so distant water gleams brighter than
        // the patch under the camera.
        let L = normalize(-scene.sun_dir.xyz);
        let NdotL = max(dot(N, L), 0.0);
        let H = normalize(L + V);
        let NdotH = max(dot(N, H), 0.0);
        let fres_spec = 0.04 + 0.96 * fres;
        let glint = pow(NdotH, 256.0) * scene.sun_dir.w * 1.4 * fres_spec;
        let sheen = pow(NdotH,  32.0) * scene.sun_dir.w * 0.25;
        let spec  = glint + sheen;
        let diffuse = body * (NdotL * scene.sun_color.rgb + scene.ambient.rgb);
        // Cap the spec*sun contribution per-channel before adding to
        // diffuse. The scene target is LDR (bgra8unorm), so an
        // uncapped sun-glint of (4.5, 3.5, 2.5) would either clamp to
        // (1,1,1) on write OR if normalised by max-luminance collapse
        // the hue to pure sun_color, washing teal out of every glint
        // pixel. Capping at 0.35 keeps glints as bright neutral
        // accents on top of the teal body; PostFX ACES then rolls
        // the highlights hue-preservingly.
        let spec_rgb = min(spec * scene.sun_color.rgb, vec3<f32>(0.35));
        var rgb = diffuse + spec_rgb;

        // Crest foam — gated by a noise mask so the foam doesn't
        // paint the underlying sine lattice as a uniform grid. Foam
        // only appears where BOTH the wave is high enough AND the
        // noise field passes, giving irregular patches. Hard-capped
        // at 0.35 so even where both fire, it's a wisp at the tip,
        // not a wide white wash.
        let amp_local = scene.time_amp_scale.y;
        let crest_thresh = scene.foam.a * amp_local;
        let band = max(0.005, amp_local * 0.20);
        let h_frag = wave_height(in.world.x, in.world.z);
        let crest_intensity = smoothstep(crest_thresh, crest_thresh + band, h_frag);
        let foam_drift = vec2<f32>(scene.flow.x, scene.flow.y) * scene.time_amp_scale.x * 0.35;
        let foam_mask = smoothstep(0.45, 0.68, fbm2(in.world.xz * 0.75 + foam_drift));
        let height_foam = crest_intensity * foam_mask * 0.35;

        // Shore foam — read the depth attachment at the fragment's
        // framebuffer pixel directly (textureLoad: no sampler,
        // no UV math, just the actual pixel value).
        var shore_foam: f32 = 0.0;
        if (scene.shore.w > 0.5) {
          let pix = vec2<i32>(in.clip.xy);
          let scene_d01 = textureLoad(depth_tex, pix, 0);
          let water_d01 = in.clip.z;
          let near      = scene.shore.x;
          let far       = scene.shore.y;
          let scene_z   = linearize_depth(scene_d01, near, far);
          let water_z   = linearize_depth(water_d01, near, far);
          let beneath   = max(scene_z - water_z, 0.0);
          let band_m    = max(scene.shore.z, 0.01);
          let prox      = 1.0 - smoothstep(0.0, band_m, beneath);

          // Foam is a BAND — a continuous stripe hugging the
          // waterline, not a noise field. Inner ribbon is a tight
          // near-solid wash where the terrain is < 30%% of the
          // band depth; outer ribbon fades out over the rest of
          // the band at lower intensity. A gentle multiplicative
          // noise (0.65..1.0) breaks the stripe into a soft organic
          // edge instead of a hard parallel line.
          let inner    = 1.0 - smoothstep(0.0, band_m * 0.30, beneath);
          let outer    = (1.0 - smoothstep(band_m * 0.25, band_m, beneath)) * 0.45;
          let st       = scene.time_amp_scale.x * 0.40;
          let drift    = vec2<f32>(scene.flow.x, scene.flow.y) * st;
          let noise    = fbm2(in.world.xz * 1.8 + drift);
          let modulate = 0.65 + 0.35 * noise;
          shore_foam = max(inner, outer) * modulate;
        }

        let foam_t = clamp(max(height_foam, shore_foam), 0.0, 1.0);
        rgb = mix(rgb, scene.foam.rgb, foam_t);
        // Foam alpha sits ABOVE body alpha so crests + shore
        // patches read as bright white, with just enough
        // translucency at the edges to feel like aerated water and
        // not a plastic decal. At full foam_t this lands at 0.95
        // (effectively opaque white); at foam_t=0 it falls back to
        // the body alpha so the rest of the water keeps its dial.
        let alpha_out = mix(scene.colors.a, 0.95, foam_t);
        // Aerial perspective. Fade the water body into the sky
        // horizon band so the finite water mesh edge merges into
        // the visible sky rather than terminating in a hard line.
        // Linear curve (fog_color.w &lt; 0.5) lets callers set `end`
        // strictly inside the mesh boundary; exp² (≥ 0.5) is the
        // softer haze curve. Alpha rides up to 1.0 with fog_t so
        // sky-blue clear doesn't bleed through near the edge.
        let fog_d   = distance(scene.camera_pos.xyz, in.world);
        let fog_lin = clamp((fog_d - scene.fog_params.x) * scene.fog_params.w, 0.0, 1.0);
        let fog_e   = fog_d * scene.fog_params.z;
        let fog_exp = 1.0 - exp(-(fog_e * fog_e));
        let fog_t   = select(fog_lin, fog_exp, scene.fog_color.w > 0.5);
        let fogged_rgb   = mix(rgb, scene.fog_color.rgb, fog_t);
        let fogged_alpha = mix(alpha_out, 1.0, fog_t);
        return vec4<f32>(fogged_rgb, fogged_alpha);
      }
    "
  }

  // Scene UBO byte size — mat4x4 (64) + 14 × vec4 (224) = 288;
  // padded up to 320 (next 64-byte boundary) so adding one or two
  // more vec4 fields later doesn't force a wgpu reallocation.
  static SCENE_UBO_BYTES_ { 320 }
  // How many floats we actually upload each frame. Bump in lockstep
  // with SCENE_UBO_BYTES_ / 4 if you grow the layout.
  static SCENE_UBO_FLOATS_ { 72 }
  static DRAW_UBO_BYTES_  { 64 }

  /// Build the pipeline against the host device.
  ///
  /// @param {Device} device
  /// @param {String} surfaceFormat. Colour attachment format.
  /// @param {String} depthFormat. Depth attachment format (matches
  ///   the depth texture used in the pass descriptor).
  construct new(device, surfaceFormat, depthFormat) {
    _device = device

    var shader = device.createShaderModule({
      "code":  WaterPipeline.SHADER_WGSL_,
      "label": "water-pipeline-shader"
    })

    _sceneBgl = device.createBindGroupLayout({
      "entries": [
        { "binding": 0, "visibility": ["vertex", "fragment"], "kind": "uniform" },
        // Scene-depth sampling so the fragment shader can mix in
        // shore foam where the terrain underneath the water surface
        // is within a few metres. The bind is always present; the
        // shader gates the actual sample on `shore.w` so callers
        // that don't plumb a depth view just see no shore foam.
        { "binding": 1, "visibility": ["fragment"], "kind": "texture", "sampleType": "depth" },
        { "binding": 2, "visibility": ["fragment"], "kind": "sampler", "samplerType": "non-filtering" },
        // Planar-reflection texture — the scene rendered from a
        // camera mirrored across the water plane. Sampled with a
        // filtering sampler so the reflection edges read smooth.
        { "binding": 3, "visibility": ["fragment"], "kind": "texture" },
        { "binding": 4, "visibility": ["fragment"], "kind": "sampler" }
      ],
      "label": "water-scene-bgl"
    })
    _drawBgl = device.createBindGroupLayout({
      "entries": [
        { "binding": 0, "visibility": ["vertex"], "kind": "uniform" }
      ],
      "label": "water-draw-bgl"
    })
    _pipelineLayout = device.createPipelineLayout({
      "bindGroupLayouts": [_sceneBgl, _drawBgl]
    })
    _pipeline = device.createRenderPipeline({
      "layout": _pipelineLayout,
      "vertex": {
        "module": shader, "entryPoint": "vs_main",
        "buffers": [{
          "arrayStride": 8 * 4,
          "stepMode": "vertex",
          "attributes": [
            { "shaderLocation": 0, "offset": 0,  "format": "float32x3" },
            { "shaderLocation": 1, "offset": 12, "format": "float32x3" },
            { "shaderLocation": 2, "offset": 24, "format": "float32x2" }
          ]
        }]
      },
      "fragment": {
        "module": shader, "entryPoint": "fs_main",
        // Alpha-blend the water against whatever's already in the
        // colour attachment so the body reads as translucent — the
        // terrain visible underneath tints the shoreline shallows
        // and the deep open water still reads as opaque-blue via the
        // shader's fresnel + ambient floor.
        "targets": [{
          "format": surfaceFormat,
          "blend": {
            "color": {
              "srcFactor": "src-alpha",
              "dstFactor": "one-minus-src-alpha",
              "operation": "add"
            },
            "alpha": {
              "srcFactor": "one",
              "dstFactor": "one-minus-src-alpha",
              "operation": "add"
            }
          }
        }]
      },
      "primitive":    { "topology": "triangle-list", "cullMode": "back" },
      // Depth test still keeps water hidden behind taller terrain,
      // but we stop writing depth so a second water surface (a
      // lake inside an island) doesn't z-fight with the ocean
      // plane drawn first.
      "depthStencil": {
        "format": depthFormat, "depthWriteEnabled": false,
        "depthCompare": "less"
      },
      "label": "water-pipeline"
    })

    _sceneUbo = device.createBuffer({
      "size":  WaterPipeline.SCENE_UBO_BYTES_,
      "usage": ["uniform", "copy-dst"],
      "label": "water-scene-ubo"
    })
    // Reused scratchpad for the per-frame scene UBO write. Sized
    // for the full struct so beginFrame can index into specific
    // slots without grow/shrink overhead. Stays as a typed array
    // so the upload hits the fast memcpy path instead of the
    // list-of-numbers slow path.
    _sceneUboFloats = Float32Array.new(WaterPipeline.SCENE_UBO_BYTES_ / 4)

    // Fallback 1×1 depth texture so the scene bind group is always
    // valid even before a caller wires in the real depth attachment
    // via `setShore`. The shader skips its sample on `shore.w == 0`,
    // so the fallback's (undefined) contents never reach output.
    _fallbackDepthTex = device.createTexture({
      "width":  1, "height": 1,
      "format": "depth32float",
      "usage":  ["render-attachment", "texture-binding"],
      "label":  "water-shore-fallback-depth"
    })
    _fallbackDepthView = _fallbackDepthTex.createView()
    _depthView = _fallbackDepthView

    // Reflection target. Owned by the pipeline so callers don't
    // have to wire up the lifetime; sized to the demo's surface
    // via `resize`. Until first resize, a 1×1 placeholder keeps
    // the bind group valid.
    _reflectionW = 1
    _reflectionH = 1
    _reflectionFormat = surfaceFormat
    _reflectionDepthFormat = depthFormat
    _reflectionTex = device.createTexture({
      "width":  1, "height": 1,
      "format": surfaceFormat,
      "usage":  ["render-attachment", "texture-binding"],
      "label":  "water-reflection-color"
    })
    _reflectionView = _reflectionTex.createView()
    _reflectionDepthTex = device.createTexture({
      "width":  1, "height": 1,
      "format": depthFormat,
      "usage":  ["render-attachment"],
      "label":  "water-reflection-depth"
    })
    _reflectionDepthView = _reflectionDepthTex.createView()
    _reflectionSampler = device.createSampler({
      "magFilter":    "linear",
      "minFilter":    "linear",
      "addressModeU": "clamp-to-edge",
      "addressModeV": "clamp-to-edge",
      "label":        "water-reflection-sampler"
    })

    // Non-filtering sampler — depth32float is not float-filterable
    // without a feature toggle, so we read a single nearest texel.
    // Shore foam edges in screen space are dense enough that
    // stairstepping isn't visible at gameplay resolutions.
    _depthSampler = device.createSampler({
      "magFilter":    "nearest",
      "minFilter":    "nearest",
      "addressModeU": "clamp-to-edge",
      "addressModeV": "clamp-to-edge",
      "label":        "water-shore-depth-sampler"
    })

    rebuildSceneBindGroup_()

    // Per-draw UBO pool (one slot per draw in a frame). Same
    // rationale as Renderer3D's pool: queue.write_buffer doesn't
    // sync between draw calls so we can't reuse one UBO across
    // draws; growth is lazy + bounded.
    _drawUboPool       = []
    _drawBindGroupPool = []
    _drawIndex         = 0

    // Default sun + look knobs — overridable via setSun / setWave /
    // setColors / setFlow / setFoam. The defaults render as a
    // calm midday lake; bump amplitude + foam to read as choppy
    // sea, drop alpha to read as shallow.
    _sunDir     = [-0.3, -1.0, -0.4]
    _sunColor   = [1.0, 0.95, 0.85]
    _sunInt     = 3.0
    _ambient    = [0.10, 0.14, 0.20]
    _waveAmp    = 0.4
    _waveScale  = 0.2
    _waveTime   = 0.5
    _baseColor  = [0.05, 0.18, 0.28, 0.85]
    _skyColor   = [0.55, 0.75, 0.92]
    _fresnelPow = 5.0
    // Flow direction across the xz plane. Strength 0 disables
    // drift; positive values make every wave slide along the
    // unit vector.
    _flowX      = 1.0
    _flowZ      = 0.0
    _flowStr    = 0.0
    // Whether the reflection texture has been populated by the
    // caller this frame. When false, the FS uses sky-colour
    // fresnel instead of sampling the (likely uninitialised)
    // reflection target.
    _reflectionEnabled = 0.0
    // Crest foam — colour + threshold expressed as a fraction of
    // the current wave amplitude. 0.7 means foam starts where the
    // wave has climbed past 70 %% of its peak; 1.0 disables it.
    _foamColor  = [0.95, 0.97, 1.0]
    _foamThresh = 0.7

    // Shore foam. Off by default; the caller wires in the scene
    // depth view via `setShore` and from then on the fragment
    // samples the depth texture to fade foam in where the terrain
    // is within `shoreBand` metres beneath the water surface.
    _shoreNear   = 0.1
    _shoreFar    = 100.0
    _shoreBand   = 2.5
    _shoreOn     = 0.0

    // Aerial-perspective fog. Defaults disable the effect by
    // placing `end` past any realistic scene range; demos opt in
    // via `setFog(fog)`.
    _fogColor    = [0.72, 0.78, 0.85]
    _fogStart    = 1.0e9
    _fogEnd      = 1.0e9 + 1.0
    _fogDensity  = 0.0
    _fogCurve    = 0.0

    // Rain-ripple defaults. Strength 0 disables the effect entirely
    // (the FS short-circuits on `ripple.x <= 0.001`), so dry frames
    // pay zero ripple cost. Density 0.35 means ~35%% of cells in
    // the cell grid fire at any moment; lifetime × speed sets the
    // outer radius before a ring dissolves. Cell size sets both
    // the grid spacing AND the natural per-sqm ring count — small
    // cells (0.2–0.3 m) read as ocean-scale spatter; larger
    // (0.6–0.8 m) reads as pond-scale plops.
    _rippleStrength = 0.0
    _rippleDensity  = 0.35
    _rippleLifetime = 0.4
    _rippleSpeed    = 0.6
    _rippleCellSize = 0.6

    _pass = null
  }

  /// Override the sun light. Defaults: warm sun coming down + forward.
  /// @param {List} direction. `[x, y, z]` — the direction the light travels in.
  /// @param {List} color. `[r, g, b]` linear-space.
  /// @param {Num} intensity
  setSun(direction, color, intensity) {
    _sunDir = direction
    _sunColor = color
    _sunInt = intensity
  }

  /// Override the wave field. The same values should be passed to
  /// `Water.waveHeight(opts, x, z, t)` on the CPU side so buoyancy
  /// matches the visible surface.
  ///
  /// @param {Num} amplitude
  /// @param {Num} scale
  /// @param {Num} timeScale
  setWave(amplitude, scale, timeScale) {
    _waveAmp = amplitude
    _waveScale = scale
    _waveTime = timeScale
  }

  /// Override the colour palette + fresnel exponent.
  ///
  /// @param {List} baseColor. `[r, g, b, a]`. Alpha controls
  ///   transparency for blending against the scene behind.
  /// @param {List} skyColor.  `[r, g, b]`.
  /// @param {Num} fresnelPow. Higher → more aggressive sky-glow
  ///   at grazing angles. 5 is a sensible default.
  setColors(baseColor, skyColor, fresnelPow) {
    _baseColor = baseColor
    _skyColor = skyColor
    _fresnelPow = fresnelPow
  }

  /// Override the ambient term (added to every fragment after
  /// diffuse). Useful when the rest of the scene is darker than
  /// the water's default sky-coloured ambient.
  /// @param {List} ambient. `[r, g, b]`.
  setAmbient(ambient) { _ambient = ambient }

  /// Drift direction in the world xz plane plus a strength
  /// multiplier. The shader adds `(x · dirX + z · dirZ) · strength`
  /// to every octave's phase so waves slide along `dir`. Pass
  /// `strength = 0` to lock the wave field in place.
  ///
  /// @param {Num} dirX. xz-plane component (any scale; normalised below).
  /// @param {Num} dirZ.
  /// @param {Num} strength. Roughly the wavelength shift per unit world.
  setFlow(dirX, dirZ, strength) {
    var len = (dirX * dirX + dirZ * dirZ).sqrt
    if (len > 0.0001) {
      _flowX = dirX / len
      _flowZ = dirZ / len
    } else {
      _flowX = 1
      _flowZ = 0
    }
    _flowStr = strength
  }

  /// Crest foam controls.
  ///
  /// @param {List} color. `[r, g, b]` linear-space (white reads
  ///   most naturally; a pale blue tint sells deeper sea).
  /// @param {Num} threshold. 0..1 fraction of the wave amplitude
  ///   above which foam starts mixing in. 0.65–0.8 is the usable
  ///   band; 1.0 disables foam.
  setFoam(color, threshold) {
    _foamColor = color
    _foamThresh = threshold
  }

  /// Shore-foam control. The water shader samples `depthView` at
  /// each fragment's screen position, linearises both that depth
  /// and the water's own depth using `near`/`far`, and fades foam
  /// in over `bandMeters` of beneath-the-surface terrain (so a
  /// fragment sitting 0 m above the floor reads as 100 %% foam, a
  /// fragment `bandMeters` deep reads as 0 %% foam).
  ///
  /// Pass `depthView = null` to disable shore foam (the bind goes
  /// back to the 1×1 fallback and the shader skips the sample).
  ///
  /// IMPORTANT: the caller must draw the water in a render pass
  /// where the depth attachment is bound read-only (set
  /// `"depthReadOnly": true` on the depth-stencil attachment + the
  /// water pipeline's `depthWriteEnabled: false` already cooperates).
  /// wgpu rejects sampling a depth texture that the same pass is
  /// also writing.
  ///
  /// @param {TextureView | null} depthView. Read-only scene depth.
  /// @param {Num} near. Camera near plane (metres).
  /// @param {Num} far.  Camera far plane (metres).
  /// @param {Num} bandMeters. Foam fade depth.
  setShore(depthView, near, far, bandMeters) {
    _shoreNear = near
    _shoreFar  = far
    _shoreBand = bandMeters
    if (depthView == null) {
      _depthView = _fallbackDepthView
      _shoreOn   = 0.0
    } else {
      _depthView = depthView
      _shoreOn   = 1.0
    }
    rebuildSceneBindGroup_()
  }

  /// Toggle whether the FS should sample the reflection texture.
  /// Pass `true` only on frames where you've actually rendered the
  /// scene from a mirror camera into the reflection target via
  /// `beginReflectionPass`; otherwise the FS falls back to the
  /// sky-colour fresnel (which is what you want when reflection
  /// isn't being maintained).
  /// @param {Bool} enabled
  setReflectionEnabled(enabled) {
    _reflectionEnabled = enabled ? 1.0 : 0.0
  }

  /// Update only the shore-foam band width. Cheap — just changes
  /// the value that lands in the scene UBO at the next `beginFrame`.
  /// Use this for a HUD slider so the band can be retuned without
  /// rebuilding the bind group every frame.
  ///
  /// @param {Num} bandMeters
  setShoreBand(bandMeters) { _shoreBand = bandMeters }

  /// Configure the rain-ripple field. The water shader runs a
  /// procedural ring field gated entirely off when `strength <= 0`,
  /// so dry-weather frames cost nothing extra.
  ///
  /// Typical use: call `setRippleScale(cellSize)` once at setup
  /// to pick ocean / lake / pond scale, then per-frame drive
  /// `strength` (and optionally `density`) from rain intensity.
  ///
  /// @param {Num} strength   Amplitude of the normal perturbation.
  ///                         0 disables; sensible range 0..1.5.
  /// @param {Num} density    Fraction of grid cells firing per
  ///                         cycle, 0..1. Default 0.35.
  /// @param {Num} lifetime   Seconds each ring takes to expand and
  ///                         fade. Default 0.4.
  /// @param {Num} speed      Outward expansion speed (m/s). Default
  ///                         0.6.
  setRipple(strength, density, lifetime, speed) {
    _rippleStrength = strength < 0 ? 0 : strength
    _rippleDensity  = density
    _rippleLifetime = lifetime <= 0 ? 0.4 : lifetime
    _rippleSpeed    = speed
  }

  /// Change only the ripple strength. Useful for a rain-on/off
  /// toggle that picks up density/lifetime/speed/cellSize defaults
  /// configured once at setup.
  /// @param {Num} strength
  setRippleStrength(strength) { _rippleStrength = strength < 0 ? 0 : strength }

  /// Change only the firing density (rings per cell per cycle).
  /// Drive this from rain intensity so heavier rain shows visibly
  /// more rings, not just stronger ones.
  /// @param {Num} density   0..1.
  setRippleDensity(density) { _rippleDensity = density }

  /// Set the ripple grid cell size in metres. This is the single
  /// knob that scales rings to the body of water:
  ///  - Ocean / large lake:  0.18–0.30 m  (small, dense spatter)
  ///  - Pond / still water:  0.55–0.80 m  (larger, sparser rings)
  /// Each firing cell emits one ring; ring radius is capped at the
  /// cell radius before fade, so smaller cells = smaller AND more
  /// numerous rings per square metre.
  /// @param {Num} cellSize   metres. Clamped to ≥ 0.05.
  setRippleScale(cellSize) {
    _rippleCellSize = cellSize < 0.05 ? 0.05 : cellSize
  }

  /// Bind a Fog object to the water shader. Subsequent frames
  /// fade the body to `fog.color` over `[fog.start, fog.end]` (or
  /// via exp² when `fog.curve != 0`). Calling once after the sky
  /// is configured is enough — the values are re-uploaded on
  /// every `beginFrame`.
  /// @param {Fog} fog
  setFog(fog) {
    _fogColor   = fog.color
    _fogStart   = fog.start
    _fogEnd     = fog.end
    _fogDensity = fog.density
    _fogCurve   = fog.curve
  }

  /// Begin a frame: writes the scene UBO with the current camera +
  /// sun + wave + colour state and the supplied `time` value, then
  /// binds the pipeline + scene group on `pass`.
  ///
  /// Call once per pass, before `draw` calls. The same render pass
  /// can mix water draws and other renderer draws; the pipeline
  /// rebinds itself on `beginFrame`.
  ///
  /// @param {RenderPass} pass
  /// @param {Camera3D} camera
  /// @param {Num} time. Seconds since simulation start; drives
  ///   the wave animation.
  beginFrame(pass, camera, time) {
    _pass = pass
    _drawIndex = 0

    // Pack the scene UBO directly into the persistent Float32Array
    // scratchpad. Direct slot writes skip the per-element validate
    // loop that a List-shaped upload would incur, AND surface a
    // clean error at the offending slot if a caller hands us a
    // non-number (the prior List-based path masked which field
    // was at fault by indexing into a concatenated buffer).
    var f = _sceneUboFloats
    writeMat4_(f, 0, camera.viewProj)
    var eye = camera.eye
    putF_(f, 16, "camera.eye.x", eye.x)
    putF_(f, 17, "camera.eye.y", eye.y)
    putF_(f, 18, "camera.eye.z", eye.z)
    putF_(f, 19, "camera.eye.w(1)", 1)
    putF_(f, 20, "sun_dir[0]", _sunDir[0])
    putF_(f, 21, "sun_dir[1]", _sunDir[1])
    putF_(f, 22, "sun_dir[2]", _sunDir[2])
    putF_(f, 23, "sun_int", _sunInt)
    putF_(f, 24, "sun_color[0]", _sunColor[0])
    putF_(f, 25, "sun_color[1]", _sunColor[1])
    putF_(f, 26, "sun_color[2]", _sunColor[2])
    putF_(f, 27, "sun_pad", 0)
    putF_(f, 28, "ambient[0]", _ambient[0])
    putF_(f, 29, "ambient[1]", _ambient[1])
    putF_(f, 30, "ambient[2]", _ambient[2])
    putF_(f, 31, "ambient_pad", 0)
    putF_(f, 32, "time", time)
    putF_(f, 33, "waveAmp", _waveAmp)
    putF_(f, 34, "waveScale", _waveScale)
    putF_(f, 35, "waveTime", _waveTime)
    putF_(f, 36, "baseColor[0]", _baseColor[0])
    putF_(f, 37, "baseColor[1]", _baseColor[1])
    putF_(f, 38, "baseColor[2]", _baseColor[2])
    putF_(f, 39, "baseColor[3]", _baseColor[3])
    putF_(f, 40, "skyColor[0]", _skyColor[0])
    putF_(f, 41, "skyColor[1]", _skyColor[1])
    putF_(f, 42, "skyColor[2]", _skyColor[2])
    putF_(f, 43, "fresnelPow", _fresnelPow)
    putF_(f, 44, "flowX", _flowX)
    putF_(f, 45, "flowZ", _flowZ)
    putF_(f, 46, "reflectionEnabled", _reflectionEnabled)
    putF_(f, 47, "flowStr", _flowStr)
    putF_(f, 48, "foamColor[0]", _foamColor[0])
    putF_(f, 49, "foamColor[1]", _foamColor[1])
    putF_(f, 50, "foamColor[2]", _foamColor[2])
    putF_(f, 51, "foamThresh", _foamThresh)
    putF_(f, 52, "shoreNear", _shoreNear)
    putF_(f, 53, "shoreFar", _shoreFar)
    putF_(f, 54, "shoreBand", _shoreBand)
    putF_(f, 55, "shoreOn", _shoreOn)
    putF_(f, 56, "fogColor[0]", _fogColor[0])
    putF_(f, 57, "fogColor[1]", _fogColor[1])
    putF_(f, 58, "fogColor[2]", _fogColor[2])
    putF_(f, 59, "fogCurve", _fogCurve)
    putF_(f, 60, "fogStart", _fogStart)
    putF_(f, 61, "fogEnd", _fogEnd)
    putF_(f, 62, "fogDensity", _fogDensity)
    // Reciprocal of (end-start) precomputed CPU-side so the FS
    // avoids a per-fragment division. Guard against start==end.
    var fogSpan = _fogEnd - _fogStart
    if (fogSpan < 1.0e-3) fogSpan = 1.0e-3
    putF_(f, 63, "fogInvSpan", 1.0 / fogSpan)
    putF_(f, 64, "rippleStrength", _rippleStrength)
    putF_(f, 65, "rippleDensity",  _rippleDensity)
    putF_(f, 66, "rippleLifetime", _rippleLifetime)
    putF_(f, 67, "rippleSpeed",    _rippleSpeed)
    putF_(f, 68, "rippleCellSize", _rippleCellSize)
    putF_(f, 69, "rippleReserved1", 0)
    putF_(f, 70, "rippleReserved2", 0)
    putF_(f, 71, "rippleReserved3", 0)
    _sceneUbo.writeFloatsN(0, _sceneUboFloats, WaterPipeline.SCENE_UBO_FLOATS_)

    pass.setPipeline(_pipeline)
    pass.setBindGroup(0, _sceneBindGroup)
  }

  // Defensive setter — aborts with the slot name if `v` isn't a
  // number. Drops in for a `f[idx] = v` so the eventual native
  // "value must be a number" error gets a human label.
  putF_(arr, idx, label, v) {
    if (!(v is Num)) Fiber.abort("WaterPipeline.beginFrame: slot %(idx) (%(label)) is not a Num: %(v)")
    arr[idx] = v
  }

  // Write a Mat4 into a Float32Array at `off`, transposing from
  // row-major (Mat4.data) to column-major (WGSL std140 layout).
  writeMat4_(arr, off, m) {
    var d = m.data
    arr[off]      = d[0]
    arr[off + 1]  = d[4]
    arr[off + 2]  = d[8]
    arr[off + 3]  = d[12]
    arr[off + 4]  = d[1]
    arr[off + 5]  = d[5]
    arr[off + 6]  = d[9]
    arr[off + 7]  = d[13]
    arr[off + 8]  = d[2]
    arr[off + 9]  = d[6]
    arr[off + 10] = d[10]
    arr[off + 11] = d[14]
    arr[off + 12] = d[3]
    arr[off + 13] = d[7]
    arr[off + 14] = d[11]
    arr[off + 15] = d[15]
  }

  /// Draw a water mesh with the given model transform. Multiple
  /// draws per frame are supported (e.g. a chunked water surface);
  /// each consumes one slot from the per-draw UBO pool.
  ///
  /// @param {Mesh} mesh — typically `Water.makePlane(...)`.
  /// @param {Mat4} model
  draw(mesh, model) {
    if (_pass == null) Fiber.abort("WaterPipeline.draw: call beginFrame first.")
    var i = reserveDrawSlot_()
    var floats = []
    appendMat4_(floats, model)
    _drawUboPool[i].writeFloats(0, floats)

    var pass = _pass
    pass.setBindGroup(1, _drawBindGroupPool[i])
    pass.setVertexBuffer(0, mesh.vertexBuffer)
    pass.setIndexBuffer(mesh.indexBuffer, "uint32")
    pass.drawIndexed(mesh.indexCount)
  }

  /// End of frame. Clears the active pass reference so a stray
  /// `draw` after this point aborts cleanly.
  endFrame() { _pass = null }

  rebuildSceneBindGroup_() {
    if (_sceneBindGroup != null) _sceneBindGroup.destroy
    _sceneBindGroup = _device.createBindGroup({
      "layout":  _sceneBgl,
      "entries": [
        { "binding": 0, "buffer":  _sceneUbo, "size": WaterPipeline.SCENE_UBO_BYTES_ },
        { "binding": 1, "view":    _depthView },
        { "binding": 2, "sampler": _depthSampler },
        { "binding": 3, "view":    _reflectionView },
        { "binding": 4, "sampler": _reflectionSampler }
      ]
    })
  }

  /// Resize the planar-reflection offscreen target. Call this on
  /// surface resize so the reflection matches viewport resolution.
  /// No-op if dimensions already match.
  ///
  /// @param {Num} width
  /// @param {Num} height
  resize(width, height) {
    if (width <= 0 || height <= 0) return
    if (width == _reflectionW && height == _reflectionH) return
    // Order matters: keep the old textures alive UNTIL the bind
    // group is rebuilt against the new ones. Destroying the old
    // textures while the previous bind group still references
    // them is a use-after-free under some wgpu/metal builds and
    // segfaults on the next encoder submission.
    var oldTex = _reflectionTex
    var oldDepthTex = _reflectionDepthTex
    _reflectionW = width
    _reflectionH = height
    _reflectionTex = _device.createTexture({
      "width":  width, "height": height,
      "format": _reflectionFormat,
      "usage":  ["render-attachment", "texture-binding"],
      "label":  "water-reflection-color"
    })
    _reflectionView = _reflectionTex.createView()
    _reflectionDepthTex = _device.createTexture({
      "width":  width, "height": height,
      "format": _reflectionDepthFormat,
      "usage":  ["render-attachment"],
      "label":  "water-reflection-depth"
    })
    _reflectionDepthView = _reflectionDepthTex.createView()
    rebuildSceneBindGroup_()    // now safe to free the old textures
    oldTex.destroy
    oldDepthTex.destroy
  }

  /// Open a render pass writing into the reflection target. The
  /// caller draws the SCENE (terrain + foliage + sky — but NOT
  /// water) into the returned pass using a mirror camera. Close
  /// with `endReflectionPass`.
  ///
  /// The returned pass has the reflection color attachment with a
  /// "clear" load op (sky-coloured fill) and a depth attachment so
  /// the reflected scene Z-tests correctly.
  ///
  /// @param {CommandEncoder} encoder
  /// @param {List} clearColor. `[r, g, b, a]` — typically the sky
  ///   colour so the reflection edges fade to sky.
  /// @returns {RenderPass}
  beginReflectionPass(encoder, clearColor) {
    return encoder.beginRenderPass({
      "colorAttachments": [{
        "view":       _reflectionView,
        "loadOp":     "clear",
        "clearValue": clearColor,
        "storeOp":    "store"
      }],
      "depthStencilAttachment": {
        "view":            _reflectionDepthView,
        "depthLoadOp":     "clear",
        "depthClearValue": 1.0,
        "depthStoreOp":    "store"
      }
    })
  }

  reserveDrawSlot_() {
    if (_drawIndex >= _drawUboPool.count) {
      var ubo = _device.createBuffer({
        "size":  WaterPipeline.DRAW_UBO_BYTES_,
        "usage": ["uniform", "copy-dst"],
        "label": "water-draw-ubo-%(_drawUboPool.count)"
      })
      var bg = _device.createBindGroup({
        "layout":  _drawBgl,
        "entries": [{ "binding": 0, "buffer": ubo, "size": WaterPipeline.DRAW_UBO_BYTES_ }]
      })
      _drawUboPool.add(ubo)
      _drawBindGroupPool.add(bg)
    }
    var i = _drawIndex
    _drawIndex = _drawIndex + 1
    return i
  }

  // Same row-major → column-major transpose Renderer3D uses for
  // its UBO writes. Mat4.data is row-major math convention; WGSL
  // reads 16 floats as column-major.
  appendMat4_(out, m) {
    var d = m.data
    out.add(d[0])
    out.add(d[4])
    out.add(d[8])
    out.add(d[12])
    out.add(d[1])
    out.add(d[5])
    out.add(d[9])
    out.add(d[13])
    out.add(d[2])
    out.add(d[6])
    out.add(d[10])
    out.add(d[14])
    out.add(d[3])
    out.add(d[7])
    out.add(d[11])
    out.add(d[15])
  }

  destroy {
    for (bg in _drawBindGroupPool) bg.destroy
    for (ubo in _drawUboPool)      ubo.destroy
    _drawBindGroupPool = []
    _drawUboPool       = []
    _sceneBindGroup.destroy
    _sceneUbo.destroy
    _depthSampler.destroy
    _fallbackDepthTex.destroy
    _reflectionSampler.destroy
    _reflectionDepthTex.destroy
    _reflectionTex.destroy
    _pipeline.destroy
    _pipelineLayout.destroy
    _drawBgl.destroy
    _sceneBgl.destroy
  }
}
