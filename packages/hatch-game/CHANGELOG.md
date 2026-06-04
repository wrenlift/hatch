# Changelog

## 0.3.29 -- 2026-06-04

*Holdout — see `docs/PUBLISH-HOLDOUTS.md`.*

This entry is prepared but the package is **not** publishing
in the 2026-06-04 wave. The gating bug is the pre-existing
module-load-order panic: subclasses of `Game` compile before
the `Game` module loads, which the resolver surfaces as an
unresolved class reference and the MIR builder turns into a
panic. The fix lives in `wren_lift`; once it lands the
hatchfile tag goes out and this entry ships unchanged.

Staged for the release once the runtime fix lands:

- Renderer2D `beginPass(pass)` / `endPass()` + auto-flush on
  texture-mismatch boundaries; `Game.run` wraps
  `instance.draw(g)` in `Fiber.try()` so GPU teardown always
  runs even when a frame aborts.
- Setup-pump pumps OS events between `Fiber.yield()` calls
  so async asset loads keep the OS responsive across long
  warmups.
- Window lifecycle: open hidden, init, paint, then show —
  fixes the white-flash + retina swap-chain mismatch on
  cold boot.
