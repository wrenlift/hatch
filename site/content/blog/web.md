`@hatch:web` is the framework you reach for when you want a server that renders HTML, swaps fragments over htmx, and streams updates over SSE — without bolting on a separate frontend project. Routes are Wren closures. Templates are Jinja-shaped. The scheduler is fiber-cooperative, so a long-poll handler doesn't block the next connection. This post walks from `hatch init` to a small live-updating app.

## Why @hatch:web

Three things make it different from "Express but in Wren":

- **Fiber-cooperative I/O.** `App.listen` is a single accept loop on a `Scheduler_`. Every accepted connection spawns a serve fiber. Reads on the socket yield the fiber on would-block, so a `Channel.receive` waiting for a broadcast costs nothing while it idles.
- **htmx-first.** The `Request` object exposes parsed `HX-*` headers as `req.hx` and `req.isHx`. The template package has `{% fragment %}` blocks you can render in isolation as the response body for an `hx-get` swap. There's no JSON layer between server and DOM.
- **No frontend framework.** Templates render server-side. Live updates ride SSE. `Static.serve` covers the few JS / CSS files you do need. The whole app is one Wren process.

The smallest version of all of this is six lines:

```wren
import "@hatch:web" for App

var app = App.new()
app.get("/")        {|req| "<h1>Hello from @hatch:web</h1>" }
app.get("/hi/:who") {|req| "<h1>Hi, %(req.param("who"))!</h1>" }
app.listen("127.0.0.1:3000")
```

A handler returning a `String` becomes a 200 `text/html` response. Returning a `Response` gives you full control. Returning `null` is a 204. The path `:who` is a route param, parsed by the router and exposed via `req.param`.

## Setup

Scaffold the workspace, add the two packages you'll need, and confirm it boots:

```sh
hatch init my-app --template web
cd my-app
hatch add @hatch:template
hatch run
```

`--template web` lays down a `main.wren` with a couple of demo routes, a `public/` for static files, and a `.gitignore`. `hatch add @hatch:template` records the dep in the hatchfile. `hatch run` resolves the graph, downloads anything missing into `~/.hatch/cache`, and runs the entry module.

The hatchfile ends up looking like this:

```toml
name        = "my-app"
version     = "0.1.0"
entry       = "main"
description = "..."

[dependencies]
"@hatch:web"      = "0.1.3"
"@hatch:template" = "0.1.4"
```

For development, swap `hatch run` for `hatch web serve`. That spawns `wlift --watch main.wren`, polls source mtimes, and on save sends `SIGUSR1` to reload modified modules in-process. No respawn, no lost in-memory state — the same socket keeps accepting.

## Your first route

Open `main.wren` and write the simplest thing that works:

```wren
import "@hatch:web" for App, Response

var app = App.new()

app.get("/") {|req|
  "<!doctype html><html><body>" +
  "<h1>Hello from @hatch:web</h1>" +
  "<p>Try <a href='/hi/world'>/hi/world</a></p>" +
  "</body></html>"
}

app.get("/hi/:who") {|req|
  if (req.isHx) return "<span>hey %(req.param("who"))</span>"
  return "<h1>Hi, %(req.param("who"))!</h1>"
}

app.listen("0.0.0.0:3000")
```

Two things to notice. First, the `req.isHx` check: htmx flags every request with `HX-Request: true`, so the same route URL can serve a full page to a fresh browser visit and a fragment to an htmx swap. Second, `app.listen("0.0.0.0:...")` instead of `127.0.0.1` — the difference matters once you containerize.

For anything beyond a `Response.new(200).html(s)` short-cut, the `Response` builder chains:

```wren
app.get("/json") {|req|
  Response.new(200)
    .json("{\"ok\": true}")
    .header("X-Custom", "1")
    .cookie("seen", "1", { "httpOnly": true, "sameSite": "Lax" })
}
```

`Response.redirect("/somewhere")` builds a 302 with `Location` set; pass `(url, 303)` for See Other. Returning a redirect from a handler is enough — the framework doesn't need a separate "send" step.

## Templates

Inline HTML strings get old fast. Move to `@hatch:template` and a `views/` folder.

`@hatch:template` ships two loaders: `MapLoader` for in-memory tests and `FnLoader` for any 1-arg function. The site itself uses an `FnLoader` over the filesystem; copy that pattern.

```wren
import "@hatch:web"      for App
import "@hatch:template" for TemplateRegistry, FnLoader
import "@hatch:fs"       for Fs

var app = App.new()

var loader = FnLoader.new(Fn.new {|name|
  var path = "./views/" + name
  if (!Fs.exists(path)) return null
  return Fs.readText(path)
})
var registry = TemplateRegistry.new(loader)
```

