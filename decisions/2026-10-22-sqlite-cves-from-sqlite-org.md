# The bundled-runtime scan matches the project's SQLite against sqlite.org/cves.html

- Date: 2026-10-22
- Status: accepted
- Builds on: `2026-10-22-bundled-runtime-upstream-advisories.md` (MOB-495)

## Context

SQLite is not in the OTP tarball. Every app compiles it from exqlite's
amalgamation, `deps/exqlite/c_src/sqlite3.c`, and the `bundled_runtime` layer
read its `SQLITE_VERSION` only to print it beside a link to
`https://www.sqlite.org/cves.html`. `hex_deps` sees exqlite the Hex package, not
the SQLite release inside it. So a project on exqlite 0.36 (SQLite 3.51.3) scanned
clean while CVE-2026-11822/11824 (FTS5 heap write, fixed in 3.53.2) applied.

## Decision

- **Source**: the "Status Of Recent SQLite CVEs" table on
  `www.sqlite.org/cves.html`, the SQLite developers' own status per CVE. There is
  no JSON feed. NVD/OSV list CVEs SQLite disputes (the six "AI hallucination"
  CVE-2026-512xx, JDBC-wrapper bugs) and their CPE ranges for SQLite are
  unreliable, so the page is the better record.
- **Matching**: a row's Fix cell names the release that fixed its CVEs
  (`3.53.2 (2026-06-03)`). Each CVE in a row whose fix is newer than the
  project's version is a finding; SQLite versions are linear, so the OpenSSL
  linear comparison is reused (numeric per component: `3.9` < `3.10`). Rows whose
  Fix cell says "Not a bug in SQLite", "Not a bug in the core SQLite library",
  "Bug not in the SQLite library" (the 2023 wording) or calls the report
  unreproducible are parsed and ignored.
- **Severity**: the page has no severity column, so findings are `:medium`. If a
  `Severity` column appears it is used (columns are found by header name).
  `:medium` fails `--strict` and `--security-gate`; that is intended for the
  core-library rows (CVE-2026-11822/11824 is a heap write reachable from SQL
  with FTS5, which exqlite enables).
- **Version only**: matching uses the Fix version alone; the page has no
  machine-readable "which component" field. So rows in extensions exqlite's
  amalgamation does not compile are reported too: CVE-2025-70873 is in the
  zipfile extension (absent from `deps/exqlite/c_src/sqlite3.c`), CVE-2023-7104
  in the session extension (not enabled by exqlite's Makefile), and the
  CVE-2021-20223 row says it "is not a vulnerability". The finding therefore says
  the SQLite *predates* the fix, not that it is affected, and quotes sqlite.org's
  note. A curated exclusion list was not added: it would rot silently as the page
  changes, and every such row so far sits below a core-library fix that fails the
  gate anyway (anything older than 3.52.0 is also older than 3.53.2).
- **Validation**: the page must carry the table heading and its `CVE Number`,
  `Fix` and `Comments` columns, every row must name a CVE and have a Fix cell
  that is a version or a recognised dispute, and at least one row must name a
  fix. Anything else is "SQLite CVE page not recognised": the cached copy is used
  (flagged STALE) and a redesign never reads as "no CVEs". A new kind of Fix
  wording (say "Pending") therefore stops the refresh until the parser learns
  it, rather than being silently skipped.
- **Plumbing**: the page is a fourth `AdvisoryFeed` source (`:sqlite`, cached as
  `sqlite-cves.html`, same TTL/stale/offline rules). The check runs whenever the
  project has `deps/exqlite/c_src/sqlite3.c`, with or without cached OTP
  tarballs; with no tarballs the layer is `:ok` rather than `:not_applicable`
  when it found SQLite.

## Consequences

- Projects on exqlite 0.36.x get three `:medium` findings (CVE-2026-11822,
  CVE-2026-11824, and CVE-2025-70873, which is zipfile-only and does not apply
  to exqlite's build) and fail `--strict`; exqlite 0.37.0 (SQLite 3.53.2) is
  clean.
- The page lists *recent* CVEs only. A very old SQLite can be missing CVEs that
  fell off the table; the layer can't see those.
- The finding reports the fixing SQLite release, not an exqlite version, because
  the page doesn't map one to the other.
