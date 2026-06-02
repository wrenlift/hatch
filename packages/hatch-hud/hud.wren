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
    // Gamepad focus nav. _focusables is the per-frame registration
    // order of focusable widgets (each `button(...)` call appends
    // its id during the draw pass). _lastFocusables is the
    // previous frame's snapshot — used at `beginFrame` to translate
    // a DPad / stick step into the *current* focused id, since this
    // frame's list isn't built yet at input-time. _focusedId is the
    // id that should read as "focused" during this frame's button
    // calls.
    _focusables     = []
    _lastFocusables = []
    _focusIndex     = -1
    _focusedId      = null
    _axisLatched_   = {}      // axis code → last frame's "past threshold" bit
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
    // ByteArray (not a plain List) so the gpu_web bridge — which
    // reads slot bytes via wrenGetSlotBytes — can take the upload
    // path. Lists aren't a typed-array kind and would silently
    // return null on the web side, aborting at the foreign call.
    device.writeTexture(tex, ByteArray.fromList([255, 255, 255, 255]),
                        { "width": 1, "height": 1, "bytesPerRow": 4 })
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
    // Snapshot last frame's focusable widgets so DPad / stick nav
    // can advance through them BEFORE this frame's button() calls
    // rebuild the list.
    _lastFocusables = _focusables
    _focusables     = []
    // Step focus on gamepad DPad / left-stick edge events. Stick
    // is read as one step per crossing into ±0.5 — Input's
    // `gamepadJustPressed` already handles the press/release edge
    // for DPad buttons; for stick axes we fold the threshold into
    // a synthetic press-once cadence in `axisStepped_`.
    if (g.input != null && _lastFocusables.count > 0) {
      var step = 0
      if (g.input.gamepadJustPressed("GamepadDPadDown") ||
          axisStepped_("GamepadAxisLY", g.input, 0.5)) step = 1
      if (g.input.gamepadJustPressed("GamepadDPadUp") ||
          axisStepped_("GamepadAxisLY", g.input, -0.5)) step = -1
      if (step != 0) {
        if (_focusIndex < 0) {
          _focusIndex = step > 0 ? 0 : _lastFocusables.count - 1
        } else {
          _focusIndex = ((_focusIndex + step) % _lastFocusables.count + _lastFocusables.count) % _lastFocusables.count
        }
      }
      if (_focusIndex >= 0 && _focusIndex < _lastFocusables.count) {
        _focusedId = _lastFocusables[_focusIndex]
      } else {
        _focusedId = null
      }
    } else if (_lastFocusables.count == 0) {
      _focusIndex = -1
      _focusedId  = null
    }
  }

  // True only on the frame the named axis CROSSES `threshold` from
  // the wrong side — gives the analog stick the same one-step-per-
  // tap cadence as the DPad. State lives in `_axisLatched`.
  axisStepped_(code, input, threshold) {
    var v = 0
    if (input.gamepadAxisMap != null && input.gamepadAxisMap.containsKey(code)) {
      v = input.gamepadAxisMap[code]
    }
    if (_axisLatched_ == null) _axisLatched_ = {}
    var was = _axisLatched_.containsKey(code) ? _axisLatched_[code] : false
    var now
    if (threshold > 0) {
      now = v >= threshold
    } else {
      now = v <= threshold
    }
    _axisLatched_[code] = now
    return now && !was
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
    // Register this widget into the per-frame focusable list so
    // next frame's `beginFrame` can step DPad / stick nav through
    // it. Registration order = navigation order.
    _focusables.add(id)
    var hovering = pointInside_(_input.mouseX, _input.mouseY, x, y, w, h)
    if (hovering) _hoverButton = id
    var focused = (id == _focusedId)

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
    // Gamepad A → press the focused button. Doesn't drive an
    // active-press state since the button-down → button-up cadence
    // is one frame on most pads; we just resolve `pressed` on the
    // edge.
    if (focused && _input.gamepadJustPressed("GamepadButtonA")) {
      pressed = true
    }

    var active = _activeButton == id && hovering
    // Focused-but-not-mouse-active reads as the hover theme so the
    // visual feedback is consistent across pointing devices.
    var bgKey  = active ? "bgActive" : ((hovering || focused) ? "bgHover" : "bg")
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

  /// Exposed for HUDPanel + custom widgets that need the same
  /// box hit test the built-in widgets use.
  pointInside(px, py, x, y, w, h) {
    return pointInside_(px, py, x, y, w, h)
  }

  /// Internal access to the live `Input` snapshot taken at
  /// `beginFrame`. HUDPanel reads `mouseX` / `mouseY` /
  /// `mouseIsPressed` / `mouseJustPressed` / `mouseJustReleased`
  /// here so it can resolve slider drag + checkbox click without
  /// the consumer threading the input object through every call.
  /// Returns `null` between frames.
  /// @returns {Input}
  input_ { _input }
}

