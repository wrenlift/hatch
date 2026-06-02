//! `@hatch:game/animation` — tweens, keyframe clips, and a per-game
//! `Tweens` manager that ticks every frame.
//!
//! Three layers, each useful on its own:
//!
//!   1. **Tween** — a single property animator. Goes from a number
//!      to another number over a duration, calling `onUpdate` with
//!      the interpolated value each frame. Chainable via `.then`
//!      (sequence) and `.also` (parallel).
//!   2. **Easing curves** — re-uses `@hatch:math`'s `Ease`. Pass the
//!      curve's string name (`"outCubic"`, `"inOutQuad"`) or a
//!      `Fn.new {|t| ...}` as the `easing` option on a tween.
//!   3. **Clip** + **AnimationPlayer** — keyframe sampling. A clip
//!      owns named tracks of `[time, value]` entries; a player
//!      drives one or more clips at a configurable speed, with
//!      looping / crossfade. Players bind to FSM statecharts via
//!      `player.bindStateChart(chart, map)` so transitioning the
//!      chart swaps the active clip.
//!
//! ```wren
//! import "@hatch:game" for Game, Tween, Tweens
//!
//! class MyGame is Game {
//!   construct new() {}
//!   setup(g) {
//!     _alpha = 0
//!     Tweens.add(Tween.new({
//!       "from":     0,
//!       "to":       1,
//!       "duration": 0.5,
//!       "easing":   "outCubic",
//!       "onUpdate": Fn.new {|v| _alpha = v }
//!     }))
//!   }
//!   update(g) {
//!     // Tweens.update(g.dt) is already called by Game.run.
//!   }
//! }
//! ```
//!
//! ## Wiring with statecharts
//!
//! `AnimationPlayer.bindStateChart` connects an FSM to a player so
//! transitions switch clips. Combined with `Actions.emitter`, a
//! character's animation reacts to input without any glue code:
//!
//! ```wren
//! var player = AnimationPlayer.new()
//! player.add(Clip.new("idle",    1.0, { ... }))
//! player.add(Clip.new("running", 0.6, { ... }))
//! player.bindStateChart(chart, { "ground": "idle", "running": "running" })
//! ```
//!
//! For the common case where the chart should also receive Actions
//! events, `Behaviors.wire` collapses both legs (`chart.bindEvents`
//! + `player.bindStateChart`) into one call:
//!
//! ```wren
//! Behaviors.wire({
//!   "chart":   chart,
//!   "actions": ["jump", "forward", "back"],
//!   "player":  player,
//!   "clips":   { "idle": "idle", "running": "run", "airborne": "jump" },
//!   "fade":    0.12
//! })
//! ```

import "@hatch:events" for EventEmitter
import "@hatch:math"   for Ease
import "./actions"     for Actions

/// A single property animator. Drives `onUpdate(value)` each frame
/// with a number interpolated from `from` to `to` over `duration`
/// seconds, optionally shaped by an easing curve. `onComplete` (if
/// set) fires once the tween finishes.
///
/// Tweens are inert until added to the `Tweens` manager —
/// `Tweens.add(tween)` schedules ticking, `Tweens.update(dt)` (run
/// automatically by `Game.run`) advances them.
///
/// ## Chaining
///
/// `.then(next)` appends `next` to run after this tween completes.
/// `.also(other)` schedules `other` to run in parallel. Both
/// return the *head* tween so further chaining accumulates onto
/// the same scheduled head — `Tweens.add(a.then(b).then(c))`
/// queues all three with `a` first.
class Tween {
  /// Build a tween from a config Map. Recognised keys:
  ///
  /// | Key | Type | Default | Notes |
  /// |---|---|---|---|
  /// | `from`     | `Num`  | `0`            | Start value. |
  /// | `to`       | `Num`  | `1`            | End value. |
  /// | `duration` | `Num`  | `1.0`          | Seconds. `0` snaps instantly. |
  /// | `easing`   | `String` or `Fn` | `"linear"` | `Easing` curve name (e.g. `"easeOutCubic"`) or `Fn.new {|t| ...}`. |
  /// | `delay`    | `Num`  | `0`            | Seconds to wait before the first `onUpdate`. |
  /// | `loop`     | `Bool` or `String` | `false` | `true` repeats, `"pingpong"` reverses each lap. |
  /// | `onUpdate` | `Fn(v)`  | `null`       | Called every frame the tween is active. |
  /// | `onComplete` | `Fn()` | `null`       | Called once when the tween finishes (never when looping). |
  ///
  /// @param {Map} opts. Configuration as above.
  construct new(opts) {
    if (!(opts is Map)) {
      Fiber.abort("Tween.new: opts must be a Map, got %(opts.type)")
    }
    _from       = Tween.numOr_(opts, "from",     0)
    _to         = Tween.numOr_(opts, "to",       1)
    _duration   = Tween.numOr_(opts, "duration", 1)
    _easing     = opts.containsKey("easing") ? opts["easing"] : null
    _delay      = Tween.numOr_(opts, "delay",    0)
    _loop       = opts.containsKey("loop") ? opts["loop"] : false
    _onUpdate   = opts["onUpdate"]
    _onComplete = opts["onComplete"]

    _elapsed    = 0
    _done       = false
    _reversing  = false       // pingpong direction
    _next       = null        // sequenced tween (then)
    _parallel   = []          // parallel siblings (also)
  }

