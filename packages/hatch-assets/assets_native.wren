// @hatch:assets — content-addressable assets database.
//
//   import "@hatch:assets" for Assets
//
//   var db = Assets.open("assets")
//
//   var shader = db.text("shaders/triangle.wgsl")
//   var pixels = db.bytes("textures/atlas.png")
//
//   db.on("shaders/triangle.wgsl") {|asset|
//     // Auto-fired when the file's content hash changes — wire
//     // it up once at startup and the dev loop keeps it fresh
//     // without you polling anything.
//     System.print("shader changed (hash %(asset.hash)) — rebuild pipeline")
//   }
//
// `Assets.open(root)` indexes a directory tree at `root`,
// hashing each file with SHA-256. `db.get(path)` re-stats the
// file on each call: if the on-disk mtime advanced we re-hash;
// if the hash differs from the indexed value we update the
// entry. Hash equality across two paths is meaningful — the
// content hash is the canonical identity, so caches keyed by
// hash automatically dedupe identical content stored at
// different paths.
//
// Hot reload integration: `db.on(path, fn)` registers
// `Hatch.watchFile(absolutePath, hook)`. Edit the file, the
// runtime's SIGUSR1 safepoint pass fires, the hook re-reads +
// re-hashes, and `fn(asset)` runs only if the hash actually
// changed (mtime-only touches are silent). Used by @hatch:gpu's
// shader hot reload and by the game framework's texture / mesh /
// audio pipelines on top.

import "@hatch:fs"   for Fs
import "@hatch:hash" for Hash
import "hatch"       for Hatch

// One indexed file. Bytes are read lazily — small assets stay
// out of memory until you actually ask for them.
class Asset {
  construct new_(db, relPath, absPath, hash, size, mtime) {
    _db    = db
    _path  = relPath
    _abs   = absPath
    _hash  = hash
    _size  = size
    _mtime = mtime
    _bytes = null
    _text  = null
  }

  path       { _path }       // relative to the db root
  absolute   { _abs }
  hash       { _hash }       // SHA-256 hex
  size       { _size }       // bytes
  mtime      { _mtime }      // seconds since epoch

  // Eagerly load (caches across calls until the hash advances).
  bytes {
    if (_bytes == null) _bytes = Fs.readBytes(_abs)
    return _bytes
  }
  text {
    if (_text == null) _text = Fs.readText(_abs)
    return _text
  }

  // Drop the cached bytes / text; next access re-reads from disk.
  // The db calls this when it observes a hash change so the next
  // read returns fresh contents.
  invalidate_ {
    _bytes = null
    _text  = null
  }

  refresh_(hash, size, mtime) {
    _hash  = hash
    _size  = size
    _mtime = mtime
    invalidate_
  }

  toString { "Asset(%(_path), %(_hash[0..7]), %(_size)b)" }
}

class Assets {
  construct new_(root) {
    _root      = root
    _absRoot   = Fs.exists(root) ? Assets.absolutize_(root) : root
    _entries   = {}     // relative path → Asset
    _abs2rel   = {}     // absolute path → relative path
    _watchers  = {}     // relative path → List<Fn>
    _hooked    = {}     // absolute path → true once Hatch.watchFile registered
  }

  // Open a database rooted at `dir`. Indexes every file under it
  // in one pass — for sub-second startup on workspaces with
  // thousands of small assets and ~tens-of-ms on small ones.
  // Hashing is content-addressable identity, so duplicate
  // contents at different paths share one Asset record? No —
  // separate Asset records per path; the hash field carries the
  // content identity callers can dedupe on themselves.
  static open(dir) {
    var db = Assets.new_(dir)
    db.scan_()
    return db
  }

  // Convert any relative root into an absolute path. We assume
  // the caller is already running in the workspace dir;
  // os.path.absolutize_ would be cleaner but @hatch:assets
  // shouldn't pull in @hatch:os just for this.
  static absolutize_(p) {
    if (p.count > 0 && p[0] == "/") return p
    return Fs.cwd + "/" + p
  }

  root    { _root }
  absRoot { _absRoot }
  count   { _entries.count }

