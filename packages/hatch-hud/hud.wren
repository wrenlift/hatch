//! `@hatch:hud` — immediate-mode HUD overlay for the WrenLift
//! game framework.
//!
//! ```wren
//! import "@hatch:game" for Game
//! import "@hatch:gpu"  for Renderer2D, Camera2D
//! import "@hatch:hud"  for HUD
//!
//! class MyGame is Game {
//!   construct new() {}
//!   setup(g) {
//!     _renderer = Renderer2D.new(g.device, g.surfaceFormat)
//!     _camera   = Camera2D.new(g.width, g.height)
//!     _hud      = HUD.new(g)
//!     _score    = 0
//!   }
//!   draw(g) {
//!     _renderer.beginFrame(_camera)
//!     _hud.beginFrame(g, _renderer)
//!
//!     _hud.label("SCORE: %(_score)", 20, 20, 2)
//!     _hud.label("LIVES: 3",         20, 50, 2)
//!     if (_hud.button("PAUSE", 20, g.height - 60, 120, 40)) {
//!       _score = 0
//!     }
//!
//!     _hud.endFrame
//!     _renderer.flush(g.pass)
//!   }
//! }
//! ```
//!
//! ## How it works
//!
//! Every HUD call queues into the supplied `Renderer2D` — there's
//! no separate render pipeline. The package ships a 1×1 white
//! texture (uploaded once at construct time) that gets tinted +
//! stretched into rectangles for backgrounds, button bodies, and
//! per-pixel font glyphs.
//!
//! Hover / click state is tracked across frames by hashing widget
//! IDs (default: position + label) so a button drawn at
//! `(x=100, y=200)` knows when the mouse enters / leaves / clicks
//! it without the caller threading any state through.

import "@hatch:gpu"   for Texture

/// Tiny 5×7 procedural font covering digits, uppercase letters,
/// and common punctuation. Glyphs are stored as `List<Num>`
/// where each entry is a 5-bit row pattern (bit 4 = leftmost
/// column). Rendered by walking the bit grid and emitting one
/// scaled 1×1 sprite per "on" pixel — no font texture needed,
/// shares the package's white-pixel atlas.
class BuiltinFont {
  /// Cell width in source pixels (5). Multiply by your text
  /// scale for the on-screen pixel width per glyph.
  /// @returns {Num}
  static cellWidth   { 5 }

  /// Cell height in source pixels (7).
  /// @returns {Num}
  static cellHeight  { 7 }

  /// Per-glyph trailing space in source pixels (1). Glyph
  /// advance = `cellWidth + spacing`.
  /// @returns {Num}
  static spacing     { 1 }

  /// Look up the 7-row bitmask for `char` (a single-character
  /// String). Unknown characters fall back to the space glyph,
  /// so misses don't abort the draw.
  /// @param  {String} char
  /// @returns {List<Num>}
  static glyph(char) {
    var g = GLYPHS_[char]
    if (g == null) return GLYPHS_[" "]
    return g
  }