/// Immediate-mode debug panel for runtime configuration. Stacks
/// `slider` / `toggle` /
/// `button` / `text` / `divider` rows top-down inside a fixed-
/// width box so a procedural-world demo can expose every knob
/// (wind strength, water amplitude, sun angle, terrain seed) at
/// runtime without rebuilding the bundle.
///
/// Layout is immediate-mode: each row is added in the order the
/// caller invokes the method, the panel auto-advances its
/// internal cursor, and the next `beginFrame` resets to the top.
/// State that has to live across frames (slider drag, hover
/// highlight) is keyed by row label + position string so the same
/// label at the same coordinate keeps its identity frame-to-
/// frame.
///
/// ## Example
///
/// ```wren
/// // setup
/// _panel = HUDPanel.new(_hud, {
///   "x": 16, "y": 16, "width": 240, "title": "WORLD"
/// })
/// _waveOpts = { "amplitude": 0.4, "scale": 0.2, "timeScale": 0.5 }
///
/// // draw, called from your Game.draw via the HUD beginFrame/end pair
/// _panel.beginFrame()
/// _panel.text("FPS", g.fps.round.toString)
/// _panel.divider()
/// _panel.slider("amplitude", _waveOpts, "amplitude", 0,   2)
/// _panel.slider("scale",     _waveOpts, "scale",     0.05, 1)
/// _panel.slider("timeScale", _waveOpts, "timeScale", 0,   2)
/// _panel.toggle("show wind", _state, "showWind")
/// _panel.button("reset camera") {|| _camera.lookAt(...) }
/// ```
class HUDPanel {
  static ROW_HEIGHT_ { 20 }
  static ROW_GAP_    { 4 }
  static TITLE_H_    { 22 }
  static LABEL_W_    { 80 }
  static PAD_        { 8 }

  /// Build a panel against `hud`. `opts` keys:
  ///   - `"x"` (Num, default 16) — left edge in screen pixels.
  ///   - `"y"` (Num, default 16) — top edge.
  ///   - `"width"` (Num, default 240) — panel width.
  ///   - `"title"` (String, default null) — when set, a title bar
  ///     renders at the top of the panel.
  ///   - `"theme"` (Map, optional) — `{ "bg", "row", "rowHover",
  ///     "track", "thumb", "thumbActive", "text", "muted",
  ///     "accent" }`, all `[r, g, b, a]` colours; defaults are a
  ///     muted dark-blue theme tuned for readability on a
  ///     procedural-world background.
  ///
  /// @param {HUD} hud
  /// @param {Map} opts
  construct new(hud, opts) {
    _hud   = hud
    _x     = opts.containsKey("x")     ? opts["x"]     : 16
    _y0    = opts.containsKey("y")     ? opts["y"]     : 16
    _w     = opts.containsKey("width") ? opts["width"] : 240
    _title = opts.containsKey("title") ? opts["title"] : null
    _theme = HUDPanel.mergeTheme_(opts.containsKey("theme") ? opts["theme"] : null)
    // Integer multiplier on every row size + font scale. The
    // bitmap font is on a 5×7 grid; only integer multiples land on
    // whole pixels. Default 1 keeps callers source-compatible.
    var s = opts.containsKey("scale") ? opts["scale"] : 1
    if (s < 1) s = 1
    _scale   = s.floor
    _rowH    = (HUDPanel.ROW_HEIGHT_ * _scale).floor
    _rowGap  = (HUDPanel.ROW_GAP_    * _scale).floor
    _titleH  = (HUDPanel.TITLE_H_    * _scale).floor
    _labelW  = (HUDPanel.LABEL_W_    * _scale).floor
    _pad     = (HUDPanel.PAD_        * _scale).floor
    _cursor = 0
    // Slider grab persists across frames: id of the active slider
    // plus the (min, max, obj, key) it's mutating. Null when no
    // slider is being dragged.
    _activeSlider = null
  }

  static mergeTheme_(override) {
    var base = HUDPanel.DEFAULT_THEME_
    if (override == null) return base
    var out = {}
    for (k in base.keys) out[k] = override.containsKey(k) ? override[k] : base[k]
    return out
  }

