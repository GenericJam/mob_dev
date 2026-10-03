# mob_dev — Agent Instructions

You're in **mob_dev**, the build/deploy/devices toolkit. Read
[`~/code/mob/AGENTS.md`](../mob/AGENTS.md) first for the system view, the
three-repo topology, the cross-cutting pre-empt-failure rules, and the
**"Don't write this slop"** list (AI-generated patterns to avoid at write
time, not after credo flags them). The notes below are mob_dev-specific;
they also cover the repo's public-but-undocumented seams (parsers/predicates
kept public for testing).

For the in-flight build-system refactor (Mix → Igniter → Zig build),
see [`~/code/mob/build_system_migration.md`](../mob/build_system_migration.md) —
multi-month sequenced plan; phase ownership lives there.

## What this repo is

Mix tasks (`mob.deploy`, `mob.connect`, `mob.devices`, `mob.emulators`,
`mob.provision`, `mob.doctor`, `mob.battery_bench_*`) plus their backing
modules (`MobDev.Discovery.{Android,IOS}`, `MobDev.NativeBuild`,
`MobDev.OtpDownloader`, `MobDev.Deployer`, `MobDev.Emulators`).

The **release tooling** lives at `scripts/release/` — shell scripts for
cross-compiling OTP for Android arm64/arm32, iOS sim, and iOS device, then
staging the tarballs and uploading to GitHub Releases. Patches we apply to
OTP source for iOS-device compatibility live at
`scripts/release/patches/` (`forker_start` skip, EPMD `NO_DAEMON` guard).
See `build_release.md` for the full release walkthrough.

## Worktrees

**Default assumption: work happens in a git worktree.** The user runs
multiple agents in parallel; each task in its own worktree prevents conflicts
between agents and keeps `master` clean while work is in flight.

If you're assigned a task and worktree usage **isn't mentioned**, ask:

> "Should I use a worktree for this?"

The user will answer:

- **yes** — long task, or other agents may be working in parallel; create a
  worktree (use `EnterWorktree` or spawn the work via Agent with
  `isolation: "worktree"`)
- **no** — quick change with no parallel agent work; work in-place on the
  current branch

If the user explicitly says "use worktrees" up front, do so without asking.
If the task is trivially small (single-file doc edit, one-line config change)
and clearly won't conflict with anything, working in-place is acceptable —
but if in doubt, ask.

## Issue tracking — status lives in Linear

Status lives in **Linear** (team `MOB`), which is the single board across `mob`,
`mob_dev` and `mob_new` — see `mob/AGENTS.md` for the full split of
responsibilities. The short version, because work in this repo routinely starts
from an issue filed against another one:

- **Linear (`MOB`)** — live status and worklist. One issue per thread.
- **`decisions/`** — durable rationale. Link it from the issue; don't copy it in.
- **PRs / git** — the code. Reference the issue id.

Keep the issue current as you go, not at the end. An issue that says what was
tried and ruled out is worth more than one that says "done" — most of what this
project has learned lives in the ruled-out half.

## TDD is the practice here

Write tests before or alongside new code. Every new function should have
corresponding tests before the task is considered done. The test suite must
stay green at all times.

```bash
mix test                       # all tests
mix test --exclude integration # skip the device-dependent ones
mix test --watch               # (with mix_test_watch dep, if added)
```

**Tests are not just for runtime code.** Every Mix task and every build
tool in this repo gets the same treatment as application code:

- Argument parsing, flag handling, `--help` output
- Output formatting (preview, summary, error messages)
- Decision logic (which device, which build target, which strip set)
- External-tool output classification (adb, simctl, devicectl, gh, xcrun)

The goal is to **find bugs in CI before users hit them.** Real failure
modes encountered this session that were caught (or should have been
caught) by tests:

- `mix mob.uninstall --all-devices` crashing on `nil and bool` because
  the test suite only covered `--help` and `format_summary/4`, not the
  decision path. Backfilled `should_skip_prompt?/2` as a pure helper.
- `mix mob.deploy --device defd4bdc` passing the prefix straight to
  `xcrun simctl install` which only accepts full UDIDs. Now
  `NativeBuild.resolve_booted_udid/2` is pure-and-tested.
- The "Failed on 5 device(s)" mis-tally when skipped-not-installed
  was bucketed as failed. Caught only by manual driving until
  `format_summary/4` and `categorize_results/1` got extracted.

**Pattern to apply:**

1. Identify the pure decision/transform inside a Mix task or
   build-tool function.
2. Extract it to a `def` (not `defp`) — `@doc false` if it's
   for-testing-only, or fully documented if useful to callers.
3. Test the matrix: happy path, every error branch, edge cases
   surfaced by real-world output (paste actual `adb` /
   `xcrun` / `gh` output into fixtures rather than guessing format).
4. The Mix task and external-tool I/O wrappers stay thin and
   unstubbed; the testable kernel is what you assert on.

If something in mob_dev isn't tested today, that's a bug-discovery
opportunity in waiting — list it as a follow-up rather than letting
the next user find it.

## Tests are part of the change, not a follow-up

New behaviour ships with a test unless the change is small enough that a test
would only restate it — a rename, a doc string, a formatting pass. "I'll add
coverage later" is how the untested paths in this repo got there.

The bar is not coverage percentage, it is: **would this test fail if the fix
were reverted?** Check by reverting it. A test that passes either way is worse
than none, because it is claimed as evidence. More than one fix here shipped
with a test that could not fail — including a headline fix whose entire clause
could be deleted with the full suite still green.

## What to test

**Always testable (pure functions, no hardware):**
- `MobDev.Device` — `short_id/1`, `node_name/1`, `summary/1`
- `MobDev.Tunnel` — `base_port/2`, `assign_dist_port/3`, `in_use_ports/4`, `stale_dist_forwards/4`
- `MobDev.Discovery.Android.parse_devices_output/1`
- `MobDev.Discovery.IOS.parse_simctl_json/1`, `parse_simctl_text/1`, `parse_runtime_version/1`
- `MobDev.HotPush.snapshot_beams/0`, `push_changed/2`
- `MobDev.IconGenerator.android_sizes/0`, `ios_sizes/0`, `generate_from_source/2`
- `MobDev.Toolchain.zig_status_from_result/1`

