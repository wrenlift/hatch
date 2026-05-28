// `@hatch:fsm` — Harel statecharts for Wren.
//
// Closure-based builder for defining a chart; pure-Wren runtime
// for executing it. Validation collapses into the builder API —
// each method's arguments are type-checked at the call site, and
// structural rules (final has no substates, parallel needs ≥2
// regions, compound needs initial) are enforced as builder mode.
//
// Surface: atomic + compound + parallel states, sibling-relative
// and fully-qualified transition targets, history pseudo-targets,
// final states with `done` emission, guards, entry / exit /
// transition actions, internal transitions, `fromMap` data-driven
// adapter, and `start` / `stop` / `send` / `matches` runtime ops.
// Observation via `@hatch:events`-style signal channels:
// `fsm.on("transition")`, `fsm.on("enter:<path>")`,
// `fsm.on("exit:<path>")`, `fsm.on("unhandled")`, `fsm.on("done")`,
// wildcard `*`, plus `bindEvents(emitter, eventNames)` to forward
// an external emitter's events into the chart.
//
// ```wren
// import "@hatch:fsm" for StateChart
//
// var fsm = StateChart.build {|chart|
//   chart.id("door")
//   chart.initial("closed")
//   chart.state("closed") {|s| s.on("open",  "open")   }
//   chart.state("open")   {|s| s.on("close", "closed") }
// }
//
// fsm.start()
// fsm.send("open")           // "closed" → "open"
// fsm.activeStates           // ["open"]
// fsm.matches("open")        // true
//
// fsm.on("transition") {|from, to, evt| log.info("%(from)→%(to)") }
// fsm.on("enter:open")  {|ctx, evt|     sfx.play("creak") }
// fsm.on("exit:closed") {|ctx, evt|     particles.dust() }
// ```

import "@hatch:events" for EventEmitter

// --- Compiled tree (immutable shape after finish) -----------------------------

/// One state in the compiled chart. Built once by the chart
/// builder; the only mutation after `finish()` is when the
/// resolver patches each transition's `target` from the
/// user-written name (possibly sibling-relative) to a
/// fully-qualified path.
class StateNode_ {
  construct new_(name, parent, kind, initial, entry, exit, transitions, states) {
    _name = name
    _parent = parent          // StateNode_ or null (root state)
    _kind = kind              // "atomic" | "compound" | "parallel" | "final"
    _initial = initial        // name of an immediate child, or null
    _entry = entry            // List<Fn>
    _exit = exit              // List<Fn>
    _transitions = transitions // Map<event, List<TransitionBranch_>>
    _states = states          // Map<name, StateNode_>
    _path = parent == null ? name : "%(parent.path).%(name)"
  }
  name { _name }
  parent { _parent }
  kind { _kind }
  initial { _initial }
  entry { _entry }
  exit { _exit }
  transitions { _transitions }
  states { _states }
  path { _path }

  /// Walk this subtree depth-first, calling `fn` with each node.
  walk(fn) {
    fn.call(this)
    for (entry in _states) entry.value.walk(fn)
  }

  /// Find the first matching transition for `event` walking from
  /// this node up through ancestors. `guardEval` is called with
  /// each branch's guard Fn (or null); it should return true
  /// when the branch is eligible. Returns `[branch, sourceNode]`
  /// of the first match, or null.
  ///
  /// SCXML semantics: at each ancestor that defines handlers
  /// for the event, evaluate every branch in declaration order,
  /// taking the first eligible one. Branches without guards are
  /// always eligible. If none match at this level, ascend.
  findTransition_(event, guardEval) {
    var key = event is String ? event : event["type"]
    var node = this
    while (node != null) {
      var branches = node.transitions[key]
      if (branches != null) {
        for (branch in branches) {
          if (guardEval.call(branch)) {
            return [branch, node]
          }
        }
      }
      node = node.parent
    }
    return null
  }
}

/// A single transition branch. Multiple branches per event become
/// guard-ordered alternatives — the first branch whose guard
/// returns `true` (or has no guard) wins.
class TransitionBranch_ {
  construct new_(event, target, guard, actions, internal) {
    _event = event
    _target = target          // user-written; rewritten to fully-qualified by resolver
    _guard = guard            // Fn or null
    _actions = actions        // List<Fn>
    _internal = internal      // Bool — internal transition skips exit/entry
  }
  event { _event }
  target { _target }
  guard { _guard }
  actions { _actions }
  internal { _internal }

  /// Called by the resolver in ChartBuilder_._resolveTargets_
  /// to rewrite the user-written target to a fully-qualified path.
  resolveTo_(path) { _target = path }
}

/// Builder yielded inside `s.on(event) {|t| ... }`. Lets the
/// user attach a guard, transition action(s), target, or mark
/// the transition internal.
class TransitionBuilder_ {
  construct new_(sourceName, event) {
    _sourceName = sourceName
    _event = event
    _target = null
    _guard = null
    _actions = []
    _internal = false
  }

  /// Conditional fire. `fn` is called with `(ctx, event)` and
  /// must return a Bool. First branch whose guard returns true
  /// wins, in declaration order; branches with no guard are
  /// always eligible and act as the fallback if listed last.
  when(fn) {
    if (!(fn is Fn)) {
      Fiber.abort("state(%(_sourceName)).on(%(_event)).when: expected Fn, got %(fn.type)")
    }
    _guard = fn
  }

  /// Transition action. Runs after exit actions, before entry
  /// actions. May be called multiple times to attach a list.
  does(fn) {
    if (!(fn is Fn)) {
      Fiber.abort("state(%(_sourceName)).on(%(_event)).does: expected Fn, got %(fn.type)")
    }
    _actions.add(fn)
  }

