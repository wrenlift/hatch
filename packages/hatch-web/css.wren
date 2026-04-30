// @hatch:web/css — a small Tailwind-dialect CSS-in-Wren combinator.
//
// The pitch:
//
//   import "./css" for Css
//
//   var btn = Css.tw("bg-blue-500 text-white px-4 py-2 rounded")
//                .hover("bg-blue-600")
//
//   // Deterministic class name (hash of the compiled CSS).
//   btn.className     // "c-a7b3d2"
//   btn.css           // ".c-a7b3d2 { background-color: #3b82f6; ... }"
//                     // ".c-a7b3d2:hover { background-color: #1d4ed8; ... }"
//   btn.styleTag      // "<style>...</style>" — inline-ready
//
// Three scopes for where the CSS lands:
//
//   * Global — call `app.globalCss(style)` at startup. A route-scope
//     stylesheet collects every global Style; `req.render` injects
//     the aggregated `<style>` tag into the `<head>` of full-page
//     renders. Deduped by class name, so adding the same style
//     twice is free.
//
//   * Fragment — call `req.fragmentCss(style)` inside a handler. The
//     `<style>` tag is emitted adjacent to the fragment's HTML, so
//     htmx `hx-swap` brings the CSS along with the swapped DOM —
//     no leaked styles from unmounted fragments, no build step.
//
//   * Slot — same wire shape as Fragment. The distinction is purely
//     author intent: "this CSS belongs to this slot's content" vs.
//     "this CSS belongs to this fragment". Use whichever reads
//     better at the call site.
//
// Dialect: a deliberate *subset* of Tailwind — enough to style a
// real app without shipping a 200KB runtime. ~200 utilities,
// procedurally generated so `p-7`, `mx-11`, `gap-3`, etc. all
// work without a 1000-line lookup. Add to `Tw_` as the surface
// grows. Full Tailwind parity isn't the goal; "I can build a
// site without switching to a different tool" is.

import "@hatch:hash" for Hash

// ── Tailwind token expansion ───────────────────────────────────────────
//
// Token → Map<String, String> of CSS declarations. Returns null for
// anything unrecognised — callers decide whether to warn or silently
// drop. State / responsive prefixes are stripped before this lookup;
// pseudo-wrapping happens in the Style builder.

class Tw_ {
  // 0.25rem × n, with "0" special-cased so "0rem" doesn't appear.
  static spacing_(n) {
    if (n == null) return null
    if (!(n is Num)) return null
    if (n == 0) return "0"
    var r = n * 0.25
    // Pretty-print integers without trailing ".0".
    if (r == r.floor) return "%(r.floor)rem"
    return "%(r)rem"
  }

  // Parse an integer trailing segment, e.g. "12" → 12, "full" → null.
  static intOf_(s) {
    if (s == null || s.count == 0) return null
    var i = 0
    while (i < s.count) {
      var b = s[i].bytes[0]
      if (b < 48 || b > 57) return null
      i = i + 1
    }
    return Num.fromString(s)
  }

