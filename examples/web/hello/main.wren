// Minimal @hatch:web example.
//
//   wlift main.wren
//   curl http://127.0.0.1:3000/
//   curl http://127.0.0.1:3000/hi/world
//   curl -H "HX-Request: true" http://127.0.0.1:3000/hi/world
//
// Showcases:
//   - App.get + path params
//   - @hatch:template for HTML rendering (auto-escaped {{ }} +
//     {% fragment %} blocks for htmx swaps)
//   - middleware logging via App.use

import "@hatch:web"      for App
import "@hatch:template" for Template

var app = App.new()

var indexTpl = Template.parse(
  "<!doctype html>" +
  "<html><head><title>@hatch:web</title></head><body>" +
  "<h1>Hello from @hatch:web</h1>" +
  "<p>Try <a href='/hi/world'>/hi/world</a></p>" +
  "</body></html>")

// One template carries both a full-page response and an htmx
// fragment swap. The fragment block renders alone for hx-* calls
// via `tpl.renderFragment("greeting", ctx)`.
var greetTpl = Template.parse(
  "<!doctype html>" +
  "<html><head><title>Hello {{ who }}</title></head><body>" +
  "{% fragment greeting %}<span>hey {{ who }}!</span>{% endfragment %}" +
  "</body></html>")

app.get("/") {|req| indexTpl.render({}) }

app.get("/hi/:who") {|req|
  var ctx = { "who": req.param("who") }
  if (req.isHx) return greetTpl.renderFragment("greeting", ctx)
  return greetTpl.render(ctx)
}

app.use(Fn.new {|req, next|
  System.print("%(req.method) %(req.path)")
  return next.call(req)
})

app.listen("127.0.0.1:3000")
