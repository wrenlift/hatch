// hatch.wrenlift.com — Hatch landing page.
//
//   cd hatch/site
//   hatch run
//   # then open http://127.0.0.1:3000

import "@hatch:web"      for App, Static, Response
import "@hatch:template" for TemplateRegistry, FnLoader
import "@hatch:fs"       for Fs
import "@hatch:proc"     for Proc
import "./lib/catalog"   for Catalog

var app = App.new()

app.use(Static.serve("/assets", "./public/assets"))

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
// from the GitHub-hosted index.toml. Aborts on first-fetch
// failure — see Catalog.boot for why.
Catalog.boot()
System.print("catalog: %(Catalog.count) distinct packages loaded")

// Build the context any landing-page render needs. Used by both
// the full / route and the htmx fragment swap.
var pageContext = Fn.new {|packages, currentCat|
  return {
    "totalCount": Catalog.count,
    "counts":     Catalog.byCategory,
    "packages":   packages,
    "currentCat": currentCat
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

// Browse: every package in one grid. The landing page's "Featured"
// section caps at 12 recents; this is the unbounded view, same
// search/filter UX layered on top so the URL is sharable.
app.get("/docs") {|req|
  var q   = req.query.containsKey("q")   ? req.query["q"]   : ""
  var cat = req.query.containsKey("cat") ? req.query["cat"] : "all"
  var packages = (q == "" && cat == "all") ?
    Catalog.search("", "all", 200) :
    Catalog.search(q, cat, 200)
  var ctx = pageContext.call(packages, cat)
  return req.render(registry.get("docs.html"), ctx)
}

// Package detail. Header is hatchfile-derived (catalog row); body
// is the README rendered via htmx + marked.js client-side. The
// raw README markdown is fetched on demand by `/docs/:name/readme`
// so the initial render stays fast (single SQL row) and the
// network hop only happens once the user actually lands.
app.get("/docs/:name") {|req|
  var name = req.params["name"]
  var pkg = Catalog.byName(name)
  if (pkg == null) {
    var r = Response.new(404)
    r.html("<!doctype html><body style='font-family:system-ui;padding:48px'>" +
      "<h1>Package not found</h1><p>No package named <code>" + name + "</code> in the registry.</p>" +
      "<p><a href='/docs'>← Back to all packages</a></p></body>")
    return r
  }
  return req.render(registry.get("package.html"), {
    "pkg":         pkg,
    "readmeUrl":   Catalog.readmeUrl(pkg),
    "totalCount":  Catalog.count
  })
}

// htmx fragment endpoint: return the raw README markdown wrapped
// in a tiny <script type="text/markdown"> + a hyperscript hook
// that runs marked.parse() and replaces the host element. Keeping
// the markdown as the response body (rather than parsed HTML
// here) avoids a server-side markdown dependency for v1; the
// design renders client-side via marked.js loaded by the layout.
app.get("/docs/:name/readme") {|req|
  var name = req.params["name"]
  var pkg = Catalog.byName(name)
  if (pkg == null) {
    var r = Response.new(404)
    r.text("not found")
    return r
  }
  var url = Catalog.readmeUrl(pkg)
  if (url == null) {
    var r = Response.new(204)
    r.text("")
    return r
  }
  var fetch = Proc.exec(["curl", "-fsSL", url, "--max-time", "10"])
  var r = Response.new(fetch.ok ? 200 : 404)
  if (fetch.ok) {
    r.html(
      "<div id=\"readme-body\" data-markdown=\"true\">" +
      "<script type=\"text/markdown\" id=\"readme-md\">" + fetch.stdout + "</script>" +
      "<noscript><pre>" + fetch.stdout + "</pre></noscript>" +
      "</div>" +
      "<script>(function(){var el=document.getElementById('readme-md');" +
      "if(el && window.marked){var src=el.textContent;" +
      "var html=window.marked.parse(src);" +
      "var host=document.getElementById('readme-body');" +
      "host.innerHTML=html;}})();</script>"
    )
  } else {
    r.html("<p class=\"readme-empty\">No README found for <code>" + name + "</code>.</p>")
  }
  return r
}

app.listen("0.0.0.0:3000")