  static DEFAULT_THEME_ {
    if (PANEL_THEME_CACHE_[0] != null) return PANEL_THEME_CACHE_[0]
    PANEL_THEME_CACHE_[0] = {
      "bg":          [0.06, 0.08, 0.12, 0.88],
      "titleBg":     [0.10, 0.14, 0.20, 0.95],
      "row":         [0.10, 0.13, 0.18, 0.60],
      "rowHover":    [0.16, 0.20, 0.28, 0.75],
      "track":       [0.04, 0.05, 0.07, 1.0],
      "thumb":       [0.55, 0.70, 0.95, 1.0],
      "thumbActive": [0.85, 0.95, 1.00, 1.0],
      "checkOff":    [0.04, 0.05, 0.07, 1.0],
      "checkOn":     [0.55, 0.70, 0.95, 1.0],
      "text":        [0.90, 0.92, 0.96, 1.0],
      "muted":       [0.55, 0.60, 0.68, 1.0],
      "accent":      [0.55, 0.70, 0.95, 1.0]
    }
    return PANEL_THEME_CACHE_[0]
  }

  /// Start a frame. Resets the row cursor to the top of the panel
  /// and draws the background + title bar. Call between
  /// `hud.beginFrame(...)` and `hud.endFrame`.
  beginFrame() {
    _cursor = _y0
    // Background panel + optional title bar. Body height grows
    // with each row; we draw the background after the rows in
    // endFrame... but immediate-mode means rows are drawn on top
    // of a pre-rendered background. Compromise: draw a "tall"
    // background that the row content overdraws. A more precise
    // background pass needs a deferred draw queue and isn't worth
    // the complexity for an MVP.
    var hud = _hud
    hud.rect(_x, _cursor, _w, _titleH + 8 * _scale, _theme["bg"])
    if (_title != null) {
      hud.rect(_x, _cursor, _w, _titleH, _theme["titleBg"])
      hud.label(_title, _x + _pad, _cursor + 6 * _scale, 2 * _scale, _theme["text"])
      _cursor = _cursor + _titleH + _rowGap
    } else {
      _cursor = _cursor + _pad
    }
  }

  /// Numeric slider. The track is split between a `LABEL_W_`
  /// label column on the left and a track + thumb on the right.
  /// Click anywhere on the track to jump the thumb; drag to scrub.
  ///
  /// Mutates `obj[key]` in place. Returns the current value for
  /// callers that want to read it without a second map lookup.
  ///
  /// @param {String} label
  /// @param {Map} obj
  /// @param {String} key
  /// @param {Num} min
  /// @param {Num} max
  /// @returns {Num}
  slider(label, obj, key, min, max) {
    var hud = _hud
    var y = _cursor
    var rowH = _rowH

    var pad = _pad
    var labelW = _labelW
    var trackX = _x + pad + labelW + pad
    var trackW = _x + _w - pad - trackX

    var input = hud.input_
    var mx = input == null ? -1 : input.mouseX
    var my = input == null ? -1 : input.mouseY
    var trackHover = hud.pointInside(mx, my, trackX, y, trackW, rowH)

    var id = "%(_x):%(y):slider:%(label)"
    if (trackHover && input != null && input.mouseJustPressed("left")) {
      _activeSlider = id
    }
    if (input != null && input.mouseJustReleased("left")) {
      if (_activeSlider == id) _activeSlider = null
    }

    var v = obj[key]
    if (_activeSlider == id) {
      var clamped = mx
      if (clamped < trackX) clamped = trackX
      if (clamped > trackX + trackW) clamped = trackX + trackW
      var frac = (clamped - trackX) / trackW
      v = min + frac * (max - min)
      obj[key] = v
    }
    var frac = (v - min) / (max - min)
    if (frac < 0) frac = 0
    if (frac > 1) frac = 1

    // Row body + label.
    hud.rect(_x + pad / 2, y, _w - pad, rowH, _theme["row"])
    hud.label(label, _x + pad, y + 6 * _scale, _scale, _theme["text"])

    // Track + thumb.
    var trackH = 4 * _scale
    var trackY = y + ((rowH - trackH) / 2).floor
    hud.rect(trackX, trackY, trackW, trackH, _theme["track"])
    var thumbW = 6 * _scale
    var thumbX = (trackX + frac * (trackW - thumbW)).floor
    var thumbColor = (_activeSlider == id) ? _theme["thumbActive"] : _theme["thumb"]
    hud.rect(thumbX, y + 3 * _scale, thumbW, rowH - 6 * _scale, thumbColor)

    // Numeric readout, right-aligned within the track column.
    var readout = HUDPanel.formatNum_(v)
    var size = HUD.measure(readout, _scale)
    hud.label(readout, trackX + trackW - size[0], y + rowH - size[1] - 2 * _scale, _scale, _theme["muted"])

    _cursor = _cursor + rowH + _rowGap
    return v
  }

