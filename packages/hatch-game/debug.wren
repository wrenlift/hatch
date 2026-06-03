// @hatch:game/debug — diagnostic overlays for the per-frame loop.
//
// `FrameTimer` keeps a rolling window of recent `dt` values so the
// game can read FPS, frame budget, and 1%-low spikes without
// holding its own ring buffer. `DebugOverlay` renders a compact
// panel through any HUD-shaped object: shows current FPS, average
// frame ms, the 1%-low, and the configured live-system counts the
// caller pumps in.

/// Rolling-window frame timer. `tick(dt)` each frame; the timer
/// keeps the last `capacity` samples (default 120 → 2 s at 60 fps)
/// and exposes summary statistics over them.
///
/// ## Example
///
/// ```wren
/// var ft = FrameTimer.new()
/// // ... in update:
/// ft.tick(g.dt)
/// System.print("%(ft.fps.floor) fps  %(ft.avgMs)ms avg  %(ft.lowFps.floor) 1%% low")
/// ```
class FrameTimer {
  /// Build a timer holding the last `capacity` samples (default
  /// 120 — 2 seconds at 60 fps).
  ///
  /// @param {Num} capacity
  construct new(capacity) {
    if (capacity < 1) Fiber.abort("FrameTimer.new: capacity must be >= 1")
    _samples = List.filled(capacity, 0)
    _capacity = capacity
    _head = 0
    _count = 0
  }

  /// Default-capacity 120-sample timer.
  construct new() {
    _samples = List.filled(120, 0)
    _capacity = 120
    _head = 0
    _count = 0
  }

  /// Push one frame's `dt` (in seconds) into the rolling window.
  /// Overwrites the oldest sample once the window is full.
  ///
  /// @param {Num} dt
  tick(dt) {
    _samples[_head] = dt
    _head = (_head + 1) % _capacity
    if (_count < _capacity) _count = _count + 1
  }

  /// Number of valid samples currently in the window.
  /// @returns {Num}
  count    { _count }
  /// Total window size — `count` saturates at this. @returns {Num}
  capacity { _capacity }

  /// Average dt across the window (seconds).
  /// @returns {Num}
  avg {
    if (_count == 0) return 0
    var sum = 0
    var i = 0
    while (i < _count) {
      sum = sum + _samples[i]
      i = i + 1
    }
    return sum / _count
  }

  /// Average frame time in milliseconds.
  /// @returns {Num}
  avgMs { avg * 1000 }

  /// Frames-per-second derived from `avg`. Zero on an empty
  /// window. @returns {Num}
  fps {
    var a = avg
    if (a <= 0) return 0
    return 1 / a
  }

  /// 1% low FPS — derived from the WORST 1% of the window's
  /// frame times. Common metric for stutter detection: a game
  /// can read 60 fps average but a 25 fps 1%-low means
  /// double-frame hitches a percent of the time. Empty window
  /// returns 0. @returns {Num}
  lowFps {
    if (_count == 0) return 0
    // Lazy snapshot + sort. We don't keep the array sorted
    // online because tick() is hot and sorts are cold (read by
    // the debug overlay at HUD-frequency, not every frame).
    var snap = []
    var i = 0
    while (i < _count) {
      snap.add(_samples[i])
      i = i + 1
    }
    // Insertion sort — _count is bounded by capacity (default
    // 120) so an O(N²) sort runs in a few hundred microseconds.
    var k = 1
    while (k < snap.count) {
      var v = snap[k]
      var j = k - 1
      while (j >= 0 && snap[j] > v) {
        snap[j + 1] = snap[j]
        j = j - 1
      }
      snap[j + 1] = v
      k = k + 1
    }
    // Bottom 1% — the worst dt is at the END of the sorted list.
    var nLow = (_count * 0.01).ceil
    if (nLow < 1) nLow = 1
    var sum = 0
    var s = snap.count - nLow
    while (s < snap.count) {
      sum = sum + snap[s]
      s = s + 1
    }
    var lowAvg = sum / nLow
    if (lowAvg <= 0) return 0
    return 1 / lowAvg
  }

  /// Reset every accumulated sample. Useful after a long load
  /// where the first frame's dt would skew the average.
  reset {
    _head  = 0
    _count = 0
  }
}

/// Renders a small diagnostic panel through a HUD. Pumps a
/// `FrameTimer` from the game's per-frame dt and exposes labelled
/// counters for ECS systems / live particles / draw calls that
/// the caller updates.
///
/// ## Example
///
/// ```wren
/// var overlay = DebugOverlay.new()
/// // ... per frame:
/// overlay.tick(g.dt)
/// overlay.setCounter("entities", world.count)
/// overlay.setCounter("particles", fx.liveCount)
/// // ... in draw:
/// overlay.draw(hud, 10, 10)
/// ```
class DebugOverlay {
  construct new() {
    _timer    = FrameTimer.new()
    _counters = {}     // name → Num
    _enabled  = true
  }