  /// Set the transition's target state. Sibling-relative or
  /// fully-qualified. Omitting `go(...)` makes this a self-
  /// transition (exit + re-enter the source).
  go(target) {
    if (!(target is String)) {
      Fiber.abort("state(%(_sourceName)).on(%(_event)).go: target must be String, got %(target.type)")
    }
    _target = target
  }

  /// Mark this transition internal. Internal transitions don't
  /// exit/re-enter the source state — actions run, but
  /// entry/exit do not fire. Useful for "tick" handlers that
  /// shouldn't reset substate progress.
  internal() { _internal = true }

  /// Internal: produce a `TransitionBranch_` for this builder.
  finish_() {
    return TransitionBranch_.new_(_event, _target, _guard, _actions, _internal)
  }
}

// --- Builders -----------------------------------------------------------------

/// Builds one state. Created by `ChartBuilder_.state` or by a
/// parent `StateBuilder_.state`. Lives only during the `build`
/// closure; finalized to a `StateNode_` by `ChartBuilder_.finish`.
class StateBuilder_ {
  construct new_(name) {
    _name = name
    _kind = null              // null = unset; flips on first state(), final(), parallel()
    _initial = null
    _entry = []
    _exit = []
    _transitions = {}         // Map<event, List<TransitionBranch_>>
    _states = {}              // Map<name, StateBuilder_> — Wren Maps preserve insertion order
  }
  name { _name }

  /// Declare which substate to descend into on entry. Must match
  /// one of the names declared via `.state(name)` — checked at finish.
  initial(stateName) {
    if (!(stateName is String)) {
      Fiber.abort("state(%(_name)).initial: expected String, got %(stateName.type)")
    }
    _initial = stateName
  }

  /// Declare a substate. First call flips this state's kind to
  /// "compound"; calling `final()` first errors.
  state(name, fn) {
    if (!(name is String)) Fiber.abort("state(%(_name)).state: name must be String, got %(name.type)")
    if (!(fn is Fn))       Fiber.abort("state(%(_name)).state(%(name)): expected Fn, got %(fn.type)")
    if (_kind == "final") {
      Fiber.abort("state(%(_name)).state(%(name)): final state cannot contain substates")
    }
    if (_kind == null) _kind = "compound"
    if (_kind != "compound") {
      Fiber.abort("state(%(_name)).state(%(name)): cannot mix substates into a '%(_kind)' state")
    }
    if (_states.containsKey(name)) {
      Fiber.abort("state(%(_name)).state(%(name)): substate already defined")
    }
    var sub = StateBuilder_.new_(name)
    fn.call(sub)
    _states[name] = sub
  }

  /// Declare a transition. Two shapes:
  ///   s.on("event", "target")     — shorthand: no guard, no action
  ///   s.on("event") {|t| ... }    — full form: configure via TransitionBuilder_
  on(event, target) {
    if (!(event is String)) {
      Fiber.abort("state(%(_name)).on: event must be String, got %(event.type)")
    }
    if (_kind == "final") {
      Fiber.abort("state(%(_name)).on(%(event)): final states cannot have outgoing transitions")
    }
    if (!_transitions.containsKey(event)) _transitions[event] = []

    if (target is String) {
      _transitions[event].add(TransitionBranch_.new_(event, target, null, [], false))
      return
    }
    if (target is Fn) {
      var tb = TransitionBuilder_.new_(_name, event)
      target.call(tb)
      _transitions[event].add(tb.finish_())
      return
    }
    Fiber.abort("state(%(_name)).on(%(event)): 2nd arg must be String or Fn, got %(target.type)")
  }

  /// Register an entry action. Fires when the state is entered,
  /// shallowest-first relative to other entries in the same step.
  /// May be called multiple times to attach a list of actions.
  entry(fn) {
    if (!(fn is Fn)) {
      Fiber.abort("state(%(_name)).entry: expected Fn, got %(fn.type)")
    }
    _entry.add(fn)
  }

  /// Register an exit action. Fires when the state is exited,
  /// deepest-first relative to other exits in the same step.
  exit(fn) {
    if (!(fn is Fn)) {
      Fiber.abort("state(%(_name)).exit: expected Fn, got %(fn.type)")
    }
    _exit.add(fn)
  }

  /// Mark this state as a terminal state.
  final() {
    if (_states.count > 0)      Fiber.abort("state(%(_name)).final: already has substates")
    if (_transitions.count > 0) Fiber.abort("state(%(_name)).final: already has outgoing transitions")
    _kind = "final"
  }

  /// Declare a substate as a parallel region container. Inside
  /// the closure, declare ≥2 substates with `.state(...)`; each
  /// becomes an independently-active region. Entering a parallel
  /// state enters every region simultaneously; exiting exits all.
  ///
  /// Mutually exclusive with `final()`. Can be mixed with regular
  /// `.state(...)` siblings at the same level — a parent can have
  /// some compound children and some parallel children.
  parallel(name, fn) {
    if (!(name is String)) Fiber.abort("state(%(_name)).parallel: name must be String, got %(name.type)")
    if (!(fn is Fn))       Fiber.abort("state(%(_name)).parallel(%(name)): expected Fn, got %(fn.type)")
    if (_kind == "final") {
      Fiber.abort("state(%(_name)).parallel(%(name)): final state cannot contain substates")
    }
    if (_kind == null) _kind = "compound"
    if (_kind != "compound") {
      Fiber.abort("state(%(_name)).parallel(%(name)): cannot mix substates into a '%(_kind)' state")
    }
    if (_states.containsKey(name)) {
      Fiber.abort("state(%(_name)).parallel(%(name)): substate already defined")
    }
    var sub = StateBuilder_.new_(name)
    fn.call(sub)
    if (sub.statesAccessor_.count < 2) {
      Fiber.abort("state(%(_name)).parallel(%(name)): parallel state needs ≥2 regions, got %(sub.statesAccessor_.count)")
    }
    sub.markParallel_()
    _states[name] = sub
  }

