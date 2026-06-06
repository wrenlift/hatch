// `@hatch:gpu` Renderer3D — target-agnostic. Imported by both
// `gpu_native` (wgpu host) and `gpu_web` (navigator.gpu wasm
// plugin). The renderer talks to the backend through the public
// `Device` API (`createBuffer`, `createShaderModule`,
// `createBindGroup{,Layout}`, `createRenderPipeline`, `createSampler`,
// `createTexture`, `writeTexture`, `uploadImage`); both backends
// expose that surface identically, so a single Wren source drives
// the PBR pipeline everywhere.
//
// Shader fragments come from `Shader` (also a shared module); the
// material data model from `Material` ditto. This file owns the
// pipeline layout, per-frame light bookkeeping, per-Material
// BindGroup cache, and the WGSL pipeline-specific code.

import "@hatch:math"    for Vec3, Mat4
import "./gpu_shader"   for Shader

/// Cook-Torrance / GGX PBR renderer. One pipeline, three bind
/// groups:
///
/// - Group 0 (scene): vp, camera position, ambient term, and
///   light arrays (up to 4 directional + 8 point + 4 spot). The
///   renderer rebuilds this once per `beginFrame`.
/// - Group 1 (per-draw): model + normal matrix. Rebuilt per
///   `draw` call.
/// - Group 2 (material): 112-byte material uniform + 5 textures
///   (albedo / metallic-roughness / normal / occlusion / emissive)
///   + 1 sampler. Cached per-Material; the cache reuses the
///   group while the material's `revision_` is unchanged and
///   rebuilds when a property has been touched.
///
/// Textures the user leaves unset on a `Material` get bound to
/// 1×1 default fallbacks (white for colour channels, "up" for
/// normal) so the shader can sample unconditionally — the factor
/// always multiplies through, so an unset texture is mathematically
/// identical to the factor alone.
///
/// ```wren
/// var renderer = Renderer3D.new(g.device, g.surfaceFormat, g.depthFormat)
///
/// renderer.beginFrame(g.pass, camera)
/// renderer.setAmbient(Vec3.new(0.1, 0.12, 0.15), 1.0)
/// renderer.addDirectional(Vec3.new(-0.3, -1.0, -0.5),
///                         Vec3.new(1.0, 0.95, 0.85), 3.0)
/// renderer.draw(cubeMesh, redMaterial, Mat4.translation(0, 0, 0))
/// renderer.draw(planeMesh, groundMaterial, Mat4.translation(0, -1, 0))
/// renderer.endFrame()
/// ```
///
/// The renderer does not own the depth target. The caller
/// passes one as part of the render-pass descriptor.
class Renderer3D {
  // Vertex layout: 3 pos + 3 normal + 2 uv. Tangent comes via
  // screen-space derivatives in the fragment shader (see
  // `Shader.normalMapping`), so we don't extend the layout.
  // Vertex layout (12 floats / 48 bytes):
  //   pos.xyz (3) + normal.xyz (3) + uv.xy (2) + tangent.xyzw (4)
  // Tangent.xyz is the tangent direction; tangent.w is the
  // bitangent handedness (+1 / -1) following the glTF spec. A
  // tangent of all zeros signals "no tangent" and tells the
  // fragment shader to fall back to screen-space-derivative TBN.
  static FLOATS_PER_VERTEX_ { 12 }

  /// Number of f32 per billboard instance in the buffer
  /// `drawBillboardN` reads. Layout:
  ///   `[origin.x, origin.y, origin.z, sizeX,
  ///     sizeY, u0, v0, u1,
  ///     v1, r, g, b,
  ///     a, rotation, lodIndex, _pad]`
  /// Use [Renderer3D.writeBillboardInstance] to pack a slot.
  static FLOATS_PER_BILLBOARD_ { 16 }

  // Billboard shader. Spherical camera-facing quad per instance,
  // size + UV rect + colour + axis rotation pulled from a storage
  // buffer indexed by `@builtin(instance_index)`. The VS does the
  // camera-facing math (`forward = normalize(camera_pos - origin)`,
  // `right = world_up × forward`, `up = forward × right`) so the
  // CPU never re-orients quads.
  static BILLBOARD_WGSL_ {
    return "
      struct Scene {
        vp:         mat4x4<f32>,
        camera_pos: vec4<f32>,
      };
      @group(0) @binding(0) var<uniform> scene: Scene;

      struct BillboardInstance {
        pos_sx:    vec4<f32>,
        sy_uv0_u1: vec4<f32>,
        v1_rgb:    vec4<f32>,
        a_rot_lod: vec4<f32>,
      };
      @group(1) @binding(0) var<storage, read> instances: array<BillboardInstance>;

      @group(2) @binding(0) var tex:  texture_2d<f32>;
      @group(2) @binding(1) var samp: sampler;

      struct VsOut {
        @builtin(position) clip:  vec4<f32>,
        @location(0)       uv:    vec2<f32>,
        @location(1)       color: vec4<f32>,
      };

      @vertex
      fn vs_main(@builtin(vertex_index)   vi: u32,
                 @builtin(instance_index) ii: u32) -> VsOut {
        var dx = array<f32, 6>(-0.5, -0.5, 0.5, -0.5, 0.5, 0.5);
        var dy = array<f32, 6>(-0.5,  0.5, 0.5, -0.5, 0.5, -0.5);
        var ux = array<f32, 6>( 0.0,  0.0, 1.0,  0.0, 1.0, 1.0);
        var uy = array<f32, 6>( 0.0,  1.0, 1.0,  0.0, 1.0, 0.0);

        let inst = instances[ii];
        let origin = inst.pos_sx.xyz;
        let sx     = inst.pos_sx.w;
        let sy     = inst.sy_uv0_u1.x;
        let uv0    = vec2<f32>(inst.sy_uv0_u1.y, inst.sy_uv0_u1.z);
        let uv1    = vec2<f32>(inst.sy_uv0_u1.w, inst.v1_rgb.x);
        let color  = vec4<f32>(inst.v1_rgb.y, inst.v1_rgb.z, inst.v1_rgb.w, inst.a_rot_lod.x);
        let rot    = inst.a_rot_lod.y;

        let to_cam  = scene.camera_pos.xyz - origin;
        let forward = normalize(to_cam);
        let world_up = vec3<f32>(0.0, 1.0, 0.0);
        var right = cross(world_up, forward);
        // Camera looking straight down → world_up degenerate.
        // Fall back to world-space X for the right axis so the
        // quad still has a stable orientation.
        if (length(right) < 0.001) {
          right = vec3<f32>(1.0, 0.0, 0.0);
        } else {
          right = normalize(right);
        }
        let up = cross(forward, right);

        let lx = dx[vi] * sx;
        let ly = dy[vi] * sy;
        let cosR = cos(rot);
        let sinR = sin(rot);
        let rx = lx * cosR - ly * sinR;
        let ry = lx * sinR + ly * cosR;
        let world = origin + right * rx + up * ry;

        var o: VsOut;
        o.clip  = scene.vp * vec4<f32>(world, 1.0);
        o.uv    = mix(uv0, uv1, vec2<f32>(ux[vi], uy[vi]));
        o.color = color;
        return o;
      }

      @fragment
      fn fs_main(in: VsOut) -> @location(0) vec4<f32> {
        let tex_s = textureSample(tex, samp, in.uv);
        // Premultiplied-additive: RGB is gated by tex.a (disc
        // falloff for old constant-RGB discs) AND tex.rgb (for
        // discs that bake falloff into RGB), AND in.color.a
        // (lifetime fade). Under additive blend the spark fades
        // out at end-of-life and reads as a circular halo.
        let life = in.color.a;
        let mask = tex_s.a;
        let rgb  = tex_s.rgb * in.color.rgb * life * mask;
        return vec4<f32>(rgb, life * mask);
      }

      // MRT entry — used when the renderer is built with
      // `normalFormat`. Billboards intentionally write a neutral
      // (camera-facing) normal placeholder so a billboard
      // composed against a normal target doesn't trigger wgpu
      // validation, but also doesn't contribute false silhouettes
      // to OutlinePass-style edge detection.
      struct FsOutMrt {
        @location(0) color:  vec4<f32>,
        @location(1) normal: vec4<f32>,
      }
      @fragment
      fn fs_main_mrt(in: VsOut) -> FsOutMrt {
        let tex_s = textureSample(tex, samp, in.uv);
        // Premultiplied-alpha output under the premultiplied
        // blend pipeline: RGB is gated by tex.a (disc falloff)
        // AND in.color.a (lifetime fade) so the spark is a soft
        // circle that cleanly fades out at end-of-life. The
        // output alpha matches the same gate, so at the disc
        // edge / end-of-life the blend formula
        // `src + dst*(1 - src.a)` collapses to `dst` and the
        // background is preserved instead of erased to black.
        let life = in.color.a;
        let mask = tex_s.a;
        let rgb  = tex_s.rgb * in.color.rgb * life * mask;
        // Normal MRT alpha is HARD-ZERO so the alpha-blended
        // normal target preserves `dst` everywhere — there's no
        // gradient from camera-facing to background inside the
        // disc for OutlinePass's sobel to detect, so billboards
        // never get inked.
        return FsOutMrt(vec4<f32>(rgb, life * mask), vec4<f32>(0.5, 0.5, 1.0, 0.0));
      }
    "
  }

  // Hard caps for the per-frame light arrays. Sized at the
  // upper end of what a typical scene actually uses; bump if a
  // game needs more (the uniform block grows by 32 / 32 / 64
  // bytes per added slot for dir / point / spot respectively).
  static MAX_DIR_LIGHTS_   { 4 }
  static MAX_POINT_LIGHTS_ { 8 }
  static MAX_SPOT_LIGHTS_  { 4 }

  // Uniform block sizes. Computed from the WGSL structs.
  //
  // Scene = vp(64) + camera(16) + ambient(16) + counts(16)
  //       + light_vp(64) + shadow_params(16) + wind(16)
  //       + env_top(16) + env_horizon(16) + env_bottom(16)
  //       + dir × 32 + point × 32 + spot × 64
  //       = 64 + 16 + 16 + 16 + 64 + 16 + 16 + 48 + 128 + 256 + 256 = 896 bytes.
  static SCENE_UBO_BYTES_  { 896 }
  static DRAW_UBO_BYTES_   { 128 }       // model(64) + normal_mat(64)
  // 5 vec4s. The trailing slot carries the toon-shading params
  // (band count, rim colour, rim strength) consumed by the cel-
  // shaded pipeline; the PBR shader has a matching field on its
  // MaterialUniforms struct but ignores it, so a single Material
  // can drive either pipeline depending on `shadingModel`.
  static MAT_UBO_BYTES_    { 112 }       // factors(80) + uv_xform vec4 (16) + uv_rot vec4 (16)
  static SHADOW_UBO_BYTES_ { 128 }       // light_vp(64) + model(64) per draw

  // Pre-allocated per-draw UBO slot count. Each individual `draw()`
  // call reserves one slot for its model + normal_mat upload; the
  // pool is sized at construction so first-frame draws don't
  // create + bind 100 buffers under GC pressure. 256 covers a
  // dense procedural scene; pools grow past this on demand at the
  // usual lazy-allocation cost (which is fine once the steady-state
  // peak is reached — the corruption only fires when many
  // createBuffer + createBindGroup calls land inside one
  // command-encoder pass).
  static INITIAL_DRAW_POOL_ { 256 }

  // Pipeline-specific WGSL — structs, bindings, and entry points.
  // Composed with the `Shader` factory library that supplies
  // PBR BRDF, normal-mapping and tonemapping helpers.
  static PBR_WGSL_ {
    return "
      struct SceneUniforms {
        vp:            mat4x4<f32>,
        camera_pos:    vec4<f32>,
        ambient:       vec4<f32>,
        // counts.x = dir light count, .y = point, .z = spot,
        // .w = shadows_enabled (1.0 means light_vp + shadow_tex are
        // populated and the first dir light is the shadow caster).
        counts:        vec4<f32>,
        // World-space → light clip-space matrix for the shadow
        // caster. Zero when shadows are disabled.
        light_vp:      mat4x4<f32>,
        // .x = depth bias (slope-scaled component multiplier),
        // .y = PCF texel-space radius (used for 3×3 jittering),
        // .z/.w = reserved.
        shadow_params: vec4<f32>,
        // xy = wind direction (unit, xz plane), z = time, w = strength
        wind:          vec4<f32>,
        // 3-band environment for image-based lighting. Sampled by
        // surface direction (N for diffuse, reflect(-V, N) for
        // specular). Solid-colour bands lerped by `direction.y`
        // give curved metals a credible reflection gradient with
        // no cubemap binding.
        env_top:       vec4<f32>,
        env_horizon:   vec4<f32>,
        env_bottom:    vec4<f32>,
        dir_lights:    array<DirLight,   4>,
        point_lights:  array<PointLight, 8>,
        spot_lights:   array<SpotLight,  4>,
      };
      struct DrawUniforms {
        model:      mat4x4<f32>,
        normal_mat: mat4x4<f32>,
      };
      struct MaterialUniforms {
        albedo_color:   vec4<f32>,
        emissive_color: vec4<f32>,
        factors:        vec4<f32>,    // x=metallic y=roughness z=normalScale w=occlusionStrength
        alpha:          vec4<f32>,    // x=mode(0/1/2) y=cutoff z=doubleSided w=pad
        // Toon-shading params. Read by the cel-shaded pipeline only;
        // the PBR shader binds this struct identically but ignores
        // the slot.
        //   x = band count (>=2; 3 = classic three-tone cel look)
        //   y = rim strength (0 disables; 1 saturates the silhouette)
        //   z = rim width (Fresnel exponent; higher = thinner rim)
        //   w = ambient floor (shadow side minimum brightness 0..1)
        toon:           vec4<f32>,
        // KHR_texture_transform vec4 #1: xy = uv scale, zw = uv offset.
        // Applied to in.uv before every textureSample so a single
        // small tile can repeat across a large mesh without rewriting
        // mesh UVs. Identity is (1, 1, 0, 0).
        uv_xform:       vec4<f32>,
        // KHR_texture_transform vec4 #2: x = cos(rotation),
        // y = sin(rotation), z/w padding. Rotation is around the UV
        // origin (0, 0) per the KHR spec — pre-translate via offset
        // to rotate around a different pivot. Identity is (1, 0, 0, 0).
        uv_rot:         vec4<f32>,
      };

      @group(0) @binding(0) var<uniform> scene: SceneUniforms;
      // Bound to a 1×1 fallback when shadows aren't enabled; the
      // shader gates sampling on `counts.w` so the fallback's
      // (undefined) contents never surface.
      @group(0) @binding(1) var shadow_tex:  texture_depth_2d;
      @group(0) @binding(2) var shadow_samp: sampler_comparison;
      @group(1) @binding(0) var<uniform> draw_u: DrawUniforms;
      @group(2) @binding(0) var<uniform> mat: MaterialUniforms;
      @group(2) @binding(1) var albedo_tex:    texture_2d<f32>;
      @group(2) @binding(2) var mr_tex:        texture_2d<f32>;
      @group(2) @binding(3) var normal_tex:    texture_2d<f32>;
      @group(2) @binding(4) var occlusion_tex: texture_2d<f32>;
      @group(2) @binding(5) var emissive_tex:  texture_2d<f32>;
      @group(2) @binding(6) var samp:          sampler;

      // KHR_texture_transform helper. Applied to every uv read by
      // `textureSample` so a single tile can be repeated and rotated
      // across a mesh without re-authoring UVs. Identity when
      // `Material.uvScale = (1, 1)`, `uvOffset = (0, 0)`,
      // `uvRotation = 0` (the Material default).
      fn apply_uv_xform(uv: vec2<f32>) -> vec2<f32> {
        let scaled  = uv * mat.uv_xform.xy;
        let c       = mat.uv_rot.x;
        let s       = mat.uv_rot.y;
        let rotated = vec2<f32>(
          scaled.x * c - scaled.y * s,
          scaled.x * s + scaled.y * c
        );
        return rotated + mat.uv_xform.zw;
      }

      // Shadow attenuation for the primary shadow-casting
      // directional light. Returns 1.0 when shadows are disabled
      // or the fragment lies outside the shadow map's clip
      // extents, otherwise a PCF-blurred 0..1 occlusion factor.
      fn shadow_factor(world_pos: vec3<f32>, N: vec3<f32>, L: vec3<f32>) -> f32 {
        if (scene.counts.w < 0.5) {
          return 1.0;
        }
        let pos_light = scene.light_vp * vec4<f32>(world_pos, 1.0);
        let proj      = pos_light.xyz / pos_light.w;
        // NDC -1..1 → texture 0..1 (with Y flip).
        let uv = vec2<f32>(proj.x * 0.5 + 0.5, -proj.y * 0.5 + 0.5);
        if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0 || proj.z > 1.0) {
          return 1.0;
        }
        // Slope-scaled bias to suppress self-shadow acne on
        // surfaces nearly parallel to the light direction.
        let cos_theta = clamp(dot(N, L), 0.0, 1.0);
        let bias      = scene.shadow_params.x * (1.0 - cos_theta) + 0.0005;
        let depth     = proj.z - bias;
        // 3×3 PCF via the hardware comparison sampler. Step size
        // shrinks at glancing angles so the kernel covers fewer
        // pixels in heavily-foreshortened regions.
        let r = scene.shadow_params.y;
        var acc = 0.0;
        acc = acc + textureSampleCompare(shadow_tex, shadow_samp, uv + vec2<f32>(-r, -r), depth);
        acc = acc + textureSampleCompare(shadow_tex, shadow_samp, uv + vec2<f32>( 0.0, -r), depth);
        acc = acc + textureSampleCompare(shadow_tex, shadow_samp, uv + vec2<f32>( r, -r), depth);
        acc = acc + textureSampleCompare(shadow_tex, shadow_samp, uv + vec2<f32>(-r,  0.0), depth);
        acc = acc + textureSampleCompare(shadow_tex, shadow_samp, uv, depth);
        acc = acc + textureSampleCompare(shadow_tex, shadow_samp, uv + vec2<f32>( r,  0.0), depth);
        acc = acc + textureSampleCompare(shadow_tex, shadow_samp, uv + vec2<f32>(-r,  r), depth);
        acc = acc + textureSampleCompare(shadow_tex, shadow_samp, uv + vec2<f32>( 0.0,  r), depth);
        acc = acc + textureSampleCompare(shadow_tex, shadow_samp, uv + vec2<f32>( r,  r), depth);
        return acc / 9.0;
      }

      struct VsIn  {
        @location(0) pos:     vec3<f32>,
        @location(1) normal:  vec3<f32>,
        @location(2) uv:      vec2<f32>,
        @location(3) tangent: vec4<f32>,
      };
      struct VsOut {
        @builtin(position) clip:    vec4<f32>,
        @location(0)       world:   vec3<f32>,
        @location(1)       normal:  vec3<f32>,
        @location(2)       uv:      vec2<f32>,
        @location(3)       tangent: vec4<f32>,
      };

      // Apply wind-driven sway to a model-local vertex. Bends the
      // mesh in the wind direction proportionally to the vertex's
      // local-Y (so the base stays put and the tip moves most). The
      // phase advances along the wind direction so neighbouring
      // blades share a phase and bend together as a rolling gust.
      fn apply_sway(local_pos: vec3<f32>, anchor_world: vec3<f32>, sway: f32) -> vec3<f32> {
        if (sway <= 0.0) { return local_pos; }
        let on_axis = anchor_world.x * scene.wind.x + anchor_world.z * scene.wind.y;
        let phase = on_axis * 0.20 - scene.wind.z * 1.6;
        let osc   = sin(phase);
        let bend  = local_pos.y * sway * scene.wind.w * osc * 0.30;
        return vec3<f32>(
          local_pos.x + scene.wind.x * bend,
          local_pos.y,
          local_pos.z + scene.wind.y * bend
        );
      }

      @vertex
      fn vs_main(in: VsIn) -> VsOut {
        var o: VsOut;
        let anchor = vec3<f32>(draw_u.model[3].x, draw_u.model[3].y, draw_u.model[3].z);
        let local_swayed = apply_sway(in.pos, anchor, mat.alpha.w);
        let world_pos  = draw_u.model * vec4<f32>(local_swayed, 1.0);
        let world_norm = (draw_u.normal_mat * vec4<f32>(in.normal, 0.0)).xyz;
        // Transform tangent into world space via the model matrix
        // (not normal_mat — tangent rotates with the surface, no
        // inverse-transpose needed). Bitangent sign rides in .w.
        let world_tan  = (draw_u.model * vec4<f32>(in.tangent.xyz, 0.0)).xyz;
        o.clip    = scene.vp * world_pos;
        o.world   = world_pos.xyz;
        o.normal  = world_norm;
        o.uv      = in.uv;
        o.tangent = vec4<f32>(world_tan, in.tangent.w);
        return o;
      }

      // Build the world-space normal from a tangent-space normal
      // sample. When the mesh ships a non-zero tangent attribute,
      // use the explicit TBN frame (high-frequency surface detail
      // resolved correctly). When tangent is zero (built-in
      // primitives, legacy meshes), fall back to the screen-space-
      // derivative cotangent frame.
      fn surface_normal(
        N0: vec3<f32>,
        in_tangent: vec4<f32>,
        world_pos: vec3<f32>,
        uv: vec2<f32>,
        sampled_xy: vec2<f32>,
        scale: f32,
      ) -> vec3<f32> {
        let xy = sampled_xy * scale;
        let z = sqrt(saturate(1.0 - dot(xy, xy)));
        let n_t = vec3<f32>(xy, z);
        let tlen2 = dot(in_tangent.xyz, in_tangent.xyz);
        if (tlen2 > 0.0001) {
          // Re-orthonormalise the supplied tangent against the
          // interpolated normal (Gram-Schmidt) — interpolation
          // across the triangle can shear the tangent off the
          // surface plane.
          let T = normalize(in_tangent.xyz - N0 * dot(N0, in_tangent.xyz));
          let B = cross(N0, T) * in_tangent.w;
          let tbn = mat3x3<f32>(T, B, N0);
          return normalize(tbn * n_t);
        }
        return perturb_normal(N0, world_pos, uv, sampled_xy, scale);
      }

