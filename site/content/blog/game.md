`@hatch:game` is a 2D-first game framework built on top of `@hatch:gpu` (wgpu under the hood) and `@hatch:window` (winit). You subclass `Game`, override `setup` / `update` / `draw`, and hand the class to `Game.run`. State lives on fields. The same Wren source runs as a native binary on macOS / Linux / Windows and as `wasm32-unknown-unknown` in the browser. This post walks from `hatch add` to a scene with sprites, input, and audio.

## Why @hatch:game

The framework is opinionated about a few things:

- **One file, one class.** No engine project, no scene serializer, no editor lock-in. A 50-line subclass of `Game` is a complete app.
- **Sprite batching by default.** `Renderer2D` flushes one draw call per texture switch. The sprite-grid demo draws 432 sprites per frame as a single batched flush.
- **State on fields.** Wren closures capture by reference and the upvalue rules are subtle; the framework leans on `_field` storage so you don't trip them. There's a `g.set("key", value)` / `g.get("key")` scratchpad if you really need a closure-friendly map.
- **Cross-target.** `hatch build --bundle-target wasm32-unknown-unknown` produces a `.hatch` that runs in a Web Worker, with frame pacing through `requestAnimationFrame` and DOM bridges through `postMessage`. The native bundle uses the same Wren source against winit.

The skeleton looks like this:

```wren
import "@hatch:game" for Game

class MyGame is Game {
  construct new() {}                 // required — Wren doesn't inherit ctors

  config { { "title": "demo", "width": 800, "height": 600 } }

  setup(g)  {}                       // one-time init
  update(g) {}                       // per-frame logic
  draw(g)   {}                       // per-frame render
}

Game.run(MyGame)
```

`Game.DEFAULTS_` covers everything `config` doesn't override: `clearColor`, `presentMode`, `surfaceFormat`, `resizable`, `depth` for 3D. Overrides are shallow-merged in.

## Setup

The bare `hatch init` workspace works for games — the framework doesn't need a special template. Add the package:

```sh
hatch init my-game
cd my-game
hatch add @hatch:game
hatch add @hatch:image
hatch run
```

`@hatch:gpu` and `@hatch:window` come along as transitive deps; declaring them again in your hatchfile trips the resolver's cycle detector. `@hatch:image` is a separate add — `Image.decode(bytes)` for PNG / JPEG, `Image.new(w, h, rgbaPixels)` for procedural textures.

The hatchfile after `hatch add`:

```toml
name        = "my-game"
version     = "0.1.0"
entry       = "main"

[dependencies]
"@hatch:game"  = "0.2.9"
"@hatch:image" = "0.1.2"
```

For development, `wlift --watch main.wren` picks up source changes and hot-reloads at the next safepoint without rebuilding the device or reopening the window — see the hot-reload section below.

## First scene

Open a window with a clear color. Six lines of body, no assets:

```wren
import "@hatch:game" for Game

class FirstScene is Game {
  construct new() {}

  config { {
    "title":      "first scene",
    "width":      800,
    "height":     600,
    "clearColor": [0.05, 0.06, 0.10, 1.0]
  } }
}

Game.run(FirstScene)
```

`Game.run` does all of: instantiate the class, resolve `config` against defaults, open the window, request a GPU device, configure the surface, call `setup(g)`, and enter the frame loop. The loop drives `update` then `draw`, polls window events into `g.input`, computes `g.dt` / `g.elapsed`, and re-configures the surface on resize. You'll see a navy-blue rectangle.

`g` is a `GameState`. The fields you'll use most:

- `g.dt` — seconds since the previous frame.
- `g.elapsed` — seconds since `Game.run` started.
- `g.input` — keyboard + mouse state for this frame.
- `g.width` / `g.height` — current surface dimensions in pixels.
- `g.device` — the `Gpu.Device` for uploading textures + creating renderers.
- `g.surfaceFormat` — pass to renderer constructors.
- `g.pass` — bound `RenderPass`, valid only inside `draw`.

## Drawing sprites

`Renderer2D` is the workhorse. Build it in `setup` against the device + surface format, build a `Camera2D`, upload at least one texture, then draw `Sprite`s every frame.

A single white pixel uploaded once and tinted per-sprite is enough for shapes:

```wren
import "@hatch:game"  for Game
import "@hatch:gpu"   for Renderer2D, Camera2D, Sprite
import "@hatch:image" for Image

class TintedRect is Game {
  construct new() {}

  config { { "title": "tinted rect", "width": 800, "height": 600 } }

  setup(g) {
    _renderer = Renderer2D.new(g.device, g.surfaceFormat)
    _camera   = Camera2D.new(g.width, g.height)

    var pixels = [255, 255, 255, 255]
    _white = g.device.uploadImage(Image.new(1, 1, pixels))

    _sprite = Sprite.new(_white)
    _sprite.width  = 200
    _sprite.height = 100
    _sprite.anchor(0.5, 0.5)
    _sprite.tint = [0.95, 0.40, 0.45, 1.0]
  }

  update(g) {
    _sprite.x = g.width  / 2 + 100 * g.elapsed.sin
    _sprite.y = g.height / 2
  }

  draw(g) {
    _renderer.beginFrame(_camera)
    _sprite.draw(_renderer)
    _renderer.flush(g.pass)
  }

  resize(g, w, h) { _camera = Camera2D.new(w, h) }
}

Game.run(TintedRect)
```

The pattern: `beginFrame(camera)`, queue draws via `sprite.draw(renderer)`, `flush(g.pass)` to submit. Multiple sprites with the same texture batch into one draw call. Switching textures (or materials) breaks the batch.

For a real texture, `Image.decode` + `device.uploadImage`:

```wren
import "@hatch:fs"    for Fs
import "@hatch:image" for Image

setup(g) {
  var bytes = Fs.readBytes("assets/player.png")
  var img   = Image.decode(bytes)
  _texture  = g.device.uploadImage(img)
  _player   = Sprite.new(_texture)
  _player.anchor(0.5, 0.5)
}
```

`anchor(0.5, 0.5)` puts the sprite's pivot at its centre — more natural for movement and rotation than the default top-left.

`setTint(r, g, b, a)` skips the four-element list allocation that `s.tint = [...]` does. At 432 sprites times 60 fps that's ~25k fewer allocations per second. The sprite-grid demo uses it.

## Input

`g.input` is the polling-style API. State persists between frames for held keys; edge-triggered helpers fire on the single frame of transition:

```wren
update(g) {
  var speed = 200 * g.dt

  if (g.input.isDown("KeyA") || g.input.isDown("ArrowLeft"))  _x = _x - speed
  if (g.input.isDown("KeyD") || g.input.isDown("ArrowRight")) _x = _x + speed
  if (g.input.isDown("KeyW") || g.input.isDown("ArrowUp"))    _y = _y - speed
  if (g.input.isDown("KeyS") || g.input.isDown("ArrowDown"))  _y = _y + speed

  if (g.input.justPressed("Space")) jump_()
  if (g.input.justPressed("Escape")) g.requestQuit
}
```

Key names match winit's `physical_key` Debug formatting, with the `Code(...)` wrapper stripped: `KeyA`, `Space`, `Escape`, `ArrowLeft`, `Digit1`, etc.

Mouse:

```wren
update(g) {
  // mouseDown stays true while the button is held.
  if (g.input.mouseJustPressed("left")) {
    spawnAt_(g.input.mouseX, g.input.mouseY)
  }
  if (g.input.mouseDown("right")) {
    pan_(g.input.mouseX, g.input.mouseY)
  }
}
```

Buttons are `"left"`, `"right"`, `"middle"`, `"other"`. Mouse position is in surface pixels with origin at the top-left.

For the rare case where state polling doesn't fit (say, you want to act on every keystroke including auto-repeat), `g.events` is the raw event list for the frame. Each entry is a Map with at least a `"type"` key.

Gamepad support is on the v0+ list — for now, drive things from keyboard + mouse.

## Scenes with @hatch:ecs

For anything past a few dozen entities, lift movement and rendering into systems that walk component archetypes. `@hatch:ecs` is the lightweight option — `World.new()`, `world.spawn()`, `world.attach(entity, component)`, then `world.each([Position, Velocity]) {|w, e| ... }`.

The asteroids demo (200 entities, two systems, one render pass) collapses to this:

```wren
import "@hatch:game" for Game
import "@hatch:gpu"  for Renderer2D, Camera2D, Sprite
import "@hatch:ecs"  for World

class Position {
  construct new(x, y) { _x = x; _y = y }
  x { _x } x=(v) { _x = v }
  y { _y } y=(v) { _y = v }
}

class Velocity {
  construct new(x, y) { _x = x; _y = y }
  x { _x }
  y { _y }
}

class SpriteRef {
  construct new(s) { _s = s }
  sprite { _s }
}

class Asteroids is Game {
  construct new() {}

  config { { "title": "asteroids", "width": 960, "height": 720 } }

  setup(g) {
    _renderer = Renderer2D.new(g.device, g.surfaceFormat)
    _camera   = Camera2D.new(g.width, g.height)
    _world    = World.new()

    // ... spawn 200 entities with Position + Velocity + SpriteRef ...
  }

  update(g) {
    var dt = g.dt
    _world.each([Position, Velocity]) {|w, e|
      var p = w.get(e, Position)
      var v = w.get(e, Velocity)
      p.x = p.x + v.x * dt
      p.y = p.y + v.y * dt
    }
  }

  draw(g) {
    _renderer.beginFrame(_camera)
    var renderer = _renderer        // closures capture locals, not fields
    _world.each([Position, SpriteRef]) {|w, e|
      var p = w.get(e, Position)
      var s = w.get(e, SpriteRef).sprite
      s.x = p.x
      s.y = p.y
      s.draw(renderer)
    }
    _renderer.flush(g.pass)
  }
}
```

