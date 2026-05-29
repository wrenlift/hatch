/// Fruit Slicer — Fruit-Ninja-style swipe game wired through the
/// canonical asset-loading + scene-flow pattern:
///
///   @hatch:assets/AssetLoader   loads the texture atlas + JSON
///                               manifest amortised over frames
///                               so the splash bar updates
///                               while assets stream in.
///   @hatch:fsm/StateChart       drives the splash → loading →
///                               ready → playing → gameover scene
///                               transitions; each state owns its
///                               own update + draw.
///
/// The game itself: fruits launch from the bottom of the stage on
/// a parabolic arc; click-and-drag the mouse across them to slice.
/// Each cut spawns two halves that tumble with their own rotation
/// and gravity. Three misses ends the run.
///
/// Asset credits:
///   * Fruits asset pack by Lemon Balm — https://lemon-balm.itch.io/
///   * Heart HUD icon by Penzilla — https://penzilla.itch.io/

import "@hatch:game"   for Game
import "@hatch:gpu"    for Renderer2D, Camera2D, Sprite
import "@hatch:json"   for JSON
import "@hatch:assets" for Assets, AssetLoader
import "@hatch:fsm"    for StateChart
import "@hatch:hud"    for HUD

class FruitSlicer is Game {
  // Design-space size. Layout, hit boxes, mouse mapping, spawn
  // bounds, and miss-detection thresholds all key off these so
  // changing the window size only needs an edit here.
  static DESIGN_W { 960 }
  static DESIGN_H { 720 }

  construct new() {}

  config { {
    "title":      "Fruit Slicer",
    "width":      FruitSlicer.DESIGN_W,
    "height":     FruitSlicer.DESIGN_H,
    "clearColor": [0.04, 0.03, 0.08, 1.0]
  } }

  setup(g) {
    _renderer = Renderer2D.new(g.device, g.surfaceFormat)
    _camera   = Camera2D.contain(FruitSlicer.DESIGN_W, FruitSlicer.DESIGN_H, g.width, g.height)
    _hud      = HUD.new(g)      // for splash + loading bar + ready prompt
    _quad     = null            // built once the atlas resolves
    _manifest = null
    _atlas    = null
    _fruitNames = []

    // Scene-flow chart. Each transition is driven by a real
    // signal (timer expiry, AssetLoader callback, mouse click,
    // lives hitting zero) — no chart-internal auto-transitions.
    _chart = StateChart.build {|c|
      c.id("flow")
      c.initial("splash")
      c.state("splash")   {|s| s.on("ready",    "loading")  }
      c.state("loading")  {|s|
        s.on("loaded",    "ready")
        s.on("loadError", "error")
      }
      c.state("ready")    {|s| s.on("start",    "playing")  }
      c.state("playing")  {|s| s.on("gameover", "gameover") }
      c.state("gameover") {|s| s.on("restart",  "ready")    }
      c.state("error")    {|s|}    // terminal
    }
    _chart.start()

    // Splash timer — bumped each frame in update; flips the chart
    // into loading once the title's had time to read.
    _splashTimer  = 0
    _splashLength = 1.2

    // AssetLoader — one queued closure per asset. The loader
    // resolves them one at a time across frames, firing
    // onProgress per resolve and onComplete when the queue
    // drains. We then upload the texture + cache the manifest
    // *inside* onComplete since GPU upload needs the device,
    // which the loader doesn't know about.
    var db = Assets.open("assets")
    _loader = AssetLoader.new()
    _loader.queue("manifest", Fn.new { JSON.parse(db.text("atlas.json")) })
    _loader.queue("bytes",    Fn.new { db.bytes("atlas.rgba8") })
    // Closures dispatch into methods so the heavy work runs in
    // method bodies rather than a closure body — the interpreter
    // path doesn't currently support every Wren idiom inside
    // closures (Map subscript get is one), and methods sidestep
    // that limitation cleanly.
    var self = this
    _loader.onError(Fn.new {|name, err| self.onLoadError_(name, err) })
    _loader.onComplete(Fn.new {|loaded| self.onAssetsLoaded_(g, loaded) })

    // Tracks the most recent (fraction, done, total) so the
    // loading-scene draw can read without hitting AssetLoader's
    // internals.
    _loadFraction = 0
    _loadDone     = 0
    _loadTotal    = 0
    _loader.onProgress(Fn.new {|fraction, done, total|
      self.onLoadProgress_(fraction, done, total)
    })

    // Artificial inter-asset delay so the loading bar stays
    // visible long enough to read. Real assets resolve in
    // milliseconds; without this throttle the loading scene
    // flashes by faster than the eye can register.
    _loadingThrottle = 0
    _loadingDelay    = 0.6     // seconds per asset

    _seed = 1
    resetGame_
    System.print("Fruit Slicer — splash → loading → ready → playing")
  }

