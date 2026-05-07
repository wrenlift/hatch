// lib/catalog.wren — package catalog backed by an in-memory SQLite
// table populated from the GitHub-hosted `index.toml`.
//
// Why this shape:
//   * GitHub raw is CDN-cached and free for read-heavy workloads;
//     we don't burden Supabase with one query per landing-page hit.
//   * Loading the rows into SQLite once means search + category
//     filter + most-recent ordering are real SQL — no Wren-side
//     List filtering at request time.
//   * Refreshing every 5 minutes is more than enough — the
//     `index.toml` mirror is rebuilt every 6 hours by
//     `sync-index.yml`, so the page is always fresher than the
//     source.

// `@hatch:sqlite` carries a native plugin (`libwlift_sqlite.dylib`)
// that needs the runtime's plugin-loading machinery — relative
// imports skip it, so we use the registered name. `@hatch:toml`
// + `@hatch:proc` are pure-Wren so either name shape would work;
// using the registry name keeps imports uniform.
import "@hatch:toml"   for Toml
import "@hatch:sqlite" for Database
import "@hatch:http"   for Http
import "@hatch:time"   for Clock

/// Public API:
///
///   Catalog.boot()                    // open db + initial fetch
///   Catalog.refresh()                 // rebuild table (single shot)
///   Catalog.count                     // distinct-name count
///   Catalog.recent(limit)             // most recent rows
///   Catalog.search(q, cat, limit)     // SQL search + filter
///   Catalog.byCategory                // {"net": N, "data": N, ...}
class Catalog {
  static INDEX_URL_ { "https://raw.githubusercontent.com/wrenlift/hatch/main/index.toml" }

  /// Color tokens picked to match the design's category chips —
  /// kept on the data layer so the templates stay dumb (a card
  /// just renders `p.catColor`).
  static CAT_COLORS_ { {
    "net":  "#B8D4E3",
    "data": "#F4C24A",
    "sys":  "#8FAE6A",
    "dev":  "#D97A2B"
  } }

  static CAT_LABELS_ { {
    "net":  "networking",
    "data": "data",
    "sys":  "system",
    "dev":  "dev tools"
  } }

  // Module-level state. We open the db once on boot and keep the
  // handle for the life of the process — sqlite-wasm-rs' memory
  // VFS can't survive a close+reopen across our refresh fiber.
  static db { __db }
  static db=(value) { __db = value }

  /// Open the in-memory db, build the schema, fetch + populate.
  /// Seeds the aggregate cache with empty defaults BEFORE the
  /// first fetch so a flaky boot (DNS not ready, GitHub blip)
  /// still leaves the page renderable — `count`, `byCategory`,
  /// `standardLibrary`, `community` are all read straight from
  /// the cache and would otherwise return `null` if `refresh`
  /// aborted before populating them.
  static boot() {
    Catalog.db = Database.openMemory()
    Catalog.createSchema_()
    __cachedCount = 0
    __cachedByCategory = { "net": 0, "data": 0, "sys": 0, "dev": 0 }
    __cachedStdlib = []
    __cachedCommunity = []
    Catalog.refresh()
  }

  /// Background fiber body — re-fetches `index.toml` on a fixed
  /// cadence so the in-memory SQLite reflects upstream changes
  /// without a server restart. Registered via `app.spawn`.
  ///
  /// `intervalSec` is the wall-clock interval between refreshes
  /// (5 minutes by default). The yielding sleep cooperates with
  /// the scheduler so request fibers keep running between refresh
  /// ticks. A failed refresh logs and keeps the previous table —
  /// the last good snapshot stays live until the next attempt.
  static refreshLoop() { Catalog.refreshLoop(300) }
  static refreshLoop(intervalSec) {
    // Stash the interval into a class-level static rather than
    // passing it through the loop body. The AOT SM transform
    // currently misses a tail-duplication remap on the
    // refresh-success loop-back terminator (bb6 in this
    // function's MIR) — the `Branch(bb1, [v_intervalSec, v_this])`
    // args keep the original `BlockParam(1)` ValueId, so on
    // resume the dispatcher hits bb1's block param 0 with no
    // dominating definition and the parameter decays to a
    // denormal-zero. Reading from a static (`__refreshInterval`)
    // sidesteps the broken save/load path. Remove this hop once
    // the SM transform's selective-clone walker recurses
    // through non-cloned post-yield-only blocks (see
    // memory/project_aot_yield_architecture.md).
    __refreshInterval = intervalSec
    while (true) {
      // Wait first so the boot-time hydration owns the initial
      // table population; the loop kicks in for subsequent
      // refreshes only.
      Catalog.sleepYielding_(__refreshInterval)
      var f = Fiber.new { Catalog.refresh() }
      Catalog.driveFiber_(f)
      if (f.error != null) {
        System.print("[catalog] refresh failed: %(f.error)")
      } else {
        System.print("[catalog] refreshed (%(Catalog.count) packages)")
      }
    }
  }

