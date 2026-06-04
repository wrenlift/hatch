# Changelog

## 0.1.9 — 2026-06-04

Plugin dylib rebuilt against wren_lift `7566533` (was `e52ba41`
/ older). Picks up the cross-plugin GC root tracking added since
the prior pin — specifically `c7eb482` (plugins: root map +
key locals across allocator calls), `9aeabba` (close GC root
miss in foreign methods + entry-block params), and the related
JIT-roots-store release work. Hosts running newer wren_lift
could otherwise sweep the plugin's foreign objects as
unreachable across allocator calls in the foreign method body.

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
