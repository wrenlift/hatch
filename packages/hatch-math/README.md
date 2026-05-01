Vector, matrix, and quaternion math for interactive apps and games. `Vec2` / `Vec3` / `Vec4` for points and directions, `Mat4` for transforms, `Quat` for rotations, plus `Math` scalar helpers and Robert Penner-style `Ease` curves. Pure Wren — the JIT optimises hot vector loops the same way it does any other code, and the package has no native dependencies.

## Overview

Operator overloads cover the obvious cases (`+`, `-`, `*`, unary `-`); every binary op returns a fresh instance. For hot loops where you'd rather not allocate, every type exposes in-place companions (`addInto(a, b)`, `mulInto(a, s)`) that write into `this`.

```wren
import "@hatch:math" for Vec3, Mat4, Quat, Math, Ease

var p = Vec3.new(1, 2, 3)
var v = Vec3.new(0, 9.8, 0)

var pNext = p + v * 0.016

var m = Mat4.translation(1, 0, 0) * Mat4.rotationY(Math.PI / 4)
var q = Quat.fromAxisAngle(Vec3.unitY, Math.PI / 2)

System.print(Ease.inOutQuad(0.35))
System.print(Math.smoothstep(0, 1, 0.5))
```

`Math` covers the usual scalar helpers — `PI`, `TAU`, `lerp`, `inverseLerp`, `clamp`, `saturate`, `smoothstep`, `smootherstep`, `wrap`, `radians` / `degrees`, `approxEq`. `Ease` covers the classic in / out / inOut variants of `quad`, `cubic`, `quart`, `quint`, `sine`, `expo`, `circ`, `back`, `elastic`, `bounce`.

## Conventions

- `Mat4` is row-major; access with `m.at(row, col)` / `m.set(row, col, v)`.
- Coordinates are right-handed with OpenGL-style clip space (`-1..1` depth, `y` up) for `Mat4.perspective` and `lookAt`.
- Factory names spell out intent — `Vec3.unitY` rather than `Vec3.up`, `Mat4.rotationX` rather than `Mat4.rx`.

> **Note — `==` is exact**
> Equality compares bit-for-bit. After accumulated floating-point error, two "equal" values might disagree at the last few ulps. Use `Math.approxEq(a, b, eps)` or the `approxEq` method on each type when fuzzy comparison is what you actually want.

## Compatibility

Wren 0.4 + WrenLift runtime 0.1 or newer. Pure-Wren — no native dependencies. `@hatch:gpu` reuses these types directly via their `.data` accessor for batched buffer uploads, so you don't need to flatten manually.
