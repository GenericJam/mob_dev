# iOS native builds: zig sources in a stable project dir, the .app in a temp dir that is removed
- Date: 2026-10-01
- Status: accepted

## Context

MOB-313: every iOS device build created `$TMPDIR/mob_ios_device_<n>` for the
generated C and Swift sources, a copy of the linked binary, the bundled `.app`
(OTP runtime included, ~190 MB) and codesign scratch, and never removed it, on
success or failure. One machine had 58 of them, 3.3 GB. The simulator build
leaked twice per build: `mob_ios_sim_<n>` (generated sources) and
`mob_ios_bundle_<n>` (the sim `.app`, ~9 MB). The device exqlite
cross-compile removed its `mob_exqlite_<n>` scratch only when both compiles
and `ar` succeeded.

Nothing reads the `.app` once it is installed: `build_ios_physical/2` and
`build_ios/2` return only a platform label, and the deploy launches by bundle
id (`xcrun devicectl device process launch … <bundle_id>`, `xcrun simctl
launch <udid> <bundle_id>`), not by `.app` path.

The generated sources are different. zig keys its cache on a source file's
path as well as its contents, and `ios/build.zig` / `build_device.zig` pass
`enif_keepalive.c`, `erl_errno_id_compat.c` and `mob_plugin_bootstrap.swift`
by absolute path. The bootstrap goes to the single swiftc step that compiles
every Swift source (mob's `ios/*.swift`, the project's and the plugins'), so
a new path each build recompiled all the Swift and relinked every time.
Measured on a blank app's simulator build with nothing changed: the
`zig build` phase took 21.4 s with a per-build source dir and 0.3–0.4 s with
a stable one.

## Decision

- Generated sources go in `NativeBuild.ios_build_inputs_dir/1`:
  `<Mix.Project.build_path()>/mob_ios/ios_sim` or `…/ios_device`, kept between
  builds. One dir per target, shared by every device of that target, so a
  deploy to a second iPhone is warm too.
- They are written with `NativeBuild.write_build_input!/2`: unchanged content
  is left alone, changed content goes to a sibling temp file that is renamed
  over the old one. Two concurrent builds of one project (for example to two
  iPhones from two terminals) never see a half-written source, and since the
  content comes from the same checkout they normally write nothing at all.
- The `.app` and codesign scratch go in `NativeBuild.with_temp_build_dir/2`:
  `$TMPDIR/mob_<label>_<os pid>_<n>`, removed in an `after`, so it goes on
  success, on an `{:error, …}` result, and on a raise, throw or exit. The OS
  pid is in the name because `System.unique_integer/1` restarts low in every
  VM (a real sim build got `mob_ios_sim_2`); without it two concurrent deploys
  could pick the same name and the first to finish would delete the other's
  bundle. `Deployer` already qualifies its iOS staging dir the same way.
- The device build no longer copies the linked binary out of `ios/zig-out/`;
  it bundles from there, as the simulator build always has.
- The device exqlite step uses `with_temp_build_dir/2` too (`exqlite`).

## Alternatives considered

- **Everything in a per-build temp dir, removed afterwards.** Fixes the leak
  but keeps the 21 s cold Swift compile on every build. The first version of
  this change did that; its doc claimed zig's caches stayed warm, which was
  wrong for the reason above.
- **Everything, `.app` included, in a stable dir under `_build/`.** Keeps the
  cache warm, but the `.app` is rebuilt from scratch every time
  (`bundle_ios_device_app/4` removes it first), so keeping it buys nothing for
  the build and costs ~190 MB per project per device. It would also need UDID
  keying or a lock so two deploys don't bundle into the same `.app`.

## Consequences

- The built `.app` is gone once the build returns. There was never a flag that
  kept it; inspect one by stopping the build before install.
- `_build/<env>/mob_ios/` holds a few small generated files per target.
- Dirs leaked by earlier versions stay in `$TMPDIR` until the OS clears it or
  someone runs `rm -rf "$TMPDIR"/mob_ios_device_* "$TMPDIR"/mob_ios_sim_*
  "$TMPDIR"/mob_ios_bundle_*` while no build is running.
- `ios/zig-out/<App>` and `~/.mob/runtime/ios-sim` are still fixed paths, so
  two concurrent builds of one project still race on those. That is separate
  from this change.