  static COLORS_ { {
    "slate":  {"50": "#f8fafc", "100": "#f1f5f9", "200": "#e2e8f0", "300": "#cbd5e1", "400": "#94a3b8", "500": "#64748b", "600": "#475569", "700": "#334155", "800": "#1e293b", "900": "#0f172a"},
    "gray":   {"50": "#f9fafb", "100": "#f3f4f6", "200": "#e5e7eb", "300": "#d1d5db", "400": "#9ca3af", "500": "#6b7280", "600": "#4b5563", "700": "#374151", "800": "#1f2937", "900": "#111827"},
    "zinc":   {"50": "#fafafa", "100": "#f4f4f5", "200": "#e4e4e7", "300": "#d4d4d8", "400": "#a1a1aa", "500": "#71717a", "600": "#52525b", "700": "#3f3f46", "800": "#27272a", "900": "#18181b"},
    "red":    {"50": "#fef2f2", "100": "#fee2e2", "200": "#fecaca", "300": "#fca5a5", "400": "#f87171", "500": "#ef4444", "600": "#dc2626", "700": "#b91c1c", "800": "#991b1b", "900": "#7f1d1d"},
    "orange": {"50": "#fff7ed", "100": "#ffedd5", "200": "#fed7aa", "300": "#fdba74", "400": "#fb923c", "500": "#f97316", "600": "#ea580c", "700": "#c2410c", "800": "#9a3412", "900": "#7c2d12"},
    "amber":  {"50": "#fffbeb", "100": "#fef3c7", "200": "#fde68a", "300": "#fcd34d", "400": "#fbbf24", "500": "#f59e0b", "600": "#d97706", "700": "#b45309", "800": "#92400e", "900": "#78350f"},
    "yellow": {"50": "#fefce8", "100": "#fef9c3", "200": "#fef08a", "300": "#fde047", "400": "#facc15", "500": "#eab308", "600": "#ca8a04", "700": "#a16207", "800": "#854d0e", "900": "#713f12"},
    "green":  {"50": "#f0fdf4", "100": "#dcfce7", "200": "#bbf7d0", "300": "#86efac", "400": "#4ade80", "500": "#22c55e", "600": "#16a34a", "700": "#15803d", "800": "#166534", "900": "#14532d"},
    "emerald":{"50": "#ecfdf5", "100": "#d1fae5", "200": "#a7f3d0", "300": "#6ee7b7", "400": "#34d399", "500": "#10b981", "600": "#059669", "700": "#047857", "800": "#065f46", "900": "#064e3b"},
    "teal":   {"50": "#f0fdfa", "100": "#ccfbf1", "200": "#99f6e4", "300": "#5eead4", "400": "#2dd4bf", "500": "#14b8a6", "600": "#0d9488", "700": "#0f766e", "800": "#115e59", "900": "#134e4a"},
    "cyan":   {"50": "#ecfeff", "100": "#cffafe", "200": "#a5f3fc", "300": "#67e8f9", "400": "#22d3ee", "500": "#06b6d4", "600": "#0891b2", "700": "#0e7490", "800": "#155e75", "900": "#164e63"},
    "sky":    {"50": "#f0f9ff", "100": "#e0f2fe", "200": "#bae6fd", "300": "#7dd3fc", "400": "#38bdf8", "500": "#0ea5e9", "600": "#0284c7", "700": "#0369a1", "800": "#075985", "900": "#0c4a6e"},
    "blue":   {"50": "#eff6ff", "100": "#dbeafe", "200": "#bfdbfe", "300": "#93c5fd", "400": "#60a5fa", "500": "#3b82f6", "600": "#2563eb", "700": "#1d4ed8", "800": "#1e40af", "900": "#1e3a8a"},
    "indigo": {"50": "#eef2ff", "100": "#e0e7ff", "200": "#c7d2fe", "300": "#a5b4fc", "400": "#818cf8", "500": "#6366f1", "600": "#4f46e5", "700": "#4338ca", "800": "#3730a3", "900": "#312e81"},
    "violet": {"50": "#f5f3ff", "100": "#ede9fe", "200": "#ddd6fe", "300": "#c4b5fd", "400": "#a78bfa", "500": "#8b5cf6", "600": "#7c3aed", "700": "#6d28d9", "800": "#5b21b6", "900": "#4c1d95"},
    "purple": {"50": "#faf5ff", "100": "#f3e8ff", "200": "#e9d5ff", "300": "#d8b4fe", "400": "#c084fc", "500": "#a855f7", "600": "#9333ea", "700": "#7e22ce", "800": "#6b21a8", "900": "#581c87"},
    "fuchsia":{"50": "#fdf4ff", "100": "#fae8ff", "200": "#f5d0fe", "300": "#f0abfc", "400": "#e879f9", "500": "#d946ef", "600": "#c026d3", "700": "#a21caf", "800": "#86198f", "900": "#701a75"},
    "pink":   {"50": "#fdf2f8", "100": "#fce7f3", "200": "#fbcfe8", "300": "#f9a8d4", "400": "#f472b6", "500": "#ec4899", "600": "#db2777", "700": "#be185d", "800": "#9d174d", "900": "#831843"},
    "rose":   {"50": "#fff1f2", "100": "#ffe4e6", "200": "#fecdd3", "300": "#fda4af", "400": "#fb7185", "500": "#f43f5e", "600": "#e11d48", "700": "#be123c", "800": "#9f1239", "900": "#881337"}
  } }

