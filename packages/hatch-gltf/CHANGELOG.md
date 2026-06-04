# Changelog

## 0.1.1 -- 2026-06-04

- `Gltf.openDir` + per-image streaming entry points: GLTF
  scenes load progressively so large asset packs don't block
  the boot frame.
- Pairs with the `StateChart` + `AssetLoader` + HUD progress-
  bar pattern wired up in the skeletal-animation-demo and
  procedural-world examples.
- Picks up the new `@hatch:image` async decode pipeline so
  per-image PNG/JPEG decodes happen on worker threads.
