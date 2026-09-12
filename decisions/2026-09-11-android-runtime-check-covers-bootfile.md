# mob.deploy Android runtime check verifies release bootfile, not just ERTS

- Date: 2026-09-11
- Status: accepted
- Linear: MOB-183
- GitHub: mob_dev#54

## Context

`mix mob.deploy` (non-native, Android) already had an `ensure_erts_on_device/2`
guard that ran `ls .../otp/erts-*/bin/erl_child_setup` on the target and
refused a push when the file was missing. That covered the "no OTP at all"
case a caller hits when they've never run `mix mob.deploy --native` on that
device.

It did *not* cover a partial-runtime state, which the reporter of mob_dev#54
hit on a physical Android 11: the device had `erts-14.2.5/bin/` populated
(the APK ships those binaries as `.so` in `jniLibs/`), but the release
directory under `.../otp/releases/*/` was empty. `ls erts-*/bin/erl_child_setup`
returned the file, so the check passed. `mob.deploy` reported "Deployed
to 1 device(s) / Apps restarted" and the app crash-dumped at boot with:

    {'cannot get bootfile', .../otp/releases/29/start_clean.boot}

That's the failure family the issue calls out — "green deploy that yields
a boot-crashing app costs a full diagnosis cycle every time." The check
was too narrow to see the release-dir-missing subset. Third sighting of
this class of bug (sim variant tracked as `app-ii3`).

## Decision

Widen the Android runtime probe to verify **both** files in one `ls`
round-trip:

- `.../otp/erts-*/bin/erl_child_setup` — the ERTS binary (existing check).
- `.../otp/releases/*/start_clean.boot` — the OTP release the emulator
  boots from.

Classification is split out to `MobDev.Deployer.classify_android_runtime_ls/3`
(pure, tested) so the ordering (`run_as_unavailable` → `erts_missing` →
`bootfile_missing`) is asserted against real fixtures rather than mental
model. `erts_missing` wins over `bootfile_missing` in the both-missing case:
provisioning ERTS is what `--native` does first, and pointing a reader at
the bootfile they don't have yet would send them chasing the wrong file.

The check now recognises three `ls`-missing message variants seen in the
wild:

- `ls: <glob>: No such file or directory` (Toybox, most Android userland)
- `<glob>: not found` (older Toybox / minimal shells)
- `ls: cannot access '<glob>': No such file or directory` (GNU coreutils)

Anchoring on the exact glob rather than substring "No such file" is what
lets the classifier distinguish which of the two globs is the one that
failed to expand.

## Consequences

- Non-native `mix mob.deploy` now fails with a targeted message and exit
  code non-zero when a device is in the release-dir-missing state, instead
  of a green deploy followed by a boot crash the user has to diagnose from
  logcat.
- The check remains best-effort: if `run_adb` itself errors (adb offline,
  device unauthorised), the deploy proceeds and the current downstream
  errors take over. Fixing that fallback is a separate concern.
- iOS is not covered by this change. The sim variant (`app-ii3`) has the
  same failure family but the runtime path is different (`sim_runtime_dir`
  under `~/.mob/runtime/ios-sim/<app>/` on the host, not `/data/data/...`
  on the device). Follow-up ticket.
- The classifier is public so future adb output shapes can be regressed
  against without needing a device — pattern already established in this
  repo for `parse_devices_output/1`, `parse_simctl_json/1`, etc.
