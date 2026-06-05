# Changelog

## 0.1.7 -- 2026-06-05

`@hatch:game` dep pin advanced 0.3.29 → 0.3.30 to pick up the
`wlift_particles` plugin path that lit Phase 6d / 11.9 perf
gates green (0.49 ms and 1 ms/frame respectively). No HUD-side
surface change — the bump keeps composing games on the fast
particle path without an old `@hatch:game` pin holding back the
registry.

## 0.1.6 -- 2026-06-04

Maintenance release riding the HUD initiative work that
landed in the playground (retained widgets, bitmap-font
import, gamepad nav). The fruit-slicer playground example
bumps to this version; see its hatchfile for the wiring.