  static FONT_SIZES_ { {
    "xs":   ["0.75rem", "1rem"],
    "sm":   ["0.875rem", "1.25rem"],
    "base": ["1rem", "1.5rem"],
    "lg":   ["1.125rem", "1.75rem"],
    "xl":   ["1.25rem", "1.75rem"],
    "2xl":  ["1.5rem", "2rem"],
    "3xl":  ["1.875rem", "2.25rem"],
    "4xl":  ["2.25rem", "2.5rem"],
    "5xl":  ["3rem", "1"],
    "6xl":  ["3.75rem", "1"],
    "7xl":  ["4.5rem", "1"]
  } }

  static FONT_WEIGHTS_ { {
    "thin":       "100", "extralight": "200", "light":    "300",
    "normal":     "400", "medium":     "500", "semibold": "600",
    "bold":       "700", "extrabold":  "800", "black":    "900"
  } }

  static RADII_ { {
    "none": "0px", "sm": "0.125rem", "md": "0.375rem", "lg": "0.5rem",
    "xl": "0.75rem", "2xl": "1rem", "3xl": "1.5rem", "full": "9999px"
  } }

  static color_(family, shade) {
    var families = Tw_.COLORS_
    if (!families.containsKey(family)) return null
    var shades = families[family]
    if (!shades.containsKey(shade)) return null
    return shades[shade]
  }

