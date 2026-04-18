#!/usr/bin/env python3
"""Convert Supabase's `packages` JSON dump into an `index.toml`
mirror of the hatch catalog.

Reads the JSON array on stdin and writes TOML to stdout. Shape:

    [packages.<name>]
    git         = "..."
    description = "..."          # optional
    owner       = "..."          # optional, Supabase user UUID
    created_at  = "..."          # optional, ISO-8601
    updated_at  = "..."          # optional, ISO-8601

Sorted by name so diffs stay stable when new packages land.
"""

import json
import sys


ALLOWED_FIELDS = ("git", "description", "owner", "created_at", "updated_at")


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

    for pkg in sorted(rows, key=lambda p: p.get("name", "")):
        name = pkg.get("name")
        git = pkg.get("git")
        if not name or not git:
            # Skip malformed rows — should never happen with NOT NULL
            # schema constraints, but be defensive.
            continue
        out.append(f"[packages.{_toml_key(name)}]")
        out.append(f"git = {json.dumps(git)}")
        for field in ALLOWED_FIELDS[1:]:
            value = pkg.get(field)
            if value is not None and value != "":
                out.append(f"{field} = {json.dumps(value)}")
        out.append("")

    sys.stdout.write("\n".join(out))
    return 0


def _toml_key(name: str) -> str:
    """Quote a package name if it's not a bare TOML key. Bare keys
    allow [A-Za-z0-9_-]; anything else gets wrapped in quotes.
    """
    if name and all(c.isalnum() or c in "_-" for c in name):
        return name
    return json.dumps(name)


if __name__ == "__main__":
    sys.exit(main())
