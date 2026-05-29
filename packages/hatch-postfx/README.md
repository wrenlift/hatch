# @hatch:postfx

Common post-processing effects for the WrenLift game framework.
The chain primitive lives in [`@hatch:game`](https://hatch.wrenlift.com/packages/@hatch:game)
as `PostFX` + `PostPass`; this package ships the effect catalogue
so the engine stays lean as the catalogue grows.

## Effects

| Class | Surface | Typical use |
|---|---|---|
| `Tonemap` | `exposure` | Final HDR → display mapping (approximate ACES). Run near the end of the chain. |
| `Vignette` | `strength`, `radius`, `softness` | Radial darkening for cinematic / scope-hood looks. |
| `FXAA` | `subpixel`, `edgeThreshold`, `edgeThresholdMin` | Cheap luma-driven anti-aliasing; run first, on input-range colours. |
| `ColorGrade` | `lift`, `gamma`, `gain`, `saturation` | Three-band colour grading + saturation. |
| `ChromaticAberration` | `strength`, `falloff` | Per-channel radial offset; subtle = realism, heavy = impact frames. |
| `Bloom` | `threshold`, `knee`, `intensity`, `levels`, `filterRadius` | Mip-pyramid additive bloom. Threshold + downsample chain + upsample chain + composite. |

## Quick start

```wren
import "@hatch:game"   for Game, PostFX
import "@hatch:postfx" for Tonemap, Vignette, FXAA, ColorGrade

class Demo is Game {
  construct new() {}
  setup(g) {
    g.postFX = PostFX.new(g)
    g.postFX.add(FXAA.new())
    g.postFX.add(ColorGrade.new({ "gain": [1.05, 1.0, 0.95] }))
    g.postFX.add(Tonemap.new({ "exposure": 1.2 }))
    g.postFX.add(Vignette.new({ "strength": 0.4 }))
  }
}

Game.run(Demo)
```

## Ordering

Passes run top-to-bottom, each reading the previous output. A
sensible default order:

1. **AA** — operates on raw input-range colours.
2. **Colour grade** — shifts the palette before tonemapping crushes range.
3. **Tonemap** — maps HDR-ish values into display range.
4. **Cosmetic** — vignette, chromatic aberration, etc.

Reorder freely when the effect demands it (e.g. heavy chromatic
aberration intended to read as a lens flaw belongs *after*
tonemapping so its colours land in display range).

## Writing your own

Subclass `PostPass` from `@hatch:game` and override the four
single-pass hooks:

```wren
import "@hatch:game" for PostPass

class Greyscale is PostPass {
  construct new() { super() }
  name         { "greyscale" }
  uniformBytes { 0 }
  fragmentBody { "
    let c = textureSample(t, s, uv).rgb;
    let g = dot(c, vec3<f32>(0.299, 0.587, 0.114));
    return vec4<f32>(g, g, g, 1.0);
  " }
}
```

For multi-pass effects (separable blur, bloom, depth-of-field)
override `stepCount`, `requestTargets(w, h)`, and `dispatchStep_`.

## Planned

- **`DepthOfField`** — needs the chain's `wantsDepth` hook to
  sample the scene depth buffer.
- **`MotionBlur`** — needs camera-prev-frame matrices threaded
  through `Game.run`.