  /// True when [draw] is allowed to render. Toggle from any
  /// keyboard / gamepad handler (F12 conventionally).
  /// @returns {Bool}
  isEnabled    { _enabled }
  /// Show / hide the overlay.
  isEnabled=(b) { _enabled = b }

  /// Underlying [FrameTimer]. Exposed so callers reading the same
  /// stats elsewhere (telemetry, /metrics endpoint) don't need
  /// two ticking sources. @returns {FrameTimer}
  timer        { _timer }

  /// Push one frame's `dt` into the timer.
  /// @param {Num} dt
  tick(dt) { _timer.tick(dt) }

  /// Set a named counter. Updated per-frame from the caller's own
  /// state — the overlay just renders whatever's most recently set.
  ///
  /// @param {String} name
  /// @param {Num} value
  setCounter(name, value) { _counters[name] = value }

  /// Look up a counter; returns 0 if missing.
  /// @param {String} name
  /// @returns {Num}
  counter(name) { _counters.containsKey(name) ? _counters[name] : 0 }

  /// Drop every named counter without resetting the frame timer.
  clearCounters() { _counters = {} }

  /// Render the panel via `hud`. `hud` must expose `.label(text,
  /// x, y, scale, color)` and `.rect(x, y, w, h, color)` —
  /// `@hatch:hud`'s HUD class fits this shape.
  ///
  /// @param {HUD} hud
  /// @param {Num} x
  /// @param {Num} y
  draw(hud, x, y) {
    if (!_enabled) return
    var lines = []
    lines.add("FPS  %(_timer.fps.floor)")
    lines.add("ms   %(_timer.avgMs.floor)")
    lines.add("1%%  %(_timer.lowFps.floor)")
    for (k in _counters.keys) {
      lines.add("%(k)  %(_counters[k])")
    }
    var lineH = 14
    var pad = 6
    var panelW = 130
    var panelH = lines.count * lineH + pad * 2
    hud.rect(x, y, panelW, panelH, [0.05, 0.05, 0.07, 0.85])
    var i = 0
    while (i < lines.count) {
      hud.label(lines[i], x + pad, y + pad + i * lineH, 1, [0.95, 0.95, 0.98, 1.0])
      i = i + 1
    }
  }
}

/// Per-entity component lister. Walks every live entity in the
/// `World`, lists which component classes it carries, and renders
/// the result through a HUD. Useful for spelunking live game state
/// without a graphical editor — toggle it on with a keybind and
/// scroll through with up / down.
///
/// `tick(world)` refreshes the snapshot. `draw(hud, x, y)` renders
/// the panel; if the snapshot has more rows than fit, scroll the
/// list with `scrollUp` / `scrollDown` (or wire the bindings via
/// `@hatch:game.Actions`).
///
/// ## Example
///
/// ```wren
/// var insp = EntityInspector.new()
/// // ... per frame:
/// insp.tick(world)
/// if (g.input.justPressed("F11")) insp.toggle()
/// // ... in draw:
/// insp.draw(hud, 200, 10)
/// ```
class EntityInspector {
  /// Configure with default size (16 visible rows, panel 240 px
  /// wide). Use the setters below to override.
  construct new() {
    _visible    = false
    _rows       = 16
    _panelW     = 240
    _scroll     = 0
    _selected   = 0
    _snapshot   = []     // List<{ "id": Num, "comps": List<String> }>
    _totalCount = 0
  }

  /// Toggle visibility — invoke from a keybind handler.
  toggle      { _visible = !_visible }
  /// @returns {Bool}
  visible     { _visible }
  /// @param {Bool} v
  visible=(v) { _visible = v }

  rows        { _rows }
  /// @param {Num} n. Number of entity rows visible at once.
  rows=(n)    { _rows = n }
  panelWidth      { _panelW }
  panelWidth=(w)  { _panelW = w }

  /// Refresh the entity snapshot. Allocates internally — call once
  /// per frame at most, ideally only when the inspector is visible.
  /// @param {World} world
  tick(world) {
    if (!_visible) return
    _snapshot.clear()
    var ids = world.entities
    _totalCount = ids.count
    var classes = world.componentTypes
    var i = 0
    while (i < ids.count) {
      var e = ids[i]
      var comps = []
      var j = 0
      while (j < classes.count) {
        if (world.has(e, classes[j])) comps.add(classes[j].toString)
        j = j + 1
      }
      _snapshot.add({ "id": e, "comps": comps })
      i = i + 1
    }
    if (_selected >= _snapshot.count) _selected = _snapshot.count - 1
    if (_selected < 0) _selected = 0
  }