**Hardware-dependent (skip gracefully when devices absent):**
- `Discovery.Android.list_devices/0` — requires adb + connected device
- `Discovery.IOS.list_simulators/0` — requires xcrun
- `Deployer.deploy_all/1` — requires running device
- `HotPush.connect/1` — requires running BEAM node

For hardware tests, use `@tag :integration` and skip them in CI:
```elixir
@tag :integration
test "lists connected Android devices" do ...
```

## Verification fidelity ladder

This repo builds and deploys other people's apps, so its failures are mostly
failures to notice that nothing happened. Run every applicable lower rung, plus
the highest rung the change actually reaches, and say which rung you stopped at.

1. **Static.** `mix format --check-formatted`, `mix credo --strict` (ex_slop
   included), `mix compile --warnings-as-errors`.
2. **Host unit.** `mix test`. Proves the task's logic against fixtures. Proves
   nothing about a real toolchain.
3. **Task run against a real project.** Actually invoke the task on a generated
   app and read the output. A task that unit-tests green can still skip its real
   work — a missing toolchain or a mismatched device id once produced a clean
   exit-0 from a deploy that never built anything, and cost several hours of
   debugging failures that had not happened.
4. **Deployed, and the app answers.** `mix mob.deploy` to a simulator or
   emulator, then attach and confirm the BEAM is up and a screen renders.
   Deploy success is the tool's opinion; a reachable node is evidence.
5. **Physical device, and the release variant.** Release changes linkage and
   packaging: iOS release links plugin NIFs and cpp_archive NIFs, compiles
   plugin Swift, the `mob_register_plugins` bootstrap, project Swift and project
   NIFs, by a separate path that reuses the device build's input functions
   (`decisions/2026-07-07-ios-release-links-plugin-nifs.md`,
   `decisions/2026-10-03-ios-release-compiles-plugin-swift-and-bootstrap.md`,
   `decisions/2026-10-03-ios-release-links-project-inputs-and-plugin-archives.md`), and release
   `otp.zip` handling is variant-scoped
   (`decisions/2026-07-24-release-otp-zip-variant-scoped-assets.md`). A release
   also leaves an `assets/otp.zip` that crash-loops the next debug deploy.
6. **From the packed Hex tarball, not the working tree.** Hex omits
   repository-root dotfiles, so code under `lib/` that reads one compiles here
   and fails for everyone else. Two releases shipped broken this way. Build the
   package and compile from it before publishing.

Every rung above exists because something got through the one below it.

Two rules that outrank the list:

- **Never substitute a lower rung because a higher one is slow, broken, or
  inconvenient.** Fix the harness, open an issue, or state plainly that the rung
  was unavailable and why. An unavailable rung is a fine answer. A silently
  skipped one is not.
- **Verify effects, not exit codes.** This repo is where that rule was learned
  and it is the repo most able to break it: every task here should prove its
  effect happened rather than reporting that it returned.

## Trust the instrument last

Every rung of the fidelity ladder assumes the thing measuring is honest. When it
is not, the failure does not look like an error — it looks like a result.

Two from one session, both of which were believed for a while:

* A navigation benchmark reported a 6.5x improvement. The tree was installed by
  a `LaunchedEffect`, which runs *after* composition, so the frame being timed
  still showed the old screen. The real figure was about half that, and the
  published numbers had to be retracted.
* An on-device check printed `PASS` against a build that had failed to compile,
  because the deploy before it had failed and the previous build was still
  installed. The screen it claimed proved the fix had never scrolled.

So:

- **A number better than the theory allows is a bug in the measurement.**
  Navigation cannot be cheaper than re-rendering the same tree. When the result
  is too good, go and find out why before reporting it.
- **Make a probe fail loudly when its own precondition does not hold.** A check
  that silently passes when the setup did not happen is worse than no check.
- **Corroborate against something you did not build.** Platform counters,
  `Davey!` frame reports, `Skipped N frames`, a screenshot. Agreement within
  30% of an independent source is evidence; your own instrument agreeing with
  itself is not.
- **When you publish a number that turns out wrong, retract it in place** and
  say what was wrong. Someone will otherwise act on it.

## Pre-commit checklist

Before committing changes, run **all** in this order:

```bash
mix test                   # full suite must pass (call out any pre-existing flake explicitly)
mix format                 # apply Elixir formatting
mix credo --strict         # **whole tree, not just changed files** — includes ExSlop (catches AI-generated patterns: blanket rescue, narrator docs, etc). Pre-existing issues are tracked separately, but new ones (including in tests) must be fixed
mix erlfmt --check priv/android/crypto.erl     # Erlang formatting
mix mob.security_scan --strict                 # surface new CVEs / drift before they ship
```

Available but **not run by default** (refactoring queues, not blockers):

```bash
mix ex_dna             # code duplication report (22 clones baseline, ~581 dup lines)
mix reach.check --smells   # 132 style/refactor findings
mix reach.check --dead-code  # 71 findings (some macro DSL false positives)
mix reach                  # interactive HTML architecture report
```

Auto-fix:
```bash
mix erlfmt --write priv/android/crypto.erl
```

