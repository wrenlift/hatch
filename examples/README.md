# Hatch Examples

Runnable demonstrations of the Hatch package ecosystem. Every example is a self-contained sub-package with its own `hatchfile` and `main.wren`.

## Build & run

`hatch run` builds + runs in one step (default tiered JIT mode):

```sh
cd hatch/examples/web/hello
hatch run
```

If tiered JIT crashes on a particular example, fall back to a two-step build + interpreter run:

```sh
cd hatch/examples/web/hello
hatch build                                              # → web-hello.hatch
wlift --mode interpreter --step-limit 0 web-hello.hatch
```

`--step-limit 0` disables the interpreter's instruction cap; required for any long-running demo (servers, game loops). The default 1B cap caps out after ~10–30 minutes of polling.

`hatch run` does not currently expose `--mode` or `--step-limit` — the two-step path above is the workaround until those flags land on the run subcommand.

## Game framework

Built on `@hatch:game`. Subclass `Game`, override `config` / `setup` / `update` / `draw`, hand the class to `Game.run`. Each demo lives in [game/](game/).

| Example | Showcases |
|---|---|
| [game/bouncing-ball](game/bouncing-ball/) | `@hatch:physics` World2D + ball/box colliders, click-to-spawn input, sprite tinting |
| [game/sprite-grid](game/sprite-grid/) | `@hatch:gpu` Renderer2D batching (~430 sprites in one flush), WASD/arrow polling |
| [game/cube-3d](game/cube-3d/) | Renderer3D + Camera3D + Light + Mesh.cube/plane, depth attachment, Renderer2D HUD overlay on the same pass |
| [game/ecs](game/ecs/) | `@hatch:ecs` World + components + system functions, 200-entity field with motion + wrap + render systems |
| [game/instanced-sprites](game/instanced-sprites/) | Renderer2D.drawInstancedSprites — 256 spinning sprites in one storage-buffer-backed instanced draw |
| [game/billboards](game/billboards/) | Renderer3D.drawBillboardN — 64 camera-facing billboards from a packed Float32Array |
| [game/weather-demo](game/weather-demo/) | Weather.rain + Weather.fog wired into a Game.run loop |
| [game/hud-gamepad](game/hud-gamepad/) | HUD focus model — pause menu navigable via DPad/stick + mouse |

The eight game examples above open a window — you need a desktop session, not a headless shell.

### Console examples — no window required

Pure-Wren demos that exercise a single API surface and print their results. Run from a shell:

| Example | Showcases |
|---|---|
| [game/bvh-cull](game/bvh-cull/) | `@hatch:spatial` BVH + `Frustum.cull(bvh, camera)` over a grid of AABBs |
| [game/quadtree2d](game/quadtree2d/) | `Quadtree2D` insert + radius / AABB queries |
| [game/noise-worley](game/noise-worley/) | `@hatch:noise` Worley, ridgedFbm2, fillSimplex3, WGSL companion |
| [game/clip-curves](game/clip-curves/) | `Clip.withInterpolations` — linear / step / cubic-Hermite sampling |
| [game/foliage-poisson](game/foliage-poisson/) | `Foliage.fromHeightmap` Poisson-disc + slope-aware scatter |
| [game/cascade-shadows](game/cascade-shadows/) | `CascadeShadows.splits` + `PointShadow.facesFor` math |
| [game/mesh-lod-pick](game/mesh-lod-pick/) | `MeshLOD.pickIndex` + `Lod.selectN` — per-instance LOD bucketing |
| [game/terrain-stream](game/terrain-stream/) | `TerrainStreamer` load / unload diff (mock device) |
| [game/audio-buses](game/audio-buses/) | `Audio.group` master / music / sfx / ui bus volumes |
| [game/frame-timer](game/frame-timer/) | `FrameTimer` rolling-window FPS / avg ms / 1%-low |

```sh
cd hatch/examples/game/bouncing-ball
hatch run                                                # tiered JIT
# or, if tiered crashes:
hatch build && wlift --mode interpreter --step-limit 0 bouncing-ball.hatch
```

## Web framework

Built on `@hatch:web`. Each demo lives in [web/](web/).

| Example | Showcases |
|---|---|
| [web/hello](web/hello/) | App.get + path params + middleware logging |
| [web/counter](web/counter/) | App.post + htmx fragment swaps + Css fragment styling |
| [web/chat](web/chat/) | App.channel pub/sub + Sse.stream + htmx sse-ext for live multi-tab updates |

```sh
cd hatch/examples/web/counter
hatch run
open http://127.0.0.1:3000
```

The chat demo polls forever, so build + run with `--step-limit 0`:

```sh
cd hatch/examples/web/chat
hatch build && wlift --mode interpreter --step-limit 0 web-chat.hatch
```

## Layout

Each example is a sub-package with its own `hatchfile` and `main.wren`. Path-relative dependencies point back into [packages/](../packages/), so framework changes are picked up immediately without republishing. Diamond deps (e.g. `@hatch:game` → `@hatch:gpu` plus a direct `@hatch:gpu` dep) trip the resolver's cycle detector — examples therefore declare only the leaf packages and rely on transitive resolution for the rest.