  /// Internal: flip kind to "parallel" after substates are
  /// declared. Called by ChartBuilder_.parallel / StateBuilder_.parallel.
  markParallel_() {
    _kind = "parallel"
  }

  // Internal accessors used by ChartBuilder_.compileState_.
  // Trailing underscore marks them as internal-only.
  kindAccessor_     { _kind }
  initialAccessor_  { _initial }
  entryAccessor_    { _entry }
  exitAccessor_     { _exit }
  transitionsAccessor_ { _transitions }
  statesAccessor_   { _states }
}

/// Top-level chart builder. Created by `StateChart.build`.
class ChartBuilder_ {
  construct new_() {
    _id = null
    _initial = null
    _context = {}
    _states = {}              // Map<name, StateBuilder_> — Wren Maps preserve insertion order
  }

  id(name) {
    if (!(name is String)) Fiber.abort("chart.id: expected String, got %(name.type)")
    _id = name
  }

  context(map) {
    if (!(map is Map)) Fiber.abort("chart.context: expected Map, got %(map.type)")
    // Shallow copy so the user's literal isn't aliased into the chart.
    var copy = {}
    for (entry in map) copy[entry.key] = entry.value
    _context = copy
  }

  initial(stateName) {
    if (!(stateName is String)) {
      Fiber.abort("chart.initial: expected String, got %(stateName.type)")
    }
    _initial = stateName
  }

  state(name, fn) {
    if (!(name is String)) Fiber.abort("chart.state: name must be String, got %(name.type)")
    if (!(fn is Fn))       Fiber.abort("chart.state(%(name)): expected Fn, got %(fn.type)")
    if (_states.containsKey(name)) {
      Fiber.abort("chart.state(%(name)): state already defined")
    }
    var sub = StateBuilder_.new_(name)
    fn.call(sub)
    _states[name] = sub
  }

  /// Declare a top-level parallel state. See StateBuilder_.parallel
  /// for semantics — same shape, scoped at the chart root.
  parallel(name, fn) {
    if (!(name is String)) Fiber.abort("chart.parallel: name must be String, got %(name.type)")
    if (!(fn is Fn))       Fiber.abort("chart.parallel(%(name)): expected Fn, got %(fn.type)")
    if (_states.containsKey(name)) {
      Fiber.abort("chart.parallel(%(name)): state already defined")
    }
    var sub = StateBuilder_.new_(name)
    fn.call(sub)
    if (sub.statesAccessor_.count < 2) {
      Fiber.abort("chart.parallel(%(name)): parallel state needs ≥2 regions, got %(sub.statesAccessor_.count)")
    }
    sub.markParallel_()
    _states[name] = sub
  }

  /// Walk the builder tree, compile to `StateNode_`s, resolve every
  /// transition target, and return a runnable `StateChart`.
  finish() {
    if (_states.count == 0) Fiber.abort("chart: at least one state must be declared")

    // Pick the initial top-level state — explicit if set, else first declared.
    // Wren Maps preserve insertion order, so .keys.toList[0] is the first declared.
    var rootInitial = _initial
    if (rootInitial == null) {
      for (key in _states.keys) {
        rootInitial = key
        break
      }
    }
    if (!_states.containsKey(rootInitial)) {
      Fiber.abort("chart.initial = '%(rootInitial)' is not a declared state")
    }

    // Compile every top-level state's subtree.
    var rootStates = {}
    for (entry in _states) {
      rootStates[entry.key] = ChartBuilder_.compileState_(entry.value, null)
    }

    // Collect ids + enforce per-node invariants.
    var ids = {}
    for (entry in rootStates) {
      ChartBuilder_.validateAndCollect_(entry.value, ids)
    }

    // Resolve every transition target against the id table.
    for (entry in ids) {
      ChartBuilder_.resolveTargets_(entry.value, ids)
    }

    return StateChart.fromCompiled_(_id, rootStates, rootInitial, ids, _context)
  }

  // --- internal compile / validate / resolve passes ------------------------

  static compileState_(sb, parentNode) {
    var children = {}
    var node = StateNode_.new_(
      sb.name,
      parentNode,
      sb.kindAccessor_ == null ? "atomic" : sb.kindAccessor_,
      sb.initialAccessor_,
      sb.entryAccessor_,
      sb.exitAccessor_,
      sb.transitionsAccessor_,
      children
    )
    for (entry in sb.statesAccessor_) {
      children[entry.key] = ChartBuilder_.compileState_(entry.value, node)
    }
    return node
  }

  static validateAndCollect_(node, ids) {
    ids[node.path] = node
    if (node.kind == "compound") {
      if (node.initial == null) {
        Fiber.abort("StateChart: compound state '%(node.path)' has substates but no initial")
      }
      if (!node.states.containsKey(node.initial)) {
        Fiber.abort("StateChart: '%(node.path).initial' = '%(node.initial)' is not one of its substates")
      }
    }
    for (entry in node.states) {
      ChartBuilder_.validateAndCollect_(entry.value, ids)
    }
  }

