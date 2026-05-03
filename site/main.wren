// hatch.wrenlift.com — Hatch landing page.
//
//   cd hatch/site
//   hatch run
//   # then open http://127.0.0.1:3000

import "@hatch:web"      for App, Static, Response
import "@hatch:template" for TemplateRegistry, FnLoader
import "@hatch:fs"       for Fs
import "@hatch:os"       for Os
import "./lib/catalog"   for Catalog
import "./lib/api"       for Api
import "./lib/badge"     for Badge

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

// `Cache-Control` policies, scaled to each route's update cadence.
// `stale-while-revalidate` lets the browser show the cached page
// instantly while it revalidates in the background — avoids the
// "I just navigated and the page froze" pattern even when our
// server is fast. `Vary: HX-Request` is set on routes whose body
// shape depends on whether htmx is asking for a fragment swap or a
// plain full-page navigation; without it, browsers / intermediaries
// could serve a `<div id="grid">` fragment to a plain reload.
//
// All bounded so a republish is visible within minutes, not hours.
// Per-package routes use `name@version` cache keys server-side, but
// the URL is `/packages/:name` (no version), so a republish doesn't
// invalidate the browser cache automatically — `max-age=300` keeps
// a republished page hidden for at most 5 minutes.
var CACHE_LANDING  = "public, max-age=120, stale-while-revalidate=600"        // / and /packages — catalog refresh window is 5 min
var CACHE_PACKAGE  = "public, max-age=300, stale-while-revalidate=3600"       // /packages/:name + /api + /readme
var CACHE_GUIDE    = "public, max-age=86400, stale-while-revalidate=604800"   // guides only change on image rebuild
var CACHE_BLOG     = "public, max-age=3600, stale-while-revalidate=86400"     // blog posts publish via image rebuild
var CACHE_FRAGMENT = "no-cache"                                                // htmx swaps depend on query state

var app = App.new()

// `/assets/*` cache policy. The sprite SVG, the CSS, the
// CodeMirror module — all immutable per deploy (Fly's image
// digest changes when any of them does). 7-day max-age with a
// 30-day stale-while-revalidate window keeps the browser cache
// hot across visits without forcing a full revalidation each
// time. `Static.serve` itself doesn't set Cache-Control today,
// so we wrap it: gate the header injection on the request path
// matching `/assets/`, otherwise the inner middleware delegates
// to `next` and we'd be stamping the asset cache policy onto
// every dynamic route's response (overriding the tier-specific
// `Cache-Control` each route sets).
var staticMw = Static.serve("/assets", "./public/assets")
app.use(Fn.new {|req, next|
  var r = staticMw.call(req, next)
  if (r != null && req.path.startsWith("/assets/")) {
    // 1-day max-age + 7-day SWR. Dropped `immutable` because we
    // don't yet ship versioned asset URLs (no `/assets/site-
    // <hash>.css`); a stale cached `site.css` was the smoking
    // gun behind the "mascot tiny" report — the prior deploy
    // had set `immutable`, the next deploy edited `site.css`,
    // and any browser that had cached the file kept rendering
    // against the old rules. With this policy, browsers will
    // revalidate after a day and SWR keeps the request fast in
    // the meantime. Once we add a content-hash to asset URLs
    // we can flip back to a long max-age + immutable.
    r.header("Cache-Control", "public, max-age=86400, stale-while-revalidate=604800")
  }
  return r
})

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

// Inject `requestPath` into a render context. The layout-level
// `<link rel="canonical">`, `og:url`, and JSON-LD `url` fields
// all read `requestPath` so social-card / search-engine link
// previews point at the actual route the user hit. Each route
// builds its ctx then passes it through here just before
// `req.render`.
var withPath = Fn.new {|req, ctx|
  ctx["requestPath"] = req.path
  return ctx
}

app.get("/") {|req|
  var packages = Catalog.recent(12)
  return req.render(registry.get("index.html"), withPath.call(req, pageContext.call(packages, "all")))
    .header("Cache-Control", CACHE_LANDING)
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
  return req.render(registry.get("index.html"), withPath.call(req, ctx))
    .header("Cache-Control", CACHE_FRAGMENT)
}