  static numOr_(opts, key, fallback) {
    if (!opts.containsKey(key)) return fallback
    var v = opts[key]
    if (!(v is Num)) Fiber.abort("Tween: '%(key)' must be a Num, got %(v.type)")
    return v
  }

  /// Start value.   @returns {Num}
  from        { _from }
  /// End value.    @returns {Num}
  to          { _to }
  /// Duration in seconds. @returns {Num}
  duration    { _duration }
  /// `true` once the tween has finished (and is not looping).
  /// @returns {Bool}
  done        { _done }

  /// Schedule `next` to run after `this` completes.
  ///
  /// `next` runs sequentially, not in parallel. Returns the *head*
  /// (this tween) so further calls keep chaining onto the same
  /// scheduling entry.
  ///
  /// @param   {Tween} next
  /// @returns {Tween} self
  then(next) {
    if (!(next is Tween)) Fiber.abort("Tween.then: next must be a Tween")
    // Walk to the tail so multiple `.then()` calls chain in order.
    var tail = this
    while (tail.next_ != null) tail = tail.next_
    tail.next_ = next
    return this
  }

  /// Run `other` in parallel with `this`. Both tweens are ticked
  /// alongside each other; `this` is still considered the head for
  /// sequencing purposes.
  ///
  /// @param   {Tween} other
  /// @returns {Tween} self
  also(other) {
    if (!(other is Tween)) Fiber.abort("Tween.also: other must be a Tween")
    _parallel.add(other)
    return this
  }

  // Internal accessors — let the manager + chaining poke at the
  // doubly-linked list of follow-ups without leaking _next as a
  // public field.
  next_      { _next }
  next_=(v)  { _next = v }
  parallel_  { _parallel }

  /// Snap the tween back to its start state. Useful for replaying
  /// a one-shot or restarting a `Tweens.add()`-managed tween.
  reset() {
    _elapsed   = 0
    _done      = false
    _reversing = false
    // Replaying a chained head also resets its tail; sibling tweens
    // reset alongside so a `then`-chain replays cleanly.
    if (_next != null) _next.reset()
    for (p in _parallel) p.reset()
  }

  // Advance by `dt` seconds. Returns `true` when the tween has
  // produced its final value and won't fire any more updates
  // (i.e. ready to drop). Looping tweens never return `true`.
  step_(dt) {
    if (_done) return true
    _elapsed = _elapsed + dt
    if (_elapsed < _delay) return false

    var local = _elapsed - _delay
    if (_duration <= 0) {
      // Zero-duration tween: emit the final value and finish.
      if (_onUpdate != null) _onUpdate.call(_to)
      if (_onComplete != null) _onComplete.call()
      _done = true
      return true
    }

    var t = local / _duration
    var laps = 0
    if (t >= 1) {
      laps = (t).floor
      t = t - laps
    }

    var eased = applyEasing_(_reversing ? (1 - t) : t)
    var value = _from + (_to - _from) * eased
    if (_onUpdate != null) _onUpdate.call(value)

    if (laps > 0) {
      if (_loop == false) {
        // Non-looping: clamp to the end, fire completion, mark done.
        var endEased = applyEasing_(_reversing ? 0 : 1)
        var endValue = _from + (_to - _from) * endEased
        if (_onUpdate != null) _onUpdate.call(endValue)
        if (_onComplete != null) _onComplete.call()
        _done = true
        return true
      }
      if (_loop == "pingpong") {
        // Flip direction for each completed lap.
        if (laps % 2 == 1) _reversing = !_reversing
      }
      // Roll the clock back so the next frame's dt accumulates onto
      // the current lap's fraction rather than skipping forward.
      _elapsed = _delay + t * _duration
    }
    return false
  }

