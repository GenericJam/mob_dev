# Slim Release — Cutting the iOS bundle from 45 MB to 19.8 MB

This guide is the working record of how the Mob iOS bundle went from
**45 MB** (the size that kept TestFlight rejecting builds for being
"unnecessarily large") down to **19.8 MB** — a 56% reduction, all
without dropping a single feature.

It also documents the toolchain we built along the way, why the
defaults are asymmetric between dev and release, and how to bisect a
broken build using the per-step `[SLIM:<tag>]` traceability markers.

> The decision to eventually extract this work as a standalone Hex
> package (`lean_release`) is tracked in
> [`lean_release_extraction.md`](../lean_release_extraction.md). For
> now, everything ships inside `mob_dev`.

---

## TL;DR

```bash
mix mob.deploy             # dev iteration — slim OFF (fast, ~2-3s saved per build)
mix mob.deploy --slim      # dev iteration — slim ON (verify before TestFlight)
mix mob.release            # App Store / TestFlight — slim ON
mix mob.release --no-slim  # App Store / TestFlight — slim OFF (debugging only)
```

Search for `[SLIM:<step>]` in the build log to see how many KB each
strip pass shaved off. If a step breaks the build, this is your bisect
log.

---

## The 45 → 19.8 → ?? MB journey

| Build  | IPA size | What changed                                                            |
| ------ | -------- | ----------------------------------------------------------------------- |
| Before | 45 MB    | Vanilla `mix mob.release` — full OTP runtime, no strips                 |
| Step 1 | 37 MB    | Apple-policy strips made traceable + made always-on                     |
| Step 2 | 27 MB    | Added `prefix_libs`, `foreign_apps`, `dedup_versions`, `src_and_headers`|
| Step 3 | 19.8 MB  | `beam_chunks` strip (Dbgi/Docs chunks, `:beam_lib.strip_release/1`)     |
| Step 4 | TBD      | Pass 1: C-side `-Os -ffunction-sections -fdata-sections` + `--gc-sections` |

### Pass 1: C-side dead-section elimination (2026-05-06)

