Hatch's docs site renders three things per package: the README, a per-module API reference, and the hatchfile metadata. The first two come straight out of your source files. This page is the convention reference for writing them.

## Comment kinds

Wren has one comment syntax (`//`), but the WrenLift lexer sorts them into three buckets:

| Marker | Where it attaches | Promoted to |
|--------|-------------------|-------------|
| `//` (anywhere mid-file) | nowhere; pure code comment | nothing, ignored by the docs collector |
| `//` at the head of a file (no preceding code) | the file's module | module docs |
| `///` | the next declaration | decl docs |
| `//!` | the enclosing module | module docs |

```wren
// Internal note for the next reader. Doesn't show up on the docs site.

/// Parse `text` as JSON. Throws on malformed input.
class JSON {
  static parse(text) { ... }
}

//! @hatch:json — RFC 8259 JSON encoder + decoder.
//!
//! ```wren
//! import "@hatch:json" for JSON
//! var v = JSON.parse("{ \"ok\": true }")
//! ```
```

The "head-of-file" promotion is the new path: a `//` block at the top of a `.wren` file (no real code before it, blank lines OK) gets treated as module docs. That means existing packages whose file headers used plain `//` keep working without an edit. New code can use `//!` for clarity, but both feed the same place.

## Markdown inside doc comments

The docs renderer pipes your prose through Marked.js. Real markdown works:

- backticks for `identifiers` and `Type` names
- fenced code blocks with language hints: ```wren, ```sh, ```toml
- pipe tables for option grids
- blockquote callouts: `> **Tip — Title**`
- headings (`##`, `###`) for sub-sections inside long doc bodies

The conventions that lift legibility:

| Bad | Good |
|-----|------|
| `Returns the body. Example: var b = res.body` | `Returns the body. Example:`<br>(blank line)<br>` ```wren`<br>`var b = res.body`<br>` ``` ` |
| `headers - a Map of header names to values` | `\`headers\` — a `Map<String, String \| List>` of header names to values.` |
| `If status is between 200-299 returns true` | `Returns \`true\` when \`status\` is in \`[200, 300)\`.` |

Keep examples runnable. The docs site doesn't execute them, but anyone copy-pasting will, and a broken example reads as a broken library.

## Module headers

The first thing in a `.wren` file. Use them for the lede + a single canonical example + a quick map of the API surface, not for every option and method. Those go on the decl itself.

`@hatch:http`'s header is the model:

```wren
// `@hatch:http` — synchronous HTTP client with TLS, streaming
// bodies, and fiber-cooperative reads.
//
// ```wren
// import "@hatch:http" for Http
//
// var res = Http.get("https://api.example.com/users")
// var res = Http.post(url, { "json": {"name": "alice"} })
// ```
//
// ## Generic dispatch
//
// `Http.request(method, url, options)` underneath the verb
// helpers accepts:
//
// | Option       | Type                              | Notes                                  |
// |--------------|-----------------------------------|----------------------------------------|
// | `headers`    | `Map<String, String \| List>`     | Case-insensitive keys.                 |
// | `query`      | `Map<String, String \| Num>`      | Appended to the URL.                   |
// | ...
```

Three things to copy from this example:

1. **One-line lede.** First sentence reads like a tagline. No marketing fluff: say what it does and one or two distinguishing properties.
2. **One canonical example.** Short. Imports + the most common verb. Don't try to demonstrate every method here.
3. **Sub-sections via `##`.** Generic dispatch options, response shape, error semantics. The reader is looking up "how do I pass headers". Make it scannable.

## Decl docs

A paragraph or two above each public method / class. Don't recap the signature; the docs page already shows it as the entry's title. Focus on *behaviour*: what it does, what it errors on, edge cases.

```wren
/// First value for the given header, case-insensitive. Returns
/// `null` when absent. Matches the "just tell me the
/// content-type" use case.
header(name) {
  ...
}

/// Raw headers map: lower-cased keys → `List<String>` of values.
/// Multi-value headers like `Set-Cookie` survive intact here
/// (a naive `Map<String, String>` would collapse them).
headerMap { _headers }
```

Skip `///` on self-describing surface: getters / setters / `toString` rarely need them. Reserve doc blocks for methods that do meaningful work: factories, mutators, things with non-obvious behaviour or error semantics.

> **Tip: Don't write the signature in prose**
> The docs page already shows `header(name)` as the heading. Starting your doc with "The `header(name)` method..." is wasted real estate. Lead with the verb: "Returns the first value...".

## Where this surfaces

Two endpoints, one source of truth:

- **README.** The hatchfile's `readme` field points at a markdown file (relative or absolute URL). Rendered as-is at `hatch.wrenlift.com/docs/<package>`.
- **API reference.** `///` decl docs + module docs flow through `hatch docs` → JSON → the API renderer at the same URL. Module docs become the section header body for each `MOD`; decl docs become the body of each method / class entry.

The same JSON ships inside the `.hatch` bundle as a `Docs` section. Tooling (LSP, playground, offline browsers) reads it without re-parsing source.

## Example: before / after

A quick before/after on the same method:

```wren
// Before — terse, no markdown, no example
/// gets a header
header(name) { ... }
```

```wren
// After — clear behaviour, runnable example, edge case noted
/// First value for the given header, case-insensitive. Returns
/// `null` when absent.
///
/// ```wren
/// var ct = res.header("content-type")
/// if (ct != null && ct.startsWith("application/json")) { ... }
/// ```
header(name) { ... }
```

Five extra lines, dramatically better page.

## Next

When your docs read well, [publish the package](/guides/cli#hatch-publish) so other people can `hatch find` it.