  // Single read-only Map. Glyph rows ordered top → bottom; each
  // value's bits run left → right with `bit (4 - col)` set when
  // pixel at `(row, col)` is on.
  //
  // Designed to read like ASCII art at a glance — each 7-entry
  // List below mirrors a 5×7 pixel grid; the leading row is the
  // top of the character.
  static GLYPHS_ {
    if (GLYPH_CACHE_[0] != null) return GLYPH_CACHE_[0]
    var g = {}
    g[" "] = [ 0,  0,  0,  0,  0,  0,  0]

    // Digits.
    g["0"] = [14, 17, 19, 21, 25, 17, 14]
    g["1"] = [ 4, 12,  4,  4,  4,  4, 14]
    g["2"] = [14, 17,  1,  2,  4,  8, 31]
    g["3"] = [14, 17,  1,  6,  1, 17, 14]
    g["4"] = [ 2,  6, 10, 18, 31,  2,  2]
    g["5"] = [31, 16, 30,  1,  1, 17, 14]
    g["6"] = [14, 17, 16, 30, 17, 17, 14]
    g["7"] = [31,  1,  2,  4,  8, 16, 16]
    g["8"] = [14, 17, 17, 14, 17, 17, 14]
    g["9"] = [14, 17, 17, 15,  1, 17, 14]

    // Uppercase A–Z.
    g["A"] = [14, 17, 17, 31, 17, 17, 17]
    g["B"] = [30, 17, 17, 30, 17, 17, 30]
    g["C"] = [14, 17, 16, 16, 16, 17, 14]
    g["D"] = [30, 17, 17, 17, 17, 17, 30]
    g["E"] = [31, 16, 16, 30, 16, 16, 31]
    g["F"] = [31, 16, 16, 30, 16, 16, 16]
    g["G"] = [14, 17, 16, 23, 17, 17, 14]
    g["H"] = [17, 17, 17, 31, 17, 17, 17]
    g["I"] = [14,  4,  4,  4,  4,  4, 14]
    g["J"] = [ 7,  2,  2,  2,  2, 18, 12]
    g["K"] = [17, 18, 20, 24, 20, 18, 17]
    g["L"] = [16, 16, 16, 16, 16, 16, 31]
    g["M"] = [17, 27, 21, 21, 17, 17, 17]
    g["N"] = [17, 25, 21, 21, 21, 19, 17]
    g["O"] = [14, 17, 17, 17, 17, 17, 14]
    g["P"] = [30, 17, 17, 30, 16, 16, 16]
    g["Q"] = [14, 17, 17, 17, 21, 18, 13]
    g["R"] = [30, 17, 17, 30, 20, 18, 17]
    g["S"] = [14, 17, 16, 14,  1, 17, 14]
    g["T"] = [31,  4,  4,  4,  4,  4,  4]
    g["U"] = [17, 17, 17, 17, 17, 17, 14]
    g["V"] = [17, 17, 17, 17, 17, 10,  4]
    g["W"] = [17, 17, 17, 21, 21, 21, 10]
    g["X"] = [17, 17, 10,  4, 10, 17, 17]
    g["Y"] = [17, 17, 10,  4,  4,  4,  4]
    g["Z"] = [31,  1,  2,  4,  8, 16, 31]

    // Punctuation + common HUD-symbol glyphs.
    g[":"] = [ 0,  4,  0,  0,  0,  4,  0]
    g["."] = [ 0,  0,  0,  0,  0,  0,  4]
    g[","] = [ 0,  0,  0,  0,  0,  4,  8]
    g["!"] = [ 4,  4,  4,  4,  4,  0,  4]
    g["?"] = [14, 17,  1,  2,  4,  0,  4]
    g["-"] = [ 0,  0,  0, 14,  0,  0,  0]
    g["/"] = [ 1,  1,  2,  4,  8, 16, 16]
    g["("] = [ 2,  4,  4,  4,  4,  4,  2]
    g[")"] = [ 8,  4,  4,  4,  4,  4,  8]
    g["+"] = [ 0,  4,  4, 31,  4,  4,  0]
    g["="] = [ 0,  0, 31,  0, 31,  0,  0]

    GLYPH_CACHE_[0] = g
    return g
  }
}

/// Immediate-mode HUD orchestrator. Owns the device-side white
/// pixel atlas, holds per-widget hover / click state between
/// frames, and forwards every draw to a `Renderer2D` supplied
/// in `beginFrame`.
///
/// ## Lifecycle
///
/// ```wren
/// setup(g) {
///   _hud = HUD.new(g)
/// }
/// draw(g) {
///   _hud.beginFrame(g, _renderer)   // wire up per-frame state
///   _hud.rect(0, 0, g.width, 40, [0, 0, 0, 0.6])  // top bar
///   _hud.label("SCORE: %(_score)", 8, 12, 2)
///   if (_hud.button("PAUSE", 20, 100, 120, 40)) g.requestQuit
///   _hud.endFrame
/// }
/// ```
///
/// `beginFrame` resets the click / press state derived from the
/// last frame so each widget can read `wasClicked_(...)` cleanly.
class HUD {
  /// Build a HUD orchestrator. Uploads the package's 1×1 white
  /// pixel texture (the atlas every rectangle / glyph stretches)
  /// against the supplied game state's device.
  ///
  /// @param {GameState} g
  construct new(g) {
    _device = g.device
    _whiteTex = HUD.uploadWhitePixel_(g.device)
    _renderer = null
    _input    = null
    _activeButton = null    // id of button that received mouseDown
    _hoverButton  = null
  }

  // 1×1 RGBA white texture: every HUD primitive (rectangles, font
  // pixels) renders by sampling this and applying a per-call
  // tint. Single pixel = no UV math + reuses Renderer2D's batch
  // for the entire HUD without texture switches.
  static uploadWhitePixel_(device) {
    var tex = device.createTexture({
      "width":  1,
      "height": 1,
      "format": "rgba8unorm",
      "usage":  ["texture-binding", "copy-dst"],
      "label":  "hatch-hud-white-pixel"
    })
    device.writeTexture(tex, [255, 255, 255, 255], { "width": 1, "height": 1, "bytesPerRow": 4 })
    return tex
  }

  /// Internal: the 1×1 white texture every HUD draw tints +
  /// stretches. Exposed for callers building auxiliary widgets
  /// (icon strip, custom drawables) on top of the same atlas.
  /// @returns {Texture}
  whiteTexture_ { _whiteTex }

