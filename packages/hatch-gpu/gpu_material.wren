// `@hatch:gpu` Material — Cook-Torrance / GGX PBR in the glTF
// metallic-roughness workflow. Target-agnostic; imported by both
// `gpu_native` and `gpu_web`. Stores plain data + texture
// handles + a packing helper; the renderer owns the bind group
// caching.

import "@hatch:math" for Vec4

/// PBR material in the glTF metallic-roughness workflow. Each
/// property pairs a *factor* (scalar / colour multiplier) with an
/// optional *texture* — when no texture is bound the renderer
/// substitutes a 1×1 default and the factor becomes the final
/// value. The texture's contribution is always multiplied with
/// the factor, matching the glTF 2.0 spec.
///
/// ## Example
///
/// ```wren
/// var m = Material.new()
/// m.albedoColor     = Vec4.new(0.85, 0.42, 0.45, 1.0)
/// m.metallicFactor  = 0.0
/// m.roughnessFactor = 0.6
/// m.albedoTexture   = albedoTex      // optional; sRGB
/// m.normalTexture   = normalTex      // optional; linear, tangent-space
/// m.emissiveColor   = Vec4.new(0.0, 0.0, 0.0, 1.0)
/// ```
///
/// Mutations are cheap. The renderer rebuilds the material's
/// bind group lazily when a property has changed since the last
/// draw; untouched materials reuse their cached bind group.
class Material {
  /// Default: opaque white albedo, fully rough non-metal, no
  /// textures, no emission. Useful as a placeholder you mutate
  /// into the final state via setters.
  construct new() {
    _albedoColor             = Vec4.new(1.0, 1.0, 1.0, 1.0)
    _albedoTexture           = null
    _metallicFactor          = 0.0
    _roughnessFactor         = 1.0
    _metallicRoughnessTexture = null
    _normalTexture           = null
    _normalScale             = 1.0
    _occlusionTexture        = null
    _occlusionStrength       = 1.0
    _emissiveColor           = Vec4.new(0.0, 0.0, 0.0, 1.0)
    _emissiveTexture         = null
    _alphaMode               = "opaque"
    _alphaCutoff             = 0.5
    _doubleSided             = false
    _sway                    = 0.0
    _shadingModel            = "pbr"
    _bands                   = 3
    _rimStrength             = 0.0
    _rimWidth                = 4.0
    _ambientFloor            = 0.35
    _revision                = 0
  }

  /// Flat-colour material: opaque, non-metal, mid roughness, just
  /// `color` as the albedo. Quick path for procedural meshes
  /// (cubes, planes) and prototyping.
  ///
  /// @param {Vec4} color. Linear-space RGBA albedo.
  construct new(color) {
    _albedoColor             = color
    _albedoTexture           = null
    _metallicFactor          = 0.0
    _roughnessFactor         = 0.6
    _metallicRoughnessTexture = null
    _normalTexture           = null
    _normalScale             = 1.0
    _occlusionTexture        = null
    _occlusionStrength       = 1.0
    _emissiveColor           = Vec4.new(0.0, 0.0, 0.0, 1.0)
    _emissiveTexture         = null
    _alphaMode               = "opaque"
    _alphaCutoff             = 0.5
    _doubleSided             = false
    _sway                    = 0.0
    _shadingModel            = "pbr"
    _bands                   = 3
    _rimStrength             = 0.0
    _rimWidth                = 4.0
    _ambientFloor            = 0.35
    _revision                = 0
  }

  /// Wind-sway response factor. 0 = static (terrain, trunks); 1 =
  /// full sway (grass tips, leaves). The renderer multiplies this
  /// by the scene's wind strength and a per-vertex height factor,
  /// so model parts low in local Y bend less than tips.
  /// @returns {Num}
  sway     { _sway }
  sway=(v) {
    _sway = v
    _revision = _revision + 1
  }

  /// Linear-space RGBA albedo. Multiplied with `albedoTexture`'s
  /// sampled value in the shader.
  /// @returns {Vec4}
  albedoColor     { _albedoColor }
  albedoColor=(v) {
    _albedoColor = v
    _revision = _revision + 1
  }

  /// Albedo (base-colour) texture. `null` means "use albedoColor
  /// alone"; the renderer substitutes a 1×1 white texture.
  /// glTF convention: sRGB encoded.
  /// @returns {Texture}
  albedoTexture     { _albedoTexture }
  albedoTexture=(t) {
    _albedoTexture = t
    _revision = _revision + 1
  }

