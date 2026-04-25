// @hatch:web/live — Phase 4 primitives: fiber-cooperative scheduler,
// in-memory Channel pub/sub, and Server-Sent Events streaming.
//
// All of this is cooperative — a handler blocks the server until it
// either returns, yields (via the scheduler's `Fiber.yield()` hook),
// or finishes. @hatch:socket's `tryAccept` / `tryRead` do the
// would-block signalling; the scheduler reads that and swaps fibers.
//
// The usage story:
//
//   // Register a channel on the app (cheap; named string).
//   var chat = app.channel("chat")
//
//   // Post a message — broadcasts to every subscriber.
//   app.post("/chat") {|req|
//     chat.broadcast("<div>" + req.form["msg"] + "</div>")
//     return ""  // htmx POSTs care only about status
//   }
//
//   // Stream live updates via SSE + hx-swap-oob.
//   app.get("/chat/stream") {|req|
//     var sub = chat.subscribe
//     return Sse.stream(Fn.new {|emit|
//       while (true) {
//         var msg = sub.receive   // yields until a broadcast arrives
//         emit.call(msg)
//       }
//     })
//   }
//
// htmx picks the SSE events up via `sse-connect` / `sse-swap`
// attributes on the containing element. Nothing else is required.

import "@hatch:time" for Clock

// ── Scheduler ──────────────────────────────────────────────────────────
//
// Round-robin fiber driver. The main App.listen loop creates one and
// each accepted connection spawns a serve fiber on it. `tick` runs
// every non-done fiber one step, which either runs to completion or
// hits a `Fiber.yield()` (typically inside a would-block tryRead, or
// a Channel.receive waiting for a broadcast).
//
// When the scheduler is idle (no fibers), the accept loop uses
// `Clock.sleepMs(10)` to avoid busy-looping.

class Scheduler_ {
  construct new() {
    _fibers = []
  }

  // Returns the Fiber so the caller can inspect .error after run
  // if needed. Don't call .try() on it yourself — the scheduler owns
  // the run.
  spawn(fn) {
    var f = Fiber.new(fn)
    _fibers.add(f)
    return f
  }

  count    { _fibers.count }
  isEmpty  { _fibers.count == 0 }

  // Drive every active fiber one tick. Fibers that complete or
  // abort are dropped. Swallows errors with an eprint-equivalent so
  // one broken handler doesn't kill the server.
  tick {
    var i = 0
    while (i < _fibers.count) {
      var f = _fibers[i]
      if (f.isDone) {
        // Shouldn't normally happen — we remove done fibers when
        // they finish in this tick — but defensive.
        Scheduler_.removeAt_(_fibers, i)
      } else {
        f.try()
        if (f.isDone) {
          if (f.error != null) {
            System.print("scheduler: fiber aborted: %(f.error)")
          }
          Scheduler_.removeAt_(_fibers, i)
        } else {
          i = i + 1
        }
      }
    }
  }

  static removeAt_(list, idx) {
    var out = []
    var i = 0
    while (i < list.count) {
      if (i != idx) out.add(list[i])
      i = i + 1
    }
    // Mutate in place — Wren's List has no direct removeAt, and the
    // swap-and-pop trick would break fiber order under nested ticks.
    // Small lists (tens of connections), small cost.
    var j = 0
    while (j < out.count) {
      list[j] = out[j]
      j = j + 1
    }
    // Pop the last slot.
    list.removeAt(list.count - 1)
  }
}

// ── Channel ────────────────────────────────────────────────────────────
//
// Named in-memory pub/sub. `broadcast(msg)` deposits the message in
// every active subscriber's pending queue; `subscribe` returns a
// Subscription whose `receive` fiber-yields until a message arrives.
//
// No persistence, no backpressure, no cleanup-on-disconnect beyond
// `Subscription.close`. Intended for "one process, many clients"
// scenarios like chat rooms and live dashboards. Production scale
// wants a real broker — that's a different library.

class Subscription_ {
  construct new_(channel) {
    _channel = channel
    _queue = []
    _closed = false
  }

  // Called by Channel.broadcast.
  deliver_(msg) {
    if (!_closed) _queue.add(msg)
  }

