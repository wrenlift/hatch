#!/usr/bin/env python3
"""Convert Supabase's `packages` JSON dump into an `index.toml`
mirror of the hatch catalog.

Reads the JSON array on stdin and writes TOML to stdout. Each row is
one `(name, version)` pair — the Supabase schema uses them as a
compound primary key so multiple published versions coexist.

Output shape:

    [packages."@hatch:assert-0.1.0"]
    name        = "@hatch:assert"
    version     = "0.1.0"
    git         = "..."
    description = "..."          # optional
    owner       = "..."          # optional, Supabase user UUID
    created_at  = "..."          # optional, ISO-8601
    updated_at  = "..."          # optional, ISO-8601

Keys are `<name>-<version>` so they're unique and inspect cleanly.
Sorted by (name, version desc) so diffs stay stable when new
versions land and newest-first order makes the "latest" entry
obvious.
"""

import json
import sys


ALLOWED_FIELDS = (
    "git",
    "description",
    "homepage",
    "readme",
    "docs_url",
    "readme_url",
    "owner",
    "created_at",
    "updated_at",
)


def version_sort_key(row):
    """Newest-first order within a name. Parses dotted version
    strings into tuples for a numeric-ish sort; falls back to the
    raw string for anything that doesn't match."""
    version = row.get("version", "")
    parts = []
    for chunk in version.split("."):
        try:
            parts.append((0, int(chunk)))
        except ValueError:
            parts.append((1, chunk))
    return parts


def main() -> int:
    rows = json.load(sys.stdin)
    if not isinstance(rows, list):
        print("error: expected a JSON array of package rows", file=sys.stderr)
        return 1

    out = []
    out.append("# Auto-generated mirror of the hatch catalog. Do not edit by hand.")
    out.append("# The source of truth is the Supabase `packages` table;")
    out.append("# this file refreshes every few hours via .github/workflows/sync-index.yml.")
    out.append("")

    # Group rows by name so each package's versions render together.
    groups = {}
    for row in rows:
        groups.setdefault(row.get("name", ""), []).append(row)
    # Names alphabetical; within each name, newest version first.
    for name in sorted(groups.keys()):
        groups[name].sort(key=version_sort_key, reverse=True)

    for name in sorted(groups.keys()):
        for row in groups[name]:
            version = row.get("version", "")
            git = row.get("git")
            if not name or not version or not git:
                # NOT NULL schema should prevent this, but stay
                # defensive against half-populated rows.
                continue
            key = f"{name}-{version}"
            out.append(f"[packages.{_toml_key(key)}]")
            out.append(f"name = {json.dumps(name)}")
            out.append(f"version = {json.dumps(version)}")
            out.append(f"git = {json.dumps(git)}")
            for field in ALLOWED_FIELDS[1:]:
                value = row.get(field)
                if value is not None and value != "":
                    out.append(f"{field} = {json.dumps(value)}")
            out.append("")

    sys.stdout.write("\n".join(out))
    return 0


def _toml_key(name: str) -> str:
    """Quote a key if it's not a bare TOML key. Package names
    always contain `@:` / `-` / `.` characters so this quotes
    nearly every entry — that's fine; TOML tolerates quoted keys
    identically."""
    if name and all(c.isalnum() or c in "_-" for c in name):
        return name
    return json.dumps(name)


if __name__ == "__main__":
    sys.exit(main())
