# Game Framework Parity — Status & Roadmap

Last audited: 2026-06-05 (date-locked snapshot — re-run /audit when state changes)

Plan source: [game-engine-parity-plan.md](./game-engine-parity-plan.md)

## Status legend
- ✅ Shipped — works end-to-end
- 🟡 Partial — specific gaps listed
- ❌ Absent — no implementation

## Phase status

| Phase ID | Title | Status | Effort to finish | Key gap |
|---|---|---|---|---|
| 0a | @hatch:math primitives | ✅ | — | — (NumRange added; Color split to @hatch:color; Mat3 deferred) |
| 0b | @hatch:fsm Harel statecharts | ✅ | — | — |
| 0c | @hatch:color colour primitive | ✅ | — | — |
| 2 | ECS-driven game components | ✅ | — | ActiveCamera + SpriteRenderer + Animator + 4 systems landed in @hatch:game/ecs_components.wren 2026-06-03 |
| 1 | Scene graph + materials + glTF + lighting | ✅ | — | Skins / animations folded in by Phase 5 (2026-06-03). |
| 3 | Input action mapping + gamepad | ✅ | — | — (half-axis sign suffix fixed 2026-06-03) |
| 4 | Physics completeness | ✅ | small | No `sensor` helper API; thin spec coverage |
| 5 | Animation (Tween + AnimationPlayer + skeletal) | ✅ | — | Full skeletal pipeline shipped 2026-06-03: glTF skin parsing, SkinPalette, Renderer3D.drawSkinned, GltfAnimation.crossfade. the_strangler 102-joint rig animates end-to-end. |
| 6a | Particles (CPU) | ✅ | — | — |
| 6b | Post-processing chain | ✅ | — | — |
| 6c | Shadows (directional) | 🟡 | medium | CSM/cubemap helpers exist but Renderer3D never consumes them |
| 6c-cascade | Cascaded directional + cubemap point shadows | 🟡 | large | Math shipped; pipeline not wired |
| 6d | Instanced 3D billboards / ParticleSystem3D | ✅ | small | No 100k-billboard exit-gate spec |
| 6e | GPU compute particle sim | ✅ | small | No wind/curl-noise uniforms; no 1M-particle spec |
| 7 | UI overlay (immediate mode HUD) | ✅ | small | Uppercase-only font; no text input/menu helper |
| 8 | Asset pipeline + save/load | 🟡 | medium | No background loading; SaveSystem doesn't round-trip FSM state |
| 9 | Audio v2 (OGG / spatial / groups / effects) | 🟡 | large | No spatial pan/attenuation, no effects bus, no wasm backend |
| 10 | Debug overlays / profiler / inspector / replay | ✅ | — | EntityInspector + PhysicsDebugDraw (2D) + InputRecorder / InputReplayer shipped 2026-06-03 — 3D physics wireframe waits on a 3D line-drawer primitive |
| 11.1 | Storage buffers + compute pipelines | ✅ | — | — |
| 11.2 | Instanced draw (Renderer3D / Renderer2D) | 🟡 | small | Per-instance attribute layout not caller-declared |
| 11.3 | @hatch:noise | ✅ | small | Missing 4D variants |
| 11.4 | @hatch:spatial (BVH / quad/oct trees / cluster grid) | ✅ | — | — |
| 11.5 | Frustum culling + indirect draw | ✅ | — | CPU cull (`Frustum.cull`) + GPU compute cull (`ComputeCull.cull` writes a `DrawIndexedIndirectArgs` buffer) + `Renderer3D.drawMeshInstancedIndirect` consumer — all shipped 2026-06-03 |
| 11.6 | LOD selection (MeshLOD + drawInstancedLOD) | ✅ | small | Compute LOD-bucketer waits on 11.5 |
| 11.7 | Procedural terrain (chunks + streaming) | 🟡 | medium | No triplanar splat material; no per-chunk LOD |
| 11.8 | Foliage scatter | 🟡 | medium | No transform packing; no wind sway shader |
| 11.9 | Weather (rain/snow/fog compute particles) | 🟡 | small | No 200k-particle exit-gate spec; fog still CPU |
| 11.10 | Water (low + FFT high quality) | 🟡 | large | FFT-ocean path absent; no caustics/SSS |

