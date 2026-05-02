// hatch.wrenlift.com — Hatch landing page.
//
//   cd hatch/site
//   hatch run
//   # then open http://127.0.0.1:3000

import "@hatch:web"      for App, Static, Response
import "@hatch:template" for TemplateRegistry, FnLoader
import "@hatch:fs"       for Fs
import "@hatch:proc"     for Proc
import "@hatch:os"       for Os
import "./lib/catalog"   for Catalog
import "./lib/api"       for Api

// Render the cozy 404 page. Used by every 404-producing route
// (missing guide, missing blog, missing package). The path is
// surfaced in the page so users see what they actually asked
// for, not just "404".
var notFound = Fn.new {|requestedPath|
  var r = Response.new(404)
  r.html(registry.get("404.html").render({
    "requestedPath":   requestedPath,
    "wrenliftVersion": WRENLIFT_VERSION
  }))
  return r
}

// Single source of truth for the WrenLift runtime version
// surfaced on the topbar pill, the landing eyebrow, and any
// "runs on" copy. Sync with `Cargo.toml`'s `version` whenever
// the runtime cuts a release — there's no native runtime API
// to read it back yet, so we keep it as a literal here and
// thread it through the page context.
var WRENLIFT_VERSION = "0.1.0"

var app = App.new()

app.use(Static.serve("/assets", "./public/assets"))

// Framework-level catchall — every unmatched route lands on the
// cozy 404 page rather than the browser's grey default. Wired
// after `registry` is constructed below; see app.notFound at the
// bottom of this file.

// Filesystem template loader — names map to ./views/<name> via
// @hatch:fs. The template registry caches parsed templates and is
// what `req.render(...)` ultimately walks.
var loader = FnLoader.new(Fn.new {|name|
  var path = "./views/" + name
  if (!Fs.exists(path)) return null
  return Fs.readText(path)
})
var registry = TemplateRegistry.new(loader)

// Boot the catalog: opens an in-memory SQLite db and hydrates it
// from the GitHub-hosted index.toml. Wrapped in `Fiber.try` so a
// flaky first-fetch (DNS not ready on a cold container, GitHub
// blip, etc.) doesn't kill the whole process before `app.listen`
// runs — without a listener, Fly's health check never gets a
// response and the machine restart-loops. The page renders an
// empty grid in this state until a manual refresh / restart
// repopulates the table.
//
// `Catalog.boot()` now yields cooperatively while the curl
// subprocess runs, so we drive the boot fiber to completion in a
// tight loop here rather than relying on a single `.try()` (which
// returns at the first yield).
System.print("boot: starting catalog…")
var bootFiber = Fiber.new { Catalog.boot() }
while (!bootFiber.isDone) {
  bootFiber.try()
}
if (bootFiber.error != null) {
  System.print("boot: catalog hydration failed: %(bootFiber.error)")
  System.print("boot: continuing with empty catalog — refresh later")
} else {
  System.print("boot: catalog: %(Catalog.count) distinct packages loaded")
}

// Build the context any landing-page render needs. Used by both
// the full / route and the htmx fragment swap.
var pageContext = Fn.new {|packages, currentCat|
  return {
    "totalCount":       Catalog.count,
    "counts":           Catalog.byCategory,
    "packages":         packages,
    "currentCat":       currentCat,
    "wrenliftVersion":  WRENLIFT_VERSION
  }
}

app.get("/") {|req|
  var packages = Catalog.recent(12)
  return req.render(registry.get("index.html"), pageContext.call(packages, "all"))
}

// htmx swap target. Search input + filter chips both POST/GET
// here; the response is just the `<div id="grid">` partial when
// the request is htmx-driven, or a full page render for plain GETs
// (so Disabled-JS clients still work via the URL).
app.get("/packages/search") {|req|
  var q   = req.query.containsKey("q")   ? req.query["q"]   : ""
  var cat = req.query.containsKey("cat") ? req.query["cat"] : "all"
  var packages = Catalog.search(q, cat, 24)
  var ctx = pageContext.call(packages, cat)

  if (req.isHx) {
    return registry.get("partials/packages.html").renderFragment("grid", ctx)
  }
  return req.render(registry.get("index.html"), ctx)
}

// Guide pages — a small fixed set (intro / install / hatchfile
// spec / CLI cheatsheet / authoring docs). Each lives as a
// markdown file under `content/`; the route reads it, hands
// the raw source to `views/guide.html`, marked.js + the
// CodeMirror upgrade pipeline render it inside the same
// `.pkg-readme` typography the README + API pages use.
var GUIDES = {
  "intro":     { "title": "Introduction",    "file": "content/intro.md" },
  "install":   { "title": "Install & setup", "file": "content/install.md" },
  "hatchfile": { "title": "The hatchfile",   "file": "content/hatchfile.md" },
  "cli":       { "title": "CLI cheatsheet",  "file": "content/cli.md" },
  "authoring": { "title": "Authoring docs",  "file": "content/authoring.md" }
}

