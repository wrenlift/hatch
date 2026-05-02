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
import "@hatch:proc"   for Proc
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
  /// Aborts on first-fetch failure — no point booting a packages
  /// page with no packages.
  static boot() {
    Catalog.db = Database.openMemory()
    Catalog.createSchema_()
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
    while (true) {
      // Wait first so the boot-time hydration owns the initial
      // table population; the loop kicks in for subsequent
      // refreshes only.
      Catalog.sleepYielding_(intervalSec)
      var f = Fiber.new { Catalog.refresh() }
      f.try()
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
    // The API renderer's per-process cache is keyed by
    // `name@version`, so a republish naturally produces a cache
    // miss for the bumped version — the stale entry just becomes
    // dead weight bounded by the number of distinct package
    // versions the site sees in a refresh window. Not worth a
    // cross-module reach to clear it explicitly.
  }

  /// Curl out to GitHub raw + parse. We use @hatch:proc rather
  /// than @hatch:http because @hatch:web ships @hatch:json@0.1.2
  /// while @hatch:http ships @hatch:json@0.1.0 — having both as
  /// transitives makes the bundler reject the encode.
  static fetchAndParse_() {
    var r = Proc.exec(["curl", "-fsSL", Catalog.INDEX_URL_, "--max-time", "10"])
    if (!r.ok) Fiber.abort("Catalog.refresh: curl failed: %(r.stderr)")
    var doc = Toml.parse(r.stdout)
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
  /// expands without a round-trip.
  static standardLibrary {
    return Catalog.db.query(
      "SELECT name, MAX(version) AS version FROM packages " +
      "WHERE name LIKE '@hatch:%' GROUP BY name ORDER BY name"
    )
  }

  /// Same shape, non-`@hatch:*` rows.
  static community {
    return Catalog.db.query(
      "SELECT name, MAX(version) AS version FROM packages " +
      "WHERE name NOT LIKE '@hatch:%' GROUP BY name ORDER BY name"
    )
  }

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

  /// Distinct-name count out of the catalog.
  static count {
    var row = Catalog.db.queryRow("SELECT COUNT(DISTINCT name) AS n FROM packages")
    return row["n"]
  }

  /// `{net: N, data: N, sys: N, dev: N}` — distinct-name counts per
  /// category, used to populate the filter chip badges.
  static byCategory {
    var rows = Catalog.db.query(
      "SELECT cat, COUNT(DISTINCT name) AS n FROM packages GROUP BY cat"
    )
    var out = { "net": 0, "data": 0, "sys": 0, "dev": 0 }
    for (row in rows) out[row["cat"]] = row["n"]
    return out
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