## Shipped phases (no further work needed)

- **0b — @hatch:fsm** — Harel statecharts complete: history pseudo-targets, parallel regions, EventEmitter wildcards (`hatch/packages/hatch-fsm/fsm.wren:49`, `:326`, `:472`, `:532`).
- **0a — @hatch:math primitives** — Math/Ease/Vec2/Vec3/Vec4/Mat4/Quat/Vec4Batch + NumRange shipped. Mat3 deferred (GPU shaders use `mat3x3<f32>` directly; no Wren-side caller needs it). Color split into its own package.
- **0c — @hatch:color** — `Color.rgb`/`rgba`/`hsv`/`hex` + named constants + `lerp` / `scale` / `withAlpha` / `toVec4` (`hatch/packages/hatch-color/color.wren`). 17/17 spec tests.
- **2 — ECS game components** — `ActiveCamera` marker + `SpriteRenderer` + `Animator` + `CameraSystem` / `SpriteRenderSystem` / `AnimationSystem` / `AudioSystem` in `@hatch:game/ecs_components.wren`. Re-exported via `@hatch:game`. 14/14 spec tests.
- **11.5 — Frustum culling + GPU indirect draw** — `Frustum.cull(bvh, camera, out)` (CPU, via `@hatch:gpu` Frustum + `@hatch:spatial` BVH), `ComputeCull` (`hatch/packages/hatch-gpu/gpu_cull.wren` — WGSL compute pass that reads instance bounding spheres + frustum-planes UBO and atomically populates a `DrawIndexedIndirectArgs` buffer + a compacted-instance SSBO), `Renderer3D.drawMeshInstancedIndirect(mesh, material, instanceBuffer, indirectBuffer)` consumer. Smoke spec: 2/4 instances admitted at the expected camera angle.
- **10 — Debug overlays** — `FrameTimer` + `DebugOverlay` (existing) + new `EntityInspector` (live entity / component listing with up/down scroll) + `PhysicsDebugDraw` (2D wireframe colliders — box / ball / capsule via projection closure) + `InputRecorder` / `InputReplayer` (deterministic replay capture). In `@hatch:game/debug.wren`; 15 new spec tests. 3D physics wireframe waits on a 3D line-drawer primitive in `@hatch:gpu`.
- **3 — Input + gamepad** — Actions API + gilrs polling end-to-end (`hatch/packages/hatch-game/actions.wren:156`, `plugins/wlift_window/src/lib.rs:139`). Half-axis sign suffix bug fixed at `actions.wren:131-160`; 3 new spec tests for full / `+` / `-` axes.
- **4 — Physics completeness** — Raycast, shape-cast, 4 joint kinds, sensors, contact events (`hatch/packages/hatch-physics/physics.wren:186`, `plugins/wlift_physics/src/lib.rs:1637`, `:255`).
- **6a — CPU particles** — Fixed-capacity pool + color-over-life (`hatch/packages/hatch-game/particles.wren:145`).
- **6b — Post-processing** — Tonemap / Vignette / FXAA / ColorGrade / ChromaticAberration / Bloom (`hatch/packages/hatch-postfx/postfx.wren:61`, `bloom.wren`).
- **6d — Instanced 3D billboards / ParticleSystem3D** — `drawBillboardN` + storage-buffer particle path (`hatch/packages/hatch-gpu/gpu_renderer3d.wren:2049`, `hatch/packages/hatch-game/particles.wren:467`).
- **6e — GPU compute particles** — Full WGSL compute integration (`hatch/packages/hatch-game/gpu_particles.wren:85`, `:408`).
- **7 — HUD overlay** — Immediate-mode HUD + HUDPanel with gamepad focus nav (`hatch/packages/hatch-hud/hud.wren:172`, `:573`).
- **11.1 — Compute pipelines** — Storage buffers + ComputePipeline + dispatchWorkgroups (`plugins/wlift_gpu/src/lib.rs:559`, `:2671`, `:3385`; `hatch/packages/hatch-gpu/gpu_native.wren:827`).
- **11.3 — @hatch:noise** — Perlin/Simplex/Worley/Value 2D+3D, fBM, ridged, bulk fill, WGSL companion (`hatch/packages/hatch-noise/noise.wren:23`, `:323`).
- **11.4 — @hatch:spatial** — BVH + Quadtree2D + Octree + ClusterGrid (`hatch/packages/hatch-spatial/spatial.wren:42`, `:301`, `:572`, `:780`).
- **11.6 — LOD selection** — MeshLOD + Lod.select3/selectN + drawInstancedLOD (`hatch/packages/hatch-gpu/gpu_native.wren:2304`, `:2387`; `gpu_renderer3d.wren:2002`).