app.get("/guides/:slug") {|req|
  var slug = req.params["slug"]
  if (!GUIDES.containsKey(slug)) return notFound.call("/guides/" + slug)
  var meta = GUIDES[slug]
  var md = Fs.exists(meta["file"]) ? Fs.readText(meta["file"]) : "*(content missing — `" + meta["file"] + "` doesn't exist yet.)*"
  var ctx = docsContext.call(null, {
    "guideSlug":     slug,
    "guideTitle":    meta["title"],
    "guideMd":       md,
    "guideKind":     "guide",
    "activeNav":     "guides",
    "inGuideShell":  true
  })
  if (req.isHx) {
    return registry.get("guide.html").renderFragment("guide_main", ctx)
  }
  return req.render(registry.get("guide.html"), ctx)
}

// Blog / tutorials. Same shell as guides — markdown source under
// `content/blog/`, rendered via marked.js + CodeMirror — but
// linked from the landing page's framework cards as "Read the
// X guide" deep dives. The breadcrumb crumb says "Blog" so the
// hierarchy reads as a separate section.
var BLOGS = [
  {
    "slug":  "web",
    "title": "Build a web app with @hatch:web",
    "file":  "content/blog/web.md",
    "blurb": "A tour through routes, htmx fragment swaps, templating, and the dev loop — by building a small site end to end.",
    "tag":   "Web"
  },
  {
    "slug":  "game",
    "title": "Build a game with @hatch:game",
    "file":  "content/blog/game.md",
    "blurb": "Sprite batching, input mapping, audio, and ECS-lite scenes — walk through a tiny 2D game from blank canvas to playable.",
    "tag":   "Game"
  }
]

// Lookup helper used by the per-post route. The list above is the
// source of truth (so the index page can just iterate it); the
// route uses this to find the matching entry by slug.
var blogBySlug = Fn.new {|slug|
  for (b in BLOGS) {
    if (b["slug"] == slug) return b
  }
  return null
}

// Blog index. Two cards (web + game today) using the same docs
// shell as /packages so the chrome stays consistent. Lives at
// /blog so the topbar's Blog link has somewhere real to land.
app.get("/blog") {|req|
  var ctx = docsContext.call(null, {
    "blogs":     BLOGS,
    "activeNav": "blog"
  })
  return req.render(registry.get("blog.html"), ctx)
}

app.get("/blog/:slug") {|req|
  var slug = req.params["slug"]
  var meta = blogBySlug.call(slug)
  if (meta == null) return notFound.call("/blog/" + slug)
  var md = Fs.exists(meta["file"]) ? Fs.readText(meta["file"]) : "*(content missing — `" + meta["file"] + "` doesn't exist yet.)*"
  var ctx = docsContext.call(null, {
    "guideSlug":     slug,
    "guideTitle":    meta["title"],
    "guideMd":       md,
    "guideKind":     "blog",
    "activeNav":     "blog",
    "inGuideShell":  true
  })
  if (req.isHx) {
    return registry.get("guide.html").renderFragment("guide_main", ctx)
  }
  return req.render(registry.get("guide.html"), ctx)
}

// Build the docs-shell context once per request. `stdlib` and
// `community` populate the sidebar; `currentPkg` lets the active
// row highlight without per-page wiring.
var docsContext = Fn.new {|currentPkg, extra|
  var ctx = {
    "stdlib":          Catalog.standardLibrary,
    "community":       Catalog.community,
    "currentPkg":      currentPkg,
    "totalCount":      Catalog.count,
    "wrenliftVersion": WRENLIFT_VERSION,
    "inGuideShell":    false
  }
  if (extra != null) {
    for (k in extra.keys) ctx[k] = extra[k]
  }
  return ctx
}

// Browse: every package in one grid. The landing page's "Featured"
// section caps at 12 recents; this is the unbounded view, same
// search/filter UX layered on top so the URL is sharable.
app.get("/packages") {|req|
  var q   = req.query.containsKey("q")   ? req.query["q"]   : ""
  var cat = req.query.containsKey("cat") ? req.query["cat"] : "all"
  var packages = (q == "" && cat == "all") ?
    Catalog.search("", "all", 200) :
    Catalog.search(q, cat, 200)
  var ctx = docsContext.call(null, {
    "packages":   packages,
    "currentCat": cat,
    "counts":     Catalog.byCategory,
    "activeNav":  "packages"
  })
  return req.render(registry.get("docs.html"), ctx)
}