  static resolveTargets_(node, ids) {
    for (entry in node.transitions) {
      for (branch in entry.value) {
        if (branch.target == null) continue
        var resolved = ChartBuilder_.resolveTarget_(branch.target, node, ids)
        if (resolved == null) {
          Fiber.abort("StateChart: '%(node.path).on.%(branch.event)' targets unknown state '%(branch.target)'")
        }
        branch.resolveTo_(resolved)
      }
    }
  }

  static resolveTarget_(target, sourceNode, ids) {
    // History pseudo-targets: validate the compound prefix and
    // keep the resolved string. The runtime walks the cache at
    // step time via `resolveHistoryTarget_`. We support both
    // fully-qualified prefixes ("game.playing.$history") and
    // sibling-relative ones ("playing.$history" from a sibling
    // of `playing`); the latter follows the same ancestor walk
    // as a plain target.
    if (target.endsWith(".$history") || target.endsWith(".$historyDeep")) {
      var suffix = target.endsWith(".$historyDeep") ? ".$historyDeep" : ".$history"
      var compoundRaw = target[0...(target.count - suffix.count)]
      var resolvedCompound = null
      if (compoundRaw.contains(".")) {
        if (ids.containsKey(compoundRaw)) resolvedCompound = compoundRaw
      } else {
        // Bare name: walk source's ancestors for a sibling with
        // this name (same as the regular sibling-relative rule).
        var ancestor = sourceNode.parent
        while (ancestor != null) {
          if (ancestor.states.containsKey(compoundRaw)) {
            resolvedCompound = ancestor.states[compoundRaw].path
            break
          }
          ancestor = ancestor.parent
        }
        // Fall back to a top-level node by that name.
        if (resolvedCompound == null) {
          for (entry in ids) {
            var n = entry.value
            if (n.parent == null && n.name == compoundRaw) {
              resolvedCompound = n.path
              break
            }
          }
        }
      }
      if (resolvedCompound == null) return null
      if (ids[resolvedCompound].kind != "compound") return null
      return resolvedCompound + suffix
    }
    // Fully-qualified path: must be a known id.
    if (target.contains(".")) {
      return ids.containsKey(target) ? target : null
    }
    // Sibling-relative: walk up source's ancestors, looking for
    // a sibling with this name.
    var ancestor = sourceNode.parent
    while (ancestor != null) {
      if (ancestor.states.containsKey(target)) {
        return ancestor.states[target].path
      }
      ancestor = ancestor.parent
    }
    // Root-level: any top-level node with this name.
    for (entry in ids) {
      var n = entry.value
      if (n.parent == null && n.name == target) return n.path
    }
    return null
  }
}

// --- StateChart (public runtime) ----------------------------------------------

class StateChart {
  /// Build a chart from a closure. The closure receives a chart
  /// builder; configure the chart by calling its methods. Returns
  /// a compiled `StateChart` ready to `start()` / `send(...)`.
  static build(builderFn) {
    if (!(builderFn is Fn)) {
      Fiber.abort("StateChart.build: expected Fn, got %(builderFn.type)")
    }
    var b = ChartBuilder_.new_()
    builderFn.call(b)
    return b.finish()
  }

  /// Build a chart from a data spec (Map). Same shape XState
  /// uses. Drives the same builder internally so all validation,
  /// error messages, and behavior are identical to `build`. Use
  /// this when the chart definition arrives as data — hot-
  /// reloadable JSON, save-loaded snapshots, asset-driven AI
  /// configs.
  ///
  /// Spec keys:
  ///   id        String — chart name (optional)
  ///   initial   String — top-level initial state (optional;
  ///                       defaults to first declared)
  ///   context   Map    — initial context
  ///   states    Map<name, stateSpec>
  ///
  /// stateSpec keys:
  ///   type      "atomic" | "compound" | "parallel" | "final"
  ///             (default: "atomic", or "compound" when `states`
  ///              present, or "parallel" if explicitly set)
  ///   initial   String — for compound states
  ///   states    Map<name, stateSpec>
  ///   entry     Fn | List<Fn>
  ///   exit      Fn | List<Fn>
  ///   on        Map<event, transitionSpec>
  ///
  /// transitionSpec:
  ///   String              — shorthand: target name
  ///   Map { target, guard, actions, internal }
  ///   List<transitionSpec> — multiple branches, evaluated in
  ///                          order (first matching guard wins)
  static fromMap(spec) {
    if (!(spec is Map)) {
      Fiber.abort("StateChart.fromMap: expected Map, got %(spec.type)")
    }
    return StateChart.build {|chart|
      if (spec.containsKey("id"))      chart.id(spec["id"])
      if (spec.containsKey("initial")) chart.initial(spec["initial"])
      if (spec.containsKey("context")) chart.context(spec["context"])
      if (spec.containsKey("states")) {
        for (entry in spec["states"]) {
          StateChart.buildStateFromMap_(chart, entry.key, entry.value)
        }
      }
    }
  }

  static buildStateFromMap_(parentBuilder, name, spec) {
    if (!(spec is Map)) {
      Fiber.abort("StateChart.fromMap: spec for state '%(name)' must be a Map, got %(spec.type)")
    }
    var type = spec.containsKey("type") ? spec["type"] : null

    if (type == "parallel") {
      parentBuilder.parallel(name) {|p|
        if (spec.containsKey("states")) {
          for (entry in spec["states"]) {
            StateChart.buildStateFromMap_(p, entry.key, entry.value)
          }
        }
        StateChart.applyStateConfig_(p, spec)
      }
    } else {
      parentBuilder.state(name) {|s|
        if (type == "final") s.final()
        if (spec.containsKey("initial")) s.initial(spec["initial"])
        if (spec.containsKey("states")) {
          for (entry in spec["states"]) {
            StateChart.buildStateFromMap_(s, entry.key, entry.value)
          }
        }
        StateChart.applyStateConfig_(s, spec)
      }
    }
  }