  /// Cooperative sleep — yields to the scheduler each tick until
  /// `seconds` of wall-clock time have elapsed. Doesn't block the
  /// thread, so other fibers (request handlers, SSE writers) run
  /// freely while we wait.
  static sleepYielding_(seconds) {
    var deadline = Clock.mono + seconds
    while (Clock.mono < deadline) Fiber.yield()
  }

  /// Drive a child fiber to completion, yielding to the scheduler
  /// between resumes whenever the child yields. Required because
  /// `Fiber.yield()` deep inside a `.try()`'d fiber doesn't
  /// resume across the nested boundary on its own — the call to
  /// `try()` returns at the first yield with `isDone == false`,
  /// and the caller would treat a half-finished fiber as the
  /// final result. We pump it ourselves: `try()` runs until the
  /// next yield, we yield ourselves to the scheduler so other
  /// fibers tick, then resume the child on our next turn.
  static driveFiber_(f) {
    while (!f.isDone) {
      f.try()
      if (!f.isDone) Fiber.yield()
    }
    return f
  }

  /// Same shape as `driveFiber_` but captures and returns the
  /// fiber's final value (the value the body returns when it
  /// completes). The plain `driveFiber_` discards each `try()`
  /// return, which is fine for fire-and-forget fibers but loses
  /// the result for fibers that wrap a value-returning call —
  /// e.g. `Fiber.new { Http.get(url) }.try()` returns whatever
  /// the FIRST yield emitted, not the final `Response`. Without
  /// this pump, a slow Supabase fetch that yields once mid-read
  /// hands the caller a half-baked yield value (often a
  /// truncated string buffer or null), the request renderer
  /// embeds it as the body, and the template parser aborts
  /// downstream with `unterminated {% if %}` because it ran out
  /// of input mid-block.
  static driveFiberValue_(f) {
    var last = null
    while (!f.isDone) {
      last = f.try()
      if (!f.isDone) Fiber.yield()
    }
    return last
  }

  static createSchema_() {
    Catalog.db.execute(
      "CREATE TABLE packages (" +
      "  name        TEXT NOT NULL," +
      "  version     TEXT NOT NULL," +
      "  git         TEXT," +
      "  description TEXT," +
      "  docs_url    TEXT," +
      "  readme_url  TEXT," +
      "  cat         TEXT NOT NULL," +
      "  created_at  TEXT NOT NULL," +
      "  PRIMARY KEY (name, version)" +
      ")"
    )
    Catalog.db.execute("CREATE INDEX idx_packages_name    ON packages(name)")
    Catalog.db.execute("CREATE INDEX idx_packages_cat     ON packages(cat)")
    Catalog.db.execute("CREATE INDEX idx_packages_created ON packages(created_at DESC)")
  }