## Partial phases (needs completion)

### 0a — @hatch:math primitives ✅

Shipped 2026-06-03. NumRange added at `hatch/packages/hatch-math/math.wren:1117` (sample/contains/clamp/remap; 7 spec tests). Color extracted to standalone `@hatch:color` per user request. Mat3 deferred — Renderer3D builds TBN inside the WGSL `mat3x3<f32>` and no Wren-side caller exists; add when a CPU-side normal-matrix flow surfaces.

### 1 — Scene graph + materials + glTF + lighting ✅

**Status**: shipped. glTF + lighting are feature-complete; the gltf.wren header comment now lists supported surfaces (animations, skins, KHR_materials_pbrSpecularGlossiness) and the remaining hard-no items (sparse accessors, morph targets, cameras) explicitly.

**Depends on**: 0a
**Effort**: — (shipped)

### 2 — ECS-driven game components 🟡

**Status**: partial — Transform/MeshRenderer/RigidBody/Collider/AudioSource/AudioListener + 4 light kinds shipped and consumed by systems; camera/sprite/animator/audio queries missing.

**Gaps**:
- No `Camera3D` / `Camera2D` ECS components — current cameras live in `hatch/packages/hatch-gpu/gpu.wren:25` and are passed imperatively to `SceneRenderer3D.run`
- No `SpriteRenderer` component — 2D still uses imperative `Sprite.draw(renderer)`
- No `Animator { clip, time, speed }` ECS component despite `AnimationPlayer` existing standalone at `hatch/packages/hatch-game/animation.wren:405`
- No `AudioSystem` walking `(Transform, AudioSource)` — `AudioSource`/`AudioListener` are inert data components at `scene.wren:531`/`:581`

**Next actions**:
- Add `Camera3D` / `Camera2D` ECS components (wrap gpu classes + active marker); add active-camera query path consumed by `SceneRenderer3D`
- Add `SpriteRenderer { sprite, visible }` plus `SpriteRenderSystem.run` batching via Renderer2D
- Add `Animator { clip, time, speed, loop }` + `AnimationSystem.run` advancing time + writing Transform deltas (uses `GltfAnimation.channels`)
- Add `AudioSystem.run` walking `(GlobalTransform, AudioSource)` + reading `AudioListener` pose, updating `@hatch:audio` voices (start/stop + position)

**Depends on**: 1
**Effort**: medium

### 3 — Input action mapping + gamepad 🟡

**Status**: partial — shipped; one bug in half-axis bindings.

**Gaps**:
- `hatch/packages/hatch-game/actions.wren:131-144` `bindingValue_` looks up raw key in axisMap without honouring `+`/`-` suffix documented at `:65` and accepted in `actions.spec.wren:93-95`. `GamepadAxisLY+` / `GamepadAxisRX-` will miss.

**Next actions**:
- Strip the sign suffix in `bindingValue_`, then sign/clamp the resulting axis value accordingly
- Add a spec case asserting half-axis bindings emit the expected signed value

**Depends on**: none
**Effort**: small

### 4 — Physics completeness 🟡

**Status**: partial — full raycast / shape-cast / joints / sensors / contact events shipped; ergonomics + coverage gaps.

