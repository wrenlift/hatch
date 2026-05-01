A clap-style argument parser for Wren command-line tools. The shape follows the Rust crate of the same name — a fluent `Cli` builder that collects `Arg` definitions, generates help and version text, and returns a `Matches` you query for parsed values. Errors come back on `matches.error` instead of aborting, so `main` decides whether to print-and-exit or retry.

## Overview

Build the parser once at startup, then call `parse(argv)` against the host's argument vector. Each `Arg` is one switch, option, positional, or counting flag. The configuration kind is mutually exclusive — the last `flag()` / `value()` / `count()` / `positional()` call wins.

```wren
import "@hatch:cli" for Cli, Arg

var app = Cli.new("greet")
  .version("0.1.0")
  .about("Prints a greeting")
  .arg(Arg.new("name").positional().required()
        .help("who to greet"))
  .arg(Arg.new("loud").short("l").long("loud").flag()
        .help("shout the greeting"))
  .arg(Arg.new("count").short("n").long("count").value().default("1")
        .help("how many times"))

var m = app.parse(argv)
if (m.error != null) {
  System.print(m.error)
  return
}

var times = Num.fromString(m.value("count"))
for (_ in 0...times) System.print(m.flag("loud") ? "HEY %(m.value("name"))!" : "hi %(m.value("name"))")
```

`m.value(name)` reads a string-valued option or positional; `m.flag(name)` returns `true` if a boolean flag was present; `m.count(name)` returns the number of occurrences (`-vvv` → `3`).

## Help and version

Calling `--help` / `-h` or `--version` / `-V` populates `matches.error` with the rendered text and sets `matches.helpRequested` / `matches.versionRequested`. That keeps the same control-flow shape as a real parse error — print and return — without conflating them with mistakes.

> **Tip — handle help separately**
> If your tool exits non-zero on parse error, branch on `helpRequested` / `versionRequested` first so `--help` exits zero. Treating any non-null `error` as failure is a common bug.

## Compatibility

Wren 0.4 + WrenLift runtime 0.1 or newer. Pure-Wren — no native dependencies. Pair with `@hatch:os` for `argv` access on native, or with `@hatch:web`'s URL-search-params bridge for browser tools.
