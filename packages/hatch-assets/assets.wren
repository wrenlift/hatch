// @hatch:assets — entry module that re-exports the right
// backend for the bundle target.
//
//   assets_native.wren — filesystem-backed (Fs.walk + content
//                         hashes + Hatch.watchFile hot reload).
//                         Used on native; also driven by the
//                         spec runner.
//   assets_web.wren    — manifest-backed (fetch-driven, lazy
//                         per-asset reads, no filesystem watch).
//                         The page ships an
//                         `assets-manifest.json` next to the
//                         assets the runtime will reach for.
//
// Same package, target-conditional re-exports. Bundler picks
// the matching set per `--bundle-target`.
//
// Both backends expose the same `Asset` / `Assets` shape — the
// one Wren-level API works against either. See each backend's
// header for behaviour notes (binary fetch, hot-reload signal,
// etc.).

#!native
import "assets_native" for Asset, Assets

#!wasm
import "assets_web" for Asset, Assets
