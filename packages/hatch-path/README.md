Filesystem path manipulation. Provides `join`, `split`, `parent`, `basename`, `stem`, `extname`, `normalize`, and `isAbsolute` on a single `Path` class. All operations are pure string work; nothing here touches the filesystem. That belongs in `@hatch:fs`.

## Overview

`join` has two overloads. The two-arg form is the common case. The list form builds a path from conditional pieces without pre-filtering. Empty entries are skipped, and an absolute argument resets the join the same way `cd /tmp; cd /home` ends up at `/home`.

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

`Path.split(path)` returns the components as a `List<String>`, preserving the empty-first element for absolute paths so `split("/a/b")[0] == ""` and `split("a/b")[0] == "a"`. This is deliberate. Round-tripping through `split` and `join` produces the same path.

> **Note: Unix-style separators only**
> The package uses `/` exclusively. Windows paths and drive letters need OS-detection plumbing that lives in `@hatch:os`. Until those helpers land, callers on Windows should use forward slashes explicitly or post-process the result before handing it to `@hatch:fs`.

## Compatibility

Wren 0.4 with WrenLift runtime 0.1 or newer. Pure Wren, no native dependencies. Pair with `@hatch:fs` for actual filesystem access.
