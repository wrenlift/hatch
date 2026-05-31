//! `@hatch:game` — Skybox pipeline. Stylised cartoon sky for the
//! Quaternius-flavoured procedural-world look: zenith/mid/horizon
//! gradient, sun disk + halo, FBM cumulus clouds drifting on a
//! wind vector at a configurable altitude band.
//!
//! Composes with `WaterPipeline` and the standard pass-1 layout —
//! call `beginFrame / draw / endFrame` as the FIRST draw of the
//! frame's main pass, before terrain. The shader emits clip.z=1
//! (far plane) and the pipeline uses `depthCompare: "less-equal"`
//! + `depthWriteEnabled: true`, so any later geometry overwrites
//! the sky on its own pixels via the standard `"less"` test.

import "@hatch:gpu"  for Gpu
import "@hatch:math" for Vec3

/// Stylised cartoon skybox: 3-band gradient + procedural sun + FBM
/// clouds. Draws a single fullscreen triangle; cost is independent
/// of scene complexity.
class SkyboxPipeline {
  // 10 vec4 in the scene UBO = 160 B, padded to 256 B for std140
  // parity with `WaterPipeline.SCENE_UBO_BYTES_`.
  static SCENE_UBO_BYTES_ { 256 }

  // ── Build ───────────────────────────────────────────────────────

  /// Build against `device`. `surfaceFormat` is the colour-target
  /// format (`g.surfaceFormat` under both PostFX and direct-to-swap
  /// configurations — pass-1's colour attachment matches that
  /// format). `depthFormat` is the depth attachment format
  /// (`g.depthFormat`); pass `null` to disable depth testing.
  ///
  /// @param {Device} device
  /// @param {String} surfaceFormat
  /// @param {String | null} depthFormat
  construct new(device, surfaceFormat, depthFormat) {
    _device = device
    var shader = device.createShaderModule({
      "code":  SkyboxPipeline.SHADER_WGSL_,
      "label": "sky-shader"
    })
    _sceneBgl = device.createBindGroupLayout({
      "entries": [
        { "binding": 0, "visibility": ["vertex", "fragment"], "kind": "uniform" }
      ],
      "label": "sky-scene-bgl"
    })
    _pipelineLayout = device.createPipelineLayout({
      "bindGroupLayouts": [_sceneBgl],
      "label":            "sky-pipeline-layout"
    })

    var pipelineDesc = {
      "layout":   _pipelineLayout,
      "vertex":   { "module": shader, "entryPoint": "vs_main", "buffers": [] },
      "fragment": {
        "module":     shader,
        "entryPoint": "fs_main",
        "targets":    [{ "format": surfaceFormat }]
      },
      "primitive": { "topology": "triangle-list", "cullMode": "none" },
      "label":     "sky-pipeline"
    }
    if (depthFormat != null) {
      // depthCompare "less-equal" because the shader emits clip.z=1
      // and pass 1 clears depth to 1.0 — a plain "less" rejects the
      // sky's own fragments. depthWriteEnabled stays on so subsequent
      // far-clipped overlays (e.g. distant fog billboards) can be
      // ordered against the sky write.
      pipelineDesc["depthStencil"] = {
        "format":            depthFormat,
        "depthWriteEnabled": true,
        "depthCompare":      "less-equal"
      }
    }
    _pipeline = device.createRenderPipeline(pipelineDesc)

    _sceneUbo = device.createBuffer({
      "size":  SkyboxPipeline.SCENE_UBO_BYTES_,
      "usage": ["uniform", "copy-dst"],
      "label": "sky-scene-ubo"
    })
    _sceneUboFloats = Float32Array.new(SkyboxPipeline.SCENE_UBO_BYTES_ / 4)
    _sceneBindGroup = device.createBindGroup({
      "layout":  _sceneBgl,
      "entries": [{ "binding": 0, "buffer": _sceneUbo, "size": SkyboxPipeline.SCENE_UBO_BYTES_ }],
      "label":   "sky-scene-bg"
    })

    // Defaults — warm midday matching the demo's amber sun.
    _sunDir       = [-0.55, -0.42, -0.72]
    _sunColor     = [1.00, 0.78, 0.55]
    _sunInt       = 3.2
    _zenith       = [0.30, 0.52, 0.92]
    _midSky       = [0.62, 0.80, 0.98]
    _horizon      = [0.96, 0.86, 0.72]
    _cloudTint    = [1.00, 0.96, 0.88]
    _coverage     = 0.42
    _altitude     = 320.0
    _softness     = 1.4
    _windX        = 0.015
    _windZ        = 0.005
    _tanHalfFov   = 0.5384  // tan(56°/2)
    _aspect       = 1.7777  // 16:9

    _pass = null
  }