  /// The big case-switch. Returns Map<property, value> or null.
  static expand(token) {
    if (token == null || token.count == 0) return null
    var parts = token.split("-")

    // Quick literal matches — short circuit.
    if (token == "flex")         return {"display": "flex"}
    if (token == "grid")         return {"display": "grid"}
    if (token == "block")        return {"display": "block"}
    if (token == "inline-block") return {"display": "inline-block"}
    if (token == "inline")       return {"display": "inline"}
    if (token == "hidden")       return {"display": "none"}
    if (token == "flex-row")     return {"flex-direction": "row"}
    if (token == "flex-col")     return {"flex-direction": "column"}
    if (token == "flex-wrap")    return {"flex-wrap": "wrap"}
    if (token == "items-start")  return {"align-items": "flex-start"}
    if (token == "items-center") return {"align-items": "center"}
    if (token == "items-end")    return {"align-items": "flex-end"}
    if (token == "items-stretch")return {"align-items": "stretch"}
    if (token == "justify-start")  return {"justify-content": "flex-start"}
    if (token == "justify-center") return {"justify-content": "center"}
    if (token == "justify-end")    return {"justify-content": "flex-end"}
    if (token == "justify-between")return {"justify-content": "space-between"}
    if (token == "justify-around") return {"justify-content": "space-around"}
    if (token == "justify-evenly") return {"justify-content": "space-evenly"}
    if (token == "text-left")   return {"text-align": "left"}
    if (token == "text-center") return {"text-align": "center"}
    if (token == "text-right")  return {"text-align": "right"}
    if (token == "uppercase")   return {"text-transform": "uppercase"}
    if (token == "lowercase")   return {"text-transform": "lowercase"}
    if (token == "capitalize")  return {"text-transform": "capitalize"}
    if (token == "italic")      return {"font-style": "italic"}
    if (token == "underline")   return {"text-decoration-line": "underline"}
    if (token == "line-through")return {"text-decoration-line": "line-through"}
    if (token == "no-underline")return {"text-decoration-line": "none"}
    if (token == "relative")    return {"position": "relative"}
    if (token == "absolute")    return {"position": "absolute"}
    if (token == "fixed")       return {"position": "fixed"}
    if (token == "sticky")      return {"position": "sticky"}
    if (token == "static")      return {"position": "static"}
    if (token == "cursor-pointer") return {"cursor": "pointer"}
    if (token == "cursor-default") return {"cursor": "default"}
    if (token == "overflow-hidden") return {"overflow": "hidden"}
    if (token == "overflow-auto")   return {"overflow": "auto"}
    if (token == "overflow-scroll") return {"overflow": "scroll"}
    if (token == "w-full")  return {"width": "100%"}
    if (token == "w-screen")return {"width": "100vw"}
    if (token == "w-auto")  return {"width": "auto"}
    if (token == "h-full")  return {"height": "100%"}
    if (token == "h-screen")return {"height": "100vh"}
    if (token == "h-auto")  return {"height": "auto"}
    if (token == "rounded") return {"border-radius": Tw_.RADII_["md"]}
    if (token == "border")  return {"border-width": "1px", "border-style": "solid"}
    if (token == "shadow")  return {"box-shadow": "0 1px 3px rgba(0,0,0,0.1), 0 1px 2px rgba(0,0,0,0.06)"}
    if (token == "shadow-lg") return {"box-shadow": "0 10px 15px -3px rgba(0,0,0,0.1), 0 4px 6px -4px rgba(0,0,0,0.05)"}

    // Spacing / sizing families with a numeric tail.
    //   p-{n}, m-{n}, px/py/pt/.../mx/my/mt/... -{n}
    //   w-{n}, h-{n}, gap-{n}
    if (parts.count == 2) {
      var head = parts[0]
      var tail = parts[1]
      var n = Tw_.intOf_(tail)

      if (head == "p"  && n != null) return {"padding": Tw_.spacing_(n)}
      if (head == "px" && n != null) return {"padding-left": Tw_.spacing_(n), "padding-right": Tw_.spacing_(n)}
      if (head == "py" && n != null) return {"padding-top": Tw_.spacing_(n), "padding-bottom": Tw_.spacing_(n)}
      if (head == "pt" && n != null) return {"padding-top": Tw_.spacing_(n)}
      if (head == "pr" && n != null) return {"padding-right": Tw_.spacing_(n)}
      if (head == "pb" && n != null) return {"padding-bottom": Tw_.spacing_(n)}
      if (head == "pl" && n != null) return {"padding-left": Tw_.spacing_(n)}

      if (head == "m"  && n != null) return {"margin": Tw_.spacing_(n)}
      if (head == "mx" && n != null) return {"margin-left": Tw_.spacing_(n), "margin-right": Tw_.spacing_(n)}
      if (head == "my" && n != null) return {"margin-top": Tw_.spacing_(n), "margin-bottom": Tw_.spacing_(n)}
      if (head == "mt" && n != null) return {"margin-top": Tw_.spacing_(n)}
      if (head == "mr" && n != null) return {"margin-right": Tw_.spacing_(n)}
      if (head == "mb" && n != null) return {"margin-bottom": Tw_.spacing_(n)}
      if (head == "ml" && n != null) return {"margin-left": Tw_.spacing_(n)}

      if (head == "w"  && n != null) return {"width": Tw_.spacing_(n)}
      if (head == "h"  && n != null) return {"height": Tw_.spacing_(n)}
      if (head == "min-w" && n != null) return {"min-width": Tw_.spacing_(n)}
      if (head == "min-h" && n != null) return {"min-height": Tw_.spacing_(n)}
      if (head == "max-w" && n != null) return {"max-width": Tw_.spacing_(n)}
      if (head == "max-h" && n != null) return {"max-height": Tw_.spacing_(n)}

      if (head == "gap" && n != null) return {"gap": Tw_.spacing_(n)}

      // border-{n} as width
      if (head == "border" && n != null) {
        return {"border-width": "%(n)px", "border-style": "solid"}
      }

      // rounded-{size}
      if (head == "rounded" && Tw_.RADII_.containsKey(tail)) {
        return {"border-radius": Tw_.RADII_[tail]}
      }

      // font-weight
      if (head == "font" && Tw_.FONT_WEIGHTS_.containsKey(tail)) {
        return {"font-weight": Tw_.FONT_WEIGHTS_[tail]}
      }

      // font-size
      if (head == "text" && Tw_.FONT_SIZES_.containsKey(tail)) {
        var fs = Tw_.FONT_SIZES_[tail]
        return {"font-size": fs[0], "line-height": fs[1]}
      }

      // max-w-{sm/md/lg/xl/2xl/4xl/6xl} — prose widths.
      if (head == "max-w") {
        if (tail == "sm")  return {"max-width": "24rem"}
        if (tail == "md")  return {"max-width": "28rem"}
        if (tail == "lg")  return {"max-width": "32rem"}
        if (tail == "xl")  return {"max-width": "36rem"}
        if (tail == "2xl") return {"max-width": "42rem"}
        if (tail == "3xl") return {"max-width": "48rem"}
        if (tail == "4xl") return {"max-width": "56rem"}
        if (tail == "5xl") return {"max-width": "64rem"}
        if (tail == "6xl") return {"max-width": "72rem"}
        if (tail == "7xl") return {"max-width": "80rem"}
        if (tail == "full")return {"max-width": "100%"}
      }

      // text-{color}-{shade} when shade is a number — fallthrough below.
    }

    // color-shaded families: bg-blue-500, text-gray-700, border-red-300
    if (parts.count == 3) {
      var head = parts[0]
      var family = parts[1]
      var shade = parts[2]
      var col = Tw_.color_(family, shade)
      if (col != null) {
        if (head == "bg")     return {"background-color": col}
        if (head == "text")   return {"color": col}
        if (head == "border") return {"border-color": col}
        if (head == "ring")   return {"box-shadow": "0 0 0 3px " + col}
        if (head == "divide") return {"border-color": col}
      }
    }

    return null
  }
}

