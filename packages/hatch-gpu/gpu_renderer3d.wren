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
/// - Group 2 (material): 64-byte material uniform + 5 textures
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
  static FLOATS_PER_VERTEX_ { 8 }

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
  //       + light_vp(64) + shadow_params(16)
  //       + dir × 32 + point × 32 + spot × 64
  //       = 112 + 80 + 128 + 256 + 256 = 832 bytes.
  static SCENE_UBO_BYTES_  { 848 }
  static DRAW_UBO_BYTES_   { 128 }       // model(64) + normal_mat(64)
  static MAT_UBO_BYTES_    { 64 }        // 4 vec4s
  static SHADOW_UBO_BYTES_ { 128 }       // light_vp(64) + model(64) per draw

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
        @location(0) pos:    vec3<f32>,
        @location(1) normal: vec3<f32>,
        @location(2) uv:     vec2<f32>,
      };
      struct VsOut {
        @builtin(position) clip:   vec4<f32>,
        @location(0)       world:  vec3<f32>,
        @location(1)       normal: vec3<f32>,
        @location(2)       uv:     vec2<f32>,
      };

      // Apply wind-driven sway to a model-local vertex. Bends the
      // mesh in the wind direction proportionally to the vertex's
      // local-Y (so the base stays put and the tip moves most). A
      // world-space phase term decorrelates neighbouring instances
      // so the field doesn't sway in lockstep.
      fn apply_sway(local_pos: vec3<f32>, anchor_world: vec3<f32>, sway: f32) -> vec3<f32> {
        if (sway <= 0.0) { return local_pos; }
        let phase = anchor_world.x * 0.45 + anchor_world.z * 0.37 + scene.wind.z * 2.6;
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
        // Anchor world position of the instance origin (so all
        // vertices of one instance share the same phase) — read
        // from model's translation column.
        let anchor = vec3<f32>(draw_u.model[3].x, draw_u.model[3].y, draw_u.model[3].z);
        let local_swayed = apply_sway(in.pos, anchor, mat.alpha.w);
        let world_pos  = draw_u.model * vec4<f32>(local_swayed, 1.0);
        let world_norm = (draw_u.normal_mat * vec4<f32>(in.normal, 0.0)).xyz;
        o.clip   = scene.vp * world_pos;
        o.world  = world_pos.xyz;
        o.normal = world_norm;
        o.uv     = in.uv;
        return o;
      }

      @fragment
      fn fs_main(in: VsOut) -> @location(0) vec4<f32> {
        // 1. Albedo: factor × texture. Texture sampled as sRGB
        //    (the shader expects linear input — when the host
        //    creates the texture with `*-srgb` format, the
        //    sampler does the decode; otherwise we'd `srgb_to_linear`).
        let albedo_sample = textureSample(albedo_tex, samp, in.uv);
        let base_color = mat.albedo_color * albedo_sample;

        // 2. Alpha mask: glTF spec says mask = discard below cutoff.
        let alpha_mode = mat.alpha.x;
        if (alpha_mode == 1.0 && base_color.a < mat.alpha.y) {
          discard;
        }

        // 3. Metallic + roughness: factor × MR.b / MR.g per glTF.
        let mr_sample = textureSample(mr_tex, samp, in.uv);
        let metallic  = mat.factors.x * mr_sample.b;
        let roughness = mat.factors.y * mr_sample.g;

        // 4. Normal: sample tangent-space xy, perturb the geo normal.
        let N0 = normalize(in.normal);
        let n_sample = textureSample(normal_tex, samp, in.uv).xy * 2.0 - vec2<f32>(1.0);
        let N = perturb_normal(N0, in.world, in.uv, n_sample, mat.factors.z);

        // 5. View direction.
        let V = normalize(scene.camera_pos.xyz - in.world);

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
            radiance = radiance * shadow_factor(in.world, N, L);
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

        // 7. Ambient + AO. Treat ambient as a cheap IBL stand-in
        //    — multiplied with base_color so dielectric tint
        //    surfaces still pick up the sky / room colour.
        let ao_sample = textureSample(occlusion_tex, samp, in.uv).r;
        let ao = mix(1.0, ao_sample, mat.factors.w);
        let ambient_term = scene.ambient.rgb * base_color.rgb * ao;

        // 8. Emissive. Added on top — never tonemapped against
        //    indirectly, but the final ACES pass still touches it.
        let emissive_sample = textureSample(emissive_tex, samp, in.uv).rgb;
        let emissive = mat.emissive_color.rgb * emissive_sample;

        // 9. Tonemap + alpha output.
        let hdr = Lo + ambient_term + emissive;
        let ldr = tonemap_aces(hdr);
        return vec4<f32>(ldr, base_color.a);
      }
    "
  }

  // Instanced PBR shader. Same fragment shader + struct surface as
  // PBR_WGSL_; the difference is the vertex stage reads `model` +
  // `normal_mat` out of a storage-buffer array indexed by
  // `@builtin(instance_index)` instead of the per-draw uniform.
  // One drawIndexed call covers an arbitrary number of instances,
  // and the storage buffer can be the direct output of a compute
  // pass (transform writers, culling, LOD selection).
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
        @location(0) pos:    vec3<f32>,
        @location(1) normal: vec3<f32>,
        @location(2) uv:     vec2<f32>,
      };
      struct VsOut {
        @builtin(position) clip:   vec4<f32>,
        @location(0)       world:  vec3<f32>,
        @location(1)       normal: vec3<f32>,
        @location(2)       uv:     vec2<f32>,
      };

      fn apply_sway(local_pos: vec3<f32>, anchor_world: vec3<f32>, sway: f32) -> vec3<f32> {
        if (sway <= 0.0) { return local_pos; }
        let phase = anchor_world.x * 0.45 + anchor_world.z * 0.37 + scene.wind.z * 2.6;
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
        o.clip   = scene.vp * world_pos;
        o.world  = world_pos.xyz;
        o.normal = world_norm;
        o.uv     = in.uv;
        return o;
      }

      @fragment
      fn fs_main(in: VsOut) -> @location(0) vec4<f32> {
        let albedo_sample = textureSample(albedo_tex, samp, in.uv);
        let base_color = mat.albedo_color * albedo_sample;
        let alpha_mode = mat.alpha.x;
        if (alpha_mode == 1.0 && base_color.a < mat.alpha.y) { discard; }

        let mr_sample = textureSample(mr_tex, samp, in.uv);
        let metallic  = mat.factors.x * mr_sample.b;
        let roughness = mat.factors.y * mr_sample.g;

        let N0 = normalize(in.normal);
        let n_sample = textureSample(normal_tex, samp, in.uv).xy * 2.0 - vec2<f32>(1.0);
        let N = perturb_normal(N0, in.world, in.uv, n_sample, mat.factors.z);

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

        let ao_sample = textureSample(occlusion_tex, samp, in.uv).r;
        let ao = mix(1.0, ao_sample, mat.factors.w);
        let ambient_term = scene.ambient.rgb * base_color.rgb * ao;
        let emissive_sample = textureSample(emissive_tex, samp, in.uv).rgb;
        let emissive = mat.emissive_color.rgb * emissive_sample;
        let hdr = Lo + ambient_term + emissive;
        let ldr = tonemap_aces(hdr);
        return vec4<f32>(ldr, base_color.a);
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

      struct VsIn {
        @location(0) pos:    vec3<f32>,
        @location(1) normal: vec3<f32>,
        @location(2) uv:     vec2<f32>,
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

      struct VsIn {
        @location(0) pos:    vec3<f32>,
        @location(1) normal: vec3<f32>,
        @location(2) uv:     vec2<f32>,
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
  construct new(device, surfaceFormat, depthFormat) {
    _device = device

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
            { "shaderLocation": 2, "offset": 24, "format": "float32x2" }
          ]
        }]
      },
      "fragment": {
        "module": shader, "entryPoint": "fs_main",
        "targets": [{ "format": surfaceFormat }]
      },
      "primitive":    { "topology": "triangle-list", "cullMode": "back" },
      "depthStencil": {
        "format": depthFormat, "depthWriteEnabled": true,
        "depthCompare": "less"
      },
      "label": "renderer3d-pipeline"
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
            { "shaderLocation": 2, "offset": 24, "format": "float32x2" }
          ]
        }]
      },
      "fragment": {
        "module": instancedShader, "entryPoint": "fs_main",
        "targets": [{ "format": surfaceFormat }]
      },
      "primitive":    { "topology": "triangle-list", "cullMode": "back" },
      "depthStencil": {
        "format": depthFormat, "depthWriteEnabled": true,
        "depthCompare": "less"
      },
      "label": "renderer3d-instanced-pipeline"
    })
    // Bind-group cache keyed by instance-storage-buffer id. Avoids
    // re-binding on hot redraws of the same instance set.
    _instanceBgCache = {}

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
    // draws in a frame; each draw needs its own. The pool grows
    // lazily (first frame creates as many as the scene needs,
    // subsequent frames reuse) so steady-state per-frame cost
    // stays at `writeFloats` calls only.
    _drawUboPool       = []   // List of Buffer
    _drawBindGroupPool = []   // List of BindGroup, indexed in lockstep with _drawUboPool
    _drawIndex         = 0

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
    _drawUboFloats = []     // packing scratchpad — reused per draw
    _sceneUboFloats = []    // packing scratchpad — reused per beginFrame

    _pass    = null
    _ambient = Vec3.new(0.0, 0.0, 0.0)
    _ambientIntensity = 0.0
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
            { "shaderLocation": 2, "offset": 24, "format": "float32x2" }
          ]
        }]
      },
      // No fragment block — depth-only pass writes nothing to
      // colour attachments (there are none on the shadow pass).
      "primitive":    { "topology": "triangle-list", "cullMode": "front" },
      "depthStencil": {
        "format": _shadowDepthFormat,
        "depthWriteEnabled": true,
        "depthCompare": "less"
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
            { "shaderLocation": 2, "offset": 24, "format": "float32x2" }
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
    _drawUboFloats.clear()
    appendMat4_(_drawUboFloats, model)
    appendMat4_(_drawUboFloats, model)

    // Pull (or grow) the per-draw UBO slot for this index.
    // Sharing one UBO across draws within a frame collapses
    // every model matrix to the last `writeFloats` call — see
    // pool comment in the constructor.
    var i = reserveDrawSlot_()
    _drawUboPool[i].writeFloats(0, _drawUboFloats)

    // Resolve material bind group; rebuild on revision change.
    var entry = bindGroupFor_(material)
    var pass = _pass
    pass.setPipeline(_pipeline)
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
    pass.setPipeline(_instancedPipeline)
    pass.setBindGroup(0, _sceneBindGroup)
    pass.setBindGroup(1, instanceBindGroupFor_(instanceBuffer))
    pass.setBindGroup(2, entry["bg"])
    pass.setVertexBuffer(0, mesh.vertexBuffer)
    pass.setIndexBuffer(mesh.indexBuffer, "uint32")
    pass.drawIndexed(mesh.indexCount, instanceCount)
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
    // shadow_params: x = depth bias, y = PCF radius, z/w reserved.
    _sceneUboFloats.add(_shadowBias)
    _sceneUboFloats.add(_shadowPcfRadius)
    _sceneUboFloats.add(0)
    _sceneUboFloats.add(0)
    // wind: xy = direction (xz plane), z = time, w = strength.
    // Vertex shaders multiply this by per-material `sway` and a
    // per-vertex local-Y factor to bend foliage in the wind.
    _sceneUboFloats.add(_windDirX)
    _sceneUboFloats.add(_windDirZ)
    _sceneUboFloats.add(_windTime)
    _sceneUboFloats.add(_windStrength)
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