  /// Scalar metallicness multiplier. `0.0` = dielectric, `1.0` =
  /// fully metallic. Conductors derive their F0 from `albedoColor`
  /// (per UE4 / glTF spec); dielectrics use F0 = 0.04.
  /// @returns {Num}
  metallicFactor     { _metallicFactor }
  metallicFactor=(v) {
    _metallicFactor = v
    _revision = _revision + 1
  }

  /// Scalar roughness multiplier. `0.0` = mirror (perceptually
  /// near-zero); the shader clamps to ~0.045 to dodge BRDF
  /// singularities. `1.0` = fully rough Lambertian-ish.
  /// @returns {Num}
  roughnessFactor     { _roughnessFactor }
  roughnessFactor=(v) {
    _roughnessFactor = v
    _revision = _revision + 1
  }

  /// MetallicRoughness packed texture. glTF convention: linear,
  /// `.b` = metallic, `.g` = roughness, `.r` unused.
  /// @returns {Texture}
  metallicRoughnessTexture     { _metallicRoughnessTexture }
  metallicRoughnessTexture=(t) {
    _metallicRoughnessTexture = t
    _revision = _revision + 1
  }

  /// Tangent-space normal map. Linear (`rgba8unorm`) encoded with
  /// the conventional (xyz + 1) * 0.5 scheme; the shader decodes
  /// and scales by `normalScale` before perturbing the geometric
  /// normal.
  /// @returns {Texture}
  normalTexture     { _normalTexture }
  normalTexture=(t) {
    _normalTexture = t
    _revision = _revision + 1
  }

  /// Multiplier applied to the X / Y components of the sampled
  /// tangent-space normal. `1.0` is the spec default; `0.0`
  /// flattens out normal mapping; values >1 exaggerate.
  /// @returns {Num}
  normalScale     { _normalScale }
  normalScale=(v) {
    _normalScale = v
    _revision = _revision + 1
  }

  /// Ambient-occlusion map. Linear, `.r` channel carries the AO
  /// term; `1.0` = fully unoccluded, `0.0` = fully shadowed.
  /// Multiplied with the ambient + IBL contribution only;
  /// direct-light terms are not occluded.
  /// @returns {Texture}
  occlusionTexture     { _occlusionTexture }
  occlusionTexture=(t) {
    _occlusionTexture = t
    _revision = _revision + 1
  }

  /// Strength multiplier for the AO texture. The shader blends
  /// between `1.0` (full ambient) and the sampled AO value by
  /// `occlusionStrength`. Per glTF.
  /// @returns {Num}
  occlusionStrength     { _occlusionStrength }
  occlusionStrength=(v) {
    _occlusionStrength = v
    _revision = _revision + 1
  }

  /// Linear-space RGB emissive colour (alpha unused). Added to
  /// the final shaded colour after lighting; multiplied with the
  /// emissive texture when present.
  /// @returns {Vec4}
  emissiveColor     { _emissiveColor }
  emissiveColor=(v) {
    _emissiveColor = v
    _revision = _revision + 1
  }

  /// Emissive map. sRGB. Multiplied with `emissiveColor`; `null`
  /// falls back to a 1×1 white texture.
  /// @returns {Texture}
  emissiveTexture     { _emissiveTexture }
  emissiveTexture=(t) {
    _emissiveTexture = t
    _revision = _revision + 1
  }

  /// glTF alpha mode: `"opaque"`, `"mask"`, or `"blend"`.
  ///
  /// - `"opaque"` ignores the albedo alpha channel
  /// - `"mask"` discards fragments where `albedo.a < alphaCutoff`
  /// - `"blend"` enables standard premultiplied-alpha blending
  ///
  /// @returns {String}
  alphaMode     { _alphaMode }
  alphaMode=(v) {
    _alphaMode = v
    _revision = _revision + 1
  }

  /// Cutoff value used when `alphaMode == "mask"`. Per glTF, 0.5
  /// is the spec default.
  /// @returns {Num}
  alphaCutoff     { _alphaCutoff }
  alphaCutoff=(v) {
    _alphaCutoff = v
    _revision = _revision + 1
  }

  /// When `true` the back face is also rendered with its normal
  /// flipped. Used for foliage / cloth / paper-thin geometry.
  /// @returns {Bool}
  doubleSided     { _doubleSided }
  doubleSided=(v) {
    _doubleSided = v
    _revision = _revision + 1
  }

  // ---------------------------------------------------------------
  // Toon / cel-shading
  //
  // The renderer picks a different pipeline when `shadingModel ==
  // "toon"`. The toon shader replaces the PBR lighting model with
  // a quantised diffuse band step + optional Fresnel-driven rim
  // light, keeping albedo / emissive texture sampling intact so the
  // same Material drives either pipeline by flipping one field.
  // The parameter slots all serialise into the trailing `toon` vec4
  // of MaterialUniforms — PBR materials still write the slot (zeros)
  // for layout consistency; the PBR shader ignores it.
  // ---------------------------------------------------------------