  /// Boolean toggle. Click the checkbox to flip `obj[key]`.
  /// Returns the current value.
  ///
  /// @param {String} label
  /// @param {Map} obj
  /// @param {String} key
  /// @returns {Bool}
  toggle(label, obj, key) {
    var hud = _hud
    var y = _cursor
    var rowH = _rowH
    var pad = _pad
    var boxSize = 14 * _scale
    var boxX = _x + _w - pad - boxSize
    var boxY = y + ((rowH - boxSize) / 2).floor

    var input = hud.input_
    var mx = input == null ? -1 : input.mouseX
    var my = input == null ? -1 : input.mouseY
    var rowHover = hud.pointInside(mx, my, _x, y, _w, rowH)
    if (rowHover && input != null && input.mouseJustPressed("left")) {
      obj[key] = !obj[key]
    }
    var v = obj[key]

    hud.rect(_x + pad / 2, y, _w - pad, rowH,
      rowHover ? _theme["rowHover"] : _theme["row"])
    hud.label(label, _x + pad, y + 6 * _scale, _scale, _theme["text"])
    hud.rect(boxX, boxY, boxSize, boxSize, _theme["checkOff"])
    if (v) {
      var inset = 3 * _scale
      hud.rect(boxX + inset, boxY + inset, boxSize - 2 * inset, boxSize - 2 * inset, _theme["checkOn"])
    }
    _cursor = _cursor + rowH + _rowGap
    return v
  }

  /// Pushbutton row. `cb` is invoked once when the button is
  /// clicked (mouse-down inside, mouse-up inside the same frame
  /// boundary as the host HUD's own `button`).
  ///
  /// @param {String} text
  /// @param {Fn} cb
  /// @returns {Bool}
  button(text, cb) {
    var hud = _hud
    var y = _cursor
    var rowH = _rowH
    var pad = _pad
    var pressed = hud.button(text, _x + pad / 2, y, _w - pad, rowH, HUDPanel.scaledButtonTheme_(_scale))
    if (pressed && cb != null) cb.call()
    _cursor = _cursor + rowH + _rowGap
    return pressed
  }

  // Default button theme with `scale` baked into the font size so
  // the label inside a panel button matches the surrounding row
  // labels' scale.
  static scaledButtonTheme_(scale) {
    var t = HUD.DEFAULT_BUTTON_THEME_
    return {
      "bg":       t["bg"],
      "bgHover":  t["bgHover"],
      "bgActive": t["bgActive"],
      "fg":       t["fg"],
      "fgActive": t["fgActive"],
      "border":   t["border"],
      "scale":    scale
    }
  }

  /// Read-only text row. Use for FPS, entity counts, cull rate —
  /// values the consumer computes once a frame and wants to
  /// display alongside the inputs.
  ///
  /// @param {String} label
  /// @param {String|Num} value
  text(label, value) {
    var hud = _hud
    var y = _cursor
    var rowH = _rowH
    var pad = _pad
    hud.rect(_x + pad / 2, y, _w - pad, rowH, _theme["row"])
    hud.label(label, _x + pad, y + 6 * _scale, _scale, _theme["text"])
    var v = value.toString
    var size = HUD.measure(v, _scale)
    hud.label(v, _x + _w - pad - size[0], y + 6 * _scale, _scale, _theme["muted"])
    _cursor = _cursor + rowH + _rowGap
  }

  /// Horizontal divider for visual grouping. One-pixel line plus
  /// a row's worth of padding.
  divider() {
    var hud = _hud
    var pad = _pad
    hud.rect(_x + pad, _cursor + 4 * _scale, _w - 2 * pad, _scale, _theme["muted"])
    _cursor = _cursor + _rowGap + 6 * _scale
  }

  /// Format a number for the slider readout. Two decimal places
  /// is the sweet spot for the typical [0, 10] knobs games tweak;
  /// integers print without a decimal point.
  static formatNum_(n) {
    if (n == n.floor) return n.toString
    var rounded = (n * 100).round / 100
    return rounded.toString
  }
}

// Module-private one-cell caches. Same pattern as `ACTION_REGISTRY_`
// / `TWEEN_LIST_` — Wren's `__foo` static-field plumbing is brittle
// through this codebase's class table, so module-level vars sidestep
// the issue. One-element Lists keep the slot mutable.
var GLYPH_CACHE_ = [null]
var THEME_CACHE_ = [null]
var PANEL_THEME_CACHE_ = [null]