  applyEasing_(t) {
    if (_easing == null)        return t
    if (_easing is String)      return Tween.resolveEase_(_easing, t)
    return _easing.call(t)
  }

  // Resolve a string easing name against `@hatch:math`'s `Ease`
  // class. Wren can't pass static method references as first-class
  // values, so the string→curve table lives here.
  static resolveEase_(name, t) {
    if (name == "linear")     return Ease.linear(t)
    if (name == "inQuad")     return Ease.inQuad(t)
    if (name == "outQuad")    return Ease.outQuad(t)
    if (name == "inOutQuad")  return Ease.inOutQuad(t)
    if (name == "inCubic")    return Ease.inCubic(t)
    if (name == "outCubic")   return Ease.outCubic(t)
    if (name == "inOutCubic") return Ease.inOutCubic(t)
    if (name == "inBack")     return Ease.inBack(t)
    if (name == "outBack")    return Ease.outBack(t)
    if (name == "inExpo")     return Ease.inExpo(t)
    if (name == "outExpo")    return Ease.outExpo(t)
    Fiber.abort("Tween: unknown easing '%(name)' — see @hatch:math Ease for valid names")
  }
}

/// A named clip of keyframed tracks. Each track is a List of
/// `[time, value]` pairs sorted by time; `sample(t)` linearly
/// interpolates between the surrounding keyframes per track and
/// returns a Map<trackName, value>.
///
/// `Clip` is the primitive `AnimationPlayer` drives. Skeletal
/// animation from `@hatch:gltf` will populate clips by mapping
/// gltf animation channels to track names — until that lands the
/// same shape covers UI prop animation, camera shake curves, and
/// any other keyframed data.
class Clip {
  /// Build a clip with linearly-interpolated tracks.
  ///
  /// @param {String} name. Identifier used by `AnimationPlayer.play`.
  /// @param {Num} duration. Total clip duration in seconds.
  /// @param {Map} tracks. `Map<String, List<[time, value]>>` — each
  ///   value list must be sorted by ascending time.
  construct new(name, duration, tracks) {
    if (!(name is String))     Fiber.abort("Clip.new: name must be a String")
    if (!(duration is Num))    Fiber.abort("Clip.new: duration must be a Num")
    if (!(tracks is Map))      Fiber.abort("Clip.new: tracks must be a Map")
    _name     = name
    _duration = duration
    _tracks   = tracks
    _interps  = {}     // trackName → "linear" | "step" | "cubic"
  }

  /// Build a clip with per-track interpolation. `interps` is a
  /// `Map<String, String>` keyed by track name; values are one of
  /// `"linear"` (default, matches `Clip.new`), `"step"` (no
  /// interpolation — hold the previous keyframe until the next
  /// fires), or `"cubic"` (Hermite cubic, glTF 2.0 CUBICSPLINE
  /// shape). Tracks marked `"cubic"` carry 4-element keyframes
  /// `[time, value, inTangent, outTangent]`; linear / step tracks
  /// keep the 2-element `[time, value]` format.
  ///
  /// @param {String} name
  /// @param {Num} duration
  /// @param {Map} tracks
  /// @param {Map} interps. `Map<String, String>`. Missing entries
  ///   default to `"linear"`.
  construct withInterpolations(name, duration, tracks, interps) {
    if (!(name is String))      Fiber.abort("Clip.withInterpolations: name must be a String")
    if (!(duration is Num))     Fiber.abort("Clip.withInterpolations: duration must be a Num")
    if (!(tracks is Map))       Fiber.abort("Clip.withInterpolations: tracks must be a Map")
    if (!(interps is Map))      Fiber.abort("Clip.withInterpolations: interps must be a Map")
    _name     = name
    _duration = duration
    _tracks   = tracks
    _interps  = interps
  }

