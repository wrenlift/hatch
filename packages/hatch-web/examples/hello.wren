// Minimal @hatch:web example:
//
//   wlift hello.wren
//   curl http://127.0.0.1:3000/
//   curl http://127.0.0.1:3000/hi/world
//   curl -H "HX-Request: true" http://127.0.0.1:3000/hi/world

import "../web" for App

var app = App.new()

app.get("/") {|req|
  "<h1>Hello from @hatch:web</h1>" +
  "<p>Try <a href='/hi/world'>/hi/world</a></p>"
}

app.get("/hi/:who") {|req|
  if (req.isHx) return "<span>hey %(req.param("who"))</span>"
  return "<h1>Hi, %(req.param("who"))!</h1>"
}

app.use(Fn.new {|req, next|
  System.print("%(req.method) %(req.path)")
  return next.call(req)
})

app.listen("127.0.0.1:3000")
