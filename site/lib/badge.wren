// lib/badge.wren — server-side SVG badge generator with the
// hatch H favicon inlined as the logo. Replaces the shields.io
// hop so the brand mark, palette, and corner radius stay in
// our hands.
//
// Public surface:
//
//   Badge.gha(owner, repo, workflow, branch) → Response
//     Fetches the latest workflow run for `branch` from the
//     GitHub Actions REST API and renders an SVG with
//     `Cache-Control` set to a 60-second stale window. Every
//     downstream — README badge, dashboard tile, Slack unfurl
//     — round-trips through this one route.
//
// Color palette aligns with the hatch landing's tokens:
//
//   pass      #4d8b3b (sage, matches the "ok" pill)
//   fail      #c0392b (terracotta, distinct from butter)
//   running   #f4a83a (warm amber, reads as "in flight")
//   unknown   #6f6f6f (neutral grey)
//
// The label panel is brand toast (#462105) with white text;
// the message panel takes the status color above.

import "@hatch:json" for JSON
import "@hatch:http" for Http
import "@hatch:fs"   for Fs

class Badge {
  /// Inline SVG fragment for the H mark. Loaded once at boot
  /// from `public/assets/hatch-icon.svg` and stripped of the
  /// outer `<svg>` wrapper so we can re-anchor it inside the
  /// badge's own coordinate system. Falls back to a plain
  /// monochrome H if the asset can't be read (defensive — the
  /// file ships with the image so absence is a build error).
  static logoFragment {
    if (__logoFragment != null) return __logoFragment
    var raw = null
    var path = "./public/assets/hatch-icon.svg"
    if (Fs.exists(path)) raw = Fs.readText(path)
    if (raw == null) {
      __logoFragment = "<path fill=\"#fff\" d=\"M5 4h4v6h6V4h4v16h-4v-6H9v6H5z\"/>"
      __logoSourceViewBox = [0, 0, 24, 24]
      return __logoFragment
    }
    // Strip leading XML decl + outer <svg ...> so we keep just
    // the inner paths. Capture the source viewBox so the badge
    // can scale the fragment to fit a 14×14 logo slot.
    var openIdx = raw.indexOf("<svg")
    if (openIdx >= 0) {
      var gtIdx = raw.indexOf(">", openIdx)
      var head = raw[openIdx...gtIdx]
      var inner = raw[(gtIdx + 1)..-1]
      var closeIdx = inner.indexOf("</svg>")
      if (closeIdx >= 0) inner = inner[0...closeIdx]
      // Pull viewBox="x y w h" out of the head so we can
      // anchor the inner paths into the badge's coordinate
      // system. Format: viewBox="219 181 816 861".
      var vbStart = head.indexOf("viewBox=\"")
      if (vbStart >= 0) {
        var s = vbStart + 9
        var e = head.indexOf("\"", s)
        var nums = head[s...e].split(" ")
        __logoSourceViewBox = [
          Num.fromString(nums[0]), Num.fromString(nums[1]),
          Num.fromString(nums[2]), Num.fromString(nums[3])
        ]
      } else {
        __logoSourceViewBox = [0, 0, 24, 24]
      }
      __logoFragment = inner.trim()
    } else {
      __logoFragment = raw
      __logoSourceViewBox = [0, 0, 24, 24]
    }
    return __logoFragment
  }
  static logoSourceViewBox { __logoSourceViewBox }

  /// Render a badge SVG. `label` lands in the dark toast panel,
  /// `message` in the status-colored panel. `state` is one of
  /// `"pass"`, `"fail"`, `"running"`, `"unknown"`; anything else
  /// defaults to unknown.
  static render(label, message, state) {
    // Coarse Verdana 11px width approximation. Caps + lowercase
    // average around 6.5px / char; 7 keeps small labels off the
    // edge without measuring per-glyph.
    var charW = 7
    var lblTextW = label.count * charW
    var msgTextW = message.count * charW
    // 22px logo gutter on the label side; 12px padding around
    // the message text.
    var logoGutter = 22
    var labelW = logoGutter + lblTextW + 8
    var messageW = msgTextW + 14
    var totalW = labelW + messageW

    var color = stateColor_(state)
    var labelColor = "#462105"

    // Touch the logo cache first so `logoSourceViewBox` is
    // populated by the time we read it on the next line. Both
    // values are initialised lazily inside `logoFragment`'s
    // first call, so the read order matters.
    var logoSvg = logoFragment
    var vb = logoSourceViewBox
    var srcW = vb[2]
    var srcH = vb[3]
    var srcX = vb[0]
    var srcY = vb[1]
    var scale = 14 / (srcH > srcW ? srcH : srcW)
    var logoG = "<g transform=\"translate(5,3) scale(%(scale)) translate(%(-srcX),%(-srcY))\">%(logoSvg)</g>"

    // Drop-shadow gradient — gives the SVG that subtle bevel
    // shields.io users expect. Pure cosmetic, mirrors their
    // standard `flat` style.
    var grad = "<linearGradient id=\"g\" x2=\"0\" y2=\"100%\"><stop offset=\"0\" stop-color=\"#fff\" stop-opacity=\".7\"/><stop offset=\".1\" stop-color=\"#aaa\" stop-opacity=\".1\"/><stop offset=\".9\" stop-opacity=\".3\"/><stop offset=\"1\" stop-opacity=\".5\"/></linearGradient>"
    var clip = "<clipPath id=\"c\"><rect width=\"%(totalW)\" height=\"20\" rx=\"4\" fill=\"#fff\"/></clipPath>"
    var bg =
      "<rect width=\"%(labelW)\" height=\"20\" fill=\"%(labelColor)\"/>" +
      "<rect x=\"%(labelW)\" width=\"%(messageW)\" height=\"20\" fill=\"%(color)\"/>" +
      "<rect width=\"%(totalW)\" height=\"20\" fill=\"url(#g)\"/>"

    var labelTextX = logoGutter + (lblTextW / 2)
    var messageTextX = labelW + (messageW / 2)
    var text =
      "<g fill=\"#fff\" text-anchor=\"middle\" font-family=\"Verdana,Geneva,DejaVu Sans,sans-serif\" font-size=\"11\">" +
      "<text x=\"%(labelTextX)\" y=\"14\">%(label)</text>" +
      "<text x=\"%(messageTextX)\" y=\"14\">%(message)</text>" +
      "</g>"

    var title = "<title>%(label): %(message)</title>"

    return "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"%(totalW)\" height=\"20\" viewBox=\"0 0 %(totalW) 20\" role=\"img\" aria-label=\"%(label): %(message)\">" +
      title + grad + clip +
      "<g clip-path=\"url(#c)\">" + bg + "</g>" +
      logoG + text +
      "</svg>"
  }

