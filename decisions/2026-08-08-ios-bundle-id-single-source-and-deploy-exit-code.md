# One iOS bundle id everywhere, and a non-zero exit on failed deploy

- Date: 2026-08-08
- Status: accepted

## Context

Three defects found deploying one app to a physical iPhone and an Android
phone, with `bundle_id: "com.example.mishka_mob"` (Android's
`applicationId`, underscore and all) plus
`ios_bundle_id: "com.genericjam.mishkamob"` in `mob.exs`:

1. `MobDev.Deployer` resolved the iOS id with `MobDev.Config.bundle_id/0`,
   discarding `:ios_bundle_id`. `MobDev.NativeBuild` honoured it. So
   `mix mob.deploy --native --device <udid>` installed the app under the
   configured id and then pushed BEAMs at an id that was never installed:
   `App 'com.example.mishka_mob' is not installed on this device.` The only
   workaround was clobbering `:bundle_id` — which Android may not accept
   (Apple forbids `_` in a bundle id; `com.example.*` is frequently already
   claimed by another Apple team).
2. That run printed `Failed on 1 device(s)` and exited **0**.
3. The iOS *simulator* bundle never stamped `CFBundleIdentifier`, so it
   inherited whatever `ios/Info.plist` carried, while the *device* bundle
   stamped the configured id. Same project, two ids, and no way to tell
   which one a given build used.

## Decision

**One resolver per side.** `MobDev.Config.ios_bundle_id/0`
(`:ios_bundle_id || bundle_id/0`) is what every iOS-targeting *consumer*
resolves — `Deployer`, `Connector`, `mob.provision`, `mob.battery_bench_ios`.
`MobDev.NativeBuild.ios_bundle_id/1` (`cfg[:ios_bundle_id] || cfg[:bundle_id]`)
is the same rule over the already-loaded build config, used by the sim
bundle, the device bundle, and code signing. The two agree because
`load_config/0` resolves `cfg[:bundle_id]` through `Config.bundle_id/0`.

`mob.provision` is included deliberately: it mints the provisioning profile,
which must cover the id `NativeBuild` actually signs.

**Simulator now stamps `CFBundleIdentifier` too**, rather than accepting the
divergence and only reporting it. No signing step rewrites the id on either
path, so there was no technical reason for them to differ. For projects that
never set `:bundle_id`/`:ios_bundle_id` this is a no-op — `bundle_id/0`
already falls back to `ios/Info.plist`, so the stamped value equals the
inherited one. Both paths additionally *print* the id they installed, since
`simctl launch` / `devicectl` / `mob.connect` all need it and it appeared
nowhere in the build output.

**`mix mob.deploy` exits non-zero when the `failed` bucket is non-empty**
(`Mix.Tasks.Mob.Deploy.failure_message/3` → `Mix.raise`), after the full
summary is printed.

- `skipped` stays non-fatal. It means "app not installed for that platform",
  the expected outcome of building `--ios` with an Android phone also
  plugged in. This keeps faith with the earlier fix that split `skipped` out
  of `Failed on N` in `format_summary/4`.
- Partial success is fatal. The fan-out is unchanged — every targeted device
  is still attempted and reported, so an operator can see which ones got the
  BEAMs. But a *script* cannot notice that one device missed out if the
  status code says everything is fine, and that is precisely who the exit
  code is for.

## Consequences

- A CI job that deploys to several devices and previously "passed" with one
  device failing now fails. That is the point, but it is a behaviour change
  for anyone who was relying on the old status code.
- `:ios_bundle_id` is now a genuinely usable setting rather than one the
  build honours and the deployer ignores; cross-platform projects no longer
  have to pick an id that satisfies both Apple and Android.
- `NativeBuild.ios_bundle_id/1` joins the public-but-undocumented seams
  (listed in `AGENTS.md`) — public for testing, don't privatise.