  /// One-shot refresh. Wipes the table and bulk-loads from
  /// index.toml inside a transaction so partial-fetch failures
  /// can't leave the page with a half-empty grid.
  ///
  /// Network fetch (the slow part — 100s of ms over the link)
  /// happens BEFORE the transaction; the table swap itself is a
  /// tight `DELETE` + N `INSERT`s that runs in well under a
  /// millisecond. Keeping the slow work outside the transaction
  /// minimises the window during which serve fibers querying the
  /// catalog block on the SQLite single-connection serialisation.
  static refresh() {
    var rows = Catalog.fetchAndParse_()
    Catalog.db.transaction {
      Catalog.db.execute("DELETE FROM packages")
      for (row in rows) {
        Catalog.db.execute(
          "INSERT INTO packages (name, version, git, description, docs_url, readme_url, cat, created_at) " +
          "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
          [row["name"], row["version"], row["git"], row["description"],
           row["docs_url"], row["readme_url"], row["cat"], row["created_at"]]
        )
      }
    }
    Catalog.rebuildAggregateCache_()
    // Drop the local `rows` reference so the parsed-toml + raw
    // network response chain is unreachable before we ask the GC
    // to sweep. Without this the `var rows = …` binding keeps the
    // entire toml document tree alive across the next request
    // window — ~hundreds of Maps with key/value strings stay
    // pinned, which under Fly's 768mb budget is enough to push
    // us over after one refresh + one /api hit.
    rows = null
    // Explicit major-GC trigger. The catalog refresh allocates
    // through several large transient buffers (curl stdout
    // ~tens of KB, toml parse tree, the in-flight `Vec<Value>`
    // → `ObjList` for the bulk INSERT params, the four
    // aggregate-cache rebuild query results) and overwrites the
    // module-level `__cachedStdlib / __cachedCommunity / …`
    // statics — the previous refresh's cached lists become
    // garbage all at once. Without a manual sweep here the
    // wren_lift nursery (default 64mb on Fly via
    // `WLIFT_GC_NURSERY_MB=64`) trickles those into the mature
    // generation while the next /api request piles on more
    // allocations, and Fly's OOM killer reaps the process at
    // ~620mb anon-rss before the next nursery fill triggers a
    // major collection on its own. Calling `System.gc()` here
    // amortises the cost into the once-per-five-minutes refresh
    // boundary instead of letting it ride.
    System.gc()
    // The API renderer's per-process cache is keyed by
    // `name@version`, so a republish naturally produces a cache
    // miss for the bumped version — the stale entry just becomes
    // dead weight bounded by the number of distinct package
    // versions the site sees in a refresh window. Not worth a
    // cross-module reach to clear it explicitly.
  }

  /// Compute the per-render aggregates (`count`, `byCategory`,
  /// `standardLibrary`, `community`) once, right after the table
  /// rebuild, and stash them in module-level statics. Every docs
  /// page render needs all four — without this cache each request
  /// fires 4 SQL queries against data that only changes on a
  /// 5-minute refresh boundary.
  static rebuildAggregateCache_() {
    var countRow = Catalog.db.queryRow(
      "SELECT COUNT(DISTINCT name) AS n FROM packages"
    )
    __cachedCount = countRow == null ? 0 : countRow["n"]

    var catRows = Catalog.db.query(
      "SELECT cat, COUNT(DISTINCT name) AS n FROM packages GROUP BY cat"
    )
    var byCat = { "net": 0, "data": 0, "sys": 0, "dev": 0 }
    for (row in catRows) byCat[row["cat"]] = row["n"]
    __cachedByCategory = byCat

    __cachedStdlib = Catalog.db.query(
      "SELECT name, MAX(version) AS version FROM packages " +
      "WHERE name LIKE '@hatch:%' GROUP BY name ORDER BY name"
    )
    __cachedCommunity = Catalog.db.query(
      "SELECT name, MAX(version) AS version FROM packages " +
      "WHERE name NOT LIKE '@hatch:%' GROUP BY name ORDER BY name"
    )
  }