  /// Prepare for a new frame's UI work. `renderer` is the
  /// `Renderer2D` UI draws will batch into; `g` provides the
  /// frame's input state.
  ///
  /// @param {GameState} g
  /// @param {Renderer2D} renderer
  beginFrame(g, renderer) {
    _renderer = renderer
    _input    = g.input
    _hoverButton = null
    // Defer click resolution to the actual `button()` call sites;
    // we just snapshot the input state here.
  }

  /// Finish the frame. Releases the per-frame renderer reference.
  endFrame {
    _renderer = null
    _input    = null
  }

  /// Filled rectangle. `color` is a 4-element `[r, g, b, a]` list
  /// in linear 0..1. Renders as one `drawSpriteTinted` call.
  ///
  /// @param {Num}  x
  /// @param {Num}  y
  /// @param {Num}  w
  /// @param {Num}  h
  /// @param {List} color. `[r, g, b, a]`.
  rect(x, y, w, h, color) {
    if (_renderer == null) {
      Fiber.abort("HUD.rect: call beginFrame(g, renderer) first.")
    }
    _renderer.drawSpriteTinted(_whiteTex, x, y, w, h,
        color[0], color[1], color[2], color[3])
  }

  /// Stroked rectangle (just the outline) drawn as four
  /// 1-pixel-thick rectangles.
  ///
  /// @param {Num}  x
  /// @param {Num}  y
  /// @param {Num}  w
  /// @param {Num}  h
  /// @param {Num}  thickness. Border width in target-space pixels.
  /// @param {List} color
  border(x, y, w, h, thickness, color) {
    rect(x, y, w, thickness, color)                            // top
    rect(x, y + h - thickness, w, thickness, color)            // bottom
    rect(x, y, thickness, h, color)                            // left
    rect(x + w - thickness, y, thickness, h, color)            // right
  }

  /// Render a string of text at `(x, y)` using the built-in
  /// 5×7 font. Each "on" pixel becomes a 1-pixel sprite scaled
  /// by `scale`. Lowercase characters are folded to uppercase
  /// before lookup so labels written in mixed case still
  /// render.
  ///
  /// Default color is white; pass an explicit `[r, g, b, a]`
  /// for tinted text.
  ///
  /// @param {String} text
  /// @param {Num}    x
  /// @param {Num}    y
  /// @param {Num}    scale. Source pixels per output pixel.
  label(text, x, y, scale) {
    label(text, x, y, scale, [1, 1, 1, 1])
  }

  /// As `label(text, x, y, scale)` but with a custom RGBA tint.
  ///
  /// @param {String} text
  /// @param {Num}    x
  /// @param {Num}    y
  /// @param {Num}    scale
  /// @param {List}   color
  label(text, x, y, scale, color) {
    if (_renderer == null) {
      Fiber.abort("HUD.label: call beginFrame(g, renderer) first.")
    }
    var cursor = x
    var advance = (BuiltinFont.cellWidth + BuiltinFont.spacing) * scale
    var i = 0
    while (i < text.count) {
      var ch = text[i]
      // Fold lowercase to uppercase so callers can write either.
      if (ch.bytes[0] >= 97 && ch.bytes[0] <= 122) {
        ch = String.fromCodePoint(ch.bytes[0] - 32)
      }
      drawGlyph_(BuiltinFont.glyph(ch), cursor, y, scale, color)
      cursor = cursor + advance
      i = i + 1
    }
  }

  // Walk the 7×5 bit grid and emit one tinted 1×1 sprite per
  // "on" pixel. Inner loops use index counters (not for-in) so
  // the closure-upvalue bug doesn't drop mutations.
  drawGlyph_(glyph, x, y, scale, color) {
    var row = 0
    while (row < 7) {
      var bits = glyph[row]
      var col = 0
      while (col < 5) {
        // Bit (4 - col) — leftmost column is the high bit so
        // the source grid reads left → right.
        var bit = (1 << (4 - col))
        // Wren has no `&` operator; reproduce via division +
        // integer modulus. `bit` is always a power of two so
        // `(bits / bit).floor % 2` extracts the single bit.
        var on = (bits / bit).floor % 2 == 1
        if (on) {
          _renderer.drawSpriteTinted(_whiteTex,
              x + col * scale, y + row * scale, scale, scale,
              color[0], color[1], color[2], color[3])
        }
        col = col + 1
      }
      row = row + 1
    }
  }

  /// Measure the on-screen pixel size a `label(...)` call will
  /// produce. Useful for centred / right-aligned text.
  ///
  /// @param  {String} text
  /// @param  {Num}    scale
  /// @returns {List}  `[width, height]`
  static measure(text, scale) {
    if (text.count == 0) return [0, 0]
    var w = text.count * (BuiltinFont.cellWidth + BuiltinFont.spacing) * scale - BuiltinFont.spacing * scale
    var h = BuiltinFont.cellHeight * scale
    return [w, h]
  }