/// ── Style ──────────────────────────────────────────────────────────────
///
/// Immutable builder. Combinator methods (`tw`, `hover`, `focus`, `raw`)
/// return NEW Style instances — share safely across routes / threads.
///
/// A Style is a base declaration map + an ordered list of pseudo and
/// media buckets. Emitting CSS walks each bucket in the order it was
/// registered, so identical builders produce identical output
/// (deterministic className hash).

class Style {
  construct new_(base, pseudos, mediaBuckets) {
    _base = base
    _pseudos = pseudos            // List of [selectorSuffix, declsMap]
    _media = mediaBuckets         // List of [mediaQuery, declsMap]
    _classCache = null
    _cssCache = null
  }

  construct empty_() {
    _base = {}
    _pseudos = []
    _media = []
    _classCache = null
    _cssCache = null
  }

  /// Add Tailwind-dialect utilities to the base rule.
  ///
  ///   var s = Css.tw("flex items-center gap-2 p-4")
  ///
  /// Prefixes on individual tokens route into the right bucket:
  ///   "hover:bg-blue-600"   → :hover pseudo
  ///   "focus:ring-blue-300" → :focus pseudo
  ///   "md:px-8"             → @media (min-width: 768px)
  /// States and media can nest: "md:hover:bg-blue-700".
  tw(classes) {
    var next = Style.clone_(this)
    if (classes == null || classes.count == 0) return next
    for (tok in classes.split(" ")) {
      if (tok != "") Style.applyToken_(next, tok)
    }
    return next
  }

  /// Register arbitrary CSS declarations on the base rule.
  ///
  ///   Css.raw({"border-image": "url(...)", "-webkit-appearance": "none"})
  ///
  /// Wren has no schema for CSS values — this is the escape hatch for
  /// anything Tailwind dialect doesn't cover.
  raw(decls) {
    var next = Style.clone_(this)
    for (k in decls.keys) next.baseMerge_(k, decls[k])
    return next
  }

  /// Pseudo-state sugar. Each takes either a Tailwind-dialect string or
  /// a nested Style (whose base decls are folded into the pseudo's).
  hover(arg)     { pseudo_(":hover", arg) }
  focus(arg)     { pseudo_(":focus", arg) }
  active(arg)    { pseudo_(":active", arg) }
  disabled(arg)  { pseudo_(":disabled", arg) }
  visited(arg)   { pseudo_(":visited", arg) }

  /// Responsive sugar. Breakpoints follow Tailwind defaults. The
  /// bucket key stores just the media condition; the final emit
  /// prepends "@media " so mixing chain-method and prefix-token
  /// usage compiles to the same rule.
  sm(arg)  { media_("(min-width: 640px)", arg) }
  md(arg)  { media_("(min-width: 768px)", arg) }
  lg(arg)  { media_("(min-width: 1024px)", arg) }
  xl(arg)  { media_("(min-width: 1280px)", arg) }