  // Walk the root tree, hashing every file. Idempotent — re-runs
  // refresh existing entries instead of duplicating them.
  //
  // Fs.walk returns paths relative to the root; we hand
  // indexFile_ the relative path it cares about and the
  // reconstructed absolute path the underlying readers want.
  //
  // Note: Fs.walk includes directory entries too (it reports
  // every name in the recursive listing). We skip non-file entries
  // explicitly rather than relying on isFile alone — calling
  // Fs.isFile on every walk result inside a tight loop sometimes
  // hits an issue with iteration order that surfaces as a
  // string-concat error at the FFI boundary, so collect first
  // then filter.
  scan_() {
    var rels = Fs.walk(_absRoot)
    var i = 0
    while (i < rels.count) {
      var rel = rels[i]
      var abs = _absRoot + "/" + rel
      if (Fs.isFile(abs)) indexFile_(rel, abs)
      i = i + 1
    }
  }

  // Compute or refresh one entry. Returns the Asset.
  indexFile_(rel, abs) {
    var bytes = Fs.readBytes(abs)
    var hash  = Hash.sha256(bytes)
    var size  = bytes.count
    // mtime via FS: best-effort, the runtime's Hatch.moduleMtime
    // primitive surfaces seconds-since-epoch for any path.
    var mt = Hatch.moduleMtime(abs) || 0
    var existing = _entries[rel]
    if (existing != null) {
      existing.refresh_(hash, size, mt)
      return existing
    }
    var asset = Asset.new_(this, rel, abs, hash, size, mt)
    _entries[rel]    = asset
    _abs2rel[abs]    = rel
    return asset
  }

  // Look up by relative path. Re-stats the file on every call:
  // if the on-disk mtime advanced past the last seen value we
  // re-hash + refresh; otherwise the cached entry is returned
  // verbatim. Throws if the path was never in the index.
  get(relPath) {
    var entry = _entries[relPath]
    if (entry == null) {
      // Try to bring in a previously-unseen file — useful when
      // assets get added between scans.
      var abs = _absRoot + "/" + relPath
      if (!Fs.isFile(abs)) Fiber.abort("Assets.get: '%(relPath)' not found.")
      return indexFile_(relPath, abs)
    }
    var abs = entry.absolute
    var mt  = Hatch.moduleMtime(abs) || 0
    if (mt > entry.mtime + 0.0001) {
      // Re-read + re-hash; if the hash changed, fire subscribers.
      var oldHash = entry.hash
      indexFile_(relPath, abs)
      if (entry.hash != oldHash) fireSubscribers_(relPath, entry)
    }
    return entry
  }

  bytes(relPath) { get(relPath).bytes }
  text(relPath)  { get(relPath).text }
  hash(relPath)  { get(relPath).hash }
  has(relPath)   { _entries.containsKey(relPath) }

  // Subscribe to content changes for a single relative path.
  // The callback receives the refreshed Asset; only fires when
  // the SHA-256 actually advances (a `touch` with no content
  // change is silent).
  on(relPath, fn) {
    if (!_watchers.containsKey(relPath)) _watchers[relPath] = []
    _watchers[relPath].add(fn)

    // Ensure the entry exists + register the SIGUSR1 hook once
    // per file. Re-subscriptions reuse the same Hatch.watchFile
    // entry (de-duped on the runtime side by closure pointer +
    // path; we de-dupe here to avoid registering N closures for
    // N subscribers).
    var asset = get(relPath)
    if (!_hooked.containsKey(asset.absolute)) {
      _hooked[asset.absolute] = true
      var self = this
      Hatch.watchFile(asset.absolute, Fn.new {|p| self.handleFileChange_(p) })
    }
    return this
  }

  // Bound to Hatch.watchFile. The runtime fires per-path; we map
  // back to the relative path, refresh the entry's hash, and
  // notify only on an actual content change.
  handleFileChange_(absPath) {
    var rel = _abs2rel[absPath]
    if (rel == null) return
    var entry = _entries[rel]
    var oldHash = entry == null ? null : entry.hash
    indexFile_(rel, absPath)
    var newEntry = _entries[rel]
    if (newEntry.hash != oldHash) fireSubscribers_(rel, newEntry)
  }

  fireSubscribers_(rel, asset) {
    var subs = _watchers[rel]
    if (subs == null) return
    for (fn in subs) fn.call(asset)
  }

  // Drop a subscriber. Returns true if it was registered.
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

  toString { "Assets(%(_root), %(_entries.count) files)" }
}
