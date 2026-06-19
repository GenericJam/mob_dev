# mob_dev — Agent Instructions

**Read [`AGENTS.md`](AGENTS.md) first**, then [`~/code/mob/AGENTS.md`](../mob/AGENTS.md)
for the system view. They cover repo topology, public-but-undocumented
seams (parsers/predicates kept public for testing), and the cross-repo
pre-empt-failure rules. This file goes deeper on Claude Code-specific
workflow.

> **Keep AGENTS.md up to date** when you add a public seam, change a
> convention, or hit a gotcha that should have been on the list. Same
> commit as the change — not a follow-up.

For the in-flight build-system refactor (Mix → Igniter → Zig build),
see [`~/code/mob/build_system_migration.md`](../mob/build_system_migration.md) —
multi-month sequenced plan; phase ownership lives there.

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

## Recurring gotchas — read these before debugging device issues

**iOS sim launches, BEAM dies fast, sim returns to home screen.** Almost
always a host-port collision with `adb`, not a BEAM bug. When an Android
device is connected, `adb forward tcp:9100 tcp:9100` binds `127.0.0.1:9100`
on the Mac. iOS sims share the Mac's network stack, so `MobDev.Tunnel.dist_port(0)
= 9100` is already taken. The OTP boot exits cleanly on `eaddrinuse` and there
is no crash report. First diagnostic:

```bash
lsof -nP -iTCP:9100-9199 -sTCP:LISTEN | grep adb
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

## TDD is the practice here

Write tests before or alongside new code. Every new function should have
corresponding tests before the task is considered done. The test suite must
stay green at all times.

```bash
mix test              # run all tests
mix test --watch      # (with mix_test_watch dep, if added)
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

## Release flow

Canonical process lives in
[`mob/RELEASE.md`](https://github.com/GenericJam/mob/blob/master/RELEASE.md)
— trigger model (mix.exs as source of truth), patch-bump default with
mandatory permission, CHANGELOG conventions, per-step idempotency of
`release.yml`. **mob_dev specifics:**

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

## What to test

**Always testable (pure functions, no hardware):**
- `MobDev.Device` — `short_id/1`, `node_name/1`, `summary/1`
- `MobDev.Tunnel` — `dist_port/1`
- `MobDev.Discovery.Android.parse_devices_output/1`
- `MobDev.Discovery.IOS.parse_simctl_json/1`, `parse_simctl_text/1`, `parse_runtime_version/1`
- `MobDev.HotPush.snapshot_beams/0`, `push_changed/2`
- `MobDev.ProjectGenerator.assigns/1`, `generate/2`
- `MobDev.IconGenerator.android_sizes/0`, `ios_sizes/0`, `generate_from_source/2`

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

Run only unit tests: `mix test --exclude integration`

## Parsing functions are public

`parse_devices_output/1`, `parse_simctl_json/1`, `parse_simctl_text/1`, and
`parse_runtime_version/1` are public specifically to enable testing. Do not
make them private.

## Releasing a new OTP runtime

When upgrading OTP, you need to rebuild the pre-built tarballs that
`MobDev.OtpDownloader` downloads. See [`build_release.md`](build_release.md)
for the full process (staging, adding headers + static libs, uploading to GitHub,
updating the hash in `otp_downloader.ex`).

## Key files

- `lib/mob_dev/device.ex` — device struct + `node_name/1`, `short_id/1`
- `lib/mob_dev/tunnel.ex` — adb tunnel setup, `dist_port/1`
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
- `lib/mob_dev/project_generator.ex` — EEx template rendering for `mix mob.new`
- `lib/mob_dev/icon_generator.ex` — robot avatar generation + platform icon resizing
- `lib/mix/tasks/mob.new.ex` — `mix mob.new APP_NAME`
- `lib/mix/tasks/mob.icon.ex` — `mix mob.icon [--source PATH]`
- `lib/mix/tasks/mob/adopt.ex` — `mix mob.adopt` orchestrator (install Mob into an existing Phoenix project)
- `lib/mix/tasks/mob/adopt/` — the adopt sub-installers (`deps`, `bridge`, `screen`, `mob_app`, `mob_exs`, `native[/android,/ios]`, `finalize`)
- `lib/mob_dev/adopt_guard.ex` — `MobDev.AdoptGuard`, the pre-1.0 detect-and-refuse for `mob.adopt`
- `lib/mob_dev/adopt/patcher.ex` / `lib/mob_dev/adopt/generator.ex` — `MobDev.Adopt.{Patcher,Generator}`, the shared LV-bridge patches + EEx assigns/dep-resolution (duplicated from mob_new; see the adopt ADR)
- `priv/templates/mob.new/` — EEx templates for generated project files

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

Then from any other IEx (or one-shot script) on the Mac:

```bash
elixir --name probe@127.0.0.1 --cookie mob_secret -e '
node = :"your_app_android_<suffix>@127.0.0.1"
Node.connect(node)
:rpc.call(node, YourApp.Module, :function, [args])
'
```

The cookie defaults to `:mob_secret` (set by `Mob.Dist.ensure_started`
in your app's `on_start/0`). `--name` (long names) is required when
the device node uses a numeric host like `@10.0.0.120`.

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

### Dist ports are serial-derived (FIXED 0.6.7, 2026-06-18)

Dist ports are no longer assigned by per-run index (which made *every*
project's first device claim 9100 → cross-project collisions in the one
shared Mac EPMD → silent timeouts). `Tunnel.serial_base_port/1` maps a
device serial to a stable port in `9100..9899` (crc32 hash), bumped past
any port a live node/forward already holds (`assign_dist_port/2`). The
device-side BEAM listens on that same port (via `MOB_DIST_PORT`), so the
forward is 1:1 and EPMD's broadcast matches. `setup` also removes the
device's own stale forwards first. A given phone always gets the same
unique port across runs/projects, and deploy + connect agree on it.

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

**Append new files; never edit existing ones.** If a decision changes, add a
new file and mark the old one `Status: superseded by <new-file>`. One file per
decision keeps the log conflict-free across parallel agents/worktrees — the
date-sorted directory listing is the index. Record a decision the moment you
make a non-obvious call, not later.
