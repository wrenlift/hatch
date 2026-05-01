ANSI colour, width-padding, and a handful of numeric helpers for terminal output. One class — `Fmt` — focused on the spots Wren's core doesn't cover. Wren already has interpolation (`"%(x)"`) so there's no `printf` here; these are the pieces you reach for when you want a styled CLI.

## Overview

Colour helpers wrap their argument in the matching ANSI escape and reset at the end. Styles compose by nesting — `Fmt.bold(Fmt.red("FAIL"))` works the way you'd expect. A global `Fmt.enabled` toggle disables every escape sequence at once for piped or non-TTY output.

```wren
import "@hatch:fmt" for Fmt

System.print(Fmt.green("ok"))
System.print(Fmt.bold(Fmt.red("FAIL")))

System.print(Fmt.padLeft("3", 4))    // "   3"
System.print(Fmt.padRight("3", 4))   // "3   "
System.print(Fmt.center("hi", 6))    // "  hi  "

System.print(Fmt.hex(255))           // "0xff"
System.print(Fmt.fixed(3.14159, 2))  // "3.14"
System.print(Fmt.duration(3670))     // "1h 1m 10s"
```

Foreground colours: `red`, `green`, `yellow`, `blue`, `magenta`, `cyan`, `white`, `gray`. Styles: `bold`, `dim`, `italic`, `underline`. Padding helpers operate on `s.toString` so passing a `Num` works without explicit conversion.

## Disabling colour

Pipe-detection isn't here yet (it needs the FFI shape that lands with `@hatch:os`). Until then, flip the flag yourself when stdout isn't a TTY:

```wren
import "@hatch:fmt" for Fmt
import "@hatch:os"  for Os

Fmt.enabled = Os.isatty(1)
```

> **Note — `enabled = false` removes the codes, not the call**
> Helpers still go through `Fmt.green` / `Fmt.bold`; they just emit the bare string. You don't need to branch at every call site.

## Compatibility

Wren 0.4 + WrenLift runtime 0.1 or newer. Pure-Wren — no native dependencies. ANSI rendering depends on the host terminal honouring escape sequences (Windows 10+ Console Host does so by default).
