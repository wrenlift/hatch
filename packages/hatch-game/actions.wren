//! `Actions` — semantic input-binding layer on top of raw key /
//! mouse / (eventually) gamepad codes.
//!
//! Game code talks about *intents* (`"jump"`, `"attack"`,
//! `"forward"`) instead of physical hardware codes. Bindings are
//! a List of code strings per action; the same intent can map to
//! several inputs simultaneously, and bindings are rebindable at
//! runtime so a settings menu can reassign them without the game
//! caring.
//!
//! Each registered action surfaces two parallel views:
//!
//!   1. **Polled state** — `Actions.isDown` / `Actions.justPressed` /
//!      `Actions.justReleased` / `Actions.value(name)`. Mirrors the
//!      shape of `g.input.justPressed("KeyW")` but reads against the
//!      semantic name.
//!   2. **Event stream** — every just-pressed / just-released edge is
//!      emitted on a shared `EventEmitter` as `"<name>"` (press)
//!      and `"<name>.released"` (release). Statecharts subscribe via
//!      [`StateChart.bindEvents(Actions.emitter, ["jump", "attack"])`](https://hatch.wrenlift.com/packages/@hatch:fsm),
//!      so an action firing directly drives FSM transitions. No
//!      glue Fn per action; the chart picks up the event name as
//!      the transition trigger.
//!
//! ```wren
//! import "@hatch:game"  for Game, Actions
//! import "@hatch:fsm"   for StateChart
//!
//! class MyGame is Game {
//!   setup(g) {
//!     Actions.define("jump",    ["KeyP", "MouseLeft"])
//!     Actions.define("forward", ["KeyW"])
//!     Actions.define("back",    ["KeyS"])
//!
//!     _player = StateChart.build {|c|
//!       c.id("player").initial("ground")
//!       c.state("ground") {|s|
//!         s.on("jump").to("air")
//!       }
//!       c.state("air") {|s|
//!         s.on("land").to("ground")
//!       }
//!     }
//!     _player.bindEvents(Actions.emitter, ["jump"])
//!     _player.start()
//!   }
//!
//!   update(g) {
//!     // Polled read for analog-ish movement:
//!     var dx = Actions.value("forward") - Actions.value("back")
//!     player.moveX(dx)
//!     // Edge-triggered transitions land on the chart automatically
//!     // via the bindEvents subscription above.
//!   }
//! }
//! ```
//!
//! ## Binding strings
//!
//! | Family | Examples |
//! |---|---|
//! | Keyboard | `"KeyA"`, `"Space"`, `"Escape"`, `"ArrowLeft"` — winit-style codes |
//! | Mouse buttons | `"MouseLeft"`, `"MouseRight"`, `"MouseMiddle"` |
//! | Gamepad buttons | `"GamepadButtonA"`, `"GamepadButtonB"`, `"GamepadDPadUp"`, `"GamepadLeftTrigger"`, ... |
//! | Gamepad axes | `"GamepadAxisLX"`, `"GamepadAxisLY"`, `"GamepadAxisRX"`, `"GamepadAxisRY"`, `"GamepadAxisLZ"`, `"GamepadAxisRZ"` |
//!
//! Gamepad bindings are honoured natively (via gilrs in the
//! `@hatch:window` plugin). Buttons resolve to 0/1; axes to -1..1.
//!
//! ## Why a static facade?
//!
//! `Actions` is a singleton because the binding table is global
//! to a running game session — every system reads against the
//! same map. Game.run wires it into the per-frame input pump
//! automatically, so user code doesn't carry an Actions instance
//! around.

import "@hatch:events" for EventEmitter

/// A single named action — a list of binding code strings plus
/// the per-frame state derived from them. You almost never
/// construct one of these directly; use `Actions.define(name, bindings)`.
class Action_ {
  construct new_(name, bindings) {
    _name           = name
    _bindings       = bindings        // List<String>
    _down           = false           // held this frame
    _wasDown        = false           // held previous frame
    _value          = 0               // 0..1 for buttons, signed for axes
    _justPressed    = false
    _justReleased   = false
  }

  name              { _name }
  bindings          { _bindings }
  isDown            { _down }
  value             { _value }
  justPressed       { _justPressed }
  justReleased      { _justReleased }

  bind(codes) {
    if (!(codes is List)) {
      Fiber.abort("Action.bind: codes must be a List<String>, got %(codes.type)")
    }
    _bindings = codes
  }
  addBinding(code)    { _bindings.add(code) }
  clearBindings       { _bindings.clear() }