  /// Clip name. @returns {String}
  name      { _name }
  /// Clip length in seconds. @returns {Num}
  duration  { _duration }
  /// Track keyframes. @returns {Map<String, List>}
  tracks    { _tracks }
  /// Per-track interpolation kinds. @returns {Map<String, String>}
  interpolations { _interps }

  /// Sample every track at `t` seconds. `t` is clamped to
  /// `0..duration`. Returns a fresh `Map<String, Num>` of
  /// interpolated values; tracks with a single keyframe return
  /// that value at any `t`.
  ///
  /// @param  {Num} t. Seconds into the clip.
  /// @returns {Map<String, Num>}
  sample(t) {
    var clamped = t
    if (clamped < 0) clamped = 0
    if (clamped > _duration) clamped = _duration

    var out = {}
    for (key in _tracks.keys) {
      var keys = _tracks[key]
      if (keys.count == 0) continue
      if (keys.count == 1) {
        out[key] = keys[0][1]
        continue
      }
      // Linear search is fine for typical clip key counts (<200);
      // a binary search lands the day the profiler asks for it.
      var prev = keys[0]
      var next = keys[keys.count - 1]
      var i = 0
      while (i < keys.count - 1) {
        if (keys[i][0] <= clamped && clamped <= keys[i + 1][0]) {
          prev = keys[i]
          next = keys[i + 1]
          break
        }
        i = i + 1
      }
      var span = next[0] - prev[0]
      var interp = _interps.containsKey(key) ? _interps[key] : "linear"
      if (span <= 0) {
        out[key] = prev[1]
      } else if (interp == "step") {
        // Step: hold the previous keyframe's value until t
        // reaches the next keyframe's time — then snap to it.
        out[key] = clamped >= next[0] ? next[1] : prev[1]
      } else if (interp == "cubic") {
        // Hermite cubic with per-keyframe in/out tangents,
        // matching the glTF 2.0 CUBICSPLINE shape:
        //   P(u) = (2u³ - 3u² + 1)·p0
        //        + (u³ - 2u² + u)·m0·span
        //        + (-2u³ + 3u²)·p1
        //        + (u³ - u²)·m1·span
        // m0 = prev.outTangent, m1 = next.inTangent.
        var u  = (clamped - prev[0]) / span
        var u2 = u * u
        var u3 = u2 * u
        var p0 = prev[1]
        var p1 = next[1]
        var m0 = prev.count > 3 ? prev[3] : 0
        var m1 = next.count > 2 ? next[2] : 0
        var h00 = 2 * u3 - 3 * u2 + 1
        var h10 = u3 - 2 * u2 + u
        var h01 = -2 * u3 + 3 * u2
        var h11 = u3 - u2
        out[key] = h00 * p0 + h10 * m0 * span + h01 * p1 + h11 * m1 * span
      } else {
        // "linear" (the default).
        var u = (clamped - prev[0]) / span
        out[key] = prev[1] + (next[1] - prev[1]) * u
      }
    }
    return out
  }
}

/// Plays one or more `Clip`s, with looping, ping-pong, crossfade,
/// and optional FSM-statechart binding. Call `player.update(dt)`
/// every frame (or hand it to `Game.run` via a system) and read
/// the interpolated tracks from `player.current` after each tick.
///
/// ## Crossfade
///
/// `player.crossfade(target, duration)` blends the current clip's
/// tracks with the target's over `duration` seconds, then drops
/// the source. Per-track values blend linearly; tracks that exist
/// only on one side fade in / out from zero.
class AnimationPlayer {
  /// Construct an empty player. Use `add(clip)` and then `play(name)`
  /// to start animation.
  construct new() {
    _clips     = {}             // name → Clip
    _active    = null           // currently playing Clip
    _activeT   = 0
    _fadeFrom  = null           // (Clip) being faded out
    _fadeFromT = 0
    _fadeIn    = 0              // crossfade elapsed
    _fadeDur   = 0
    _speed     = 1
    _loop      = true
    _onSample  = null           // Fn(tracksMap)
    _current   = {}             // last sampled tracks
    _events    = EventEmitter.new()
  }