  className {
    if (_classCache != null) return _classCache
    var h = Hash.md5(normalizedForHash_)
    _classCache = "c-" + h[0..9]
    return _classCache
  }

  /// Compiled CSS — rule for the base class, then each pseudo, then
  /// each @media bucket (itself containing the `.c-...` rule at the
  /// breakpoint). No whitespace minification beyond "clean".
  css {
    if (_cssCache != null) return _cssCache
    var cls = className
    var out = Style.emitRule_(".%(cls)", _base)
    for (p in _pseudos) {
      out = out + Style.emitRule_(".%(cls)%(p[0])", p[1])
    }
    for (m in _media) {
      var query = m[0]
      var decls = m[1]
      var inner = Style.emitRule_(".%(cls)", decls)
      out = out + "@media %(query) { %(inner) }"
    }
    _cssCache = out
    return _cssCache
  }

  /// Convenience for "just give me the <style> tag". Use directly in
  /// template output.
  styleTag { "<style>%(css)</style>" }

  // ── internal helpers ─────────────────────────────────────────────

  base_     { _base }
  pseudos_  { _pseudos }
  media_    { _media }

  baseMerge_(key, value)    { _base[key] = value }
  pseudoMerge_(sel, key, v) {
    for (entry in _pseudos) {
      if (entry[0] == sel) {
        entry[1][key] = v
        return
      }
    }
    _pseudos.add([sel, {key: v}])
  }
  mediaMerge_(query, key, v) {
    for (entry in _media) {
      if (entry[0] == query) {
        entry[1][key] = v
        return
      }
    }
    _media.add([query, {key: v}])
  }

  pseudo_(sel, arg) {
    var next = Style.clone_(this)
    var decls = Style.declsFromArg_(arg)
    for (k in decls.keys) next.pseudoMerge_(sel, k, decls[k])
    return next
  }

  media_(query, arg) {
    var next = Style.clone_(this)
    var decls = Style.declsFromArg_(arg)
    for (k in decls.keys) next.mediaMerge_(query, k, decls[k])
    return next
  }

  static declsFromArg_(arg) {
    if (arg is String) {
      var tmp = Style.empty_()
      for (tok in arg.split(" ")) {
        if (tok != "") Style.applyToken_(tmp, tok)
      }
      return tmp.base_
    }
    if (arg is Style) return arg.base_
    if (arg is Map) return arg
    return {}
  }

  // Parse a single Tailwind token (possibly with state / media prefixes
  // like "hover:bg-blue-600" or "md:flex") and apply the resulting
  // declarations to `style` at the right scope.
  static applyToken_(style, token) {
    var state = null          // :hover / :focus / :active / :disabled / :visited
    var mediaQuery = null     // @media (min-width: ...)
    var base = token
    while (true) {
      var colon = Style.indexOf_(base, ":")
      if (colon < 0) break
      var head = base[0..(colon - 1)]
      var tail = colon + 1 < base.count ? base[(colon + 1)..(base.count - 1)] : ""
      if (head == "hover" || head == "focus" || head == "active" || head == "disabled" || head == "visited") {
        state = ":" + head
        base = tail
      } else if (head == "sm") {
        mediaQuery = "(min-width: 640px)"
        base = tail
      } else if (head == "md") {
        mediaQuery = "(min-width: 768px)"
        base = tail
      } else if (head == "lg") {
        mediaQuery = "(min-width: 1024px)"
        base = tail
      } else if (head == "xl") {
        mediaQuery = "(min-width: 1280px)"
        base = tail
      } else {
        break
      }
    }
    var decls = Tw_.expand(base)
    if (decls == null) return
    for (k in decls.keys) {
      if (mediaQuery != null && state != null) {
        // Combined: :hover inside @media. Store under the media
        // bucket but prefix its selector via a synthetic state key.
        style.mediaMerge_(mediaQuery, state + "::" + k, decls[k])
      } else if (mediaQuery != null) {
        style.mediaMerge_(mediaQuery, k, decls[k])
      } else if (state != null) {
        style.pseudoMerge_(state, k, decls[k])
      } else {
        style.baseMerge_(k, decls[k])
      }
    }
  }

