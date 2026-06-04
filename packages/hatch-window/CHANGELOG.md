# Changelog

## 0.2.13 -- 2026-06-04

- Stores the physical inner_size on the Window record so
  retina swap-chain setup can compute the actual surface
  resolution without re-querying winit each frame.
- New `Window.setVisible` (paired with the hidden-then-show
  lifecycle in `@hatch:game`) lets games open the window
  hidden, finish GPU init, paint a clean first frame, then
  flip visibility — fixes the white-flash + retina
  swap-chain mismatch on cold boot.
- Plugin: gilrs gamepad surface, cursor lock/hide helpers,
  mouse-wheel delta channel.
