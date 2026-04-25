// @hatch:web chat demo — Phase 4 showcase.
//
//   wlift --mode interpreter --step-limit 0 chat.wren
//   Open two browser tabs at http://127.0.0.1:3000
//   Post a message in one; watch it appear in the other.
//
// `--step-limit 0` disables the interpreter step cap (default 1B
// caps out after ~10-30 minutes of polling-loop instructions on
// a long-running server).
//
// What this stitches together (and is the first demo that needs):
//   - Fiber-cooperative scheduler in App.listen (concurrent conns)
//   - Channel pub/sub for fan-out
//   - Sse.stream + htmx sse-ext for live DOM updates
//
// The HTML is minimal — one form, one #messages div, one SSE
// listener. No JS beyond htmx + htmx's SSE extension (both CDN
// in the page head).

import "../web" for App, Response, Css, Sse

var app = App.new()
var chat = app.channel("chat")

// ── Styling ───────────────────────────────────────────────────

var page    = Css.tw("font-sans max-w-md mx-auto my-10 p-6 bg-white rounded-lg shadow")
var heading = Css.tw("text-2xl font-bold text-gray-900 mb-4")
var msgList = Css.tw("h-64 overflow-auto bg-gray-50 rounded p-3 mb-3 text-sm")
var msgLine = Css.tw("py-1")
var form    = Css.tw("flex gap-2")
var input   = Css.tw("flex-1 px-3 py-2 border border-gray-300 rounded")
              .focus("border-blue-500")
var btn     = Css.tw("bg-blue-500 text-white px-4 py-2 rounded font-semibold")
              .hover("bg-blue-600")

// ── Routes ────────────────────────────────────────────────────

app.get("/") {|req|
  req.style(page)
  req.style(heading)
  req.style(msgList)
  req.style(form)
  req.style(input)
  req.style(btn)
  return "<!doctype html>" +
    "<html><head>" +
    "<title>@hatch:web chat</title>" +
    "<script src=\"https://unpkg.com/htmx.org@1.9.12\"></script>" +
    "<script src=\"https://unpkg.com/htmx.org@1.9.12/dist/ext/sse.js\"></script>" +
    req.fragmentSheet.styleTag +
    "</head><body>" +
    "<div class='" + page.className + "'>" +
    "<h1 class='" + heading.className + "'>chat</h1>" +
    "<div id='messages' class='" + msgList.className + "'" +
    " hx-ext='sse' sse-connect='/stream' sse-swap='message' hx-swap='beforeend'></div>" +
    "<form class='" + form.className + "' hx-post='/post' hx-swap='none' hx-on::after-request='this.reset()'>" +
    "<input class='" + input.className + "' name='msg' placeholder='say something...' autofocus>" +
    "<button class='" + btn.className + "' type='submit'>Send</button>" +
    "</form>" +
    "</div>" +
    "</body></html>"
}

app.post("/post") {|req|
  var msg = req.form.containsKey("msg") ? req.form["msg"] : ""
  if (msg != "") {
    // Emit an HTML fragment. htmx swaps it straight into #messages
    // via the SSE connection's `sse-swap="message"` handler.
    chat.broadcast("<div class='" + msgLine.className + "'>" + escape_.call(msg) + "</div>")
  }
  return Response.new(204)
}

app.get("/stream") {|req|
  var sub = chat.subscribe
  return Sse.stream(Fn.new {|emit|
    // Kick the stream so the browser registers `event: message`
    // and doesn't sit on an empty buffer.
    emit.call({"event": "message", "data": "<div class='" + msgLine.className + "'><em>connected</em></div>"})
    while (true) {
      var html = sub.receive
      if (html == null) return  // channel closed
      emit.call({"event": "message", "data": html})
    }
  })
}

var escape_ = Fn.new {|s|
  if (s == null) return ""
  if (!(s is String)) return s.toString
  var out = ""
  var i = 0
  while (i < s.count) {
    var c = s[i]
    if (c == "&") {
      out = out + "&amp;"
    } else if (c == "<") {
      out = out + "&lt;"
    } else if (c == ">") {
      out = out + "&gt;"
    } else {
      out = out + c
    }
    i = i + 1
  }
  return out
}

app.listen("127.0.0.1:3000")