  static applyStateConfig_(builder, spec) {
    if (spec.containsKey("entry")) {
      var e = spec["entry"]
      if (e is Fn) {
        builder.entry(e)
      } else if (e is List) {
        for (f in e) builder.entry(f)
      } else {
        Fiber.abort("StateChart.fromMap: 'entry' must be Fn or List<Fn>")
      }
    }
    if (spec.containsKey("exit")) {
      var e = spec["exit"]
      if (e is Fn) {
        builder.exit(e)
      } else if (e is List) {
        for (f in e) builder.exit(f)
      } else {
        Fiber.abort("StateChart.fromMap: 'exit' must be Fn or List<Fn>")
      }
    }
    if (spec.containsKey("on")) {
      var onMap = spec["on"]
      if (!(onMap is Map)) Fiber.abort("StateChart.fromMap: 'on' must be a Map")
      for (transEntry in onMap) {
        StateChart.applyTransitionFromMap_(builder, transEntry.key, transEntry.value)
      }
    }
  }

  static applyTransitionFromMap_(builder, event, def) {
    if (def is String) {
      builder.on(event, def)
      return
    }
    if (def is Map) {
      builder.on(event) {|t|
        if (def.containsKey("target")) t.go(def["target"])
        if (def.containsKey("guard"))  t.when(def["guard"])
        if (def.containsKey("actions")) {
          var a = def["actions"]
          if (a is Fn) {
            t.does(a)
          } else if (a is List) {
            for (f in a) t.does(f)
          } else {
            Fiber.abort("StateChart.fromMap: 'actions' must be Fn or List<Fn>")
          }
        }
        if (def.containsKey("internal") && def["internal"] == true) {
          t.internal()
        }
      }
      return
    }
    if (def is List) {
      for (branch in def) {
        StateChart.applyTransitionFromMap_(builder, event, branch)
      }
      return
    }
    Fiber.abort("StateChart.fromMap: transition for event '%(event)' must be String, Map, or List")
  }

  // Internal constructor used by `ChartBuilder_.finish`.
  construct fromCompiled_(id, rootStates, rootInitial, ids, context) {
    _id = id
    _rootStates = rootStates    // Map<name, StateNode_> — top-level
    _rootInitial = rootInitial  // String — which top-level state to enter
    _ids = ids                  // Map<path, StateNode_>
    _context = context          // Map (mutable through actions)
    _active = []                // List<String> — shallowest-first paths
    _started = false
    _processing = false
    _pending = null
    _emitter = EventEmitter.new()   // observers attach via on/once/off
    _bindings = []              // List of [emitter, eventName, disconnectFn]
    // Per-compound-state history caches. Shallow records the
    // immediate-substate-last-active; deep records the leaf-last-
    // active. Populated on exit by `recordHistory_`; consumed by
    // target resolution for `$history` / `$historyDeep`.
    _historyShallow = {}        // Map<compoundPath, substateName>
    _historyDeep = {}           // Map<compoundPath, leafPath>
  }

  id { _id }
  context { _context }
  activeStates { _active }
  started { _started }

  // --- @hatch:events delegation ------------------------------------------
  //
  // `StateChart` composes an EventEmitter so subscribers can use the
  // standard on/once/off vocabulary. Channels the chart publishes:
  //
  //   transition         (fromPath, toPath, event)
  //   enter:<full.path>  (context,  event)
  //   exit:<full.path>   (context,  event)
  //   unhandled          (event)
  //   *                  (channelName, ...same args as the specific channel)
  //
  // Wildcard `*` fires after every specific-channel emit so a single
  // listener can observe everything the chart does — useful for FSM
  // inspector overlays and replay capture.

  /// Subscribe to a channel. Returns a disconnect Fn from `@hatch:events`.
  on(event, fn)    { _emitter.on(event, fn) }
  once(event, fn)  { _emitter.once(event, fn) }
  off(event, fn)   { _emitter.off(event, fn) }
  offAll(event)    { _emitter.offAll(event) }
  offAll           { _emitter.offAll }
  listenerCount(event) { _emitter.listenerCount(event) }
  eventNames       { _emitter.eventNames }

  /// Forward selected events from `emitter` into this chart's
  /// `send`. `eventNames` is a List of strings. The chart
  /// subscribes a zero-arity listener for each name on the
  /// source emitter; when fired, the event name is sent into
  /// the chart as if `send(name)` had been called.
  ///
  /// Forwards only the event NAME, not any payload args from the
  /// emit call. `@hatch:events` dispatches listeners by exact
  /// arity (`emit("x")` calls 0-arity Fns; `emit("x", a)` calls
  /// 1-arity Fns; etc.), and there's no single Fn shape that
  /// matches every arity. Payload-carrying transitions land when
  /// the chart grows a `bindMapped` helper for non-bare events.
  ///
  /// Returns a single Fn that, when called, unsubscribes every
  /// binding installed by this call.
  bindEvents(emitter, eventNames) {
    if (!(eventNames is List)) {
      Fiber.abort("StateChart.bindEvents: eventNames must be a List<String>, got %(eventNames.type)")
    }
    var self = this
    var disconnects = []
    for (name in eventNames) {
      if (!(name is String)) {
        Fiber.abort("StateChart.bindEvents: event names must be Strings, got %(name.type)")
      }
      // Capture `name` in a local so the closure picks up the
      // right value each iteration (Wren closures over loop
      // variables otherwise see the last-iteration value).
      var captured = name
      var disc = emitter.on(captured, Fn.new { self.send(captured) })
      disconnects.add(disc)
      _bindings.add([emitter, captured, disc])
    }
    return Fn.new {
      for (d in disconnects) d.call()
    }
  }

