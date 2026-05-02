// lib/api.wren — fetch the docs JSON for a package and decorate
// it for the template renderer.
//
// All HTML is produced by templates (see `views/partials/_api_*.html`),
// not string concat — keeping the renderer in one declarative
// place + letting `@hatch:template`'s slot / fragment machinery
// stay the source of truth for layout.
//
// Source of truth: the catalog row's `docs_url` column, populated
// at publish time by `hatch publish` uploading the per-package
// docs JSON to Supabase Storage. The site curls the URL at
// request time; an in-process cache keyed by `name@version`
// avoids re-fetching the same JSON twice between catalog
// refreshes (the catalog refresh fiber bumps `version` when a
// republish lands).

import "@hatch:json" for JSON
import "@hatch:http" for Http

class Api {
  /// Per-process cache keyed by `name@version` → parsed-and-
  /// decorated module list. Cleared every time the catalog
  /// refreshes (see `Catalog.refresh`). Bounded only by the
  /// number of distinct package versions the site sees in a
  /// given refresh window; small enough to leave unbounded.
  static cache_ { __cache }

  /// Public entry point. Returns the parsed `Vec<ModuleDoc>` so
  /// the template can iterate over it directly. Each member is
  /// decorated with the verb pill data the template needs.
  static fetch(pkg) {
    if (__cache == null) __cache = {}
    var name = pkg["name"]
    var version = pkg.containsKey("version") ? pkg["version"] : ""
    var key = "%(name)@%(version)"
    if (__cache.containsKey(key)) return __cache[key]

    var json = Api.fetchJson_(pkg)
    if (json == null) {
      __cache[key] = null
      return null
    }
    var modules = JSON.parse(json)
    if (!(modules is List) || modules.count == 0) {
      __cache[key] = null
      return null
    }
    var decorated = Api.decorate_(modules, null)
    __cache[key] = decorated
    return decorated
  }

  /// Drop everything cached. Called from `Catalog.refresh` when
  /// the package set rolls forward — a republish bumps `version`
  /// so the cache key changes anyway, but blowing the cache
  /// keeps memory bounded against a runaway publisher loop.
  static clearCache() {
    __cache = {}
  }

  /// Walk a list of catalog rows and pre-populate the cache for
  /// each. Called from a background fiber spawned at boot (see
  /// `main.wren`) so the first user visit to a `/packages/:name/api`
  /// route doesn't pay the curl + JSON parse + decorate cost on the
  /// request fiber. `@hatch:gpu` in particular has a multi-hundred-
  /// member docs JSON that takes ~20s to walk on a cold interpreter
  /// — we'd rather amortise that into one boot-time pass per machine
  /// than make every cold visitor wait.
  ///
  /// Yields between packages so request fibers keep handling traffic
  /// while the warm-up runs. Cache misses still work normally during
  /// warm-up (the request fiber populates the same cache the warmer
  /// is filling).
  static warmAll(packages) {
    for (pkg in packages) {
      Api.fetch(pkg)
      Fiber.yield()
    }
  }

  static fetchJson_(pkg) {
    if (!pkg.containsKey("docs_url")) return null
    var url = pkg["docs_url"]
    if (url == null || url == "") return null
    // `@hatch:http` runs against `@hatch:socket` with
    // fiber-cooperative reads, so a slow Supabase fetch yields
    // back to the scheduler instead of blocking the request
    // fiber's whole machine. The earlier `Proc.exec(curl)` shim
    // was kept while @hatch:web@0.1.5 (json@0.1.2) and
    // @hatch:http@0.3.0 (json@0.1.0) couldn't co-exist in one
    // bundle; @hatch:http@0.3.2 moved to json@0.1.2 so the
    // diamond resolves and we can drop the shell-out.
    //
    // The drive-loop here is load-bearing: a plain `fib.try()`
    // returns at the FIRST yield with the partial value the
    // child emitted, not the final `Response`. `Http.get`
    // yields several times during a slow Supabase fetch, so
    // a single try() gets the caller a half-baked sentinel —
    // typically a string fragment of the response body. The
    // template parser downstream sees a truncated docs JSON
    // and aborts mid-`{% if %}` block ("unterminated {% if %}"
    // in fly logs).
    var fib = Fiber.new {
      Http.get(url, { "timeoutMs": 5000, "followRedirects": true })
    }
    var resp = null
    while (!fib.isDone) {
      resp = fib.try()
      if (!fib.isDone) Fiber.yield()
    }
    if (fib.error != null || resp == null) return null
    if (!resp.ok) return null
    var body = resp.body
    if (body == null || body.count == 0) return null
    return body
  }

