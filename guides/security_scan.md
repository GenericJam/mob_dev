# Security scanning

Mob ships three commands for tracking known vulnerabilities across
every surface a Mob app actually compiles into the binary:

| Command | When to use it |
| ------- | -------------- |
| `mix mob.security_scan` | One-off scan. Pretty terminal output for the human at the keyboard. |
| `mix mob.security_scan.log` | Scheduled run (cron / GitHub Actions). Writes a current snapshot, prepends a delta entry to a changelog, and persists state across runs. |
| `mix mob.release --security-gate` | Release-time gate. Runs the scan, aborts the build on any critical/high/medium finding. |

All three sit on top of the same scan engine — pick the wrapper
that matches your trigger.

---

## What gets scanned

Seven layers, each running independently and aggregated into one
report. A missing external scanner is a soft warning (the layer
reports `tool missing`), not a failure.

| Layer | Tool(s) | Surface area |
| ----- | ------- | ------------ |
| `hex_deps` | [`mix_audit`](https://hexdocs.pm/mix_audit/) + [`osv-scanner`](https://google.github.io/osv-scanner/) | Hex deps in `mix.lock`. Two sources because they miss different things — the Erlef CNA feed (osv-scanner) tends to surface CVE-numbered advisories Mirego's curated database (mix_audit) hasn't ingested yet. |
| `gradle_deps` | `osv-scanner` | Android Gradle deps. Best results when you've turned on Gradle dependency locking — see "Enabling Gradle dependency locking" below. |
| `swift_deps` | `osv-scanner` | iOS Swift Package Manager (`Package.resolved`) and CocoaPods (`Podfile.lock`). |
| `bundled_runtime` | manifest + binary fingerprint | OpenSSL, ERTS, Elixir, exqlite, SQLite **baked into Mob's pre-built OTP tarball**. Generic dep scanners can't see these because they're in static archives, not lockfiles. |
| `c_source` | [`semgrep`](https://semgrep.dev/) + [`flawfinder`](https://dwheeler.com/flawfinder/) | Mob's NIF C/Objective-C plus the exqlite NIF wrapper. Excludes the SQLite amalgamation (huge, battle-tested, would generate thousands of low-value findings). |
| `kotlin_source` | [`detekt`](https://detekt.dev/) | Kotlin/Java under `android/app/src/main/`. Set `MOB_DETEKT_CONFIG=path` to use a security-focused rule config. |
| `swift_source` | [`swiftlint`](https://github.com/realm/SwiftLint) | Swift under `ios/`. Mob's iOS bridge is mostly Objective-C, which is covered by `c_source` instead. |

The `bundled_runtime` layer is the one that makes Mob's scan
unusual. It opens `libcrypto.a` from the cached OTP tarball, scans
the `.rodata` section for the OpenSSL version banner, and emits a
`:high` finding if the binary disagrees with what
[`priv/security/bundled_versions.exs`](../priv/security/bundled_versions.exs)
claims shipped. That manifest is the source of truth for what's
inside the static archives Mob distributes; the fingerprinter is
the receipt that proves the manifest is honest.

---

## One-time setup

```bash
brew install osv-scanner semgrep flawfinder detekt swiftlint
```

`mix_audit` is a Hex dependency of `mob_dev`, no extra install.
The OpenSSL/SQLite/OTP fingerprinting is pure Elixir — no external
`strings(1)` or similar required.

Each layer soft-degrades when its scanner is missing, so install
incrementally as you want fuller coverage. `osv-scanner` is the
highest-value install (it drives three layers).

---

## `mix mob.security_scan`

The interactive entry point. Run it whenever you want to know "what
does this project look like right now?".

```bash
mix mob.security_scan                         # full scan, terminal output
mix mob.security_scan --json                  # machine-readable to stdout
mix mob.security_scan --skip kotlin_source,c_source
mix mob.security_scan --strict                # exit 1 on any critical/high/medium
mix mob.security_scan --write-report SECURITY_SCAN.md
```

Output is severity-coloured, sorted critical → unknown, with
`fixed_in` versions when known and clickable advisory URLs.

---

## `mix mob.security_scan.log`

The scheduled-run wrapper. Designed for cron, GitHub Actions, or
any other recurring trigger. Each run writes three files at the
project root:

| File | Role |
| ---- | ---- |
| `SECURITY_SCAN.md` | Current-state snapshot, overwritten each run. |
| `SECURITY_HISTORY.md` | Append-only changelog, newest entry on top. Each entry has **New since last scan**, **Resolved since last scan**, and **Still present from last scan** sections. Persisting findings carry a `_(first seen N days ago)_` patch-lag suffix. |
| `.security_scan/state.json` | JSON sidecar that records the last-known finding set + per-finding `first_seen_at` timestamps. |

**Commit all three.** The state file is what makes the changelog
meaningful across machines and CI runs — without it, every run
reports every finding as "new" and the timeline loses signal.

### A typical history entry

```markdown
## 2026-05-07T13:59:24Z

**Project:** `/Users/me/myapp`
**Total findings:** 2 (0 critical, 2 high, 0 medium, 0 low, 0 unknown)

### New since last scan (1)
- **HIGH** `mob/otp-tarball@ios_sim` `[MOB-DRIFT-ios_sim-elixir]` —
  Bundled-versions drift: Elixir manifest=1.19.5 binary=1.20.0-rc.4

### Resolved since last scan (1) ✓
- **HIGH** `phoenix@1.8.5` `[EEF-CVE-2026-32689]` —
  Long-poll NDJSON body splitting causes unbounded memory allocation

### Still present from last scan (1)
- **CRITICAL** `openssl@3.4.0` ... _(first seen 22 days ago)_
```

### Cron entry

```bash
# daily at 06:00 local
0 6 * * *  cd /path/to/project && mix mob.security_scan.log >> /tmp/security_scan.log 2>&1
```

### GitHub Actions workflow

Opens a PR each week with the three files updated:

```yaml
name: security-scan
on:
  schedule: [{cron: "0 6 * * 1"}]
  workflow_dispatch:
jobs:
  scan:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - uses: erlef/setup-beam@v1
        with: {elixir-version: "1.19", otp-version: "28"}
      - run: brew install osv-scanner semgrep flawfinder detekt swiftlint
      - run: mix deps.get
      - run: mix mob.security_scan.log
      - uses: peter-evans/create-pull-request@v6
        with:
          title: "security: weekly scan update"
          branch: security-scan-update
          add-paths: |
            SECURITY_SCAN.md
            SECURITY_HISTORY.md
            .security_scan/state.json
```

Each scan becomes a small, reviewable PR that explicitly tells you
"this week we fixed N, found M new, still owe these K."

---

## `mix mob.release --security-gate`

The release gate. Wraps `mix mob.security_scan --strict` around
your release build so a vulnerable artifact never reaches signing.

```bash
mix mob.release --android --security-gate
mix mob.release --ios --security-gate
```

If the scan surfaces any critical/high/medium finding, the release
aborts with exit code 1 — nothing is built, nothing is signed.
Low/unknown findings are non-blocking (you can review them in
`SECURITY_SCAN.md`).

The same flag works alongside the existing release flags:

```bash
mix mob.release --ios --slim --security-gate
```

The success printouts of `mix mob.release` mention `--security-gate`
as a tip whenever the gate wasn't used, so the option stays visible.

---

## Updating after rebuilding the OTP tarballs

When Mob's pre-built OTP runtime is rebuilt
([`build_release.md`](../build_release.md)),
[`priv/security/bundled_versions.exs`](../priv/security/bundled_versions.exs)
must be updated to declare the new versions baked into each
tarball. The `bundled_runtime` layer fingerprints the cached
binaries on disk and emits a `:high` "manifest drift" finding if
the manifest disagrees with what's actually shipping — that's the
exact failure mode the manifest exists to catch. Update it in the
**same PR** as the OTP hash bump.

---

## Enabling Gradle dependency locking

By default, Gradle doesn't lock transitive dependencies, which
means `osv-scanner` only sees the deps you've declared in
`build.gradle`. To get full transitive coverage, opt into Gradle's
dependency locking:

```gradle
// android/build.gradle
allprojects {
  configurations.all {
    resolutionStrategy.activateDependencyLocking()
  }
}

// android/app/build.gradle
dependencyLocking {
  lockAllConfigurations()
}
```

Then run:

```bash
cd android && ./gradlew :app:dependencies --write-locks
```

`gradle.lockfile` will appear under `android/app/`. Commit it.
Subsequent scans will pick up every transitive dep and surface
its CVEs.

---

## Tradeoffs and limitations

- **No live OpenSSL/SQLite CVE feed.** OpenSSL retired its JSON
  feed and OSV.dev doesn't index native libraries as packages.
  The `bundled_runtime` layer instead reports the exact OpenSSL
  and SQLite versions it found and points you at the upstream
  advisory pages (`openssl-library.org/news/vulnerabilities/`,
  `sqlite.org/cves.html`) so you can verify manually. The
  manifest-drift detection is real and runs every scan — that
  catches the most common failure mode (your manifest is lying
  about what shipped).

- **`xcodebuild analyze` is not in the Swift layer.** The Clang
  Static Analyzer is the gold standard for Objective-C and Swift
  but requires a buildable Xcode project (signing, provisioning,
  the works). `swiftlint` is the pragmatic substitute that doesn't
  need a build. If you want clang-analyze in CI, run it as a
  separate step.

- **SQLite amalgamation is excluded from C-source scanning.** It's
  ~9MB of well-tested code; running general C rules over it would
  produce thousands of low-value findings. Use the
  `bundled_runtime` layer to track its version against the SQLite
  advisory page instead.