  static indexOf_(s, ch) {
    var i = 0
    while (i < s.count) {
      if (s[i] == ch) return i
      i = i + 1
    }
    return -1
  }

  // Clone so combinator chains stay immutable.
  static clone_(src) {
    var base = {}
    for (k in src.base_.keys) base[k] = src.base_[k]
    var ps = []
    for (p in src.pseudos_) {
      var m = {}
      for (k in p[1].keys) m[k] = p[1][k]
      ps.add([p[0], m])
    }
    var mq = []
    for (m in src.media_) {
      var mm = {}
      for (k in m[1].keys) mm[k] = m[1][k]
      mq.add([m[0], mm])
    }
    return Style.new_(base, ps, mq)
  }

  // Canonical text used for the className hash — sorted keys and
  // deterministic emission order, so equivalent builders share a
  // class name.
  normalizedForHash_ {
    var out = "|"
    out = out + Style.dumpSorted_(_base)
    for (p in _pseudos) out = out + "||" + p[0] + "|" + Style.dumpSorted_(p[1])
    for (m in _media) out = out + "||" + m[0] + "|" + Style.dumpSorted_(m[1])
    return out
  }

  static dumpSorted_(m) {
    var keys = []
    for (k in m.keys) keys.add(k)
    // Insertion sort — Wren's List has no .sort in the stdlib we use,
    // and 10-key maps are the common case.
    var i = 1
    while (i < keys.count) {
      var k = keys[i]
      var j = i - 1
      while (j >= 0 && Style.strGt_(keys[j], k)) {
        keys[j + 1] = keys[j]
        j = j - 1
      }
      keys[j + 1] = k
      i = i + 1
    }
    var out = ""
    for (k in keys) out = out + k + ":" + m[k] + ";"
    return out
  }

  static strGt_(a, b) {
    var i = 0
    while (i < a.count && i < b.count) {
      var ba = a[i].bytes[0]
      var bb = b[i].bytes[0]
      if (ba != bb) return ba > bb
      i = i + 1
    }
    return a.count > b.count
  }

  static emitRule_(selector, decls) {
    if (decls.count == 0) return ""
    var out = selector + " {"
    for (k in decls.keys) {
      // Skip synthetic state-inside-media keys; they need a different
      // selector which is already expanded in `applyToken_`.
      if (Style.indexOf_(k, "::") >= 0) {
        // Key format is ":hover::background-color". Split it back.
        var hh = Style.indexOf_(k, ":")
        var tt = Style.indexOf_(k[1..(k.count - 1)], ":")
        // This path is NYI in v1 — silently drop so we don't emit
        // malformed CSS. Follow-up ticket.
      } else {
        out = out + " " + k + ": " + decls[k] + ";"
      }
    }
    out = out + " }"
    return out
  }
}

/// ── Stylesheet ─────────────────────────────────────────────────────────
///
/// A collection of Styles, deduped by className. `add` returns the
/// style unchanged so handlers can thread it:
///
///   return req.render(tpl, {
///     "btn": req.fragmentSheet.add(btn).className
///   })
///
/// `emit` returns the concatenated CSS. `styleTag` wraps it in
/// `<style>...</style>`. Empty sheets emit "" / an empty style tag;
/// handlers can always include it without null-checking.

class Stylesheet {
  construct new() {
    _seen = {}   // className -> true
    _styles = []
  }

  count { _styles.count }

  add(style) {
    var name = style.className
    if (!_seen.containsKey(name)) {
      _seen[name] = true
      _styles.add(style)
    }
    return style
  }

  emit {
    var out = ""
    for (s in _styles) out = out + s.css + "\n"
    return out
  }

  styleTag {
    if (_styles.count == 0) return ""
    return "<style>%(emit)</style>"
  }
}

/// ── Css namespace ──────────────────────────────────────────────────────

class Css {
  static empty       { Style.empty_() }
  static tw(classes) { Css.empty.tw(classes) }
  static raw(decls)  { Css.empty.raw(decls) }

  /// Convenience: new empty Stylesheet.
  static sheet { Stylesheet.new() }
}