// Guide pages — a small fixed set (intro / install / hatchfile
// spec / CLI cheatsheet / authoring docs). Each lives as a
// markdown file under `content/`; the route reads it, hands
// the raw source to `views/guide.html`, marked.js + the
// CodeMirror upgrade pipeline render it inside the same
// `.pkg-readme` typography the README + API pages use.
// `published` and `updated` populate the `datePublished` /
// `dateModified` fields on the per-guide TechArticle JSON-LD.
// Google's Article rich-result eligibility requires both, so
// without these the structured-data block was indexed but
// didn't trigger a rich-result card. ISO-8601 dates, no
// timezone (Google defaults to UTC).
var GUIDES = {
  "intro":     { "title": "Introduction",    "file": "content/intro.md",     "published": "2026-04-01", "updated": "2026-05-03" },
  "install":   { "title": "Install & setup", "file": "content/install.md",   "published": "2026-04-01", "updated": "2026-05-03" },
  "hatchfile": { "title": "The hatchfile",   "file": "content/hatchfile.md", "published": "2026-04-01", "updated": "2026-05-03" },
  "cli":       { "title": "CLI cheatsheet",  "file": "content/cli.md",       "published": "2026-04-01", "updated": "2026-05-03" },
  "authoring": { "title": "Authoring docs",  "file": "content/authoring.md", "published": "2026-04-01", "updated": "2026-05-03" }
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
    "inGuideShell":  true,
    "guidePublished": meta["published"],
    "guideUpdated":   meta["updated"]
  })
  if (req.isHx) {
    return registry.get("guide.html").renderFragment("guide_main", ctx)
  }
  return req.render(registry.get("guide.html"), withPath.call(req, ctx))
    .header("Cache-Control", CACHE_GUIDE)
    .header("Vary", "HX-Request")
}