  /// Returns `true` on the single frame `(x, y, w, h)` was
  /// pressed inside. Renders the button as a filled rectangle
  /// with a centred label; the body and text colours change on
  /// hover / active for visual feedback.
  ///
  /// Internally hashes `id = "%(x):%(y):%(label)"` to track
  /// hover + press state across frames so callers don't thread
  /// any per-button bookkeeping through.
  ///
  /// @param  {String} text
  /// @param  {Num}    x
  /// @param  {Num}    y
  /// @param  {Num}    w
  /// @param  {Num}    h
  /// @returns {Bool}
  button(text, x, y, w, h) {
    return button(text, x, y, w, h, HUD.DEFAULT_BUTTON_THEME_)
  }

  /// As `button(text, x, y, w, h)` with an explicit theme map.
  /// Theme keys (all optional, with sensible defaults):
  ///
  /// | Key | Type | Default | Notes |
  /// |---|---|---|---|
  /// | `bg`      | `[r,g,b,a]` | `[0.18, 0.20, 0.24, 0.92]` | Idle body. |
  /// | `bgHover` | `[r,g,b,a]` | `[0.26, 0.30, 0.36, 0.96]` | Mouse over. |
  /// | `bgActive`| `[r,g,b,a]` | `[0.10, 0.12, 0.14, 1.0]`  | Mouse held. |
  /// | `fg`      | `[r,g,b,a]` | `[1, 1, 1, 1]` | Idle label. |
  /// | `fgActive`| `[r,g,b,a]` | `[0.80, 0.85, 1.0, 1]`     | Mouse held label. |
  /// | `border`  | `[r,g,b,a]` | `null`           | If set, drawn 1px around the body. |
  /// | `scale`   | `Num`       | `2`              | Label scale. |
  ///
  /// @param  {String} text
  /// @param  {Num}    x
  /// @param  {Num}    y
  /// @param  {Num}    w
  /// @param  {Num}    h
  /// @param  {Map}    theme
  /// @returns {Bool}
  button(text, x, y, w, h, theme) {
    if (_renderer == null) {
      Fiber.abort("HUD.button: call beginFrame(g, renderer) first.")
    }
    var id = "%(x):%(y):%(text)"
    var hovering = pointInside_(_input.mouseX, _input.mouseY, x, y, w, h)
    if (hovering) _hoverButton = id

    var pressed = false
    if (hovering && _input.mouseJustPressed("left")) {
      _activeButton = id
    }
    if (_input.mouseJustReleased("left")) {
      if (_activeButton == id && hovering) {
        pressed = true
      }
      _activeButton = null
    }

    var active = _activeButton == id && hovering
    var bgKey  = active ? "bgActive" : (hovering ? "bgHover" : "bg")
    var fgKey  = active ? "fgActive" : "fg"
    rect(x, y, w, h, theme[bgKey])
    if (theme.containsKey("border") && theme["border"] != null) {
      border(x, y, w, h, 1, theme["border"])
    }

    var scale = theme.containsKey("scale") ? theme["scale"] : 2
    var size  = HUD.measure(text, scale)
    var lx    = (x + (w - size[0]) / 2).floor
    var ly    = (y + (h - size[1]) / 2).floor
    label(text, lx, ly, scale, theme[fgKey])
    return pressed
  }

  /// Default button theme. Override individual keys at the call
  /// site (`button(text, x, y, w, h, { "fg": [1, 0, 0, 1] })`).
  static DEFAULT_BUTTON_THEME_ {
    if (THEME_CACHE_[0] != null) return THEME_CACHE_[0]
    THEME_CACHE_[0] = {
      "bg":       [0.18, 0.20, 0.24, 0.92],
      "bgHover":  [0.26, 0.30, 0.36, 0.96],
      "bgActive": [0.10, 0.12, 0.14, 1.0],
      "fg":       [1.0,  1.0,  1.0,  1.0],
      "fgActive": [0.80, 0.85, 1.0,  1.0],
      "border":   null,
      "scale":    2
    }
    return THEME_CACHE_[0]
  }

  // Point-in-axis-aligned-box test. Inclusive on the left / top,
  // exclusive on the right / bottom so neighbouring buttons sharing
  // an edge don't both report `hovering = true`.
  pointInside_(px, py, x, y, w, h) {
    return px >= x && px < x + w && py >= y && py < y + h
  }
}

// Module-private one-cell caches. Same pattern as `ACTION_REGISTRY_`
// / `TWEEN_LIST_` — Wren's `__foo` static-field plumbing is brittle
// through this codebase's class table, so module-level vars sidestep
// the issue. One-element Lists keep the slot mutable.
var GLYPH_CACHE_ = [null]
var THEME_CACHE_ = [null]