  /// Shorthand: bind a single event name.
  bindEvent(emitter, eventName) { bindEvents(emitter, [eventName]) }

  // --- Pretty printer ----------------------------------------------------

  /// A human-readable rendering of the chart's structure. Shows the
  /// state hierarchy with ASCII box-drawing characters, each state's
  /// kind (atomic implied, compound / parallel / final shown), the
  /// initial substate of each compound, every declared transition,
  /// and which states are currently active.
  ///
  /// ```
  ///   player
  ///   |-- ground (initial: idle) [active]
  ///   |   |   on jump -> air
  ///   |   |-- idle [active]
  ///   |   |       on walk -> ground.walking
  ///   |   |-- walking
  ///   |   |       on stop -> ground.idle
  ///   |   `-- running
  ///   |           on stop -> ground.walking
  ///   |-- air
  ///   |       on land -> ground
  ///   `-- dead (final)
  /// ```
  tree {
    var sb = _id == null ? "<chart>\n" : "%(_id)\n"
    var keys = []
    for (entry in _rootStates) keys.add(entry.key)
    var i = 0
    while (i < keys.count) {
      var isLast = i == keys.count - 1
      sb = sb + treeNode_(_rootStates[keys[i]], "", isLast)
      i = i + 1
    }
    return sb
  }

  /// `System.print(fsm)` and `"%(fsm)"` both render the tree.
  toString { tree }

  treeNode_(node, prefix, isLast) {
    // Connector for this line; continuation prefix for our descendants.
    var connector = isLast ? "`-- " : "|-- "
    var childPrefix = prefix + (isLast ? "    " : "|   ")

    // Annotations on the state line: kind ("atomic" implied; compound's
    // initial-substate is more useful than the bare "compound" label;
    // active marker if any active path equals this node).
    var kindTag = node.kind == "atomic" ? "" : " (%(node.kind))"
    if (node.kind == "compound" && node.initial != null) {
      kindTag = " (initial: %(node.initial))"
    }
    var activeTag = ""
    for (path in _active) {
      if (path == node.path) {
        activeTag = " [active]"
        break
      }
    }
    var sb = "%(prefix)%(connector)%(node.name)%(kindTag)%(activeTag)\n"

    // Transitions: rendered as indented attribute lines under the
    // state, distinct from tree branches so a reader can tell them
    // apart from substates at a glance.
    for (entry in node.transitions) {
      var event = entry.key
      for (branch in entry.value) {
        var arrow = branch.target == null ? "(self)" : branch.target
        sb = sb + "%(childPrefix)    on %(event) -> %(arrow)\n"
      }
    }

    // Recurse into substates in declaration order (Map iteration).
    var keys = []
    for (entry in node.states) keys.add(entry.key)
    var i = 0
    while (i < keys.count) {
      var subIsLast = i == keys.count - 1
      sb = sb + treeNode_(node.states[keys[i]], childPrefix, subIsLast)
      i = i + 1
    }
    return sb
  }

  /// True if any active state's path equals `pattern` or is one
  /// of its descendants. So `matches("ground")` is true while
  /// active is `ground.walking`.
  matches(pattern) {
    if (!(pattern is String)) {
      Fiber.abort("StateChart.matches: expected String, got %(pattern.type)")
    }
    for (path in _active) {
      if (path == pattern) return true
      if (path.startsWith(pattern + ".")) return true
    }
    return false
  }

  /// The deepest currently-active leaf (full path). For non-
  /// parallel charts this is the unique active leaf.
  activePath {
    if (_active.count == 0) return null
    return _active[_active.count - 1]
  }

  /// Enter the chart: walk from the root initial down to its
  /// deepest descendant. Idempotent.
  start() {
    if (_started) return
    _started = true
    enterPath_(_rootStates[_rootInitial], null)
  }

  /// Exit every active state, deepest first. Idempotent.
  stop() {
    if (!_started) return
    var i = _active.count - 1
    while (i >= 0) {
      var node = _ids[_active[i]]
      runActions_(node.exit, null)
      i = i - 1
    }
    _active.clear()
    _started = false
  }

  /// Process an event. Fires at most one transition per active
  /// leaf. Events that arrive while a step is mid-flight (an
  /// action calls `send`) queue and drain after the current step.
  send(event) {
    if (!_started) Fiber.abort("StateChart.send: chart not started — call start() first")
    if (_processing) {
      if (_pending == null) _pending = []
      _pending.add(event)
      return
    }
    _processing = true
    step_(event)
    while (_pending != null && _pending.count > 0) {
      var next = _pending.removeAt(0)
      step_(next)
    }
    _processing = false
    _pending = null
  }

  // --- internal step engine ----

  step_(event) {
    // Process each active leaf independently. A parallel chart has
    // multiple leaves; each region may fire its own transition.
    // Transitions are applied in leaf order; after each, the active
    // config is refreshed before the next leaf is checked.
    var leaves = activeLeaves_
    var fired = false
    var self = this
    // Guard evaluator passed to findTransition_. Captures `event`
    // and `self`'s _context so guard fns receive the right args.
    var guardEval = Fn.new {|branch|
      if (branch.guard == null) return true
      var result = branch.guard.call(self.context, event)
      if (!(result is Bool)) {
        Fiber.abort("StateChart: guard for transition on '%(branch.event)' returned %(result.type), expected Bool")
      }
      return result
    }
    for (leafPath in leaves) {
      // Refresh — earlier transitions in this step may have exited
      // this leaf already.
      if (!_active.contains(leafPath)) continue
      var leaf = _ids[leafPath]
      var hit = leaf.findTransition_(event, guardEval)
      if (hit == null) continue
      fired = true
      stepOne_(hit[0], hit[1], event)
    }
    if (!fired) fire_("unhandled", [event])
  }

