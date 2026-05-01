A minimal game framework for Wren. Subclass `Game`, override `setup` / `update` / `draw`, hand the class to `Game.run` — you get a window, a GPU device, a per-frame loop, and aggregated input state wired in. The same source drives a `winit` window on native and a page-attached canvas on web. Composes with `@hatch:ecs` for entities, `@hatch:assets` for hot-reloaded content, `@hatch:audio` for sound, and `@hatch:physics` for collision.

## Overview

State lives on your subclass — no userdata scratchpad, no closure ceremony. `Game.run` instantiates the class (so declare a `construct new() {}`), opens the window using your `config` getter, then drives the loop until something flips `g.requestQuit`.

```wren
import "@hatch:game"  for Game
import "@hatch:gpu"   for Renderer2D, Camera2D, Sprite
import "@hatch:image" for Image

class MyGame is Game {
  construct new() {}

  config { {
    "title":      "Sprite Demo",
    "width":      800, "height": 600,
    "clearColor": [0.08, 0.08, 0.12, 1.0]
  } }

  setup(g) {
    _sprite   = Sprite.new(g.device.uploadImage(Image.decode(bytes)))
    _renderer = Renderer2D.new(g.device, g.surfaceFormat)
    _camera   = Camera2D.new(g.width, g.height)
  }

  update(g) {
    if (g.input.isDown("KeyD"))   _sprite.x = _sprite.x + 200 * g.dt
    if (g.input.isDown("Escape")) g.requestQuit
  }

  draw(g) {
    _renderer.beginFrame(_camera)
    _sprite.draw(_renderer)
    _renderer.flush(g.pass)
  }
}

Game.run(MyGame)
```

`Game.run` owns the window, device, and surface lifetimes. Resize events re-configure the surface automatically; `g.requestQuit` exits on the next frame boundary.

## Input and timing

`g.input` aggregates keyboard and mouse state. Use `isDown(key)` for held-state polling, `justPressed(key)` for edge-triggered actions. Key names match `winit`'s `physical_key` Debug formatting (`KeyA`, `Space`, `Escape`, `ArrowLeft`). The raw event list lives at `g.events` if you want to drive your own state machine instead.

`g.dt` is the seconds-since-last-frame `Num`, clamped to a sane upper bound so a paused tab doesn't dump a giant integration step into your update.

> **Note — web target yields each frame**
> On `#!wasm` builds, the loop parks on `Browser.nextFrame.await` (vsync-paced via `requestAnimationFrame`) so the JS event loop drains and the page stays responsive. Native builds strip that import via the cfg pre-pass; you don't see the difference at the source level.

## Compatibility

Wren 0.4 + WrenLift runtime 0.1 or newer. Depends on `@hatch:window`, `@hatch:gpu`, and `@hatch:time`. Native targets need a working `winit` + `wgpu` stack; web targets need WebGPU (Chrome and Edge ship it; Safari and Firefox are flag-gated as of writing).
