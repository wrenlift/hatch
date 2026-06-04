# Changelog

## 0.1.8 -- 2026-06-04

- Worker-thread async decode pipeline: `Image.decodeBegin`
  returns an `ImageDecodeHandle` that `AssetLoader.queueDecode`
  polls; per-job decode runs on a `std::thread` via the new
  `JobRegistry` (six entry points wired up).
- Plugin: GC roots map + pixel array held across allocator
  calls inside the decode path, closing the foreign-method
  root-miss class on the image side.