The `var renderer = _renderer` line is load-bearing: closures capture local variables, not fields. Fields read fine from inside the method body but reading them from inside the `each` block's closure is what trips the closure-upvalue interaction. Hoist the field into a local immediately before the loop.

The full demo lives in `examples/game/ecs/main.wren` in the framework repo.

## Audio

`@hatch:audio` is the WAV-decoding mixer. Open a context once, load samples in `setup`, trigger them with `Audio.play`:

```wren
import "@hatch:audio"  for Audio, Sound
import "@hatch:fs"     for Fs

setup(g) {
  Audio.context()                          // open the output stream
  _bang = Sound.load(Fs.readBytes("assets/bang.wav"))
}

update(g) {
  if (g.input.justPressed("Space")) {
    Audio.play(_bang, { "volume": 0.6 })
  }
}
```

Each `Audio.play` schedules a fresh voice; overlapping triggers naturally stack. Pass `{ "loop": true }` for looping background tracks. `Audio.stopAll()` hard-cuts every active voice.

The 0.1 release decodes WAV only — convert assets during the build if your source is MP3 / OGG. Higher-quality resampling and additional codecs are planned.

## Hot reload

`wlift --watch main.wren` polls the source file's mtime every 500ms. On any change, the runtime sends `SIGUSR1` to itself, hits the next safepoint, and re-runs the modified module's top-level. Class identity is preserved across the swap (a live `Sprite` keeps working), and module-scoped state survives unless the module explicitly resets it.

For game state you don't want to keep across reloads — a half-built world, a pending physics step — clear it from a `Hatch.beforeReload` hook:

```wren
import "hatch" for Hatch

Hatch.beforeReload(Fn.new {|name|
  // name = the module that's about to reload
  // wipe whatever you don't want to leak across the swap
})
```

The web framework's `App.new()` already installs one of these to clear routes; copy the pattern for any registry you accumulate into.

The full hot-reload story (which modules reload, how class identity is preserved, the gotchas) is in the authoring guide. For a game iteration loop, the short version is: edit, save, see the change next frame.

## Web and desktop targets

The same Wren source runs natively and in the browser. Build for both:

```sh
hatch build                                              # native bundle (.hatch)
hatch build --bundle-target wasm32-unknown-unknown       # browser bundle
```

The native `.hatch` is a single-file artifact you can hand to `wlift run my-game.hatch` on any host that has the runtime. Ship it, double-click it, run it from a CI image — it's just bytes.

The wasm bundle drops into a page with a `<canvas>` host. The runtime's `worker.js` shim picks up the bundle, spawns a Web Worker for the Wren VM, and routes DOM-touching APIs through `postMessage`. The frame loop yields with `Browser.nextFrame.await` — backed by `requestAnimationFrame` on the page thread, falling back to a 16ms timer in worker mode where rAF isn't available. Vsync-paced, paint-aligned, naturally throttled when the tab backgrounds.

To attach to an existing canvas instead of opening a fresh one, set `"canvas"` in `config`:

```wren
config { {
  "title":  "my-game",
  "canvas": "game-canvas",        // id of an <canvas> in the page
  "width":  800,                  // ignored when canvas attached
  "height": 600                   // (uses element's natural size)
} }
```

Native ignores the `"canvas"` key.

> **Note: cross-target attributes**
> Wren pulls in `@hatch:audio` only on builds where the host has an output device. If you want a code path that's web-only or native-only, mark the import or statement with `#!wasm` / `#!native`. The cfg pre-pass strips other-target lines before the parser sees them.

## Where to next

- [/packages/@hatch:game](/packages/@hatch:game) — the full API reference: `Game`, `GameState`, `Input`, `Viewport`, `config` keys, lifecycle hooks.
- [/packages/@hatch:gpu](/packages/@hatch:gpu) — `Renderer2D`, `Renderer3D`, `Sprite`, `Camera2D`, `Camera3D`, `Mesh`, `Material`, `Light`, `Texture`.
- The `examples/game/` folder in the framework repo: `bouncing-ball` (physics), `sprite-grid` (batching + input), `ecs` (component-driven scenes), `cube-3d` (3D + HUD overlay). Each is one `main.wren`, tens to a couple hundred lines.