  resize(g, w, h) { _camera.fitContain(w, h) }

  // Draw `text` horizontally + vertically centred in the design
  // space, with `yOffset` shifting it above (negative) or below
  // (positive) the centre line. Caller-side use:
  //
  //   labelCentre_("FRUIT SLICER", -40, 5, [1, 0.85, 0.4, 1])
  //   labelCentre_("A SWIPE GAME",  30, 2, [0.85, 0.85, 0.85, 0.85])
  //
  // wraps the same intent as raw `_hud.label((DESIGN_W - W) / 2,
  // DESIGN_H / 2 + offset - H / 2, ...)` without spelling the
  // anchor math at every call site.
  labelCentre_(text, yOffset, scale, color) {
    var size = HUD.measure(text, scale)
    // Snap to integer pixel coords so the sprite-batch vertex
    // floats stay clean — non-integer x/y are valid for the
    // shader but the JIT's been seen to corrupt fractional
    // arithmetic across closure-receiver tier-ups, surfacing as
    // `Float32Array[_]=: value must be a number` errors on
    // every batch write that frame.
    var x = ((FruitSlicer.DESIGN_W - size[0]) / 2).floor
    var y = (FruitSlicer.DESIGN_H / 2 + yOffset - size[1] / 2).floor
    _hud.label(text, x, y, scale, color)
  }

  // Loader callback dispatch — these are method bodies the
  // closures above forward into so the Map subscript / texture
  // upload code runs outside a closure context.
  onAssetsLoaded_(g, loaded) {
    _manifest = loaded["manifest"]
    var size  = _manifest["size"]
    _atlasW   = size[0]
    _atlasH   = size[1]
    _atlas = g.device.createTexture({
      "width":  _atlasW, "height": _atlasH,
      "format": "rgba8unorm",
      "usage":  ["texture-binding", "copy-dst"]
    })
    g.device.writeTexture(_atlas, loaded["bytes"], {
      "width": _atlasW, "height": _atlasH, "bytesPerRow": _atlasW * 4
    })
    _quad = Sprite.new(_atlas)
    _quad.anchor(0.5, 0.5)
    for (k in _manifest["sprites"].keys) _fruitNames.add(k)
    _chart.send("loaded")
  }

  onLoadProgress_(fraction, done, total) {
    _loadFraction = fraction
    _loadDone     = done
    _loadTotal    = total
  }

  onLoadError_(name, err) {
    System.print("asset '%(name)' failed: %(err)")
    _chart.send("loadError")
  }

  resetGame_ {
    _fruits = []
    _halves = []
    _trail  = []
    _score  = 0
    _lives  = 3
    _spawnTimer = 0.5
    _gameoverT  = 0
  }

  // ── Random ─────────────────────────────────────────────────────