`mix mob.security_scan` covers Hex deps, Android Gradle deps, iOS
Swift Package deps, the **bundled OpenSSL/OTP/Elixir/SQLite versions**
(via fingerprint of `~/.mob/cache/otp-*-{hash}/` against
`priv/security/bundled_versions.exs`), and C/Kotlin/Swift static
analysis. See [`README.md`](README.md#security-scan-mix-mobsecurity_scan)
for the full layer list and the one-time `brew install` of external
scanners.

### Decision log — check both directions

Before committing, ask two questions, not one.

**Does this need a new record?** Anything non-obvious: a tradeoff, a workaround,
a convention, a "why X and not Y". The test is whether a reader six months from
now would ask why it is like this. If the commit message is explaining a
decision, that decision belongs in `decisions/` where it is findable, not only
in `git log`. Record it in the same commit, not as a follow-up.

**Does this INVALIDATE an existing record?** This is the half that gets missed,
and it is the more dangerous one. A record asserting a property the code no
longer has is worse than no record: it is a claim a maintainer will act on.
Grep `decisions/` for the mechanism you are changing before you commit.

Both failed in one session, on the same change:

* A decision record claimed "the frame-registry generation is untouched because
  the parked slot stops re-registering once it stops laying out." It reasoned
  about the outgoing direction only. The returning direction was broken —
  silently, for exactly the screens the change optimised for — and the record
  said it was fine.
* Source comments elsewhere stated invariants the same change inverted:
  `MobLazyList`'s latch reasoned that "only navigation changes the container's
  identity", which had just stopped being true.

When you correct a record, correct it **in place** with a note saying what was
wrong, rather than quietly deleting the claim. The wrong version is the part a
future reader needs to recognise, and `decisions/` is append-only for
superseding whole decisions, not for silently editing away a mistake inside one.

### Adversarial review — before the commit, by a subagent

**Non-trivial work gets an adversarial review before it is committed.** Spawn a
subagent, point it at the actual diff, and tell it to find defects rather than
to approve. Act on what it finds, then commit.

It must be a **separate agent**, not a re-read of your own work. The thing that
is wrong is usually the author's mental model of the change, and that model is
exactly what a self-review carries into the second pass.

Give the reviewer: the diff to read (`git diff <base>..HEAD`, and the base
explicitly, since a diverged local branch will otherwise sweep in the whole
tree), what the change claims to do, and the specific things you are least sure
about. Tell it to cite `file:line` for every finding, to rank them
blocking / should-fix / nitpick, and to separate what it verified in source from
what it is reasoning about platform semantics. Ask it to say plainly if the
change is sound rather than inventing problems — but only after it has looked
hard.

**Skip it for** mechanical or trivial changes: formatting, a typo, a version
bump, a changelog edit, moving a file. Reach for it when the change has
behaviour, touches native code, or spans a platform boundary.

This is not ceremony. In one session, pre-commit reviews caught the following
in `mob` — the examples are from there because that is where the session ran,
and this repo builds and deploys exactly that native code — each of which would
otherwise have shipped:

* a helper defined inside `#if !MOB_RELEASE` but called unconditionally from
  Swift, which linked in debug and would have failed **every iOS release
  build**;
* a cache whose tests asserted the write path and nothing about the read, so
  deleting the lookup, or reading under a constant key, passed the whole suite;
* a fix that covered 3 of 7 call sites on one platform while claiming parity
  with the other;
* a comment and a decision record asserting a race was closed when the code
  only narrowed it;
* generated source telling every user that a feature does nothing, in the
  release that made it work.

The one substantial change that skipped review that session was the largest one
in the batch. Do not let size be the reason to skip.

### Before the merge — a second review, on the PR

The pre-commit review reads a diff. This one reads a diff **that claims to be
finished**, against a master that has moved since you started. Those are
different questions, and the second one has caught more.

Both frame-timing PRs in one session passed pre-commit review. The pre-merge
review then found that one of them shipped its headline fix untested — it
deleted the conversion and all 1545 tests still passed — and blocked the other
outright over per-widget state that navigation had silently stopped resetting.
Neither was visible in the diff alone; both needed someone asking "is this
actually done, and does it still fit?"

Give the reviewer the PR, what it claims, and what you are least sure of, and
ask for a verdict — MERGE or DO NOT MERGE, with reasons. Then act on it. A
review you overrule is fine if you say why; a review you skip because the work
felt done is the case this exists for.

**Check the mechanical preconditions yourself; do not delegate them:**

- **CI is green AND the run is newer than the last commit.** A green check from
  before your latest push proves nothing. One PR here carried a month-old green
  run from 40 commits of master ago.
- **The branch is not behind master.** The `pre-push` hook says how far.
- **Cross-repo claims are true now, not eventually.** Documentation that names
  a sibling's version — "requires mob_new 0.4.32" — is false until that version
  exists. Land the sibling first, or make the claim true in the same session.
- **Stacked PRs merge base-first**, and the child gets retargeted and re-checked
  after the base lands.

## Recurring device gotchas — read these before debugging device issues

**iOS sim launches, BEAM dies fast, sim returns to home screen.** Almost
always a host-port collision with `adb`, not a BEAM bug. An Android
device's `adb forward tcp:<port> tcp:<port>` binds `127.0.0.1:<port>` on
the Mac, and iOS sims share the Mac's network stack. `mix mob.deploy`
starts the sim's BEAM on `MobDev.Tunnel.dist_port_for/1` (crc32 of app +
udid into `9100..9899`, bumped past ports registered in EPMD or forwarded to
another device), but a non-BEAM listener or another sim's non-registered
process can still hold it, and then the sim can't bind it. The OTP boot exits
cleanly on `eaddrinuse` and there is no crash report. First diagnostic:

```bash
lsof -nP -iTCP:9100-9899 -sTCP:LISTEN | grep adb
```

…and read `Documents/beam_stdout.log` inside the sim's app container — look
for `Protocol 'inet_tcp': register/listen error: eaddrinuse`. Workaround:
`mix mob.deploy --device <sim-udid> --dist-port 9200`. Full writeup in
`guides/troubleshooting.md` ("iOS simulator: BEAM dies silently…"). This
trap has bitten the iOS sim path several times — Android tooling and iOS
sims compete for the same `127.0.0.1` namespace; check host-port collisions
before suspecting sim or BEAM bugs.

**iOS sim stuck on "Starting BEAM…" forever.** Read
`beam_stdout.log` inside the sim's Documents dir. If you see:

```
step 2 => {error,{"no such file or directory","elixir.app"}}
step 5 => {error,undef}
```

…it's a runtime-path mismatch. `MobDev.Paths.sim_runtime_dir/0` falls back
to `/tmp/otp-ios-sim` when `ios/build.sh` is missing (zig-based iOS builds),
but the build syncs OTP + Elixir stdlib to `~/.mob/runtime/ios-sim`. Workaround
when launching manually:

```bash
SIMCTL_CHILD_MOB_SIM_RUNTIME_DIR="$HOME/.mob/runtime/ios-sim" \
  xcrun simctl launch <udid> com.example.<app>
```

