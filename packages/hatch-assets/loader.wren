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
    _queue           = []     // List<{ name, load }>
    _loaded          = {}     // name → asset
    _onProgress      = null
    _onComplete      = null
    _onError         = null
    _running         = false
    _originalTotal   = 0
    // Cap on the number of decode-kind entries kicked off in
    // parallel when the head reaches the first decode entry. 32
    // is a sane default for typical scene loads (10-30 textures);
    // a level editor with 1000 icons would lower it via the
    // `decodeBatchCap = N` setter, and a single big load might
    // raise it.
    _decodeBatchCap  = 32
  }

  /// Cap on the number of `queueDecode` entries that have their
  /// `beginFn` invoked in parallel. The first decode entry to
  /// reach the head triggers a prefetch sweep of the next
  /// `decodeBatchCap` decode entries — without this, decodes run
  /// serially and the worker-thread parallelism is wasted. Lower
  /// the cap when individual decodes are large enough that
  /// memory pressure (raw RGBA buffers held in the JobRegistry
  /// until drained) becomes a concern.
  /// @returns {Num}
  decodeBatchCap { _decodeBatchCap }

  /// @param {Num} n. Bounded to `[1, 4096]`.
  decodeBatchCap=(n) {
    if (!(n is Num) || n < 1) Fiber.abort("AssetLoader.decodeBatchCap: must be a positive Num.")
    _decodeBatchCap = (n > 4096) ? 4096 : n.floor
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

  /// Queue an asset whose `loadFn` yields via `.await` (e.g.
  /// `Browser.fetch(url).await` on web). The loader invokes the
  /// closure directly on its calling fiber so the yield
  /// propagates up to the game loop, which the wasm browser
  /// bridge already drives — sidesteps the nested-`Fiber.try` +
  /// async-scheduler conflict that breaks the `queue(...)` path
  /// on web. Errors raised by the closure propagate out of
  /// `update`; if you want soft failure, return a sentinel
  /// instead of aborting.
  ///
  /// ```wren
  /// loader.queueAsync("manifest", Fn.new {
  ///   JSON.parse(Browser.fetch("./atlas.json").await)
  /// })
  /// ```
  ///
  /// @param {String} name
  /// @param {Fn}     loadFn
  queueAsync(name, loadFn) {
    if (!(name is String)) {
      Fiber.abort("AssetLoader.queueAsync: name must be a String, got %(name.type)")
    }
    if (!(loadFn is Fn)) {
      Fiber.abort("AssetLoader.queueAsync: loadFn must be a Fn, got %(loadFn.type)")
    }
    _queue.add({ "name": name, "load": loadFn, "async": true })
  }

  /// Queue a poll-handle-style asset — typically a non-blocking
  /// PNG decode (`Image.decodeBegin`) but the pattern is generic
  /// for any "kick off work, poll each frame, drain once ready"
  /// shape. The loader drives it in two stages over multiple
  /// frames:
  ///
  ///   1. On the entry's FIRST `update(dt)`, calls
  ///      `beginFn` and stashes whatever it returns as the
  ///      in-flight handle. `beginFn` is expected to return an
  ///      object that responds to `isReady`, `isFailed`,
  ///      `result`, `errorMessage`. (`ImageDecodeHandle` fits.)
  ///   2. On every subsequent `update(dt)`, polls the handle.
  ///      While still pending, the entry stays at the head of
  ///      the queue — no progress is fired, no other entries
  ///      advance. On ready: `finishFn.call(handle.result)`,
  ///      whatever it returns is stored under `name`, progress
  ///      + complete fire as normal. On failed:
  ///      `onError.call(name, handle.errorMessage)` and the
  ///      entry is dropped.
  ///
  /// ## Example
  ///
  /// ```wren
  /// loader.queueDecode("hero_diffuse",
  ///   Fn.new { Image.decodeBegin(db.bytes("hero_diffuse.png")) },
  ///   Fn.new {|img|  device.uploadImage(img, {"format": "rgba8unorm-srgb"}) })
  /// ```
  ///
  /// @param {String} name
  /// @param {Fn}     beginFn.  Returns a handle (no args).
  /// @param {Fn}     finishFn. Receives `handle.result`, returns
  ///                           whatever should be stored under `name`.
  queueDecode(name, beginFn, finishFn) {
    if (!(name is String)) {
      Fiber.abort("AssetLoader.queueDecode: name must be a String, got %(name.type)")
    }
    if (!(beginFn is Fn)) {
      Fiber.abort("AssetLoader.queueDecode: beginFn must be a Fn, got %(beginFn.type)")
    }
    if (!(finishFn is Fn)) {
      Fiber.abort("AssetLoader.queueDecode: finishFn must be a Fn, got %(finishFn.type)")
    }
    _queue.add({
      "name":     name,
      "begin":    beginFn,
      "finish":   finishFn,
      "kind":     "decode",
      "handle":   null,
      "started":  false
    })
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

  /// Drain pending entries. Called every frame by the game loop
  /// (`loader.update(g.dt)`). One entry per tick.
  ///
  /// Each entry is dispatched in one of two modes set at queue
  /// time:
  ///   * `queue(name, loadFn)` — synchronous, error-catching.
  ///     The closure runs inside `Fiber.new(loadFn).try()`; any
  ///     `Fiber.abort` from the closure populates `fiber.error`
  ///     and routes to `onError`. Required for the desktop /
  ///     filesystem-backed pattern where reads can raise.
  ///   * `queueAsync(name, loadFn)` — closures that yield via
  ///     `.await` (e.g. `Browser.fetch(url).await` on web). The
  ///     loader `.call()`s the closure DIRECTLY on its calling
  ///     fiber so the yield propagates up to the game-loop
  ///     fiber, which the wasm browser-bridge scheduler resumes
  ///     cleanly. The `Fiber.new` wrap can't be used here — the
  ///     scheduler would resume the wrap fiber out from under the
  ///     loader and the next `.try` would land on a finished
  ///     fiber. Errors raised by an async closure propagate out
  ///     of `update`; the caller wraps if it wants soft failure.
  ///
  /// @param {Num} dt. Seconds since the previous frame. Unused.
  update(dt) {
    if (!_running) return
    if (_queue.count == 0) {
      _running = false
      if (_onComplete != null) _onComplete.call(_loaded)
      return
    }
    // Decode-kind entries live in the queue across multiple update
    // ticks — peek at the head first, only `removeAt(0)` once the
    // entry has actually resolved (or failed). For sync / async
    // entries the resolve always happens this tick.
    var entry = _queue[0]
    var name  = entry["name"]
    var asset
    var dropEntry = false
    var firedProgress = false

    if (entry["kind"] == "decode") {
      // First time we see a decode entry at the head, walk the
      // whole queue forward and kick off `beginFn` on every
      // not-yet-started decode entry. This lets PNG decodes run in
      // parallel on their worker threads — without this every entry
      // would wait for the previous one's poll loop to drain before
      // its own worker even starts, defeating the point of
      // backgrounded decode. Bound the prefetch by `decodeBatchCap`
      // so a 1000-image scene doesn't spawn 1000 std::threads at once.
      var qi = 0
      var kicked = 0
      while (qi < _queue.count && kicked < _decodeBatchCap) {
        var qe = _queue[qi]
        if (qe["kind"] == "decode" && !qe["started"]) {
          qe["started"] = true
          var bfib = Fiber.new(qe["begin"])
          var h = bfib.try()
          if (bfib.error != null) {
            qe["handle"] = null
            qe["beginError"] = bfib.error
          } else {
            qe["handle"] = h
          }
          kicked = kicked + 1
        }
        qi = qi + 1
      }
      // Surface the head entry's begin error (if any) on the same
      // tick — keeps error semantics identical to the non-decode path.
      if (entry["beginError"] != null) {
        var err = entry["beginError"]
        dropEntry = true
        if (_onError != null) {
          _onError.call(name, err)
        } else {
          Fiber.abort("AssetLoader.update: '%(name)' begin failed: %(err)")
        }
      }

      // Subsequent visits OR same-tick visit on a fast-path handle
      // (wasm32 decode runs inline so `isReady` is true immediately
      // after the begin call above): poll, drain on ready, error
      // on failure.
      if (!dropEntry) {
        var handle = entry["handle"]
        if (handle == null) {
          // Source slot was empty — finish step gets null and routes
          // to its no-op branch. Drain immediately.
          asset = entry["finish"].call(null)
          _loaded[name] = asset
          dropEntry = true
        } else if (handle.isReady) {
          var finishFiber = Fiber.new {
            return entry["finish"].call(handle.result)
          }
          asset = finishFiber.try()
          if (finishFiber.error != null) {
            dropEntry = true
            if (_onError != null) {
              _onError.call(name, finishFiber.error)
            } else {
              Fiber.abort("AssetLoader.update: '%(name)' finish failed: %(finishFiber.error)")
            }
          } else {
            _loaded[name] = asset
            dropEntry = true
          }
        } else if (handle.isFailed) {
          dropEntry = true
          var msg = handle.errorMessage
          if (_onError != null) {
            _onError.call(name, msg)
          } else {
            Fiber.abort("AssetLoader.update: '%(name)' decode failed: %(msg)")
          }
        }
        // else still pending — leave entry at head, return so the
        // game loop renders a frame, retry next update.
      }
    } else if (entry["async"] == true) {
      dropEntry = true
      // Direct invocation: yields the calling fiber chain to the
      // browser bridge; no Fiber.new wrap so the bridge can drive
      // the same fiber the .await is parked on.
      asset = entry["load"].call()
      _loaded[name] = asset
    } else {
      dropEntry = true
      // Synchronous: wrap in a child fiber so we can route abort
      // through onError without the loader itself dying.
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
    }

    if (dropEntry) {
      _queue.removeAt(0)
      var fraction = _originalTotal == 0 ? 1 : _loaded.count / _originalTotal
      if (_onProgress != null) {
        _onProgress.call(fraction, _loaded.count, _originalTotal)
      }
      firedProgress = true
    }

    if (firedProgress && _queue.count == 0) {
      _running = false
      if (_onComplete != null) _onComplete.call(_loaded)
    }
  }

  /// Stop loading immediately. The queue is preserved — call
  /// `start()` again to resume from where this left off.
  pause { _running = false }

  /// Clear every pending entry and previously loaded asset, and
  /// drop the original-total counter. Useful between scenes; also
  /// abandons any in-flight fiber so a half-decoded async closure
  /// can't bleed into the next batch.
  reset() {
    _queue.clear()
    _loaded.clear()
    _running       = false
    _originalTotal = 0
  }
}
