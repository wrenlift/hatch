// `@hatch:gpu` Shader factory.
//
// Target-agnostic: pure WGSL string composition + a thin
// `Device.createShaderModule` pass-through. Imported by both
// `gpu_native` and `gpu_web` so the WGSL fragment library only
// lives in one place.

/// Static library of reusable WGSL fragments plus a composition
/// helper. Pipelines describe themselves as a list of named
/// fragments + their own struct / binding / entry-point code;
/// the factory concatenates them in declaration order and hands
/// the result to `Device.createShaderModule`. Keeps per-pipeline
/// shader source small and lets BRDF / normal-mapping /
/// tonemapping math live in one place instead of being copied
/// into every renderer's inline string.
///
/// ## Example
///
/// ```wren
/// var shader = Shader.module(device, [
///   Shader.prelude,
///   Shader.lightTypes,
///   Shader.pbrBrdf,
///   Shader.lightAttenuation,
///   Shader.normalMapping,
///   Shader.tonemapping,
///   Renderer3D.PBR_WGSL_,
/// ], "renderer3d-pbr")
/// ```
class Shader {
  /// Math constants + small ergonomic helpers (`saturate`,
  /// `srgb_to_linear`, `linear_to_srgb`). Always include first;
  /// downstream fragments lean on `PI` and `saturate`.
  static prelude {
    return "
      const PI: f32 = 3.14159265359;
      const EPSILON: f32 = 0.0001;

      fn saturate(x: f32) -> f32 { return clamp(x, 0.0, 1.0); }

      // sRGB → linear, per-channel. Used to decode 8-bit
      // texture samples when the host doesn't tag them as sRGB.
      fn srgb_to_linear(c: vec3<f32>) -> vec3<f32> {
        let cutoff = vec3<f32>(0.04045);
        let high = pow((c + vec3<f32>(0.055)) / vec3<f32>(1.055), vec3<f32>(2.4));
        let low  = c / vec3<f32>(12.92);
        return select(high, low, c <= cutoff);
      }

      // linear → sRGB, per-channel. Used right before output if
      // the swap-chain format isn't sRGB-tagged.
      fn linear_to_srgb(c: vec3<f32>) -> vec3<f32> {
        let cutoff = vec3<f32>(0.0031308);
        let high = vec3<f32>(1.055) * pow(c, vec3<f32>(1.0 / 2.4)) - vec3<f32>(0.055);
        let low  = c * vec3<f32>(12.92);
        return select(high, low, c <= cutoff);
      }
    "
  }

  /// WGSL struct definitions for the three light kinds. Mirrors
  /// the per-frame uniform layout the renderer fills in: each
  /// kind packs its hot data into two or three `vec4`s so the
  /// uniform block stays std140-friendly.
  ///
  /// - `DirLight`: `dir_intensity.xyz` = direction the light
  ///   travels in, `w` = intensity. `color.xyz` = linear RGB.
  /// - `PointLight`: `pos_range.xyz` = world position, `w` = range
  ///   cap (0 = unbounded). `color_intensity.xyz` = colour, `w` =
  ///   intensity.
  /// - `SpotLight`: same as `PointLight` plus `dir_inner.xyz` =
  ///   forward, `w` = cos(innerAngle); `outer_cos.x` =
  ///   cos(outerAngle).
  static lightTypes {
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
    "
  }

