// @hatch:assets: web backend.
//
// Mirrors `assets_native.wren`'s `Asset` / `Assets` shape but
// the database is mounted from a VFS manifest the server (or
// build step) emits next to the assets:
//
//   assets-manifest.json schema
//   ---------------------------
//   {
//     "version": 1,
//     "tree": {
//       "shaders": {
//         "triangle.wgsl": { "hash": "<hex>", "size": <Num> },
//         "solid.wgsl":    { "hash": "<hex>", "size": <Num> }
//       },
//       "textures": {
//         "atlas.png":     { "hash": "<hex>", "size": <Num> }
//       },
//       "config.json":     { "hash": "<hex>", "size": <Num> }
//     }
//   }
//
// A node is a *file* iff its value is a Map containing `"hash"`.
// Anything else is a *directory* whose children are nested under
// it. Servers can hydrate this from any source: a `find`-style
// dump, a database query, an embedded asset bundle. The page
// fetches the manifest at `<baseUrl>/assets-manifest.json` and
// `Assets.open(baseUrl)` mounts the tree as a VFS on top of the
// runtime, with each leaf addressable by its forward-slashed
// path. Per-asset bytes / text are fetched lazily from
// `<baseUrl>/<path>` on first read and cached.
//
// In addition to the path-keyed `db.text(path)` / `db.bytes
// (path)` API every backend exposes, the web variant offers
// VFS-like enumeration:
//
//   db.list                 // every file path under the mount
//   db.list("shaders")      // every file under shaders/ (recursive)
//   db.dirs("")             // immediate subdirectories under the root
//   db.files("shaders")     // immediate files in shaders/
//
// Hot reload: `db.on(path, fn)` registers a watcher; `db.reload
// (path)` re-fetches the manifest + the named asset and fires
// any subscribers if the hash advances. Browsers don't surface
// filesystem-watch events, so the user wires `reload` to a UI
// affordance: a "refresh shaders" button, a debug-channel
// websocket message, etc.
//
// **Run from a fiber.** `Assets.open` and `Asset.text` reach
// the network through `Browser.fetch(...).await`, and `await`
// suspends the *current* fiber. Wren's top-level main module
// has no caller to yield to, so any program that touches the
// db has to start its work inside `Fiber.new { ... }.try()`:
//
//   var program = Fiber.new {
//     var db = Assets.open("./assets")
//     System.print(db.text("shaders/triangle.wgsl"))
//   }
//   program.try()
//
// `@hatch:game`'s `Game.run` already runs the user's
// `setup` / `update` / `draw` hooks inside a fiber, so games
// don't need to wrap manually.

import "wlift_prelude" for Browser
import "@hatch:json"   for JSON

class Asset {
  construct new_(db, relPath, url, hash, size) {
    _db    = db
    _path  = relPath
    _url   = url
    _hash  = hash
    _size  = size
    _bytes = null
    _text  = null
  }

  path     { _path }
  absolute { _url }
  hash     { _hash }
  size     { _size }
  /// Filesystem mtime has no analogue here; the browser's HTTP
  /// caching layer and the manifest hash drive change detection.
  mtime    { 0 }

  /// Lazily fetch text. Cached after the first read; `db.reload
  /// (path)` invalidates so a future read re-fetches.
  text {
    if (_text == null) _text = Browser.fetch(_url).await
    return _text
  }

  /// Bytes path is currently a String shim. The Browser bridge
  /// resolves `fetch(url).then(r => r.text())`, which is fine for
  /// shaders and configs but loses fidelity on binary payloads
  /// (UTF-8 decode with replacement chars). Real binary support
  /// lands once `Browser.fetchBytes` ships; until then, the abort
  /// makes the limitation loud rather than letting a corrupted
  /// PNG slip through.
  bytes {
    Fiber.abort("Asset.bytes: binary fetch not yet wired on web. Use `text` for shaders / configs; image / audio loading lands with Browser.fetchBytes.")
  }

  invalidate_ {
    _bytes = null
    _text  = null
  }

  refresh_(hash, size) {
    _hash = hash
    _size = size
    invalidate_
  }

  toString { "Asset(%(_path), %(_hash[0..7]), %(_size)b)" }
}

class Assets {
  construct new_(baseUrl) {
    _baseUrl  = baseUrl
    _entries  = {}      // "a/b/file.ext" → Asset
    _children = {}      // dirPath ("" for root) → List<{name, isDir}>
    _watchers = {}      // path → List<Fn>
  }

  /// Fetch the manifest and mount its VFS at `baseUrl`. Manifest
  /// shape is documented at the top of this file. Must run from
  /// inside a fiber; see the file header.
  static open(baseUrl) {
    var url = baseUrl + "/assets-manifest.json"
    var text = Browser.fetch(url).await
    if (text == null) Fiber.abort("Assets.open: failed to fetch %(url).")
    var manifest = JSON.parse(text)
    if (!(manifest is Map)) Fiber.abort("Assets.open: manifest at %(url) must be a JSON object, got %(manifest.type).")

    // Schema validation: `version` and `tree` are required so the
    // user gets a clear hint rather than a silent zero-asset
    // mount when they ship an old or wrong shape.
    if (!manifest.containsKey("tree")) {
      Fiber.abort("Assets.open: manifest at %(url) is missing the 'tree' field.")
    }
    var tree = manifest["tree"]
    if (!(tree is Map)) {
      Fiber.abort("Assets.open: manifest 'tree' must be a JSON object, got %(tree.type).")
    }

    var db = Assets.new_(baseUrl)
    db.mount_(tree, "")
    return db
  }