// Blog / tutorials. Same shell as guides — markdown source under
// `content/blog/`, rendered via marked.js + CodeMirror — but
// linked from the landing page's framework cards as "Read the
// X guide" deep dives. The breadcrumb crumb says "Blog" so the
// hierarchy reads as a separate section.
var BLOGS = [
  {
    "slug":      "web",
    "title":     "Build a web app with @hatch:web",
    "file":      "content/blog/web.md",
    "blurb":     "A tour through routes, htmx fragment swaps, templating, and the dev loop — by building a small site end to end.",
    "tag":       "Web",
    "published": "2026-04-15",
    "updated":   "2026-05-03"
  },
  {
    "slug":      "game",
    "title":     "Build a game with @hatch:game",
    "file":      "content/blog/game.md",
    "blurb":     "Sprite batching, input mapping, audio, and ECS-lite scenes — walk through a tiny 2D game from blank canvas to playable.",
    "tag":       "Game",
    "published": "2026-04-22",
    "updated":   "2026-05-03"
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
// Per-process cache of pre-rendered blog HTML, keyed by slug.
// Filled by the boot-time warmer below. Each entry is a complete
// page body, ready to ship as a Response.html - cuts the cold
// first-hit cost (2.6-6.6s on warm runs measured 2026-05-02 for
// `/blog/web`) down to a `Map.containsKey` + `Response.new`. The
// catalog-refresh fiber rewarms after `rebuildAggregateCache_`
// so the embedded sidebar (`stdlib` + `community` lists) isn't
// stale across refreshes.
var blogHtmlCache = null

// Same shape as the routes use, broken out so the boot-time
// warmer and the dynamic-render fallback render an identical
// page.
var renderBlogPage = Fn.new {|slug|
  if (blogHtmlCache == null) blogHtmlCache = {}
  var meta = blogBySlug.call(slug)
  if (meta == null) return null
  var md = Fs.exists(meta["file"]) ? Fs.readText(meta["file"]) : "*(content missing - `" + meta["file"] + "` doesn't exist yet.)*"
  var ctx = docsContext.call(null, {
    "guideSlug":     slug,
    "guideTitle":    meta["title"],
    "guideMd":       md,
    "guideKind":     "blog",
    "activeNav":     "blog",
    "inGuideShell":  true,
    "guidePublished": meta["published"],
    "guideUpdated":   meta["updated"],
    // Canonical path baked in at warm-time. The boot-time warmer
    // doesn't have a `req`, so we synthesize the path here from
    // the slug — matches what the route handler would have set
    // via `withPath`.
    "requestPath":   "/blog/" + slug
  })
  return registry.get("guide.html").render(ctx)
}

var warmBlogs = Fn.new {
  for (b in BLOGS) {
    var html = renderBlogPage.call(b["slug"])
    if (html != null) blogHtmlCache[b["slug"]] = html
    Fiber.yield()
  }
}

app.get("/blog") {|req|
  var ctx = docsContext.call(null, {
    "blogs":     BLOGS,
    "activeNav": "blog"
  })
  return req.render(registry.get("blog.html"), withPath.call(req, ctx))
    .header("Cache-Control", CACHE_BLOG)
}

app.get("/blog/:slug") {|req|
  var slug = req.params["slug"]
  var meta = blogBySlug.call(slug)
  if (meta == null) return notFound.call("/blog/" + slug)
  if (req.isHx) {
    // htmx swap target — render the inner fragment fresh; we
    // don't cache fragments because the swap shape changes
    // independently of the full-page chrome.
    var md = Fs.exists(meta["file"]) ? Fs.readText(meta["file"]) : "*(content missing — `" + meta["file"] + "` doesn't exist yet.)*"
    var ctx = docsContext.call(null, {
      "guideSlug":     slug,
      "guideTitle":    meta["title"],
      "guideMd":       md,
      "guideKind":     "blog",
      "activeNav":     "blog",
      "inGuideShell":  true
    })
    return registry.get("guide.html").renderFragment("guide_main", ctx)
      .header("Cache-Control", CACHE_BLOG)
      .header("Vary", "HX-Request")
  }
  // Pre-rendered cache hit - common path. Skips the full
  // template render (sidebar iteration over ~150 catalog rows +
  // markdown embed) which is what dominates blog cold-load time.
  if (blogHtmlCache != null && blogHtmlCache.containsKey(slug)) {
    return Response.new(200).html(blogHtmlCache[slug])
      .header("Cache-Control", CACHE_BLOG)
      .header("Vary", "HX-Request")
  }
  // Fallback for warm-up race: render dynamically and seed the
  // cache so subsequent requests skip the work.
  var html = renderBlogPage.call(slug)
  if (html == null) return notFound.call("/blog/" + slug)
  if (blogHtmlCache == null) blogHtmlCache = {}
  blogHtmlCache[slug] = html
  return Response.new(200).html(html)
    .header("Cache-Control", CACHE_BLOG)
    .header("Vary", "HX-Request")
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
  return req.render(registry.get("docs.html"), withPath.call(req, ctx))
    .header("Cache-Control", CACHE_LANDING)
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
  return req.render(registry.get("package.html"), withPath.call(req, ctx))
    .header("Cache-Control", CACHE_PACKAGE)
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
  return req.render(registry.get("package_api.html"), withPath.call(req, ctx))
    .header("Cache-Control", CACHE_PACKAGE)
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
  // The route URL is `/packages/:name/readme` (no version), so
  // a republish doesn't invalidate a browser cache automatically.
  // `CACHE_PACKAGE` keeps `max-age=300` (matching the catalog's
  // 5-min refresh) plus `stale-while-revalidate=3600` so the
  // browser shows the prior body instantly on revisit and
  // refreshes in the background.
  r.header("Cache-Control", CACHE_PACKAGE)
  return r
}

// `/badge/version` — static "version: <hatchfile-version>"
// badge. Reads the deployed site's hatchfile once at boot,
// so the README's version badge tracks the live deploy
// without anyone hand-editing the literal each release.
// Cached aggressively because the version only changes when
// a new image rolls out (which invalidates the in-memory
// state anyway).
app.get("/badge/version") {|req|
  var r = Response.new(200)
  r.text(Badge.version)
  r.header("Content-Type", "image/svg+xml; charset=utf-8")
  r.header("Cache-Control", "public, max-age=3600, stale-while-revalidate=86400")
  return r
}

// `/badge/gha/:owner/:repo/:workflow` — branded GitHub Actions
// status badge. Replaces shields.io's render so the H favicon
// + brand palette stay in our hands; consumers (the hatch
// README, package READMEs that want a CI badge, dashboards)
// hit this once and get an SVG with the same look as the rest
// of hatch.wrenlift.com. `:workflow` accepts the workflow's
// filename (`regression.yml`) or numeric ID — both pass
// through to the GitHub API verbatim. `branch` defaults to
// `main`. We bound the cache at 60s so a re-run shows up
// quickly without hammering GitHub's rate limit.
app.get("/badge/gha/:owner/:repo/:workflow") {|req|
  var owner    = req.params["owner"]
  var repo     = req.params["repo"]
  var workflow = req.params["workflow"]
  var branch   = req.query.containsKey("branch") ? req.query["branch"] : "main"
  var svg = Badge.gha(owner, repo, workflow, branch)
  var r = Response.new(200)
  r.text(svg)
  r.header("Content-Type", "image/svg+xml; charset=utf-8")
  r.header("Cache-Control", "public, max-age=60, stale-while-revalidate=300")
  return r
}

// `/robots.txt` — explicit allow + sitemap pointer. Bots that
// hit the apex without a robots.txt fall back to default
// behavior; serving an explicit file gets us into Search
// Console + Bing Webmaster Tools' "robots OK" check, and
// pointing to the sitemap saves them a discovery hop.
app.get("/robots.txt") {|req|
  var body = "User-agent: *\nAllow: /\nSitemap: https://hatch.wrenlift.com/sitemap.xml\n"
  var r = Response.new(200)
  r.text(body)
  r.header("Cache-Control", "public, max-age=86400, stale-while-revalidate=604800")
  return r
}

// `/sitemap.xml` — every URL search engines should index.
// Pulled from `Catalog.allRecent` (one entry per package
// version at its latest `created_at`), `GUIDES`, `BLOGS`, plus
// the small set of static routes. Cached for 5 min via the
// route-level `Cache-Control` to match the catalog's refresh
// cadence — search engines re-fetch sitemaps on their own
// schedule (typically daily) and a 5-minute window keeps
// per-machine sitemap renders cheap without staleness.
app.get("/sitemap.xml") {|req|
  var lines = []
  lines.add("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
  lines.add("<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">")
  // Top-level routes — change frequency matters more than
  // priority for a small site.
  for (path in ["/", "/packages", "/blog"]) {
    lines.add("  <url><loc>https://hatch.wrenlift.com" + path + "</loc><changefreq>daily</changefreq></url>")
  }
  // Guides + blog posts are weekly-stable.
  for (slug in ["intro", "install", "hatchfile", "cli", "authoring"]) {
    lines.add("  <url><loc>https://hatch.wrenlift.com/guides/" + slug + "</loc><changefreq>weekly</changefreq></url>")
  }
  for (b in BLOGS) {
    lines.add("  <url><loc>https://hatch.wrenlift.com/blog/" + b["slug"] + "</loc><changefreq>weekly</changefreq></url>")
  }
  // Per-package pages — both /packages/:name (README view) and
  // /packages/:name/api. We include both because they have
  // independent canonical URLs and render different content.
  for (pkg in Catalog.allRecent) {
    var name = pkg["name"]
    lines.add("  <url><loc>https://hatch.wrenlift.com/packages/" + name + "</loc><changefreq>weekly</changefreq></url>")
    lines.add("  <url><loc>https://hatch.wrenlift.com/packages/" + name + "/api</loc><changefreq>weekly</changefreq></url>")
  }
  lines.add("</urlset>")
  var body = lines.join("\n")
  var r = Response.new(200)
  r.text(body)
  r.header("Content-Type", "application/xml; charset=utf-8")
  r.header("Cache-Control", "public, max-age=300, stale-while-revalidate=3600")
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
// Blog HTML warmer — see `blogHtmlCache` and `renderBlogPage`
// above. Pre-renders each blog post's full page (~14KB markdown
// embed + ~150-row sidebar iteration) once at boot so the first
// user visit doesn't pay the 2.6–6.6s template-render cost
// measured under prod load (`/blog/web` cold = 6.6s, warm =
// 2.6s before this change).
app.spawn(Fn.new { warmBlogs.call() })

app.listen("0.0.0.0:" + port)