  // Evaluate this action against `input` for one frame. `axisMap`
  // is an optional Map<String, Num> for axis-typed bindings (e.g.
  // gamepad sticks). Returns true if the action transitioned to /
  // from pressed this frame.
  evaluate_(input, axisMap) {
    _wasDown = _down
    _down    = false
    _value   = 0
    for (code in _bindings) {
      var v = bindingValue_(code, input, axisMap)
      if (v.abs > _value.abs) _value = v
      if (v.abs > 0.5) _down = true
    }
    _justPressed  = _down && !_wasDown
    _justReleased = !_down && _wasDown
  }

  // Resolve one binding code to a value in -1..1. Buttons map to
  // 0 or 1 (held), positive axes to 0..1, negative axes to -1..0.
  // Unsupported codes (today: gamepad anything) return 0 so the
  // API surface accepts them without throwing.
  bindingValue_(code, input, axisMap) {
    if (code is String) {
      if (code.startsWith("Mouse")) {
        var b = Action_.mouseButton_(code)
        return b != null && input.mouseDown(b) ? 1 : 0
      }
      if (code.startsWith("Gamepad")) {
        if (axisMap != null && axisMap.containsKey(code)) return axisMap[code]
        return 0
      }
      return input.isDown(code) ? 1 : 0
    }
    return 0
  }

  static mouseButton_(code) {
    if (code == "MouseLeft")   return "left"
    if (code == "MouseRight")  return "right"
    if (code == "MouseMiddle") return "middle"
    return null
  }
}

/// `Actions` — global semantic-input registry. Define actions in
/// `setup`, query / observe them through the frame.
class Actions {
  /// Define `name` with a list of binding code strings. Replaces
  /// any existing definition for that name.
  ///
  /// ```wren
  /// Actions.define("jump", ["KeyP", "MouseLeft"])
  /// ```
  ///
  /// @param  {String}        name
  /// @param  {List<String>}  bindings
  static define(name, bindings) {
    Actions.ensureInit_()
    if (!(name is String)) {
      Fiber.abort("Actions.define: name must be a String, got %(name.type)")
    }
    if (!(bindings is List)) {
      Fiber.abort("Actions.define: bindings must be a List<String>, got %(bindings.type)")
    }
    ACTION_REGISTRY_[name] = Action_.new_(name, bindings.toList)
  }

  /// Replace an existing action's bindings. Errors if `name`
  /// hasn't been defined yet — use `define` for a fresh entry.
  ///
  /// @param  {String}        name
  /// @param  {List<String>}  bindings
  static bind(name, bindings) {
    Actions.ensureInit_()
    var a = ACTION_REGISTRY_[name]
    if (a == null) Fiber.abort("Actions.bind: '%(name)' not defined")
    a.bind(bindings)
  }

  /// Append a single binding to an existing action without
  /// disturbing the rest.
  ///
  /// @param  {String} name
  /// @param  {String} code
  static addBinding(name, code) {
    Actions.ensureInit_()
    var a = ACTION_REGISTRY_[name]
    if (a == null) Fiber.abort("Actions.addBinding: '%(name)' not defined")
    a.addBinding(code)
  }

  /// Drop every binding from an action. The action itself stays
  /// registered (so `isDown` still returns `false` rather than
  /// erroring); rebind through `bind` to wire it back up.
  ///
  /// @param  {String} name
  static clearBindings(name) {
    Actions.ensureInit_()
    var a = ACTION_REGISTRY_[name]
    if (a == null) Fiber.abort("Actions.clearBindings: '%(name)' not defined")
    a.clearBindings
  }

  /// Forget the action entirely. Subsequent queries on `name`
  /// return `false` / `0` without erroring.
  ///
  /// @param  {String} name
  static remove(name) {
    Actions.ensureInit_()
    ACTION_REGISTRY_.remove(name)
  }

  /// Drop every registered action. Test hook + "new game"
  /// shortcut.
  static reset() {
    Actions.ensureInit_()
    ACTION_REGISTRY_.clear()
    Actions.replaceEmitter_(EventEmitter.new())
  }

  /// Iterate the registered action names. Useful for a settings
  /// UI that wants to render the binding table.
  ///
  /// @returns {Sequence<String>}
  static names {
    Actions.ensureInit_()
    return ACTION_REGISTRY_.keys
  }

  /// Read back the current binding list for an action — a fresh
  /// copy you can hand to a UI table or serialize for save/load.
  ///
  /// @param  {String} name
  /// @returns {List<String>}
  static bindings(name) {
    Actions.ensureInit_()
    var a = ACTION_REGISTRY_[name]
    if (a == null) return []
    return a.bindings.toList
  }