**Gaps**:
- Sensor support requires the user to know the magic `sensor: true` options-Map key (`plugins/wlift_physics/src/lib.rs:255-267`); no `Collider3D.sensor(...)` / `Collider2D.sensor(...)` helper on the Wren side
- `physics.spec.wren` only covers gravity/fall (~5 Test.it cases); no raycast / shape-cast / joint / sensor / drainContactEvents coverage

**Next actions**:
- Add `Collider3D.sensor(...)` / `Collider2D.sensor(...)` ergonomic constructors that flip the descriptor flag
- Expand `physics.spec.wren` with raycast, shape-cast, each joint kind, sensor trigger, and contact-event drain

**Depends on**: none
**Effort**: small

### 5 — Animation (Tween + AnimationPlayer + skeletal) ✅

**Status**: shipped. Scalar-track Tween/Clip/AnimationPlayer + Behaviors.wire on top of the existing animation surface; full glTF skeletal pipeline landed 2026-06-03.

**What landed**:
- `GltfSkin` (joints + inverse-bind matrices) parsed in `buildSkins_` (`hatch/packages/hatch-gltf/gltf.wren:1193`); `GltfNode.skinIndex` populated for skinned nodes.
- `GltfAnimation` + `GltfAnimChannel` with `sample(t)` for STEP / LINEAR / CUBICSPLINE; `applyTo(scene, world, t)` writes joint Transforms each frame.
- `GltfAnimation.crossfade(other, scene, world, tA, tB, blend)` — blends two clips into one pose (translation/scale LERP, rotation SLERP) for clip-to-clip transitions. 4 spec tests at `gltf.spec.wren:382-447`.
- `Mesh.fromArraysSkinned(device, vertices, joints, weights, indices)` builds the skinned VBO trio (`hatch/packages/hatch-gpu/gpu_native.wren:2623`).
- `SkinPalette` storage-buffer manager (`hatch/packages/hatch-gpu/gpu_skin.wren`); one `mat4` per joint, 64 B/joint.
- `Renderer3D.drawSkinned(mesh, material, skin, model)` — dedicated skinned PBR pipeline (`SKINNED_PBR_WGSL_`) consuming JOINTS_0 / WEIGHTS_0 at slots 1/2 and the joint-matrix palette via `@group(3)`. Multi-DirLight + PointLight scene UBO already wired.
- End-to-end demo: `hatch/examples/game/skeletal-animation-demo` loads `the_strangler` (102 joints, KHR_materials_pbrSpecularGlossiness textures), composes the per-frame palette as `joint_world * IBM`, dispatches `drawSkinned` per skinned primitive, drives one animation through `GltfAnimation.applyTo`.

**Optional follow-ups (none blocking the parity gate)**:
- Multi-animation crossfade demo asset (the_strangler only ships one animation; a walk/run/idle asset would visually exercise `crossfade` end-to-end). Spec coverage already validates the math.
- An `Animator` glTF-aware variant or a wrapper that routes `AnimationPlayer.crossfade(name, duration)` into `GltfAnimation.crossfade` for the FSM-driven state-machine flow.

**Depends on**: 1, 2
**Effort**: — (shipped)

### 6c — Shadows (directional, single cascade) 🟡

**Status**: partial — single-cascade directional shadows work end-to-end.

**Gaps**:
- Only `dir_lights[0]` casts (`gpu_renderer3d.wren:1449-1455`); single 2D depth texture, single shadow pipeline
- `hatch/packages/hatch-gpu/gpu_shadows.wren` ships `CascadeShadows` (`:38`) + `PointShadow` (`:203`) as pure CPU math, but `gpu_renderer3d.wren` references neither (zero grep hits)
- `beginShadowFace`/`endShadowFace` referenced in `gpu_shadows.wren:198`-`:200` docstrings do not exist on Renderer3D

**Next actions**:
- Fold into 6c-cascade — they share the renderer-pipeline rewrite

**Depends on**: none (math layer ready)
**Effort**: covered under 6c-cascade

### 6c-cascade — Cascaded directional + cubemap point shadows 🟡

**Status**: partial — CPU math shipped (`gpu_shadows.wren:38`, `:203`); zero renderer integration.