  /// Move the highlight one row up (clamped at top).
  scrollUp {
    if (_selected > 0) _selected = _selected - 1
    if (_selected < _scroll) _scroll = _selected
  }

  /// Move the highlight one row down (clamped at bottom).
  scrollDown {
    if (_selected < _snapshot.count - 1) _selected = _selected + 1
    if (_selected >= _scroll + _rows) _scroll = _selected - _rows + 1
  }

  /// Currently-highlighted entity id, or `null` if the snapshot
  /// is empty.
  /// @returns {Num|Null}
  selectedEntity {
    if (_snapshot.count == 0) return null
    return _snapshot[_selected]["id"]
  }

  /// Render the inspector panel. The HUD-shaped object must expose
  /// `rect(x, y, w, h, color)` and `label(text, x, y, scale, color)`
  /// (the immediate-mode `@hatch:hud.HUD` works). Returns the
  /// panel's drawn height so callers can stack other overlays.
  ///
  /// @param  {HUD} hud
  /// @param  {Num} x
  /// @param  {Num} y
  /// @returns {Num}
  draw(hud, x, y) {
    if (!_visible) return 0
    var lineH = 14
    var pad = 6
    var headerH = lineH + pad
    var rowsToShow = _rows < _snapshot.count ? _rows : _snapshot.count
    var detailLines = 0
    if (_snapshot.count > 0) {
      detailLines = _snapshot[_selected]["comps"].count
    }
    var panelH = headerH + rowsToShow * lineH + detailLines * lineH + pad * 3

    hud.rect(x, y, _panelW, panelH, [0.05, 0.05, 0.07, 0.85])
    hud.label("entities %(_snapshot.count) / %(_totalCount)",
              x + pad, y + pad, 1, [0.65, 0.85, 0.95, 1.0])

    var rowY = y + pad + headerH
    var i = 0
    while (i < rowsToShow) {
      var idx = _scroll + i
      if (idx >= _snapshot.count) break
      var row = _snapshot[idx]
      var label = "#%(row["id"])  (%(row["comps"].count))"
      var color = idx == _selected ? [1.0, 0.95, 0.55, 1.0] : [0.85, 0.85, 0.9, 1.0]
      hud.label(label, x + pad, rowY + i * lineH, 1, color)
      i = i + 1
    }

    // Detail rows for the selected entity.
    if (_snapshot.count > 0) {
      var detailY = rowY + rowsToShow * lineH + pad
      var comps = _snapshot[_selected]["comps"]
      var c = 0
      while (c < comps.count) {
        hud.label("  " + comps[c], x + pad, detailY + c * lineH, 1, [0.7, 0.9, 0.75, 1.0])
        c = c + 1
      }
    }
    return panelH
  }
}

/// Wireframe overlay for 2D collision shapes. Iterates every
/// `(Transform, Collider)` entity and draws the shape outline via
/// a HUD's `border()` / `rect()`. Box / ball / capsule shapes from
/// `@hatch:physics.Collider2D` are supported; unknown shapes are
/// skipped. The 3D analogue waits for a 3D line-drawer primitive
/// (`@hatch:gpu` doesn't ship one yet — Phase 10-followup).
///
/// The caller passes a `projectFn` closure that maps world-space
/// `(x, y)` to screen-space `[sx, sy]` (returned as a 2-element
/// list). For simple identity-mapped 2D scenes the closure can be
/// `Fn.new {|wx, wy| [wx, wy] }`; cameras with offset / scale
/// build the corresponding transform.
///
/// ## Example
///
/// ```wren
/// // Identity projection for design-space 2D:
/// var project = Fn.new {|wx, wy| [wx, wy] }
/// // ... per frame in draw:
/// PhysicsDebugDraw.run(world, hud, project)
/// ```
class PhysicsDebugDraw {
  /// Default green wireframe (`[0.4, 0.95, 0.5, 1.0]`).
  ///
  /// @param {World} world
  /// @param {HUD}   hud
  /// @param {Fn}    projectFn. `{|wx, wy| [sx, sy] }`.
  static run(world, hud, projectFn) {
    var color = [0.4, 0.95, 0.5, 1.0]
    PhysicsDebugDraw.runWith(world, hud, projectFn, color)
  }

  /// Same as `run` but the caller picks the wireframe colour.
  /// `color` is a 4-element `[r, g, b, a]` list in `[0, 1]`.
  static runWith(world, hud, projectFn, color) {
    var ck = PhysicsDebugDraw.colliderClass_(world)
    var tk = PhysicsDebugDraw.transformClass_(world)
    if (ck == null || tk == null) return
    for (e in world.query(ck)) {
      var collider = world.get(e, ck)
      if (collider == null) continue
      var t = world.get(e, tk)
      if (t == null) continue
      var shape = collider.shape
      if (!(shape is Map)) continue
      var kind = shape["kind"]
      if (kind == "box") {
        PhysicsDebugDraw.drawBox_(hud, projectFn, t, shape, color)
      } else if (kind == "ball") {
        PhysicsDebugDraw.drawBall_(hud, projectFn, t, shape, color)
      } else if (kind == "capsule") {
        PhysicsDebugDraw.drawCapsule_(hud, projectFn, t, shape, color)
      }
    }
  }