  /// Distance + spot-cone attenuation helpers.
  ///
  /// - `distance_attenuation(distance, range)`: inverse-square
  ///   with a smooth window over the last 10 % of `range`. When
  ///   `range == 0` the window collapses and the fall-off stays
  ///   pure inverse-square.
  /// - `spot_attenuation(L, light_dir, inner_cos, outer_cos)`:
  ///   smoothstep'd cone falloff between the inner and outer
  ///   half-angles.
  static lightAttenuation {
    return "
      fn distance_attenuation(distance: f32, range: f32) -> f32 {
        let inv_sqr = 1.0 / max(distance * distance, EPSILON);
        if (range <= 0.0) {
          return inv_sqr;
        }
        // Smooth window: 1.0 inside `0.9 * range`, smoothstep to
        // 0 between `0.9 * range` and `range`. Same shape glTF /
        // Filament use.
        let r = distance / range;
        let window = 1.0 - smoothstep(0.9, 1.0, r);
        return inv_sqr * window;
      }

      fn spot_attenuation(L: vec3<f32>, light_dir: vec3<f32>, inner_cos: f32, outer_cos: f32) -> f32 {
        // L points from surface → light. The spot's forward axis
        // is `light_dir`; cone is centred on `-light_dir`.
        let cos_angle = dot(-light_dir, L);
        if (cos_angle <= outer_cos) { return 0.0; }
        if (cos_angle >= inner_cos) { return 1.0; }
        let t = (cos_angle - outer_cos) / max(inner_cos - outer_cos, EPSILON);
        return t * t * (3.0 - 2.0 * t);  // smoothstep
      }
    "
  }

  /// Cook-Torrance / GGX / Smith / Schlick PBR BRDF. Exposes one
  /// entry point — `pbr_direct(N, V, L, base_color, metallic,
  /// roughness, radiance)` — which returns the per-light shaded
  /// outgoing radiance (diffuse + specular, energy-conserved).
  /// Callers sum its return value over every active light, then
  /// add ambient + emissive separately.
  static pbrBrdf {
    return "
      fn ggx_distribution(NoH: f32, alpha: f32) -> f32 {
        let a2 = alpha * alpha;
        let f = (NoH * a2 - NoH) * NoH + 1.0;
        return a2 / (PI * f * f + EPSILON);
      }

      // Smith joint-visibility term, height-correlated GGX. Matches
      // Filament / UE4's `V_SmithGGXCorrelated`.
      fn smith_g(NoV: f32, NoL: f32, alpha: f32) -> f32 {
        let a2 = alpha * alpha;
        let GGXV = NoL * sqrt(NoV * NoV * (1.0 - a2) + a2);
        let GGXL = NoV * sqrt(NoL * NoL * (1.0 - a2) + a2);
        return 0.5 / max(GGXV + GGXL, EPSILON);
      }

      fn schlick_fresnel(VoH: f32, F0: vec3<f32>) -> vec3<f32> {
        let f = pow(saturate(1.0 - VoH), 5.0);
        return F0 + (vec3<f32>(1.0) - F0) * f;
      }

      // Per-light outgoing radiance: BRDF * NoL * radiance, where
      // BRDF = diffuse + specular. Energy conservation: the
      // diffuse term is dimmed by `1 - F` (Fresnel-reflected
      // energy can't also diffuse) and `1 - metallic` (metals
      // have no diffuse). Roughness floor at 0.045² to dodge the
      // mirror singularity in D and G.
      fn pbr_direct(
        N: vec3<f32>,
        V: vec3<f32>,
        L: vec3<f32>,
        base_color: vec3<f32>,
        metallic: f32,
        roughness: f32,
        radiance: vec3<f32>,
      ) -> vec3<f32> {
        let NoL = saturate(dot(N, L));
        if (NoL <= 0.0) { return vec3<f32>(0.0); }

        let H   = normalize(V + L);
        let NoV = saturate(dot(N, V));
        let NoH = saturate(dot(N, H));
        let VoH = saturate(dot(V, H));

        // Perceptual roughness → linear (alpha) per UE4.
        let perceptual = max(roughness, 0.045);
        let alpha = perceptual * perceptual;

        // Conductors derive F0 from albedo; dielectrics use 0.04.
        let F0 = mix(vec3<f32>(0.04), base_color, metallic);

        let D = ggx_distribution(NoH, alpha);
        let G = smith_g(NoV, NoL, alpha);
        let F = schlick_fresnel(VoH, F0);

        let specular = D * G * F;
        let diffuse  = (vec3<f32>(1.0) - F) * (1.0 - metallic) * base_color / PI;

        return (diffuse + specular) * NoL * radiance;
      }
    "
  }