Real fix: `sim_runtime_dir/0` should detect `ios/build.zig` and use
`default_runtime_dir()` for it, so build and launch agree.

## Things that bite specifically in mob_dev

- **Compile-time regex literals are unsafe** on Elixir 1.19 / OTP 28.0. Use
  `Regex.compile!("...", "flags")` for runtime compilation. Already swept in
  0.3.17 — don't reintroduce.
- **Plugin signatures cover `Sign.build_inputs/2`, nothing else.** A new
  `Merge` gatherer (or build step) that reads a file from the plugin directory
  must be added there, or the file is unsigned. A change that would make
  `build_inputs/2` demand files existing marked signatures do not list rejects
  published plugins, so it needs a new coverage marker. Signed envelopes must
  stay decodable by mob_dev 0.7.2: no new atoms, no new payload keys. See
  `decisions/2026-09-30-plugin-signature-coverage.md` (MOB-297).
- **Hex packages omit repository-root dotfiles by default.** Code under `lib/`
  must not compile-time read `.tool-versions` or another root-only file. Keep a
  packaged authority in source, enforce exact lockstep with the root file in a
  source test, and compile the unpacked Hex artifact in the regression suite.
- **`mix mob.deploy --device <id>`** resolves the id via discovery before
  deciding which platform to build. The narrowing logic is in
  `narrow_platforms_for_device/2` and is the single source of truth for both
  build and deploy. Bypass it and you'll get either spurious "No device
  matched" warnings (deploy) or builds for the wrong platform (build).
- **Deployment BEAM discovery follows Mix's active paths.** Use
  `Mix.Project.build_path/0` for dependency output and
  `Mix.Project.compile_path/0` for every application BEAM, including modules
  compiled from `erlc_paths`. Hard-coding `_build/dev` can push a stale,
  incomplete override that shadows the complete application bundle.
- **App config ships as `mob_app_config.beam` in the app's compile path.**
  `MobDev.AppConfig.write!/1` regenerates it from `config/config.exs` +
  `runtime.exs` (minus `:mob_dev`) wherever the app's BEAMs are collected:
  `HotPush`'s `app_compile_path/0` (every deploy/push/watch/Android release),
  the iOS `copy_app_beams/2` (sim + device) and the iOS release script's
  `_build/dev` copy. A new path that ships the app's ebin some other way must
  call it too, or that platform boots with nil config. mob applies it at start.
- **Android deploys relabel `otp/` once, last.** Anything written as root
  (`adb root` push, `ln -s`) keeps root's SELinux categories until
  `relabel_otp_android/1` in `deploy_android/3` runs. Add new device writes
  before that call, never after: the dist (hot) path doesn't restart, so there
  is no later relabel, and the app fails on its next launch (P11: exqlite's
  NIF symlink, `dlopen ... not found`).
- **Physical iOS BEAM overrides must be exact and self-verifying.** The app
  prefers `Documents/otp/<app>` over its complete signed bundle. Replace that
  directory rather than incrementally merging it, require `<app>.beam` before
  transfer, and verify the received bootstrap bytes before restarting.
- **iOS bundle ids resolve through one function per side, never `bundle_id/0`.**
  Consumers (deploy, connect, provision, battery bench) use
  `MobDev.Config.ios_bundle_id/0`; the build (sim bundle, device bundle,
  codesign) uses `NativeBuild.ios_bundle_id/1` over the loaded cfg. Both are
  `:ios_bundle_id || :bundle_id`. Reaching for plain `bundle_id/0` on an
  iOS path is the bug that installed an app under one id and pushed BEAMs at
  another ("App '…' is not installed on this device" right after a
  successful install). Android keeps `bundle_id/0` — the two ids often
  cannot be the same string (Apple forbids `_`). See
  `decisions/2026-08-08-ios-bundle-id-single-source-and-deploy-exit-code.md`.
- **`xcodebuild` errors get rewritten** to actionable hints by
  `diagnose_xcodebuild_failure/1` in `mob.provision`. Apple's verbatim text is
  preserved alongside our hint so the snippet stays google-able. Add new
  pattern matches there when you encounter a new Apple error string.
- **APNs push token never arrives on iOS device** if the binary's codesigning
  entitlements omit `aps-environment`. `NativeBuild.codesign_ios_device_app/3`
  auto-mirrors the value from the embedded provisioning profile into the
  fallback entitlements. If the profile was provisioned without push, no
  mirroring happens — either re-provision with push enabled or create
  `ios/<AppName>.entitlements` with `aps-environment: development`. Test the
  plist text via `NativeBuild.fallback_entitlements_plist/3`.
- **OTP tarball schema changes need bumping `valid_otp_dir?/2`** in
  `otp_downloader.ex` so existing caches auto-redownload. Don't bump the OTP
  hash — the schema check is the right knob.
- **The release scripts assume `~/code/otp` exists** with the right cross-compile
  output. The patches in `scripts/release/patches/` are applied automatically
  by `xcompile_ios_device.sh`, idempotently — re-running is safe.
- **The application-build Zig version is exact.** `MobDev.Toolchain` carries
  its own copy of the pin (`@required_zig_version`; `test/mob_dev/toolchain_test.exs`
  keeps it in lockstep with the root `.tool-versions`, which Hex omits) and both
  native build preflight and `mob.doctor`
  reject any other version. `mob.adopt` deliberately does not rewrite an
  existing Phoenix project's toolchain file: it installs `build.zig`-bearing
  native trees, then the preflight reports a missing or conflicting pin with
  the exact mise command. Changing an adopted app's existing language/runtime
  pins without its owner's consent would be destructive.
- **`mob.add_nif` is the entry point for new NIFs.** Don't add `:static_nifs`
  entries by hand to `mob.exs` — the task already does the AST-aware append,
  generates the Elixir stub via Igniter, and re-runs `mob.regen_driver_tab`
  so `priv/generated/driver_tab_*.zig` stays in sync. `--type` of `c`,
  `zigler`, `rustler` also drops the right native skeleton; `elixir-only`
  (default) leaves the C/Zig/Rust to you. The stubs for zigler/rustler
  carry an explicit static-link warning — those backends produce dlopen'd
  `.so` by default, which is wrong for Mob's iOS App Store /
  Android-RTLD_LOCAL constraints. The host-dev path works; on-device
  shipping needs the user to wire the archive into ios/build.zig +
  android/jni/ themselves. Reach for `--type c` if static linking matters
  more than the source language.