  // ── Setters (state only; consumed at next beginFrame) ───────────

  /// Override the sun light. The direction is the same one passed to
  /// `WaterPipeline.setSun`; the FS uses `-direction` for the
  /// light-source ray so the disk lands where the rays come FROM.
  /// @param {List} direction. `[x, y, z]` direction the light travels in.
  /// @param {List} color. `[r, g, b]` linear-space.
  /// @param {Num}  intensity. Tints the sun disk; doesn't change sky body.
  setSun(direction, color, intensity) {
    _sunDir = direction
    _sunColor = color
    _sunInt = intensity
  }

  /// Set the 3-band sky gradient. Mid sits between horizon and
  /// zenith via two smoothsteps so callers can dial palettes from
  /// hot-summer (saturated zenith, warm horizon) to overcast
  /// (desaturated everything) without re-tuning the FS.
  /// @param {List} zenith.  `[r, g, b]` straight up.
  /// @param {List} mid.     `[r, g, b]` ≈45° above the horizon.
  /// @param {List} horizon. `[r, g, b]` at the visible horizon.
  setSkyGradient(zenith, mid, horizon) {
    _zenith  = zenith
    _midSky  = mid
    _horizon = horizon
  }

  /// Configure the cloud layer.
  /// @param {Num}  coverage.  0=clear, 1=fully overcast. Drives the
  ///   threshold of the FBM mask.
  /// @param {Num}  altitude.  World-space y for the cloud plane.
  /// @param {Num}  softness.  Exponent on the cloud mask; lower =
  ///   harder cumulus edges, higher = wispy.
  /// @param {List} tint.      `[r, g, b]` cloud body colour.
  setClouds(coverage, altitude, softness, tint) {
    _coverage  = coverage
    _altitude  = altitude
    _softness  = softness
    _cloudTint = tint
  }

  /// Cloud drift velocity in the world-XZ plane (per-second
  /// scaling — multiplied by `time` inside the FS).
  /// @param {Num} windX
  /// @param {Num} windZ
  setWind(windX, windZ) {
    _windX = windX
    _windZ = windZ
  }

  /// Camera projection parameters. Need to be re-set whenever the
  /// camera's perspective changes (typically once at `setup` and
  /// again on every `resize`). `tanHalfFov` is `tan(fovYrad / 2)`;
  /// pass the same `fovY` you handed `Camera3D.setPerspective`.
  /// @param {Num} fovYDegrees
  /// @param {Num} aspect
  setProjection(fovYDegrees, aspect) {
    _tanHalfFov = (fovYDegrees * 3.141592653589793 / 360.0).tan
    _aspect     = aspect
  }

  // ── Frame cycle ─────────────────────────────────────────────────

  /// Begin a sky frame. Writes the scene UBO, binds the pipeline +
  /// scene bind group. Call once per pass, before `draw`.
  /// @param {RenderPass} pass
  /// @param {Camera3D}   camera
  /// @param {Num}        time. Seconds since simulation start; drives cloud drift.
  beginFrame(pass, camera, time) {
    _pass = pass

    // Recompute the camera basis in world space from eye/target/up.
    // Mirrors the lookAt convention in @hatch:math (forward = target-eye,
    // right = forward × up_world, up = right × forward).
    var eye    = camera.eye
    var fwd    = (camera.target - eye).normalized
    var rightV = fwd.cross(camera.up).normalized
    var upV    = rightV.cross(fwd)

    var f = _sceneUboFloats
    putF_(f,  0, "eye.x",     eye.x)
    putF_(f,  1, "eye.y",     eye.y)
    putF_(f,  2, "eye.z",     eye.z)
    putF_(f,  3, "tanHalfFov", _tanHalfFov)
    putF_(f,  4, "right.x",   rightV.x)
    putF_(f,  5, "right.y",   rightV.y)
    putF_(f,  6, "right.z",   rightV.z)
    putF_(f,  7, "aspect",    _aspect)
    putF_(f,  8, "up.x",      upV.x)
    putF_(f,  9, "up.y",      upV.y)
    putF_(f, 10, "up.z",      upV.z)
    putF_(f, 11, "time",      time)
    putF_(f, 12, "fwd.x",     fwd.x)
    putF_(f, 13, "fwd.y",     fwd.y)
    putF_(f, 14, "fwd.z",     fwd.z)
    putF_(f, 15, "coverage",  _coverage)
    putF_(f, 16, "sun_dir.x", _sunDir[0])
    putF_(f, 17, "sun_dir.y", _sunDir[1])
    putF_(f, 18, "sun_dir.z", _sunDir[2])
    putF_(f, 19, "sun_int",   _sunInt)
    putF_(f, 20, "sun_col.r", _sunColor[0])
    putF_(f, 21, "sun_col.g", _sunColor[1])
    putF_(f, 22, "sun_col.b", _sunColor[2])
    putF_(f, 23, "softness",  _softness)
    putF_(f, 24, "zen.r",     _zenith[0])
    putF_(f, 25, "zen.g",     _zenith[1])
    putF_(f, 26, "zen.b",     _zenith[2])
    putF_(f, 27, "altitude",  _altitude)
    putF_(f, 28, "mid.r",     _midSky[0])
    putF_(f, 29, "mid.g",     _midSky[1])
    putF_(f, 30, "mid.b",     _midSky[2])
    putF_(f, 31, "wind_x",    _windX)
    putF_(f, 32, "hor.r",     _horizon[0])
    putF_(f, 33, "hor.g",     _horizon[1])
    putF_(f, 34, "hor.b",     _horizon[2])
    putF_(f, 35, "wind_z",    _windZ)
    putF_(f, 36, "tint.r",    _cloudTint[0])
    putF_(f, 37, "tint.g",    _cloudTint[1])
    putF_(f, 38, "tint.b",    _cloudTint[2])
    putF_(f, 39, "tint.pad",  0)
    _sceneUbo.writeFloats(0, _sceneUboFloats)

    pass.setPipeline(_pipeline)
    pass.setBindGroup(0, _sceneBindGroup)
  }