  /// Curl out to GitHub raw + parse. We use @hatch:proc rather
  /// `@hatch:http` reads cooperate with the scheduler so the
  /// rest of the box keeps serving while the GitHub raw fetch
  /// completes. The earlier `Proc.run` shim was kept while
  /// `@hatch:web@0.1.5` (json@0.1.2) and `@hatch:http@0.3.0`
  /// (json@0.1.0) couldn't co-exist in one bundle;
  /// `@hatch:http@0.3.2` moved to json@0.1.2 so the diamond
  /// resolves.
  static fetchAndParse_() {
    var fib = Fiber.new {
      Http.get(Catalog.INDEX_URL_, { "timeoutMs": 10000, "followRedirects": true })
    }
    // Drive the fiber to completion — `Http.get` yields
    // cooperatively while waiting for the network and
    // `fib.try()` would otherwise return at the first yield with
    // a partial/null sentinel rather than the final `Response`.
    // See `Catalog.driveFiberValue_` for the failure mode this
    // prevents (truncated body → template parser abort).
    var resp = Catalog.driveFiberValue_(fib)
    if (fib.error != null || resp == null || !resp.ok || resp.body == null) {
      var err = fib.error != null ? fib.error : (resp == null ? "no response" : "%(resp.status)")
      Fiber.abort("Catalog.refresh: index.toml fetch failed: %(err)")
    }
    var doc = Toml.parse(resp.body)
    var packages = doc["packages"]
    if (!(packages is Map)) Fiber.abort("Catalog.refresh: unexpected index.toml shape")
    var out = []
    for (key in packages.keys) {
      var row = packages[key]
      var name = row["name"]
      var description = row.containsKey("description") ? row["description"] : ""
      out.add({
        "name":        name,
        "version":     row["version"],
        "git":         row.containsKey("git") ? row["git"] : "",
        "description": description,
        "docs_url":    row.containsKey("docs_url")   ? row["docs_url"]   : null,
        "readme_url":  row.containsKey("readme_url") ? row["readme_url"] : null,
        "cat":         Catalog.categorize_(name, description),
        "created_at":  row.containsKey("created_at") ? row["created_at"] : ""
      })
    }
    return out
  }

  /// Heuristic on package name + description. Errs on the side of
  /// "dev" (the catch-all) so unknown names don't all land under
  /// "data" or "system" arbitrarily. Wren's String has no
  /// `lowercase` method; we ASCII-lowercase by hand since every
  /// package name we care about is ASCII anyway.
  static categorize_(name, desc) {
    var n = Catalog.lower_(name)
    var s = Catalog.lower_(name + " " + (desc == null ? "" : desc))

    var netKeywords  = ["http", "websocket", "socket", "tcp", "udp", "dns", "url", "https"]
    var dataKeywords = ["json", "yaml", "toml", "csv", "sqlite", "regex", "hash",
                         "crypto", "uuid", "tar", "zip", "image"]
    var sysKeywords  = ["fs", "io", "os", "path", "proc", "time", "datetime",
                         "log", "fmt", "events", "audio", "physics", "gpu",
                         "window", "game", "assets", "random"]

    // Name-based pass first — the package name is a stronger
    // signal than the description and prevents `@hatch:gpu`
    // landing in `data` because its blurb mentions "Buffers".
    for (kw in netKeywords)  if (n.contains(kw)) return "net"
    for (kw in dataKeywords) if (n.contains(kw)) return "data"
    for (kw in sysKeywords)  if (n.contains(kw)) return "sys"

    // Fallback: description-level scan.
    for (kw in netKeywords)  if (s.contains(kw)) return "net"
    for (kw in dataKeywords) if (s.contains(kw)) return "data"
    for (kw in sysKeywords)  if (s.contains(kw)) return "sys"

    return "dev"
  }

  /// ASCII-lowercase a string. Maps `A`..`Z` (0x41..0x5A) to
  /// `a`..`z` (0x61..0x7A). Non-ASCII bytes pass through.
  static lower_(s) {
    var out = ""
    for (i in 0...s.count) {
      var c = s.bytes[i]
      if (c >= 65 && c <= 90) c = c + 32
      out = out + String.fromByte(c)
    }
    return out
  }

  // -- Public read API --

  /// Distinct `@hatch:*` packages (latest version per name,
  /// alphabetical). The sidebar template shows the first
  /// `SIDEBAR_PREVIEW` rows and tucks the rest behind a "Show all"
  /// toggle — we still hand back the full list so the toggle
  /// expands without a round-trip. Served from the cache rebuilt
  /// each refresh; see `rebuildAggregateCache_`.
  static standardLibrary { __cachedStdlib }