**Gaps**:
- No texture-array shadow map for cascades, no per-cascade VP uniform, no cascade-pick logic in PBR sampling
- No cubemap depth target / 6-face render path for point shadows
- `gpu_shadows.wren:1-15` header explicitly defers pipeline + WGSL changes

**Next actions**:
- Extend `Renderer3D.enableShadows` to accept `{ cascades: N, pointShadows: bool, ... }`
- Allocate a 2D-array depth texture for CSM (one slice per cascade) + a cubemap depth target per point caster
- Render N cascades per directional + 6 faces per point caster; pack per-cascade VPs and cube face matrices into the scene UBO
- Update PBR shader to pick cascade by view-space Z, sample depth-comparison; sample cubemap for points
- Add specs covering multi-cascade VP packing + cubemap-face matrices feeding through

**Depends on**: none
**Effort**: large

### 6d — Instanced 3D billboards 🟡

**Status**: shipped except for a perf exit-gate.

**Gaps**:
- No spec / playground asserting "100k billboards at 60 fps native / 30 fps wasm"

**Next actions**:
- Add a benchmark spec under `hatch/packages/hatch-game/particles.spec.wren` (or a `playground/`) driving 100k live billboards with a frame counter

**Depends on**: none
**Effort**: small

### 6e — GPU compute particle sim 🟡

**Status**: shipped; missing wind-field uniform + perf exit-gate.

**Gaps**:
- Compute shader only has constant gravity + drag + colour/size lerp; no wind / curl-noise / attractor field uniforms
- `Wind.sample` exists CPU-side in `hatch/packages/hatch-game/weather.wren:66` but is not fed into the compute pass
- No 1M-particle perf spec

**Next actions**:
- Add a wind / curl-noise uniform path + WGSL sample inside `gpu_particles.wren:263` pipeline; expose `gpuParticles.setWind(vec3)` or driver from `Wind.sample`
- Add a perf-gated spec asserting 1M-particle update + draw budget

**Depends on**: none
**Effort**: small

### 7 — HUD overlay 🟡

**Status**: shipped end-to-end; quality/coverage gaps.

**Gaps**:
- `BuiltinFont` at `hatch/packages/hatch-hud/hud.wren:54-148` is uppercase-only (digits + A-Z + ~10 punctuation); labels fold mixed case
- No editable text-input widget, no dropdown, no scrollable list/grid layout (HUDPanel offers slider/toggle/button/read-only-text/divider)
- HUDPanel background is fixed-height pre-draw (`hud.wren:651-666` comment)
- No canned pause-menu helper / FSM-driven menu flow (parity exit gate)

**Next actions**:
- Add lowercase glyphs or wire a `@hatch:image`-loaded bitmap font into BuiltinFont
- Refactor HUDPanel to defer the background draw until row count is known
- Ship a `Menu`/`Modal` helper composing HUDPanel rows with `@hatch:fsm` transitions for the canonical pause-menu pattern

**Depends on**: none
**Effort**: small

### 8 — Asset pipeline + save/load 🟡

**Status**: partial — frame-amortised AssetLoader + SaveSystem shipped; not background, no FSM round-trip.

**Gaps**:
- `hatch/packages/hatch-assets/loader.wren:34-46` explicitly notes background loading needs OS threads + thread-safe decoders; today is one-asset-per-update only
- Documented `loader.partial(name, fn)` hook (`loader.wren:43-46`) not implemented
- `hatch/packages/hatch-ecs/save.wren:61-213` does not round-trip `@hatch:fsm` `StateChart` active config; parity plan calls this out as required
- Entity-id remapping for components referencing other entity ids is caller responsibility via `onEntity` (`save.wren:156-185`)
- No drag-and-drop file-event surface (folded into Phase 8 by parity plan)

**Next actions**:
- Add an FSM-aware snapshot helper that round-trips `StateChart` configuration alongside ECS components
- Implement true background loading via the fiber scheduler so `queue(...)` parallelises across closures
- Surface winit drag-and-drop file events as `AssetLoader.queueDroppedFile(...)`

**Depends on**: 0b
**Effort**: medium

