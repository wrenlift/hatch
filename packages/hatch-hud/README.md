# @hatch:hud

Immediate-mode HUD overlay for the WrenLift game framework. `HUD.new(g)`
gives you `hud.label`, `hud.rect`, `hud.button` — drawn through
`@hatch:gpu`'s Renderer2D, with click + hover state tracked across
frames. Ships a built-in 5×7 procedural font (digits + uppercase +
common punctuation) so HUD essentials (`SCORE: 100`, `LIVES: 3`,
`PAUSE`) work without bringing an asset font.

## Quick start

```wren
import "@hatch:game" for Game
import "@hatch:gpu"  for Renderer2D, Camera2D
import "@hatch:hud"  for HUD

class MyGame is Game {
  construct new() {}

  setup(g) {
    _renderer = Renderer2D.new(g.device, g.surfaceFormat)
    _camera   = Camera2D.new(g.width, g.height)
    _hud      = HUD.new(g)
    _score    = 0
  }

  update(g) {
    _score = _score + g.dt * 10
  }

  draw(g) {
    _renderer.beginFrame(_camera)
    _hud.beginFrame(g, _renderer)

    _hud.rect(0, 0, g.width, 56, [0, 0, 0, 0.55])     // top bar
    _hud.label("SCORE: %(_score.floor)", 12, 18, 3)
    _hud.label("LIVES: 3",                240, 18, 3)

    if (_hud.button("PAUSE", g.width - 140, 12, 120, 32)) {
      g.requestQuit
    }

    _hud.endFrame
    _renderer.flush(g.pass)
  }
}

Game.run(MyGame)
```

## API

### `HUD.new(g)`

Allocates the 1×1 white pixel atlas every primitive samples from.

### `hud.beginFrame(g, renderer)`

Wires up the per-frame state. `g` provides input; `renderer` is the
`Renderer2D` every primitive draws into.

### `hud.rect(x, y, w, h, color)`

Filled rectangle. `color` is `[r, g, b, a]` in linear 0..1.

### `hud.border(x, y, w, h, thickness, color)`

Stroked rectangle outline (four edge rects).

### `hud.label(text, x, y, scale, color = [1,1,1,1])`

Render text using the built-in 5×7 font. Lowercase is folded to
uppercase before lookup. Each "on" pixel becomes a `scale × scale`
sprite — scale 2–4 is comfortable for HUD use; 1 looks pixelated.

### `HUD.measure(text, scale) → [width, height]`

Width / height the corresponding `label(...)` will produce. Use for
centred or right-aligned text.

### `hud.button(text, x, y, w, h, theme = HUD.DEFAULT_BUTTON_THEME_)`

Filled button with centred label. Returns `true` on the single frame
the user finishes a click (press-down inside, release inside). State
is tracked across frames internally, keyed off `"%(x):%(y):%(text)"`.

`theme` is a Map of optional colours + scale:

| Key | Default | Notes |
|---|---|---|
| `bg`       | `[0.18, 0.20, 0.24, 0.92]` | Idle body. |
| `bgHover`  | `[0.26, 0.30, 0.36, 0.96]` | Mouse over. |
| `bgActive` | `[0.10, 0.12, 0.14, 1.0]`  | Mouse held. |
| `fg`       | `[1, 1, 1, 1]` | Idle label. |
| `fgActive` | `[0.80, 0.85, 1.0, 1]` | Mouse held label. |
| `border`   | `null` | If set, drawn 1px around the body. |
| `scale`    | `2`    | Label scale. |

### `hud.endFrame`

Releases the per-frame renderer reference.

## Built-in font glyphs

| Range | Count |
|---|---|
| `0`–`9`     | 10 |
| `A`–`Z`     | 26 |
| ` `         | 1  |
| `:` `.` `,` `!` `?` `-` `/` `(` `)` `+` `=` | 11 |

Lowercase folds to uppercase. Characters outside this set render as
the space glyph (visually invisible) — so an unknown character is a
gap, never a crash.

## Planned

- **Retained widget tree** (Godot Control / PlayCanvas Element style) —
  layout solver, themed widget hierarchy, declarative menu trees.
  Ships as a separate package; immediate mode here stays the
  one-line-per-widget surface.
- **Bitmap-font import** — `BitmapFont.fromImage(img, {glyphWidth,
  glyphHeight, ...})` so games with custom typography can replace the
  built-in 5×7 default.
- **Gamepad nav** — focus + D-pad/stick selection through registered
  widgets, so the same HUD code drives mouse + controller input.