  /// Same shape, non-`@hatch:*` rows.
  static community { __cachedCommunity }

  /// Latest row for a single package by exact name. Returns `null`
  /// if no row matches — the docs page surfaces that as a 404.
  /// Used by the `/docs/:name` route; the row is fed straight into
  /// the same hatchfile-derived header partial the listing uses,
  /// so the field set must stay parallel to `decorate_`'s output.
  static byName(name) {
    var rows = Catalog.db.query(
      "SELECT * FROM packages WHERE name = ? " +
      "ORDER BY created_at DESC LIMIT 1",
      [name]
    )
    var decorated = Catalog.decorate_(rows)
    if (decorated.count == 0) return null
    return decorated[0]
  }

  /// Map a catalog row to a public README URL. Resolution order:
  ///
  ///   1. `pkg.readme_url` set → use verbatim. This is the
  ///      Supabase Storage URL `hatch publish` writes after
  ///      uploading the package's README at publish time.
  ///      Forge-agnostic: works the same for GitHub, GitLab,
  ///      Bitbucket, self-hosted Forgejo, anything.
  ///   2. `pkg.readme` is an absolute URL → use verbatim
  ///      (legacy hatchfiles that point at an external host).
  ///   3. `pkg.readme` is a relative path → resolve against
  ///      `pkg.git` via the host's raw-URL convention. Today
  ///      only GitHub is wired up; non-GitHub legacy rows fall
  ///      to (4).
  ///   4. None of the above → `null` (the route renders the
  ///      empty-state placeholder).
  ///
  /// Once every active publisher republishes through the v0.1.7+
  /// flow, paths (2) and (3) are quiet; only (1) fires.
  static readmeUrl(row) {
    var url = row.containsKey("readme_url") ? row["readme_url"] : null
    if (url != null && url != "") return url

    var readme = row.containsKey("readme") ? row["readme"] : null
    if (readme != null && readme != "") {
      if (readme.startsWith("http://") || readme.startsWith("https://")) {
        return readme
      }
      var base = Catalog.gitRawBase_(row)
      if (base == null) return null
      var path = readme.startsWith("/") ? readme : "/" + readme
      return base + path
    }
    var base = Catalog.gitRawBase_(row)
    if (base == null) return null
    return base + "/README.md"
  }

  /// Build a `<host-raw>/<branch>` prefix from the row's `git`
  /// URL. Today only GitHub is wired up — other forges (GitLab
  /// `/-/raw/`, Gitea `/raw/branch/`) need their own arms. Returns
  /// `null` for unknown hosts so the caller falls through to
  /// "no README" rather than emitting a broken URL.
  static gitRawBase_(row) {
    var git = row.containsKey("git") ? row["git"] : ""
    if (git == null || git == "") return null
    if (git.endsWith(".git")) git = git[0..(git.count - 5)]
    if (git.startsWith("https://github.com/")) {
      return git.replace("https://github.com/", "https://raw.githubusercontent.com/") + "/main"
    }
    return null
  }

