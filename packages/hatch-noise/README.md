CPU-side procedural noise. Same deterministic, seeded scalars across runs, machines, and versions — `Noise.simplex2(x, y, seed)` returns the same bits everywhere. Backed by `noise-rs` so the algorithms have a long tail of production use behind them.

## Overview

```wren
import "@hatch:noise" for Noise

// 2D OpenSimplex for terrain height.
var h = Noise.simplex2(x * 0.01, z * 0.01, 1337)

// Fractal Brownian motion sums octaves of OpenSimplex with
// caller-controlled lacunarity (frequency multiplier per
// octave) and persistence (amplitude multiplier per octave).
// Output stays in roughly [-1, 1] regardless of octave count.
var rugged = Noise.fbm2(x * 0.01, z * 0.01, 1337, 6, 2.0, 0.5)

// Batched heightmap fill. One foreign call writes the whole
// width × height grid into a Float32Array; the Wren-side loop
// overhead drops away for chunk-sized samplers.
var heightmap = Float32Array.new(64 * 64)
Noise.fillSimplex2(heightmap, 0.0, 0.0, 0.01, 0.01, 64, 64, 1337)
```

## Algorithms

| Function | Cost | Notes |
|---|---|---|
| `simplex2 / simplex3` | mid | OpenSimplex. Smooth, isotropic, patent-free. The default. |
| `perlin2 / perlin3` | mid | Classic gradient noise. Slight axis-aligned artefacts at high octaves. |
| `value2 / value3` | low | Cheapest. Blockier; good placeholder. |
| `fbm2 / fbm3` | octaves × simplex | Fractal Brownian motion. Normalised so the range stays consistent. |
| `fillSimplex2` | width × height | Batched 2D simplex fill into a Float32Array. |

## Compatibility

Wren 0.4 and WrenLift runtime 0.1 or newer. No transitive deps beyond `noise-rs`. Loads via the standard plugin path (`libs/<platform>/libwlift_noise.{dylib,so,dll}`) — drop a freshly-built dylib into `libs/` for local development:

    cargo build -p wlift_noise --release
    cp target/release/libwlift_noise.dylib hatch/packages/hatch-noise/libs/
