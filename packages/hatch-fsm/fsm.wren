// `@hatch:fsm` — Harel statecharts for Wren.
//
// Closure-based builder for defining a chart; pure-Wren runtime
// for executing it. Validation collapses into the builder API —
// each method's arguments are type-checked at the call site, and
// structural rules (final has no substates, parallel needs ≥2
// regions, compound needs initial) are enforced as builder mode.
//
// Day-1 scope: atomic + compound states, sibling-relative and
// fully-qualified transition targets, start/stop/send/matches,
// context map. Parallel, history, final-with-done, guards,
// entry/exit actions, EventEmitter signals, fromMap come in
// later days (see `docs/hatch-fsm-design.md`).
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
// ```

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
  /// this node up through ancestors. Returns `[branch, sourceNode]`,
  /// or null if no handler matches.
  findTransition_(event) {
    var key = event is String ? event : event["type"]
    var node = this
    while (node != null) {
      var branches = node.transitions[key]
      if (branches != null && branches.count > 0) {
        // Day 1: no guards — first branch wins.
        // Day 4 will evaluate guards in order.
        return [branches[0], node]
      }
      node = node.parent
    }
    return null
  }
}

/// A single transition branch. Multiple branches per event become
/// guard-ordered alternatives (day 4).
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
  ///   s.on("event") {|t| ... }    — full form (day 4)
  on(event, target) {
    if (!(event is String)) {
      Fiber.abort("state(%(_name)).on: event must be String, got %(event.type)")
    }
    if (_kind == "final") {
      Fiber.abort("state(%(_name)).on(%(event)): final states cannot have outgoing transitions")
    }
    if (target is String) {
      if (!_transitions.containsKey(event)) _transitions[event] = []
      _transitions[event].add(TransitionBranch_.new_(event, target, null, [], false))
      return
    }
    if (target is Fn) {
      Fiber.abort("state(%(_name)).on(%(event)): full-form transitions (guards/actions) land in day 4 — pass a String target for now")
    }
    Fiber.abort("state(%(_name)).on(%(event)): 2nd arg must be String or Fn, got %(target.type)")
  }

  /// Mark this state as a terminal state.
  final() {
    if (_states.count > 0)      Fiber.abort("state(%(_name)).final: already has substates")
    if (_transitions.count > 0) Fiber.abort("state(%(_name)).final: already has outgoing transitions")
    _kind = "final"
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
  }

  id { _id }
  context { _context }
  activeStates { _active }
  started { _started }

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
  /// leaf in day 1 (only one leaf exists). Events that arrive
  /// while a step is mid-flight (an action calls `send`) queue
  /// and drain after the current step.
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
    var leaf = _ids[activePath]
    var hit = leaf.findTransition_(event)
    if (hit == null) return        // day 2: emit "unhandled" signal
    var branch = hit[0]
    var source = hit[1]
    var target = branch.target == null ? null : _ids[branch.target]

    // Self / internal: no exit/entry, just run actions.
    if (target == null || (branch.internal && target == source)) {
      runActions_(branch.actions, event)
      return
    }

    var lca = lca_(source, target)

    // Exit set: active leaf up to (but not including) lca.
    var exitSet = []
    var n = leaf
    while (n != null && n != lca) {
      exitSet.add(n)
      n = n.parent
    }
    for (node in exitSet) runActions_(node.exit, event)
    for (node in exitSet) removeActive_(node.path)

    // Transition action.
    runActions_(branch.actions, event)

    // Entry set: lca (exclusive) down to target.
    var entrySet = pathFromLcaToTarget_(lca, target)
    for (node in entrySet) {
      _active.add(node.path)
      runActions_(node.entry, event)
    }
    descendIntoInitial_(target, event)
  }

  enterPath_(node, event) {
    _active.add(node.path)
    runActions_(node.entry, event)
    descendIntoInitial_(node, event)
  }

  descendIntoInitial_(node, event) {
    if (node.kind != "compound") return
    var child = node.states[node.initial]
    enterPath_(child, event)
  }

  runActions_(actions, event) {
    if (actions == null) return
    for (fn in actions) {
      // Actions throw straight through to the caller's send().
      // Day-1 has no extra wrapping; day 4 can re-add per-action
      // fiber.try if richer error context turns out to matter.
      fn.call(_context, event)
    }
  }

  lca_(a, b) {
    var aAncestors = {}
    var x = a
    while (x != null) {
      aAncestors[x.path] = x
      x = x.parent
    }
    var y = b
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