### 9 — Audio v2 🟡

**Status**: partial — WAV + OGG decode, master/music/sfx/ui buses, group volumes shipped; spatial + effects + wasm absent.

**Gaps**:
- No spatial pan / distance attenuation — `hatch/packages/hatch-game/scene.wren:565-569` treats `spatial` as a hint; `plugins/wlift_audio/src/lib.rs` has zero pan/distance/attenuation references
- No effects bus / reverb send / lowpass / highpass
- No wasm Web Audio backend (plugin is native-only `libs/libwlift_audio.dylib`; no `audio_web.wren`)
- Nearest-neighbour resampler only (`hatch/packages/hatch-audio/audio.wren:27-30`)

**Next actions**:
- Add panning + distance attenuation to `wlift_audio` mix loop driven by `Audio.setListener(pos, fwd, up)` foreign + per-voice position state
- Add reverb / lowpass effect chain on the per-bus path so `Audio.group(...).reverbSend = 0.3` works
- Implement Web Audio backend behind `#!wasm` so wasm target satisfies the plan
- Upgrade resampler to linear / cubic when wiring in pitch/spatial doppler

**Depends on**: 2 (AudioSystem ECS) for full end-to-end
**Effort**: large

### 10 — Debug overlays / profiler / inspector / replay 🟡

**Status**: partial — `FrameTimer` + `DebugOverlay` shipped (`hatch/packages/hatch-game/debug.wren:22`, `:151`); inspector / physics draw / replay missing.