  /// Tangent-space normal-map perturbation that derives the
  /// tangent frame from screen-space position + UV derivatives —
  /// no `TANGENT` vertex attribute required. Approximate but
  /// matches Christian Schüler's standard formulation; close
  /// enough for typical glTF assets.
  ///
  /// Exposes `perturb_normal(N, world_pos, uv, sampled_n_xy,
  /// scale)`. `sampled_n_xy` is the decoded tangent-space normal
  /// in the range [-1, 1]; the function reconstructs `z` from
  /// the unit constraint, then transforms into world space.
  static normalMapping {
    return "
      fn perturb_normal(
        N: vec3<f32>,
        world_pos: vec3<f32>,
        uv: vec2<f32>,
        sampled_xy: vec2<f32>,
        scale: f32,
      ) -> vec3<f32> {
        // Reconstruct tangent-space normal: clamp the XY into the
        // unit disk, derive Z from sqrt(1 - x² - y²).
        let xy = sampled_xy * scale;
        let z = sqrt(saturate(1.0 - dot(xy, xy)));
        let n_t = vec3<f32>(xy, z);

        // Screen-space-derivative tangent frame. dp1 / dp2 are the
        // world-pos gradients; duv1 / duv2 are the uv gradients.
        let dp1  = dpdx(world_pos);
        let dp2  = dpdy(world_pos);
        let duv1 = dpdx(uv);
        let duv2 = dpdy(uv);

        // Cotangent-frame basis vectors (Schüler 2013). Avoid
        // matrix inverse with cross-products into the normal.
        let dp2perp = cross(dp2, N);
        let dp1perp = cross(N, dp1);
        let T = dp2perp * duv1.x + dp1perp * duv2.x;
        let B = dp2perp * duv1.y + dp1perp * duv2.y;
        let invmax = inverseSqrt(max(dot(T, T), dot(B, B)));
        let tbn = mat3x3<f32>(T * invmax, B * invmax, N);

        return normalize(tbn * n_t);
      }
    "
  }

  /// ACES filmic tonemapper (the cheap Krzysztof Narkowicz
  /// approximation, not the full RRT+ODT chain). Compresses HDR
  /// scene colour into [0, 1] before the swap-chain encode.
  static tonemapping {
    return "
      fn tonemap_aces(c: vec3<f32>) -> vec3<f32> {
        let a = 2.51;
        let b = 0.03;
        let cc = 2.43;
        let d = 0.59;
        let e = 0.14;
        // clamp(vec3, scalar, scalar) broadcasts the bounds —
        // `saturate` in the prelude is the f32-only helper.
        return clamp((c * (a * c + b)) / (c * (cc * c + d) + e),
                     vec3<f32>(0.0), vec3<f32>(1.0));
      }

      fn tonemap_reinhard(c: vec3<f32>) -> vec3<f32> {
        return c / (c + vec3<f32>(1.0));
      }
    "
  }

  /// Concatenate `parts` (List<String>) into a single WGSL
  /// source string, joining with newlines so the per-part line
  /// numbers in compiler errors stay close to source.
  ///
  /// @param {List<String>} parts. Each fragment of WGSL.
  /// @returns {String}
  static compose(parts) {
    var out = ""
    var i = 0
    while (i < parts.count) {
      out = out + parts[i] + "\n"
      i = i + 1
    }
    return out
  }

  /// Compose `parts` + compile against `device` in one call.
  ///
  /// @param {Device} device. Backend-specific device handle
  ///   exposing `createShaderModule({"code", "label"})`.
  /// @param {List<String>} parts. Each fragment of WGSL.
  /// @param {String} label. Shader module label passed to the
  ///   wgpu backend (shows up in `Renderdoc` / `Xcode`).
  /// @returns {ShaderModule}
  static module(device, parts, label) {
    return device.createShaderModule({
      "code":  compose(parts),
      "label": label,
    })
  }
}