  stepOne_(branch, source, event) {
    var target = resolveTargetForStep_(branch.target)

    // Self / internal: no exit/entry, just run actions + emit.
    if (target == null || (branch.internal && target == source)) {
      runActions_(branch.actions, event)
      fire_("transition", [source.path, source.path, event])
      return
    }

    var lca = lca_(source, target)

    // Exit set: every currently-active state that's a strict
    // descendant of LCA. For non-parallel charts this is the
    // single active branch; for parallel charts this naturally
    // includes leaves from sibling regions too.
    var exitSet = activeDescendantsOf_(lca)
    // Record history for any compound parent being exited, then
    // run inline exit (deepest first), then emit signals.
    for (node in exitSet) recordHistory_(node)
    for (node in exitSet) runActions_(node.exit, event)
    for (node in exitSet) fire_("exit:%(node.path)", [_context, event])
    for (node in exitSet) removeActive_(node.path)

    // Inline transition action, then the transition signal.
    runActions_(branch.actions, event)
    fire_("transition", [source.path, target.path, event])

    // Entry set: from LCA (exclusive) down to target. Inline entry
    // first (shallowest first), then enter:<path> signal per state,
    // then descend via initial / parallel regions.
    var entrySet = pathFromLcaToTarget_(lca, target)
    for (node in entrySet) {
      _active.add(node.path)
      runActions_(node.entry, event)
      fire_("enter:%(node.path)", [_context, event])
    }
    descendIntoInitial_(target, event)

    // After entering: if any of the now-active leaves is a final
    // state, emit `done` for its parent. For parallel parents,
    // emit `done` only when ALL regions have hit final.
    emitDoneIfApplicable_(target, event)
  }

  enterPath_(node, event) {
    _active.add(node.path)
    runActions_(node.entry, event)
    fire_("enter:%(node.path)", [_context, event])
    descendIntoInitial_(node, event)
  }

  /// Compound → enter the initial substate (or recorded history).
  /// Parallel → enter every region simultaneously.
  /// Atomic / final → no further descent.
  descendIntoInitial_(node, event) {
    if (node.kind == "compound") {
      var childName = node.initial
      var child = node.states[childName]
      enterPath_(child, event)
    } else if (node.kind == "parallel") {
      // Enter every region; each region descends into its own
      // initial. Iteration order = declaration order (Wren Maps).
      for (entry in node.states) {
        enterPath_(entry.value, event)
      }
    }
  }

  /// All currently-active state paths whose `path` is a strict
  /// descendant of `ancestor`. Returns StateNode_s sorted
  /// deepest-first so exit actions/signals fire in the right order.
  activeDescendantsOf_(ancestor) {
    var paths = []
    if (ancestor == null) {
      // No common ancestor — exit everything currently active.
      for (p in _active) paths.add(p)
    } else {
      var prefix = ancestor.path + "."
      for (p in _active) {
        if (p.startsWith(prefix)) paths.add(p)
      }
    }
    // Sort by depth descending: count '.' in each path.
    // Wren's List.sort isn't stable across versions; use a manual
    // insertion sort, O(n²) but fine for typical small active sets.
    var depths = []
    for (p in paths) depths.add(p.split(".").count)
    var i = 1
    while (i < paths.count) {
      var j = i
      while (j > 0 && depths[j] > depths[j - 1]) {
        var tp = paths[j]
        paths[j] = paths[j - 1]
        paths[j - 1] = tp
        var td = depths[j]
        depths[j] = depths[j - 1]
        depths[j - 1] = td
        j = j - 1
      }
      i = i + 1
    }
    var nodes = []
    for (p in paths) nodes.add(_ids[p])
    return nodes
  }

  /// All "leaf" active states — those with no active descendant.
  /// For non-parallel charts this is exactly one path; for
  /// parallel, it's one per region.
  activeLeaves_ {
    var leaves = []
    for (p in _active) {
      var hasChild = false
      var prefix = p + "."
      for (other in _active) {
        if (other != p && other.startsWith(prefix)) {
          hasChild = true
          break
        }
      }
      if (!hasChild) leaves.add(p)
    }
    return leaves
  }

  /// Resolve a transition's `target` field to a runtime node.
  /// Most targets were resolved to fully-qualified paths at
  /// finish-time, so this is just a Map lookup. `$history` /
  /// `$historyDeep` targets were left as-is by the resolver and
  /// translate to a real state here, falling back to the
  /// compound's initial if no history is yet recorded.
  resolveTargetForStep_(targetStr) {
    if (targetStr == null) return null
    if (targetStr.endsWith(".$history") || targetStr.endsWith(".$historyDeep")) {
      return resolveHistoryTarget_(targetStr)
    }
    return _ids[targetStr]
  }