  /// Map a workflow run conclusion / status pair to one of the
  /// state buckets `render` understands.
  ///   completed + success    → pass
  ///   completed + failure / cancelled / timed_out → fail
  ///   in_progress / queued / waiting → running
  ///   anything else (including null) → unknown
  static stateFromRun(status, conclusion) {
    if (status == "in_progress" || status == "queued" ||
        status == "waiting" || status == "pending") return "running"
    if (conclusion == "success") return "pass"
    if (conclusion == "failure" || conclusion == "cancelled" ||
        conclusion == "timed_out" || conclusion == "startup_failure") return "fail"
    return "unknown"
  }

  static stateMessage(state) {
    if (state == "pass") return "passing"
    if (state == "fail") return "failing"
    if (state == "running") return "running"
    return "unknown"
  }

  /// Fetch + render the latest GHA run for the given workflow.
  /// Returns the SVG string; caller wraps in a Response with
  /// the right Content-Type / Cache-Control. On any fetch
  /// failure we render an "unknown" badge so the README never
  /// shows a broken-image icon.
  static gha(owner, repo, workflow, branch) {
    // GitHub's REST API takes the workflow filename or numeric
    // ID interchangeably — we accept whatever the caller gives
    // us. `per_page=1` is enough; the result list is sorted
    // newest-first by `created_at`.
    var url = "https://api.github.com/repos/%(owner)/%(repo)/actions/workflows/%(workflow)/runs?branch=%(branch)&per_page=1"
    var headers = {
      "Accept":               "application/vnd.github+json",
      "X-GitHub-Api-Version": "2022-11-28",
      // Identify ourselves so GitHub's abuse-prevention layer
      // doesn't penalise unknown UAs.
      "User-Agent":           "hatch-badge/0.1 (+https://hatch.wrenlift.com)"
    }
    var fib = Fiber.new {
      Http.get(url, { "timeoutMs": 4000, "followRedirects": true, "headers": headers })
    }
    var resp = null
    while (!fib.isDone) {
      resp = fib.try()
      if (!fib.isDone) Fiber.yield()
    }
    var label = workflowLabel_(workflow)
    if (fib.error != null || resp == null || !resp.ok || resp.body == null) {
      return Badge.render(label, "unknown", "unknown")
    }
    var parsed = null
    var fib2 = Fiber.new { JSON.parse(resp.body) }
    while (!fib2.isDone) {
      parsed = fib2.try()
      if (!fib2.isDone) Fiber.yield()
    }
    if (fib2.error != null || parsed == null) {
      return Badge.render(label, "unknown", "unknown")
    }
    var runs = parsed["workflow_runs"]
    if (runs == null || runs.count == 0) {
      return Badge.render(label, "unknown", "unknown")
    }
    var run = runs[0]
    var state = stateFromRun(run["status"], run["conclusion"])
    return Badge.render(label, stateMessage(state), state)
  }

  // -- internals ----------------------------------------------------------

  static stateColor_(state) {
    if (state == "pass")    return "#4d8b3b"
    if (state == "fail")    return "#c0392b"
    if (state == "running") return "#f4a83a"
    return "#6f6f6f"
  }

  // Strip a `.yml`/`.yaml` suffix and title-case the result so
  // `regression.yml` reads as `Regression` on the badge. The
  // caller can override by passing `?label=...` to the route.
  static workflowLabel_(workflow) {
    var base = workflow
    if (base.endsWith(".yml")) base = base[0...-4]
    if (base.endsWith(".yaml")) base = base[0...-5]
    if (base.count == 0) return "Workflow"
    var first = base[0]
    if (first.bytes[0] >= 97 && first.bytes[0] <= 122) {
      first = String.fromCodePoint(first.bytes[0] - 32)
    }
    return first + base[1..-1]
  }
}