  // Park-Miller minimal-standard LCG. The product seed*16807 peaks
  // at ~3.6e13 — well under 2^53 — so it stays exact in f64 and the
  // mod keeps state in [0, 2^31-2].
  rand_ {
    _seed = (_seed * 16807) % 2147483647
    return _seed / 2147483647
  }
  randRange_(lo, hi) { lo + (hi - lo) * rand_ }

  // ── Per-state update / draw dispatch ───────────────────────────

  update(g) {
    if      (_chart.activeStates.contains("splash"))   updateSplash_(g)
    else if (_chart.activeStates.contains("loading"))  updateLoading_(g)
    else if (_chart.activeStates.contains("ready"))    updateReady_(g)
    else if (_chart.activeStates.contains("playing")) updatePlaying_(g)
    else if (_chart.activeStates.contains("gameover")) updateGameover_(g)
  }

  draw(g) {
    _renderer.beginFrame(_camera)
    _renderer.beginPass(g.pass)
    _hud.beginFrame(g, _renderer)
    if      (_chart.activeStates.contains("splash"))   drawSplash_(g)
    else if (_chart.activeStates.contains("loading"))  drawLoading_(g)
    else if (_chart.activeStates.contains("ready"))    drawReady_(g)
    else if (_chart.activeStates.contains("playing")) drawPlaying_(g)
    else if (_chart.activeStates.contains("gameover")) drawGameover_(g)
    else if (_chart.activeStates.contains("error"))    drawError_(g)
    _hud.endFrame
    _renderer.endPass()
    _renderer.flush(g.pass)
  }

  // ── Splash ─────────────────────────────────────────────────────

  updateSplash_(g) {
    _splashTimer = _splashTimer + g.dt
    if (_splashTimer >= _splashLength) {
      _chart.send("ready")              // splash → loading
      _loader.start()
    }
  }

  drawSplash_(g) {
    // No atlas yet — use HUD's procedural font so the splash has
    // something visible while the chart waits out the timer.
    labelCentre_("FRUIT SLICER", -30, 5, [1, 0.85, 0.4, 1])
    labelCentre_("A SWIPE GAME",  30, 2, [0.85, 0.85, 0.85, 0.85])
  }

  // ── Loading ────────────────────────────────────────────────────

  updateLoading_(g) {
    _loadingThrottle = _loadingThrottle + g.dt
    if (_loadingThrottle < _loadingDelay) return
    _loadingThrottle = 0
    _loader.update(g.dt)
  }

  drawLoading_(g) {
    // HUD's 1×1 white pixel + procedural font draws without
    // needing an asset texture, so the loader's progress fraction
    // animates a real bar instead of vanishing into the splash.
    labelCentre_("LOADING", -40, 3, [1, 1, 1, 1])
    // Track + fill — centred horizontally on the design space,
    // sitting on the centre line so LOADING / bar / % stack
    // symmetrically.
    var barW = 500
    var barH = 18
    var barX = (FruitSlicer.DESIGN_W - barW) / 2
    var barY = FruitSlicer.DESIGN_H / 2 - barH / 2
    _hud.rect(barX, barY, barW, barH, [0.18, 0.18, 0.22, 0.9])
    _hud.rect(barX + 2, barY + 2, ((barW - 4) * _loadFraction).floor, barH - 4, [0.4, 0.85, 0.5, 1])
    var pct = (_loadFraction * 100).floor
    labelCentre_("%(pct)%", 40, 2, [0.85, 0.85, 0.85, 1])
  }

  // ── Ready ──────────────────────────────────────────────────────

  updateReady_(g) {
    if (g.input.mouseJustPressed("left")) {
      _chart.send("start")
    }
  }

  drawReady_(g) {
    // Atlas is loaded by ready state — use HUD for menu prompts
    // (system UI) and reserve the atlas's baked letter glyphs for
    // in-game overlays so the visual hierarchy stays clean.
    labelCentre_("CLICK TO START", -25, 4, [1, 1, 1, 1])
    labelCentre_("SLICE THE FRUIT", 25, 2, [0.85, 0.85, 0.85, 1])
  }

