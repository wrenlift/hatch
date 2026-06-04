# Changelog

## 0.1.1 -- 2026-06-04

Maintenance bump for the publish wave (2026-06-04).

Known limitation carried forward: `PostPass` subclasses still
hit class-field slot aliasing under wlift codegen (`_pipelines`
reads back as the subclass scalar, layout ids cascade to
"unknown layout"). PostFX is disabled in procedural-world
pending the wlift-level field-layout fix; the package surface
stays available so simpler single-pass effects keep working.