  /// Register a clip with the player. Replaces any existing clip
  /// with the same name.
  ///
  /// @param {Clip} clip
  add(clip) {
    if (!(clip is Clip)) Fiber.abort("AnimationPlayer.add: clip must be a Clip")
    _clips[clip.name] = clip
  }

  /// Start playing the named clip immediately, resetting playhead
  /// to `0`. Errors if the clip hasn't been added.
  ///
  /// @param {String} name
  play(name) {
    if (!_clips.containsKey(name)) {
      Fiber.abort("AnimationPlayer.play: no clip named '%(name)'")
    }
    _active   = _clips[name]
    _activeT  = 0
    _fadeFrom = null
    _fadeDur  = 0
    _fadeIn   = 0
  }

  /// Smoothly transition to `name` over `duration` seconds. The
  /// previously active clip continues to tick during the fade so
  /// the visual remains stable.
  ///
  /// @param {String} name
  /// @param {Num}    duration. Seconds.
  crossfade(name, duration) {
    if (!_clips.containsKey(name)) {
      Fiber.abort("AnimationPlayer.crossfade: no clip named '%(name)'")
    }
    if (_active == null || duration <= 0) {
      play(name)
      return
    }
    _fadeFrom  = _active
    _fadeFromT = _activeT
    _active    = _clips[name]
    _activeT   = 0
    _fadeIn    = 0
    _fadeDur   = duration
  }

  /// Set playback speed multiplier. `1.0` is real time, `0.5` is
  /// half speed, `2.0` is double, negative values run backwards.
  /// @param {Num} v
  speed=(v)   {
    if (!(v is Num)) Fiber.abort("AnimationPlayer.speed=: must be a Num")
    _speed = v
  }
  /// Current speed multiplier. @returns {Num}
  speed       { _speed }

  /// Whether the active clip wraps around at its end. Default `true`.
  /// @param {Bool} v
  loop=(v)    { _loop = v }
  /// @returns {Bool}
  loop        { _loop }

  /// Per-frame sample callback, fired after every `update(dt)` with
  /// the latest `Map<String, Num>` of interpolated track values.
  /// Use this to push samples into your skeletal pose, sprite
  /// transforms, or shader uniforms.
  /// @param {Fn} fn. `Fn.new {|tracks| ...}`
  onSample(fn) { _onSample = fn }

  /// The most recent sample's track Map. Empty before the first
  /// `update(dt)`.
  /// @returns {Map<String, Num>}
  current      { _current }

  /// Internal event emitter. Mostly useful for tests that want to
  /// observe `"complete"` (non-looping playback finished).
  /// @returns {EventEmitter}
  events       { _events }

  /// Advance the player by `dt` seconds. Should be called from
  /// each frame's `update` hook (or any system driving it). No-op
  /// when no clip is active.
  /// @param {Num} dt
  update(dt) {
    if (_active == null) return
    var step = dt * _speed
    _activeT = _activeT + step

    if (_active.duration > 0) {
      if (_activeT >= _active.duration) {
        if (_loop) {
          var d = _active.duration
          _activeT = _activeT - d * (_activeT / d).floor
        } else {
          _activeT = _active.duration
          _events.emit("complete", _active.name)
        }
      }
      if (_activeT < 0 && _loop) {
        var d = _active.duration
        var laps = (-_activeT / d).floor + 1
        _activeT = _activeT + d * laps
      }
    }

    if (_fadeFrom != null) {
      _fadeFromT = _fadeFromT + step
      _fadeIn    = _fadeIn + dt
      if (_fadeIn >= _fadeDur) {
        _fadeFrom = null
        _fadeDur  = 0
        _fadeIn   = 0
      }
    }

    var sample = _active.sample(_activeT)
    if (_fadeFrom != null) {
      var blend = _fadeIn / _fadeDur
      var prev  = _fadeFrom.sample(_fadeFromT)
      var mixed = {}
      for (k in prev.keys) {
        var b = sample.containsKey(k) ? sample[k] : 0
        mixed[k] = prev[k] + (b - prev[k]) * blend
      }
      for (k in sample.keys) {
        if (!mixed.containsKey(k)) {
          mixed[k] = sample[k] * blend
        }
      }
      sample = mixed
    }
    _current = sample
    if (_onSample != null) _onSample.call(sample)
  }