  // ── Playing ────────────────────────────────────────────────────

  updatePlaying_(g) {
    // Clamp dt so a tab-focus-loss gap (or a long debugger pause)
    // doesn't drain every fruit past the bottom edge in one tick.
    // ~33 ms = a 30 fps step's worth.
    var dt = g.dt
    if (dt > 0.033) dt = 0.033

    _spawnTimer = _spawnTimer - dt
    if (_spawnTimer <= 0) {
      spawn_
      _spawnTimer = randRange_(0.7, 1.4)
    }

    // Whole-fruit kinematics + miss detection.
    var i = 0
    while (i < _fruits.count) {
      var f = _fruits[i]
      f["vy"] = f["vy"] + 1500 * dt
      f["x"]  = f["x"]  + f["vx"] * dt
      f["y"]  = f["y"]  + f["vy"] * dt
      if (f["y"] > FruitSlicer.DESIGN_H + 60) {
        _fruits.removeAt(i)
        _lives = _lives - 1
        if (_lives <= 0) {
          _chart.send("gameover")
          _gameoverT = 0
        }
      } else {
        i = i + 1
      }
    }

    updateHalves_(dt)
    updateTrail_(g)
  }

  updateHalves_(dt) {
    var hi = 0
    while (hi < _halves.count) {
      var h = _halves[hi]
      h["vy"]  = h["vy"]  + 1500 * dt
      h["x"]   = h["x"]   + h["vx"] * dt
      h["y"]   = h["y"]   + h["vy"] * dt
      h["rot"] = h["rot"] + h["vrot"] * dt
      h["age"] = h["age"] + dt
      if (h["age"] > 1.0 || h["y"] > FruitSlicer.DESIGN_H + 120) {
        _halves.removeAt(hi)
      } else {
        hi = hi + 1
      }
    }
  }

  updateTrail_(g) {
    if (g.input.mouseJustPressed("left")) _trail.clear()
    if (g.input.mouseDown("left")) {
      var mx = g.input.mouseX * (FruitSlicer.DESIGN_W / g.width)
      var my = g.input.mouseY * (FruitSlicer.DESIGN_H / g.height)
      if (_trail.count > 0) {
        var p1 = _trail[_trail.count - 1]
        checkSlice_(p1["x"], p1["y"], mx, my)
        // Interpolate between the last sample and the new one so
        // a fast swipe reads as a continuous streak instead of
        // discrete dots. step controls the visual density —
        // smaller = denser, more sprites per frame.
        var dx = mx - p1["x"]
        var dy = my - p1["y"]
        var dist = (dx * dx + dy * dy).sqrt
        var step = 6
        var nSeg = (dist / step).floor
        if (nSeg > 1) {
          var i = 1
          while (i < nSeg) {
            var t = i / nSeg
            _trail.add({"x": p1["x"] + dx * t, "y": p1["y"] + dy * t, "age": 0})
            i = i + 1
          }
        }
      }
      _trail.add({"x": mx, "y": my, "age": 0})
      if (_trail.count > 64) _trail.removeAt(0)
    }
    var j = 0
    while (j < _trail.count) {
      _trail[j]["age"] = _trail[j]["age"] + 1
      if (_trail[j]["age"] > 16) {
        _trail.removeAt(j)
      } else {
        j = j + 1
      }
    }
  }

