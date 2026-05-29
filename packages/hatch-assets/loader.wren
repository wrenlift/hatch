//! `@hatch:assets/loader` — frame-amortised batch asset loader.
//!
//! Spreads heavy decode work across multiple frames so a loading
//! scene's progress bar can update without the game loop
//! stalling. Each `update(dt)` call drains one queued item; a
//! 60 fps loop with 30 queued assets resolves in ~0.5 s wall
//! time without dropping below ~16.6 ms per frame.
//!
//! ```wren
//! import "@hatch:assets" for Assets, AssetLoader
//! import "@hatch:image"  for Image
//! import "@hatch:audio"  for Sound
//!
//! var db     = Assets.open("assets")
//! var loader = AssetLoader.new()
//! loader.queue("hero", Fn.new { Image.decode(db.bytes("hero.png")) })
//! loader.queue("shot", Fn.new { Sound.decode(db.bytes("shot.wav")) })
//! loader.queue("font", Fn.new { Image.decode(db.bytes("font.png")) })
//!
//! loader.onProgress {|fraction, done, total|
//!   System.print("loading %((fraction * 100).floor)%% (%(done)/%(total))")
//! }
//! loader.onComplete {|loaded|
//!   _hero = loaded["hero"]
//!   _shot = loaded["shot"]
//!   _font = loaded["font"]
//! }
//! loader.start()
//!
//! // In Game.run's update loop:
//! loader.update(g.dt)
//! ```
//!
//! ## Why frame-amortised
//!
//! True background loading needs OS threads + thread-safe
//! decoders — neither of which @hatch's runtime ships
//! generically. Amortising across frames gives the same
//! user-visible property (responsive loop, progress bar
//! updates) for the common case where each individual asset
//! decodes in under a frame.
//!
//! For assets that take *multiple* frames to decode (e.g. a
//! 64 MB texture), wrap the slow decode in a closure that
//! yields chunks across `update` calls — the loader's
//! `partial(name, fn)` hook is planned for that path.
//!
//! ## Wiring into a game-flow statechart
//!
//! The loader exposes signals (`onProgress` / `onComplete` /
//! `onError`); it doesn't model the surrounding scene
//! transitions itself. For a typical
//! `splash → loading → ready → playing` flow drive a
//! `StateChart` from `@hatch:fsm` and route the loader's
//! callbacks into chart events:
//!
//! ```wren
//! import "@hatch:assets" for AssetLoader, Assets
//! import "@hatch:fsm"    for StateChart
//! import "@hatch:image"  for Image
//!
//! var chart = StateChart.build {|c|
//!   c.id("flow")
//!   c.initial("splash")
//!   c.state("splash") {|s|
//!     s.on("loadStart", "loading")
//!   }
//!   c.state("loading") {|s|
//!     s.on("loadDone",  "ready")
//!     s.on("loadError", "error")
//!   }
//!   c.state("ready") {|s|
//!     s.on("play", "playing")
//!   }
//!   c.state("playing") {|s|}
//!   c.state("error")   {|s|}
//! }
//!
//! var db     = Assets.open("assets")
//! var loader = AssetLoader.new()
//! loader.queue("hero", Fn.new { Image.decode(db.bytes("hero.png")) })
//! loader.onComplete(Fn.new {|loaded| chart.send("loadDone") })
//! loader.onError(   Fn.new {|name, err| chart.send("loadError") })
//!
//! chart.start()
//! chart.send("loadStart")
//! loader.start()
//! ```
//!
//! Chart entry actions handle the transient work the loader
//! doesn't (camera fade-in, audio ducking, swapping scenes); the
//! loader stays a pure progress engine.

/// Frame-amortised asset loader. Holds a queue of
/// `(name, loadFn)` entries; each `update(dt)` call resolves one
/// entry by calling its `loadFn` and storing the result under
/// `name`. Fires `onProgress` after each item, `onComplete`
/// when the queue drains.
class AssetLoader {
  /// Construct an empty loader.
  construct new() {
    _queue          = []     // List<{ name, load }>
    _loaded         = {}     // name → asset
    _onProgress     = null
    _onComplete     = null
    _onError        = null
    _running        = false
    _originalTotal  = 0
  }

