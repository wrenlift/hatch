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
      };
      struct DrawUniforms {
        model: mat4x4<f32>,
      };
      @group(0) @binding(0) var<uniform> scene: SceneUniforms;
      @group(1) @binding(0) var<uniform> draw_u: DrawUniforms;

      // Sum-of-sines wave height. Cheap, periodic, no lookup tables.
      // Three octaves of doubling frequency / halving amplitude
      // give enough chop to read as water without LF artefacts.
      fn wave_height(x: f32, z: f32) -> f32 {
        let a   = scene.time_amp_scale.y;
        let s   = scene.time_amp_scale.z;
        let ts  = scene.time_amp_scale.w;
        let t   = scene.time_amp_scale.x;
        var h: f32 = 0.0;
        h = h + a       * sin(x *  s        + t * ts);
        h = h + a * 0.5 * sin(z *  s * 1.7  + t * ts * 1.3);
        h = h + a * 0.25* sin((x + z) * s * 3.1 + t * ts * 0.7);
        return h;
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

        var o: VsOut;
        o.clip   = scene.vp * vec4<f32>(displaced, 1.0);
        o.world  = displaced;
        o.normal = n;
        o.uv     = in.uv;
        return o;
      }

      @fragment
      fn fs_main(in: VsOut) -> @location(0) vec4<f32> {
        let N = normalize(in.normal);
        let V = normalize(scene.camera_pos.xyz - in.world);
        let NdotV = max(dot(N, V), 0.0);

        // Schlick fresnel. The sky.a slot tunes the falloff
        // exponent so callers can dial in a near-constant base
        // colour (low exponent) or a strong horizon glow at
        // grazing angles (high exponent).
        let fres = pow(1.0 - NdotV, scene.sky.a);
        let base = scene.colors.rgb;
        let sky  = scene.sky.rgb;
        let body = mix(base, sky, fres);

        // Lambert + Blinn-Phong specular against the configured
        // sun direction. Specular sits on the crests because the
        // gradient normal lifts there.
        let L = normalize(-scene.sun_dir.xyz);
        let NdotL = max(dot(N, L), 0.0);
        let H = normalize(L + V);
        let NdotH = max(dot(N, H), 0.0);
        let spec = pow(NdotH, 128.0) * scene.sun_dir.w;
        let diffuse = body * (NdotL * scene.sun_color.rgb + scene.ambient.rgb);
        let rgb = diffuse + spec * scene.sun_color.rgb;
        return vec4<f32>(rgb, scene.colors.a);
      }
    "
  }

  // Scene UBO byte size — 6 × vec4 (96) + mat4x4 (64) = 160. Padded
  // to 256 so any future field added inside the 16-byte alignment
  // rule has room without a wgpu validation error mid-flight.
  static SCENE_UBO_BYTES_ { 256 }
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
        { "binding": 0, "visibility": ["vertex", "fragment"], "kind": "uniform" }
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
        "targets": [{ "format": surfaceFormat }]
      },
      "primitive":    { "topology": "triangle-list", "cullMode": "back" },
      "depthStencil": {
        "format": depthFormat, "depthWriteEnabled": true,
        "depthCompare": "less"
      },
      "label": "water-pipeline"
    })

    _sceneUbo = device.createBuffer({
      "size":  WaterPipeline.SCENE_UBO_BYTES_,
      "usage": ["uniform", "copy-dst"],
      "label": "water-scene-ubo"
    })
    _sceneBindGroup = device.createBindGroup({
      "layout":  _sceneBgl,
      "entries": [{ "binding": 0, "buffer": _sceneUbo, "size": WaterPipeline.SCENE_UBO_BYTES_ }]
    })

    // Per-draw UBO pool (one slot per draw in a frame). Same
    // rationale as Renderer3D's pool: queue.write_buffer doesn't
    // sync between draw calls so we can't reuse one UBO across
    // draws; growth is lazy + bounded.
    _drawUboPool       = []
    _drawBindGroupPool = []
    _drawIndex         = 0

    // Default sun + look knobs — overridable via setSun / setWave /
    // setColors. The defaults render as a calm midday lake.
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

    // Pack 160 bytes (we allocated 256; the tail is unused).
    // Layout matches the WGSL SceneUniforms struct above.
    var floats = []
    appendMat4_(floats, camera.viewProj)
    // camera_pos
    var eye = camera.eye
    floats.add(eye.x)
    floats.add(eye.y)
    floats.add(eye.z)
    floats.add(1)
    // sun_dir.xyz + intensity
    floats.add(_sunDir[0])
    floats.add(_sunDir[1])
    floats.add(_sunDir[2])
    floats.add(_sunInt)
    // sun_color + pad
    floats.add(_sunColor[0])
    floats.add(_sunColor[1])
    floats.add(_sunColor[2])
    floats.add(0)
    // ambient + pad
    floats.add(_ambient[0])
    floats.add(_ambient[1])
    floats.add(_ambient[2])
    floats.add(0)
    // time / amp / scale / timeScale
    floats.add(time)
    floats.add(_waveAmp)
    floats.add(_waveScale)
    floats.add(_waveTime)
    // base colour
    floats.add(_baseColor[0])
    floats.add(_baseColor[1])
    floats.add(_baseColor[2])
    floats.add(_baseColor[3])
    // sky colour + fresnel exponent in .a
    floats.add(_skyColor[0])
    floats.add(_skyColor[1])
    floats.add(_skyColor[2])
    floats.add(_fresnelPow)
    _sceneUbo.writeFloats(0, floats)

    pass.setPipeline(_pipeline)
    pass.setBindGroup(0, _sceneBindGroup)
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
    _pipeline.destroy
    _pipelineLayout.destroy
    _drawBgl.destroy
    _sceneBgl.destroy
  }
}