  drawPlaying_(g) {
    var quad = _quad

    // Whole fruits.
    for (f in _fruits) {
      var p = _manifest["sprites"][f["name"]]["uv"]
      quad.uv(p[0], p[1], p[2], p[3])
      quad.width  = 80
      quad.height = 80
      quad.x = f["x"]
      quad.y = f["y"]
      quad.setTint(1, 1, 1, 1)
      quad.draw(_renderer)
    }

    // Sliced halves. The current native Renderer2D draws
    // axis-aligned quads only; tumbling rotation is planned but
    // not yet shipped, so the halves translate along their
    // velocity vectors and fade out as age approaches 1s without
    // spinning. Half geometry still flies apart perpendicular to
    // the swipe direction so the slice still reads.
    for (h in _halves) {
      var key = h["name"] + "_" + h["side"]
      var p = _manifest["halves"][key]["uv"]
      quad.uv(p[0], p[1], p[2], p[3])
      quad.width  = 40
      quad.height = 80
      quad.x = h["x"]
      quad.y = h["y"]
      var alpha = 1 - h["age"]
      if (alpha < 0) alpha = 0
      quad.setTint(1, 1, 1, alpha)
      quad.draw(_renderer)
    }

    drawStreak_()
    drawHud_()
  }

  drawStreak_() {
    var quad = _quad
    var streakUv = _manifest["hud"]["streak"]["uv"]
    quad.uv(streakUv[0], streakUv[1], streakUv[2], streakUv[3])
    var ti = 0
    while (ti < _trail.count) {
      var p = _trail[ti]
      var a = p["age"] / 16
      var alpha = (1 - a) * (1 - a)
      quad.x = p["x"]
      quad.y = p["y"]
      quad.width  = 14 + 6 * (1 - a)
      quad.height = 14 + 6 * (1 - a)
      quad.setTint(1, 1, 0.85, alpha)
      quad.draw(_renderer)
      ti = ti + 1
    }
  }

  drawHud_() {
    var quad = _quad
    // Lives (hearts top-left).
    var heartUv = _manifest["hud"]["heart"]["uv"]
    quad.uv(heartUv[0], heartUv[1], heartUv[2], heartUv[3])
    quad.width  = 32
    quad.height = 32
    quad.setTint(1, 1, 1, 1)
    var hi = 0
    while (hi < _lives) {
      quad.x = 28 + hi * 36
      quad.y = 28
      quad.draw(_renderer)
      hi = hi + 1
    }

    // Score (digits top-right). Right-aligned by precomputing
    // the total width.
    var digits = _score.toString
    var n = digits.count
    var startX = FruitSlicer.DESIGN_W - 16 - 24 * n + 12   // anchor=centre → +half-width
    var di = 0
    while (di < n) {
      var ch = digits[di]
      var dproto = _manifest["hud"]["digits"][ch]
      quad.uv(dproto["uv"][0], dproto["uv"][1], dproto["uv"][2], dproto["uv"][3])
      quad.width  = 24
      quad.height = 24
      quad.x = startX + di * 24
      quad.y = 28
      quad.draw(_renderer)
      di = di + 1
    }
  }

  // ── Game over ──────────────────────────────────────────────────

  updateGameover_(g) {
    _gameoverT = _gameoverT + g.dt
    if (g.input.mouseJustPressed("left")) {
      resetGame_
      _chart.send("restart")            // → ready
    }
  }

  drawGameover_(g) {
    // Game-over draws over the last frame of playing state — the
    // sprites froze when the chart transitioned, so the halves
    // and trail still settle visually behind the message.
    drawPlaying_(g)
    _renderer.flush(g.pass)
    var pulse = 0.5 + 0.5 * (_gameoverT * 4).sin
    var alpha = 0.7 + 0.3 * pulse
    labelCentre_("GAME OVER",       -30, 5, [1, 0.35, 0.35, alpha])
    labelCentre_("CLICK TO RESUME",  35, 2, [0.95, 0.85, 0.55, 0.6 + 0.4 * pulse])
  }

  // ── Error state ────────────────────────────────────────────────

  drawError_(g) {
    labelCentre_("ASSET LOAD FAILED", -25, 3, [1, 0.4, 0.4, 1])
    labelCentre_("CHECK CONSOLE",      30, 2, [0.85, 0.85, 0.85, 1])
  }

  // ── Fruit spawn + slice geometry ───────────────────────────────