  /// Queue an asset for loading. `loadFn` is a zero-arg `Fn`
  /// called exactly once on the frame this entry is reached;
  /// whatever it returns is stored under `name` in the loaded
  /// map. The closure shape lets the loader stay decoupled from
  /// `@hatch:image` / `@hatch:audio` / any other decoder.
  ///
  /// ```wren
  /// loader.queue("level", Fn.new { JSON.parse(db.text("level.json")) })
  /// ```
  ///
  /// @param {String} name
  /// @param {Fn}     loadFn
  queue(name, loadFn) {
    if (!(name is String)) {
      Fiber.abort("AssetLoader.queue: name must be a String, got %(name.type)")
    }
    if (!(loadFn is Fn)) {
      Fiber.abort("AssetLoader.queue: loadFn must be a Fn, got %(loadFn.type)")
    }
    _queue.add({ "name": name, "load": loadFn })
  }

  /// Set the per-item progress callback. Fires once per resolved
  /// entry with `(fraction, done, total)` where `fraction` is in
  /// `0..1` and `total` is the original queue size at `start`.
  ///
  /// @param {Fn} fn. `Fn.new {|fraction, done, total| ... }`
  onProgress(fn) {
    if (!(fn is Fn)) Fiber.abort("AssetLoader.onProgress: fn must be a Fn")
    _onProgress = fn
  }

  /// Set the queue-drained callback. Fires once after the last
  /// entry resolves; receives the full `Map<name, asset>`.
  ///
  /// @param {Fn} fn. `Fn.new {|loaded| ... }`
  onComplete(fn) {
    if (!(fn is Fn)) Fiber.abort("AssetLoader.onComplete: fn must be a Fn")
    _onComplete = fn
  }

  /// Set the per-item error callback. Fires when a `loadFn`
  /// aborts a fiber (`Fiber.abort(...)`); receives the name and
  /// the abort message. Default behaviour without this hook is
  /// to propagate the abort, halting the loader.
  ///
  /// @param {Fn} fn. `Fn.new {|name, error| ... }`
  onError(fn) {
    if (!(fn is Fn)) Fiber.abort("AssetLoader.onError: fn must be a Fn")
    _onError = fn
  }

  /// Begin amortised loading. Records the current queue size as
  /// the denominator for `onProgress` fractions so progress
  /// reports stay monotonic even if `queue(...)` is called
  /// while loading is in flight (added items don't affect the
  /// fraction calculation for the current batch).
  start() {
    _running = true
    _originalTotal = _queue.count + _loaded.count
  }

  /// True while a `start()` is pending and the queue still has
  /// entries to resolve.
  /// @returns {Bool}
  running { _running && _queue.count > 0 }

  /// Snapshot of every asset loaded so far. The Map grows as
  /// entries resolve. Safe to read mid-load.
  /// @returns {Map}
  loaded { _loaded }

  /// Entries still waiting to resolve.
  /// @returns {Num}
  pending { _queue.count }

  /// Resolved count.
  /// @returns {Num}
  done { _loaded.count }

  /// Original total at the most recent `start()` — the
  /// denominator for `onProgress` fractions.
  /// @returns {Num}
  total { _originalTotal }

  /// Drain one pending entry. Called every frame by the game
  /// loop (`loader.update(g.dt)`); a `dt` argument is accepted
  /// for symmetry with the rest of the framework's per-frame
  /// tick shape but currently ignored — one entry per call gives
  /// monotonic progress and predictable frame cost.
  ///
  /// @param {Num} dt. Seconds since the previous frame. Unused.
  update(dt) {
    if (!_running)            return
    if (_queue.count == 0) {
      _running = false
      if (_onComplete != null) _onComplete.call(_loaded)
      return
    }
    var entry = _queue.removeAt(0)
    var name  = entry["name"]
    var asset = null
    var fiber = Fiber.new(entry["load"])
    asset = fiber.try()
    if (fiber.error != null) {
      if (_onError != null) {
        _onError.call(name, fiber.error)
      } else {
        Fiber.abort("AssetLoader.update: '%(name)' failed: %(fiber.error)")
      }
    } else {
      _loaded[name] = asset
    }
    var fraction = _originalTotal == 0 ? 1 : _loaded.count / _originalTotal
    if (_onProgress != null) {
      _onProgress.call(fraction, _loaded.count, _originalTotal)
    }
    if (_queue.count == 0) {
      _running = false
      if (_onComplete != null) _onComplete.call(_loaded)
    }
  }

  /// Stop loading immediately. The queue is preserved — call
  /// `start()` again to resume from where this left off.
  pause { _running = false }

  /// Clear every pending entry and previously loaded asset, and
  /// drop the original-total counter. Useful between scenes.
  reset() {
    _queue.clear()
    _loaded.clear()
    _running       = false
    _originalTotal = 0
  }
}
