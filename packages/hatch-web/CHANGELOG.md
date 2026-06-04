# Changelog

## 0.1.9 -- 2026-06-04

Maintenance release riding the latest `wren_lift` runtime
fixes — CallKnownFunc arity truncation no longer affects 4+
argument calls (Renderer2D regression fix that flowed into
the broader codegen), and `hatch bundle` dep-order dedup
keeps `@hatch:events` ordered after its dependants when the
bundler folds in transitive packages.
