Compiled regular expressions with capture groups, replace, and split. `Regex` represents a compiled pattern and `Match` represents an individual hit. Backed by the Rust `regex` crate, so matching runs in linear time. The syntax is Perl-ish without backreferences or lookaround.

## Overview

Compile once, reuse the handle. The pattern is parsed and the automaton built on `Regex.compile`; subsequent `isMatch` / `find` / `findAll` / `replaceAll` / `split` calls run against the prepared state.

```wren
import "@hatch:regex" for Regex

var email = Regex.compile("(\\w+)@(\\w+\\.\\w+)")

System.print(email.isMatch("ping@host.io"))      // true

var m = email.find("ping@host.io")
System.print(m.text)                              // "ping@host.io"
System.print(m.groups)                            // ["ping@host.io", "ping", "host.io"]

System.print(Regex.compile("hello", "i").isMatch("HELLO"))   // true

System.print(Regex.compile("(\\w+)").replaceAll("hi bob", "<$1>")) // "<hi> <bob>"
System.print(Regex.compile(",\\s*").split("a, b ,c,   d"))         // ["a", "b", "c", "d"]
```

`Regex.escape(text)` returns a pattern that matches `text` literally. Use it before embedding user input into a pattern.

## Match shape and lifetime

A `Match` exposes `text`, `start`, `end`, `groups` (positional, with index `0` being the whole match), and `named` (a `Map` of named-group results). `match.group(i)` / `match.group(name)` shortcut into either.

`Regex` instances hold a numeric id into a runtime registry. The compiled automaton stays alive until `regex.free` is called. Short scripts can rely on program exit to clean up. Long-running servers that build many patterns should free aggressively, or pre-compile a fixed set at startup.

| Flag | Effect |
|------|--------|
| `i`  | Case-insensitive |
| `m`  | Multi-line mode (`^` / `$` match line boundaries) |
| `s`  | Dot-all (`.` matches `\n`) |
| `U`  | Swap greedy / non-greedy defaults |
| `x`  | Verbose. Ignores whitespace and `#` comments in the pattern |

> **Note: no backrefs, no lookaround**
> The `regex` crate guarantees linear-time matching by excluding constructs that require unbounded backtracking. Patterns that need `(?=...)` or `\1` must be parsed with a hand-rolled state machine; there is no flag to enable them.

## Compatibility

Wren 0.4 with WrenLift runtime 0.1 or newer. Native only. `#!wasm` builds need a separate compiled-regex bridge that has not shipped yet.
