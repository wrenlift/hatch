# Changelog

## 0.1.8 -- 2026-06-04

- Shape casts + joints + sensor opt-in on the rapier-backed
  plugin.
- Raycasts + contact-event channel for the per-step query
  surface.
- Non-allocating rotation + `positionInto` / `rotationInto`
  helpers so per-frame physics reads stop allocating temp
  vectors.
- Plugin: rapier parallel solver is now wired up; pairs with
  the `@hatch:gpu` 0.3.14 release for the matching GPU side.
