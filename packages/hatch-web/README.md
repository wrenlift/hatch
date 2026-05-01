A server-rendered, htmx-native web framework for Wren. Router with path parameters, middleware pipeline, content-negotiated rendering through `@hatch:template`, sessions, flash messages, fragment-scoped CSS, server-sent events, and an HTTP/1.1 server on top of `@hatch:socket`. Designed for the "make HTML on the server, swap fragments on the client" shape — no SPA build pipeline, no API gateway in front.

## Overview

Build an `App`, register handlers, listen on an address. Handlers receive a `Request` and return a `String` (200 text/html), a `Response` (full control), an `HxResponse` (template-builder shape), or `null` (204).

```wren
import "@hatch:web"      for App
import "@hatch:template" for Template

var tpl = Template.parse("<h1>Hello {{ name }}</h1>")

var app = App.new()
app.get("/")           {|req| req.render(tpl, { "name": "world" }) }
app.get("/hi/:who")    {|req| "Hi %(req.param("who"))!" }
app.post("/users")     {|req|
  var user = createUser(req.form)
  req.setFlash("notice", "Saved!")
  return Response.redirect("/users/%(user.id)")
}

app.listen("127.0.0.1:3000")
```

Path parameters (`:who`) populate `req.params` after router match. `req.query` is parsed lazily on first access; `req.form` parses urlencoded or multipart bodies on demand. `req.session` carries cookie-backed session data; `req.flash` reads one-shot messages from the previous request and `req.setFlash(key, value)` writes ones for the next.

## Middleware

Middleware is a `Fn(req, next)` — call `next.call(req)` to forward, return anything else to short-circuit. Outermost runs first, the handler runs innermost.

```wren
app.use {|req, next|
  var start = Clock.mono
  var res = next.call(req)
  Log.info("%(req.method) %(req.path) — %((Clock.mono - start) * 1000)ms")
  return res
}
```

Sessions, flashes, and CSRF middleware ship in the box; wire them with `app.use(Session.middleware)` and friends.

## htmx and live updates

Fragment-scoped stylesheets travel with the fragment HTML so htmx swaps don't leak styles to other parts of the page:

```wren
import "@hatch:web" for App, Css

app.get("/button") {|req|
  var btn = Css.tw("bg-blue-500 text-white px-4 py-2 rounded")
  req.style(btn)
  return "<button class='%(btn.className)'>ok</button>"
}
```

Server-sent events live under `Sse` / `SseStream` for streaming updates (chat, notifications, build status). The `Channel` primitive is a fiber-cooperative pub/sub for in-process fan-out — wire it through `Sse` to push messages.

> **Note — the runtime is HTTP/1.1 cleartext today**
> No TLS, no HTTP/2, no WebSockets, no keep-alive (one request per connection). Front it with a reverse proxy (Caddy, nginx, fly.io's edge) for TLS termination and connection reuse until the server picks those up natively.

## Compatibility

Wren 0.4 + WrenLift runtime 0.1 or newer. Native only — `#!wasm` builds use `@hatch:web`'s browser-side `Document` bridge instead of this server. Depends on `@hatch:socket`, `@hatch:template`, `@hatch:log`, `@hatch:hash`, `@hatch:json`, `@hatch:crypto`, `@hatch:fs`, and `@hatch:time`.
