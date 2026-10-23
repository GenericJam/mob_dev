# The bundled-runtime scan matches OTP and OpenSSL against upstream advisories

- Date: 2026-10-22
- Status: accepted
- Issue: MOB-495

## Context

`mix mob.security_scan` ran in every release preflight while the device
runtime (OTP 29.0, OpenSSL 3.4.0, tarball `5c9c69fc`) fell 47 erlang/otp
advisories and 56 OpenSSL CVEs behind, and OpenSSL 3.4 reached end of life. The
`bundled_runtime` layer only printed "verify upstream" links; its moduledoc said
no machine-readable feed existed. That is true of OSV for OTP (the EEF records
carry `GIT` ranges only, so `pkg:otp/ssl@11.7` returns nothing) but the data is
published elsewhere.

## Decision

For the tarballs of the manifest's `active_hash` only (the runtime this mob_dev
deploys; stale caches of other hashes still get drift checks but are not what
ships), the layer matches:

- **OTP**: `GET api.github.com/repos/erlang/otp/security-advisories` (Link
  pagination; a token from `GITHUB_TOKEN`/`GH_TOKEN`/`gh auth token` if present,
  unauthenticated otherwise; a rejected token retries unauthenticated).
  Application entries (`ssl`, `public_key`, `erts`, …) are matched against the
  `lib/<app>-<vsn>` dirs in the tarball, which is what the native build packages
  (`installed_application_versions` omits ssl/crypto on iOS though `lib/ssl-*`
  ships). The umbrella `OTP` entry is used only when an advisory names no app.
  Entries for one package are merged across introduction points.
- **Version order**: OTP and application versions form a tree, so the matcher
  ports OTP's `versions:compare/2` (`same`/`ancestor`/`descendant`/`undefined`,
  "Version Scheme" in the OTP system principles; the advisories use `>=` in that
  sense). An installed version is affected when it is the same as or descends
  from an introduction point, fixed when it is the same as or descends from a
  patched version, vulnerable when affected and not fixed. The reported fix is the
  patched version descending from it with the longest common prefix (`11.7` →
  `11.7.8`), or none when nothing descends from it (an unmaintained branch). A
  first cut compared versions linearly with a "same prefix = same track"
  heuristic; review showed it called `26.2` vulnerable to an advisory introduced
  at `26.2.1` because a lower branch's `>= 25.3.2.8` caught it. A release
  candidate is an ancestor of its release.
- **OpenSSL**: the branch page `openssl-library.org/news/vulnerabilities-<branch>/`
  (OpenSSL retired its JSON feed), "Affected: from X before Y" ranges applied only
  on the installed branch (an open-ended `from 3.0.0 before` would otherwise catch
  3.4). OpenSSL versions are linear; letter suffixes order by length then
  alphabet (`1.1.1z` < `1.1.1za`).
- **EOL**: `endoflife.date/api/openssl.json`; on or after the branch's EOL date
  is a `:high` finding. OpenSSL says 3.4 is "supported until 2026-10-22", so the
  last supported day is counted as EOL: no further release will come on it, and
  a build made that day ships for months.
- Severity is the upstream one (OpenSSL `Moderate` → `:medium`). One finding per
  (id, package, version); the platforms carrying it are listed in the description.

Fetched bodies are validated before use and before they replace the cache: the
GitHub list must be non-empty with every advisory carrying `ghsa_id` and
`vulnerabilities[].package.name`; endoflife.date must be a non-empty list of
`cycle`/`eol` maps; the OpenSSL page must carry its `Vulnerabilities <branch>`
heading, every CVE block must yield a known severity and an affected range, and
a page mentioning a CVE must yield at least one block. A body failing that is a
refresh failure, never "no advisories". The cache (`advisories/` under `$MOB_CACHE_DIR`, default `~/.mob/cache`,
24 h TTL by mtime) is used when fresh; on a failed refresh the cached copy is used
and the note says STALE with the reason; a fetch that couldn't be written says so;
with no copy the layer warns and prints the page to check by hand, and the drift
checks still run. An active tarball with no application versions under `lib/` is
called out ("OTP advisories not checked"), not passed.

Unavailable advisory data is a warning, not a finding, and does not fail
`--strict` or `--security-gate`. That was the brief (MOB-495: "degrade to the
current notes plus a warning when there's no network"), and it matches how those
modes already treat a layer whose scanner is missing (`:tool_missing` doesn't fail
them either). Review argued strict/gate modes should fail closed when a check
couldn't run; that is a reasonable policy, but for every layer at once, so it is
left as a follow-up rather than special-cased here. So that "clean" can't hide
it, `--security-gate` prints every ⚠ note above its "security scan clean" line
(it printed nothing but the counts on a pass before).

## Consequences

- `--strict`, the AGENTS.md pre-commit `mix mob.security_scan --strict`, and
  `mix mob.release --security-gate` fail on any machine whose cache holds the
  active runtime while it has unpatched critical/high/medium advisories. That is
  the point; it clears when the runtime is rebuilt on patched OTP/OpenSSL and
  `active_hash` moves.
- The OpenSSL HTML layout is a dependency. A redesign shows up as an
  "advisory page not recognised" warning with the stale copy in use.
- The `otp-android-x86_64-*` cache dir is not decoded by
  `Fingerprint.locate_cached_tarballs/1` and is not scanned (pre-existing).
