// @hatch:events — in-process pub/sub: Signal for single-channel,
// EventEmitter for Node-style named events.
//
//   import "@hatch:events" for Signal, EventEmitter
//
// ## Signal — one event channel, many listeners
//
//   var onExit = Signal.new
//   var disconnect = onExit.connect {|code| System.print("exit: %(code)") }
//   onExit.emit(0)                // fires the listener
//   disconnect.call()             // or `onExit.disconnect(fn)` with the original fn
//
// Signal's .connect returns a disconnect closure so you can pass
// it around without keeping a handle to the original Fn. Listeners
// fire in registration order.
//
// ## EventEmitter — multiple named events
//
//   var bus = EventEmitter.new
//   bus.on("data")   {|chunk| handle(chunk) }
//   bus.on("error")  {|err|   System.print("err: %(err)") }
//   bus.once("end")  { System.print("done") }
//   bus.emit("data", chunk)
//   bus.emit("end")
//
// `once(event, fn)` fires exactly once and removes itself. `off`
// accepts the original Fn reference. `offAll(event)` clears every
// listener for a single event; `offAll` with no arg wipes the
// whole emitter.
//
// Both classes guard against listener-mutation-during-emit by
// iterating over a snapshot. A listener that `off`s itself (or
// adds a new listener) during emission is safe — the current
// emit pass finishes, then later emits see the updated state.
//
// Pure Wren; no runtime dependency. Fibers / threads aren't
// involved — emit runs synchronously on the caller.

// --- Signal ------------------------------------------------------------------

class Signal {
  construct new() {
    _listeners = []
    _name = null
  }
  construct new(name) {
    _listeners = []
    _name = name
  }

  name { _name }

  // Active listener count, including any that are flagged for
  // one-shot removal but haven't fired yet.
  listenerCount { _listeners.count }

  // Register a listener. Returns a disconnect closure — calling
  // it removes the listener. `disconnect(fn)` with the same Fn
  // reference is equivalent.
  connect(fn) {
    if (!(fn is Fn)) Fiber.abort("Signal.connect: listener must be a Fn")
    _listeners.add([fn, false])
    var self = this
    return Fn.new { self.disconnect(fn) }
  }

  // Register a one-shot listener. Fires at most once, then is
  // removed automatically.
  connectOnce(fn) {
    if (!(fn is Fn)) Fiber.abort("Signal.connectOnce: listener must be a Fn")
    _listeners.add([fn, true])
    var self = this
    return Fn.new { self.disconnect(fn) }
  }

  // Remove a listener by reference. No-op if absent.
  disconnect(fn) {
    var i = 0
    while (i < _listeners.count) {
      if (_listeners[i][0] == fn) {
        _listeners.removeAt(i)
        return
      }
      i = i + 1
    }
  }

  // Remove every listener.
  disconnectAll {
    _listeners.clear()
  }

  // --- Emit helpers: Wren Fn.call is arity-specific, so we
  // expose emit overloads up through 3 positional args. For more,
  // use `emitMany(list)` which unpacks.

  emit()          { emit_([]) }
  emit(a)         { emit_([a]) }
  emit(a, b)      { emit_([a, b]) }
  emit(a, b, c)   { emit_([a, b, c]) }

  // Fire with a list of 0..3 arguments. Anything longer aborts —
  // wrap your arguments in a struct-like Map or List instead.
  emitMany(args) {
    if (!(args is List)) Fiber.abort("Signal.emitMany: args must be a list")
    if (args.count > 3) Fiber.abort("Signal.emitMany: supports up to 3 args; pass a List/Map for more")
    emit_(args)
  }

