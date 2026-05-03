A namespace re-export for the built-in typed buffer classes: `ByteArray`, `Float32Array`, and `Float64Array`. The classes themselves live in the Wren prelude and are always callable; this package exists so projects that prefer explicit imports can pull them in via `import "@hatch:buffers" for ByteArray` and pin the dependency in their hatchfile.

## Overview

Three constructors and a Sequence-protocol element view per type. Storage is contiguous, fixed-size, and zero-initialised. Negative indices wrap from the end the same way `List` does.

```wren
import "@hatch:buffers" for ByteArray, Float32Array

var bytes = ByteArray.fromString("hello")
System.print(bytes.count) // 5

var coords = Float32Array.fromList([0.0, 1.0, 0.0, 1.0])
coords[0] = 0.5
System.print(coords.toList) // [0.5, 1.0, 0.0, 1.0]
```

`arr.count` gives the element count; `arr.byteLength` multiplies by the element size (`1` for `ByteArray`, `4` for `Float32Array`, `8` for `Float64Array`). `ByteArray` stores via `i & 0xff`; values outside `0..=255` clamp into range, matching the `Uint8Array` convention.

## Interop

Typed arrays are drop-in replacements for `List<Num>` against the host packages that take byte input. `@hatch:crypto`, `@hatch:zip`, `@hatch:socket`, `@hatch:hash`, and `@hatch:io` accept a `ByteArray` directly without a `List` round-trip. The same goes for `@hatch:gpu`'s vertex and index buffers, which take `Float32Array` and `ByteArray` natively.

> **Note: the prelude is canonical**
> Importing this package is optional; `ByteArray.new(16)` works in any module. The package exists for pin-as-dependency hygiene and for callers who like their imports explicit.

## Compatibility

Wren 0.4 + WrenLift runtime 0.1 or newer. Pure-runtime types; no host capabilities, no native dependencies.