      // 3-band environment sampler: lerps bottom→horizon→top by
      // `direction.y`. Returns linear-RGB irradiance scaled by
      // each band's .w intensity. When all three bands are zero
      // (no setEnvironment call), returns zero so the legacy flat
      // ambient still drives the look.
      fn env_sample(dir: vec3<f32>) -> vec3<f32> {
        let y = clamp(dir.y, -1.0, 1.0);
        var c: vec3<f32>;
        if (y >= 0.0) {
          c = mix(scene.env_horizon.rgb, scene.env_top.rgb, y);
        } else {
          c = mix(scene.env_horizon.rgb, scene.env_bottom.rgb, -y);
        }
        return c;
      }

      // PBR lighting computation, extracted from `fs_main` so the
      // MRT entry point (`fs_main_mrt`, defined at the end of this
      // module) can reuse the exact same lit value while ALSO
      // emitting world-space normals into the secondary G-buffer.
      // WGSL doesn't allow one @fragment entry point to call
      // another, so the shared logic has to live in a plain
      // function.
      fn pbr_compute(in: VsOut) -> vec4<f32> {
        // 1. Albedo: factor × texture. Texture sampled as sRGB
        //    (the shader expects linear input — when the host
        //    creates the texture with `*-srgb` format, the
        //    sampler does the decode; otherwise we'd `srgb_to_linear`).
        let albedo_sample = textureSample(albedo_tex, samp, apply_uv_xform(in.uv));
        var base_color = mat.albedo_color * albedo_sample;

        // 2. Alpha mask: glTF spec says mask = discard below cutoff.
        //    For MASK foliage textures (trees, grasses, petals), the
        //    transparent texels often hold stale white RGB; bilinear
        //    filtering and mipmaps then bleed that white into leaf-
        //    edge fragments that still pass the alpha cutoff. Damp
        //    only the low-alpha AND low-chroma fragments (the
        //    whitish silhouette pixels); saturated leaf/grass colour
        //    and antialiased canopy interiors pass through untouched.
        let alpha_mode = mat.alpha.x;
        if (alpha_mode == 1.0) {
          if (base_color.a < mat.alpha.y) { discard; }
          let edge_lo = mat.alpha.y;
          let edge_hi = min(mat.alpha.y + 0.4, 1.0);
          let alpha_damp = smoothstep(edge_lo, edge_hi, albedo_sample.a);
          let mx2 = max(max(base_color.r, base_color.g), base_color.b);
          let mn2 = min(min(base_color.r, base_color.g), base_color.b);
          let sat2 = (mx2 - mn2) / max(mx2, 0.0001);
          let sat_damp = smoothstep(0.10, 0.30, sat2);
          let damp = max(alpha_damp, sat_damp);
          base_color = vec4<f32>(base_color.rgb * damp, base_color.a);
        }

        // 2b. Universal anti-whitebleed for OPAQUE foliage assets
        //     (grass / tip strips on white backgrounds): when the
        //     texel reads as near-white AND extremely desaturated,
        //     damp toward black. Tight thresholds (lum > 0.85,
        //     sat < 0.10) so legitimately bright surfaces (Boden
        //     floor, painted walls, paper, sand) barely trigger
        //     while bilinear/mip drift into a texture's white
        //     border gets visibly suppressed.
        {
          let mx = max(max(base_color.r, base_color.g), base_color.b);
          let mn = min(min(base_color.r, base_color.g), base_color.b);
          let sat = (mx - mn) / max(mx, 0.0001);
          // Gate on mx <= 1.0 — HDR-range albedo (e.g. the Boden
          // floor's intentional (2.2, 2.2, 2.3) factor) passes
          // through untouched; only LDR-bright + low-chroma fragments
          // (the actual whitebleed signature) get damped.
          let bleed = saturate((mx - 0.85) * 6.0) * saturate(0.10 - sat) * 10.0 * step(mx, 1.0);
          base_color = vec4<f32>(base_color.rgb * saturate(1.0 - bleed), base_color.a);
        }

        // 3. Metallic + roughness: factor × MR.b / MR.g per glTF.
        let mr_sample = textureSample(mr_tex, samp, apply_uv_xform(in.uv));
        let metallic  = mat.factors.x * mr_sample.b;
        let roughness = mat.factors.y * mr_sample.g;

        // 4. Normal: sample tangent-space xy, build TBN from vertex
        //    tangent when available, otherwise screen-space.
        let N0 = normalize(in.normal);
        let n_sample = textureSample(normal_tex, samp, apply_uv_xform(in.uv)).xy * 2.0 - vec2<f32>(1.0);
        let N = surface_normal(N0, in.tangent, in.world, in.uv, n_sample, mat.factors.z);

        // 5. View direction.
        let V = normalize(scene.camera_pos.xyz - in.world);

        // Compute the primary directional caster's shadow factor
        // once, up-front. Reused for both direct light attenuation
        // (below) and ambient/IBL attenuation (further down) so
        // shadow regions are visibly darker against the lit ones —
        // ACES tonemap otherwise collapses the dynamic range.
        var primary_shadow = 1.0;
        if (scene.counts.x > 0.0) {
          let primary_L = normalize(-scene.dir_lights[0].dir_intensity.xyz);
          primary_shadow = shadow_factor(in.world, N, primary_L);
        }

        // 6. Direct lighting: sum every active light's contribution.
        var Lo = vec3<f32>(0.0);

        let dir_count = u32(scene.counts.x);
        for (var i: u32 = 0u; i < dir_count; i = i + 1u) {
          let dl = scene.dir_lights[i];
          let L = normalize(-dl.dir_intensity.xyz);
          var radiance = dl.color.rgb * dl.dir_intensity.w;
          // Apply shadow attenuation to the primary shadow caster
          // (always index 0 — the renderer reorders the dir-light
          // list so the shadow caster lands first).
          if (i == 0u) {
            radiance = radiance * primary_shadow;
          }
          Lo = Lo + pbr_direct(N, V, L, base_color.rgb, metallic, roughness, radiance);
        }

        let point_count = u32(scene.counts.y);
        for (var i: u32 = 0u; i < point_count; i = i + 1u) {
          let pl = scene.point_lights[i];
          let to_light = pl.pos_range.xyz - in.world;
          let dist = length(to_light);
          if (dist < EPSILON) { continue; }
          let L = to_light / dist;
          let att = distance_attenuation(dist, pl.pos_range.w);
          let radiance = pl.color_intensity.rgb * pl.color_intensity.w * att;
          Lo = Lo + pbr_direct(N, V, L, base_color.rgb, metallic, roughness, radiance);
        }

        let spot_count = u32(scene.counts.z);
        for (var i: u32 = 0u; i < spot_count; i = i + 1u) {
          let sl = scene.spot_lights[i];
          let to_light = sl.pos_range.xyz - in.world;
          let dist = length(to_light);
          if (dist < EPSILON) { continue; }
          let L = to_light / dist;
          let dist_att = distance_attenuation(dist, sl.pos_range.w);
          let cone_att = spot_attenuation(L, sl.dir_inner.xyz, sl.dir_inner.w, sl.outer_cos.x);
          let radiance = sl.color_intensity.rgb * sl.color_intensity.w * dist_att * cone_att;
          Lo = Lo + pbr_direct(N, V, L, base_color.rgb, metallic, roughness, radiance);
        }

        // 7. Image-based lighting. Sample the 3-band environment
        //    (top / horizon / bottom) by surface normal for diffuse
        //    irradiance and by the reflection vector for specular.
        //    Roughness blurs the spec sample toward the diffuse one
        //    (cheap fake of prefiltered-cubemap miplevels). Metals
        //    pick up the env colour directly via Fresnel-weighted
        //    F0 mixing; dielectrics scatter it diffusely. Adds the
        //    legacy flat ambient on top so callers that don't set
        //    an environment still get a base fill.
        let ao_sample = textureSample(occlusion_tex, samp, apply_uv_xform(in.uv)).r;
        let ao = mix(1.0, ao_sample, mat.factors.w);
        let env_n = env_sample(N);
        let R     = reflect(-V, N);
        let env_r = mix(env_sample(R), env_n, roughness * roughness);
        let F0    = mix(vec3<f32>(0.04), base_color.rgb, metallic);
        let NdotV_amb = max(dot(N, V), 0.0);
        let F_amb = F0 + (vec3<f32>(1.0) - F0) * pow(1.0 - NdotV_amb, 5.0);
        // MASK foliage shouldn't grazing-reflect like a polished
        // dielectric — at edge-on view (NoV → 0) Schlick would
        // drive kS toward 1.0 and the env_r horizon colour would
        // wash silhouette pixels. Clamp kS back to F0 so leaves /
        // grass blades stay matte at silhouettes.
        var kS = F_amb;
        if (alpha_mode == 1.0) { kS = F0; }
        let kD    = (vec3<f32>(1.0) - kS) * (1.0 - metallic);
        let diffuse_ibl  = kD * base_color.rgb * env_n;
        let specular_ibl = kS * env_r;
        // Shadow attenuates direct lighting only — Blinc / Filament
        // standard. Indirect ambient + IBL stays at full intensity.
        let ambient_term = (diffuse_ibl + specular_ibl) * ao
                         + scene.ambient.rgb * base_color.rgb * ao;

        // 8. Emissive. Added on top — never tonemapped against
        //    indirectly, but the final ACES pass still touches it.
        let emissive_sample = textureSample(emissive_tex, samp, apply_uv_xform(in.uv)).rgb;
        let emissive = mat.emissive_color.rgb * emissive_sample;

        // 9. Tonemap + alpha output.
        let hdr = Lo + ambient_term + emissive;
        let ldr = tonemap_aces(hdr);
        return vec4<f32>(ldr, base_color.a);
      }

      // Single-target PBR entry — used when the renderer is built
      // without `normalFormat`. Pure delegation to `pbr_compute`.
      @fragment
      fn fs_main(in: VsOut) -> @location(0) vec4<f32> {
        return pbr_compute(in);
      }

      // -- Toon / cel-shaded fragment entry. -------------------
      //
      // Same VS, same scene + draw + material bind groups, same
      // textures — only the lighting model changes. Quantises the
      // dominant directional light's `dot(N, L)` into `mat.toon.x`
      // bands, layers an optional Fresnel rim with `mat.toon.yz`,
      // floors the shadow side at `mat.toon.w`, and skips ACES so
      // the output stays in the saturated stylised palette artists
      // author against. Albedo / emissive texture sampling + alpha-
      // mode handling carry over from the PBR path so one Material
      // can drive either pipeline by flipping `shadingModel`.
      // Toon lighting computation — same compute / entry split as
      // `pbr_compute` so the MRT entry can share it.
      fn toon_compute(in: VsOut) -> vec4<f32> {
        let albedo_sample = textureSample(albedo_tex, samp, apply_uv_xform(in.uv));
        var base_color = mat.albedo_color * albedo_sample;
        let alpha_mode = mat.alpha.x;
        if (alpha_mode == 1.0) {
          if (base_color.a < mat.alpha.y) { discard; }
        }

        let N = normalize(in.normal);
        let V = normalize(scene.camera_pos.xyz - in.world);

        let bands         = max(mat.toon.x, 2.0);
        let rim_strength  = mat.toon.y;
        let rim_width     = max(mat.toon.z, 1.0);
        let ambient_floor = clamp(mat.toon.w, 0.0, 1.0);

        // Quantise the strongest-contributing directional light's
        // diffuse term. Multi-dir scenes blend by max() — the
        // dominant key wins each band, which matches how stylised
        // illustrations get drawn (one primary light decides the
        // shadow shape; fills modulate the colour but not the band).
        //
        // The band itself stays in [0, 1] — `intensity` is an HDR
        // PBR concept and would crush every step past 1 without a
        // tonemap, which is exactly the stylised look we are NOT
        // reaching for. Tone comes from the key vs ambient tint
        // blend below.
        var step_max = 0.0;
        var key_tint = vec3<f32>(1.0);
        let dir_count = u32(scene.counts.x);
        for (var i: u32 = 0u; i < dir_count; i = i + 1u) {
          let dl = scene.dir_lights[i];
          let L = normalize(-dl.dir_intensity.xyz);
          let n_dot_l = max(dot(N, L), 0.0);
          // floor(n*bands + 0.5)/bands gives crisp steps at 0,
          // 1/b, 2/b…1. The +0.5/bands phase shift puts the
          // brightest band at the dot(N,L)=1 surface so the key
          // light isn't dimmed.
          let stepped = floor(n_dot_l * bands + 0.5) / bands;
          if (stepped > step_max) {
            step_max = stepped;
            key_tint = dl.color.rgb;
          }
        }
        // Cool shadow / warm key two-tone tint — the canonical
        // cel-shading move. Build the two endpoint colours, then
        // mix between them by the quantised lit amount. This keeps
        // shadows readable as the material colour (just cooler +
        // dimmer) instead of compound-darkening to near-black.
        let shadow_tint  = scene.ambient.rgb;
        let shadow_color = base_color.rgb * shadow_tint;
        let lit_color    = base_color.rgb * key_tint;
        let lit_amount   = max(step_max, ambient_floor);
        var lit = mix(shadow_color, lit_color, lit_amount);

        // Rim light: Fresnel-driven silhouette highlight, saturated
        // blend toward white. At grazing view angles dot(N, V) -> 0
        // and fresnel -> 1.0; the previous additive form
        // (lit = lit + vec3(rim)) added 0.25 white across every
        // upward-facing surface (every grass blade has hardcoded
        // +Y normals), pushing lit out of LDR range and tripping
        // Bloom's threshold so the foreground washed to a glowing
        // cream-yellow haze at low camera pitch. Using mix toward
        // white clamps the contribution at white and never crosses
        // the bloom threshold accidentally.
        if (rim_strength > 0.0) {
          let fresnel = 1.0 - max(0.0, dot(N, V));
          let rim_factor = pow(fresnel, rim_width) * rim_strength;
          lit = mix(lit, vec3<f32>(1.0), rim_factor);
        }

        // Emissive carries through so authored self-glow elements
        // still read (lanterns, signage, magic).
        let toon_emissive_sample = textureSample(emissive_tex, samp, apply_uv_xform(in.uv)).rgb;
        lit = lit + mat.emissive_color.rgb * toon_emissive_sample;

        return vec4<f32>(lit, base_color.a);
      }

      // Single-target toon entry.
      @fragment
      fn fs_toon_main(in: VsOut) -> @location(0) vec4<f32> {
        return toon_compute(in);
      }

