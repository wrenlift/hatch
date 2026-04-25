// @hatch:web styled-components demo.
//
// Shows the three CSS scopes:
//   - Global:   base typography via app.globalCss
//   - Fragment: button styling registered per request
//   - htmx:     swapping a fragment also brings its <style> along
//
//   wlift --mode interpreter styled.wren
//   open http://127.0.0.1:3000
//
// NOTE: run with `--mode interpreter` until the tiered JIT's
// method-IC specializer is fixed for the Stylesheet.add path.
// Tiered mis-dispatches `_styles.add(style)` inside Stylesheet.add
// to `Request.style(_)`, causing infinite recursion + a bus error.
// Logged as project_web_jit_miscompile in memory.

import "../web" for App, Css

var base = Css.tw("font-sans text-gray-900 leading-normal")
                .raw({"font-family": "system-ui, -apple-system, sans-serif"})

var btn = Css.tw("bg-blue-500 text-white px-4 py-2 rounded font-semibold")
                .hover("bg-blue-600")
                .focus("bg-blue-700")
                .disabled("bg-gray-300 text-gray-500")

var card = Css.tw("bg-white p-6 rounded-lg shadow max-w-md mx-auto my-8")

var headline = Css.tw("text-3xl font-bold text-gray-900 mb-4")
                      .md("text-4xl")

var app = App.new()
app.globalCss(base)

app.get("/") {|req|
  req.style(card)
  req.style(headline)
  req.style(btn)
  var html = "" +
    req.globalSheet.styleTag + req.fragmentSheet.styleTag +
    "<div class='%(card.className)'>" +
      "<h1 class='%(headline.className)'>@hatch:web</h1>" +
      "<p>Server-rendered, htmx-native, Tailwind-dialect styling — all pure Wren.</p>" +
      "<div hx-get='/counter' hx-swap='outerHTML' hx-target='this' style='margin-top: 1rem;'>" +
        "<button class='%(btn.className)'>Click me</button>" +
      "</div>" +
    "</div>"
  return html
}

var count = 0

app.get("/counter") {|req|
  count = count + 1
  var pill = Css.tw("inline-block px-3 py-1 rounded-full bg-indigo-100 text-indigo-800 font-medium")
  var wrap = Css.tw("flex items-center gap-3 mt-4")
  req.style(pill)
  req.style(wrap)
  req.style(btn)
  return req.fragmentSheet.styleTag +
    "<div class='%(wrap.className)' hx-get='/counter' hx-swap='outerHTML' hx-target='this'>" +
      "<button class='%(btn.className)'>Click me</button>" +
      "<span class='%(pill.className)'>%(count) click(s)</span>" +
    "</div>"
}

app.listen("127.0.0.1:3000")
