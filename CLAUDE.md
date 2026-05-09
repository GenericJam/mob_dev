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

## TDD is the practice here

Write tests before or alongside new code. Every new function should have
corresponding tests before the task is considered done. The test suite must
stay green at all times.

```bash
mix test              # run all tests
mix test --watch      # (with mix_test_watch dep, if added)
```

## Pre-commit checklist

Before committing changes, run **all** in this order:

```bash
mix test                   # full suite must pass (call out any pre-existing flake explicitly)
mix format                 # apply Elixir formatting
mix credo --strict         # **whole tree, not just changed files** — pre-existing issues are tracked separately, but new ones (including in tests) must be fixed
mix erlfmt --check priv/android/crypto.erl     # Erlang formatting
mix mob.security_scan --strict                 # surface new CVEs / drift before they ship
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
- `priv/templates/mob.new/` — EEx templates for generated project files
