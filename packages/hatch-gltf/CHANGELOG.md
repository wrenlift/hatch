# Changelog

## 0.1.2 -- 2026-06-05

`@hatch:game` dep pin advanced 0.3.29 → 0.3.30 to pick up the
`wlift_particles` plugin path. No package-surface change here —
the bump lets `Gltf` consumers compose with `ParticleSystem3D`'s
new native-Rust hot loops (Phase 6d / 11.9 exit gates at 0.49 ms
and 1 ms/frame respectively) without an old `@hatch:game` pinning
the registry to the slower pure-Wren path.

## 0.1.1 -- 2026-06-04

- `Gltf.openDir` + per-image streaming entry points: GLTF
  scenes load progressively so large asset packs don't block
  the boot frame.
- Pairs with the `StateChart` + `AssetLoader` + HUD progress-
  bar pattern wired up in the skeletal-animation-demo and
  procedural-world examples.
- Picks up the new `@hatch:image` async decode pipeline so
  per-image PNG/JPEG decodes happen on worker threads.