  /// Walk the parsed modules and attach view-helper fields the
  /// template uses. Returns the list verbatim; nested maps are
  /// mutated in place. Per-member helpers:
  ///   tag      — "FN" / "GET" / "SET" / "NEW" / "CL"
  ///   tagClass — matching CSS class ("api-tag-fn", …)
  ///   docHtml  — escaped + backtick-rewritten doc prose,
  ///              ready to drop in via `{{{ … }}}`.
  static decorate_(modules, workspaceDir) {
    for (m in modules) {
      // `docMd` carries the raw markdown the docs collector emits
      // (file-leading `//` block for modules, `///` blocks for
      // classes / members). The template embeds each as a
      // `<script type="text/markdown">` and the inline hook in
      // `package_api.html` runs marked.parse + mountWrenCode
      // after the page mounts — same pipeline
      // `Catalog.wrapReadme_` uses for READMEs.
      m["docMd"] = Api.s_(m, "doc")
      m["slug"]  = "mod-" + Api.slug_(m["name"])
      var classes = Api.l_(m, "classes")
      for (c in classes) {
        c["slug"]  = "cl-" + Api.slug_(c["name"])
        c["docMd"] = Api.s_(c, "doc")
        var members = Api.l_(c, "members")
        // Bucket into the four categories the design groups
        // members under: Constructor, Fields, Getters/Setters,
        // Functions. Each entry decorates `tag` / `tagClass` /
        // `docHtml` / `displaySignature` so the template stays
        // loop-only.
        var constructors = []
        var fields = []
        var accessors = []
        var functions = []
        for (mem in members) {
          var kind = Api.s_(mem, "kind")
          Api.decorateMember_(c["name"], kind, mem)
          if (kind == "constructor") {
            constructors.add(mem)
          } else if (kind == "field") {
            fields.add(mem)
          } else if (kind == "getter" || kind == "setter") {
            accessors.add(mem)
          } else {
            functions.add(mem)
          }
        }
        c["constructors"] = constructors
        c["fields"]       = fields
        c["accessors"]    = accessors
        c["functions"]    = functions
      }
    }
    return modules
  }

  /// Set the per-member view-helper fields the template needs.
  /// `displaySignature` is the form rendered as the entry title:
  /// `ClassName.method(args)` for static methods, just the
  /// signature for instance getters / fields. Constructors lose
  /// the `construct ` prefix and gain `ClassName.` in front so
  /// `construct new_(a, b)` reads as `Response.new_(a, b)`.
  static decorateMember_(className, kind, mem) {
    var sig = Api.s_(mem, "signature")
    // Strip the `construct ` prefix on constructors — `Response.new_(...)`
    // reads better than `Response.construct new_(...)`.
    if (kind == "constructor" && sig.startsWith("construct ")) {
      sig = sig[10..(sig.count - 1)]
    }
    // Always prefix with the class name so each entry stands
    // alone as a navigable identity, regardless of static vs
    // instance. `Http.get(url, opts?)`, `Response.status`,
    // `Response.header(name)` — the entry tells the reader
    // *which* class it belongs to without scrolling back to a
    // banner.
    var display = className + "." + sig
    var tag = "FN"
    var tagClass = "api-tag-fn"
    if (kind == "getter") {
      tag = "GET"
      tagClass = "api-tag-get"
    } else if (kind == "setter") {
      tag = "SET"
      tagClass = "api-tag-set"
    } else if (kind == "constructor") {
      tag = "NEW"
      tagClass = "api-tag-new"
    } else if (kind == "field") {
      tag = "FLD"
      tagClass = "api-tag-fld"
    } else if (kind == "static_method") {
      tag = "FN"
      tagClass = "api-tag-fn"
    }
    mem["tag"]              = tag
    mem["tagClass"]         = tagClass
    mem["displaySignature"] = display
    mem["docMd"]            = Api.s_(mem, "doc")
  }