  /// Lighting model. `"pbr"` (default) uses the Cook-Torrance / GGX
  /// metallic-roughness pipeline; `"toon"` switches to the cel-
  /// shaded pipeline (quantised diffuse + optional rim light).
  /// Unrecognised values fall back to `"pbr"`.
  /// @returns {String}
  shadingModel     { _shadingModel }
  shadingModel=(v) {
    _shadingModel = v
    _revision = _revision + 1
  }

  /// Number of diffuse light bands the toon pipeline quantises into.
  /// Integer ≥ 2; 3 is the classic three-tone cel look (highlight
  /// / mid / shadow). Higher values approach smooth Lambertian.
  /// Ignored when `shadingModel != "toon"`.
  /// @returns {Num}
  bands     { _bands }
  bands=(v) {
    _bands = v
    _revision = _revision + 1
  }

  /// Rim-light strength. 0 disables the rim; 1 saturates the
  /// silhouette in pure white-ish highlight on the side facing
  /// away from the camera. The classic anime hair / character
  /// edge highlight lands around 0.4–0.7.
  /// Ignored when `shadingModel != "toon"`.
  /// @returns {Num}
  rimStrength     { _rimStrength }
  rimStrength=(v) {
    _rimStrength = v
    _revision = _revision + 1
  }

  /// Fresnel exponent for the rim band. Higher values produce a
  /// thinner, sharper rim; lower values widen the bloom around the
  /// silhouette. Sensible range 1.5–8.0; default 4.0.
  /// Ignored when `shadingModel != "toon"`.
  /// @returns {Num}
  rimWidth     { _rimWidth }
  rimWidth=(v) {
    _rimWidth = v
    _revision = _revision + 1
  }

  /// Floor brightness on the shadow side of the diffuse step. 0
  /// produces deep black shadow; 1 disables the toon step entirely
  /// (flat lit). The cel-shaded look typically sits around 0.3–0.45 so
  /// the shadowed side reads as a darker tint of the albedo rather
  /// than a hard black silhouette.
  /// Ignored when `shadingModel != "toon"`.
  /// @returns {Num}
  ambientFloor     { _ambientFloor }
  ambientFloor=(v) {
    _ambientFloor = v
    _revision = _revision + 1
  }

  /// Internal — counter that ticks on every mutation, so the
  /// renderer can detect "this material has changed since the
  /// last time I built a bind group for it" without diffing
  /// every field.
  /// @returns {Num}
  revision_ { _revision }

  /// Internal — pack the material's plain-old-data into the
  /// 80-byte uniform block the WGSL shader expects. Texture
  /// handles aren't part of this — they bind separately.
  /// Appends 20 floats to `out` (5 vec4 rows).
  packUniform_(out) {
    out.add(_albedoColor.x)
    out.add(_albedoColor.y)
    out.add(_albedoColor.z)
    out.add(_albedoColor.w)
    out.add(_emissiveColor.x)
    out.add(_emissiveColor.y)
    out.add(_emissiveColor.z)
    out.add(_emissiveColor.w)
    out.add(_metallicFactor)
    out.add(_roughnessFactor)
    out.add(_normalScale)
    out.add(_occlusionStrength)
    var modeIdx = 0
    if (_alphaMode == "mask")  modeIdx = 1
    if (_alphaMode == "blend") modeIdx = 2
    out.add(modeIdx)
    out.add(_alphaCutoff)
    out.add(_doubleSided ? 1.0 : 0.0)
    // `alpha.w` repurposed as the wind-sway factor — the renderer's
    // vertex shader uses it to bend the mesh with the scene's wind.
    out.add(_sway)
    // Toon vec4 (read by the cel-shaded pipeline, ignored by PBR):
    //   x = band count, y = rim strength, z = rim width (Fresnel
    //   exponent), w = ambient floor. PBR materials still emit the
    //   slot so the UBO layout stays uniform across pipelines.
    out.add(_bands)
    out.add(_rimStrength)
    out.add(_rimWidth)
    out.add(_ambientFloor)
  }

  /// Legacy compatibility — `color` was the only knob on the
  /// previous flat-colour Material. Reads return the linear-space
  /// albedo; writes set the albedo colour and mark the material
  /// dirty.
  ///
  /// @returns {Vec4}
  color    { _albedoColor }
  color=(c) {
    _albedoColor = c
    _revision = _revision + 1
  }
}