  emit_(args) {
    // Snapshot first: a listener that disconnects itself (or
    // anyone else) mid-emit must not trip iteration. Then drop
    // once-listeners from the real list before firing so a
    // listener that re-enters emit doesn't see the stale entry.
    var snapshot = []
    var i = 0
    while (i < _listeners.count) {
      snapshot.add(_listeners[i][0])
      i = i + 1
    }
    var j = 0
    while (j < _listeners.count) {
      if (_listeners[j][1] == true) {
        _listeners.removeAt(j)
      } else {
        j = j + 1
      }
    }
    i = 0
    while (i < snapshot.count) {
      var fn = snapshot[i]
      if (args.count == 0)      fn.call()
      else if (args.count == 1) fn.call(args[0])
      else if (args.count == 2) fn.call(args[0], args[1])
      else                       fn.call(args[0], args[1], args[2])
      i = i + 1
    }
  }

  toString {
    if (_name == null) return "Signal(%(_listeners.count) listeners)"
    return "Signal(%(_name), %(_listeners.count) listeners)"
  }
}

// --- EventEmitter ------------------------------------------------------------

class EventEmitter {
  construct new() {
    _listeners = {}   // event name → List of [fn, once_flag]
  }

  // Names of every event with at least one listener.
  eventNames {
    var out = []
    for (entry in _listeners) out.add(entry.key)
    return out
  }

  // How many listeners (counting once-pending ones) for `event`.
  listenerCount(event) {
    if (!_listeners.containsKey(event)) return 0
    return _listeners[event].count
  }

  // Register a listener. Returns a disconnect closure.
  on(event, fn) {
    if (!(event is String)) Fiber.abort("EventEmitter.on: event must be a string")
    if (!(fn is Fn))        Fiber.abort("EventEmitter.on: listener must be a Fn")
    add_(event, fn, false)
    var self = this
    return Fn.new { self.off(event, fn) }
  }

  // One-shot listener. Fires at most once, removes itself.
  once(event, fn) {
    if (!(event is String)) Fiber.abort("EventEmitter.once: event must be a string")
    if (!(fn is Fn))        Fiber.abort("EventEmitter.once: listener must be a Fn")
    add_(event, fn, true)
    var self = this
    return Fn.new { self.off(event, fn) }
  }

  // Remove a specific listener by reference.
  off(event, fn) {
    if (!_listeners.containsKey(event)) return
    var list = _listeners[event]
    var i = 0
    while (i < list.count) {
      if (list[i][0] == fn) {
        list.removeAt(i)
        if (list.count == 0) _listeners.remove(event)
        return
      }
      i = i + 1
    }
  }

  // `offAll(event)` clears one event's listeners. `offAll` with
  // no argument clears everything.
  offAll(event) {
    _listeners.remove(event)
  }

  offAll {
    _listeners.clear()
  }

  // --- Emit overloads ---

  emit(event)            { emit_(event, []) }
  emit(event, a)         { emit_(event, [a]) }
  emit(event, a, b)      { emit_(event, [a, b]) }
  emit(event, a, b, c)   { emit_(event, [a, b, c]) }

  emitMany(event, args) {
    if (!(args is List)) Fiber.abort("EventEmitter.emitMany: args must be a list")
    if (args.count > 3) Fiber.abort("EventEmitter.emitMany: supports up to 3 args; pass a List/Map for more")
    emit_(event, args)
  }

  // Fires `fn` directly — used internally by `once` / `on` after
  // capturing the arity path.
  emit_(event, args) {
    if (!_listeners.containsKey(event)) return
    var list = _listeners[event]
    var snapshot = []
    var i = 0
    while (i < list.count) {
      snapshot.add(list[i][0])
      i = i + 1
    }
    var j = 0
    while (j < list.count) {
      if (list[j][1] == true) {
        list.removeAt(j)
      } else {
        j = j + 1
      }
    }
    if (list.count == 0) _listeners.remove(event)
    i = 0
    while (i < snapshot.count) {
      var fn = snapshot[i]
      if (args.count == 0)      fn.call()
      else if (args.count == 1) fn.call(args[0])
      else if (args.count == 2) fn.call(args[0], args[1])
      else                       fn.call(args[0], args[1], args[2])
      i = i + 1
    }
  }

  add_(event, fn, once) {
    if (!_listeners.containsKey(event)) _listeners[event] = []
    _listeners[event].add([fn, once])
  }

  toString { "EventEmitter(%(_listeners.count) events)" }
}
