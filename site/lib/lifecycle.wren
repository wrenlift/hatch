// Boot-lifecycle state machine for the site process.
//
// The site's start-up has four observable phases — pre-boot, the
// catalog hydration that opens the in-memory SQLite and loads
// index.toml, the routes-registered-but-not-yet-listening window,
// and the serving phase that runs from `app.listen` onwards. Each
// transition is meaningful for diagnostics:
//
//   - `/readyz` returns 200 only once the chart reaches `serving`,
//     so a platform readiness probe can distinguish "process up"
//     from "process ready to handle traffic"
//   - the FSM's transition signal logs every boot phase to stderr,
//     which beats the previous loose `System.print("boot: ...")`
//     calls scattered through `main.wren`
//   - failure to hydrate the catalog isn't fatal — we still proceed
//     to `serving` with an empty catalog and the chart records
//     `catalogError` in context for the readiness probe to surface
//
// The chart deliberately doesn't model the background warmers
// (api / readme / blog / refresh fibers) — they run in parallel
// with `serving` and finish at unpredictable times. The lifecycle
// is "ready to serve traffic", not "every cache is filled".

import "@hatch:fsm" for StateChart

class Lifecycle {
  /// Compiled chart instance. Construction is lazy so importing
  /// this module is free when the chart isn't going to be driven.
  static fsm {
    if (__fsm == null) __fsm = Lifecycle.build_()
    return __fsm
  }

  /// True iff the chart has reached the `serving` state.
  static isServing { Lifecycle.fsm.matches("serving") }

  /// Snapshot of the boot context plus active states — used by
  /// `/readyz` to surface catalog stats alongside the readiness
  /// flag. The Map is freshly constructed each call so callers
  /// can mutate it without affecting the FSM's own context.
  static snapshot {
    var ctx = Lifecycle.fsm.context
    return {
      "state":            Lifecycle.fsm.activeStates,
      "ready":            Lifecycle.isServing,
      "startedAtMs":      ctx["startedAtMs"],
      "bootDurationMs":   ctx["bootDurationMs"],
      "catalogPackages":  ctx["catalogPackages"],
      "catalogError":     ctx["catalogError"]
    }
  }

  /// Initialise the chart and wire the default `[lifecycle]` log
  /// observer. Idempotent; subsequent calls are a no-op so a spec
  /// or REPL session can call it freely.
  static start() {
    if (__started == true) return Lifecycle.fsm
    __started = true
    var chart = Lifecycle.fsm
    chart.on("transition") {|from, to, evt|
      System.print("[lifecycle] %(from) -> %(to) via %(evt)")
    }
    chart.start()
    return chart
  }

  static build_() {
    return StateChart.build {|c|
      c.id("site")
      // The driver fills these fields by mutating `fsm.context`
      // directly around each `send(...)` call. Keeping the chart
      // definition free of inline-time-source / driver-state
      // lookups avoids the closure-scope footguns that come with
      // calling a static helper from inside an entry/transition
      // action.
      c.context({
        "startedAtMs":     null,
        "bootDurationMs":  null,
        "catalogPackages": 0,
        "catalogError":    null
      })

      c.state("init") {|s|
        s.on("boot", "bootingCatalog")
      }

      c.state("bootingCatalog") {|s|
        s.on("catalogHydrated", "routesReady")
        // Hydration failed but we still want to serve traffic so
        // Fly's liveness check stays green; the catalog refills
        // on the next refresh tick.
        s.on("catalogFailed",   "routesReady")
      }

      c.state("routesReady") {|s|
        s.on("listen", "serving")
      }

      c.state("serving") {|s|
        s.on("shutdown", "stopped")
      }

      c.state("stopped") {|s|
        s.final()
      }

      c.initial("init")
    }
  }
}
