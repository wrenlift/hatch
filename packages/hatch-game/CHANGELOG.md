# Changelog

## 0.3.36 -- 2026-06-05

`@hatch:gpu` dep pin advanced 0.3.20 → 0.3.21 to pick up the
foliage transform-pack helpers (`Renderer3D.writeInstanceXYZ`)
and `Mesh.grassBlade` primitive (§12.6). No `@hatch:game`
surface change; the existing `Foliage.scatter` already supplies
the (x, z) placement points that feed the new fast path.

## 0.3.35 -- 2026-06-05

`@hatch:gpu` dep pin advanced 0.3.19 → 0.3.20 to pick up the
toon-skinned pipeline + skinned/billboard MRT (§12.5). No
`@hatch:game` surface change; `drawSkinned` consumers and
particle systems automatically inherit MRT compatibility and
toon dispatch when material flips `shadingModel = "toon"`.

## 0.3.34 -- 2026-06-05

§12.4 of the stylised-shading plan — PostFX dispatch ctx surfaces the
scene normal view alongside depth.

- `PostFX.runChain` per-step `ctx` now includes
  `"normalView": _sceneNormalView` (parallel to the existing
  `"depthView"`). `OutlinePass` in `@hatch:postfx` consumes it.
  Other passes are unaffected — they read `ctx["depthView"]` as
  before and ignore the new field.
- No `@hatch:gpu` pin change (still 0.3.19).

## 0.3.33 -- 2026-06-05

`@hatch:gpu` dep pin advanced 0.3.18 → 0.3.19 to pick up the
toon-instanced pipeline + instanced MRT (§12.3). No `@hatch:game`
surface change; ParticleSystem3D and other consumers of
`drawMeshInstanced` automatically inherit toon dispatch when their
`Material.shadingModel` is flipped to `"toon"`.

## 0.3.32 -- 2026-06-05

§12.2 of the stylised-shading plan — PostFX + scene-pass support for
the secondary normal G-buffer.

- `PostFX.new(g, { "normalFormat": "rgba8unorm" })` 2-arg form
  opts in to a third scene-attached target. `PostFX.sceneNormalView_`
  and `PostFX.normalFormat_` expose the resource so OutlinePass
  (§12.4) and similar edge-aware passes can sample it.
- `Game.run` attaches `sceneNormalView_` as a second colour
  attachment on the scene render pass when present, with clear
  value `(0.5, 0.5, 1.0, 1.0)` (packed +Z unit normal — anything
  the scene doesn't write resolves to "no edge" under depth+normal
  Sobel).
- `@hatch:gpu` dep pin advanced 0.3.17 → 0.3.18 for
  `Renderer3D.new(.., normalFormat)` and the `fs_main_mrt` /
  `fs_toon_main_mrt` shader entries that emit packed world-space
  normals into `@location(1)`.

## 0.3.31 -- 2026-06-05

`@hatch:gpu` dep pin advanced 0.3.16 → 0.3.17 to pick up the
toon-shader band-math fix and the new `Mesh.sphere` primitive.
No `@hatch:game` surface change — the bump keeps the engine on
the corrected cel pipeline so games flipping
`Material.shadingModel = "toon"` get readable midtones instead
of the saturation-crushed near-white the 0.3.16 shader produced
under typical sun intensities.

## 0.3.30 -- 2026-06-05

`ParticleSystem3D` delegates its per-frame hot loops to a new
native plugin `wlift_particles` (paired with `@hatch:game` the
same way `wlift_physics` pairs with `@hatch:physics`). The
plugin's two foreign entry points handle the per-particle
integration (gravity + drag + lifetime decay + kill-plane
crossing + swap-with-last compaction) and the per-particle
instance-buffer pack (colour-over-lifetime lerp + optional
distance-scaled width + 5 changing slots per instance).
Configuration, spawning, lifecycle, and renderer dispatch stay
in Wren.

Phase 6d and Phase 11.9 exit gates both green:

| Workload | Pure-Wren baseline | Wren after hot-path hoist | Plugin |
|---|---|---|---|
| Phase 6d, 100k particles | 186 ms/frame | 11 ms/frame | **0.49 ms/frame** |
| Phase 11.9, 200k rain+snow | ~360 ms/frame | ~22 ms/frame | **1 ms/frame** |

Both against the 8 ms parity budget — 16× and 8× headroom
respectively. Run with `WLIFT_PERF=1 hatch test packages/hatch-game`
to gate against either.

Internal Wren-side changes:

- `ParticleSystem3D.update` and `.draw` pack their per-frame scalar
  inputs (gravity, drag, kill-plane, colour gradient, size,
  rotation, screen-space-width inputs) into pre-allocated
  `_updateParams` / `_drawParams` Float32Array scratchpads and
  call `ParticleSim3DCore.integrate` / `.pack` once per frame.
- `_deaths` layout changed: the first two floats are a sentinel
  header (`deathCount`, reserved) that the plugin writes;
  death-position triples start at index 2. `consumeDeaths`
  reflects the new layout.
- Dead helpers `recordDeath_` and `killSlot_` removed (the
  integrate kernel owns those operations now).

## 0.3.29 -- 2026-06-04

*Holdout — see `docs/PUBLISH-HOLDOUTS.md`.*

This entry is prepared but the package is **not** publishing
in the 2026-06-04 wave. The gating bug is the pre-existing
module-load-order panic: subclasses of `Game` compile before
the `Game` module loads, which the resolver surfaces as an
unresolved class reference and the MIR builder turns into a
panic. The fix lives in `wren_lift`; once it lands the
hatchfile tag goes out and this entry ships unchanged.

Staged for the release once the runtime fix lands:

- Renderer2D `beginPass(pass)` / `endPass()` + auto-flush on
  texture-mismatch boundaries; `Game.run` wraps
  `instance.draw(g)` in `Fiber.try()` so GPU teardown always
  runs even when a frame aborts.
- Setup-pump pumps OS events between `Fiber.yield()` calls
  so async asset loads keep the OS responsive across long
  warmups.
- Window lifecycle: open hidden, init, paint, then show —
  fixes the white-flash + retina swap-chain mismatch on
  cold boot.
