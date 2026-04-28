// htmx counter demo.
//
//   wlift main.wren
//   open http://127.0.0.1:3000
//
// Click the button; the server increments a counter and returns
// the `counter` fragment. htmx swaps it into place. No client-
// side JavaScript beyond htmx itself.
//
// One @hatch:template carries both the full page and the
// addressable fragment. The post handler returns the fragment
// alone via `tpl.renderFragment("counter", ctx)`.

import "@hatch:web"      for App, Css
import "@hatch:template" for Template

var app   = App.new()
var count = 0

var page    = Css.tw("font-sans max-w-sm mx-auto my-16 p-6 bg-white rounded-lg shadow")
var heading = Css.tw("text-2xl font-bold text-gray-900 mb-4")
var row     = Css.tw("flex items-center gap-3")
var btn     = Css.tw("bg-blue-500 text-white px-4 py-2 rounded font-semibold")
              .hover("bg-blue-600")
              .focus("bg-blue-700")
var pill    = Css.tw("inline-block px-3 py-1 rounded-full bg-indigo-100 text-indigo-800 font-medium")

var tpl = Template.parse("
<!doctype html>
<html><head>
  <title>@hatch:web counter</title>
  <script src=\"https://unpkg.com/htmx.org@1.9.12\"></script>
  {{{ styles }}}
</head><body>
  <div class=\"{{ page }}\">
    <h1 class=\"{{ heading }}\">Counter</h1>
    {% fragment counter %}
    <div id=\"counter\" class=\"{{ row }}\">
      <button class=\"{{ btn }}\" hx-post=\"/inc\" hx-target=\"#counter\" hx-swap=\"outerHTML\">+1</button>
      <button class=\"{{ btn }}\" hx-post=\"/reset\" hx-target=\"#counter\" hx-swap=\"outerHTML\">reset</button>
      <span class=\"{{ pill }}\">{{ count }} click(s)</span>
    </div>
    {% endfragment %}
  </div>
</body></html>
")

var ctxFor_ = Fn.new {|req|
  req.style(page)
  req.style(heading)
  req.style(row)
  req.style(btn)
  req.style(pill)
  return {
    "count":   count,
    "page":    page.className,
    "heading": heading.className,
    "row":     row.className,
    "btn":     btn.className,
    "pill":    pill.className,
    "styles":  req.fragmentSheet.styleTag
  }
}

app.get("/")       {|req| tpl.render(ctxFor_.call(req)) }
app.post("/inc")   {|req|
  count = count + 1
  return tpl.renderFragment("counter", ctxFor_.call(req))
}
app.post("/reset") {|req|
  count = 0
  return tpl.renderFragment("counter", ctxFor_.call(req))
}

app.listen("127.0.0.1:3000")