Inspired by the [GRiSP nano writeup (2025-06-11)](https://www.grisp.org/blog/posts/2025-06-11-grisp-nano-codebeam-sto)
where the same flags were the single biggest C-side shrink for fitting
the BEAM into 16 MB of OctoSPI DRAM. The mechanic:

- `-Os` (size-optimised) over the default `-O2` / `-O3`.
- `-ffunction-sections -fdata-sections` puts every function and global
  data object in its own ELF/Mach-O section.
- `-Wl,--gc-sections` (GNU ld, used on Android) and `-Wl,-dead_strip`
  (ld64, used on iOS) drop sections nothing references at link time.

Together they let the linker delete unused functions from `libbeam.a`,
`libcrypto.a`, our `crypto.a` static NIF wrapper, and our own
`libpigeon.so` / iOS app binary. This is the C-side analog of what
`beam_lib:strip_release/1` does for `.beam` files.

Applied to:
- All four OTP cross-compiles (`xcomp/erl-xcomp-*-android.conf`,
  `xcomp/erl-xcomp-arm64-ios{,simulator}.conf`).
- All four OpenSSL cross-compile scripts in `scripts/release/openssl/`.
- The custom `build_crypto_static_*.sh` scripts that recompile
  crypto's NIF C sources with `-DSTATIC_ERLANG_NIF -fPIC`.
- The Android `CMakeLists.txt` template in `mob_new` and
  `mob_dev/lib/mob_dev/native_build.ex`'s generated iOS-device link.
- The iOS `build.sh.eex` template (sim-build link).

Size delta recorded in `~/code/mob/crypto_plan.md` once the rebuild +
republish cycle completes.

Sample `[SLIM:...]` log from a recent release build:

```
[SLIM:prefix_libs]    120824 KB → 74756 KB   (-46068 KB)
[SLIM:foreign_apps]    74756 KB → 74020 KB     (-736 KB)
[SLIM:dedup_versions]  74020 KB → 64012 KB  (-10008 KB)
[SLIM:src_and_headers] 64012 KB → 47840 KB  (-16172 KB)
[SLIM:beam_chunks]     47840 KB → 27552 KB  (-20288 KB)
```

Note that the first column above is the OTP _runtime tree_ (~120 MB
unzipped on disk), not the IPA. The IPA is the codesigned `.app`
zipped with `ditto` after these strips, plus the main Mach-O.

---

## What gets stripped (and why)

Every step is a separate bash invocation routed through the
`slim_step <tag> <command>` helper. Each prints a tagged size delta so
the build log makes the impact of each step obvious — and so a
regression in a single step can be bisected from the log alone.

### `apple_binaries` (always on, never gated)

Apple's App Store validator (error 90171) rejects bundles with `.so`,
`.a`, or any standalone Mach-O other than the `CFBundleExecutable`.
We strip all of these from the bundled OTP runtime. This is the **one
strip that runs even with `--no-slim`** — it's not optional for
shipping to TestFlight or the App Store.

What goes:

- `*.so` and `*.a` everywhere under `OTP_BUNDLE`
- `priv/bin/*` (memsup, cpu_sup, et al.)
- `erts-*/bin/*` (erl_call, erlexec, et al.)

### `prefix_libs`

Strips OTP applications by name prefix that no Mob app ever loads.
The biggest single saving — typically 40–50 MB.

The current strip set:

```
megaco runtime_tools erl_interface os_mon wx et eunit
observer debugger diameter edoc tools snmp dialyzer
syntax_tools parsetools xmerl reltool inets ftp tftp
common_test mnesia eldap odbc
compiler ssh                                     # 2026-05-06
```

The 2026-05-06 additions came from `Mob.Diag.loaded_snapshot/0` against
a running pigeon iOS-sim build: 0 of 59 `compiler-9.0.5` modules and
0 of 43 `ssh-5.5.1` modules ever loaded. ~4.4 MB win, no observed
regressions on either platform. **Risk floor:** any mob app that calls
`Code.eval_string/1`, `Code.compile_string/1`, `:erl_eval.eval_str/1`,
or starts an `:ssh` client/server breaks. None of the apps in this
tree do; new apps with those needs need to drop the strip in
`MobDev.Release` / `MobDev.NativeBuild`.

**Empirical-snapshot-driven additions are the way.** Apps that
shouldn't have made the strip set show up in the next loaded_snapshot
diff. The dance: deploy → `mob.snapshot_loaded` → see what's loaded
that shouldn't be vs. shipped that's never used → iterate.

Adding to this list is a one-line change in `lib/mob_dev/release.ex`
(and the matching `lib/mob_dev/native_build.ex` for dev parity, plus
the test list in `test/mob_dev/release_script_test.exs`). Any prefix
on this list will balloon the bundle if removed — only do that if a
specific app actually depends on it at runtime.

### `foreign_apps`

If you've ever run `mix mob.release` from a checkout that shares a
dep cache with another project, you may end up with `toy_*`,
`test_*`, `mob_test`, or `scratch_*` apps shipping in the bundle.
These are not OTP apps and definitely not _your_ app — they leaked in
from another release tree. This strip drops them.

### `dedup_versions`

`asn1-5.4` and `asn1-5.4.3`. `public_key-1.18` and `public_key-1.20.2`
and `public_key-1.20.3`. The OTP runtime cache accumulates older
versions of libraries when you upgrade. Only the newest version is
ever loaded; older versions are dead weight. This step keeps the
highest version of each library and removes the rest.

The duplicate detection logic is in
`MobDev.OtpAudit.collapse_duplicates/1` — covered by unit tests in
`test/mob_dev/otp_audit_test.exs`.

### `src_and_headers`

`src/*.erl` and `include/*.hrl` are compile-time only. They are not
loaded at runtime. They sit in the bundle out of habit because OTP's
release packager copies the whole library directory. We drop them.

This is a ~16 MB win on a typical Mob app.

### `beam_chunks`

`:beam_lib.strip_release/1` removes the `Dbgi`, `Docs`, `Atom`, and
`Locals` chunks from every `.beam` file in the bundle. Roughly 30%
saved per `.beam` — usually 15–25 MB total across the OTP runtime
tree.

Mix has a `strip_beams: true` release option that does the same thing,
but `mix mob.release` does not go through `mix release` (we build a
custom `.ipa` that bypasses Mix's release packaging entirely), so we
call `:beam_lib.strip_release/1` directly on the bundle.

### `xcrun strip -x` (main binary symbol strip)

Run after the OTP strips, before codesigning. Removes non-global
symbols from the main Mach-O. Smaller win (~1–2 MB) but mandatory for
clean App Store submission.

---

## Asymmetric defaults (dev OFF, release ON)

The slim pass adds 5–10 seconds per build:

- `:beam_lib.strip_release/1` spawns an `erl` process and walks every
  `.beam` in the bundle.
- `xcrun strip -x` rewrites the main Mach-O.
- Cache cleanup (`dedup_versions`, `foreign_apps`) does I/O across the
  full lib tree.

For dev iteration, that's 5–10 seconds you don't get back. For App
Store delivery, that's 5–10 seconds against a 20-minute TestFlight
round-trip plus the cost of confusing testers with a second build
number — easy trade.

So the defaults are flipped between paths:

| Task                     | Slim default | Override flag       |
| ------------------------ | ------------ | ------------------- |
| `mix mob.deploy`         | OFF          | `--slim`            |
| `mix mob.deploy --native`| OFF          | `--slim`            |
| `mix mob.release`        | ON           | `--no-slim`         |

The opt-in for dev exists so you can verify a slim build runs on
device _before_ you round-trip it through TestFlight. The opt-out for
release exists for the case where you're debugging a strip-induced
regression and need symbols + Dbgi chunks to do it.

---

## Plumbing

The slim flag travels from the Mix task to the bash script through
three hops:

1. `mix mob.deploy` / `mix mob.release` parse `--slim` / `--no-slim`,
   defaulting to `false` / `true` respectively.
2. The Mix task calls `MobDev.NativeBuild.build_all(slim: bool)` (dev)
   or `MobDev.Release.build_ipa(slim: bool)` (release).
3. Both stash the value in the process dictionary
   (`Process.put(:mob_slim, bool)`), and the env-var builder reads it
   into `MOB_SLIM=0` or `MOB_SLIM=1`.
4. The generated bash script gates the slim block on
   `if [ "${MOB_SLIM:-1}" = "1" ]; then` (release default 1) or
   `if [ "${MOB_SLIM:-0}" = "1" ]; then` (dev default 0).

The bash default differs between paths so that if `MOB_SLIM` is unset
entirely (e.g. someone runs the generated script by hand), the right
behavior happens for that path.

---

## Per-step traceability — the `[SLIM:<tag>]` log

Every strip step is wrapped with the `slim_step` bash function:

```bash
slim_step() {
    local label=$1
    local before=$(du -sk "$OTP_BUNDLE" 2>/dev/null | awk '{print $1}')
    shift
    "$@"
    local after=$(du -sk "$OTP_BUNDLE" 2>/dev/null | awk '{print $1}')
    local delta=$((before - after))
    printf "[SLIM:%s] %s KB → %s KB  (-%s KB)\n" "$label" "$before" "$after" "$delta"
}
```

Sample output:

```
[SLIM:prefix_libs] 120824 KB → 74756 KB  (-46068 KB)
```

If a build breaks _and_ the breakage is in the slim pass, the
`[SLIM:<tag>]` log tells you exactly which step did it. The build log
should be the first place you look:

```bash
grep '\[SLIM:' build.log
```

If the failing step's `[SLIM:<tag>]` line is missing entirely, the
breakage happened _during_ that step — look at the lines just above
the next `[SLIM:...]` line for the actual error. If every step is
present but the build still fails, the breakage is downstream
(codesigning, ditto packaging, plist surgery).

---

## Tool inventory

These all live under `mix mob.*` and are documented per-task with
`mix help <task>`. The slim build itself is always-on infrastructure;
the rest are diagnostic tools you reach for when investigating bundle
size or stripping aggressiveness.

### `mix mob.audit_otp`

Static reachability analysis. Walks every `.beam` file under an OTP
root, extracts the `imports` chunk, computes the transitive closure
from your app's entry-point modules. Anything not reachable is a
strip candidate.

```bash
mix mob.audit_otp
```

The output reports unreachable libraries (candidates for the
`prefix_libs` set), duplicate library versions (caught by
`dedup_versions`), and foreign apps from cache pollution (caught by
`foreign_apps`).

This is how the original 10 MB of cruft was found.

Implementation: `MobDev.OtpAudit` (covered by unit tests in
`test/mob_dev/otp_audit_test.exs`).

### `mix mob.trace_otp`

Empirical trace of what an app actually loads at runtime. Wraps
`:erlang.trace_pattern/3` to capture every MFA called by a synthetic
harness that exercises the basic Elixir/OTP surface (collections,
strings, processes, OTP behaviours, errors). The result is a set of
59 modules / 447 MFAs that we treat as the floor — anything not in
this set is at least worth questioning.

This is the empirical complement to `mix mob.audit_otp`'s static
analysis. The static call graph misses dynamic dispatch
(`apply/3`, GenServer callbacks, behaviour callbacks, hot-loaded
modules); the trace catches them.

### `mix mob.verify_strip`

Eager-loads every `.beam` file in the deployed bundle on a connected
device (via Erlang distribution). If the strip pass dropped something
the app can no longer load, this surfaces it before a user does.

```bash
mix mob.connect      # in one terminal
mix mob.verify_strip # in another
```

Implementation: `Mob.Diag.verify_loaded_modules/0` (lives in `mob`
itself, not `mob_dev`, so it ships in every app).

### `mix mob.snapshot_loaded`

Snapshot of which modules are actually loaded right now on a
connected device, plus the list of `.beam` files in the bundle that
have NOT been loaded. Useful for spotting strip candidates that
slipped through `audit_otp` because the import graph was wrong, or
for confirming a rare code path actually loads what you expected.

---

## Tests

Coverage as of 2026-05-02:

| File                                          | Tests | Covers                                                                              |
| --------------------------------------------- | ----: | ----------------------------------------------------------------------------------- |
| `test/mob_dev/release_script_test.exs`        | 29    | Bash shape: Apple-policy strips, `slim_step` helper, `[SLIM:tag]` markers, codesign |
| `test/mob_dev/otp_audit_test.exs`             | 10    | Synthetic OTP tree: discovery, dedup, foreign-app detection, size accounting       |
| `test/mob_dev/otp_asset_bundle_test.exs`      |  7    | Default strip set sanity, `build/3` error paths                                     |
| `test/mob_dev/otp_trace_test.exs`             |  4    | Trace harness phases, MFA collector normalization                                   |

Run the slim-related subset:

```bash
mix test test/mob_dev/release_script_test.exs \
         test/mob_dev/otp_audit_test.exs \
         test/mob_dev/otp_asset_bundle_test.exs \
         test/mob_dev/otp_trace_test.exs
```

Gaps still on the list (none blocking):

- `Mob.Diag.verify_loaded_modules/0` lives in the `mob` repo and
  needs a connected device; no synthetic-fixture test yet.
- `Mob.Diag.loaded_snapshot/0` same.
- Live-device round-trip of `mix mob.verify_strip` against a slim
  build, blocked at time of writing by an `eaddrinuse` flake on the
  EPMD tunnel.

---

## Adding a new strip step

The pattern is:

1. Decide what to strip and why. Look for prior art in
   `MobDev.OtpAudit` reports — most strip ideas come from finding
   something unreachable that nobody noticed.
2. Add the step to `MobDev.Release.release_device_sh/0` (release
   path) AND `MobDev.NativeBuild.maybe_slim_otp_bundle/2` (dev
   path — Phase 2 iter 13a moved the dev slim pipeline into Mix),
   wrapped in `slim_step <tag> ...`.
3. Add a string-shape test in `test/mob_dev/release_script_test.exs`
   under the "MOB_SLIM gating and per-step traceability" describe
   block — every tag in the strip set should appear in the
   `Enum.each` list for "every strip step routes through slim_step".
4. Update the table at the top of this guide with the new size
   delta.

The dev and release paths must stay in lockstep on which strips run
(both gated on `MOB_SLIM`); divergence means a slim build that works
on the dev path can break on TestFlight, which is exactly the trap
this asymmetric-defaults setup is designed to avoid.