  /// Doc comment → HTML. Splits on blank lines for paragraphs,
  /// HTML-escapes everything, and rewrites backtick spans to
  /// `<code>` chips via `Catalog.inlineCode_` — same chip
  /// treatment as the lede / README body.
  static docHtml_(text) {
    if (text == null || text == "") return ""
    var paras = text.split("\n\n")
    var s = ""
    for (p in paras) {
      var trimmed = Api.trim_(p)
      if (trimmed == "") continue
      s = s + "<p>" + Api.inlineCode_(trimmed) + "</p>"
    }
    return s
  }

  // Local copy of `Catalog.inlineCode_` — `lib/api.wren`
  // shouldn't import `Catalog` purely for one helper since the
  // renderer is otherwise self-contained.
  static inlineCode_(s) {
    if (s == null || s == "") return ""
    var out = ""
    var inCode = false
    var buf = ""
    for (i in 0...s.count) {
      var ch = s[i]
      if (ch == "`") {
        if (inCode) {
          out = out + "<code>" + Api.htmlEscape_(buf) + "</code>"
          buf = ""
          inCode = false
        } else {
          out = out + Api.htmlEscape_(buf)
          buf = ""
          inCode = true
        }
      } else {
        buf = buf + ch
      }
    }
    if (inCode) {
      out = out + "`" + Api.htmlEscape_(buf)
    } else {
      out = out + Api.htmlEscape_(buf)
    }
    return out
  }

  static htmlEscape_(s) {
    if (s == null) return ""
    var r = s.replace("&", "&amp;")
    r = r.replace("<", "&lt;")
    r = r.replace(">", "&gt;")
    r = r.replace("\"", "&quot;")
    r = r.replace("'", "&#39;")
    return r
  }

  static s_(map, key) {
    if (!(map is Map)) return ""
    var v = map.containsKey(key) ? map[key] : null
    return v is String ? v : ""
  }
  static l_(map, key) {
    if (!(map is Map)) return []
    var v = map.containsKey(key) ? map[key] : null
    return v is List ? v : []
  }

  static trim_(s) {
    var start = 0
    var end = s.count - 1
    while (start <= end && Api.isWs_(s[start])) start = start + 1
    while (end >= start && Api.isWs_(s[end])) end = end - 1
    if (start > end) return ""
    return s[start..end]
  }
  static isWs_(c) {
    return c == " " || c == "\t" || c == "\n" || c == "\r"
  }

  /// Lowercase + alphanumeric-and-hyphen-only slug for anchor
  /// ids — `@hatch:web` → `hatch-web`, `Http.Client` →
  /// `http-client`. Drops collapsing runs of non-alphanum and
  /// trailing dashes.
  static slug_(s) {
    if (s == null) return ""
    var out = ""
    var lastDash = false
    for (i in 0...s.count) {
      var c = s[i]
      var b = c.bytes[0]
      var keep = false
      if (b >= 65 && b <= 90) {
        c = String.fromByte(b + 32)
        keep = true
      } else if (b >= 97 && b <= 122) {
        keep = true
      } else if (b >= 48 && b <= 57) {
        keep = true
      }
      if (keep) {
        out = out + c
        lastDash = false
      } else if (!lastDash && out != "") {
        out = out + "-"
        lastDash = true
      }
    }
    if (out.endsWith("-")) out = out[0..(out.count - 2)]
    return out
  }
}
