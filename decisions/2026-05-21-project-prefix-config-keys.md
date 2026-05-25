# Build-flag config keys use the project_ prefix

- Date: 2026-05-21
- Status: accepted

## Context
A contributor PR added an `:ios_swift_sources` `mob.exs` key to pass extra
Swift sources into the iOS Zig build. The Zig build flag is
`-Dproject_swift_sources`, matching the existing `project_c_nifs` /
`project_rust_libs` flags — but the `mob.exs` key used an `ios_` prefix
instead, an inconsistent naming surface.

## Decision
Rename the config key to `:project_swift_sources` so the `mob.exs` key matches
the Zig flag name and the sibling `project_*` conventions. Swift is iOS-only by
language, so no platform prefix is needed.

## Consequences
One consistent `project_*` family across config keys and build flags. Shipped
in mob_dev 0.5.11.
