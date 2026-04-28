// @hatch:web chat demo — pub/sub + SSE + htmx + templates.
//
//   wlift --mode interpreter --step-limit 0 main.wren
//   Open two browser tabs at http://127.0.0.1:3000
//   Post a message in one; watch it appear in the other.
//
// Showcases the Phase 4 stack:
//   - Fiber-cooperative scheduler in App.listen (concurrent conns)
//   - Channel pub/sub for fan-out
//   - Sse.stream + htmx sse-ext for live DOM updates
//   - @hatch:template Template + {% fragment message %} for both
//     the page shell and the per-message HTML pushed over SSE
//
// `--step-limit 0` disables the interpreter step cap (default 1B
// caps out after ~10–30 minutes of polling-loop instructions on
// a long-running server).

import "@hatch:web"      for App, Response, Css, Sse
import "@hatch:template" for Template

var app  = App.new()
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

// ── Templates ─────────────────────────────────────────────────
//
// One template, two outputs:
//   - render(ctx)                       → full page
//   - renderFragment("message", ctx)    → just the <div> for SSE

var tpl = Template.parse("
<!doctype html>
<html><head>
  <title>@hatch:web chat</title>
  <script src=\"https://unpkg.com/htmx.org@1.9.12\"></script>
  <script src=\"https://unpkg.com/htmx.org@1.9.12/dist/ext/sse.js\"></script>
  {{{ styles }}}
</head><body>
  <div class=\"{{ page }}\">
    <h1 class=\"{{ heading }}\">chat</h1>
    <div id=\"messages\" class=\"{{ msgList }}\"
         hx-ext=\"sse\" sse-connect=\"/stream\" sse-swap=\"message\" hx-swap=\"beforeend\"></div>
    <form class=\"{{ form }}\" hx-post=\"/post\" hx-swap=\"none\" hx-on::after-request=\"this.reset()\">
      <input class=\"{{ input }}\" name=\"msg\" placeholder=\"say something...\" autofocus>
      <button class=\"{{ btn }}\" type=\"submit\">Send</button>
    </form>
  </div>
  {% fragment message %}<div class=\"{{ msgLine }}\">{{ msg }}</div>{% endfragment %}
</body></html>
")

// ── Routes ────────────────────────────────────────────────────

app.get("/") {|req|
  req.style(page)
  req.style(heading)
  req.style(msgList)
  req.style(form)
  req.style(input)
  req.style(btn)
  return tpl.render({
    "page":    page.className,
    "heading": heading.className,
    "msgList": msgList.className,
    "form":    form.className,
    "input":   input.className,
    "btn":     btn.className,
    "styles":  req.fragmentSheet.styleTag
  })
}

app.post("/post") {|req|
  var msg = req.form.containsKey("msg") ? req.form["msg"] : ""
  if (msg != "") {
    // {{ msg }} auto-escapes — no manual HTML escape pass needed.
    var html = tpl.renderFragment("message", {
      "msgLine": msgLine.className,
      "msg":     msg
    })
    chat.broadcast(html)
  }
  return Response.new(204)
}

app.get("/stream") {|req|
  var sub  = chat.subscribe
  var line = msgLine.className
  return Sse.stream(Fn.new {|emit|
    var hello = tpl.renderFragment("message", {"msgLine": line, "msg": "— connected —"})
    emit.call({"event": "message", "data": hello})
    while (true) {
      var html = sub.receive
      if (html == null) return  // channel closed
      emit.call({"event": "message", "data": html})
    }
  })
}

app.listen("127.0.0.1:3000")