  /// Bind the player to a statechart. Each entry in `stateToClip`
  /// maps a chart state name (or fully-qualified `parent.child`
  /// path) to a clip name; when the chart transitions into that
  /// state the player crossfades to the corresponding clip.
  ///
  /// Uses the default crossfade duration of `0.15s`. For an
  /// explicit duration use `bindStateChart(chart, map, fade)`.
  ///
  /// ```wren
  /// player.bindStateChart(chart, {
  ///   "ground":  "idle",
  ///   "running": "run",
  ///   "air":     "jump"
  /// })
  /// ```
  ///
  /// @param {StateChart} chart
  /// @param {Map<String, String>} stateToClip
  bindStateChart(chart, stateToClip) {
    bindStateChart(chart, stateToClip, 0.15)
  }

  /// As `bindStateChart(chart, stateToClip)` with an explicit
  /// crossfade duration in seconds. Pass `0` to snap.
  ///
  /// @param {StateChart} chart
  /// @param {Map<String, String>} stateToClip
  /// @param {Num} fadeDuration
  bindStateChart(chart, stateToClip, fadeDuration) {
    if (!(stateToClip is Map)) {
      Fiber.abort("AnimationPlayer.bindStateChart: stateToClip must be a Map")
    }
    // StateChart fires "transition" with (fromPath, toPath, event).
    // Match the toPath both as the full path and as its tail
    // (`parent.leaf` → `leaf`) so callers can use either spelling.
    //
    // `Fn.new` bodies don't inherit `this` from the enclosing
    // method — bare `play(...)` would resolve to `null.play(...)`
    // at invocation time. Capture the receiver as `self` so the
    // emitter callback dispatches against the player.
    var self = this
    chart.on("transition", Fn.new {|fromPath, toPath, evt|
      var clipName = AnimationPlayer.lookupClip_(stateToClip, toPath)
      if (clipName == null) return
      // `crossfade` falls back to `play` when there's no active
      // clip or the fade duration is non-positive, so this is the
      // one-line dispatch for both first-entry and follow-up
      // transitions.
      self.crossfade(clipName, fadeDuration)
    })
  }

  // Lookup helper. First try the exact path, then strip parent
  // segments left-to-right so `app.idle` / `idle` both resolve
  // against a `{ "idle": "..." }` mapping. Wren's String has no
  // `indexOf`, so we walk bytes.
  static lookupClip_(map, toPath) {
    if (map.containsKey(toPath)) return map[toPath]
    var path = toPath
    while (true) {
      var dot = -1
      var i = 0
      while (i < path.count) {
        if (path[i] == ".") {
          dot = i
          break
        }
        i = i + 1
      }
      if (dot < 0) return null
      path = path[(dot + 1)..-1]
      if (map.containsKey(path)) return map[path]
    }
  }
}

/// Per-game tween manager. `Game.run` calls `Tweens.update(g.dt)`
/// every frame, so user code only needs to `Tweens.add(tween)` and
/// the tween ticks until done. Sequencing and parallel siblings
/// established via `tween.then(next)` / `tween.also(other)` are
/// honoured automatically.
class Tweens {
  /// Schedule `tween` for per-frame updates. Returns the same
  /// tween (so chaining + add can happen in one expression).
  ///
  /// @param  {Tween} tween
  /// @returns {Tween}
  static add(tween) {
    if (!(tween is Tween)) Fiber.abort("Tweens.add: arg must be a Tween")
    TWEEN_LIST_.add(tween)
    for (p in tween.parallel_) TWEEN_LIST_.add(p)
    return tween
  }

  /// Stop and drop `tween` (and any chained / parallel siblings)
  /// without firing `onComplete`.
  ///
  /// @param {Tween} tween
  static cancel(tween) {
    var i = 0
    while (i < TWEEN_LIST_.count) {
      if (TWEEN_LIST_[i] == tween) {
        TWEEN_LIST_.removeAt(i)
      } else {
        i = i + 1
      }
    }
    for (p in tween.parallel_) Tweens.cancel(p)
    if (tween.next_ != null) Tweens.cancel(tween.next_)
  }

  /// Drop every scheduled tween. Useful between scene transitions.
  static cancelAll() { TWEEN_LIST_.clear() }