  /// Issue the fullscreen-triangle draw. Call once between
  /// `beginFrame` and `endFrame`.
  draw() {
    if (_pass == null) Fiber.abort("SkyboxPipeline.draw: call beginFrame first.")
    _pass.draw(3, 1)
  }

  /// Mark the frame complete. Drops the pass reference so a missed
  /// `draw` call doesn't trail GPU state into the next frame.
  endFrame() { _pass = null }

  /// Release device-side resources. Safe to call multiple times.
  destroy {
    if (_sceneBindGroup != null) _sceneBindGroup.destroy
    if (_sceneUbo       != null) _sceneUbo.destroy
    if (_pipeline       != null) _pipeline.destroy
    if (_pipelineLayout != null) _pipelineLayout.destroy
    if (_sceneBgl       != null) _sceneBgl.destroy
    _sceneBindGroup = null
    _sceneUbo       = null
    _pipeline       = null
    _pipelineLayout = null
    _sceneBgl       = null
  }

  // ── Internals ───────────────────────────────────────────────────

  putF_(arr, idx, label, v) {
    if (!(v is Num)) Fiber.abort("SkyboxPipeline.beginFrame: slot %(idx) (%(label)) is not a Num: %(v)")
    arr[idx] = v
  }

  static SHADER_WGSL_ { "
    struct SceneUniforms {
      eye_tan:   vec4<f32>,   // xyz=eye, w=tanHalfFov
      right_asp: vec4<f32>,   // xyz=right, w=aspect
      up_time:   vec4<f32>,   // xyz=up_camera, w=time
      fwd_cov:   vec4<f32>,   // xyz=forward, w=coverage
      sun_dir:   vec4<f32>,   // xyz=direction-light-travels, w=intensity
      sun_col:   vec4<f32>,   // xyz=colour, w=cloud_softness
      zen_alt:   vec4<f32>,   // xyz=zenith, w=cloud altitude (world y)
      mid_wx:    vec4<f32>,   // xyz=mid sky, w=wind_x
      hor_wz:    vec4<f32>,   // xyz=horizon, w=wind_z
      tint:      vec4<f32>,   // xyz=cloud tint
    };
    @group(0) @binding(0) var<uniform> scene: SceneUniforms;

    struct VsOut {
      @builtin(position) clip: vec4<f32>,
      @location(0)       ndc:  vec2<f32>,
    };

    // Fullscreen triangle at the far plane. Covers the whole viewport
    // by emitting positions outside [-1, 1] (the rasterizer clips
    // them) — cheaper than a 6-vertex quad and dodges the diagonal
    // seam.
    @vertex
    fn vs_main(@builtin(vertex_index) vid: u32) -> VsOut {
      var pts = array<vec2<f32>, 3>(
        vec2<f32>(-1.0, -1.0),
        vec2<f32>( 3.0, -1.0),
        vec2<f32>(-1.0,  3.0),
      );
      var o: VsOut;
      o.clip = vec4<f32>(pts[vid], 1.0, 1.0);
      o.ndc  = pts[vid];
      return o;
    }

    // 2D value-noise hash; same idiom as water.wren's bump path so
    // the visual character of the noise matches.
    fn h2(p: vec2<f32>) -> f32 {
      var q = fract(p * vec2<f32>(123.34, 234.45));
      q = q + dot(q, q + 34.56);
      return fract(q.x * q.y);
    }
    fn vnoise(p: vec2<f32>) -> f32 {
      let i = floor(p);
      let f = fract(p);
      let u = f * f * (3.0 - 2.0 * f);
      let a = h2(i);
      let b = h2(i + vec2<f32>(1.0, 0.0));
      let c = h2(i + vec2<f32>(0.0, 1.0));
      let d = h2(i + vec2<f32>(1.0, 1.0));
      return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
    }
    fn fbm(p: vec2<f32>) -> f32 {
      var v: f32 = 0.0;
      var amp: f32 = 0.5;
      var q = p;
      for (var i: i32 = 0; i < 5; i = i + 1) {
        v   = v + amp * vnoise(q);
        q   = q * 2.03;
        amp = amp * 0.5;
      }
      return v;
    }

    @fragment
    fn fs_main(in: VsOut) -> @location(0) vec4<f32> {
      // Reconstruct the world-space view ray for this pixel from
      // the camera basis + tanHalfFov + aspect — no matrix inverse
      // needed. uv is in NDC [-1, 1].
      let uv = in.ndc;
      let ray = normalize(
          scene.fwd_cov.xyz
        + scene.right_asp.xyz * (uv.x * scene.eye_tan.w * scene.right_asp.w)
        + scene.up_time.xyz   * (uv.y * scene.eye_tan.w)
      );

      // 3-band gradient blended via ray.y. Below the horizon we
      // clamp to the horizon band so a tilted camera doesn't reveal
      // a black under-dome.
      let t       = clamp(ray.y, -0.20, 1.0);
      let upperT  = smoothstep(0.25, 1.00, t);
      let lowerT  = smoothstep(0.00, 0.25, t);
      let upper   = mix(scene.mid_wx.xyz, scene.zen_alt.xyz, upperT);
      let lower   = mix(scene.hor_wz.xyz, scene.mid_wx.xyz,  lowerT);
      var col     = select(lower, upper, t > 0.25);

      // Sun disk + halo. The sun_dir is the direction light TRAVELS
      // in, so the on-screen sun is at -sun_dir. Two stacked pow
      // lobes give a tight bright core (exponent 1800) plus a soft
      // surrounding halo (exponent 64) — same two-lobe trick water
      // uses for specular.
      let L     = normalize(-scene.sun_dir.xyz);
      let d     = max(dot(ray, L), 0.0);
      let core  = pow(d, 1800.0);
      let halo  = pow(d, 64.0) * 0.35;
      col       = col + scene.sun_col.xyz * (core + halo) * scene.sun_dir.w;

      // Cloud layer — ray-plane intersect at world-y = altitude.
      // Only rays that point above the horizon hit the plane in
      // positive distance. We attenuate the cloud mask by the
      // horizon proximity so the layer fades into the warm band
      // instead of cutting off in a flat ring.
      if (ray.y > 0.02) {
        let alt   = scene.zen_alt.w;
        let tP    = (alt - scene.eye_tan.y) / ray.y;
        let hit   = scene.eye_tan.xyz + ray * tP;
        let wind  = vec2<f32>(scene.mid_wx.w, scene.hor_wz.w);
        let p     = hit.xz * 0.0015 + wind * scene.up_time.w;
        let n     = fbm(p);
        // Coverage tunes the smoothstep window. At coverage=0 the
        // mask is the top 0% of the FBM range (clear), at coverage=1
        // the window is the entire [0,1] range (overcast).
        let cv    = smoothstep(1.0 - scene.fwd_cov.w, 1.0, n);
        // Softness shapes cumulus edges — small = puffy hard
        // boundaries, large = wispy cirrus. Horizon fade kills the
        // visible plane-cut ring.
        let mask  = pow(cv, scene.sun_col.w) * smoothstep(0.0, 0.18, ray.y);
        // Underside shade — cloud bottoms face down so dot(downN,L)
        // is bright when sun is overhead. Bias keeps shaded bases
        // visible at low sun angles instead of crushing to black.
        let downN = vec3<f32>(0.0, -1.0, 0.0);
        let lit   = 0.55 + 0.45 * max(dot(downN, L), 0.0);
        col       = mix(col, scene.tint.xyz * lit, mask);
      }
      return vec4<f32>(col, 1.0);
    }
  " }
}