  /// Fetch the package's README, wrap it in `wrapReadme_`'s
  /// marked.js + CodeMirror harness, and return the resulting
  /// HTML. Returns `null` when there's no README to render
  /// (catalog row has no readme_url + no derivable raw URL, or
  /// the network fetch fails).
  ///
  /// Per-process cache keyed by `name@version@url` so successive
  /// requests for the same package skip the curl shell-out + the
  /// markdown-wrap step. The catalog refresh fiber bumps
  /// `version` on republish, so the cache key changes naturally;
  /// stale entries become bounded dead weight, not a leak.
  static fetchReadmeHtml(pkg) {
    var url = Catalog.readmeUrl(pkg)
    if (url == null) return null

    if (__readmeCache == null) __readmeCache = {}
    var name = pkg["name"]
    var version = pkg.containsKey("version") ? pkg["version"] : ""
    var key = "%(name)@%(version)@%(url)"
    if (__readmeCache.containsKey(key)) return __readmeCache[key]

    // `@hatch:http` reads cooperate with the scheduler so a slow
    // Supabase round-trip yields back to other request fibers
    // instead of blocking the machine. Previously this shelled
    // out via `Proc.exec(curl)` because `@hatch:web@0.1.5` and
    // `@hatch:http@0.3.0` shipped incompatible `@hatch:json`
    // versions; that diamond resolves now that
    // `@hatch:http@0.3.2` is on `@hatch:json@0.1.2`.
    var fib = Fiber.new {
      Http.get(url, { "timeoutMs": 10000, "followRedirects": true })
    }
    // Pump the fiber to completion — see `driveFiberValue_`
    // for why a single `fib.try()` returns a partial value.
    var resp = Catalog.driveFiberValue_(fib)
    if (fib.error != null || resp == null || !resp.ok || resp.body == null || resp.body.count == 0) {
      var miss = "<p class=\"readme-empty\">No README found for <code>" + name + "</code>.</p>"
      Catalog.storeReadme_(key, miss)
      return miss
    }
    var html = Catalog.wrapReadme_(resp.body, name)
    Catalog.storeReadme_(key, html)
    return html
  }

  /// Cache cap matching `Api.cacheCap_`. See `Api.store_` for
  /// the rationale; same FIFO bound applies here.
  static readmeCacheCap_ { 64 }

  /// FIFO-bounded insert into `__readmeCache`. Mirror of
  /// `Api.store_` — see comment there for why FIFO is fine vs
  /// strict LRU for this access pattern.
  static storeReadme_(key, value) {
    if (__readmeCache == null) __readmeCache = {}
    if (__readmeCacheKeys == null) __readmeCacheKeys = []
    if (!__readmeCache.containsKey(key)) __readmeCacheKeys.add(key)
    __readmeCache[key] = value
    while (__readmeCacheKeys.count > Catalog.readmeCacheCap_) {
      var evict = __readmeCacheKeys.removeAt(0)
      if (evict != null) __readmeCache.remove(evict)
    }
  }

  /// Walk every catalog row and pre-populate `__readmeCache` for
  /// each. Called from a background fiber spawned at boot so the
  /// first user visit to `/packages/:name/readme` doesn't pay the
  /// curl + wrap cost on the request fiber. Yields between
  /// packages; misses during warm-up still work normally.
  ///
  /// Pulls the latest version per package directly from the
  /// SQLite table — the same shape `recent` / `byName` produce —
  /// so we warm exactly what the routes will resolve. Skips
  /// missing-readme rows silently (they cache as a stub html
  /// the first time anyway).
  static warmReadmes() {
    for (pkg in Catalog.allRecent) {
      Catalog.fetchReadmeHtml(pkg)
      Fiber.yield()
    }
  }