  spawn_ {
    var name = _fruitNames[(rand_ * _fruitNames.count).floor]
    _fruits.add({
      "name": name,
      "x":    randRange_(80, FruitSlicer.DESIGN_W - 80),
      "y":    FruitSlicer.DESIGN_H + 40,
      "vx":   randRange_(-180, 180),
      "vy":   randRange_(-1100, -900)
    })
  }

  // Per-frame slice check. (x1,y1)→(x2,y2) is the swipe segment
  // between this frame and the previous mouse position. The cut
  // direction is the segment direction; halves fly perpendicular
  // to it and pick up a small velocity component along the swipe
  // so the cut feels followed-through.
  checkSlice_(x1, y1, x2, y2) {
    var sdx = x2 - x1
    var sdy = y2 - y1
    var sLen2 = sdx * sdx + sdy * sdy
    if (sLen2 < 64) return              // < 8 px swipe = treat as click
    var sLen = sLen2.sqrt
    var ux = sdx / sLen
    var uy = sdy / sLen
    var px = -uy
    var py =  ux
    var cutAngle = uy.atan(ux)          // atan2 result
    var i = 0
    while (i < _fruits.count) {
      var f = _fruits[i]
      var hw = 36
      var hh = 36
      var ax = f["x"] - hw
      var ay = f["y"] - hh
      var bx = f["x"] + hw
      var by = f["y"] + hh
      if (segVsAabb_(x1, y1, x2, y2, ax, ay, bx, by)) {
        var spreadV = 280
        var followV =  60
        var spin    = randRange_(8, 14)
        _halves.add({
          "name": f["name"], "side": "left",
          "x": f["x"] + px * 14,
          "y": f["y"] + py * 14,
          "vx": f["vx"] + px * spreadV + ux * followV,
          "vy": f["vy"] + py * spreadV + uy * followV - 80,
          "age": 0, "rot": cutAngle, "vrot": -spin
        })
        _halves.add({
          "name": f["name"], "side": "right",
          "x": f["x"] - px * 14,
          "y": f["y"] - py * 14,
          "vx": f["vx"] - px * spreadV + ux * followV,
          "vy": f["vy"] - py * spreadV + uy * followV - 80,
          "age": 0, "rot": cutAngle, "vrot": spin
        })
        _fruits.removeAt(i)
        _score = _score + 1
      } else {
        i = i + 1
      }
    }
  }

  // Segment-vs-AABB. Both endpoints inside → hit. Otherwise test
  // segment against each of the four box edges via segment-segment.
  segVsAabb_(x1, y1, x2, y2, ax, ay, bx, by) {
    if (x1 < ax && x2 < ax) return false
    if (x1 > bx && x2 > bx) return false
    if (y1 < ay && y2 < ay) return false
    if (y1 > by && y2 > by) return false
    if (x1 >= ax && x1 <= bx && y1 >= ay && y1 <= by) return true
    if (x2 >= ax && x2 <= bx && y2 >= ay && y2 <= by) return true
    return segVsSeg_(x1, y1, x2, y2, ax, ay, bx, ay) ||
           segVsSeg_(x1, y1, x2, y2, bx, ay, bx, by) ||
           segVsSeg_(x1, y1, x2, y2, bx, by, ax, by) ||
           segVsSeg_(x1, y1, x2, y2, ax, by, ax, ay)
  }

  segVsSeg_(ax, ay, bx, by, cx, cy, dx, dy) {
    var d = (bx - ax) * (dy - cy) - (by - ay) * (dx - cx)
    if (d == 0) return false
    var t = ((cx - ax) * (dy - cy) - (cy - ay) * (dx - cx)) / d
    var u = ((cx - ax) * (by - ay) - (cy - ay) * (bx - ax)) / d
    return t >= 0 && t <= 1 && u >= 0 && u <= 1
  }
}

Game.run(FruitSlicer)