// Package detail. Header is hatchfile-derived (catalog row); body
// is the README rendered via htmx + marked.js client-side. The
// raw README markdown is fetched on demand by `/docs/:name/readme`
// so the initial render stays fast (single SQL row) and the
// network hop only happens once the user actually lands.
app.get("/packages/:name") {|req|
  var name = req.params["name"]
  var pkg = Catalog.byName(name)
  if (pkg == null) return notFound.call("/packages/" + name)
  var ctx = docsContext.call(name, {
    "pkg":       pkg,
    "readmeUrl": Catalog.readmeUrl(pkg),
    "view":      "readme",
    "activeNav": "packages"
  })
  return req.render(registry.get("package.html"), ctx)
}

// API reference view. Same package detail header, but the body
// renders the bundled `Docs` JSON section (classes / members /
// signatures collected from `///` doc comments at publish time)
// rather than the README. The header CTA flips to "← README" so
// the user has a one-click way back.
app.get("/packages/:name/api") {|req|
  var name = req.params["name"]
  var pkg = Catalog.byName(name)
  if (pkg == null) return notFound.call("/packages/" + name + "/api")
  // `Api.render` shells out to `hatch docs <workspace>` (or
  // `<bundle>`) and turns the resulting `Vec<ModuleDoc>` JSON
  // into the page body. Returns `null` when no source / cached
  // bundle is reachable; the template falls back to the empty
  // placeholder in that case.
  var ctx = docsContext.call(name, {
    "pkg":        pkg,
    "readmeUrl":  Catalog.readmeUrl(pkg),
    "view":       "api",
    "apiModules": Api.fetch(pkg),
    "activeNav":  "packages"
  })
  return req.render(registry.get("package_api.html"), ctx)
}

// htmx fragment endpoint: return the raw README markdown wrapped
// in a tiny <script type="text/markdown"> + a hyperscript hook
// that runs marked.parse() and replaces the host element. Keeping
// the markdown as the response body (rather than parsed HTML
// here) avoids a server-side markdown dependency for v1; the
// design renders client-side via marked.js loaded by the layout.
app.get("/packages/:name/readme") {|req|
  var name = req.params["name"]
  var pkg = Catalog.byName(name)
  if (pkg == null) {
    var r = Response.new(404)
    r.text("not found")
    return r
  }
  var html = Catalog.fetchReadmeHtml(pkg)
  if (html == null) {
    var r = Response.new(204)
    r.text("")
    return r
  }
  var r = Response.new(200)
  r.html(html)
  // README content is immutable per `name@version` (a republish
  // bumps the version → new URL → cache miss naturally), so
  // browsers can keep the response indefinitely. Server already
  // memoises in-process via `__readmeCache`; the browser cache
  // saves the round-trip on revisit. 1h is conservative —
  // honours the 5-min catalog refresh window during which a
  // republish might land + a few minutes for downstream cache
  // invalidation.
  r.header("Cache-Control", "public, max-age=3600")
  return r
}

// Catchall: any path that didn't match a route above renders the
// cozy 404 with the requested path echoed back. Bare sections
// (`/blog`, `/guides`) hit this — there's no index page for them
// because the topbar links go straight to a default slug.
app.notFound {|req| notFound.call(req.path) }

// Surface request-fiber aborts on stderr. The framework catches
// them and renders the default 500 page silently, which makes
// intermittent crashes (a JIT IC mis-dispatch, a stale catalog
// row, a template lookup miss) impossible to diagnose from the
// server log alone. Logging here also still renders the page so
// the user sees the same UX.
app.error {|req, err|
  System.print("[error] %(req.method) %(req.path) → %(err)")
  var r = Response.new(500)
  r.html("<h1>500 Internal Server Error</h1><pre>%(err)</pre>")
  return r
}

// Honour `PORT` from the environment so Fly (or any platform
// that injects its own port) routes through correctly; falls
// back to 3000 for local dev where the Dockerfile / fly.toml
// already align on that internal port.
var port = Os.env("PORT", "3000")
System.print("listening on 0.0.0.0:%(port)")
// Background catalog refresher — re-pulls `index.toml` every
// 5 minutes so the in-memory SQLite picks up registry changes
// without a server restart. Yields cooperatively so request
// fibers keep ticking between refreshes.
app.spawn(Fn.new { Catalog.refreshLoop() })

// Background cache warmers — pre-fill the per-process API +
// README caches for every package the catalog knows about, so
// the first user visit to `/packages/:name/api` or
// `/packages/:name/readme` doesn't pay the curl + JSON parse +
// decorate (or markdown-wrap) cost on the request fiber.
// `@hatch:gpu`'s docs alone took 20+ seconds to walk on a cold
// interpreter and dominated the cold-start experience for every
// new visitor; warming up-front amortises that into a quiet
// boot-time pass per machine. The warmers yield between
// packages so request fibers keep handling live traffic; cache
// misses during warm-up still work normally and just populate
// the same map the warmer is filling.
app.spawn(Fn.new { Api.warmAll(Catalog.allRecent) })
app.spawn(Fn.new { Catalog.warmReadmes() })

app.listen("0.0.0.0:" + port)
