Filesystem path manipulation — `join`, `split`, `parent`, `basename`, `stem`, `extname`, `normalize`, `isAbsolute`. One class — `Path` — and pure string work. Nothing here touches the filesystem; that belongs in `@hatch:fs`.

## Overview

Two `join` overloads — the two-arg form is the common case, the list form lets you build a path from conditional pieces without pre-filtering. Empty entries are skipped, and an absolute argument resets the join the same way `cd /tmp; cd /home` ends up at `/home`.

```wren
import "@hatch:path" for Path

System.print(Path.join("foo", "bar", "baz.txt"))   // "foo/bar/baz.txt"
System.print(Path.join(["foo", "", "bar"]))        // "foo/bar"

System.print(Path.parent("foo/bar/baz.txt"))       // "foo/bar"
System.print(Path.basename("foo/bar/baz.txt"))     // "baz.txt"
System.print(Path.stem("foo/bar/baz.txt"))         // "baz"
System.print(Path.extname("foo/bar/baz.txt"))      // ".txt"

System.print(Path.normalize("foo//./bar/../x"))    // "foo/x"
System.print(Path.isAbsolute("/a/b"))              // true
```

`Path.split(path)` returns the components as a `List<String>`, preserving the empty-first element for absolute paths so `split("/a/b")[0] == ""` and `split("a/b")[0] == "a"`. That's deliberate — round-tripping through `split` and `join` should produce the same path.

> **Note — Unix-style separators only**
> The package uses `/` exclusively. Windows paths and drive letters need OS-detection plumbing that lives in `@hatch:os`; until those helpers land, callers on Windows should use forward slashes explicitly or post-process the result before handing it to `@hatch:fs`.

## Compatibility

Wren 0.4 + WrenLift runtime 0.1 or newer. Pure-Wren — no native dependencies. Pair with `@hatch:fs` for actual filesystem access.
