# Changelog

## 0.1.4 -- 2026-06-05

§12.7 of the stylised-shading plan — `SkyPass` ships.

- New `SkyPass` class (`sky.wren`, re-exported through
  `@hatch:postfx`). Vertical gradient sky-dome composited where
  scene depth is at the far plane (no geometry written). Two-stop
  zenith/horizon mix with a `falloff` exponent for transition
  sharpness.
- Public surface:
  ```wren
  g.postFX = PostFX.new(g)
  g.postFX.add(SkyPass.new({
    "zenith":  [0.55, 0.75, 0.92, 1.0],
    "horizon": [0.92, 0.85, 0.72, 1.0],
    "falloff": 1.2
  }))
  g.postFX.add(Tonemap.new())
  ```
  Composes cleanly with `OutlinePass` (depth=1.0 sky fragments
  don't fire edges; the depth discontinuity at the geometry
  boundary triggers an outline against the sky — exactly the
  silhouette read the cel aesthetic wants).
- Standard PostPass wiring — `wantsDepth = true`, 48 B uniform
  block, no custom layout. Drops into the default
  `buildFragmentPipeline_` path.
- Placement: put it early in the chain (before Tonemap) so ACES
  normalises sky + scene together. Put it last when you want the
  painted gradient verbatim.

## 0.1.3 -- 2026-06-05

§12.4 of the stylised-shading plan — `OutlinePass` ships.

- New `OutlinePass` class in `outline.wren`, re-exported through
  `@hatch:postfx`. Sobel-style edge detection on the depth +
  normal G-buffers (4-tap cross). Both gradients are thresholded
  independently and OR'd, then the edge mask blends the configured
  ink colour over the scene.
- Public surface:
  ```wren
  PostFX.new(g, { "normalFormat": "rgba8unorm" }).add(
    OutlinePass.new(g.device, {
      "depthThreshold":  0.005,
      "normalThreshold": 0.30,
      "color":           [0.05, 0.05, 0.08, 1.0],
      "thickness":       1.0
    })
  )
  ```
  Composes with toon shading for a full stylised anime look; works on top
  of plain PBR for a comic-book-on-real look.
- Requires `Renderer3D.new(.., normalFormat)` and
  `PostFX.new(g, { "normalFormat": ... })` to both be wired with
  matching formats; throws a clear error otherwise.
- `@hatch:game` dep pin advanced 0.3.30 → 0.3.33 for the
  `ctx["normalView"]` field added to the chain's per-step
  dispatch context (alongside the existing `ctx["depthView"]`).

## 0.1.2 -- 2026-06-05

`@hatch:game` dep pin advanced 0.3.29 → 0.3.30 to pick up the
`wlift_particles` plugin path. No PostFX-side surface change —
the bump keeps PostFX composing with the new fast particle
pipeline, and the long-standing `PostPass` field-aliasing
limitation continues to live under `memory/project_postfx_
inheritance_blocker.md` until a wlift-level field-layout fix
lands.

## 0.1.1 -- 2026-06-04

Maintenance bump for the publish wave (2026-06-04).

Known limitation carried forward: `PostPass` subclasses still
hit class-field slot aliasing under wlift codegen (`_pipelines`
reads back as the subclass scalar, layout ids cascade to
"unknown layout"). PostFX is disabled in procedural-world
pending the wlift-level field-layout fix; the package surface
stays available so simpler single-pass effects keep working.
