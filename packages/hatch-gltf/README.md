# `@hatch:gltf`

Pure-Wren glTF 2.0 / `.glb` loader. Parses the binary container into nodes /
meshes / materials, decodes accessors into typed vertex + index arrays, and
spawns a `Transform`-rooted hierarchy into a `@hatch:ecs` `World`.

```wren
import "@hatch:gltf" for Gltf
import "@hatch:ecs"  for World

var world = World.new()
var doc = Gltf.load(device, bytes)   // parse + upload meshes
doc.spawnInto(world)                  // entities + Transform + MeshRenderer
```

The two halves are split so headless tooling (build pipelines, asset
inspectors, importers) can run without a GPU:

```wren
var doc = Gltf.parse(bytes)          // pure-data parse, no device
doc.meshes[0].primitives[0].positions  // Float32Array
doc.nodes[0].transform.position        // @hatch:game Transform → Vec3
```

## What's here today

- `.glb` (single-file binary) container parsing — magic, version, JSON +
  BIN chunk decoding
- Node hierarchy with translation / rotation / scale → `Transform`
- Indexed triangle meshes with `POSITION` + `NORMAL` + `TEXCOORD_0`
  accessors
- u8 / u16 / u32 index accessor decoding
- `pbrMetallicRoughness.baseColorFactor` → flat `Material`
- Default-scene root walk; orphan top-level nodes fall back to "every
  non-child node"
- `spawnInto(world)` creates one ECS entity per node + parents children via
  `world.setParent`; mesh-bearing nodes additionally gain a `MeshRenderer`

## Not yet supported

External buffer / texture URIs, embedded textures, animation channels,
skins + joints, KHR extensions beyond `pbrMetallicRoughness`, sparse
accessors, point / line primitives, morph targets, cameras. Each lands
when the downstream feature needs it.

## Storage

Decoded vertex data lives in packed typed arrays so GPU upload streams
contiguous bytes:

| Channel | Type | Notes |
|---|---|---|
| `binBuffer` | `ByteArray` | The raw BIN chunk |
| `positions` / `normals` / `uvs` | `Float32Array` | One allocation per accessor |
| `indices` | `Int32Array` | u8 / u16 / u32 → i32 |

## Build + run tests

```sh
hatch test packages/hatch-gltf
```
