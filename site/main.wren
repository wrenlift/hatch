// hatch.wrenlift.com — Hatch landing page.
//
//   cd hatch/site
//   hatch run
//   # then open http://127.0.0.1:3000

import "@hatch:web"      for App, Static, Response
import "@hatch:template" for TemplateRegistry, FnLoader
import "@hatch:fs"       for Fs
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

app.listen("0.0.0.0:3000")
