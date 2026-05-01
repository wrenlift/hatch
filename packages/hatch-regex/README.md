Compiled regular expressions with capture groups, replace, and split. Two classes — `Regex` for the compiled pattern and `Match` for individual hits. Backed by the Rust `regex` crate, so matching runs in linear time and the syntax is Perl-ish without backreferences or lookaround.

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

`Regex.escape(text)` returns a pattern that matches `text` literally — use it before embedding user input into a pattern.

## Match shape and lifetime

A `Match` exposes `text`, `start`, `end`, `groups` (positional, with index `0` being the whole match), and `named` (a `Map` of named-group results). `match.group(i)` / `match.group(name)` shortcut into either.

`Regex` instances hold a numeric id into a runtime registry; the compiled automaton stays alive until you call `regex.free`. For short scripts you can let the program exit clean it up, but for long-running servers that build lots of patterns, free aggressively or pre-compile a fixed set at startup.

| Flag | Effect |
|------|--------|
| `i`  | Case-insensitive |
| `m`  | Multi-line mode (`^` / `$` match line boundaries) |
| `s`  | Dot-all (`.` matches `\n`) |
| `U`  | Swap greedy / non-greedy defaults |
| `x`  | Verbose — ignore whitespace and `#` comments in the pattern |

> **Note — no backrefs, no lookaround**
> The `regex` crate guarantees linear-time matching by excluding constructs that require unbounded backtracking. If you genuinely need `(?=...)` or `\1`, parse with a hand-rolled state machine instead — there isn't a flag to turn them on.

## Compatibility

Wren 0.4 + WrenLift runtime 0.1 or newer. Native only — `#!wasm` builds need a separate compiled-regex bridge that hasn't shipped yet.
