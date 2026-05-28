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

import "@hatch:math"    for Vec3
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
  //       + dir × 32 + point × 32 + spot × 64
  //       = 112 + 128 + 256 + 256 = 752 bytes.
  static SCENE_UBO_BYTES_ { 752 }
  static DRAW_UBO_BYTES_  { 128 }       // model(64) + normal_mat(64)
  static MAT_UBO_BYTES_   { 64 }        // 4 vec4s

  // Pipeline-specific WGSL — structs, bindings, and entry points.
  // Composed with the `Shader` factory library that supplies
  // PBR BRDF, normal-mapping and tonemapping helpers.
  static PBR_WGSL_ {
    return "
      struct SceneUniforms {
        vp:           mat4x4<f32>,
        camera_pos:   vec4<f32>,
        ambient:      vec4<f32>,
        counts:       vec4<f32>,
        dir_lights:   array<DirLight,   4>,
        point_lights: array<PointLight, 8>,
        spot_lights:  array<SpotLight,  4>,
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
      @group(1) @binding(0) var<uniform> draw_u: DrawUniforms;
      @group(2) @binding(0) var<uniform> mat: MaterialUniforms;
      @group(2) @binding(1) var albedo_tex:    texture_2d<f32>;
      @group(2) @binding(2) var mr_tex:        texture_2d<f32>;
      @group(2) @binding(3) var normal_tex:    texture_2d<f32>;
      @group(2) @binding(4) var occlusion_tex: texture_2d<f32>;
      @group(2) @binding(5) var emissive_tex:  texture_2d<f32>;
      @group(2) @binding(6) var samp:          sampler;

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

      @vertex
      fn vs_main(in: VsIn) -> VsOut {
        var o: VsOut;
        let world_pos  = draw_u.model * vec4<f32>(in.pos, 1.0);
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
          let radiance = dl.color.rgb * dl.dir_intensity.w;
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
        { "binding": 0, "visibility": ["vertex", "fragment"], "kind": "uniform" }
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
        { "binding": 0, "visibility": ["fragment"], "kind": "uniform" },
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

    _sceneUbo = device.createBuffer({
      "size":  Renderer3D.SCENE_UBO_BYTES_,
      "usage": ["uniform", "copy-dst"],
      "label": "renderer3d-scene-ubo"
    })
    _drawUbo = device.createBuffer({
      "size":  Renderer3D.DRAW_UBO_BYTES_,
      "usage": ["uniform", "copy-dst"],
      "label": "renderer3d-draw-ubo"
    })

    _sceneBindGroup = device.createBindGroup({
      "layout":  _sceneBgl,
      "entries": [{ "binding": 0, "buffer": _sceneUbo, "size": Renderer3D.SCENE_UBO_BYTES_ }]
    })
    _drawBindGroup = device.createBindGroup({
      "layout":  _drawBgl,
      "entries": [{ "binding": 0, "buffer": _drawUbo, "size": Renderer3D.DRAW_UBO_BYTES_ }]
    })

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
    _whiteTex  = makeFallback_(device, 255, 255, 255, 255)            // albedo / mr / occlusion / emissive
    _normalTex = makeFallback_(device, 128, 128, 255, 255)             // tangent-space up: (0.5, 0.5, 1)

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
    _dirLights   = []   // each: { dir: Vec3, color: Vec3, intensity: Num }
    _pointLights = []   // each: { pos, color, intensity, range }
    _spotLights  = []   // each: { pos, dir, color, intensity, range, innerCos, outerCos }
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

    pass.setPipeline(_pipeline)
    pass.setBindGroup(0, _sceneBindGroup)
    pass.setBindGroup(1, _drawBindGroup)
  }

  /// Set the scene-wide ambient term. Replaces previous calls
  /// within the frame; the renderer commits the value into the
  /// scene uniform on the first draw.
  ///
  /// @param {Vec3} color. Linear-space RGB.
  /// @param {Num} intensity. Scalar multiplier.
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
    if (_dirLights.count >= Renderer3D.MAX_DIR_LIGHTS_) {
      _overflow = (_overflow == null ? 0 : _overflow) + 1
      return
    }
    _dirLights.add({
      "dir":       direction,
      "color":     color,
      "intensity": intensity,
    })
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
    _drawUbo.writeFloats(0, _drawUboFloats)

    // Resolve material bind group; rebuild on revision change.
    var entry = bindGroupFor_(material)
    var pass = _pass
    pass.setBindGroup(2, entry["bg"])
    pass.setVertexBuffer(0, mesh.vertexBuffer)
    pass.setIndexBuffer(mesh.indexBuffer, "uint32")
    pass.drawIndexed(mesh.indexCount)
  }

  commitScene_ {
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
    // counts (dir, point, spot, pad)
    _sceneUboFloats.add(_dirLights.count)
    _sceneUboFloats.add(_pointLights.count)
    _sceneUboFloats.add(_spotLights.count)
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
    _sceneUbo.destroy
    _drawUbo.destroy
    _sampler.destroy
    _whiteTex.destroy
    _normalTex.destroy
    _pipeline.destroy
    _pipelineLayout.destroy
    _materialBgl.destroy
    _drawBgl.destroy
    _sceneBgl.destroy
  }
}