  root    { _baseUrl }
  absRoot { _baseUrl }
  count   { _entries.count }

  // Walk a tree subtree, registering each file as an Asset and
  // recording the parent's child set so dirs / files queries can
  // answer in O(1). `prefix` accumulates the slash-joined path.
  mount_(node, prefix) {
    var children = []
    for (name in node.keys) {
      var childPath = prefix == "" ? name : prefix + "/" + name
      var value = node[name]
      var isFile = value is Map && value.containsKey("hash")
      if (isFile) {
        var hash = value["hash"]
        var size = value.containsKey("size") ? value["size"] : 0
        _entries[childPath] = Asset.new_(this, childPath, _baseUrl + "/" + childPath, hash, size)
        children.add({ "name": name, "isDir": false })
      } else if (value is Map) {
        mount_(value, childPath)
        children.add({ "name": name, "isDir": true })
      } else {
        Fiber.abort("Assets.mount: '%(childPath)' must be a file (Map with 'hash') or a directory (Map of children); got %(value.type).")
      }
    }
    _children[prefix] = children
  }

  /// -- Path-keyed lookups (parity with native) -----------------

  has(relPath)   { _entries.containsKey(relPath) }
  get(relPath) {
    var entry = _entries[relPath]
    if (entry == null) Fiber.abort("Assets.get: '%(relPath)' is not in the manifest.")
    return entry
  }
  bytes(relPath) { get(relPath).bytes }
  text(relPath)  { get(relPath).text }
  hash(relPath)  { get(relPath).hash }

  // -- VFS enumeration ----------------------------------------

  /// Every file path under the mount, optionally restricted to a
  /// sub-directory. `prefix == ""` returns every file.
  list { listUnder_("") }
  list(prefix) { listUnder_(prefix) }

  /// Immediate subdirectory names directly under `prefix` (no
  /// recursion). Empty list if `prefix` doesn't resolve to a
  /// directory.
  dirs(prefix) { childrenOfKind_(prefix, true) }

  /// Immediate file names directly under `prefix`. Same shape as
  /// `dirs(prefix)` but for leaves.
  files(prefix) { childrenOfKind_(prefix, false) }

  /// True iff the path resolves to a known directory (the root
  /// counts: `exists("")` returns true).
  isDir(prefix) { _children.containsKey(prefix) }

  listUnder_(prefix) {
    var out = []
    if (prefix == "") {
      for (k in _entries.keys) out.add(k)
    } else {
      var p = prefix + "/"
      for (k in _entries.keys) {
        if (k == prefix || k.startsWith(p)) out.add(k)
      }
    }
    return out
  }

  childrenOfKind_(prefix, wantDir) {
    var children = _children[prefix]
    if (children == null) return []
    var out = []
    for (c in children) {
      if (c["isDir"] == wantDir) out.add(c["name"])
    }
    return out
  }

  /// -- Watchers / hot reload ----------------------------------

  on(relPath, fn) {
    if (!_watchers.containsKey(relPath)) _watchers[relPath] = []
    _watchers[relPath].add(fn)
    return this
  }

  off(relPath, fn) {
    var subs = _watchers[relPath]
    if (subs == null) return false
    var rebuilt = []
    var removed = false
    for (s in subs) {
      if (s == fn) {
        removed = true
      } else {
        rebuilt.add(s)
      }
    }
    _watchers[relPath] = rebuilt
    return removed
  }

  /// Re-fetch the manifest, refresh a single asset's metadata,
  /// drop its content cache, and fire watchers iff the hash
  /// changed. Cheap dev affordance: a "refresh shaders" button
  /// can wire straight to this.
  reload(relPath) {
    var entry = _entries[relPath]
    if (entry == null) Fiber.abort("Assets.reload: '%(relPath)' is not in the manifest.")
    var url = _baseUrl + "/assets-manifest.json"
    var text = Browser.fetch(url).await
    var manifest = JSON.parse(text)
    var tree = (manifest is Map && manifest["tree"] is Map) ? manifest["tree"] : null
    if (tree == null) Fiber.abort("Assets.reload: manifest at %(url) is malformed.")
    var node = lookupTreeNode_(tree, relPath)
    if (!(node is Map) || !node.containsKey("hash")) {
      Fiber.abort("Assets.reload: '%(relPath)' is no longer in the manifest.")
    }
    var newHash = node["hash"]
    var newSize = node.containsKey("size") ? node["size"] : entry.size
    var oldHash = entry.hash
    entry.refresh_(newHash, newSize)
    if (newHash != oldHash) fireSubscribers_(relPath, entry)
    return entry
  }

  // Walk the tree manifest down to a leaf at `relPath`. Returns
  // the leaf's metadata Map, or null if the path doesn't resolve.
  lookupTreeNode_(tree, relPath) {
    var node = tree
    var parts = relPath.split("/")
    var i = 0
    while (i < parts.count) {
      var name = parts[i]
      if (name == "") {
        i = i + 1
        continue
      }
      if (!(node is Map) || !node.containsKey(name)) return null
      node = node[name]
      i = i + 1
    }
    return node
  }

  fireSubscribers_(relPath, asset) {
    var subs = _watchers[relPath]
    if (subs == null) return
    for (fn in subs) fn.call(asset)
  }

  toString { "Assets(%(_baseUrl), %(_entries.count) files)" }
}
