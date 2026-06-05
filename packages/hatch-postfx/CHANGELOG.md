# Changelog

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