  /// True while any of `name`'s bindings is currently held.
  /// Mirrors `g.input.isDown` but reads against the semantic
  /// name.
  ///
  /// @param  {String} name
  /// @returns {Bool}
  static isDown(name) {
    Actions.ensureInit_()
    var a = ACTION_REGISTRY_[name]
    return a == null ? false : a.isDown
  }

  /// True only on the single frame any binding for `name` first
  /// transitioned to pressed.
  ///
  /// @param  {String} name
  /// @returns {Bool}
  static justPressed(name) {
    Actions.ensureInit_()
    var a = ACTION_REGISTRY_[name]
    return a == null ? false : a.justPressed
  }

  /// True only on the single frame any binding for `name` was
  /// released.
  ///
  /// @param  {String} name
  /// @returns {Bool}
  static justReleased(name) {
    Actions.ensureInit_()
    var a = ACTION_REGISTRY_[name]
    return a == null ? false : a.justReleased
  }

  /// Continuous value in `-1..1`. For pure-button bindings this
  /// is `0` or `1`; for analog axes it follows the axis. Held
  /// modifier of any pressed binding wins.
  ///
  /// @param  {String} name
  /// @returns {Num}
  static value(name) {
    Actions.ensureInit_()
    var a = ACTION_REGISTRY_[name]
    return a == null ? 0 : a.value
  }

  /// Shared event emitter. Every just-pressed edge emits
  /// `"<name>"`; every just-released edge emits
  /// `"<name>.released"`. Subscribe with a StateChart to drive
  /// FSM transitions:
  ///
  /// ```wren
  /// chart.bindEvents(Actions.emitter, ["jump", "attack"])
  /// ```
  ///
  /// @returns {EventEmitter}
  static emitter {
    Actions.ensureInit_()
    return ACTION_EMITTER_HOLDER_[0]
  }

  /// Convenience: subscribe a Fn to a single action's press
  /// edge. Returns a disconnect Fn (call it to unsubscribe).
  ///
  /// @param  {String} name
  /// @param  {Fn}     fn   zero-arity Fn
  /// @returns {Fn}    disconnect closure
  static on(name, fn) {
    Actions.ensureInit_()
    return ACTION_EMITTER_HOLDER_[0].on(name, fn)
  }

  /// Convenience: subscribe a Fn to a single action's release
  /// edge.
  ///
  /// @param  {String} name
  /// @param  {Fn}     fn
  /// @returns {Fn}    disconnect closure
  static onReleased(name, fn) {
    Actions.ensureInit_()
    return ACTION_EMITTER_HOLDER_[0].on("%(name).released", fn)
  }

  // Internal — called once per frame by Game.run after the
  // window event drain and `Input.beginFrame_` have completed.
  // `axisMap` is an optional Map<String, Num> for analog inputs
  // (gamepad axes). Today's input layer doesn't surface them so
  // it's typically null.
  static update_(input) { Actions.update_(input, null) }
  static update_(input, axisMap) {
    Actions.ensureInit_()
    var em = ACTION_EMITTER_HOLDER_[0]
    for (k in ACTION_REGISTRY_.keys) {
      var a = ACTION_REGISTRY_[k]
      a.evaluate_(input, axisMap)
      // Emit edges. The press event name is bare (`"jump"`) so
      // statecharts pick it up via `bindEvents`; release events
      // are dotted (`"jump.released"`) so a release listener
      // doesn't fight the press subscription on the same name.
      if (a.justPressed)  em.emit(k)
      if (a.justReleased) em.emit("%(k).released")
    }
  }

  // Lazy bootstrap. The state lives in module-level vars
  // (Wren's static-field convention `__foo` doesn't round-trip
  // cleanly through this codebase's reflection — see
  // GameState.lastTime_ for the same workaround). Holders are
  // single-element lists so a static method can rebind the
  // emitter pointer without losing the binding from earlier
  // calls.
  static ensureInit_() {
    if (ACTION_EMITTER_HOLDER_[0] == null) {
      ACTION_EMITTER_HOLDER_[0] = EventEmitter.new()
    }
  }

  // Internal: swap in a fresh emitter. Used by `reset()`; lives
  // here so tests can verify the emitter identity changes.
  static replaceEmitter_(em) { ACTION_EMITTER_HOLDER_[0] = em }
}

// Module-private state. Plain Maps / Lists rather than `__`
// statics — matches `PHYSICS_SCRATCH_3D_` in scene.wren and
// `GameState.lastTime_` in game.wren, both of which dodge the
// same Wren static-field plumbing. The emitter lives inside a
// one-slot list so `Actions.reset()` can rebind the pointer
// without losing the cell identity.
var ACTION_REGISTRY_       = {}
var ACTION_EMITTER_HOLDER_ = [null]
