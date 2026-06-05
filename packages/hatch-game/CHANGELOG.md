# Changelog

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
