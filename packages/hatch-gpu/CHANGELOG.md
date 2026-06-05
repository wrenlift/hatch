# Changelog

## 0.3.17 — 2026-06-05

Follow-on to the toon-shader landing in 0.3.16:

- `Mesh.sphere(device, radius, segments)` UV-sphere primitive
  (smooth normals, longitude × latitude grid). Toon banding only
  reads as crescent steps on curved geometry — cubes show one
  flat tone per face, which obscures the effect.
- `fs_toon_main` band math rewrite. The previous version
  multiplied each quantised step by `dl.dir_intensity.w`, which
  with a typical sun intensity of 3.5 crushed every band past 1.0
  and rendered as near-white. Now the band amount stays in [0, 1]
  and tone comes from `mix(shadow_color, lit_color, lit_amount)`
  where shadow tints by `scene.ambient` and lit by the dominant
  directional's colour — Ghibli's signature cool-shadow /
  warm-key two-tone, without compound darkening.
- Toon-shading demo (`hatch/examples/game/toon-shading`) switched
  to spheres with an orbiting sun so the cel bands sweep across
  each surface dynamically; rim dialled to 0.35 strength × 6.0
  width (the prior 0.85 × 3.5 was bleeding onto whole side
  faces).

## 0.3.16 — 2026-06-05

Toon / cel shading lands as a first-class `Material` variant.

- `Material.shadingModel` (`"pbr"` default, `"toon"` opts in) plus
  `bands` / `rimStrength` / `rimWidth` / `ambientFloor` dials.
  Defaults (`bands = 3`, `rim = 0`, `floor = 0.35`) produce a
  Ghibli-style three-band look with no shadow crush; setters tick
  `revision_` so the renderer rebuild-trigger picks them up.
- `Renderer3D` builds a second pipeline (`_toonPipeline`) off the
  existing PBR shader module — the shader gains an `fs_toon_main`
  fragment entry that quantises Lambert by bands, applies an
  ambient floor, and adds a fresnel rim. No new bind group, no
  new vertex layout — `draw(mesh, material, model)` just picks
  `_toonPipeline` when `material.shadingModel == "toon"`.
- `MaterialUniforms` UBO grew 64 → 80 bytes with a trailing
  `toon: vec4<f32>` slot. PBR ignores the slot at runtime; the
  layout stays uniform so both pipelines bind the same struct.
- New demo: `hatch/examples/game/toon-shading` — three cel-shaded
  spheres comparing 2 / 3 / 4 bands and a rim-lit hero shot
  against a PBR ground for reference.

Pending follow-ons (tracked in `game-engine-parity-status.md` §12):
`_toonInstancedPipeline` for billboards / foliage,
`_toonSkinnedPipeline` for characters, and an `OutlinePass` in
`@hatch:postfx` for ink edges.

## 0.3.15 — 2026-06-04

Plugin dylib rebuilt against wren_lift `7566533` (was `e52ba41`
/ older). Picks up the cross-plugin GC root tracking added since
the prior pin — specifically `c7eb482` (plugins: root map +
key locals across allocator calls), `9aeabba` (close GC root
miss in foreign methods + entry-block params), and the related
JIT-roots-store release work. Hosts running newer wren_lift
could otherwise sweep the plugin's foreign objects as
unreachable across allocator calls in the foreign method body.

## 0.3.14 -- 2026-06-04

- Compute pipeline + compute pass + fast typed-array readback
  for GPU-side buffers.
- `RenderPass` command decoder gains `DrawIndexedIndirect` so
  Wren-driven indirect draws round-trip through the wgpu
  backend.
- Plugin-side: GPU blend descriptors + comparison sampler
  land for the broader rendering matrix the procedural-world
  and animation-showcase examples exercise.
- Picks up the `wren_lift` JIT/AOT GC stack-map fixes that
  closed the foreign-method root-miss class.