  // Duck-type the Collider / Transform classes from the world's
  // componentTypes so this module doesn't hard-import `scene.wren`
  // (keeps the debug overlay self-contained / mockable).
  static colliderClass_(world) {
    for (k in world.componentTypes) {
      if (k.toString == "Collider") return k
    }
    return null
  }

  static transformClass_(world) {
    for (k in world.componentTypes) {
      if (k.toString == "Transform") return k
    }
    return null
  }

  static drawBox_(hud, projectFn, t, shape, color) {
    var hw = shape["halfWidth"]
    var hh = shape["halfHeight"]
    var pos = t.position
    var tl = projectFn.call(pos.x - hw, pos.y - hh)
    var br = projectFn.call(pos.x + hw, pos.y + hh)
    hud.border(tl[0], tl[1], br[0] - tl[0], br[1] - tl[1], 1, color)
  }

  static drawBall_(hud, projectFn, t, shape, color) {
    var r = shape["radius"]
    var pos = t.position
    var tl = projectFn.call(pos.x - r, pos.y - r)
    var br = projectFn.call(pos.x + r, pos.y + r)
    var c  = projectFn.call(pos.x, pos.y)
    var sw = br[0] - tl[0]
    var sh = br[1] - tl[1]
    hud.border(tl[0], tl[1], sw, sh, 1, color)
    // Cross hatch through the centre so balls are distinguishable
    // from boxes.
    hud.rect(tl[0], c[1] - 0.5, sw, 1, color)
    hud.rect(c[0] - 0.5, tl[1], 1, sh, color)
  }

  static drawCapsule_(hud, projectFn, t, shape, color) {
    var hh = shape["halfHeight"]
    var r  = shape["radius"]
    var pos = t.position
    var tl = projectFn.call(pos.x - r, pos.y - hh - r)
    var br = projectFn.call(pos.x + r, pos.y + hh + r)
    hud.border(tl[0], tl[1], br[0] - tl[0], br[1] - tl[1], 1, color)
  }
}

/// Deterministic-replay input capture. `record(snapshot)` saves a
/// per-frame snapshot of pressed keys / mouse buttons; `frames`
/// returns the recorded list so callers can serialise it to disk.
/// Pairs with `InputReplayer` for playback.
///
/// A "snapshot" is a plain Map (e.g. `{"keys": ["Space"], "mouse":
/// ["left"]}`) so the recorder is decoupled from the live
/// `Input` shape — the caller builds whatever envelope they want.
/// The matching `InputReplayer` walks the captured list one frame
/// at a time.
///
/// ## Example
///
/// ```wren
/// var rec = InputRecorder.new()
/// // ... per frame:
/// rec.record({
///   "keys":  g.input.pressedKeys,
///   "mouse": g.input.pressedMouseButtons
/// })
/// // ... save:
/// File.write("replay.json", JSON.encode(rec.frames))
/// ```
class InputRecorder {
  construct new() {
    _frames = []
  }

  /// Append a snapshot to the recording. Plain Map; callers shape
  /// it freely so the recorder works against any `Input`.
  /// @param {Map} snapshot
  record(snapshot) { _frames.add(snapshot) }

  /// Captured snapshots in order. Caller owns serialisation.
  /// @returns {List<Map>}
  frames { _frames }

  /// Number of frames captured so far.
  /// @returns {Num}
  count  { _frames.count }

  /// Discard the recording — fresh start.
  reset  { _frames = [] }
}

/// Walks captured frames produced by `InputRecorder` in order.
/// Pull each frame's snapshot with `next` and apply it however
/// the host wants (substituting for live `g.input` while in
/// replay mode is the typical shape).
class InputReplayer {
  /// @param {List<Map>} frames. Same shape `InputRecorder.frames`
  ///   produces.
  construct new(frames) {
    if (frames == null) Fiber.abort("InputReplayer.new: frames must be non-null")
    _frames = frames
    _cursor = 0
  }

  /// True if there are still frames left to replay.
  /// @returns {Bool}
  hasNext { _cursor < _frames.count }

  /// Advance and return the next captured snapshot, or `null` if
  /// the recording is exhausted.
  /// @returns {Map|Null}
  next {
    if (!hasNext) return null
    var f = _frames[_cursor]
    _cursor = _cursor + 1
    return f
  }

  /// Number of frames consumed so far.
  cursor { _cursor }

  /// Rewind to the start without rebuilding the replayer.
  reset { _cursor = 0 }
}