**Gaps**:
- No entity inspector (zero `inspector` hits in `hatch-ecs`/`hatch-game`); parity F11 panel absent
- No physics debug draw — no `debugDraw`/`drawColliders`/`wireframe` surface in `hatch-physics`; no Renderer3D wireframe helper
- No replay capture / input recording (parity plan's load-bearing AOT battle-test tool)
- DebugOverlay reads externally-pumped counters; no auto per-system µs breakdown, no `vm.alloc_trace_snapshot()` wiring for RSS/alloc-count/GC pauses
- No FSM inspector

**Next actions**:
- Add `EntityInspector` panel walking `World.entities` + per-entity components into HUDPanel rows
- Add `Renderer3D.drawColliderWireframes(physicsWorld)` (line-list primitives per collider shape) or a `@hatch:physics` debug-draw helper
- Wire `vm.alloc_trace_snapshot` (under `alloc_trace` feature) into DebugOverlay
- Ship a `ReplayRecorder` capturing per-frame Input snapshots to a buffer + deterministic restore

**Depends on**: 7
**Effort**: medium

### 11.2 — Instanced draw 🟡

**Status**: shipped (storage-buffer-driven, single drawIndexed) but layout is fixed.

**Gaps**:
- Plan names `Renderer3D.drawInstanced(mesh, material, instanceBuffer, count, attributeLayout)` with caller-declared per-instance attributes (model + tint + UV-rect + LOD)
- Shipped `drawMeshInstanced` (`hatch/packages/hatch-gpu/gpu_renderer3d.wren:1969`) has fixed 32-f32 (model + normalMat) layout — tint / uvScale / LOD slots not exposed

**Next actions**:
- Either rename to `drawInstanced` and extend the per-instance attribute layout to include tint/UV-rect/LOD, or codify the rename as deliberate and amend the plan

**Depends on**: none
**Effort**: small

### 11.5 — Frustum culling + indirect draw 🟡

**Status**: partial — CPU `Frustum.cull` + BVH integration fully shipped; GPU path absent.

**Gaps**:
- Plan names `Renderer3D.cullFrustum(bvh, camera) -> Int32Array`; shipped is static `Frustum.cull(bvh, camera, out)` (`hatch/packages/hatch-gpu/gpu_native.wren:2495`) — API rename only
- No `Renderer3D.drawInstancedIndirect`, no compute-cull pipeline producing a draw-indirect buffer, no `"indirect"` buffer-usage path through `drawIndirect` (zero grep hits in `hatch-gpu/*.wren` and `plugins/wlift_gpu/src/*.rs`)

**Next actions**:
- Wrap as `Renderer3D.cullFrustum` for naming parity, or update the plan to match `Frustum.cull`
- Wire `"indirect"` buffer usage + `pass.drawIndexedIndirect` through `wlift_gpu`; build a compute-cull pipeline + `Renderer3D.drawInstancedIndirect`

**Depends on**: 11.4
**Effort**: medium

### 11.7 — Procedural terrain 🟡

**Status**: partial — chunk grid + streamer + heightmap mesh shipped; material + per-chunk LOD missing.

**Gaps**:
- No triplanar splat material (grass/dirt/rock by slope + altitude) — zero `triplanar`/`splat` hits in `hatch-game/terrain*.wren`
- No per-chunk multi-resolution LOD on the chunk mesh itself (plan mentions `TerrainChunk.fromHeightmap(... , lodLevels)`)

**Next actions**:
- Add a triplanar PBR material in `@hatch:game` (or `@hatch:gpu`) with slope+altitude masking, plus terrain spec coverage
- Add per-chunk LOD tiers so distant chunks downsample without rebuilding

**Depends on**: 11.6 (for `MeshLOD` integration on the chunk side)
**Effort**: medium

### 11.8 — Foliage scatter 🟡

**Status**: partial — `Foliage.scatter` / `poisson` / `fromHeightmap` ship XZ positions; no transform-pack or wind shader.

**Gaps**:
- Plan asks for output as `Float32Array of instance transforms` feeding `drawInstancedLOD`; shipped is XZ positions only — caller must pull y from terrain, build transforms, and bucket per-LOD themselves
- No wind sway in foliage VS — zero `sway|wind` hits in `hatch/packages/hatch-game/foliage.wren` (only `weather.wren` has CPU `Wind.sample`)
- No exit-gate spec for "200k blades at 60 fps native"

**Next actions**:
- Add a Foliage helper packing (xs, zs, terrainHeights) into a `drawMeshInstanced`/`drawInstancedLOD`-ready Float32Array with rotation + scale jitter
- Ship a foliage VS variant consuming a wind uniform + world-position offset and bending top-vertices
- Add the perf spec

**Depends on**: 11.6, 11.7
**Effort**: medium

### 11.9 — Weather 🟡

**Status**: shipped factories (rain/snow/fog) + GPU opt-in (`hatch/packages/hatch-game/weather.wren:174`, `:224`, `:269`); coverage gaps.

**Gaps**:
- No bench-style spec asserting "rain + snow simultaneously, 200k combined particles, 60 fps native"
- Fog still backs onto the pre-existing CPU `Fog` class — no compute-particle layer for volumetric fog

**Next actions**:
- Add an exit-gate spec / playground bench for 100k rain + 100k snow on the GPU path
- Decide volumetric-fog scope; if in, design a compute-particle Fog variant; otherwise codify shipped Fog as the deliverable

**Depends on**: 6e
**Effort**: small

### 11.10 — Water 🟡

**Status**: partial — sine-sum + fbm `WaterPipeline` (`hatch/packages/hatch-game/water.wren:176`) with Schlick / Blinn-Phong / foam / ripples shipped; FFT path absent.

**Gaps**:
- High-quality FFT ocean (Phillips spectrum compute + heightmap-displaced VS) not implemented; no `"high"` quality switch
- No caustics / sub-surface scatter post-effects

**Next actions**:
- Build an FFT-ocean compute path: Phillips spectrum init, FFT compute (or summed-cosines fallback), displaced VS sampling the heightmap; gate behind a `quality:` enum on `WaterPipeline`
- Add caustics + SSS as `@hatch:postfx` passes when FFT lands

**Depends on**: 11.1
**Effort**: large

## Absent phases (not started)

None — every phase has at least partial shipping today. The closest-to-absent items are the cascaded/cubemap shadow renderer integration (6c-cascade) and the FFT ocean (11.10).

## Recommended sequencing

A pragmatic order picking highest-impact unblocked items first.

1. ~~**0a — math primitives**~~ ✅ shipped 2026-06-03 (NumRange + Color extracted to @hatch:color).
2. ~~**3 — half-axis gamepad fix**~~ ✅ shipped 2026-06-03 (rectifies `+`/`-` suffix in `actions.wren:bindingValue_`).
3. ~~**2 — ECS components**~~ ✅ shipped 2026-06-03 in `@hatch:game/ecs_components.wren` (consolidated with the existing scene components).
4. ~~**10 — debug overlays**~~ ✅ shipped 2026-06-03 (`EntityInspector`, `PhysicsDebugDraw`, `InputRecorder`, `InputReplayer`). 3D physics wireframe blocked on `@hatch:gpu` 3D line-drawer.
5. ~~**11.5 — indirect draw + GPU cull**~~ ✅ shipped 2026-06-03: `ComputeCull.cull` (WGSL compute shader, sphere-vs-frustum, atomic visible-count), `Renderer3D.drawMeshInstancedIndirect`. Smoke spec validates 2/4 visible at the expected camera angle.
6. **11.2 — per-instance attribute layout** — small follow-on to 11.5 / 11.6; once indirect lands, callers want tint/UV-rect/LOD slots.
7. **11.7 — triplanar terrain material + per-chunk LOD** — depends on 11.6 (shipped) and benefits from 11.5; brings the procedural-world demo closer to "real game" surface.
8. **11.8 — foliage transform pack + wind shader** — depends on 11.6 + 11.7; together these three deliver the "open-world" exit gate.
9. ~~**5 — skeletal animation**~~ ✅ shipped 2026-06-03: glTF skin parsing + `GltfAnimation.crossfade` + `SkinPalette` + `Renderer3D.drawSkinned`; the_strangler 102-joint rig animates end-to-end with KHR_materials_pbrSpecularGlossiness textures.
10. **6c-cascade — CSM + cubemap shadow pipeline** — large; renderer rewrite is intrusive but math layer is in. Tackle after the smaller wins above so it can land in a focused session.
11. **9 — audio spatial + effects + wasm backend** — large; ordering after Phase 2 means `AudioSystem` exists to consume listener/position updates.
12. **8 — background loading + FSM-aware save** — medium; FSM round-trip needs careful design but is unblocked by 0b (✅).
13. **6d / 6e exit-gate specs + 11.9 weather perf spec + 7 lowercase font** — small polish items; batch as one PR each.
14. **11.10 — FFT water + caustics** — large, lowest immediate-impact; sequence last unless a downstream demo specifically demands FFT seas.

## Known issues / accepted limitations

- **Rotor shadow on Boden** — pending; tracked in active memory entries.
- **PostFX inheritance blocker** — PostPass subclasses hit class-field slot aliasing under wlift codegen; `_pipelines` reads back as the subclass scalar, layout ids cascade to "unknown layout"; PostFX in procedural-world disabled pending a wlift-level field-layout fix. See `memory/project_postfx_inheritance_blocker.md`.
- **GPU loop runaway memory** — long-running `@hatch:game` + `@hatch:physics` + `@hatch:gpu` render loop leaks RSS into tens of GB even after all per-frame Wren-side allocs eliminated (65 GB OOM in ecs-cubes ~100 bodies; 13 GB idle with 3). Suspected upstream: wgpu staging-belt recycling or Wren GC not destroying foreign-handle wrappers. See `memory/project_gpu_loop_runaway_memory.md`.
- **Renderer2D auto-flush + Game.run Fiber.try** — landed 2026-05-29; documented for completeness so future regressions are easy to spot (`memory/project_renderer2d_auto_flush.md`).
- **Bare var branch assign aliasing** — late-in-method locals can slot-alias each other under wlift codegen; workaround: instance field or helper method instead of a deep local. Touches any phase that introduces new long methods.
- ~~**Fiber.try stale slot**~~ RESOLVED 2026-06-04 (wren_lift commit `d5f8e6d`). The misread of the spec is gone from the BC interp + krio paths; canonical Wren `var x = f.try()` works under interpreter/tiered/AOT on macOS arm64 + linux/amd64. Use `fiber.error` as the clean-vs-abort discriminator.
