# Changelog

## 0.1.2 -- 2026-06-04

Maintenance bump for the publish wave (2026-06-04). The
`StateChart` shape used by skeletal-animation-demo and the
AssetLoader progress patterns is unchanged; this release
ships to pick up runtime fixes from `wren_lift` (AOT GC
stack-map closure for foreign methods, Fiber.try() stale-
slot guard).
