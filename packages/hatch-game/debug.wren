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