  /// Number of currently-scheduled tweens.
  /// @returns {Num}
  static count { TWEEN_LIST_.count }

  /// Advance every scheduled tween by `dt` seconds. Called once per
  /// frame by `Game.run`; user code rarely calls this directly
  /// except in tests or custom main loops.
  ///
  /// @param {Num} dt
  static update(dt) {
    // Index-based while loop avoids the closure-upvalue bug that
    // makes `for (t in TWEEN_LIST_)` miscompile when the body
    // mutates outer-scope state. Iterating backwards lets us
    // remove finished tweens in place without re-checking indices.
    var i = TWEEN_LIST_.count - 1
    while (i >= 0) {
      var t = TWEEN_LIST_[i]
      var done = t.step_(dt)
      if (done) {
        TWEEN_LIST_.removeAt(i)
        if (t.next_ != null) {
          // Chain the next tween in place — preserves ordering and
          // its parallel siblings come along too.
          TWEEN_LIST_.add(t.next_)
          for (p in t.next_.parallel_) TWEEN_LIST_.add(p)
        }
      }
      i = i - 1
    }
  }
}

/// Single-call facade over the granular `chart.bindEvents` and
/// `player.bindStateChart` wires. Use this when you want the
/// canonical *Actions → StateChart → AnimationPlayer* graph
/// (semantic input forwards into transitions, transitions swap
/// clips), and use the individual methods when one of the legs
/// is bespoke — chart driven by network packets, or clip set
/// switched manually by gameplay code.
///
/// ## Example
///
/// ```wren
/// Behaviors.wire({
///   "chart":   _chart,
///   "actions": ["jump", "forward", "back"],
///   "player":  _player,
///   "clips":   { "idle": "idle", "running": "run", "airborne": "jump" },
///   "fade":    0.12
/// })
/// ```
///
/// `chart` is the only required key; everything else is optional
/// so the same facade also covers half-wires (only Actions, only
/// clips, etc).
class Behaviors {
  /// Wire any subset of:
  ///   - Actions emitter → chart events (`actions`, optional `emitter`)
  ///   - Chart transitions → animation clips (`player`, `clips`, optional `fade`)
  ///
  /// Recognised keys:
  ///
  /// | Key | Type | Required | Notes |
  /// |---|---|---|---|
  /// | `chart`   | `StateChart`      | ✓ | Target chart. |
  /// | `actions` | `List<String>`    |   | Event names to forward from the emitter. |
  /// | `emitter` | `EventEmitter`    |   | Defaults to `Actions.emitter`. |
  /// | `player`  | `AnimationPlayer` |   | Animation player to drive. |
  /// | `clips`   | `Map<String, String>` |  | State name → clip name. |
  /// | `fade`    | `Num` (seconds)   |   | Crossfade duration, default `0.15`. |
  ///
  /// Aborts only on type mismatch — unknown / missing optional
  /// keys silently no-op so partial wires work.
  ///
  /// @param  {Map} opts
  static wire(opts) {
    if (!(opts is Map)) {
      Fiber.abort("Behaviors.wire: opts must be a Map, got %(opts.type)")
    }
    var chart = opts["chart"]
    if (chart == null) {
      Fiber.abort("Behaviors.wire: 'chart' is required")
    }

    if (opts.containsKey("actions")) {
      var events = opts["actions"]
      if (!(events is List)) {
        Fiber.abort("Behaviors.wire: 'actions' must be a List<String>, got %(events.type)")
      }
      var em = opts.containsKey("emitter") ? opts["emitter"] : Actions.emitter
      chart.bindEvents(em, events)
    }

    if (opts.containsKey("player")) {
      var player = opts["player"]
      if (!opts.containsKey("clips")) {
        Fiber.abort("Behaviors.wire: 'player' requires 'clips' to know which clip per state")
      }
      var clips = opts["clips"]
      var fade  = opts.containsKey("fade") ? opts["fade"] : 0.15
      player.bindStateChart(chart, clips, fade)
    }
  }
}

// Module-private. Same pattern as `ACTION_REGISTRY_` in actions.wren
// and `PHYSICS_SCRATCH_3D_` in scene.wren — Wren's `__foo` static
// fields don't round-trip cleanly through this codebase's class
// table on certain paths, so manager state lives at module scope.
var TWEEN_LIST_ = []