  // Cooperative receive: yield until a message is queued, then
  // return the head. Returns null when the subscription has been
  // closed.
  receive {
    while (!_closed) {
      if (_queue.count > 0) {
        var head = _queue[0]
        // Drop head the cheap way — shift via a new list.
        var rest = []
        var i = 1
        while (i < _queue.count) {
          rest.add(_queue[i])
          i = i + 1
        }
        _queue = rest
        return head
      }
      Fiber.yield()
    }
    return null
  }

  close {
    _closed = true
    _channel.unsubscribe_(this)
  }

  closed_ { _closed }
}

class Channel {
  construct new(name) {
    _name = name
    _subs = []
  }

  name { _name }
  subscriberCount { _subs.count }

  // Attach a new subscriber. Returns a Subscription the caller
  // drives via `receive`.
  subscribe {
    var sub = Subscription_.new_(this)
    _subs.add(sub)
    return sub
  }

  // Fan-out a message to every attached subscriber.
  //
  //   chat.broadcast("event:message\ndata:hello\n\n")
  //
  // Callers pass whatever text they want the subscriber to see —
  // Channel doesn't impose a format. Sse.stream's emit wraps
  // payloads in SSE syntax; plain subscribers get whatever you send.
  broadcast(msg) {
    for (sub in _subs) sub.deliver_(msg)
  }

  unsubscribe_(sub) {
    var rebuilt = []
    for (s in _subs) {
      if (s != sub) rebuilt.add(s)
    }
    _subs = rebuilt
  }
}

// ── SSE ────────────────────────────────────────────────────────────────
//
// `Sse.stream(writerFn)` returns a value the listen loop recognises:
// instead of serialising a Response once, it writes SSE headers and
// invokes `writerFn` with an `emit` helper. The writer typically
// loops forever, calling `emit.call(payload)` for each event it
// wants to push to the client.
//
// `emit` accepts:
//   - a String → sent as `data:` (one line)
//   - a Map with any of `event`, `data`, `id`, `retry` → full SSE frame
//
// Heartbeats: call `emit.call(":ping")` (comments are ignored by the
// client) to keep intermediate proxies from closing an idle connection.

class SseStream {
  construct new_(writerFn) {
    _writer = writerFn
  }

  writer { _writer }

  static stream(writerFn) {
    return SseStream.new_(writerFn)
  }
}

class Sse {
  // Sugar so `import "./live" for Sse` is enough to start streaming.
  static stream(writerFn) { SseStream.stream(writerFn) }

  // Format one SSE frame. Caller writes the result to the socket.
  // Accepts the same shapes as `emit` above.
  static frame(payload) {
    if (payload is String) {
      if (payload.count > 0 && payload[0] == ":") {
        // Comment / heartbeat — pass through as-is + blank line.
        return payload + "\n\n"
      }
      return "data: " + Sse.escapeLines_(payload) + "\n\n"
    }
    if (payload is Map) {
      var out = ""
      if (payload.containsKey("event")) out = out + "event: " + payload["event"] + "\n"
      if (payload.containsKey("id"))    out = out + "id: " + payload["id"].toString + "\n"
      if (payload.containsKey("retry")) out = out + "retry: " + payload["retry"].toString + "\n"
      if (payload.containsKey("data"))  out = out + "data: " + Sse.escapeLines_(payload["data"]) + "\n"
      return out + "\n"
    }
    return "data: " + payload.toString + "\n\n"
  }

  // SSE data lines are delimited by \n — embedded newlines need to
  // become multiple `data:` lines.
  static escapeLines_(s) {
    if (!(s is String)) return s.toString
    if (Sse.indexOf_(s, "\n") < 0) return s
    var out = ""
    var i = 0
    var start = 0
    while (i < s.count) {
      if (s[i] == "\n") {
        out = out + s[start..(i - 1)] + "\ndata: "
        start = i + 1
      }
      i = i + 1
    }
    out = out + s[start..(s.count - 1)]
    return out
  }

  static indexOf_(s, ch) {
    var i = 0
    while (i < s.count) {
      if (s[i] == ch) return i
      i = i + 1
    }
    return -1
  }
}
