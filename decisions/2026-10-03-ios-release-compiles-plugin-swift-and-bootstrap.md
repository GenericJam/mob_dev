# iOS release build compiles the plugin Swift sources and the generated bootstrap

- Date: 2026-10-03
- Status: accepted

## Context

`mix mob.release --ios` of a fresh app (mob_new 0.6.3, mob 0.9.10, no plugins,
no code changes) failed to link:

```
Undefined symbols for architecture arm64:
  "_mob_register_plugins", referenced from:
      -[AppDelegate application:didFinishLaunchingWithOptions:] in AppDelegate.o
```

`mix mob.deploy --native --ios` of the same app links. This is MOB-7
(`2026-07-04-blank-ios-plugin-bootstrap.md`) again, on the other iOS build
path. The generated `AppDelegate.m` calls `mob_register_plugins()`
unconditionally; the Swift bootstrap that defines it
(`MobDev.Plugin.IOSBootstrap.swift_source/1`) is compiled by the dev builds
through `-Dplugin_swift_files`. The release build is the hand-rolled
`release_device.sh` (`2026-07-07-ios-release-links-plugin-nifs.md`), whose
single swiftc step compiled only `$MOB_DIR/ios/*.swift`: neither the bootstrap
nor any plugin's Swift sources. MOB-7 fixed the dev path only, and the release
fix for plugin NIFs left Swift out on purpose, so an app with no plugins and an
app whose plugins ship SwiftUI views both failed.

## Decision

`release_env/2` adds `MOB_PLUGIN_IOS_SWIFT_SOURCES` and the script passes it to
that same swiftc call (one `-wmo` module, so a plugin view and the bootstrap
that registers it compile together, as they do under zig).

- **The rule is the dev path's.** Which files go in is decided by
  `NativeBuild.ios_plugin_swift_mode/2`, so release and dev agree: plugins
  activated → their Swift files plus the bootstrap; none, and the app's
  `ios/build_device.zig` has the `plugin_swift_files` option → the bootstrap
  alone; none, and it does not (a pre-plugin scaffold, whose AppDelegate never
  calls the symbol) → nothing. `build_device.zig` is the file because release
  is a device build and the dev device build asks the same file.
- **Pure core, write at the edge.** `Release.plugin_ios_swift_env/3` takes the
  activated plugins, the build-file answer and the bootstrap path and returns
  the env tuple, like `plugin_ios_build_env/1`. `plugin_ios_swift_env_written/3`
  is the edge: it reads the build file and writes the bootstrap, and takes
  both paths as arguments so the I/O is tested in a tmp dir.
- **Same bootstrap file as the dev device build.** It is written with
  `NativeBuild.write_build_input!/2` into `ios_build_inputs_dir(:ios_device)`.
  The content is a function of the activated plugins only, so a release and a
  dev build write identical bytes; the writer leaves an unchanged file alone
  and renames a changed one into place, so neither a release nor a dev build
  invalidates the other's zig cache or sees a half-written file
  (`2026-10-01-ios-build-sources-stable-app-dir-removed.md`).
- **Frameworks need nothing new.** `MOB_PLUGIN_IOS_FRAMEWORKS` already carries
  `Merge.ios_frameworks/1`, the dev path's `-Dplugin_frameworks` value, to the
  release link line.

## Alternatives considered

- **Guard the call in `AppDelegate.m.eex`** (`#if`), as MOB-7 noted. That is a
  mob_new change and does nothing for apps already generated; it also leaves a
  plugin-with-Swift app unfixed.
- **Decide from `AppDelegate.m` mentioning the symbol** rather than from
  `build_device.zig`. Closer to the actual dependency for the release script,
  but it would give the two paths different rules for the same app. The
  build-file token and the call are generated together (MOB-7), so the dev rule
  is kept.
- **One shared helper for dev and release**, wrapping the private
  `ios_plugin_swift_and_frameworks/3`. It would have put the file write inside
  the function the env var comes from, and it adds a public seam. The release
  side is a dozen lines over already-public `NativeBuild` and `IOSBootstrap`
  functions.

## Consequences

- `mix mob.release --ios` links a blank app, and an app with Swift-bearing
  plugins gets their views and the registration in the binary.
- Paths are space-joined and word-split unquoted by the script, exactly like
  `MOB_PLUGIN_IOS_NIF_SOURCES`, so a plugin path containing a space is
  unsupported for this variable as for that one. The bootstrap lives under the
  project's `_build`, so a *project directory* containing a space also fails
  here, which includes a blank app (it fails at the swiftc step instead of the
  link; before this change it already failed at the link). The dev path joins
  with commas and has its own limit (no commas). Passing the bootstrap as its
  own quoted variable would lift the project-directory case; not done, to stay
  consistent with the NIF variable.
- The release path still does not run the plugin signature and capability-drift
  gate (`Validator.raise_on_capability_drift!/1`) that the iOS sim, iOS device
  and Android builds run before linking plugins. That was already true for
  plugin NIF sources; compiling plugin Swift widens it, since the Swift-import
  vs manifest-frameworks check has nothing to guard in a release. Closing it
  would make releases refuse unsigned or untrusted plugins, a behaviour change
  left to the maintainers. Follow-up.
- Still not in the release path, all of which the dev path handles:
  `project_swift_sources` from `mob.exs`, `project_c_nifs`, and plugin
  `static_archives` (`:cpp_archive`). A Swift file configured through
  `project_swift_sources` is in dev builds and missing from a release. Follow-up.
- Verified on the host, not on a device. Two apps, `mix mob.release --ios`
  against master and against this change, with an Apple Distribution identity
  and an App Store profile for the bundle id:
  - A blank app from mob_new 0.6.3 (mob 0.9.10, no plugins). Master fails with
    `Undefined symbols … _mob_register_plugins, referenced from AppDelegate.o`;
    with this change it links, is signed, and packages an `.ipa` whose binary
    defines `_mob_register_plugins`.
  - An app with a tier-2 plugin that ships a SwiftUI view and no NIFs (Elixir
    1.20.4 / OTP 29). Master fails with the same undefined symbol; with this
    change it links, is signed, and packages an `.ipa` whose binary defines
    `_mob_register_plugins` and carries the plugin's view type, source file
    and registry key.
  Nothing was uploaded or launched on a device, and a plugin whose Swift needs
  frameworks beyond the link line's defaults was not tried.
- Tests: the mode matrix and the I/O edge in `release_test.exs`; the script
  shape in `release_script_test.exs`.