  /// Wrap raw README markdown in the inline-script harness that
  /// runs `marked.parse` client-side and then upgrades any
  /// `language-wren` fences via `window.mountWrenCode` (CodeMirror,
  /// gutter-less, same theme as the playground). The `<noscript>`
  /// fallback shows the raw markdown so JS-disabled clients still
  /// see the content. Both the local-FS and remote-fetch branches
  /// of the route call this so the swap shape stays identical.
  static wrapReadme_(markdown, name) {
    // Wren's parser ends a `return` statement at the first
    // newline if there's no expression on the same line — a
    // bare `return` followed by a multi-line concat returns
    // `null`. Keeping the first segment on the return line
    // anchors the expression so the trailing `+` continuations
    // get folded in.
    var html = "<div id=\"readme-body\" data-markdown=\"true\">"
    html = html + "<script type=\"text/markdown\" id=\"readme-md\">" + markdown + "</script>"
    html = html + "<noscript><pre>" + markdown + "</pre></noscript>"
    html = html + "</div>"
    html = html + "<script>(function(){var el=document.getElementById('readme-md');"
    html = html + "if(el && window.marked){var src=el.textContent;"
    html = html + "var html=window.marked.parse(src);"
    html = html + "var host=document.getElementById('readme-body');"
    html = html + "host.innerHTML=html;"
    html = html + "if(window.mountWrenCode){window.mountWrenCode(host);}"
    html = html + "else{var t=setInterval(function(){"
    html = html + "if(window.mountWrenCode){clearInterval(t);window.mountWrenCode(host);}"
    html = html + "},80);setTimeout(function(){clearInterval(t);},5000);}"
    // Build the right-rail "On this page" TOC from the rendered
    // h2 + h3 elements. Each gets a slug id (lowercase, dashed)
    // so anchors work; h3 entries indent under their owning h2.
    // IntersectionObserver flags the heading currently in view —
    // its TOC entry gets `.active` for the toast highlight.
    html = html + "var toc=document.getElementById('readme-toc');"
    html = html + "if(toc){toc.innerHTML='';"
    html = html + "var slug=function(s){return (s||'').toLowerCase().replace(/[^a-z0-9]+/g,'-').replace(/^-|-$/g,'');};"
    html = html + "var heads=host.querySelectorAll('h2,h3');"
    html = html + "var entries=[];"
    html = html + "heads.forEach(function(h){"
    html = html + "  var id=h.id||slug(h.textContent);if(!id)return;h.id=id;"
    html = html + "  var li=document.createElement('li');"
    html = html + "  if(h.tagName==='H3')li.className='indent';"
    html = html + "  var a=document.createElement('a');a.href='#'+id;a.textContent=h.textContent.trim();"
    html = html + "  li.appendChild(a);toc.appendChild(li);"
    html = html + "  entries.push({el:h,link:a});"
    html = html + "});"
    html = html + "if(entries.length && 'IntersectionObserver' in window){"
    html = html + "  var byEl=new Map(entries.map(function(e){return [e.el,e.link];}));"
    html = html + "  var visible=new Set();"
    html = html + "  var io=new IntersectionObserver(function(items){"
    html = html + "    items.forEach(function(it){"
    html = html + "      if(it.isIntersecting)visible.add(it.target);else visible.delete(it.target);"
    html = html + "    });"
    html = html + "    var first=null;"
    html = html + "    entries.forEach(function(e){if(!first && visible.has(e.el))first=e.el;});"
    html = html + "    if(!first && entries[0])first=entries[0].el;"
    html = html + "    entries.forEach(function(e){e.link.classList.toggle('active',e.el===first);});"
    html = html + "  },{rootMargin:'-80px 0px -70% 0px',threshold:0});"
    html = html + "  entries.forEach(function(e){io.observe(e.el);});"
    html = html + "  if(entries[0])entries[0].link.classList.add('active');"
    html = html + "}}"
    html = html + "}})();</script>"
    return html
  }

  /// Distinct-name count out of the catalog. Cached per refresh.
  static count { __cachedCount }

  /// `{net: N, data: N, sys: N, dev: N}` — distinct-name counts per
  /// category, used to populate the filter chip badges. Cached per
  /// refresh.
  static byCategory { __cachedByCategory }

  /// Every package, latest version each — same shape as `recent`
  /// but unbounded. Used by the boot-time API + readme warmers
  /// in `main.wren` so they iterate exactly the rows the
  /// `/packages/:name/api` and `/packages/:name/readme` routes
  /// will resolve, with `docs_url` / `readme_url` already
  /// attached.
  static allRecent {
    var rows = Catalog.db.query(
      "SELECT * FROM packages WHERE (name, created_at) IN " +
      "  (SELECT name, MAX(created_at) FROM packages GROUP BY name) " +
      "ORDER BY name"
    )
    return Catalog.decorate_(rows)
  }

  /// Most recent version of each package, newest first.
  static recent(limit) {
    var rows = Catalog.db.query(
      "SELECT * FROM packages WHERE (name, created_at) IN " +
      "  (SELECT name, MAX(created_at) FROM packages GROUP BY name) " +
      "ORDER BY created_at DESC LIMIT ?",
      [limit]
    )
    return Catalog.decorate_(rows)
  }

