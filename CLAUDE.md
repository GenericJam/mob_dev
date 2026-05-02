# mob_dev — Agent Instructions

**Read [`AGENTS.md`](AGENTS.md) first**, then [`~/code/mob/AGENTS.md`](../mob/AGENTS.md)
for the system view. They cover repo topology, public-but-undocumented
seams (parsers/predicates kept public for testing), and the cross-repo
pre-empt-failure rules. This file goes deeper on Claude Code-specific
workflow.

> **Keep AGENTS.md up to date** when you add a public seam, change a
> convention, or hit a gotcha that should have been on the list. Same
> commit as the change — not a follow-up.

## TDD is the practice here

Write tests before or alongside new code. Every new function should have
corresponding tests before the task is considered done. The test suite must
stay green at all times.

```bash
mix test              # run all tests
mix test --watch      # (with mix_test_watch dep, if added)
```

## Pre-commit checklist

Before committing changes, run **all three** in this order:

```bash
mix test            # full suite must pass (call out any pre-existing flake explicitly)
mix format          # apply Elixir formatting
mix credo --strict  # address new issues; pre-existing ones are tracked separately
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
- `priv/templates/mob.new/` — EEx templates for generated project files