- **`mob.regen_driver_tab` reads `:static_nifs` from `mob.exs`** via
  `Config.Reader`, NOT from `Application.get_env`. mob.exs is not
  auto-imported into Mix application env (this matches every other
  mob_dev task that consumes mob.exs values). If you add a new task that
  reads `:static_nifs`, use `MobDev.Config.load_mob_config()` to stay
  consistent — using `Application.get_env(:mob_dev, :static_nifs, [])`
  silently misses the user's entries.
- **A `mob.exs` that fails to evaluate must raise, never read as empty.**
  Every `Config.Reader.read!("mob.exs")` caller falls back (to `[]`, `%{}`
  or `Application.get_env`) only when the file is *missing*; no `rescue`
  around the read. MOB-280: a blanket rescue in
  `MobDev.Plugin.activated_names/1` turned a mob.exs syntax error into
  "no plugins activated" — the build succeeded and every plugin call hit
  `:nif_not_loaded` at runtime with nothing pointing at mob.exs.
- **`mob.enable` is now Igniter-driven (Phase 4).** Per-feature
  handlers live in `MobDev.Enable.Igniter` and return
  `igniter -> igniter`. When adding a new feature: add a clause to
  the `@valid_features` list in `mob.enable.ex`, a `dispatch/3`
  clause, and an `enable_<name>/2` function in
  `MobDev.Enable.Igniter`. Use `Igniter.update_file` for text-level
  patches (plist, AndroidManifest, JS, HEEX) and AST-aware helpers
  (`Igniter.Project.Module.create_module`, `Project.Deps.add_dep`,
  `Project.Config.modify_config_code`) for Elixir source. Always
  emit `Igniter.add_notice` when a platform dir is missing — silent
  skips were a recurring user-confusion source in the legacy task.
- **File discovery in `Enable.Igniter` is Igniter-aware.** Helpers
  like `find_ios_plist/1` and `find_android_manifest/1` check disk
  first then fall back to `Rewrite.paths(igniter.rewrite)` /
  `Igniter.exists?/2`, so `Igniter.test_project(files: %{...})` in
  tests works without writing to disk. Don't bypass this with raw
  `File.exists?/1` — `mix mob.enable` tests will pass on disk but
  break Igniter test virtualization.
- **`mix mob.enable` reads app name via `Igniter.Project.Application.app_name/1`**,
  NOT `File.cwd!() <> "/mix.exs"`. Under `test_project`, disk reads
  see mob_dev's own mix.exs (wrong app). Falls back to the legacy
  on-disk read only when Igniter has no mix.exs source.