  /// Free-text search + optional category filter. `q` and `cat`
  /// can be null/empty — empty matches everything in that axis.
  static search(query, cat, limit) {
    var hasQ   = query != null && query != ""
    var hasCat = cat   != null && cat   != "" && cat != "all"

    var sql =
      "SELECT * FROM packages WHERE (name, created_at) IN " +
      "  (SELECT name, MAX(created_at) FROM packages GROUP BY name)"
    var params = []

    if (hasQ) {
      sql = sql + " AND (LOWER(name) LIKE ? OR LOWER(description) LIKE ?)"
      var pat = "%" + Catalog.lower_(query) + "%"
      params.add(pat)
      params.add(pat)
    }

    if (hasCat) {
      sql = sql + " AND cat = ?"
      params.add(cat)
    }

    sql = sql + " ORDER BY created_at DESC LIMIT ?"
    params.add(limit)

    return Catalog.decorate_(Catalog.db.query(sql, params))
  }

  /// Attach view-helper fields that the template can splice in
  /// without further computation. Keeps the renderer dumb.
  static decorate_(rows) {
    var colors = Catalog.CAT_COLORS_
    var labels = Catalog.CAT_LABELS_
    var out = []
    for (row in rows) {
      var cat = row["cat"]
      var copy = {}
      for (k in row.keys) copy[k] = row[k]
      copy["catColor"]    = colors.containsKey(cat) ? colors[cat] : "#EFDDA8"
      copy["catLabel"]    = labels.containsKey(cat) ? labels[cat] : cat
      copy["relativeAge"] = Catalog.shortDate_(row["created_at"])
      copy["descriptionHtml"] = Catalog.inlineCode_(row["description"])
      out.add(copy)
    }
    return out
  }

  /// Convert a plain-text description into HTML, mapping
  /// backtick-quoted spans to `<code>…</code>` chips. The rest of
  /// the string is HTML-escaped so a `<` or `&` in the wild
  /// description doesn't break the page. Output is consumed via
  /// `{{ … | raw }}` in the lede template.
  ///
  /// Pairing rule: a backtick opens a chip, the next backtick
  /// closes it. Unmatched trailing backticks pass through as
  /// literals so an obvious typo doesn't swallow content.
  static inlineCode_(s) {
    if (s == null || s == "") return ""
    var out = ""
    var inCode = false
    var buf = ""
    for (i in 0...s.count) {
      var ch = s[i]
      if (ch == "`") {
        if (inCode) {
          out = out + "<code>" + Catalog.htmlEscape_(buf) + "</code>"
          buf = ""
          inCode = false
        } else {
          out = out + Catalog.htmlEscape_(buf)
          buf = ""
          inCode = true
        }
      } else {
        buf = buf + ch
      }
    }
    // Trailing buffer: if we were still inside a code span (no
    // closer), spit it back out as literal text with the leading
    // backtick restored.
    if (inCode) {
      out = out + "`" + Catalog.htmlEscape_(buf)
    } else {
      out = out + Catalog.htmlEscape_(buf)
    }
    return out
  }

  /// Minimal HTML escaper for `<`, `>`, `&`, `"`, `'`.
  static htmlEscape_(s) {
    if (s == null) return ""
    var r = s.replace("&", "&amp;")
    r = r.replace("<", "&lt;")
    r = r.replace(">", "&gt;")
    r = r.replace("\"", "&quot;")
    r = r.replace("'", "&#39;")
    return r
  }

  /// "2026-04-30T19:31:51.372215+00:00" -> "Apr 30, 2026".
  /// Cheap to compute — we re-do this per response rather than
  /// caching since the catalog is small.
  static shortDate_(iso) {
    if (iso == null || iso == "") return ""
    // ISO 8601 always starts with YYYY-MM-DDT...
    var m = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    var year  = Num.fromString(iso[0..3])
    var month = Num.fromString(iso[5..6])
    var day   = Num.fromString(iso[8..9])
    if (year == null || month == null || day == null) return iso
    if (month < 1 || month > 12) return iso
    return "%(m[month - 1]) %(day), %(year)"
  }
}