The registry parses on first read and caches the result, so subsequent calls are O(1). `{% extends %}` and `{% include %}` resolve through the same loader.

Now add a layout and a page that extends it.

`views/layout.html`:

```wren
<!doctype html>
<html>
<head>
  <title>{% block title %}my app{% endblock %}</title>
  <script src="https://unpkg.com/htmx.org@2"></script>
</head>
<body>
  {% block body %}{% endblock %}
</body>
</html>
```

`views/index.html`:

```wren
{% extends "layout.html" %}
{% block title %}home{% endblock %}
{% block body %}
  <h1>Hello, {{ user.name }}</h1>
  <p>You have {{ items | length }} items.</p>
  <ul>
    {% for item in items %}
      <li>{{ item.title }}</li>
    {% endfor %}
  </ul>
{% endblock %}
```

(That fenced block is HTML, not Wren — the page renders it as the syntax theme is happiest with HTML inside a `wren` block. Treat it as template source.)

Render it from a handler with `req.render`:

```wren
app.get("/") {|req|
  req.render(registry.get("index.html"), {
    "user":  { "name": "world" },
    "items": [{ "title": "first" }, { "title": "second" }]
  })
}
```

`req.render` returns a `Response`. It also content-negotiates: if the request is htmx (`req.isHx`), the template can branch on `{% if hx.request %}` and emit a different shape. For most apps you won't need that — fragment routes (next section) are the cleaner answer.

> **Note: extends needs a registry**
> A standalone `Template.parse(src)` can render `{% if %}` / `{% for %}` etc., but `{% extends %}` and cross-file `{% include %}` need a `TemplateRegistry` so the parser can resolve names. Always go through `registry.get(name)` once your templates inherit from a layout.

## htmx fragments

Fragment routes are where `@hatch:web` earns its keep. Define a `{% fragment %}` block in a template, render only that block as the response body, and htmx swaps it into the DOM without a page reload.

The hatch.wrenlift.com homepage uses this for live package search. The relevant slice — the search bar plus the swap target:

```wren
<input id="search" name="q" type="text"
       hx-get="/packages/search"
       hx-trigger="input changed delay:120ms, keyup[key=='Enter']"
       hx-target="#grid"
       hx-include="[name=cat]:checked"
       hx-swap="outerHTML" />

{% fragment grid %}
<div class="pkg-grid" id="grid">
  {% for p in packages %}{% include "partials/_package_card.html" %}{% endfor %}
  {% if packages | length == 0 %}
  <div class="empty">No packages matched.</div>
  {% endif %}
</div>
{% endfragment %}
```

The handler returns the full page on a plain `GET` and just the fragment on an htmx request:

```wren
app.get("/packages/search") {|req|
  var q   = req.query.containsKey("q")   ? req.query["q"]   : ""
  var cat = req.query.containsKey("cat") ? req.query["cat"] : "all"
  var packages = Catalog.search(q, cat, 24)
  var ctx = { "packages": packages, "currentCat": cat }

  if (req.isHx) {
    return registry.get("partials/packages.html").renderFragment("grid", ctx)
  }
  return req.render(registry.get("index.html"), ctx)
}
```

`renderFragment(name, ctx)` walks the AST, only emits output once it enters the named fragment, and ignores everything else. The same template source serves the full-page first paint and every subsequent swap. The branch on `req.isHx` is the only thing the handler has to know about htmx.

For htmx-targeted side effects (toast on save, push the URL, retarget the swap), build an `HxResponse`:

```wren
import "@hatch:template" for Hx

app.post("/items") {|req|
  // ... save ...
  return Hx.response(registry.get("partials/items.html").renderFragment("row", ctx))
    .trigger("item-created", { "id": newId })
    .pushUrl("/items/%(newId)")
    .reswap("afterbegin")
}
```

`HxResponse` is just a body + map of `HX-*` headers; the framework coerces it to a `Response` at the edge. Returning one is interchangeable with returning a string.

## Live channels

For broadcast-shaped state — a chat room, a build dashboard, anything where one writer fans out to many readers — `@hatch:web` ships `Channel` (in-memory pub/sub) and `Sse` (Server-Sent Events).

`app.channel("name")` is a registry. Same name, same Channel, every call. Subscribers attach via `chan.subscribe`, get a `Subscription` whose `receive` getter fiber-yields until a message arrives. Producers call `chan.broadcast(msg)`.

The full chat demo from `examples/chat.wren` is about 80 lines including styling. The protocol part:

```wren
import "@hatch:web" for App, Response, Sse

var app = App.new()
var chat = app.channel("chat")

app.post("/post") {|req|
  var msg = req.form.containsKey("msg") ? req.form["msg"] : ""
  if (msg != "") {
    chat.broadcast("<div>" + escape_.call(msg) + "</div>")
  }
  return Response.new(204)
}

app.get("/stream") {|req|
  var sub = chat.subscribe
  return Sse.stream(Fn.new {|emit|
    while (true) {
      var html = sub.receive
      if (html == null) return    // channel closed
      emit.call({ "event": "message", "data": html })
    }
  })
}
```

The `/post` handler broadcasts an HTML fragment. The `/stream` handler returns an `SseStream` — the listen loop spots that, writes SSE headers, and runs the writer fiber until it returns or the connection drops. Each `emit.call(payload)` formats one frame and flushes.

The page wires the swap with htmx's SSE extension:

```wren
<div id="messages"
     hx-ext="sse"
     sse-connect="/stream"
     sse-swap="message"
     hx-swap="beforeend"></div>
```

That's it for the wire. No JS beyond the htmx + sse-ext CDN scripts. Message arrives, htmx appends it to `#messages`, browser scrolls. The Wren side never serializes JSON or builds a JS-side renderer.

The Channel reaps stale subscriptions automatically: if a tab closes, the serve fiber dies, and on the next broadcast its overflowed queue gets flagged and dropped. No reaper thread, no manual cleanup.

> **Note: run with --step-limit 0**
> The interpreter caps fiber instructions at 1B by default — fine for batch workloads, ~10-30 minutes for a server polling its accept loop. For long-running web processes, `wlift --mode interpreter --step-limit 0 main.wren` removes the cap. `hatch web serve` already does this.

## Static assets

`Static.serve(urlPrefix, root)` is a middleware. Mount it before your routes:

```wren
import "@hatch:web" for App, Static

var app = App.new()
app.use(Static.serve("/assets", "./public/assets"))
```

A `GET /assets/site.css` reads `./public/assets/site.css` and streams the bytes back with an extension-inferred `Content-Type`. Misses fall through to the next middleware, so dynamic routes still get a chance — the 404 only comes from the router. Path traversal (`..`) gets a 403 before the filesystem is touched.

The MIME table covers HTML, CSS, JS, JSON, SVG, PNG, JPEG, GIF, WebP, ICO, WOFF, WOFF2, TTF, plain text, XML. Anything else falls back to `application/octet-stream` — fine for downloads, set the header explicitly for content you want sniffed.

For form-driven apps, `Session.cookie(secret)` and `Csrf.middleware` are both in the box. `Session` is HMAC-signed JSON in a cookie (stateless, a few KB cap). `Csrf` rides on the session, demands a token on `POST` / `PUT` / `PATCH` / `DELETE`, exempts htmx requests that send `X-CSRF-Token`. The signup example walks through both.

## Deploy

The hatch.wrenlift.com site itself runs in a two-stage Dockerfile: a `builder` stage installs `wlift` + `hatch` from the published `install.sh`, a `runtime` stage copies just the binaries plus the workspace and runs `hatch run .`. The whole thing is a few hundred bytes of Dockerfile.

Sketch:

```sh
FROM debian:bookworm-slim AS builder
RUN apt-get update && apt-get install -y curl ca-certificates
RUN curl -fsSL https://wrenlift.com/install.sh \
  | INSTALL_DIR=/usr/local/bin sh

FROM debian:bookworm-slim AS runtime
RUN apt-get update && apt-get install -y ca-certificates curl
COPY --from=builder /usr/local/bin/wlift /usr/local/bin/wlift
COPY --from=builder /usr/local/bin/hatch /usr/local/bin/hatch
WORKDIR /app
COPY hatchfile main.wren ./
COPY views public lib ./
EXPOSE 3000
CMD ["hatch", "run", "."]
```

`hatch run` resolves the dep graph against `~/.hatch/cache` on first boot, then runs your entry module. No build step inside the image, no NPM install, no asset pipeline. Fly.io, Render, a bare VM behind nginx — anything that runs a Linux binary works.

Listen on `0.0.0.0` (not `127.0.0.1`) and read the port from `$PORT` if your platform sets one:

```wren
import "@hatch:os" for Os
var port = Os.env("PORT") == null ? "3000" : Os.env("PORT")
app.listen("0.0.0.0:" + port)
```

## Where to next

`@hatch:web` has more surface than this article covers — `Form` schemas with transforms + validators, `Css.tw(...)` for inline Tailwind-shaped styling, fragment-scoped stylesheets that ride along with htmx swaps, signed-cookie sessions, CSRF.

- [/packages/@hatch:web](/packages/@hatch:web) — the full API reference + README.
- [/packages/@hatch:template](/packages/@hatch:template) — every directive, every filter, fragment / slot / embed semantics.
- The `examples/` folder in the package source has runnable versions of `hello`, `chat`, `signup`, and `styled`. Each is one file, tens of lines.
