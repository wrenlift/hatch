#!/usr/bin/env python3
"""Promote `//` doc-blocks immediately above declarations to `///`.

Bulk-converts existing `//` prose authors wrote above class /
method declarations into `///` so the doc collector picks them
up. Conservative by design — does NOT promote:

  * blocks that aren't adjacent to a declaration line (random
    inline commentary, mid-method explanations)
  * blocks above declarations whose name ends with `_` (those
    are package-internal by convention)
  * `// ---` / `// ===` section separators
  * lines that are already `///`

Walk every `.wren` file under hatch/packages/, skipping
`*.spec.wren`. Idempotent — running twice is a no-op once
every promotable block has been promoted.
"""

import re
import sys
from pathlib import Path

# `// ` or `//` lines (NOT `///`).
COMMENT_RE = re.compile(r'^( *)//(?!/)( ?.*)$')

# `// ----` / `// ====` separators — leave as-is even when
# they sit inside a doc block.
SEPARATOR_RE = re.compile(r'^\s*//\s*[-=]{3,}.*$')

# Wren control-flow / statement keywords. A line that starts
# with one of these is NOT a method declaration even though
# the regex `\w+(...)` would happily match it.
CONTROL_KEYWORDS = {
    'if', 'else', 'while', 'for', 'return', 'break', 'continue',
    'var', 'import', 'is', 'as', 'this', 'super', 'null', 'true',
    'false', 'in', 'Fiber', 'System', 'Fn', 'List', 'Map', 'String',
    'Num', 'Bool', 'Range', 'Object', 'Class',
}

# Declaration prefixes — at least one of these has to lead the
# line for it to be a doc-block target. The lambda checks the
# *first token* against the prefix set, so `if (x)` and
# `while (cond)` are rejected up-front.
DECL_LEADERS = ('class', 'foreign', 'static', 'construct')


def first_token(line):
    """Return the first identifier-shape token, or None."""
    s = line.strip()
    if not s:
        return None
    m = re.match(r'(\w+)', s)
    return m.group(1) if m else None


def looks_like_decl(line, expected_indent):
    """True when `line` (at the given indent) is something whose
    immediately-preceding `//` block we want to promote to `///`."""
    m = re.match(r'^( *)', line)
    if not m or len(m.group(1)) != expected_indent:
        return False
    stripped = line[expected_indent:].rstrip()
    if not stripped:
        return False

    tok = first_token(stripped)
    if tok is None:
        return False

    # Reject control-flow / common-class lines outright.
    if tok in CONTROL_KEYWORDS:
        return False

    # Class / foreign-class / static / construct lead → declaration.
    if tok in DECL_LEADERS:
        # Pull the actual name out so we can skip `_`-suffixed
        # internals. Strip every leading modifier keyword (each
        # is independently optional — `static foo`, `construct foo`,
        # `foreign static foo`, `class Foo`, etc.).
        peeled = stripped
        for _ in range(4):
            new = re.sub(
                r'^(?:foreign|static|construct|class)\s+',
                '',
                peeled,
                count=1,
            )
            if new == peeled:
                break
            peeled = new
        name_m = re.match(r'^(\w+)', peeled)
        if name_m and (name_m.group(1).endswith('_') or name_m.group(1).startswith('_')):
            return False
        return True

    # Otherwise the line must look like a method shape:
    #   foo(args) { ... }
    #   foo { ... }
    #   foo=(arg) { ... }
    method_re = re.compile(
        r'^(\w+)\s*'
        r'(?:'
        r'\([^)]*\)\s*\{'           # foo(args) {
        r'|\{'                       # foo {
        r'|=\([^)]*\)\s*\{'         # foo=(arg) {
        r')'
    )
    name_m = method_re.match(stripped)
    if not name_m:
        return False
    name = name_m.group(1)
    if name.endswith('_') or name.startswith('_'):
        return False
    return True


def promote(text):
    lines = text.splitlines(keepends=True)
    out = list(lines)
    n = len(lines)
    i = 0
    while i < n:
        cm = COMMENT_RE.match(lines[i].rstrip('\n'))
        if not cm:
            i += 1
            continue
        indent = len(cm.group(1))
        # Gather a contiguous comment block at this indent.
        end = i
        while end < n:
            m = COMMENT_RE.match(lines[end].rstrip('\n'))
            if not m or len(m.group(1)) != indent:
                break
            end += 1
        # Look for a declaration on the next non-blank line.
        # Allow up to one blank line between the doc block and
        # the declaration — a very common authoring pattern is
        # to leave a visual gap after a section-header `// ────`
        # ruler before the class actually starts.
        decl_idx = end
        blanks = 0
        while decl_idx < n and lines[decl_idx].strip() == '':
            blanks += 1
            if blanks > 1:
                break
            decl_idx += 1
        if decl_idx >= n:
            i = end + 1
            continue
        if blanks > 1:
            # Two or more blank lines — too far separated to
            # treat as the same doc unit.
            i = end + 1
            continue
        if not looks_like_decl(lines[decl_idx], indent):
            i = end + 1
            continue
        # Promote each non-separator line in the block.
        block_has_real_content = False
        for j in range(i, end):
            if not SEPARATOR_RE.match(lines[j]):
                block_has_real_content = True
                break
        if not block_has_real_content:
            i = end + 1
            continue
        for j in range(i, end):
            lj = lines[j]
            if SEPARATOR_RE.match(lj):
                continue
            mm = COMMENT_RE.match(lj.rstrip('\n'))
            if not mm:
                continue
            body = mm.group(2)
            tail = '\n' if lj.endswith('\n') else ''
            out[j] = ' ' * indent + '///' + body + tail
        i = end + 1
    return ''.join(out)


def main():
    base = Path('hatch/packages')
    if not base.exists():
        print('hatch/packages not found (run from repo root)', file=sys.stderr)
        sys.exit(1)
    edited = 0
    skipped = 0
    for path in sorted(base.rglob('*.wren')):
        if path.name.endswith('.spec.wren'):
            skipped += 1
            continue
        original = path.read_text()
        promoted = promote(original)
        if promoted != original:
            path.write_text(promoted)
            edited += 1
    print(f'edited {edited} file(s); {skipped} spec file(s) skipped')


if __name__ == '__main__':
    main()
