/// `@hatch:buffers`: namespace re-export for the built-in typed
/// buffer classes. `ByteArray`, `Float32Array`, and `Float64Array`
/// live in the Wren prelude so they're always callable; this
/// package exists so callers who prefer explicit imports can
/// `import "@hatch:buffers" for ByteArray` and have it show up in
/// their hatchfile dependencies.
///
/// ## Surface
///
/// Lives on the classes themselves:
///
/// ```wren
/// ByteArray.new(n)            // n-byte zero-initialized buffer
/// ByteArray.fromList(list)    // copy from List<Num 0..=255>
/// ByteArray.fromString(s)     // UTF-8 bytes of s
///
/// Float32Array.new(n)         // n f32s zero-initialized
/// Float32Array.fromList(list) // copy from List<Num>
///
/// Float64Array.new(n)         // n f64s zero-initialized
/// Float64Array.fromList(list) // copy from List<Num>
///
/// arr.count                   // element count
/// arr.byteLength              // count * elementSize
/// arr[i]                      // load (negative index allowed)
/// arr[i] = v                  // store (byte clamped for U8)
/// arr.iterate(it) + arr.iteratorValue(it)  // Sequence protocol
/// arr.toList                  // convert back to List<Num>
/// arr.toString                // e.g. "ByteArray(16)"
/// ```
///
/// Typed arrays are drop-in replacements for `List<Num>` wherever
/// `@hatch:crypto`, `@hatch:zip`, `@hatch:socket`, `@hatch:hash`,
/// or `@hatch:io` expect a byte input. They accept `ByteArray`
/// directly without a `List` round-trip.

class Buffers {
  static ByteArray    { ByteArray }
  static Float32Array { Float32Array }
  static Float64Array { Float64Array }
}