- **`mix mob.adopt` is the install-into-existing-Phoenix task** (Igniter,
  like `mob.enable`). The orchestrator (`Mix.Tasks.Mob.Adopt`) gates on
  `MobDev.AdoptGuard.check/2` then composes the sub-installers
  `mob.adopt.{deps,bridge,screen,mob_app,mob_exs,native,finalize}` — each a
  task module under `lib/mix/tasks/mob/adopt/`. Pre-1.0 it *refuses* (adds
  Igniter issues, no file changes) on unblessed shapes; widen the guard, not
  the silent-proceed path. Shared Elixir-source content + LV-bridge patches
  live in `MobDev.Adopt.Patcher`; assigns / dep-resolution / Pythonx wiring
  in `MobDev.Adopt.Generator`. **The native Android/iOS trees come from
  mob_new's `priv/templates/mob.new/`** — `Generator.templates_root/1`
  resolves a `:mob_new` dep, then `$MOB_NEW_DIR`, then `~/code/mob_new`. Both
  `Adopt.{Patcher,Generator}` are duplicated from mob_new's
  `LiveViewPatcher` / `ProjectGenerator` (mob_new is a self-contained
  archive, can't depend on mob_dev); Phase 5 of `build_system_migration.md`
  reunifies them. See `decisions/2026-06-19-mob-adopt-lives-in-mob_dev.md`.
  `MobDev.AdoptGuard.check/2` / `mode_from/1` and the `Adopt.Patcher` /
  `Adopt.Generator` helpers are public for testing — don't privatise.

## Public-but-undocumented seams

A few helpers are public specifically to enable testing (the parsing and
narrowing functions). Don't make them private:

- `Discovery.Android.parse_devices_output/1`
- `Discovery.IOS.parse_simctl_json/1`, `parse_simctl_text/1`, `parse_runtime_version/1`
- `OtpDownloader.valid_otp_dir?/2`, `ios_device_extras_present?/1`
- `PythonAppleSupport.valid_dir?/1`, `PythonAndroidSupport.valid_dir?/1`
- `NativeBuild.narrow_platforms_for_device/2`, `ios_toolchain_available?/0`, `read_sdk_dir/1`, `fallback_entitlements_plist/3`
- `NativeBuild.pythonx_in_project?/1`, `python_apple_support_env/2`
- `NativeBuild.__prune_plugin_artifacts__/2` (the plugin-removal prune; ledger-tracked per merge concern)
- `Mix.Tasks.Mob.Doctor.__zig_install_fix__/0`
- `Mix.Tasks.Mob.Doctor.__zig_check_result__/1`
- `Enable.inject_pythonx_dep/1`, `inject_pythonx_uv_init_gate/2`, `python_paths_module_template/1`
- `NativeBuild.ios_bundle_id/1` (the `:ios_bundle_id || :bundle_id` rule for the build side)
- `Deployer.ios_bundle_id/0`, `Connector.ios_bundle_id/0` (the same rule on the
  consumer side — public so the WIRING is testable, not just the resolver;
  reverting either to `bundle_id/0` was the original defect and the suite
  did not notice)
- `DistCookie.candidates/2`, `DistCookie.connect/2`, `DistCookie.default_path/1`,
  `DistCookie.load_or_create!/1`, `Discovery.IOS.physical_launch_env/1` (the
  private per-app distribution cookie, its legacy fallback, and its launch plumbing)
- `Emulators.parse_simctl_json/1`, `find_emulator_binary/1`
- `Provision.diagnose_xcodebuild_failure/1`
- `Mix.Tasks.Mob.Deploy.failure_message/3` (which bucket makes a deploy exit non-zero)
- `Uninstaller.resolve_apps_for_device/3` (which id gets uninstalled, per platform)
- `Mix.Tasks.Mob.Doctor.__inactive_nif_plugins_check__/2`, and the documented
  pure kernels of `MobDev.Plugin.NifActivation` (`inactive_nif_plugins/3`,
  `nif_plugins_by_platform/2`, `drift/3`, `parse_record/1`, `node_platforms/2`,
  `record_native_build/3`) — the MOB-281 inactive-NIF-plugin and
  stale-native-build warnings
- `HotPush.runtime_lib_names/0` (which deps ship to the device — the push set,
  and the scope of the MOB-281 inactive-plugin warning) and
  `Plugin.Manifest.nif_for_platform?/2` (the one NIF platform rule — lives in
  `Manifest`, not `Merge`, because every public `Merge` function must be a
  classified gatherer; see `conflict_surface_test.exs`)
- `MobDev.AppConfig.read/1` and `compile/2` (what config reaches the device)
- `MobDev.NodeUtil.start_host_dist/3` (host node name, with the per-process
  fallback when `mob_dev@127.0.0.1` is taken)
- `Tunnel.forward_owner/2`, `Discovery.Android.pick_registered_node/2` (attach
  mode of `mix mob.connect --no-restart`) and `Deployer.prune_other_versions_cmd/2`
- `IconGenerator.platforms/1`, `platforms_missing_icons/1` (icons only for the
  platforms the project has)
- `MobDev.AppLifecycleHooks.check/2` (the mob 0.9.6 Android lifecycle-hook
  check shared by `mix mob.doctor` and the Android native build) and
  `Connector.ios_scan_needed?/2` (when `mob.connect` skips iOS discovery)
- `Tunnel.base_port/2`, `assign_dist_port/3`, `in_use_ports/4` and
  `stale_dist_forwards/4` (the serial + app dist-port rule, and which
  forwards `mob.connect` may remove); deploy and connect must both go through
  `Tunnel.dist_port_for/1`, or they disagree on the port
- The `@doc false` kernel of `MobDev.Smoke` (`parse_report/1`, `find_claim/2`,
  `test_argv/3`, `run_paths/4`, `health_findings/2`, `receipts_delta/2`,
  `receipt_findings/3`, `failure_hints/2`, `verdict/1`, …) and
  `Mix.Tasks.Mob.Smoke.run/2`, which takes the agent-device runner, discovery,
  connect, node wait and RPC as functions so the task is tested end to end with
  fakes. `Mix.Tasks.Mob.Deploy.target_error/3` is shared with `mob.smoke`'s
  device selection. agent-device's `"success": true` is not a pass, Diag
  counters reset with the app's BEAM (so health is read per flow), and
  `Mob.Agent.Receipts.count/0` is bounded; see
  `decisions/2026-09-30-mob-smoke-replays-agent-device-flows.md`
- `MobDev.DeviceLeases.parse_status/1`, `current_session/1`, `foreign_claim/2`
  and `partition/2` (which agent-device claims block auto-selection), and
  `MobDev.Plugin.TrustStore.trust_stanza/1` / `Mix.Tasks.Mob.Plugin.Trust.version/3`
  (the one-entry-per-line trust map and the version shown for review)
- `Release.plugin_ios_swift_env/3` and `plugin_ios_swift_env_written/3` (which
  Swift files the iOS release script compiles: the plugins' plus the bootstrap
  that defines `mob_register_plugins`, by the dev path's
  `NativeBuild.ios_plugin_swift_mode/2` rule, which `ios_build_file_supports_plugins?/1`
  feeds; the second is the I/O edge), `Release.plugin_release_env/3` (every
  plugin env var, behind the plugin signature/trust/capability gate) and
  `Release.release_env/4` (the assembled script env). See
  `decisions/2026-10-03-ios-release-compiles-plugin-swift-and-bootstrap.md`
- `NativeBuild.project_nif_build_inputs/1`, `project_swift_sources/1` and
  `build_plugin_static_archives/3`, plus `Release.project_release_env/3` (MOB-373:
  the project NIFs, project Swift and cpp_archive plugin archives a device build
  links, as data the zig builds and `mix mob.release --ios` both consume;
  `project_nif_zig_args/1` renders its `-D` args from the first). See
  `decisions/2026-10-03-ios-release-links-project-inputs-and-plugin-archives.md`
- `NativeBuild.with_temp_build_dir/2`, `ios_build_inputs_dir/1` and
  `write_build_input!/2` (MOB-313: the iOS `.app` goes in a temp dir removed
  on every exit path; the sources zig compiles stay at stable paths so its
  cache hits; see
  `decisions/2026-10-01-ios-build-sources-stable-app-dir-removed.md`)

If you make any of these private, every downstream test breaks loudly — but
you'll lose the ability to evolve the parsers safely.

## Destructive-task conventions

Apply consistently to every Mix task that mutates device state
(`mix mob.uninstall`, `mix mob.deploy`,
`mix mob.connect`, future ones).

**Emulator vs physical safety pattern (from `mix mob.uninstall`):**

- `--all-devices` sweeps **emulators and simulators only**. NEVER
  physical devices. Phones are someone's personal property and have
  real-data blast radius; emulators are throwaway dev fixtures.
- `--all-physical` is the opt-in for sweeping physical devices.
  Composes with `--all-devices` for "literally everything."
- `--device <id>` is the explicit-id escape hatch — the user typed
  the id, that's consent; bypasses the type filter regardless of
  whether the device is emulator or physical.
- **Auto-detect** (no flags, exactly one device connected) only
  fires for a non-physical device. A solo phone connected with no
  flags → error with a hint pointing at `--all-physical` or
  `--device`.
- **agent-device leases** (MOB-330): every selection the user did not
  name — auto-detect and both broad flags — skips devices another
  `agent-device` session has claimed and prints each skip; a claimed
  device named with `--device` is used after a loud warning. A claim is
  the caller's own when its session equals `AGENT_DEVICE_SESSION`.
  Read the claims once with `MobDev.DeviceLeases.load/0` and filter with
  `exclude_claimed/3` / `warn_claimed/2` (TaskTargets does this when given
  `:leases`; `Connector.connect_all/1` and `HotPush.connect/1` load them
  themselves). A new task that picks devices on its own must do the same,
  and so must anything that acts on devices outside the selection: the
  stale-app cleanup (`Connector.stale_simulator_pids/3`) and a watcher's
  cached nodes (`HotPush.reconnect/2`). An iPhone found over the LAN has its
  IP as its serial and counts as claimed while any foreign claim could be an
  iPhone.

The predicate to route on is `MobDev.Device.physical?/1`. Shared
selection logic lives in `MobDev.TaskTargets`; task-specific planning
and error messages wrap it. Pin the headline guarantee in
each task's tests — "personal iPhone + dev emulators + `--all-devices`
must leave the iPhone alone."

## Naming gotcha: `mix mob.install` vs `mix mob.uninstall`

These look like inverses but aren't. Future agents touching either
should know:

- **`mix mob.install`** — first-run **project setup**. Downloads the
  OTP runtime, generates icons, writes machine paths to the gitignored
  `mob.local.exs` (never rewrites the committed `mob.exs`). Per-project, runs
  once. Doesn't touch any device. A later `mix mob.deploy --native` also
  repairs or creates `android/local.properties` when it can detect the SDK;
  fresh worktrees therefore do not need another interactive install just to
  restore that gitignored machine-local file.
- **`mix mob.uninstall`** — per-**device** app removal. Sweeps
  connected devices and removes installed `.app` / `.apk` bundles.
  Doesn't undo `mix mob.install`'s project setup.

A user reading the task list will plausibly type `mix mob.uninstall`
expecting it to undo `mix mob.install`. If we ever want true
symmetry, the device-cleanup task wants a clearer name (e.g.
`mob.app.uninstall` or `mob.devices.clear`) and `mob.uninstall`
could become the project-cleanup inverse of `mob.install`. Until we
make that call, the help text in both task @moduledoc blocks
should call out the scope difference explicitly. Don't quietly
rename — users have muscle memory by now.

## Key files

- `lib/mob_dev/device.ex` — device struct + `node_name/1`, `short_id/1`
- `lib/mob_dev/tunnel.ex` — adb tunnel setup, serial + app derived dist ports (`base_port/2`, `assign_dist_port/3`, `dist_port_for/1`)
- `lib/mob_dev/hot_push.ex` — BEAM snapshot + RPC push
- `lib/mob_dev/deployer.ex` — full BEAM push + app restart
- `lib/mob_dev/connector.ex` — discover → tunnel → restart → wait → connect
- `lib/mob_dev/discovery/android.ex` — adb device discovery
- `lib/mob_dev/discovery/ios.ex` — xcrun simctl discovery
- `lib/mix/tasks/mob.deploy.ex` — `mix mob.deploy`
- `lib/mix/tasks/mob.push.ex` — `mix mob.push`
- `lib/mix/tasks/mob.watch.ex` — `mix mob.watch`
- `lib/mix/tasks/mob.connect.ex` — `mix mob.connect`
- `lib/mix/tasks/mob.devices.ex` — `mix mob.devices`
- `lib/mob_dev/icon_generator.ex` — robot avatar generation + platform icon resizing
- `lib/mix/tasks/mob.icon.ex` — `mix mob.icon [--source PATH]`
- `lib/mix/tasks/mob/adopt.ex` — `mix mob.adopt` orchestrator (install Mob into an existing Phoenix project)
- `lib/mix/tasks/mob/adopt/` — the adopt sub-installers (`deps`, `bridge`, `screen`, `mob_app`, `mob_exs`, `native[/android,/ios]`, `finalize`)
- `lib/mob_dev/adopt_guard.ex` — `MobDev.AdoptGuard`, the pre-1.0 detect-and-refuse for `mob.adopt`
- `lib/mob_dev/adopt/patcher.ex` / `lib/mob_dev/adopt/generator.ex` — `MobDev.Adopt.{Patcher,Generator}`, the shared LV-bridge patches + EEx assigns/dep-resolution (duplicated from mob_new; see the adopt ADR)
- `lib/mob_dev/toolchain.ex` — `MobDev.Toolchain`, the exact Zig pin (lockstep with `.tool-versions` via `test/mob_dev/toolchain_test.exs`)

## Connecting an IEx session to a running mob app (Mac → device BEAM)

Drive any running mob app from a Mac-side IEx via Erlang
distribution. Beats `adb shell input tap` for anything
state-related — you get full RPC into the device BEAM.

### The happy path (single device)

```bash
cd /path/to/your_mob_app

mix mob.connect            # starts IEx connected to all devices
# or
mix mob.connect --no-iex   # sets up tunnels, prints node names, exits
```

Another IEx (or one-shot script) needs the app's private cookie. Load it
inside the VM, from the project directory, so it never appears in the
process arguments:

```bash
elixir --name probe@127.0.0.1 -S mix run --no-start -e '
Node.set_cookie(MobDev.DistCookie.for_project!())
node = :"your_app_android_<suffix>@127.0.0.1"
Node.connect(node)
:rpc.call(node, YourApp.Module, :function, [args])
'
```

In an `iex --name me@127.0.0.1 -S mix` session, run
`Node.set_cookie(MobDev.DistCookie.for_project!())` first.

The cookie is per app, kept under `~/.mob/dist_cookies/` and handed to the app
at deploy/connect time (Android: a file in its private storage; iOS: the launch
environment). An app built against a mob from before MOB-49 still uses the
public `mob_secret`; mob_dev's tasks fall back to it with a warning. `--name`
(long names) is required when the device node uses a numeric host like
`@10.0.0.120`.

### Multi-Android — node naming (FIXED 2026-05-28, commit `7497f4b`)

`mob_dev` now derives the Android dist node-name suffix from the device
**serial** (matching what `Mob.Dist` actually registers), not the IP.
Emulators get distinct suffixes like `emulator_5554` / `emulator_5556`,
so two emulators no longer collide in EPMD. The bug was in
`discovery/android.ex` `enrich/1` — it had a duplicated half-implementation
of `device_node_suffix/1` that was IP-based, while the correct serial-based
helper already existed and was used in `restart_app/4`. See ADR
`decisions/2026-05-28-android-node-name-by-serial.md`.

Physical (USB/Wi-Fi) Android is unchanged: still keyed off `ro.serialno`.
iOS untouched.

### Dist ports are serial + app derived (0.6.7; app added in 0.7.5)

Dist ports are no longer assigned by per-run index (which made *every*
project's first device claim 9100 → cross-project collisions in the one
shared Mac EPMD → silent timeouts). `Tunnel.base_port/2` maps a device
serial plus the app name to a stable port in `9100..9899` (crc32 hash), and
`assign_dist_port/3` bumps past any port another live node or another
device's forward already holds. Keying on the serial alone gave two apps on
one device the same port, and the second one's dist failed with
`:nodistribution` (N18). Deploy and connect both resolve the port through
`Tunnel.dist_port_for/1`, so they agree. The device-side BEAM listens on that
port (via `MOB_DIST_PORT` / the `mob_dist` file), so the forward is 1:1 and
EPMD's broadcast matches. `setup` removes the device's stale dist forwards
first, but never one another app on the same device is live on.

If `mix mob.connect` still fails, it now tells you *why* (app not running /
Standby-killed, dist not registered, port mismatch, no forward, cookie
mismatch) instead of a bare "timed out". To inspect by hand:

```bash
epmd -names           # registered nodes + their ports
adb forward --list    # host→device forwards (should be 1:1, no dupes)
```

For physical-device-on-Wi-Fi targets (iPhone, real Android), the
node name uses the device IP directly (`@10.0.0.120`) and dist
goes through real network — no adb-forward dance required.

### Inspecting state that contains opaque resources

Several mob/Pigeon operations return values containing opaque NIF
resources (e.g. `Pythonx.Object`, ETS table refs). These cannot
cross Erlang distribution: `:rpc.call/4` will fail with `:badrpc`
on the way back. Pattern: do the resource-touching work *on the
device side* and return primitives (strings, maps, ints).

Example — bad (returns `Pythonx.Object`, dies on dist boundary):

```elixir
:rpc.call(node, Pythonx, :eval, [src, %{}])  # returns {Pythonx.Object, _}; cannot serialize
```

Good — wrap in a helper module compiled into the app:

```elixir
defmodule YourApp.IexHelpers do
  def python_state do
    {obj, _} = Pythonx.eval("...", %{})
    Jason.decode!(Pythonx.decode(obj))   # plain map; safe to ship
  end
end
```

Then `:rpc.call(node, YourApp.IexHelpers, :python_state, [])` works.
Pigeon has `Pigeon.IexHelpers` exactly for this purpose — copy
that pattern when adding device-side debugging surfaces.

### What to reach for first

Write small named functions in `<your_app>.IexHelpers`, push with
`mix mob.deploy`, call by RPC. That keeps the Mac-side script
minimal and debuggable, and the helpers double as documentation
of the operations you actually need.

---

## Release flow

Canonical process lives in
[`mob/RELEASE.md`](https://github.com/GenericJam/mob/blob/master/RELEASE.md)
— trigger model (mix.exs as source of truth), patch-bump default with
mandatory permission, CHANGELOG conventions, per-step idempotency of
`release.yml`.

> **Review gate is on by default.** Everything that landed since the
> last published version gets a code review *before* you publish —
> scoped at `v<last-published>..HEAD`, not per-PR — plus the
> version-sanity checks (is this version already published? did
> anything merge after the bump commit?). Skip only if the user says
> so. See RELEASE.md → "Review gate".

**mob_dev specifics:**

- The pre-push hook (below) additionally runs `mix mob.security_scan`
  in this repo — the scanner ships from here, so we get the
  highest-fidelity check before pushing.
- OTP runtime tarballs (`otp-<hash>` releases on the `mob` repo) are
  built and published manually via `scripts/release/` — they are NOT
  driven by `mix.exs` bumps. See `## Releasing a new OTP runtime`
  below for the tarball workflow. The `mix.exs` bump that ships a
  `@otp_hash` change in `lib/mob_dev/otp_downloader.ex` follows the
  standard release flow.

**Pre-push hook**: `.githooks/pre-push` runs `mix format
--check-formatted`, `mix credo --strict`, `mix compile
--warnings-as-errors` on every push (fast). When the push touches
`mix.exs` it additionally runs the full test suite + `mix
mob.security_scan` as the release preflight. Activate once per clone
or worktree:

```bash
git config core.hooksPath .githooks
```

## Releasing a new OTP runtime

When upgrading OTP, you need to rebuild the pre-built tarballs that
`MobDev.OtpDownloader` downloads. See [`build_release.md`](build_release.md)
for the full process (staging, adding headers + static libs, uploading to GitHub,
updating the hash in `otp_downloader.ex`).

## Decision log

Non-obvious decisions — tradeoffs, workarounds, conventions, "why we chose X
over Y" — go in `decisions/`, **one file per decision**:

    decisions/YYYY-MM-DD-short-slug.md

Each file is a lightweight ADR:

    # <Title>
    - Date: YYYY-MM-DD
    - Status: accepted | superseded by <file> | proposed
    ## Context        — what prompted this
    ## Decision       — what we chose
    ## Consequences   — tradeoffs, follow-ups

**Append new files; never rewrite a decision.** If a decision changes, add a
new file and mark the old one `Status: superseded by <new-file>`. If a record
was *wrong*, correct it in place with a note saying what was wrong (see
"Decision log — check both directions" above). One file per
decision keeps the log conflict-free across parallel agents/worktrees — the
date-sorted directory listing is the index. Record a decision the moment you
make a non-obvious call, not later.

## Keep this file up to date

When you change repo conventions, add a public seam, or hit a gotcha that
should have been on the list — update this file in the same commit, not as a
follow-up. Stale guidance is worse than none.