  /// Called for each node being exited (deepest-first). Records
  /// the exited path into history caches for each compound
  /// ancestor — shallow remembers the immediate substate,
  /// deep remembers the leaf. Future `$history` / `$historyDeep`
  /// transitions targeting that compound resolve to these values.
  recordHistory_(node) {
    // Shallow: if this node's parent is a compound, the parent now
    // forgets its previous active substate and records THIS one.
    if (node.parent != null && node.parent.kind == "compound") {
      _historyShallow[node.parent.path] = node.path
    }
    // Deep: walk every compound ancestor and record the leaf path
    // (this node, which is the deepest exiter we see thanks to
    // deepest-first sort in `activeDescendantsOf_`).
    var ancestor = node.parent
    while (ancestor != null) {
      if (ancestor.kind == "compound") {
        _historyDeep[ancestor.path] = node.path
      }
      ancestor = ancestor.parent
    }
  }

  /// Resolve a `<path>.$history` or `<path>.$historyDeep` target
  /// to a real StateNode_. If history was recorded, use it; else
  /// fall back to the compound's initial substate.
  resolveHistoryTarget_(targetStr) {
    var deep = targetStr.endsWith(".$historyDeep")
    var suffixLen = deep ? ".$historyDeep".count : ".$history".count
    var compoundPath = targetStr[0...(targetStr.count - suffixLen)]
    var compound = _ids[compoundPath]

    var cache = deep ? _historyDeep : _historyShallow
    if (cache.containsKey(compoundPath)) {
      var recorded = cache[compoundPath]
      if (_ids.containsKey(recorded)) return _ids[recorded]
    }
    // No history yet: fall back to the compound's initial substate.
    if (compound.initial != null && compound.states.containsKey(compound.initial)) {
      return compound.states[compound.initial]
    }
    return compound
  }

  /// After a transition enters `target` (and descends), emit
  /// `done` for any final state that was just entered. Walks up
  /// from each entered final's compound parent looking for
  /// parallel ancestors — fires `done` for them too when every
  /// region has reached a final. Dedups within a step so a
  /// single final isn't reported twice across nested levels.
  emitDoneIfApplicable_(target, event) {
    if (target == null) return
    var emittedThisStep = {}
    // States entered as part of this transition = target +
    // anything in the active set under target's path.
    var prefix = target.path + "."
    var entered = [target.path]
    for (p in _active) {
      if (p.startsWith(prefix)) entered.add(p)
    }

    for (path in entered) {
      var node = _ids[path]
      if (node == null || node.kind != "final") continue
      var parent = node.parent
      if (parent == null) continue
      if (!emittedThisStep.containsKey(parent.path)) {
        fire_("done", [parent.path])
        emittedThisStep[parent.path] = true
      }
      // Walk up: every parallel ancestor whose regions are all
      // at final emits done too.
      var ancestor = parent.parent
      while (ancestor != null) {
        if (ancestor.kind == "parallel" && !emittedThisStep.containsKey(ancestor.path)) {
          if (allRegionsFinal_(ancestor)) {
            fire_("done", [ancestor.path])
            emittedThisStep[ancestor.path] = true
          }
        }
        ancestor = ancestor.parent
      }
    }
  }

  /// True iff every region of `parallelNode` has its deepest
  /// active leaf in a `final` state. Used for parallel-done
  /// emission.
  allRegionsFinal_(parallelNode) {
    var leaves = activeLeaves_
    for (entry in parallelNode.states) {
      var regionRoot = entry.value
      var found = false
      for (lp in leaves) {
        if (lp == regionRoot.path || lp.startsWith(regionRoot.path + ".")) {
          found = true
          if (_ids[lp].kind != "final") return false
          break
        }
      }
      if (!found) return false
    }
    return true
  }

  /// Emit on a specific channel and also on the wildcard `*`
  /// channel so a single observer can introspect every signal
  /// the chart raises. `*` receives `(channelName, ...originalArgs)`,
  /// arity-capped at 3 to match `@hatch:events` emit overloads —
  /// wildcard listeners that need more should subscribe to the
  /// specific channel directly.
  fire_(channel, args) {
    _emitter.emitMany(channel, args)
    var wildArgs = [channel]
    for (a in args) wildArgs.add(a)
    if (wildArgs.count > 3) {
      wildArgs = [wildArgs[0], wildArgs[1], wildArgs[2]]
    }
    _emitter.emitMany("*", wildArgs)
  }

  runActions_(actions, event) {
    if (actions == null) return
    for (fn in actions) {
      // Actions throw straight through to the caller's send().
      // No per-action fiber.try wrapping; if richer error context
      // turns out to matter, add it then.
      fn.call(_context, event)
    }
  }

  /// Lowest common ancestor of two nodes for transition-scope
  /// computation. SCXML semantics: an external transition's
  /// scope is the lowest PROPER ancestor — even when source ==
  /// target (self-transition) or source ancestors target, the
  /// scope must be strictly above the source so the source
  /// itself gets exited and re-entered. The internal-transition
  /// path in stepOne_ short-circuits before calling this, so
  /// we don't need to handle internal here.
  lca_(a, b) {
    if (a == b) return a.parent
    var aAncestors = {}
    var x = a.parent
    while (x != null) {
      aAncestors[x.path] = x
      x = x.parent
    }
    var y = b.parent
    while (y != null) {
      if (aAncestors.containsKey(y.path)) return y
      y = y.parent
    }
    return null
  }

  pathFromLcaToTarget_(lca, target) {
    // Collect target → child-of-lca, then reverse to shallowest-first.
    var rev = []
    var n = target
    while (n != null && n != lca) {
      rev.add(n)
      n = n.parent
    }
    var out = []
    var i = rev.count - 1
    while (i >= 0) {
      out.add(rev[i])
      i = i - 1
    }
    return out
  }

  removeActive_(path) {
    var i = 0
    while (i < _active.count) {
      if (_active[i] == path) {
        _active.removeAt(i)
        return
      }
      i = i + 1
    }
  }
}