      // -- MRT entries. --------------------------------------------
      //
      // Used when the renderer is built with `normalFormat` set.
      // The PostFX chain's OutlinePass (and any other depth+normal
      // edge-aware effect) samples `@location(1)`. World-space
      // normals are packed `N * 0.5 + 0.5` into rgba8unorm so the
      // clear value (0.5, 0.5, 1.0) reads as the +Z unit normal —
      // anything the scene doesn't write registers as 'no edge'
      // under depth+normal Sobel.
      struct FsOutMrt {
        @location(0) color:  vec4<f32>,
        @location(1) normal: vec4<f32>,
      }
      @fragment
      fn fs_main_mrt(in: VsOut) -> FsOutMrt {
        let color = pbr_compute(in);
        let n = normalize(in.normal) * 0.5 + 0.5;
        return FsOutMrt(color, vec4<f32>(n, 1.0));
      }
      @fragment
      fn fs_toon_main_mrt(in: VsOut) -> FsOutMrt {
        let color = toon_compute(in);
        let n = normalize(in.normal) * 0.5 + 0.5;
        return FsOutMrt(color, vec4<f32>(n, 1.0));
      }
    "
  }

  // Instanced PBR shader. Same fragment shader + struct surface as
  // PBR_WGSL_; the difference is the vertex stage reads `model` +
  // `normal_mat` out of a storage-buffer array indexed by
  // `@builtin(instance_index)` instead of the per-draw uniform.
  // One drawIndexed call covers an arbitrary number of instances,
  // and the storage buffer can be the direct output of a compute
  // Minimal skinned PBR shader. v1 — diffuse + one directional
  // light + ambient. Reads vertex skinning attributes JOINTS_0
  // (vec4<u32>) and WEIGHTS_0 (vec4<f32>) from VBO slots 1 + 2,
  // samples joint_matrices from a storage buffer at @group(3)
  // @binding(0), and folds the weighted joint transforms into
  // pos / normal before the standard model matrix applies.
  // Feature parity with the full PBR_WGSL_ (IBL, shadows, alpha
  // modes, anti-whitebleed) lands in a follow-up.
  static SKINNED_PBR_WGSL_ {
    return "
      struct DirLight {
        dir_intensity: vec4<f32>,
        color:         vec4<f32>,
      };
      struct PointLight {
        pos_range:       vec4<f32>,
        color_intensity: vec4<f32>,
      };
      struct SpotLight {
        pos_range:       vec4<f32>,
        color_intensity: vec4<f32>,
        dir_inner:       vec4<f32>,
        outer_cos:       vec4<f32>,
      };
      // Layout-compatible with PBR_WGSL_'s SceneUniforms — the
      // skinned vertex stage only reads vp + ambient, but binding
      // the same `_sceneBindGroup` requires identical struct shape.
      struct SceneUniforms {
        vp:            mat4x4<f32>,
        camera_pos:    vec4<f32>,
        ambient:       vec4<f32>,
        counts:        vec4<f32>,
        light_vp:      mat4x4<f32>,
        shadow_params: vec4<f32>,
        wind:          vec4<f32>,
        env_top:       vec4<f32>,
        env_horizon:   vec4<f32>,
        env_bottom:    vec4<f32>,
        dir_lights:    array<DirLight,   4>,
        point_lights:  array<PointLight, 8>,
        spot_lights:   array<SpotLight,  4>,
      };
      struct DrawUniforms {
        model:      mat4x4<f32>,
        normal_mat: mat4x4<f32>,
      };
      struct MaterialUniforms {
        albedo_color:   vec4<f32>,
        emissive_color: vec4<f32>,
        factors:        vec4<f32>,
        alpha:          vec4<f32>,
        // Toon-shading slot (read by the cel-shaded pipeline; this
        // shader binds the struct identically but ignores it).
        toon:           vec4<f32>,
        // KHR_texture_transform — xy = scale, zw = offset.
        uv_xform:       vec4<f32>,
        // KHR_texture_transform rotation — x = cos, y = sin.
        uv_rot:         vec4<f32>,
      };

      @group(0) @binding(0) var<uniform>            scene: SceneUniforms;
      // Scene BGL also exposes shadow_tex + shadow_samp at
      // bindings 1 + 2 (see PBR_WGSL_); the skinned v1 doesn't
      // sample them but the BGL still requires shader declarations.
      @group(0) @binding(1) var                     shadow_tex:  texture_depth_2d;
      @group(0) @binding(2) var                     shadow_samp: sampler_comparison;
      @group(1) @binding(0) var<uniform>            draw_u: DrawUniforms;
      // Material layout matches `_materialBgl`: UBO at 0, five
      // textures at 1..5 (albedo, MR, normal, occlusion, emissive),
      // shared sampler at 6. v1 reads only albedo + sampler.
      @group(2) @binding(0) var<uniform>            mat:        MaterialUniforms;
      @group(2) @binding(1) var                     albedo_tex: texture_2d<f32>;
      @group(2) @binding(2) var                     mr_tex:     texture_2d<f32>;
      @group(2) @binding(3) var                     normal_tex: texture_2d<f32>;
      @group(2) @binding(4) var                     occlusion_tex: texture_2d<f32>;
      @group(2) @binding(5) var                     emissive_tex:  texture_2d<f32>;
      @group(2) @binding(6) var                     samp:       sampler;

      // KHR_texture_transform helper (see PBR shader for spec).
      fn apply_uv_xform(uv: vec2<f32>) -> vec2<f32> {
        let scaled  = uv * mat.uv_xform.xy;
        let c       = mat.uv_rot.x;
        let s       = mat.uv_rot.y;
        let rotated = vec2<f32>(
          scaled.x * c - scaled.y * s,
          scaled.x * s + scaled.y * c
        );
        return rotated + mat.uv_xform.zw;
      }
      @group(3) @binding(0) var<storage, read>      joint_matrices: array<mat4x4<f32>>;

      struct VsIn {
        @location(0) pos:     vec3<f32>,
        @location(1) normal:  vec3<f32>,
        @location(2) uv:      vec2<f32>,
        @location(3) tangent: vec4<f32>,
        @location(4) joints:  vec4<u32>,
        @location(5) weights: vec4<f32>,
      };
      struct VsOut {
        @builtin(position) clip:  vec4<f32>,
        @location(0)       world: vec3<f32>,
        @location(1)       normal:vec3<f32>,
        @location(2)       uv:    vec2<f32>,
      };

      @vertex
      fn vs_main(in: VsIn) -> VsOut {
        var o: VsOut;
        // Weighted blend of the 4 joint matrices. glTF guarantees
        // joints.* < jointCount and the four weights sum to ~1.
        let M_skin = in.weights.x * joint_matrices[in.joints.x]
                   + in.weights.y * joint_matrices[in.joints.y]
                   + in.weights.z * joint_matrices[in.joints.z]
                   + in.weights.w * joint_matrices[in.joints.w];
        // Skin first, then apply the mesh's root model matrix.
        let skinned_pos    = (M_skin * vec4<f32>(in.pos, 1.0)).xyz;
        let skinned_normal = normalize((M_skin * vec4<f32>(in.normal, 0.0)).xyz);
        let world_pos      = draw_u.model * vec4<f32>(skinned_pos, 1.0);
        let world_norm     = (draw_u.normal_mat * vec4<f32>(skinned_normal, 0.0)).xyz;
        o.clip   = scene.vp * world_pos;
        o.world  = world_pos.xyz;
        o.normal = world_norm;
        o.uv     = in.uv;
        return o;
      }

      // Skinned PBR lighting — Lambert + ambient + emissive. Same
      // compute-fn + thin-entry split as the static + instanced
      // shaders so the MRT entries can share the lit value.
      fn skinned_pbr_compute(in: VsOut) -> vec4<f32> {
        let albedo_sample = textureSample(albedo_tex, samp, apply_uv_xform(in.uv));
        let base_color    = mat.albedo_color * albedo_sample;
        let N = normalize(in.normal);

        // Sum every active directional + point light, Lambert
        // term per source. shadow / IBL / spot still deferred to
        // the full PBR pipeline (v1).
        var Lo = vec3<f32>(0.0);
        let dir_count = u32(scene.counts.x);
        for (var i: u32 = 0u; i < dir_count; i = i + 1u) {
          let dl = scene.dir_lights[i];
          let L  = normalize(-dl.dir_intensity.xyz);
          let radiance = dl.color.rgb * dl.dir_intensity.w;
          Lo = Lo + base_color.rgb * max(dot(N, L), 0.0) * radiance;
        }
        let point_count = u32(scene.counts.y);
        for (var i: u32 = 0u; i < point_count; i = i + 1u) {
          let pl = scene.point_lights[i];
          let to_light = pl.pos_range.xyz - in.world;
          let dist = length(to_light);
          if (dist < 0.0001) { continue; }
          let L = to_light / dist;
          let att = 1.0 / max(dist * dist, 0.0001);
          let radiance = pl.color_intensity.rgb * pl.color_intensity.w * att;
          Lo = Lo + base_color.rgb * max(dot(N, L), 0.0) * radiance;
        }

        // scene.ambient.rgb is already pre-multiplied by intensity
        // by commitScene_; .w is padding.
        let ambient  = scene.ambient.rgb * base_color.rgb;
        let emissive = mat.emissive_color.rgb;
        return vec4<f32>(Lo + ambient + emissive, base_color.a);
      }

      // Skinned toon / cel-shaded lighting — same band-quantised
      // dominant-directional + two-tone tint + Fresnel rim math
      // as the static and instanced toon variants. Operates over
      // the same VsOut shape so skinned characters can mix freely
      // with cel-shaded static + instanced meshes.
      fn skinned_toon_compute(in: VsOut) -> vec4<f32> {
        let albedo_sample = textureSample(albedo_tex, samp, apply_uv_xform(in.uv));
        var base_color = mat.albedo_color * albedo_sample;
        let alpha_mode = mat.alpha.x;
        if (alpha_mode == 1.0) {
          if (base_color.a < mat.alpha.y) { discard; }
        }

        let N = normalize(in.normal);
        let V = normalize(scene.camera_pos.xyz - in.world);

        let bands         = max(mat.toon.x, 2.0);
        let rim_strength  = mat.toon.y;
        let rim_width     = max(mat.toon.z, 1.0);
        let ambient_floor = clamp(mat.toon.w, 0.0, 1.0);

        var step_max = 0.0;
        var key_tint = vec3<f32>(1.0);
        let dir_count = u32(scene.counts.x);
        for (var i: u32 = 0u; i < dir_count; i = i + 1u) {
          let dl = scene.dir_lights[i];
          let L = normalize(-dl.dir_intensity.xyz);
          let n_dot_l = max(dot(N, L), 0.0);
          let stepped = floor(n_dot_l * bands + 0.5) / bands;
          if (stepped > step_max) {
            step_max = stepped;
            key_tint = dl.color.rgb;
          }
        }

        let shadow_tint  = scene.ambient.rgb;
        let shadow_color = base_color.rgb * shadow_tint;
        let lit_color    = base_color.rgb * key_tint;
        let lit_amount   = max(step_max, ambient_floor);
        var lit = mix(shadow_color, lit_color, lit_amount);

        if (rim_strength > 0.0) {
          let fresnel = 1.0 - max(0.0, dot(N, V));
          let rim = pow(fresnel, rim_width) * rim_strength;
          lit = lit + vec3<f32>(rim);
        }

        let toon_emissive_sample = textureSample(emissive_tex, samp, apply_uv_xform(in.uv)).rgb;
        lit = lit + mat.emissive_color.rgb * toon_emissive_sample;

        return vec4<f32>(lit, base_color.a);
      }

      // Single-target entries — picked when the renderer is built
      // without `normalFormat`.
      @fragment
      fn fs_main(in: VsOut) -> @location(0) vec4<f32> {
        return skinned_pbr_compute(in);
      }
      @fragment
      fn fs_toon_main(in: VsOut) -> @location(0) vec4<f32> {
        return skinned_toon_compute(in);
      }

      // MRT entries — picked when the renderer is built with
      // `normalFormat`. Packed world-space normal in @location(1).
      struct FsOutMrt {
        @location(0) color:  vec4<f32>,
        @location(1) normal: vec4<f32>,
      }
      @fragment
      fn fs_main_mrt(in: VsOut) -> FsOutMrt {
        let color = skinned_pbr_compute(in);
        let n = normalize(in.normal) * 0.5 + 0.5;
        return FsOutMrt(color, vec4<f32>(n, 1.0));
      }
      @fragment
      fn fs_toon_main_mrt(in: VsOut) -> FsOutMrt {
        let color = skinned_toon_compute(in);
        let n = normalize(in.normal) * 0.5 + 0.5;
        return FsOutMrt(color, vec4<f32>(n, 1.0));
      }
    "
  }

  // Skinned + instanced TOON shader. Combines skinning (joint
  // palette blend via JOINTS_0/WEIGHTS_0 vertex attrs + group(3)
  // skin BGL) with per-instance model+normal_mat+tint pulled
  // from a storage buffer indexed by @builtin(instance_index).
  // Single drawSkinnedInstanced call dispatches N posed instances
  // at distinct world transforms + emissive tints, replacing N
  // drawSkinned calls. Only the toon-MRT variant exists today
  // (butterflies cel-shade against the rest of nature-garden via
  // a normalFormat-equipped Renderer3D); PBR + non-MRT entries
  // can be added later.
  static SKINNED_INSTANCED_TOON_WGSL_ {
    return "
      struct DirLight {
        dir_intensity: vec4<f32>,
        color:         vec4<f32>,
      };
      struct PointLight {
        pos_range:       vec4<f32>,
        color_intensity: vec4<f32>,
      };
      struct SpotLight {
        pos_range:       vec4<f32>,
        color_intensity: vec4<f32>,
        dir_inner:       vec4<f32>,
        outer_cos:       vec4<f32>,
      };
      struct SceneUniforms {
        vp:            mat4x4<f32>,
        camera_pos:    vec4<f32>,
        ambient:       vec4<f32>,
        counts:        vec4<f32>,
        light_vp:      mat4x4<f32>,
        shadow_params: vec4<f32>,
        wind:          vec4<f32>,
        env_top:       vec4<f32>,
        env_horizon:   vec4<f32>,
        env_bottom:    vec4<f32>,
        dir_lights:    array<DirLight,   4>,
        point_lights:  array<PointLight, 8>,
        spot_lights:   array<SpotLight,  4>,
      };
      // Per-instance data: model + normal_mat + tint. 144 bytes
      // per instance, packed as 9 vec4s into the storage buffer.
      // The vertex shader indexes into `instances[inst]` for each
      // dispatched primitive instance.
      struct SkinnedInstance {
        model:      mat4x4<f32>,
        normal_mat: mat4x4<f32>,
        tint:       vec4<f32>,
      };
      struct MaterialUniforms {
        albedo_color:   vec4<f32>,
        emissive_color: vec4<f32>,
        factors:        vec4<f32>,
        alpha:          vec4<f32>,
        toon:           vec4<f32>,
        uv_xform:       vec4<f32>,
        uv_rot:         vec4<f32>,
      };

      @group(0) @binding(0) var<uniform>            scene: SceneUniforms;
      @group(0) @binding(1) var                     shadow_tex:  texture_depth_2d;
      @group(0) @binding(2) var                     shadow_samp: sampler_comparison;
      @group(1) @binding(0) var<storage, read>      instances: array<SkinnedInstance>;
      @group(2) @binding(0) var<uniform>            mat:        MaterialUniforms;
      @group(2) @binding(1) var                     albedo_tex: texture_2d<f32>;
      @group(2) @binding(2) var                     mr_tex:     texture_2d<f32>;
      @group(2) @binding(3) var                     normal_tex: texture_2d<f32>;
      @group(2) @binding(4) var                     occlusion_tex: texture_2d<f32>;
      @group(2) @binding(5) var                     emissive_tex:  texture_2d<f32>;
      @group(2) @binding(6) var                     samp:       sampler;
      @group(3) @binding(0) var<storage, read>      joint_matrices: array<mat4x4<f32>>;

      fn apply_uv_xform(uv: vec2<f32>) -> vec2<f32> {
        let scaled  = uv * mat.uv_xform.xy;
        let c       = mat.uv_rot.x;
        let s       = mat.uv_rot.y;
        let rotated = vec2<f32>(
          scaled.x * c - scaled.y * s,
          scaled.x * s + scaled.y * c
        );
        return rotated + mat.uv_xform.zw;
      }

      struct VsIn {
        @location(0) pos:     vec3<f32>,
        @location(1) normal:  vec3<f32>,
        @location(2) uv:      vec2<f32>,
        @location(3) tangent: vec4<f32>,
        @location(4) joints:  vec4<u32>,
        @location(5) weights: vec4<f32>,
      };
      struct VsOut {
        @builtin(position)                   clip:   vec4<f32>,
        @location(0)                         world:  vec3<f32>,
        @location(1)                         normal: vec3<f32>,
        @location(2)                         uv:     vec2<f32>,
        // `flat` interpolation — tint is constant per instance,
        // no need to interpolate across triangle vertices.
        // Location 4 (not 3) avoids any chance of clashing with
        // VsIn's @location(3) tangent slot.
        @location(4) @interpolate(flat)      tint:   vec4<f32>,
      };

      @vertex
      fn vs_main(in: VsIn, @builtin(instance_index) inst: u32) -> VsOut {
        let M_skin = in.weights.x * joint_matrices[in.joints.x]
                   + in.weights.y * joint_matrices[in.joints.y]
                   + in.weights.z * joint_matrices[in.joints.z]
                   + in.weights.w * joint_matrices[in.joints.w];
        let inst_model      = instances[inst].model;
        let inst_normal_mat = instances[inst].normal_mat;
        let skinned_pos     = (M_skin * vec4<f32>(in.pos, 1.0)).xyz;
        let skinned_normal  = normalize((M_skin * vec4<f32>(in.normal, 0.0)).xyz);
        let world_pos       = inst_model * vec4<f32>(skinned_pos, 1.0);
        let world_norm      = (inst_normal_mat * vec4<f32>(skinned_normal, 0.0)).xyz;
        var o: VsOut;
        o.clip   = scene.vp * world_pos;
        o.world  = world_pos.xyz;
        o.normal = world_norm;
        o.uv     = in.uv;
        o.tint   = instances[inst].tint;
        return o;
      }

      // Toon lighting — same shape as skinned_toon_compute but
      // the emissive multiplier comes from the per-instance tint
      // (passed via VsOut.tint) instead of the shared material's
      // emissive_color uniform. Keeps every other knob (bands,
      // rim, ambient_floor) sourced from the material.
      fn skinned_inst_toon_compute(in: VsOut) -> vec4<f32> {
        let albedo_sample = textureSample(albedo_tex, samp, apply_uv_xform(in.uv));
        var base_color = mat.albedo_color * albedo_sample;
        let alpha_mode = mat.alpha.x;
        if (alpha_mode == 1.0) {
          if (base_color.a < mat.alpha.y) { discard; }
        }
        let N = normalize(in.normal);
        let V = normalize(scene.camera_pos.xyz - in.world);
        let bands         = max(mat.toon.x, 2.0);
        let rim_strength  = mat.toon.y;
        let rim_width     = max(mat.toon.z, 1.0);
        let ambient_floor = clamp(mat.toon.w, 0.0, 1.0);
        var step_max = 0.0;
        var key_tint = vec3<f32>(1.0);
        let dir_count = u32(scene.counts.x);
        for (var i: u32 = 0u; i < dir_count; i = i + 1u) {
          let dl = scene.dir_lights[i];
          let L = normalize(-dl.dir_intensity.xyz);
          let n_dot_l = max(dot(N, L), 0.0);
          let stepped = floor(n_dot_l * bands + 0.5) / bands;
          if (stepped > step_max) {
            step_max = stepped;
            key_tint = dl.color.rgb;
          }
        }
        let shadow_tint  = scene.ambient.rgb;
        let shadow_color = base_color.rgb * shadow_tint;
        let lit_color    = base_color.rgb * key_tint;
        let lit_amount   = max(step_max, ambient_floor);
        var lit = mix(shadow_color, lit_color, lit_amount);
        if (rim_strength > 0.0) {
          let fresnel = 1.0 - max(0.0, dot(N, V));
          let rim = pow(fresnel, rim_width) * rim_strength;
          lit = lit + vec3<f32>(rim);
        }
        // Per-instance tint provides the COLOUR of the emissive
        // glow; the texture provides the SHAPE (which pixels
        // glow + how strongly). Using channel-wise multiply
        // here makes every butterfly inherit the texture's hue —
        // for a wing texture that's predominantly blue, no tint
        // would survive past the texture's blue bias. Collapsing
        // the sample to its luma + multiplying by tint gives
        // each instance its own glow colour while keeping the
        // detail pattern of the wing texture.
        let emiss = textureSample(emissive_tex, samp, apply_uv_xform(in.uv)).rgb;
        let emiss_mask = max(max(emiss.r, emiss.g), emiss.b);
        // Tint should DOMINATE the wing colour, not just nudge
        // the texture's native blue. Knock the base-colour
        // contribution down to a 25% shadow + emiss_mask
        // wrapper, and rebuild the surface from the tint
        // directly. Each instance's tint provides the hue;
        // the mask provides the detail pattern.
        lit = lit * 0.25 + in.tint.rgb * emiss_mask * 1.8;
        return vec4<f32>(lit, base_color.a);
      }

      struct FsOutMrt {
        @location(0) color:  vec4<f32>,
        @location(1) normal: vec4<f32>,
      }
      @fragment
      fn fs_toon_main_mrt(in: VsOut) -> FsOutMrt {
        let color = skinned_inst_toon_compute(in);
        let n = normalize(in.normal) * 0.5 + 0.5;
        return FsOutMrt(color, vec4<f32>(n, 1.0));
      }
      @fragment
      fn fs_toon_main(in: VsOut) -> @location(0) vec4<f32> {
        return skinned_inst_toon_compute(in);
      }
    "
  }

  static INSTANCED_PBR_WGSL_ {
    return "
      struct SceneUniforms {
        vp:            mat4x4<f32>,
        camera_pos:    vec4<f32>,
        ambient:       vec4<f32>,
        counts:        vec4<f32>,
        light_vp:      mat4x4<f32>,
        shadow_params: vec4<f32>,
        // xy = wind direction (unit, xz plane), z = time, w = strength
        wind:          vec4<f32>,
        // 3-band environment for image-based lighting. Sampled by
        // surface direction (N for diffuse, reflect(-V, N) for
        // specular). Solid-colour bands lerped by `direction.y`
        // give curved metals a credible reflection gradient with
        // no cubemap binding.
        env_top:       vec4<f32>,
        env_horizon:   vec4<f32>,
        env_bottom:    vec4<f32>,
        dir_lights:    array<DirLight,   4>,
        point_lights:  array<PointLight, 8>,
        spot_lights:   array<SpotLight,  4>,
      };
      struct DrawUniforms {
        model:      mat4x4<f32>,
        normal_mat: mat4x4<f32>,
      };
      struct MaterialUniforms {
        albedo_color:   vec4<f32>,
        emissive_color: vec4<f32>,
        factors:        vec4<f32>,
        alpha:          vec4<f32>,
        // Toon-shading slot (read by the cel-shaded pipeline; this
        // shader binds the struct identically but ignores it).
        toon:           vec4<f32>,
        // KHR_texture_transform — xy = scale, zw = offset.
        uv_xform:       vec4<f32>,
        // KHR_texture_transform rotation — x = cos, y = sin.
        uv_rot:         vec4<f32>,
      };

      @group(0) @binding(0) var<uniform> scene: SceneUniforms;
      @group(0) @binding(1) var shadow_tex:  texture_depth_2d;
      @group(0) @binding(2) var shadow_samp: sampler_comparison;
      // Per-instance transforms. One entry per drawn instance.
      @group(1) @binding(0) var<storage, read> instances: array<DrawUniforms>;
      @group(2) @binding(0) var<uniform> mat: MaterialUniforms;
      @group(2) @binding(1) var albedo_tex:    texture_2d<f32>;
      @group(2) @binding(2) var mr_tex:        texture_2d<f32>;
      @group(2) @binding(3) var normal_tex:    texture_2d<f32>;
      @group(2) @binding(4) var occlusion_tex: texture_2d<f32>;
      @group(2) @binding(5) var emissive_tex:  texture_2d<f32>;
      @group(2) @binding(6) var samp:          sampler;

      // KHR_texture_transform helper. Applied to every uv read by
      // `textureSample` so a single tile can be repeated and rotated
      // across a mesh without re-authoring UVs. Identity when
      // `Material.uvScale = (1, 1)`, `uvOffset = (0, 0)`,
      // `uvRotation = 0` (the Material default).
      fn apply_uv_xform(uv: vec2<f32>) -> vec2<f32> {
        let scaled  = uv * mat.uv_xform.xy;
        let c       = mat.uv_rot.x;
        let s       = mat.uv_rot.y;
        let rotated = vec2<f32>(
          scaled.x * c - scaled.y * s,
          scaled.x * s + scaled.y * c
        );
        return rotated + mat.uv_xform.zw;
      }

      fn shadow_factor(world_pos: vec3<f32>, N: vec3<f32>, L: vec3<f32>) -> f32 {
        if (scene.counts.w < 0.5) { return 1.0; }
        let pos_light = scene.light_vp * vec4<f32>(world_pos, 1.0);
        let proj      = pos_light.xyz / pos_light.w;
        let uv = vec2<f32>(proj.x * 0.5 + 0.5, -proj.y * 0.5 + 0.5);
        if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0 || proj.z > 1.0) {
          return 1.0;
        }
        let cos_theta = clamp(dot(N, L), 0.0, 1.0);
        let bias      = scene.shadow_params.x * (1.0 - cos_theta) + 0.0005;
        let depth     = proj.z - bias;
        let r = scene.shadow_params.y;
        var acc = 0.0;
        acc = acc + textureSampleCompare(shadow_tex, shadow_samp, uv + vec2<f32>(-r, -r), depth);
        acc = acc + textureSampleCompare(shadow_tex, shadow_samp, uv + vec2<f32>( 0.0, -r), depth);
        acc = acc + textureSampleCompare(shadow_tex, shadow_samp, uv + vec2<f32>( r, -r), depth);
        acc = acc + textureSampleCompare(shadow_tex, shadow_samp, uv + vec2<f32>(-r,  0.0), depth);
        acc = acc + textureSampleCompare(shadow_tex, shadow_samp, uv, depth);
        acc = acc + textureSampleCompare(shadow_tex, shadow_samp, uv + vec2<f32>( r,  0.0), depth);
        acc = acc + textureSampleCompare(shadow_tex, shadow_samp, uv + vec2<f32>(-r,  r), depth);
        acc = acc + textureSampleCompare(shadow_tex, shadow_samp, uv + vec2<f32>( 0.0,  r), depth);
        acc = acc + textureSampleCompare(shadow_tex, shadow_samp, uv + vec2<f32>( r,  r), depth);
        return acc / 9.0;
      }

      struct VsIn  {
        @location(0) pos:     vec3<f32>,
        @location(1) normal:  vec3<f32>,
        @location(2) uv:      vec2<f32>,
        @location(3) tangent: vec4<f32>,
      };
      struct VsOut {
        @builtin(position) clip:    vec4<f32>,
        @location(0)       world:   vec3<f32>,
        @location(1)       normal:  vec3<f32>,
        @location(2)       uv:      vec2<f32>,
        @location(3)       tangent: vec4<f32>,
      };

      // Same coherent-wave sway as the PBR pipeline above.
      fn apply_sway(local_pos: vec3<f32>, anchor_world: vec3<f32>, sway: f32) -> vec3<f32> {
        if (sway <= 0.0) { return local_pos; }
        let on_axis = anchor_world.x * scene.wind.x + anchor_world.z * scene.wind.y;
        let phase = on_axis * 0.20 - scene.wind.z * 1.6;
        let osc   = sin(phase);
        let bend  = local_pos.y * sway * scene.wind.w * osc * 0.30;
        return vec3<f32>(
          local_pos.x + scene.wind.x * bend,
          local_pos.y,
          local_pos.z + scene.wind.y * bend
        );
      }

      @vertex
      fn vs_main(in: VsIn, @builtin(instance_index) inst_idx: u32) -> VsOut {
        let draw_u = instances[inst_idx];
        var o: VsOut;
        let anchor = vec3<f32>(draw_u.model[3].x, draw_u.model[3].y, draw_u.model[3].z);
        let local_swayed = apply_sway(in.pos, anchor, mat.alpha.w);
        let world_pos  = draw_u.model * vec4<f32>(local_swayed, 1.0);
        let world_norm = (draw_u.normal_mat * vec4<f32>(in.normal, 0.0)).xyz;
        let world_tan  = (draw_u.model * vec4<f32>(in.tangent.xyz, 0.0)).xyz;
        o.clip    = scene.vp * world_pos;
        o.world   = world_pos.xyz;
        o.normal  = world_norm;
        o.uv      = in.uv;
        o.tangent = vec4<f32>(world_tan, in.tangent.w);
        return o;
      }

      // Vertex-tangent TBN with screen-space-derivative fallback —
      // same shape as the non-instanced PBR shader.
      fn surface_normal(
        N0: vec3<f32>,
        in_tangent: vec4<f32>,
        world_pos: vec3<f32>,
        uv: vec2<f32>,
        sampled_xy: vec2<f32>,
        scale: f32,
      ) -> vec3<f32> {
        let xy = sampled_xy * scale;
        let z = sqrt(saturate(1.0 - dot(xy, xy)));
        let n_t = vec3<f32>(xy, z);
        let tlen2 = dot(in_tangent.xyz, in_tangent.xyz);
        if (tlen2 > 0.0001) {
          let T = normalize(in_tangent.xyz - N0 * dot(N0, in_tangent.xyz));
          let B = cross(N0, T) * in_tangent.w;
          let tbn = mat3x3<f32>(T, B, N0);
          return normalize(tbn * n_t);
        }
        return perturb_normal(N0, world_pos, uv, sampled_xy, scale);
      }

      // 3-band environment sampler: lerps bottom→horizon→top by
      // `direction.y`. Returns linear-RGB irradiance scaled by
      // each band's .w intensity. When all three bands are zero
      // (no setEnvironment call), returns zero so the legacy flat
      // ambient still drives the look.
      fn env_sample(dir: vec3<f32>) -> vec3<f32> {
        let y = clamp(dir.y, -1.0, 1.0);
        var c: vec3<f32>;
        if (y >= 0.0) {
          c = mix(scene.env_horizon.rgb, scene.env_top.rgb, y);
        } else {
          c = mix(scene.env_horizon.rgb, scene.env_bottom.rgb, -y);
        }
        return c;
      }

      // Instanced PBR lighting computation — same split as the
      // non-instanced shader so the MRT entry below shares the
      // exact lit value and just adds a packed-normal write.
      fn instanced_pbr_compute(in: VsOut) -> vec4<f32> {
        let albedo_sample = textureSample(albedo_tex, samp, apply_uv_xform(in.uv));
        var base_color = mat.albedo_color * albedo_sample;
        let alpha_mode = mat.alpha.x;
        // Foliage edge damp: see non-instanced PBR for rationale.
        // Damp only the low-alpha AND low-chroma fragments — the
        // whitish silhouette pixels — so saturated leaf/grass
        // colour and antialiased canopy interiors stay untouched.
        if (alpha_mode == 1.0) {
          if (base_color.a < mat.alpha.y) { discard; }
          let edge_lo = mat.alpha.y;
          let edge_hi = min(mat.alpha.y + 0.4, 1.0);
          let alpha_damp = smoothstep(edge_lo, edge_hi, albedo_sample.a);
          let mx2 = max(max(base_color.r, base_color.g), base_color.b);
          let mn2 = min(min(base_color.r, base_color.g), base_color.b);
          let sat2 = (mx2 - mn2) / max(mx2, 0.0001);
          let sat_damp = smoothstep(0.10, 0.30, sat2);
          let damp = max(alpha_damp, sat_damp);
          base_color = vec4<f32>(base_color.rgb * damp, base_color.a);
        }

        // Universal anti-whitebleed (see non-instanced PBR).
        {
          let mx = max(max(base_color.r, base_color.g), base_color.b);
          let mn = min(min(base_color.r, base_color.g), base_color.b);
          let sat = (mx - mn) / max(mx, 0.0001);
          // Gate on mx <= 1.0 — HDR-range albedo (e.g. the Boden
          // floor's intentional (2.2, 2.2, 2.3) factor) passes
          // through untouched; only LDR-bright + low-chroma fragments
          // (the actual whitebleed signature) get damped.
          let bleed = saturate((mx - 0.85) * 6.0) * saturate(0.10 - sat) * 10.0 * step(mx, 1.0);
          base_color = vec4<f32>(base_color.rgb * saturate(1.0 - bleed), base_color.a);
        }

        let mr_sample = textureSample(mr_tex, samp, apply_uv_xform(in.uv));
        let metallic  = mat.factors.x * mr_sample.b;
        let roughness = mat.factors.y * mr_sample.g;

        let N0 = normalize(in.normal);
        let n_sample = textureSample(normal_tex, samp, apply_uv_xform(in.uv)).xy * 2.0 - vec2<f32>(1.0);
        let N = surface_normal(N0, in.tangent, in.world, in.uv, n_sample, mat.factors.z);

        let V = normalize(scene.camera_pos.xyz - in.world);
        var Lo = vec3<f32>(0.0);

        let dir_count = u32(scene.counts.x);
        for (var i: u32 = 0u; i < dir_count; i = i + 1u) {
          let dl = scene.dir_lights[i];
          let L = normalize(-dl.dir_intensity.xyz);
          var radiance = dl.color.rgb * dl.dir_intensity.w;
          if (i == 0u) { radiance = radiance * shadow_factor(in.world, N, L); }
          Lo = Lo + pbr_direct(N, V, L, base_color.rgb, metallic, roughness, radiance);
        }

        let point_count = u32(scene.counts.y);
        for (var i: u32 = 0u; i < point_count; i = i + 1u) {
          let pl = scene.point_lights[i];
          let to_light = pl.pos_range.xyz - in.world;
          let dist = length(to_light);
          if (dist < EPSILON) { continue; }
          let L = to_light / dist;
          let att = distance_attenuation(dist, pl.pos_range.w);
          let radiance = pl.color_intensity.rgb * pl.color_intensity.w * att;
          Lo = Lo + pbr_direct(N, V, L, base_color.rgb, metallic, roughness, radiance);
        }

        let spot_count = u32(scene.counts.z);
        for (var i: u32 = 0u; i < spot_count; i = i + 1u) {
          let sl = scene.spot_lights[i];
          let to_light = sl.pos_range.xyz - in.world;
          let dist = length(to_light);
          if (dist < EPSILON) { continue; }
          let L = to_light / dist;
          let dist_att = distance_attenuation(dist, sl.pos_range.w);
          let cone_att = spot_attenuation(L, sl.dir_inner.xyz, sl.dir_inner.w, sl.outer_cos.x);
          let radiance = sl.color_intensity.rgb * sl.color_intensity.w * dist_att * cone_att;
          Lo = Lo + pbr_direct(N, V, L, base_color.rgb, metallic, roughness, radiance);
        }

        let ao_sample = textureSample(occlusion_tex, samp, apply_uv_xform(in.uv)).r;
        let ao = mix(1.0, ao_sample, mat.factors.w);
        // IBL — same shape as the non-instanced PBR shader.
        let env_n = env_sample(N);
        let R     = reflect(-V, N);
        let env_r = mix(env_sample(R), env_n, roughness * roughness);
        let F0    = mix(vec3<f32>(0.04), base_color.rgb, metallic);
        let NdotV_amb = max(dot(N, V), 0.0);
        let F_amb = F0 + (vec3<f32>(1.0) - F0) * pow(1.0 - NdotV_amb, 5.0);
        // MASK foliage: clamp kS to F0 (see non-instanced PBR).
        var kS = F_amb;
        if (alpha_mode == 1.0) { kS = F0; }
        let kD    = (vec3<f32>(1.0) - kS) * (1.0 - metallic);
        let diffuse_ibl  = kD * base_color.rgb * env_n;
        let specular_ibl = kS * env_r;
        let ambient_term = (diffuse_ibl + specular_ibl) * ao
                         + scene.ambient.rgb * base_color.rgb * ao;
        let emissive_sample = textureSample(emissive_tex, samp, apply_uv_xform(in.uv)).rgb;
        let emissive = mat.emissive_color.rgb * emissive_sample;
        let hdr = Lo + ambient_term + emissive;
        let ldr = tonemap_aces(hdr);
        return vec4<f32>(ldr, base_color.a);
      }

      // Instanced toon / cel-shaded lighting computation — bands
      // the dominant directional light's dot(N, L), two-tone tint
      // between scene ambient and the key colour, Fresnel rim.
      // Same math as the non-instanced `toon_compute` so the
      // shading is uniform whether a mesh is drawn through `draw`
      // or `drawMeshInstanced`.
      fn instanced_toon_compute(in: VsOut) -> vec4<f32> {
        let albedo_sample = textureSample(albedo_tex, samp, apply_uv_xform(in.uv));
        var base_color = mat.albedo_color * albedo_sample;
        let alpha_mode = mat.alpha.x;
        if (alpha_mode == 1.0) {
          if (base_color.a < mat.alpha.y) { discard; }
        }

        let N = normalize(in.normal);
        let V = normalize(scene.camera_pos.xyz - in.world);

        let bands         = max(mat.toon.x, 2.0);
        let rim_strength  = mat.toon.y;
        let rim_width     = max(mat.toon.z, 1.0);
        let ambient_floor = clamp(mat.toon.w, 0.0, 1.0);

        var step_max = 0.0;
        var key_tint = vec3<f32>(1.0);
        let dir_count = u32(scene.counts.x);
        for (var i: u32 = 0u; i < dir_count; i = i + 1u) {
          let dl = scene.dir_lights[i];
          let L = normalize(-dl.dir_intensity.xyz);
          let n_dot_l = max(dot(N, L), 0.0);
          let stepped = floor(n_dot_l * bands + 0.5) / bands;
          if (stepped > step_max) {
            step_max = stepped;
            key_tint = dl.color.rgb;
          }
        }

        let shadow_tint  = scene.ambient.rgb;
        let shadow_color = base_color.rgb * shadow_tint;
        let lit_color    = base_color.rgb * key_tint;
        let lit_amount   = max(step_max, ambient_floor);
        var lit = mix(shadow_color, lit_color, lit_amount);

        if (rim_strength > 0.0) {
          let fresnel = 1.0 - max(0.0, dot(N, V));
          let rim = pow(fresnel, rim_width) * rim_strength;
          lit = lit + vec3<f32>(rim);
        }

        let toon_emissive_sample = textureSample(emissive_tex, samp, apply_uv_xform(in.uv)).rgb;
        lit = lit + mat.emissive_color.rgb * toon_emissive_sample;

        return vec4<f32>(lit, base_color.a);
      }

      // Single-target entries — used when the renderer is built
      // without `normalFormat`.
      @fragment
      fn fs_main(in: VsOut) -> @location(0) vec4<f32> {
        return instanced_pbr_compute(in);
      }
      @fragment
      fn fs_toon_main(in: VsOut) -> @location(0) vec4<f32> {
        return instanced_toon_compute(in);
      }

      // MRT entries — used when the renderer is built with
      // `normalFormat`. Packed world-space normal in @location(1).
      struct FsOutMrt {
        @location(0) color:  vec4<f32>,
        @location(1) normal: vec4<f32>,
      }
      @fragment
      fn fs_main_mrt(in: VsOut) -> FsOutMrt {
        let color = instanced_pbr_compute(in);
        let n = normalize(in.normal) * 0.5 + 0.5;
        return FsOutMrt(color, vec4<f32>(n, 1.0));
      }
      @fragment
      fn fs_toon_main_mrt(in: VsOut) -> FsOutMrt {
        let color = instanced_toon_compute(in);
        let n = normalize(in.normal) * 0.5 + 0.5;
        return FsOutMrt(color, vec4<f32>(n, 1.0));
      }
    "
  }

  // Vertex-only shader for the shadow pass. Reads `pos` out of
  // the shared mesh vertex layout (normal + uv are present but
  // unused — keeps mesh buffers reusable between main and
  // shadow passes without re-binding).
  static SHADOW_WGSL_ {
    return "
      struct ShadowUniforms {
        light_vp: mat4x4<f32>,
        model:    mat4x4<f32>,
      };
      @group(0) @binding(0) var<uniform> u: ShadowUniforms;

      // VsIn declares the full vertex layout (including tangent at
      // location 3) so the shadow pipeline can share its attribute
      // list with the PBR pipelines; only `pos` is actually read.
      struct VsIn {
        @location(0) pos:     vec3<f32>,
        @location(1) normal:  vec3<f32>,
        @location(2) uv:      vec2<f32>,
        @location(3) tangent: vec4<f32>,
      };

      @vertex
      fn vs_main(in: VsIn) -> @builtin(position) vec4<f32> {
        return u.light_vp * u.model * vec4<f32>(in.pos, 1.0);
      }
    "
  }

  // Instanced depth-only shadow shader. light_vp lives on a per-pass
  // uniform; the model matrix comes from an instance-buffer storage
  // array indexed by `@builtin(instance_index)` — the SAME instance
  // buffer the instanced PBR pipeline already populates per frame.
  // One drawIndexed call covers an arbitrary number of casters
  // (the foliage buckets), matching the main-pass shape.
  static SHADOW_INSTANCED_WGSL_ {
    return "
      struct ShadowUniforms {
        light_vp: mat4x4<f32>,
      };
      struct DrawUniforms {
        model:      mat4x4<f32>,
        normal_mat: mat4x4<f32>,
      };
      @group(0) @binding(0) var<uniform> u: ShadowUniforms;
      @group(1) @binding(0) var<storage, read> instances: array<DrawUniforms>;

      // VsIn matches the shared mesh layout (12 floats); only pos
      // is actually read.
      struct VsIn {
        @location(0) pos:     vec3<f32>,
        @location(1) normal:  vec3<f32>,
        @location(2) uv:      vec2<f32>,
        @location(3) tangent: vec4<f32>,
      };

      @vertex
      fn vs_main(in: VsIn, @builtin(instance_index) inst_idx: u32) -> @builtin(position) vec4<f32> {
        let draw_u = instances[inst_idx];
        return u.light_vp * draw_u.model * vec4<f32>(in.pos, 1.0);
      }
    "
  }

  /// Build a renderer against `device`. Pre-creates the three
  /// bind-group layouts, the PBR pipeline, the scene + draw
  /// uniform buffers, the default 1×1 fallback textures, and the
  /// default linear-repeat sampler.
  ///
  /// @param {Device} device
  /// @param {String} surfaceFormat. Colour-attachment format,
  ///   matches the surface configure (`"bgra8unorm"` etc.).
  /// @param {String} depthFormat. Depth-attachment format, matches
  ///   the depth texture used in the pass descriptor.
  /// @param {String} normalFormat. Optional secondary normal G-buffer
  ///   format (typically `"rgba8unorm"`). When supplied, ALL render
  ///   pipelines (PBR / transparent / toon, instanced PBR /
  ///   instanced toon, skinned PBR / skinned toon) bind a second
  ///   colour target and write world-space normals (packed as
  ///   `N * 0.5 + 0.5`) for edge-aware PostFX like OutlinePass.
  ///   Must match `PostFX.new(g, { "normalFormat": ... })`. The
  ///   billboard / particle pipelines stay single-target — they
  ///   write a neutral (camera-facing) normal placeholder so
  ///   nothing breaks if a billboard renders while a normal target
  ///   is bound, but they don't contribute meaningful edges to
  ///   outline detection (intentional — sprites shouldn't be
  ///   ink-outlined alongside meshes).
  construct new(device, surfaceFormat, depthFormat) {
    init_(device, surfaceFormat, depthFormat, null)
  }
  construct new(device, surfaceFormat, depthFormat, normalFormat) {
    init_(device, surfaceFormat, depthFormat, normalFormat)
  }

  init_(device, surfaceFormat, depthFormat, normalFormat) {
    _device       = device
    _normalFormat = normalFormat

    var shader = Shader.module(device, [
      Shader.prelude,
      Shader.lightTypes,
      Shader.lightAttenuation,
      Shader.pbrBrdf,
      Shader.normalMapping,
      Shader.tonemapping,
      Renderer3D.PBR_WGSL_,
    ], "renderer3d-pbr")

    _sceneBgl = device.createBindGroupLayout({
      "entries": [
        { "binding": 0, "visibility": ["vertex", "fragment"], "kind": "uniform" },
        // Shadow map is always declared in the layout so the PBR
        // pipeline doesn't need to know whether shadows are active.
        // When disabled, a 1×1 fallback depth texture binds here
        // and the shader's `counts.w == 0` early-out skips the
        // sample.
        { "binding": 1, "visibility": ["fragment"], "kind": "texture", "sampleType": "depth" },
        { "binding": 2, "visibility": ["fragment"], "kind": "sampler", "samplerType": "comparison" }
      ],
      "label": "renderer3d-scene-bgl"
    })
    _drawBgl = device.createBindGroupLayout({
      "entries": [
        { "binding": 0, "visibility": ["vertex"], "kind": "uniform" }
      ],
      "label": "renderer3d-draw-bgl"
    })
    _materialBgl = device.createBindGroupLayout({
      "entries": [
        // Material UBO is read by BOTH stages now: fragment for the
        // PBR factors, vertex for the wind-sway scalar in alpha.w.
        { "binding": 0, "visibility": ["vertex", "fragment"], "kind": "uniform" },
        { "binding": 1, "visibility": ["fragment"], "kind": "texture" },
        { "binding": 2, "visibility": ["fragment"], "kind": "texture" },
        { "binding": 3, "visibility": ["fragment"], "kind": "texture" },
        { "binding": 4, "visibility": ["fragment"], "kind": "texture" },
        { "binding": 5, "visibility": ["fragment"], "kind": "texture" },
        { "binding": 6, "visibility": ["fragment"], "kind": "sampler" }
      ],
      "label": "renderer3d-material-bgl"
    })

    _pipelineLayout = device.createPipelineLayout({
      "bindGroupLayouts": [_sceneBgl, _drawBgl, _materialBgl]
    })

    // MRT-aware entry-point + target selection. When the renderer
    // is constructed with `normalFormat != null`, the non-instanced
    // pipelines route to the `_mrt` shader entries (which write
    // packed world-space normals to `@location(1)`) and declare a
    // second colour target. Existing single-target builds are
    // unchanged.
    var mrt = _normalFormat != null
    var pbrEntry  = mrt ? "fs_main_mrt"      : "fs_main"
    var toonEntry = mrt ? "fs_toon_main_mrt" : "fs_toon_main"
    var transparentBlend = {
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
    var opaqueTargets = [{ "format": surfaceFormat }]
    var transparentTargets = [{ "format": surfaceFormat, "blend": transparentBlend }]
    if (mrt) {
      opaqueTargets.add({ "format": _normalFormat })
      transparentTargets.add({ "format": _normalFormat })
    }

    _pipeline = device.createRenderPipeline({
      "layout": _pipelineLayout,
      "vertex": {
        "module": shader, "entryPoint": "vs_main",
        "buffers": [{
          "arrayStride": Renderer3D.FLOATS_PER_VERTEX_ * 4,
          "stepMode": "vertex",
          "attributes": [
            { "shaderLocation": 0, "offset": 0,  "format": "float32x3" },
            { "shaderLocation": 1, "offset": 12, "format": "float32x3" },
            { "shaderLocation": 2, "offset": 24, "format": "float32x2" },
            { "shaderLocation": 3, "offset": 32, "format": "float32x4" }
          ]
        }]
      },
      "fragment": {
        "module": shader, "entryPoint": pbrEntry,
        "targets": opaqueTargets
      },
      "primitive":    { "topology": "triangle-list", "cullMode": "back" },
      "depthStencil": {
        "format": depthFormat, "depthWriteEnabled": true,
        // `less-equal` + a small constant + slope bias kills the
        // coplanar z-fight that glTF assets routinely hit (panels
        // exported at exactly the same depth, rotor blades inside
        // a containing ring, etc.). 1 ulp / 1× slope is the
        // gentlest knob that resolves the conflict deterministically.
        "depthCompare":         "less-equal",
        "depthBias":            2,
        "depthBiasSlopeScale":  1.0
      },
      "label": "renderer3d-pipeline"
    })

    // Transparent variant of the PBR pipeline. Shares everything
    // with `_pipeline` except: standard alpha-blend on the colour
    // target, depth write OFF (so two stacked transparent fragments
    // don't z-fight + reject each other), and depth bias dropped
    // (we don't fight coplanar transparents). Draw order: opaque
    // first, then transparent — the existing `draw(...)` flow is
    // immediate-mode so callers naturally interleave; for true
    // back-to-front correctness use sorted submission.
    _transparentPipeline = device.createRenderPipeline({
      "layout": _pipelineLayout,
      "vertex": {
        "module": shader, "entryPoint": "vs_main",
        "buffers": [{
          "arrayStride": Renderer3D.FLOATS_PER_VERTEX_ * 4,
          "stepMode": "vertex",
          "attributes": [
            { "shaderLocation": 0, "offset": 0,  "format": "float32x3" },
            { "shaderLocation": 1, "offset": 12, "format": "float32x3" },
            { "shaderLocation": 2, "offset": 24, "format": "float32x2" },
            { "shaderLocation": 3, "offset": 32, "format": "float32x4" }
          ]
        }]
      },
      "fragment": {
        "module": shader, "entryPoint": pbrEntry,
        "targets": transparentTargets
      },
      "primitive":    { "topology": "triangle-list", "cullMode": "back" },
      "depthStencil": {
        "format": depthFormat, "depthWriteEnabled": false,
        "depthCompare": "less-equal"
      },
      "label": "renderer3d-pipeline-transparent"
    })

    // Toon / cel-shaded pipeline. Same shader module + bind group
    // layout as `_pipeline`; only the fragment entry point swaps
    // to `fs_toon_main`, which reads `mat.toon` for the band count
    // / rim params / ambient floor and skips ACES so the output
    // stays in the saturated stylised palette. The `Material.shading-
    // Model` field selects between this pipeline and `_pipeline`
    // at draw time.
    _toonPipeline = device.createRenderPipeline({
      "layout": _pipelineLayout,
      "vertex": {
        "module": shader, "entryPoint": "vs_main",
        "buffers": [{
          "arrayStride": Renderer3D.FLOATS_PER_VERTEX_ * 4,
          "stepMode": "vertex",
          "attributes": [
            { "shaderLocation": 0, "offset": 0,  "format": "float32x3" },
            { "shaderLocation": 1, "offset": 12, "format": "float32x3" },
            { "shaderLocation": 2, "offset": 24, "format": "float32x2" },
            { "shaderLocation": 3, "offset": 32, "format": "float32x4" }
          ]
        }]
      },
      "fragment": {
        "module": shader, "entryPoint": toonEntry,
        "targets": opaqueTargets
      },
      "primitive":    { "topology": "triangle-list", "cullMode": "back" },
      "depthStencil": {
        "format": depthFormat, "depthWriteEnabled": true,
        "depthCompare":         "less-equal",
        "depthBias":            2,
        "depthBiasSlopeScale":  1.0
      },
      "label": "renderer3d-pipeline-toon"
    })

    // Instanced pipeline. Same scene + material binding shape; the
    // per-draw uniform is replaced by a storage buffer indexed by
    // `@builtin(instance_index)`. One drawIndexed handles the whole
    // batch — the foliage / asteroid-field / particle-mesh path.
    var instancedShader = Shader.module(device, [
      Shader.prelude,
      Shader.lightTypes,
      Shader.lightAttenuation,
      Shader.pbrBrdf,
      Shader.normalMapping,
      Shader.tonemapping,
      Renderer3D.INSTANCED_PBR_WGSL_,
    ], "renderer3d-pbr-instanced")
    _instancedBgl = device.createBindGroupLayout({
      "entries": [
        { "binding": 0, "visibility": ["vertex"], "kind": "read-only-storage" }
      ],
      "label": "renderer3d-instanced-bgl"
    })
    _instancedPipelineLayout = device.createPipelineLayout({
      "bindGroupLayouts": [_sceneBgl, _instancedBgl, _materialBgl]
    })
    _instancedPipeline = device.createRenderPipeline({
      "layout": _instancedPipelineLayout,
      "vertex": {
        "module": instancedShader, "entryPoint": "vs_main",
        "buffers": [{
          "arrayStride": Renderer3D.FLOATS_PER_VERTEX_ * 4,
          "stepMode": "vertex",
          "attributes": [
            { "shaderLocation": 0, "offset": 0,  "format": "float32x3" },
            { "shaderLocation": 1, "offset": 12, "format": "float32x3" },
            { "shaderLocation": 2, "offset": 24, "format": "float32x2" },
            { "shaderLocation": 3, "offset": 32, "format": "float32x4" }
          ]
        }]
      },
      "fragment": {
        "module": instancedShader, "entryPoint": pbrEntry,
        "targets": opaqueTargets
      },
      "primitive":    { "topology": "triangle-list", "cullMode": "back" },
      "depthStencil": {
        "format": depthFormat, "depthWriteEnabled": true,
        "depthCompare":         "less-equal",
        "depthBias":            2,
        "depthBiasSlopeScale":  1.0
      },
      "label": "renderer3d-instanced-pipeline"
    })

    // Toon variant of the instanced pipeline. Same VS (per-instance
    // model matrix + wind sway), same bind groups; differs only in
    // the fragment entry point — `instanced_toon_compute` lives in
    // the same shader module as `instanced_pbr_compute`, so we
    // can swap entries at no extra compile cost. Picked at draw
    // time when the bound `Material.shadingModel == "toon"`.
    _toonInstancedPipeline = device.createRenderPipeline({
      "layout": _instancedPipelineLayout,
      "vertex": {
        "module": instancedShader, "entryPoint": "vs_main",
        "buffers": [{
          "arrayStride": Renderer3D.FLOATS_PER_VERTEX_ * 4,
          "stepMode": "vertex",
          "attributes": [
            { "shaderLocation": 0, "offset": 0,  "format": "float32x3" },
            { "shaderLocation": 1, "offset": 12, "format": "float32x3" },
            { "shaderLocation": 2, "offset": 24, "format": "float32x2" },
            { "shaderLocation": 3, "offset": 32, "format": "float32x4" }
          ]
        }]
      },
      "fragment": {
        "module": instancedShader, "entryPoint": toonEntry,
        "targets": opaqueTargets
      },
      "primitive":    { "topology": "triangle-list", "cullMode": "back" },
      "depthStencil": {
        "format": depthFormat, "depthWriteEnabled": true,
        "depthCompare":         "less-equal",
        "depthBias":            2,
        "depthBiasSlopeScale":  1.0
      },
      "label": "renderer3d-instanced-pipeline-toon"
    })
    // Bind-group cache keyed by instance-storage-buffer id. Avoids
    // re-binding on hot redraws of the same instance set.
    _instanceBgCache = {}

    // ---- Skinned pipeline. Same scene + draw + material binding
    // shape as the static PBR pipeline, plus a fourth bind group
    // at @group(3) carrying the per-skin joint-matrix palette
    // SSBO. Two extra vertex buffer slots (joints u32x4 + weights
    // f32x4) feed the vertex shader's M_skin fold.
    _skinBgl = device.createBindGroupLayout({
      "entries": [
        { "binding": 0, "visibility": ["vertex"], "kind": "read-only-storage" }
      ],
      "label": "renderer3d-skin-bgl"
    })
    _skinnedPipelineLayout = device.createPipelineLayout({
      "bindGroupLayouts": [_sceneBgl, _drawBgl, _materialBgl, _skinBgl]
    })
    var skinnedShader = device.createShaderModule({
      "code":  Renderer3D.SKINNED_PBR_WGSL_,
      "label": "renderer3d-skinned-shader"
    })
    _skinnedPipeline = device.createRenderPipeline({
      "layout": _skinnedPipelineLayout,
      "vertex": {
        "module": skinnedShader, "entryPoint": "vs_main",
        "buffers": [
          {
            "arrayStride": Renderer3D.FLOATS_PER_VERTEX_ * 4,
            "stepMode": "vertex",
            "attributes": [
              { "shaderLocation": 0, "offset": 0,  "format": "float32x3" },
              { "shaderLocation": 1, "offset": 12, "format": "float32x3" },
              { "shaderLocation": 2, "offset": 24, "format": "float32x2" },
              { "shaderLocation": 3, "offset": 32, "format": "float32x4" }
            ]
          },
          {
            // Joints VBO — one vec4<u32> per vertex, 16 B stride.
            "arrayStride": 16,
            "stepMode": "vertex",
            "attributes": [
              { "shaderLocation": 4, "offset": 0, "format": "uint32x4" }
            ]
          },
          {
            // Weights VBO — one vec4<f32> per vertex, 16 B stride.
            "arrayStride": 16,
            "stepMode": "vertex",
            "attributes": [
              { "shaderLocation": 5, "offset": 0, "format": "float32x4" }
            ]
          }
        ]
      },
      "fragment": {
        "module": skinnedShader, "entryPoint": pbrEntry,
        "targets": opaqueTargets
      },
      "primitive":    { "topology": "triangle-list", "cullMode": "back" },
      "depthStencil": {
        "format": depthFormat, "depthWriteEnabled": true,
        "depthCompare":         "less-equal",
        "depthBias":            2,
        "depthBiasSlopeScale":  1.0
      },
      "label": "renderer3d-skinned-pipeline"
    })

    // Toon variant of the skinned pipeline. Shares the joint
    // matrix palette + skinning VS; differs only in the fragment
    // entry. Picked by `drawSkinned` when
    // `Material.shadingModel == "toon"`. Same shader module, no
    // extra compile cost.
    _toonSkinnedPipeline = device.createRenderPipeline({
      "layout": _skinnedPipelineLayout,
      "vertex": {
        "module": skinnedShader, "entryPoint": "vs_main",
        "buffers": [
          {
            "arrayStride": Renderer3D.FLOATS_PER_VERTEX_ * 4,
            "stepMode": "vertex",
            "attributes": [
              { "shaderLocation": 0, "offset": 0,  "format": "float32x3" },
              { "shaderLocation": 1, "offset": 12, "format": "float32x3" },
              { "shaderLocation": 2, "offset": 24, "format": "float32x2" },
              { "shaderLocation": 3, "offset": 32, "format": "float32x4" }
            ]
          },
          {
            "arrayStride": 16,
            "stepMode": "vertex",
            "attributes": [
              { "shaderLocation": 4, "offset": 0, "format": "uint32x4" }
            ]
          },
          {
            "arrayStride": 16,
            "stepMode": "vertex",
            "attributes": [
              { "shaderLocation": 5, "offset": 0, "format": "float32x4" }
            ]
          }
        ]
      },
      "fragment": {
        "module": skinnedShader, "entryPoint": toonEntry,
        "targets": opaqueTargets
      },
      "primitive":    { "topology": "triangle-list", "cullMode": "back" },
      "depthStencil": {
        "format": depthFormat, "depthWriteEnabled": true,
        "depthCompare":         "less-equal",
        "depthBias":            2,
        "depthBiasSlopeScale":  1.0
      },
      "label": "renderer3d-skinned-pipeline-toon"
    })

    // ---- Skinned + instanced TOON pipeline. Same skinning VS
    // shape as the non-instanced skinned path (vertex VBO +
    // joints VBO + weights VBO + joint-palette SSBO at @group(3))
    // PLUS a per-instance SSBO at @group(1) holding model +
    // normal_mat + tint per instance. One drawSkinnedInstanced
    // dispatches N posed instances at distinct transforms +
    // emissive tints, collapsing what would otherwise be N
    // drawSkinned calls into one.
    _skinnedInstancedPipelineLayout = device.createPipelineLayout({
      "bindGroupLayouts": [_sceneBgl, _instancedBgl, _materialBgl, _skinBgl]
    })
    var skinnedInstancedShader = device.createShaderModule({
      "code":  Renderer3D.SKINNED_INSTANCED_TOON_WGSL_,
      "label": "renderer3d-skinned-instanced-shader"
    })
    _toonSkinnedInstancedPipeline = device.createRenderPipeline({
      "layout": _skinnedInstancedPipelineLayout,
      "vertex": {
        "module": skinnedInstancedShader, "entryPoint": "vs_main",
        "buffers": [
          {
            "arrayStride": Renderer3D.FLOATS_PER_VERTEX_ * 4,
            "stepMode": "vertex",
            "attributes": [
              { "shaderLocation": 0, "offset": 0,  "format": "float32x3" },
              { "shaderLocation": 1, "offset": 12, "format": "float32x3" },
              { "shaderLocation": 2, "offset": 24, "format": "float32x2" },
              { "shaderLocation": 3, "offset": 32, "format": "float32x4" }
            ]
          },
          {
            "arrayStride": 16,
            "stepMode": "vertex",
            "attributes": [
              { "shaderLocation": 4, "offset": 0, "format": "uint32x4" }
            ]
          },
          {
            "arrayStride": 16,
            "stepMode": "vertex",
            "attributes": [
              { "shaderLocation": 5, "offset": 0, "format": "float32x4" }
            ]
          }
        ]
      },
      "fragment": {
        "module": skinnedInstancedShader,
        "entryPoint": _normalFormat == null ? "fs_toon_main" : "fs_toon_main_mrt",
        "targets": opaqueTargets
      },
      "primitive":    { "topology": "triangle-list", "cullMode": "back" },
      "depthStencil": {
        "format": depthFormat, "depthWriteEnabled": true,
        "depthCompare":         "less-equal",
        "depthBias":            2,
        "depthBiasSlopeScale":  1.0
      },
      "label": "renderer3d-skinned-instanced-pipeline-toon"
    })

    // ---- Billboard pipeline. Spherical camera-facing quads for
    // 3D particles / decals / icons. Reads a slim Scene struct
    // (vp + camera_pos) at group 0, the per-instance storage
    // buffer at group 1, and a (texture, sampler) pair at group
    // 2. No vertex / index buffer — VS pulls quad corners from
    // `@builtin(vertex_index)`.
    var billboardShader = device.createShaderModule({
      "code":  Renderer3D.BILLBOARD_WGSL_,
      "label": "renderer3d-billboard"
    })
    _billboardSceneBgl = device.createBindGroupLayout({
      "entries": [
        { "binding": 0, "visibility": ["vertex"], "kind": "uniform" }
      ],
      "label": "renderer3d-billboard-scene-bgl"
    })
    _billboardInstanceBgl = _instancedBgl   // reuse: same single-storage-binding layout
    _billboardMaterialBgl = device.createBindGroupLayout({
      "entries": [
        { "binding": 0, "visibility": ["fragment"], "kind": "texture" },
        { "binding": 1, "visibility": ["fragment"], "kind": "sampler" }
      ],
      "label": "renderer3d-billboard-material-bgl"
    })
    _billboardPipelineLayout = device.createPipelineLayout({
      "bindGroupLayouts": [_billboardSceneBgl, _billboardInstanceBgl, _billboardMaterialBgl]
    })
    var billboardEntry = mrt ? "fs_main_mrt" : "fs_main"
    // Color target uses PREMULTIPLIED alpha so the same pipeline
    // serves both translucent sprites (rain, smoke, fog) AND
    // HDR-emissive ones (fireflies, sparks, halos). With the FS
    // outputting RGB already premultiplied by alpha + mask, the
    // formula `src.rgb + dst.rgb * (1 - src.a)` produces:
    //   - translucent overlay for alpha-fading sprites — src.a
    //     attenuates dst correctly, no "donut against bright
    //     bloom" failure mode of standard alpha blend
    //   - bright LDR-clamped centre for emissive sprites — bloom
    //     extracts the saturated bright pixels and casts the
    //     visible glow halo through the postFX chain
    // Pure additive (One, One) would correctly handle emissives
    // but turn rain drops into glowing white streaks; this single
    // pipeline keeps both classes of sprite looking right.
    var billboardTargets = [{ "format": surfaceFormat, "blend": "premultiplied" }]
    if (mrt) {
      // Normal target stays alpha-blended against the underlying
      // surface normal so the disc's soft falloff edges don't
      // appear as normal discontinuities to OutlinePass-style
      // edge detection.
      billboardTargets.add({ "format": _normalFormat, "blend": "alpha" })
    }
    _billboardPipeline = device.createRenderPipeline({
      "layout": _billboardPipelineLayout,
      "vertex": {
        "module": billboardShader, "entryPoint": "vs_main",
        "buffers": []
      },
      "fragment": {
        "module": billboardShader, "entryPoint": billboardEntry,
        "targets": billboardTargets
      },
      "primitive":    { "topology": "triangle-list", "cullMode": "none" },
      "depthStencil": {
        "format": depthFormat,
        "depthWriteEnabled": false,
        "depthCompare": "less"
      },
      "label": "renderer3d-billboard-pipeline"
    })
    // Slim scene UBO carrying just vp + camera_pos for the
    // billboard VS. Repopulated in `beginFrame_` alongside the
    // main scene uniform write.
    _billboardSceneUbo = device.createBuffer({
      "size":  80,   // 16 floats vp + 4 floats camera_pos = 20 f32 = 80 bytes
      "usage": ["uniform", "copy-dst"],
      "label": "renderer3d-billboard-scene-ubo"
    })
    _billboardSceneBg = device.createBindGroup({
      "layout":  _billboardSceneBgl,
      "entries": [{ "binding": 0, "buffer": _billboardSceneUbo }]
    })
    _billboardSampler = device.createSampler({
      "magFilter":   "linear",
      "minFilter":   "linear",
      "addressModeU":"clamp-to-edge",
      "addressModeV":"clamp-to-edge",
      "label":       "renderer3d-billboard-sampler"
    })
    _billboardMatBgCache = {}     // texture id → BindGroup

    _sceneUbo = device.createBuffer({
      "size":  Renderer3D.SCENE_UBO_BYTES_,
      "usage": ["uniform", "copy-dst"],
      "label": "renderer3d-scene-ubo"
    })

    // Fallback shadow map: a 1×1 depth texture bound when shadows
    // aren't enabled. The shader gates sampling on `counts.w`, so
    // the fallback's (undefined) contents never reach output.
    _shadowFallbackTex = device.createTexture({
      "width":  1,
      "height": 1,
      "format": "depth32float",
      "usage":  ["render-attachment", "texture-binding"],
      "label":  "renderer3d-shadow-fallback"
    })
    _shadowFallbackView = _shadowFallbackTex.createView()

    // Comparison sampler — `textureSampleCompare` returns a 0..1
    // hardware-PCF result. `less` matches the depth pass's
    // `depthCompare: less` so a stored depth less than the test
    // depth means "the fragment is behind something" → 0
    // (shadowed); 1 means "lit".
    _shadowCmpSampler = device.createSampler({
      "magFilter":   "linear",
      "minFilter":   "linear",
      "addressModeU":"clamp-to-edge",
      "addressModeV":"clamp-to-edge",
      "compare":     "less",
      "label":       "renderer3d-shadow-cmp-sampler"
    })

    _shadowView = _shadowFallbackView      // active view, switched by enableShadows
    _sceneBindGroup = device.createBindGroup({
      "layout":  _sceneBgl,
      "entries": [
        { "binding": 0, "buffer":  _sceneUbo, "size": Renderer3D.SCENE_UBO_BYTES_ },
        { "binding": 1, "view":    _shadowView },
        { "binding": 2, "sampler": _shadowCmpSampler }
      ]
    })

    // Per-draw UBO pool. `queue.write_buffer` doesn't sync with
    // intervening command-buffer records — all writes to a single
    // UBO collapse to the LAST write when the encoder finally
    // submits. So we can't share one draw UBO across multiple
    // draws in a frame; each draw needs its own.
    //
    // Pre-allocated to `Renderer3D.INITIAL_DRAW_POOL_` slots at
    // construction so per-frame growth is zero in the common case
    // (scenes that draw ≤ that many individual meshes). Empirically,
    // doing `createBuffer + createBindGroup` repeatedly during
    // `draw()` — across ~20+ slots in one frame — interacts badly
    // with the GC and corrupts the shared `_drawUboFloats` list
    // (Buffer.writeFloats fails with index-0 not-a-number on the
    // next upload). Pre-allocating moves all allocator pressure to
    // setup time, eliminating the hot-path corruption window.
    // `reserveDrawSlot_` still grows the pool past the pre-allocated
    // cap if needed; the per-slot cost just isn't paid every frame.
    _drawUboPool       = []   // List of Buffer
    _drawBindGroupPool = []   // List of BindGroup, indexed in lockstep with _drawUboPool
    _drawIndex         = 0
    var poolPrefill = Renderer3D.INITIAL_DRAW_POOL_
    var pi = 0
    while (pi < poolPrefill) {
      var ubo = device.createBuffer({
        "size":  Renderer3D.DRAW_UBO_BYTES_,
        "usage": ["uniform", "copy-dst"],
        "label": "renderer3d-draw-ubo"
      })
      var bg = device.createBindGroup({
        "layout":  _drawBgl,
        "entries": [{ "binding": 0, "buffer": ubo, "size": Renderer3D.DRAW_UBO_BYTES_ }]
      })
      _drawUboPool.add(ubo)
      _drawBindGroupPool.add(bg)
      pi = pi + 1
    }

    // Default sampler — linear filtering, repeat addressing.
    // Materials with point-filtered textures (pixel art) build
    // their own sampler and bind it via the BindGroup cache.
    _sampler = device.createSampler({
      "magFilter":    "linear",
      "minFilter":    "linear",
      "mipmapFilter": "linear",
      "addressModeU": "repeat",
      "addressModeV": "repeat",
      "label":        "renderer3d-default-sampler"
    })

    // 1×1 default fallback textures. Sampling these is effectively
    // free (single-texel L1 hits) so the shader can always sample
    // every slot without branching on "is this texture set".
    _whiteTex  = Renderer3D.makeFallback_(device, 255, 255, 255, 255)  // albedo / mr / occlusion / emissive
    _normalTex = Renderer3D.makeFallback_(device, 128, 128, 255, 255)  // tangent-space up: (0.5, 0.5, 1)

    // Per-Material BindGroup cache. Keyed by Material identity
    // (not revision_), so a long-lived material reuses its bind
    // group across frames; revision_ bumps trigger a rebuild on
    // the next draw without growing the cache.
    _materialCache = {}     // Material → { "bg": BindGroup, "ubo": Buffer, "rev": Num }

    _matUboFloats = []      // packing scratchpad — reused per draw
    // `_drawUboFloats` lives on the hottest path in the renderer
    // (one rebuild + writeFloats per `draw()` / `drawSkinned()` /
    // `drawMeshInstancedIndirect()`). A plain Wren List triggers
    // `writeFloats`'s slow per-element walker, and a GC cycle
    // mid-frame can corrupt index 0 so the validator rejects the
    // upload ("every element must be a number (index 0)"). A
    // `Float32Array(32)` takes the typed-array memcpy fast path
    // and bypasses the validator entirely.
    _drawUboFloats = Float32Array.new(32)
    _sceneUboFloats = []    // packing scratchpad — reused per beginFrame

    _pass    = null
    _ambient = Vec3.new(0.0, 0.0, 0.0)
    _ambientIntensity = 0.0
    // 3-band IBL environment. All zero by default so demos that
    // never call `setEnvironment` keep the legacy ambient-only
    // look; populated triples make curved metals reflect the
    // gradient and dielectrics pick up sky tint diffusely.
    _envTop     = Vec3.new(0, 0, 0)
    _envHorizon = Vec3.new(0, 0, 0)
    _envBottom  = Vec3.new(0, 0, 0)
    // Shadow-driven AO strength on the indirect (ambient + IBL)
    // term. 0 disables (legacy behaviour — every scene built
    // before this knob landed); 1 fully attenuates indirect by
    // the primary shadow factor (drone-showcase look). Most
    // open-world scenes want 0; studio-lit single-object demos
    // benefit from ≥0.7.
    _shadowAOStrength = 0.0
    _dirLights   = []   // each: { dir, color, intensity, castsShadows }
    _pointLights = []   // each: { pos, color, intensity, range }
    _spotLights  = []   // each: { pos, dir, color, intensity, range, innerCos, outerCos }

    // Shadow infrastructure — null until `enableShadows(...)` is
    // called. The PBR shader's `counts.w == 0` early-out leaves
    // the fallback bind path completely passive when shadows
    // aren't configured.
    _shadowsEnabled    = false
    _shadowSize        = 0
    _shadowExtent      = 50.0
    _shadowNear        = 0.1
    _shadowFar         = 100.0
    _shadowBias        = 0.005
    _shadowPcfRadius   = 0.0015
    _windDirX     = 1.0
    _windDirZ     = 0.0
    _windStrength = 0.0
    _windTime     = 0.0
    _shadowDepthFormat = "depth32float"
    _shadowTex         = null
    _shadowPipeline    = null
    _shadowBgl         = null
    _shadowLayout      = null
    _shadowUboPool     = []   // List of per-draw UBO (light_vp + model)
    _shadowBgPool      = []   // List of BindGroup keyed off pool index
    _shadowDrawIndex   = 0
    _shadowPass        = null
    _shadowLightVP     = null  // Mat4 computed by beginShadowPass
    _shadowUboFloats   = []
  }

  // 1×1 RGBA texture filled with (r, g, b, a) bytes. Used for the
  // default fallback textures the renderer binds when a Material
  // leaves a slot null.
  static makeFallback_(device, r, g, b, a) {
    var tex = device.createTexture({
      "width":  1,
      "height": 1,
      "format": "rgba8unorm",
      "usage":  ["texture-binding", "copy-dst"],
      "label":  "renderer3d-fallback-tex"
    })
    var bytes = ByteArray.new(4)
    bytes[0] = r
    bytes[1] = g
    bytes[2] = b
    bytes[3] = a
    device.writeTexture(tex, bytes, {
      "width":       1,
      "height":      1,
      "bytesPerRow": 4
    })
    return tex
  }

  /// Begin a frame. Stores the active pass + camera, flushes the
  /// light arrays from the previous frame, binds the pipeline +
  /// scene group. Add lights after `beginFrame` and before the
  /// first `draw` (the renderer commits the scene uniform on
  /// the first draw call, so the order is `beginFrame → addLight*
  /// → setAmbient → draw* → endFrame`).
  ///
  /// @param {RenderPass} pass
  /// @param {Camera3D} camera
  beginFrame(pass, camera) {
    _pass = pass
    _vp   = camera.viewProj
    _cameraPos = camera.eye

    _ambient = Vec3.new(0.0, 0.0, 0.0)
    _ambientIntensity = 0.0
    // IBL env is NOT reset — it's a scene-wide property a caller
    // configures once at setup, distinct from per-frame lights.
    _dirLights.clear()
    _pointLights.clear()
    _spotLights.clear()
    _sceneCommitted = false

    // Each frame's draws re-fill the pool from slot 0; the
    // ring grows when the scene needs more slots than the
    // previous frame, never shrinks.
    _drawIndex = 0

    pass.setPipeline(_pipeline)
    pass.setBindGroup(0, _sceneBindGroup)
  }

  /// Set the scene-wide ambient term. Replaces previous calls
  /// within the frame; the renderer commits the value into the
  /// scene uniform on the first draw.
  ///
  /// @param {Vec3} color. Linear-space RGB.
  /// @param {Num} intensity. Scalar multiplier.
  /// Set the wind direction (xz unit) + strength. Any material
  /// with a non-zero `sway` factor bends in this direction during
  /// vertex shading; high vertices in mesh-local space bend more.
  /// Call once per frame before `addDirectional` / `draw`.
  /// @param {Num} dirX. xz-plane component, normalised below.
  /// @param {Num} dirZ.
  /// @param {Num} strength. 0 = still; ~1.0 = visibly windy.
  setWind(dirX, dirZ, strength) {
    var len = (dirX * dirX + dirZ * dirZ).sqrt
    if (len > 0.0001) {
      _windDirX = dirX / len
      _windDirZ = dirZ / len
    }
    _windStrength = strength
  }

  /// Advance the wind animation clock — should be incremented by
  /// `g.dt` every frame so sway oscillates over time.
  /// @param {Num} time. Seconds since simulation start.
  setWindTime(time) { _windTime = time }

  setAmbient(color, intensity) {
    _ambient = color
    _ambientIntensity = intensity
  }

  /// Configure a 3-band IBL environment. The PBR shader samples
  /// the surface normal against this gradient for diffuse
  /// irradiance and the reflection vector for specular — curved
  /// metals catch a sky-toned reflection without needing a real
  /// cubemap binding. All three colours pass as linear-space
  /// `Vec3`; pass `Vec3.zero` for each to disable IBL (the
  /// flat-ambient path is unaffected).
  ///
  /// Cheap, no-allocation, no-pipeline-change. Real prefiltered-
  /// cubemap IBL is a future upgrade.
  ///
  /// @param {Vec3} topColor      Zenith (above-horizon) colour.
  /// @param {Vec3} horizonColor  Horizon colour, dominant at
  ///                             surface tangent directions.
  /// @param {Vec3} bottomColor   Nadir (below-horizon / ground)
  ///                             colour.
  setEnvironment(topColor, horizonColor, bottomColor) {
    _envTop     = topColor
    _envHorizon = horizonColor
    _envBottom  = bottomColor
  }

  /// Tune how strongly IBL contributes vs. analytic lighting.
  /// Diffuse strength multiplies the env-as-irradiance term that
  /// dielectrics scatter; specular strength multiplies the
  /// reflection-vector sample that metals pick up. Metals stay
  /// "shiny" rather than "tinted" by keeping specular strength
  /// low — the gradient bands don't carry the bright micro-detail
  /// a real cubemap would, so a strong env_r reads as a uniform
  /// flat reflection instead of a sharp environment.
  ///
  /// Defaults: diffuse 1.0, specular 0.25 — gives dielectrics a
  /// full env-tinted fill, metals just a hint of reflection.
  ///
  /// @param {Num} diffuseStrength    Multiplier on the diffuse
  ///                                 IBL term. Typical 0.6..1.2.
  /// @param {Num} specularStrength   Multiplier on the specular
  ///                                 IBL term. Typical 0.1..0.4 for
  ///                                 stylised look; 1.0 for
  ///                                 physically-matched mirror metals.
  setEnvironmentStrength(diffuseStrength, specularStrength) {
    _envDiffuseStrength  = diffuseStrength
    _envSpecularStrength = specularStrength
  }

  /// Strength of the shadow-driven AO multiplier on the indirect
  /// (ambient + IBL) term. `0` = off (open-world default — back-
  /// lit surfaces stay at full indirect, just like before this
  /// knob existed). `1` = full attenuation (cast shadow drops
  /// indirect to near-zero in the umbra — desirable for studio-
  /// lit single-object showcases where the shadow is a focal
  /// element). Sensible studio range 0.6..0.9.
  /// @param {Num} strength    0..1
  setShadowAOStrength(strength) {
    var s = strength
    if (s < 0) s = 0
    if (s > 1) s = 1
    _shadowAOStrength = s
  }

  /// Queue a directional light for this frame. The renderer holds
  /// the values until the scene uniform commits on the first
  /// draw call. Up to `MAX_DIR_LIGHTS_` are honoured; surplus
  /// lights are silently dropped (`overflow_` getter exposes the
  /// drop count for diagnostics).
  ///
  /// @param {Vec3} direction. World-space direction the light
  ///   travels in (sun-to-ground).
  /// @param {Vec3} color. Linear-space RGB.
  /// @param {Num} intensity. Scalar multiplier.
  addDirectional(direction, color, intensity) {
    addDirectional(direction, color, intensity, false)
  }

  /// As `addDirectional(direction, color, intensity)` but with an
  /// explicit shadow-caster flag. Shadow-casting lights are
  /// reordered to slot 0 of the per-frame dir-light list so the
  /// PBR shader's `i == 0` shadow-application path stays
  /// stable; only the *first* shadow-casting light is honoured —
  /// additional flagged lights light the scene as normal but
  /// don't cast shadows.
  ///
  /// Effective only when `Renderer3D.enableShadows({...})` was
  /// called at setup; otherwise the flag is recorded but no
  /// shadow pass runs.
  ///
  /// @param {Vec3} direction
  /// @param {Vec3} color
  /// @param {Num}  intensity
  /// @param {Bool} castsShadows
  addDirectional(direction, color, intensity, castsShadows) {
    if (_dirLights.count >= Renderer3D.MAX_DIR_LIGHTS_) {
      _overflow = (_overflow == null ? 0 : _overflow) + 1
      return
    }
    var entry = {
      "dir":          direction,
      "color":        color,
      "intensity":    intensity,
      "castsShadows": castsShadows
    }
    // Keep shadow caster at index 0 so the shader always applies
    // the shadow factor to dir_lights[0] without branching.
    if (castsShadows && _dirLights.count > 0 && !_dirLights[0]["castsShadows"]) {
      _dirLights.insert(0, entry)
    } else {
      _dirLights.add(entry)
    }
  }

  /// Allocate a shadow render target + pipeline so subsequent
  /// frames can run a depth-only pass from a directional light's
  /// viewpoint. Call once at setup; calling again replaces the
  /// existing infrastructure with fresh sizes.
  ///
  /// | Key | Type | Default | Notes |
  /// |---|---|---|---|
  /// | `size`     | `Num` | `1024` | Shadow-map resolution per side. Power-of-2 preferred. |
  /// | `extent`   | `Num` | `50`   | Half-extent of the orthographic projection (world units). |
  /// | `near`     | `Num` | `0.1`  | Near plane in light space. |
  /// | `far`      | `Num` | `100`  | Far plane in light space. |
  /// | `bias`     | `Num` | `0.005`| Slope-scaled depth bias to suppress shadow acne. |
  /// | `pcfRadius`| `Num` | `0.0015` | PCF kernel step in uv space. |
  ///
  /// @param {Map} opts
  enableShadows(opts) {
    if (opts == null) opts = {}
    _shadowSize       = Renderer3D.intOr_(opts, "size",      1024)
    _shadowExtent     = Renderer3D.numOr_(opts, "extent",    50.0)
    _shadowNear       = Renderer3D.numOr_(opts, "near",      0.1)
    _shadowFar        = Renderer3D.numOr_(opts, "far",       100.0)
    _shadowBias       = Renderer3D.numOr_(opts, "bias",      0.005)
    _shadowPcfRadius  = Renderer3D.numOr_(opts, "pcfRadius", 0.0015)

    if (_shadowTex != null) {
      _shadowTex.destroy
      _shadowTex = null
    }
    _shadowTex = _device.createTexture({
      "width":  _shadowSize,
      "height": _shadowSize,
      "format": _shadowDepthFormat,
      "usage":  ["render-attachment", "texture-binding"],
      "label":  "renderer3d-shadow-map"
    })
    _shadowView = _shadowTex.createView()

    // Re-bind the scene group so the PBR pipeline samples the real
    // shadow map instead of the 1×1 fallback.
    _sceneBindGroup = _device.createBindGroup({
      "layout":  _sceneBgl,
      "entries": [
        { "binding": 0, "buffer":  _sceneUbo, "size": Renderer3D.SCENE_UBO_BYTES_ },
        { "binding": 1, "view":    _shadowView },
        { "binding": 2, "sampler": _shadowCmpSampler }
      ]
    })

    if (_shadowPipeline == null) {
      buildShadowPipeline_()
    }
    _shadowsEnabled = true
  }

  // Build the depth-only pipeline + bind-group layout used by
  // every shadow draw. Layout takes a single per-draw UBO with
  // `light_vp` + `model`. Cull front faces to push shadow acne
  // onto the back side of every caster.
  buildShadowPipeline_() {
    _shadowBgl = _device.createBindGroupLayout({
      "entries": [
        { "binding": 0, "visibility": ["vertex"], "kind": "uniform" }
      ],
      "label": "renderer3d-shadow-bgl"
    })
    _shadowLayout = _device.createPipelineLayout({
      "bindGroupLayouts": [_shadowBgl]
    })
    var shader = _device.createShaderModule({
      "code":  Renderer3D.SHADOW_WGSL_,
      "label": "renderer3d-shadow-shader"
    })
    _shadowPipeline = _device.createRenderPipeline({
      "layout": _shadowLayout,
      "vertex": {
        "module": shader, "entryPoint": "vs_main",
        "buffers": [{
          "arrayStride": Renderer3D.FLOATS_PER_VERTEX_ * 4,
          "stepMode":    "vertex",
          "attributes": [
            { "shaderLocation": 0, "offset": 0,  "format": "float32x3" },
            { "shaderLocation": 1, "offset": 12, "format": "float32x3" },
            { "shaderLocation": 2, "offset": 24, "format": "float32x2" },
            { "shaderLocation": 3, "offset": 32, "format": "float32x4" }
          ]
        }]
      },
      // No fragment block — depth-only pass writes nothing to
      // colour attachments (there are none on the shadow pass).
      // cullMode: "back" + depthBias is the standard PCF shadow
      // setup. "front" (the old default here) writes the
      // far-side of each occluder, which on concave geometry
      // (rotor rings, panel cavities) lets the actual top-facing
      // occluder pass through and the shadow map stays cleared —
      // so shadow_factor returned 1.0 for every fragment.
      // cullMode "none" + 2 / 2.0. The buster_drone (and most authored
      // glTF bodies) leaves materials at doubleSided=false. Under
      // "back" cull, slope-bias blows up at curved silhouettes and
      // leaves a fragmented hole pattern. Under "front" cull, the
      // single-sided body sub-meshes (14 in this asset — panels,
      // generator covers, upper parts, sensor housings) have no
      // back face to draw at all and contribute zero depth, leaving
      // the same holes. "none" writes both faces; slope-scale 2.0
      // tames the silhouette case "front" was guarding against,
      // and thin double-sided rotors keep working because their
      // front face is now drawn too.
      "primitive":    { "topology": "triangle-list", "cullMode": "none" },
      "depthStencil": {
        "format": _shadowDepthFormat,
        "depthWriteEnabled":   true,
        "depthCompare":        "less",
        "depthBias":           2,
        "depthBiasSlopeScale": 2.0
      },
      "label": "renderer3d-shadow-pipeline"
    })

    // Instanced shadow pipeline — same depth-only target as the
    // non-instanced version, but the vertex stage reads `model`
    // from `_instancedBgl`'s storage buffer (the same one the
    // instanced PBR pipeline binds at @group(1)). One drawIndexed
    // per foliage bucket casts thousands of shadow casters in one
    // GPU dispatch.
    _shadowInstancedBgl0 = _device.createBindGroupLayout({
      "entries": [
        { "binding": 0, "visibility": ["vertex"], "kind": "uniform" }
      ],
      "label": "renderer3d-shadow-instanced-bgl0"
    })
    _shadowInstancedLayout = _device.createPipelineLayout({
      "bindGroupLayouts": [_shadowInstancedBgl0, _instancedBgl]
    })
    var instShader = _device.createShaderModule({
      "code":  Renderer3D.SHADOW_INSTANCED_WGSL_,
      "label": "renderer3d-shadow-instanced-shader"
    })
    _shadowInstancedPipeline = _device.createRenderPipeline({
      "layout": _shadowInstancedLayout,
      "vertex": {
        "module": instShader, "entryPoint": "vs_main",
        "buffers": [{
          "arrayStride": Renderer3D.FLOATS_PER_VERTEX_ * 4,
          "stepMode":    "vertex",
          "attributes": [
            { "shaderLocation": 0, "offset": 0,  "format": "float32x3" },
            { "shaderLocation": 1, "offset": 12, "format": "float32x3" },
            { "shaderLocation": 2, "offset": 24, "format": "float32x2" },
            { "shaderLocation": 3, "offset": 32, "format": "float32x4" }
          ]
        }]
      },
      // Front-cull would push acne off geometry's lit face for
      // closed solids — but Quaternius foliage uses single-sided
      // cards (grass blades, leaves) that get culled away
      // entirely under front-cull, leaving zero shadow casters
      // for those buckets. Disable culling so both faces register.
      "primitive":    { "topology": "triangle-list", "cullMode": "none" },
      "depthStencil": {
        "format": _shadowDepthFormat,
        "depthWriteEnabled": true,
        "depthCompare": "less"
      },
      "label": "renderer3d-shadow-instanced-pipeline"
    })
    // Single per-pass UBO holding `light_vp` — populated in
    // `beginShadowPass` and reused for every instanced shadow draw
    // in that pass.
    _shadowInstancedUbo = _device.createBuffer({
      "size":  64,                 // one mat4
      "usage": ["uniform", "copy-dst"],
      "label": "renderer3d-shadow-instanced-ubo"
    })
    _shadowInstancedBg0 = _device.createBindGroup({
      "layout":  _shadowInstancedBgl0,
      "entries": [
        { "binding": 0, "buffer": _shadowInstancedUbo, "size": 64 }
      ]
    })
    _shadowInstanceBgCache = {}
  }

  /// True after a successful `enableShadows(...)` call.
  /// @returns {Bool}
  shadowsEnabled  { _shadowsEnabled }

  /// Internal view bound into the scene bind group. Exposed for
  /// debug overlays + shadow-map preview UIs.
  /// @returns {TextureView}
  shadowMapView_  { _shadowView }

  /// The secondary normal G-buffer format the renderer was built
  /// with, or `null` when single-target. OutlinePass + other edge-
  /// aware PostFX consumers read this to verify their texture-
  /// binding format matches the renderer's MRT setup.
  /// @returns {String}
  normalFormat    { _normalFormat }

  static numOr_(opts, key, fallback) {
    if (!opts.containsKey(key)) return fallback
    return opts[key]
  }

  static intOr_(opts, key, fallback) {
    return Renderer3D.numOr_(opts, key, fallback).floor
  }

  /// Open a depth-only render pass for shadow casting. Compute
  /// the light view-projection from the configured extent +
  /// near/far, walking the orthographic frustum centred on
  /// `lightCenter` and looking along `lightDir`.
  ///
  /// Call this before `beginFrame(...)` — the shadow pass must
  /// complete before the main PBR pass reads from the shadow map.
  ///
  /// ```wren
  /// renderer.beginShadowPass(g.encoder, sunDir, Vec3.zero)
  /// for (e in shadowCasters) renderer.drawShadow(e.mesh, e.transform)
  /// renderer.endShadowPass
  /// ```
  ///
  /// @param {CommandEncoder} encoder
  /// @param {Vec3} lightDir.    Direction the light travels (sun-to-ground).
  /// @param {Vec3} lightCenter. World-space focus point the shadow box centres on.
  beginShadowPass(encoder, lightDir, lightCenter) {
    if (!_shadowsEnabled) {
      Fiber.abort("Renderer3D.beginShadowPass: call enableShadows({...}) first.")
    }
    _shadowLightVP   = Renderer3D.computeLightVP_(lightDir, lightCenter,
        _shadowExtent, _shadowNear, _shadowFar)
    _shadowDrawIndex = 0

    _shadowPass = encoder.beginRenderPass({
      "colorAttachments": [],
      "depthStencilAttachment": {
        "view":            _shadowView,
        "depthLoadOp":     "clear",
        "depthClearValue": 1.0,
        "depthStoreOp":    "store"
      },
      "label": "renderer3d-shadow-pass"
    })
    _shadowPass.setPipeline(_shadowPipeline)

    // Upload the per-pass light_vp used by every instanced shadow
    // draw. The non-instanced `drawShadow` writes (light_vp, model)
    // into its per-slot UBO; the instanced variant reads light_vp
    // once from this shared UBO and pulls model from each
    // instance's storage buffer entry.
    _shadowInstancedFloats = _shadowInstancedFloats == null ? [] : _shadowInstancedFloats
    _shadowInstancedFloats.clear()
    appendMat4_(_shadowInstancedFloats, _shadowLightVP)
    _shadowInstancedUbo.writeFloats(0, _shadowInstancedFloats)
  }

  /// Issue an INSTANCED shadow draw. The instance buffer holds
  /// per-instance `DrawUniforms { model, normal_mat }` packed
  /// 32-floats-per-entry (the same layout `Renderer3D.writeInstance`
  /// + the existing `drawMeshInstanced` already consume). Only the
  /// `model` half is read by the depth-only shadow VS; normal_mat
  /// is ignored.
  ///
  /// @param {Mesh}   mesh
  /// @param {Buffer} instanceBuffer
  /// @param {Num}    instanceCount
  drawShadowMeshInstanced(mesh, instanceBuffer, instanceCount) {
    if (_shadowPass == null) {
      Fiber.abort("Renderer3D.drawShadowMeshInstanced: call beginShadowPass first.")
    }
    var bgKey = instanceBuffer.id
    var bg = _shadowInstanceBgCache[bgKey]
    if (bg == null) {
      bg = _device.createBindGroup({
        "layout":  _instancedBgl,
        "entries": [{ "binding": 0, "buffer": instanceBuffer }]
      })
      _shadowInstanceBgCache[bgKey] = bg
    }
    _shadowPass.setPipeline(_shadowInstancedPipeline)
    _shadowPass.setBindGroup(0, _shadowInstancedBg0)
    _shadowPass.setBindGroup(1, bg)
    _shadowPass.setVertexBuffer(0, mesh.vertexBuffer)
    _shadowPass.setIndexBuffer(mesh.indexBuffer, "uint32")
    _shadowPass.drawIndexed(mesh.indexCount, instanceCount)
    // Restore the non-instanced shadow pipeline state for any
    // subsequent `drawShadow(...)` call in the same pass — the
    // typical pattern is `terrain (non-instanced) → bucket-N
    // (instanced)`, so callers may interleave either order.
    _shadowPass.setPipeline(_shadowPipeline)
  }

  /// Issue a shadow draw. Only the mesh's vertex positions are
  /// consumed (normal + uv are present in the layout but the
  /// shadow vertex shader ignores them).
  ///
  /// @param {Mesh} mesh
  /// @param {Mat4} model. World-space transform.
  drawShadow(mesh, model) {
    if (_shadowPass == null) {
      Fiber.abort("Renderer3D.drawShadow: call beginShadowPass first.")
    }
    var slot = reserveShadowSlot_()
    _shadowUboFloats.clear()
    appendMat4_(_shadowUboFloats, _shadowLightVP)
    appendMat4_(_shadowUboFloats, model)
    _shadowUboPool[slot].writeFloats(0, _shadowUboFloats)

    _shadowPass.setBindGroup(0, _shadowBgPool[slot])
    _shadowPass.setVertexBuffer(0, mesh.vertexBuffer)
    _shadowPass.setIndexBuffer(mesh.indexBuffer, "uint32")
    _shadowPass.drawIndexed(mesh.indexCount)
  }

  reserveShadowSlot_() {
    if (_shadowDrawIndex >= _shadowUboPool.count) {
      var ubo = _device.createBuffer({
        "size":  Renderer3D.SHADOW_UBO_BYTES_,
        "usage": ["uniform", "copy-dst"],
        "label": "renderer3d-shadow-ubo"
      })
      var bg = _device.createBindGroup({
        "layout":  _shadowBgl,
        "entries": [{ "binding": 0, "buffer": ubo, "size": Renderer3D.SHADOW_UBO_BYTES_ }]
      })
      _shadowUboPool.add(ubo)
      _shadowBgPool.add(bg)
    }
    var i = _shadowDrawIndex
    _shadowDrawIndex = _shadowDrawIndex + 1
    return i
  }

  /// Close the shadow render pass. Subsequent `beginFrame` /
  /// `draw` calls bind the populated shadow map automatically.
  endShadowPass {
    if (_shadowPass == null) {
      Fiber.abort("Renderer3D.endShadowPass: no shadow pass is open.")
    }
    _shadowPass.end
    _shadowPass = null
  }

  // Build a row-major view-projection matrix for a directional
  // shadow caster. Ortho box centred at `centre`, half-extents
  // `extent` × `extent`, depth range [near, far] along
  // `-lightDir`. Returns a Mat4 row-major (the renderer's wire
  // format; transposed at upload time inside appendMat4_).
  static computeLightVP_(lightDir, centre, extent, near, far) {
    // Normalised forward = the light's travel direction.
    var f = Renderer3D.normalize_(lightDir)
    // Pick up vector — avoid degeneracy when light is straight
    // down (or up): swap to world-Z up if the light's vertical.
    var up = (f.y.abs > 0.999) ? Vec3.new(0, 0, 1) : Vec3.new(0, 1, 0)
    // Right = forward × up.
    var r = Renderer3D.cross_(f, up)
    r = Renderer3D.normalize_(r)
    // Recompute up so the basis is orthonormal: up = right × forward.
    up = Renderer3D.cross_(r, f)
    up = Renderer3D.normalize_(up)

    // Eye = centre stepped back along -lightDir by the half-depth
    // so the box's near plane lies just in front of the eye.
    var halfDepth = (far - near) * 0.5
    var eye = Vec3.new(
      centre.x - f.x * halfDepth,
      centre.y - f.y * halfDepth,
      centre.z - f.z * halfDepth
    )

    var view = Mat4.lookAt(eye, centre, up)
    var proj = Mat4.ortho(-extent, extent, -extent, extent, near, far)
    return proj * view
  }

  static normalize_(v) {
    var len = (v.x * v.x + v.y * v.y + v.z * v.z).sqrt
    if (len < 0.000001) return Vec3.new(0, 0, 1)
    return Vec3.new(v.x / len, v.y / len, v.z / len)
  }

  static cross_(a, b) {
    return Vec3.new(
      a.y * b.z - a.z * b.y,
      a.z * b.x - a.x * b.z,
      a.x * b.y - a.y * b.x
    )
  }

  /// Queue a point light. `range == 0` means unbounded
  /// inverse-square; positive values cap the falloff at `range`.
  ///
  /// @param {Vec3} position
  /// @param {Vec3} color
  /// @param {Num} intensity
  /// @param {Num} range
  addPoint(position, color, intensity, range) {
    if (_pointLights.count >= Renderer3D.MAX_POINT_LIGHTS_) {
      _overflow = (_overflow == null ? 0 : _overflow) + 1
      return
    }
    _pointLights.add({
      "pos":       position,
      "color":     color,
      "intensity": intensity,
      "range":     range,
    })
  }

  /// Queue a spot light. Cone half-angles are in radians;
  /// `cos(inner)` and `cos(outer)` are passed up to the shader,
  /// so smaller angles → tighter cones.
  ///
  /// @param {Vec3} position
  /// @param {Vec3} direction. Forward axis the spot points along.
  /// @param {Vec3} color
  /// @param {Num} intensity
  /// @param {Num} range
  /// @param {Num} innerConeAngle. Half-angle in radians.
  /// @param {Num} outerConeAngle. Half-angle in radians.
  addSpot(position, direction, color, intensity, range, innerConeAngle, outerConeAngle) {
    if (_spotLights.count >= Renderer3D.MAX_SPOT_LIGHTS_) {
      _overflow = (_overflow == null ? 0 : _overflow) + 1
      return
    }
    _spotLights.add({
      "pos":       position,
      "dir":       direction,
      "color":     color,
      "intensity": intensity,
      "range":     range,
      "innerCos":  innerConeAngle.cos,
      "outerCos":  outerConeAngle.cos,
    })
  }

  /// Number of lights dropped this frame for exceeding the per-kind
  /// cap. Reset by every `beginFrame`. Useful for a debug overlay.
  /// @returns {Num}
  overflow_ { _overflow == null ? 0 : _overflow }

  /// Issue one draw. Builds the per-draw uniform (model +
  /// normal_mat), resolves the material's bind group from the
  /// cache (rebuilding it if the material's `revision_` has
  /// advanced), binds it as group 2, and dispatches indexed.
  ///
  /// @param {Mesh} mesh
  /// @param {Material} material
  /// @param {Mat4} model. World-space transform.
  draw(mesh, material, model) {
    if (_pass == null) Fiber.abort("Renderer3D.draw: call beginFrame first.")

    // First draw of the frame commits the scene uniform — gives
    // the caller a chance to call `setAmbient` / `addDirectional`
    // / etc. between beginFrame and the first draw without
    // forcing a double-upload.
    if (!_sceneCommitted) commitScene_()

    // Per-draw uniform: model + normal_mat. For orthonormal
    // model matrices (rotation + translation only) the model
    // matrix itself doubles as a normal matrix; non-orthonormal
    // models will need `Mat4.inverse(model).transpose` once
    // `Mat4.inverse` is exposed.
    writeMat4ToScratch_(_drawUboFloats,  0, model)
    writeMat4ToScratch_(_drawUboFloats, 16, model)

    // Pull (or grow) the per-draw UBO slot for this index.
    // Sharing one UBO across draws within a frame collapses
    // every model matrix to the last `writeFloats` call — see
    // pool comment in the constructor.
    var i = reserveDrawSlot_()
    _drawUboPool[i].writeFloats(0, _drawUboFloats)

    // Resolve material bind group; rebuild on revision change.
    var entry = bindGroupFor_(material)
    var pass = _pass
    // Pipeline selection by material state:
    //   - shadingModel "toon" → cel-shaded pipeline (mat.toon read,
    //     ACES bypass). Wins over the alpha-mode switch because
    //     toon assets are typically opaque or alpha-mask; if a
    //     future toon material needs alpha-blend it gets its own
    //     pipeline pairing.
    //   - alphaMode "blend" → transparent PBR pipeline (depth-write
    //     off, standard src-alpha blend).
    //   - everything else → the default PBR pipeline.
    if (material.shadingModel == "toon") {
      pass.setPipeline(_toonPipeline)
    } else if (material.alphaMode == "blend") {
      pass.setPipeline(_transparentPipeline)
    } else {
      pass.setPipeline(_pipeline)
    }
    // Re-bind scene group explicitly so a preceding pipeline
    // switch (e.g. `drawMeshInstanced` → `draw` in the same pass)
    // can't leave slot 0 invalidated. Matches what
    // `drawMeshInstanced` already does.
    pass.setBindGroup(0, _sceneBindGroup)
    pass.setBindGroup(1, _drawBindGroupPool[i])
    pass.setBindGroup(2, entry["bg"])
    pass.setVertexBuffer(0, mesh.vertexBuffer)
    pass.setIndexBuffer(mesh.indexBuffer, "uint32")
    pass.drawIndexed(mesh.indexCount)
  }

  /// Instanced draw. Submits `instanceCount` copies of `mesh`
  /// styled with `material`, with per-instance `model` + `normalMat`
  /// matrices read out of `instanceBuffer` (a storage buffer laid
  /// out as `array<DrawUniforms>` — 32 f32 per instance: 16 model
  /// + 16 normal_mat).
  ///
  /// The buffer must be created with `["storage", "copy-dst"]`
  /// usage. Pack the matrix data with `Renderer3D.appendInstance(
  /// scratchpad, model)` (auto-derives `normalMat = model` for
  /// orthonormal transforms) or `appendInstance(scratchpad, model,
  /// normalMat)` for the explicit form, then upload with
  /// `instanceBuffer.writeFloats(0, scratchpad)`.
  ///
  /// One drawIndexed call covers the whole batch. The instance
  /// buffer can also be the direct output of a compute pass that
  /// computes per-instance transforms (procedural placement,
  /// frustum culling write-out, LOD selection).
  ///
  /// @param {Mesh} mesh
  /// @param {Material} material
  /// @param {Buffer} instanceBuffer
  /// @param {Num} instanceCount
  drawMeshInstanced(mesh, material, instanceBuffer, instanceCount) {
    if (_pass == null) Fiber.abort("Renderer3D.drawMeshInstanced: call beginFrame first.")
    if (instanceCount <= 0) return
    if (!_sceneCommitted) commitScene_()

    var entry = bindGroupFor_(material)
    var pass = _pass
    pass.setPipeline(instancedPipelineFor_(material))
    pass.setBindGroup(0, _sceneBindGroup)
    pass.setBindGroup(1, instanceBindGroupFor_(instanceBuffer))
    pass.setBindGroup(2, entry["bg"])
    pass.setVertexBuffer(0, mesh.vertexBuffer)
    pass.setIndexBuffer(mesh.indexBuffer, "uint32")
    pass.drawIndexed(mesh.indexCount, instanceCount)
  }

  // Pick the right instanced pipeline for `material`. Mirrors the
  // non-instanced draw() dispatch: toon → `_toonInstancedPipeline`,
  // anything else → the PBR-instanced pipeline. Transparent
  // instanced is the PBR-instanced path with the caller's own
  // sort + alpha-blend material — there's no parallel
  // `_transparentInstancedPipeline` yet.
  instancedPipelineFor_(material) {
    if (material.shadingModel == "toon") return _toonInstancedPipeline
    return _instancedPipeline
  }

  // Skinned-mesh dispatch: toon → `_toonSkinnedPipeline`,
  // anything else → the PBR-skinned pipeline. Mirrors
  // `instancedPipelineFor_` so `drawSkinned` consumers get
  // material-driven shading-model selection.
  skinnedPipelineFor_(material) {
    if (material.shadingModel == "toon") return _toonSkinnedPipeline
    return _skinnedPipeline
  }

  /// GPU-driven indexed-instanced draw. Identical render setup to
  /// [Renderer3D.drawMeshInstanced] (scene BG, instance SSBO BG,
  /// material BG, instanced pipeline, mesh VB/IB) but the instance
  /// count + index count come from `indirectBuffer` at `offset`
  /// instead of CPU args. Pair with `ComputeCull.cull` which fills
  /// those args from a GPU frustum-cull pass.
  ///
  /// `instanceBuffer` must hold the COMPACTED-output buffer
  /// `ComputeCull` wrote into — its slot count is the count slot
  /// in `indirectBuffer` and its stride is the standard 128 B /
  /// DrawUniforms slot.
  ///
  /// @param {Mesh}     mesh
  /// @param {Material} material
  /// @param {Buffer}   instanceBuffer
  /// @param {Buffer}   indirectBuffer  5 × u32 = 20 B, usage includes "indirect"
  drawMeshInstancedIndirect(mesh, material, instanceBuffer, indirectBuffer) {
    drawMeshInstancedIndirect(mesh, material, instanceBuffer, indirectBuffer, 0)
  }

  /// As `drawMeshInstancedIndirect/4` but with an explicit byte
  /// offset into the indirect-args buffer (lets one args buffer
  /// hold args for multiple draws).
  drawMeshInstancedIndirect(mesh, material, instanceBuffer, indirectBuffer, offset) {
    if (_pass == null) Fiber.abort("Renderer3D.drawMeshInstancedIndirect: call beginFrame first.")
    if (!_sceneCommitted) commitScene_()

    var entry = bindGroupFor_(material)
    var pass = _pass
    pass.setPipeline(instancedPipelineFor_(material))
    pass.setBindGroup(0, _sceneBindGroup)
    pass.setBindGroup(1, instanceBindGroupFor_(instanceBuffer))
    pass.setBindGroup(2, entry["bg"])
    pass.setVertexBuffer(0, mesh.vertexBuffer)
    pass.setIndexBuffer(mesh.indexBuffer, "uint32")
    pass.drawIndexedIndirect(indirectBuffer, offset)
  }

  /// Skinned mesh draw. Uses the dedicated skinned PBR pipeline:
  /// reads JOINTS_0 / WEIGHTS_0 from `mesh.jointsBuffer` /
  /// `mesh.weightsBuffer` (slots 1 + 2), samples the joint matrix
  /// palette from `skin.bindGroup` (bind group 3), and otherwise
  /// behaves like the static `draw` path — same scene + draw +
  /// material bindings.
  ///
  /// The caller is responsible for keeping the skin palette
  /// up-to-date each frame via `skin.update(matrices)` before
  /// this draw.
  ///
  /// @param {Mesh}        mesh
  /// @param {Material}    material
  /// @param {SkinPalette} skin
  /// @param {Mat4}        model. Mesh-root world transform.
  drawSkinned(mesh, material, skin, model) {
    if (_pass == null) Fiber.abort("Renderer3D.drawSkinned: call beginFrame first.")
    if (mesh.jointsBuffer == null || mesh.weightsBuffer == null) {
      Fiber.abort("Renderer3D.drawSkinned: mesh has no jointsBuffer / weightsBuffer — build via Mesh.fromArraysSkinned.")
    }
    if (!_sceneCommitted) commitScene_()

    // Per-draw UBO (model + normal_mat), matching `draw`. Treats
    // the model matrix as its own normal_mat — valid for the
    // orthonormal transforms typical of skinned character roots.
    writeMat4ToScratch_(_drawUboFloats,  0, model)
    writeMat4ToScratch_(_drawUboFloats, 16, model)
    var i = reserveDrawSlot_()
    _drawUboPool[i].writeFloats(0, _drawUboFloats)

    var skinBg = skin.bindWith(_skinBgl)
    var entry  = bindGroupFor_(material)
    var pass = _pass
    pass.setPipeline(skinnedPipelineFor_(material))
    pass.setBindGroup(0, _sceneBindGroup)
    pass.setBindGroup(1, _drawBindGroupPool[i])
    pass.setBindGroup(2, entry["bg"])
    pass.setBindGroup(3, skinBg)
    pass.setVertexBuffer(0, mesh.vertexBuffer)
    pass.setVertexBuffer(1, mesh.jointsBuffer)
    pass.setVertexBuffer(2, mesh.weightsBuffer)
    pass.setIndexBuffer(mesh.indexBuffer, "uint32")
    pass.drawIndexed(mesh.indexCount)
  }

  /// Skinned + instanced toon draw. ONE GPU dispatch renders N
  /// posed instances of `mesh` at distinct world transforms +
  /// emissive tints by indexing into `instanceBuffer` from the
  /// vertex shader's `@builtin(instance_index)`.
  ///
  /// Bind groups:
  ///   - @group(0): scene
  ///   - @group(1): per-instance SSBO (model + normal_mat + tint
  ///                per instance, 144 bytes / 36 floats / 9 vec4
  ///                stride)
  ///   - @group(2): material
  ///   - @group(3): joint-matrix palette (shared across all
  ///                instances in this dispatch)
  ///
  /// The caller is responsible for keeping the skin palette
  /// up-to-date each frame via `skin.update(matrices)` and for
  /// packing per-instance data into `instanceBuffer` via the
  /// `Renderer3D.writeSkinnedInstance(scratch, slot, model,
  /// normalMat, tint)` helper.
  ///
  /// Currently toon-shading + MRT only (the variant nature-garden
  /// uses); PBR + non-MRT support will land alongside the first
  /// PBR consumer.
  ///
  /// @param {Mesh}        mesh
  /// @param {Material}    material        toon-shading model required
  /// @param {SkinPalette} skin
  /// @param {Buffer}      instanceBuffer  storage buffer with
  ///                                      `count × 144 B` of per-
  ///                                      instance data
  /// @param {Num}         count           number of instances to dispatch
  drawSkinnedInstanced(mesh, material, skin, instanceBuffer, count) {
    if (_pass == null) Fiber.abort("Renderer3D.drawSkinnedInstanced: call beginFrame first.")
    if (count <= 0) return
    if (mesh.jointsBuffer == null || mesh.weightsBuffer == null) {
      Fiber.abort("Renderer3D.drawSkinnedInstanced: mesh has no jointsBuffer / weightsBuffer.")
    }
    if (!_sceneCommitted) commitScene_()

    var skinBg = skin.bindWith(_skinBgl)
    var entry  = bindGroupFor_(material)
    var pass   = _pass
    pass.setPipeline(_toonSkinnedInstancedPipeline)
    pass.setBindGroup(0, _sceneBindGroup)
    pass.setBindGroup(1, instanceBindGroupFor_(instanceBuffer))
    pass.setBindGroup(2, entry["bg"])
    pass.setBindGroup(3, skinBg)
    pass.setVertexBuffer(0, mesh.vertexBuffer)
    pass.setVertexBuffer(1, mesh.jointsBuffer)
    pass.setVertexBuffer(2, mesh.weightsBuffer)
    pass.setIndexBuffer(mesh.indexBuffer, "uint32")
    pass.drawIndexed(mesh.indexCount, count)
  }

  /// Pack one instance's data into `scratch` at `slot`. Slot
  /// stride is 36 floats (model 16 + normal_mat 16 + tint 4).
  /// Caller pre-allocates `Float32Array.new(maxInstances × 36)`
  /// and uses this helper to fill it before uploading via
  /// `instanceBuffer.writeFloats(0, scratch)`.
  ///
  /// `normalMat` should be the inverse-transpose of `model` for
  /// correct lit normals; for orthonormal model matrices it can
  /// be the model itself.
  ///
  /// @param {Float32Array} scratch
  /// @param {Num}          slot       0-based instance index
  /// @param {Mat4}         model
  /// @param {Mat4}         normalMat
  /// @param {Vec4}         tint       xyz = emissive RGB multiplier
  static writeSkinnedInstance(scratch, slot, model, normalMat, tint) {
    var off = slot * 36
    var md = model.data
    var nd = normalMat.data
    // Mat4 row-major data → column-major storage (WGSL convention)
    var c = 0
    while (c < 4) {
      var r = 0
      while (r < 4) {
        scratch[off + c * 4 + r] = md[r * 4 + c]
        r = r + 1
      }
      c = c + 1
    }
    off = off + 16
    c = 0
    while (c < 4) {
      var r = 0
      while (r < 4) {
        scratch[off + c * 4 + r] = nd[r * 4 + c]
        r = r + 1
      }
      c = c + 1
    }
    off = off + 16
    scratch[off + 0] = tint.x
    scratch[off + 1] = tint.y
    scratch[off + 2] = tint.z
    scratch[off + 3] = tint.w
  }

  /// Multi-LOD instanced draw. Issues one `drawIndexed` per LOD
  /// tier, picking the right `Mesh` out of `lodMesh` (a `MeshLOD`)
  /// for each one. `buckets` is a parallel list — one entry per
  /// LOD level — where each entry is either:
  ///
  ///   - `null` (skip that tier — no instances), or
  ///   - a `Map { "buffer": Buffer, "count": Num }`
  ///
  /// The caller partitions its instance set into per-LOD buckets
  /// (via `MeshLOD.pickIndex` per instance + a fast scatter into
  /// pre-allocated Float32Array scratchpads), then dispatches one
  /// `drawInstancedLOD` for the whole scene's worth of foliage /
  /// crowd / asteroid instances.
  ///
  /// @param {MeshLOD} lodMesh
  /// @param {Material} material
  /// @param {List<Map?>} buckets. Length must equal `lodMesh.count`.
  drawInstancedLOD(lodMesh, material, buckets) {
    if (_pass == null) Fiber.abort("Renderer3D.drawInstancedLOD: call beginFrame first.")
    // Duck-typed: lodMesh exposes `count` (Num) and `meshAt(i)`
    // (Mesh). MeshLOD lives in the package's entry file
    // (gpu_native.wren) which imports this one, so a hard `is`
    // check would close a circular dep we don't want.
    if (buckets.count != lodMesh.count) {
      Fiber.abort("Renderer3D.drawInstancedLOD: buckets.count (%(buckets.count)) must match lodMesh.count (%(lodMesh.count))")
    }
    if (!_sceneCommitted) commitScene_()
    var entry = bindGroupFor_(material)
    var pass = _pass
    pass.setPipeline(instancedPipelineFor_(material))
    pass.setBindGroup(0, _sceneBindGroup)
    pass.setBindGroup(2, entry["bg"])
    var i = 0
    while (i < buckets.count) {
      var bucket = buckets[i]
      if (bucket != null) {
        var count = bucket["count"]
        if (count > 0) {
          var mesh = lodMesh.meshAt(i)
          pass.setBindGroup(1, instanceBindGroupFor_(bucket["buffer"]))
          pass.setVertexBuffer(0, mesh.vertexBuffer)
          pass.setIndexBuffer(mesh.indexBuffer, "uint32")
          pass.drawIndexed(mesh.indexCount, count)
        }
      }
      i = i + 1
    }
  }

  /// Instanced billboard draw. `instanceBuffer` is a storage
  /// buffer laid out as `array<BillboardInstance>` with 16 f32
  /// per slot — see `BILLBOARD_WGSL_` for the field order, or
  /// pack via [Renderer3D.writeBillboardInstance]. Each billboard
  /// is a spherical camera-facing quad; the VS performs the
  /// camera-orient math per instance so the CPU never re-orients.
  ///
  /// Issues one `pass.draw(6, instanceCount)` — no vertex / index
  /// buffer needed. Uses `blend: "alpha"` and `depthWriteEnabled:
  /// false` so soft-edged particle sprites composite correctly
  /// over the opaque scene without obscuring each other.
  ///
  /// @param {Texture} texture
  /// @param {Buffer} instanceBuffer
  /// @param {Num} instanceCount
  drawBillboardN(texture, instanceBuffer, instanceCount) {
    if (_pass == null) Fiber.abort("Renderer3D.drawBillboardN: call beginFrame first.")
    if (instanceCount <= 0) return
    if (!_sceneCommitted) commitScene_()
    var pass = _pass
    pass.setPipeline(_billboardPipeline)
    pass.setBindGroup(0, _billboardSceneBg)
    pass.setBindGroup(1, instanceBindGroupFor_(instanceBuffer))
    pass.setBindGroup(2, billboardMatBindGroupFor_(texture))
    pass.draw(6, instanceCount)
  }

  // BindGroup cache for the billboard pipeline's (texture, sampler)
  // group 2. Keyed by texture id so a particle system that re-uses
  // the same atlas across frames hits the cache.
  billboardMatBindGroupFor_(texture) {
    var existing = _billboardMatBgCache[texture.id]
    if (existing != null) return existing
    var bg = _device.createBindGroup({
      "layout":  _billboardMaterialBgl,
      "entries": [
        { "binding": 0, "view":    texture.createView() },
        { "binding": 1, "sampler": _billboardSampler }
      ]
    })
    _billboardMatBgCache[texture.id] = bg
    return bg
  }

  /// Pack one billboard instance into a 16-f32 slot at
  /// `slotIndex` of `out`. Slot stride is
  /// `Renderer3D.FLOATS_PER_BILLBOARD_` (16). Pre-allocate `out`
  /// as `Float32Array.new(capacity * 16)`; upload via
  /// `instanceBuffer.writeFloats(0, out)`.
  ///
  /// `(ox, oy, oz)` is the world-space origin (the billboard
  /// centre). `(sx, sy)` is the billboard's world-space size.
  /// `(u0, v0, u1, v1)` is the UV rectangle into the bound
  /// texture. `rotation` rotates around the camera-forward axis
  /// (radians). `lodIndex` is reserved for the GPU-driven LOD
  /// path that consumes the same instance buffer from a compute
  /// pass.
  ///
  /// @param {Float32Array} out
  /// @param {Num} slotIndex
  /// @param {Num} ox
  /// @param {Num} oy
  /// @param {Num} oz
  /// @param {Num} sx
  /// @param {Num} sy
  /// @param {Num} u0
  /// @param {Num} v0
  /// @param {Num} u1
  /// @param {Num} v1
  /// @param {Num} r
  /// @param {Num} g
  /// @param {Num} b
  /// @param {Num} a
  /// @param {Num} rotation
  /// @param {Num} lodIndex
  static writeBillboardInstance(out, slotIndex, ox, oy, oz, sx, sy,
                                u0, v0, u1, v1, r, g, b, a, rotation, lodIndex) {
    var off = slotIndex * 16
    out[off]      = ox
    out[off + 1]  = oy
    out[off + 2]  = oz
    out[off + 3]  = sx
    out[off + 4]  = sy
    out[off + 5]  = u0
    out[off + 6]  = v0
    out[off + 7]  = u1
    out[off + 8]  = v1
    out[off + 9]  = r
    out[off + 10] = g
    out[off + 11] = b
    out[off + 12] = a
    out[off + 13] = rotation
    out[off + 14] = lodIndex
    out[off + 15] = 0
  }

  // Get or build the BindGroup that points at `buf` for the
  // instanced pipeline's group 1.
  instanceBindGroupFor_(buf) {
    var existing = _instanceBgCache[buf.id]
    if (existing != null) return existing
    var bg = _device.createBindGroup({
      "layout":  _instancedBgl,
      "entries": [{ "binding": 0, "buffer": buf }]
    })
    _instanceBgCache[buf.id] = bg
    return bg
  }

  /// Append one instance's (model, normalMat) to a List-shaped
  /// scratchpad (32 floats per instance). Convenient for one-off
  /// tests; the hot path should use `writeInstance` with a
  /// pre-allocated `Float32Array` instead — every `.add` on a
  /// growing List hits the allocator, and a 200-cube frame is
  /// 6400 entries vs. a single indexed-write loop into a typed
  /// array.
  ///
  /// @param {List} floats. Scratchpad. The 32 f32 of this instance
  ///   are appended to the end.
  /// @param {Mat4} model
  static appendInstance(floats, model) {
    appendInstance(floats, model, model)
  }
  /// @param {List} floats
  /// @param {Mat4} model
  /// @param {Mat4} normalMat
  static appendInstance(floats, model, normalMat) {
    // Mat4.data is row-major; WGSL mat4x4<f32> reads 16 floats as
    // column-major. Transpose at the upload boundary so the shader's
    // M*v reads the rows as expected. Unrolled to match the
    // appendMat4_ note: looped form miscompiled under tiered.
    var d = model.data
    floats.add(d[0])
    floats.add(d[4])
    floats.add(d[8])
    floats.add(d[12])
    floats.add(d[1])
    floats.add(d[5])
    floats.add(d[9])
    floats.add(d[13])
    floats.add(d[2])
    floats.add(d[6])
    floats.add(d[10])
    floats.add(d[14])
    floats.add(d[3])
    floats.add(d[7])
    floats.add(d[11])
    floats.add(d[15])
    var n = normalMat.data
    floats.add(n[0])
    floats.add(n[4])
    floats.add(n[8])
    floats.add(n[12])
    floats.add(n[1])
    floats.add(n[5])
    floats.add(n[9])
    floats.add(n[13])
    floats.add(n[2])
    floats.add(n[6])
    floats.add(n[10])
    floats.add(n[14])
    floats.add(n[3])
    floats.add(n[7])
    floats.add(n[11])
    floats.add(n[15])
  }

  /// Hot-path instance write. Stores one instance's transposed
  /// (model, normalMat) at slot `slot` of a pre-allocated
  /// `Float32Array` — 32 floats per slot, indexed directly. No
  /// per-element allocation, no method dispatch on the inner
  /// loop. Pair with `buffer.writeFloatsN(0, scratch, count * 32)`
  /// to upload just the live tail.
  ///
  /// `scratch.length >= (slot + 1) * 32` must hold. The transpose
  /// pattern mirrors `appendInstance` (Mat4.data is row-major,
  /// WGSL `mat4x4<f32>` reads column-major).
  ///
  /// @param {Float32Array} scratch
  /// @param {Num} slot
  /// @param {Mat4} model
  static writeInstance(scratch, slot, model) {
    writeInstance(scratch, slot, model, model)
  }
  /// @param {Float32Array} scratch
  /// @param {Num} slot
  /// @param {Mat4} model
  /// @param {Mat4} normalMat
  static writeInstance(scratch, slot, model, normalMat) {
    var off = slot * 32
    var d = model.data
    scratch[off]      = d[0]
    scratch[off + 1]  = d[4]
    scratch[off + 2]  = d[8]
    scratch[off + 3]  = d[12]
    scratch[off + 4]  = d[1]
    scratch[off + 5]  = d[5]
    scratch[off + 6]  = d[9]
    scratch[off + 7]  = d[13]
    scratch[off + 8]  = d[2]
    scratch[off + 9]  = d[6]
    scratch[off + 10] = d[10]
    scratch[off + 11] = d[14]
    scratch[off + 12] = d[3]
    scratch[off + 13] = d[7]
    scratch[off + 14] = d[11]
    scratch[off + 15] = d[15]
    var n = normalMat.data
    scratch[off + 16] = n[0]
    scratch[off + 17] = n[4]
    scratch[off + 18] = n[8]
    scratch[off + 19] = n[12]
    scratch[off + 20] = n[1]
    scratch[off + 21] = n[5]
    scratch[off + 22] = n[9]
    scratch[off + 23] = n[13]
    scratch[off + 24] = n[2]
    scratch[off + 25] = n[6]
    scratch[off + 26] = n[10]
    scratch[off + 27] = n[14]
    scratch[off + 28] = n[3]
    scratch[off + 29] = n[7]
    scratch[off + 30] = n[11]
    scratch[off + 31] = n[15]
  }

  /// Foliage fast path. Writes one instance directly into
  /// `scratch[slot]` from `(x, y, z, scale, yawRad)` without
  /// constructing a Mat4. Same 32-float layout as `writeInstance`
  /// — model matrix in the first 16, normal matrix in the second.
  /// The normal matrix drops the uniform scale (vector transforms
  /// don't need it; the renormalize in the VS would cancel it
  /// anyway).
  ///
  /// Use this for scattered grass / leaf / rock fields where each
  /// instance is a translation × Y-rotation × uniform scale; the
  /// allocator-free path keeps a 100k-blade frame in CPU budget.
  /// For sheared / non-uniform transforms, fall back to
  /// `writeInstance`.
  ///
  /// @param {Float32Array} scratch
  /// @param {Num} slot
  /// @param {Num} x
  /// @param {Num} y
  /// @param {Num} z
  /// @param {Num} scale  uniform scale (1.0 = mesh-native size)
  /// @param {Num} yawRad rotation around the +Y axis (radians)
  static writeInstanceXYZ(scratch, slot, x, y, z, scale, yawRad) {
    var off = slot * 32
    var cy = yawRad.cos
    var sy = yawRad.sin
    var sc = scale * cy
    var ss = scale * sy
    // Model — column-major in storage (writeInstance comment
    // explains why). col 0 = (s·cy, 0, -s·sy, 0); col 2 = (s·sy, 0,
    // s·cy, 0); col 3 = (x, y, z, 1); col 1 = (0, s, 0, 0).
    scratch[off]      = sc
    scratch[off + 1]  = 0
    scratch[off + 2]  = -ss
    scratch[off + 3]  = 0
    scratch[off + 4]  = 0
    scratch[off + 5]  = scale
    scratch[off + 6]  = 0
    scratch[off + 7]  = 0
    scratch[off + 8]  = ss
    scratch[off + 9]  = 0
    scratch[off + 10] = sc
    scratch[off + 11] = 0
    scratch[off + 12] = x
    scratch[off + 13] = y
    scratch[off + 14] = z
    scratch[off + 15] = 1
    // Normal matrix — rotation only, scale dropped (the VS
    // normalizes the result, and uniform scale cancels under
    // normalize).
    scratch[off + 16] = cy
    scratch[off + 17] = 0
    scratch[off + 18] = -sy
    scratch[off + 19] = 0
    scratch[off + 20] = 0
    scratch[off + 21] = 1
    scratch[off + 22] = 0
    scratch[off + 23] = 0
    scratch[off + 24] = sy
    scratch[off + 25] = 0
    scratch[off + 26] = cy
    scratch[off + 27] = 0
    scratch[off + 28] = 0
    scratch[off + 29] = 0
    scratch[off + 30] = 0
    scratch[off + 31] = 1
  }

  // Reserve the next free per-draw slot. Grows the parallel
  // pool arrays when the scene's draw count exceeds previous
  // frames'; otherwise just bumps the index. Returns the slot
  // index — callers read `_drawUboPool[i]` / `_drawBindGroupPool[i]`
  // directly so the hot path never allocates a Map wrapper.
  reserveDrawSlot_() {
    if (_drawIndex >= _drawUboPool.count) {
      var ubo = _device.createBuffer({
        "size":  Renderer3D.DRAW_UBO_BYTES_,
        "usage": ["uniform", "copy-dst"],
        "label": "renderer3d-draw-ubo"
      })
      var bg = _device.createBindGroup({
        "layout":  _drawBgl,
        "entries": [{ "binding": 0, "buffer": ubo, "size": Renderer3D.DRAW_UBO_BYTES_ }]
      })
      _drawUboPool.add(ubo)
      _drawBindGroupPool.add(bg)
    }
    var i = _drawIndex
    _drawIndex = _drawIndex + 1
    return i
  }

  commitScene_() {
    _sceneUboFloats.clear()
    appendMat4_(_sceneUboFloats, _vp)
    // camera_pos (xyz + 1 pad)
    _sceneUboFloats.add(_cameraPos.x)
    _sceneUboFloats.add(_cameraPos.y)
    _sceneUboFloats.add(_cameraPos.z)
    _sceneUboFloats.add(0)
    // ambient (rgb * intensity + pad)
    _sceneUboFloats.add(_ambient.x * _ambientIntensity)
    _sceneUboFloats.add(_ambient.y * _ambientIntensity)
    _sceneUboFloats.add(_ambient.z * _ambientIntensity)
    _sceneUboFloats.add(0)
    // counts (dir, point, spot, shadows_enabled). The shadow flag
    // is `1.0` only when (a) `enableShadows` ran and (b) the
    // primary dir light has its `castsShadows` flag set — that's
    // what makes the PBR shader's `shadow_factor` actually sample
    // the shadow map.
    var shadowsActive = _shadowsEnabled &&
        _dirLights.count > 0 &&
        _dirLights[0]["castsShadows"] &&
        _shadowLightVP != null
    _sceneUboFloats.add(_dirLights.count)
    _sceneUboFloats.add(_pointLights.count)
    _sceneUboFloats.add(_spotLights.count)
    _sceneUboFloats.add(shadowsActive ? 1 : 0)
    // light_vp — populated when shadowsActive; zeroed otherwise so
    // an unused slot doesn't carry stale matrix bits across frames.
    if (shadowsActive) {
      appendMat4_(_sceneUboFloats, _shadowLightVP)
    } else {
      appendZeros_(_sceneUboFloats, 16)
    }
    // shadow_params: x = depth bias, y = PCF radius,
    //                z = shadow-AO strength, w = reserved.
    _sceneUboFloats.add(_shadowBias)
    _sceneUboFloats.add(_shadowPcfRadius)
    _sceneUboFloats.add(_shadowAOStrength)
    _sceneUboFloats.add(0)
    // wind: xy = direction (xz plane), z = time, w = strength.
    // Vertex shaders multiply this by per-material `sway` and a
    // per-vertex local-Y factor to bend foliage in the wind.
    _sceneUboFloats.add(_windDirX)
    _sceneUboFloats.add(_windDirZ)
    _sceneUboFloats.add(_windTime)
    _sceneUboFloats.add(_windStrength)
    // env_top / env_horizon / env_bottom — 3-band IBL gradient.
    // All zero by default; `setEnvironment` populates them
    // per-frame between `beginFrame` and the first draw.
    _sceneUboFloats.add(_envTop.x)
    _sceneUboFloats.add(_envTop.y)
    _sceneUboFloats.add(_envTop.z)
    _sceneUboFloats.add(0)
    _sceneUboFloats.add(_envHorizon.x)
    _sceneUboFloats.add(_envHorizon.y)
    _sceneUboFloats.add(_envHorizon.z)
    _sceneUboFloats.add(0)
    _sceneUboFloats.add(_envBottom.x)
    _sceneUboFloats.add(_envBottom.y)
    _sceneUboFloats.add(_envBottom.z)
    _sceneUboFloats.add(0)
    // dir_lights[0..MAX]; pad slots after the live count with zeros
    // so the shader's loop bound (`scene.counts.x`) governs reads.
    var i = 0
    while (i < Renderer3D.MAX_DIR_LIGHTS_) {
      if (i < _dirLights.count) {
        var d = _dirLights[i]
        _sceneUboFloats.add(d["dir"].x)
        _sceneUboFloats.add(d["dir"].y)
        _sceneUboFloats.add(d["dir"].z)
        _sceneUboFloats.add(d["intensity"])
        _sceneUboFloats.add(d["color"].x)
        _sceneUboFloats.add(d["color"].y)
        _sceneUboFloats.add(d["color"].z)
        _sceneUboFloats.add(0)
      } else {
        appendZeros_(_sceneUboFloats, 8)
      }
      i = i + 1
    }
    i = 0
    while (i < Renderer3D.MAX_POINT_LIGHTS_) {
      if (i < _pointLights.count) {
        var p = _pointLights[i]
        _sceneUboFloats.add(p["pos"].x)
        _sceneUboFloats.add(p["pos"].y)
        _sceneUboFloats.add(p["pos"].z)
        _sceneUboFloats.add(p["range"])
        _sceneUboFloats.add(p["color"].x)
        _sceneUboFloats.add(p["color"].y)
        _sceneUboFloats.add(p["color"].z)
        _sceneUboFloats.add(p["intensity"])
      } else {
        appendZeros_(_sceneUboFloats, 8)
      }
      i = i + 1
    }
    i = 0
    while (i < Renderer3D.MAX_SPOT_LIGHTS_) {
      if (i < _spotLights.count) {
        var s = _spotLights[i]
        _sceneUboFloats.add(s["pos"].x)
        _sceneUboFloats.add(s["pos"].y)
        _sceneUboFloats.add(s["pos"].z)
        _sceneUboFloats.add(s["range"])
        _sceneUboFloats.add(s["color"].x)
        _sceneUboFloats.add(s["color"].y)
        _sceneUboFloats.add(s["color"].z)
        _sceneUboFloats.add(s["intensity"])
        _sceneUboFloats.add(s["dir"].x)
        _sceneUboFloats.add(s["dir"].y)
        _sceneUboFloats.add(s["dir"].z)
        _sceneUboFloats.add(s["innerCos"])
        _sceneUboFloats.add(s["outerCos"])
        _sceneUboFloats.add(0)
        _sceneUboFloats.add(0)
        _sceneUboFloats.add(0)
      } else {
        appendZeros_(_sceneUboFloats, 16)
      }
      i = i + 1
    }
    _sceneUbo.writeFloats(0, _sceneUboFloats)
    _sceneCommitted = true

    // Slim billboard scene UBO: vp + camera_pos. Reuses the same
    // values we already packed into the main scene UBO so any
    // billboard pass within the frame stays consistent with the
    // 3D scene's projection.
    var bbf = []
    appendMat4_(bbf, _vp)
    bbf.add(_cameraPos.x)
    bbf.add(_cameraPos.y)
    bbf.add(_cameraPos.z)
    bbf.add(0)
    _billboardSceneUbo.writeFloats(0, bbf)
  }

  /// Pre-build (or refresh) the per-Material UBO + BindGroup so
  /// the first draw of `material` in a frame doesn't pay the
  /// `createBuffer + createBindGroup` cost on the hot path.
  ///
  /// Many props with many distinct materials drawn in one frame
  /// produce enough allocator churn that the GC corrupts the
  /// shared `_drawUboFloats` list mid-frame ("Buffer.writeFloats:
  /// every element must be a number (index 0)"). Calling
  /// `prewarmMaterial(m)` once at setup time keeps draw() pure
  /// dispatch.
  ///
  /// @param {Material} material
  prewarmMaterial(material) {
    bindGroupFor_(material)
  }

  /// Walk every `GltfScene` in `scenes` and pre-warm a UBO +
  /// BindGroup for every primitive's material. Equivalent to
  /// calling `prewarmMaterial` for each non-null `prim.material`
  /// across all the scenes' meshes — just spelled in one call so
  /// callers don't have to write the nested loop.
  ///
  /// @param {List<GltfScene>} scenes
  prewarmGltfScenes(scenes) {
    var si = 0
    while (si < scenes.count) {
      var meshes = scenes[si].meshes
      var mi = 0
      while (mi < meshes.count) {
        var prims = meshes[mi].primitives
        var pj = 0
        while (pj < prims.count) {
          var prim = prims[pj]
          if (prim.material != null) bindGroupFor_(prim.material)
          pj = pj + 1
        }
        mi = mi + 1
      }
      si = si + 1
    }
  }

  // Look up (or build) the BindGroup for `material`. The cache
  // stores the GPU resources (bind group + small material UBO) so
  // unchanged materials reuse them across frames. A revision
  // bump triggers a rewrite of the UBO bytes — the BindGroup
  // itself stays alive since the textures it references are
  // pinned by the cache.
  bindGroupFor_(material) {
    if (_materialCache.containsKey(material)) {
      var existing = _materialCache[material]
      if (existing["rev"] == material.revision_) return existing
      // Property mutated — refresh the UBO contents.
      _matUboFloats.clear()
      material.packUniform_(_matUboFloats)
      existing["ubo"].writeFloats(0, _matUboFloats)
      existing["rev"] = material.revision_
      return existing
    }
    return buildMaterialBindGroup_(material)
  }

  buildMaterialBindGroup_(material) {
    var ubo = _device.createBuffer({
      "size":  Renderer3D.MAT_UBO_BYTES_,
      "usage": ["uniform", "copy-dst"],
      "label": "renderer3d-mat-ubo"
    })
    _matUboFloats.clear()
    material.packUniform_(_matUboFloats)
    ubo.writeFloats(0, _matUboFloats)

    var albedoTex    = material.albedoTexture            != null ? material.albedoTexture            : _whiteTex
    var mrTex        = material.metallicRoughnessTexture != null ? material.metallicRoughnessTexture : _whiteTex
    var normalTex    = material.normalTexture            != null ? material.normalTexture            : _normalTex
    var occlusionTex = material.occlusionTexture         != null ? material.occlusionTexture         : _whiteTex
    var emissiveTex  = material.emissiveTexture          != null ? material.emissiveTexture          : _whiteTex

    var bg = _device.createBindGroup({
      "layout":  _materialBgl,
      "entries": [
        { "binding": 0, "buffer":  ubo, "size": Renderer3D.MAT_UBO_BYTES_ },
        { "binding": 1, "view":    albedoTex.createView() },
        { "binding": 2, "view":    mrTex.createView() },
        { "binding": 3, "view":    normalTex.createView() },
        { "binding": 4, "view":    occlusionTex.createView() },
        { "binding": 5, "view":    emissiveTex.createView() },
        { "binding": 6, "sampler": _sampler }
      ],
      "label": "renderer3d-mat-bg"
    })

    var entry = { "bg": bg, "ubo": ubo, "rev": material.revision_ }
    _materialCache[material] = entry
    return entry
  }

  /// Mark the end of the frame. The caller should `pass.end`
  /// after this; the renderer keeps no in-flight state between
  /// frames apart from the per-material BindGroup cache.
  endFrame() { _pass = null }

  // Mat4.data is row-major (math convention) but WGSL's
  // mat4x4<f32> consumes 16 floats as column-major. Transpose at
  // the upload boundary so the shader's M*v multiplies row 0
  // dotted with v as expected. Unrolled (no nested while). The
  // looped form miscompiled under tiered execution; see the
  // matching note in `Renderer2D.beginFrame`.
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
  // Float32Array-targeted variant of `appendMat4_`. Writes the
  // 16 transposed entries of `m` at `out[off .. off+15]`. Used
  // by the per-draw UBO scratch (a Float32Array, not a List) so
  // the upload takes the typed-array memcpy path.
  writeMat4ToScratch_(out, off, m) {
    var d = m.data
    out[off]      = d[0]
    out[off + 1]  = d[4]
    out[off + 2]  = d[8]
    out[off + 3]  = d[12]
    out[off + 4]  = d[1]
    out[off + 5]  = d[5]
    out[off + 6]  = d[9]
    out[off + 7]  = d[13]
    out[off + 8]  = d[2]
    out[off + 9]  = d[6]
    out[off + 10] = d[10]
    out[off + 11] = d[14]
    out[off + 12] = d[3]
    out[off + 13] = d[7]
    out[off + 14] = d[11]
    out[off + 15] = d[15]
  }
  appendZeros_(out, n) {
    var i = 0
    while (i < n) {
      out.add(0)
      i = i + 1
    }
  }

  /// Release every GPU resource owned by the renderer. The
  /// per-material BindGroup cache is dropped too — caller-owned
  /// `Material` instances stay alive but lose their cached bind
  /// groups.
  destroy {
    for (entry in _materialCache.values) {
      entry["ubo"].destroy
      entry["bg"].destroy
    }
    _materialCache = {}
    for (bg in _drawBindGroupPool) bg.destroy
    for (ubo in _drawUboPool)      ubo.destroy
    _drawBindGroupPool = []
    _drawUboPool = []
    _sceneUbo.destroy
    _sampler.destroy
    _whiteTex.destroy
    _normalTex.destroy
    for (bg in _instanceBgCache.values) bg.destroy
    _instanceBgCache = {}
    _instancedPipeline.destroy
    _instancedPipelineLayout.destroy
    _instancedBgl.destroy
    _pipeline.destroy
    _pipelineLayout.destroy
    _materialBgl.destroy
    _drawBgl.destroy
    _sceneBgl.destroy
  }
}
