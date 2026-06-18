# Changelog

All notable changes to **mob_dev** are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

Full module documentation: [hexdocs.pm/mob_dev](https://hexdocs.pm/mob_dev).

---

## [0.6.7] - 2026-06-18

### Fixed
- **`mix mob.connect` reliability — dist ports keyed by device serial, not run
  index.** The Mac runs one shared EPMD; assigning ports as `9100 + index` meant
  *every* project's first device claimed 9100, so two phones (or two projects'
  device-0) registered the same port and `adb forward tcp:9100` could only reach
  one — the other silently timed out. Ports are now derived from the device
  serial (`Tunnel.serial_base_port/1`, a crc32 hash into 9100..9899) and bumped
  past any port another live node/forward already holds (`assign_dist_port/2`).
  A given phone always gets the same unique port across runs and projects, and
  deploy and connect agree on it. `Tunnel.setup/2` → `setup/1` (port is now
  serial-derived, not index-passed).
- **Stale-tunnel cleanup.** `Tunnel.setup` removes the device's own old forwards
  first (scoped to that serial), so prior runs no longer leave duplicate/wrong
  forwards that poison the next connect.
- **Real diagnostics on connect failure.** A timed-out node now reports *why* —
  app not running / Standby-killed, dist never registered in EPMD, registered at
  a different port, no forward, or cookie mismatch — instead of a black-box
  "timed out".

---

## [0.6.6] - 2026-06-18

### Fixed
- **Android native build skips ABIs the app's `build.zig` doesn't handle**
  instead of hard-failing. mob_dev builds arm64-v8a/armeabi-v7a/x86_64 by
  default, but an app's app-owned `build.zig` (copied at `mix mob.new` time)
  may predate x86_64 support (mob_new < 0.4.5) and reject `-Dabi=x86_64`. That
  used to fail the whole native build — aborting *before* the
  `io.mob.plugin.MobPluginBootstrap` regen, so the next gradle build then failed
  on an unresolved bootstrap. Now each ABI is pre-flighted against the build.zig
  (`build_zig_supports_abi?/2`) and unsupported ones are skipped with a warning
  (gradle `abiFilters` wouldn't ship them anyway). Real failures of a SUPPORTED
  ABI still halt the build.

---

## [0.6.5] - 2026-06-17

### Changed
- **Default OTP runtime → Elixir 1.20.1** (`@otp_hash` `7d46fdd4` → `5c9c69fc`).
  Same OTP-29 / erts-17.0 / OpenSSL 3.4.0 base; the bundled Elixir stdlib
  (elixir/logger/eex) is swapped rc.5 → 1.20.1 across all five tarballs
  (android, android-arm32, android-x86_64, ios-sim, ios-device), published as
  the `otp-5c9c69fc` release on GenericJam/mob. `bundled_versions.exs` adds the
  `5c9c69fc` bundle and flips `active_hash`. Backward compatible — apps pick up
  1.20.1 on their next `mix mob.deploy` (recompile against the new runtime).
  NOTE: the major.minor skew check treats rc.5 and 1.20.1 as both "1.20", so it
  does NOT warn on this transition; the stdlib swap is what makes beams load.

---

## [0.6.4] - 2026-06-16

### Added
- **Android x86_64 emulator support** (resolves GenericJam/mob#20). The `x86_64`
  ABI is now wired throughout: `OtpDownloader.ensure_android("x86_64")` (#11),
  the x86_64 native build path (`zig_build_android_objects`, `ensure_jni_libs`,
  `otp_dir_for_abi`), and an `android_x86_64` target in `mix mob.release.otp`
  plus the `scripts/release/*x86_64*` build scripts. The
  `otp-android-x86_64-<hash>.tar.gz` runtime is published on the `otp-<hash>`
  release. This is the slice x86_64 Linux / CI hosts need, where ARM emulation
  isn't available.

## [0.6.3] - 2026-06-16

### Fixed
- **exqlite NIF symlink now picks the device's actual ABI.** The Android
  deployer hardcoded `lib/arm64` for the `sqlite3_nif.so` symlink target, so on
  a 32-bit (`armeabi-v7a`) device the link dangled, exqlite was
  `:nif_not_loaded`, and any generated app using ecto_sqlite3 crashed on boot.
  It now probes `lib/<abi>/libsqlite3_nif.so` (Android extracts only the active
  ABI). Found + fixed verifying the showcase on a 32-bit Moto E — SQLite
  migrations now run and the app boots.

## [0.6.2] - 2026-06-15

### Fixed
- **Create an app-level driver_tab when a NIF-bearing plugin is active.** A
  generated app ships no driver_tab and links against mob's core static-NIF
  table — which has no plugin entries. So a plugin's `<module>_nif_init` linked
  but never registered, and the NIF was `:nif_not_loaded` on device (the home
  rendered, the Kotlin/permission bridge worked, but the actual capability call
  crashed). `regen_driver_tab!` now creates `priv/generated/driver_tab_*.zig`
  (core + plugin entries) when plugins contribute NIFs and the app has none.
  Found + fixed verifying the showcase app on a physical Android phone and the
  iOS simulator (location demo now returns a real fix on both).

## [0.6.1] - 2026-06-15

### Fixed
- **Prune orphaned plugin artifacts when a plugin is removed.** Plugin tier-3
  merges copy files into the host tree (bridge Kotlin into the Kotlin sourceSet,
  migrations, images); these lingered after a plugin was dropped, and an
  orphaned bridge `.kt` could break the Gradle compile. `NativeBuild`'s kotlin /
  migration / image merges now ledger what they write (per concern, under
  `priv/generated/.mob_plugin_artifacts/`) and delete what a prior build
  produced but the current one no longer does — so add/remove of a plugin is
  clean in both directions.

## [0.6.0] - 2026-06-12

### Added
- **Style packages, tokens-only tier**: `MobDev.Style` (priv/mob_style.exs loader + validator), `config :mob, :styles`/`:default_style` activation, runtime-manifest emission (misconfiguration fails the build), and `mix mob.styles`.
- **`ui_components` `expand:` form honored** (pure-Elixir composites): validated native-XOR-expand; expand-only plugins classify tier 2 but hot-push; the runtime manifest carries `composites` for boot registration.
- **`mix mob.doctor`**: pre-plugin build.zig detection (missing `-Dplugin_*` options) and the host_requirements lane.
- **`host_requirements` manifest key** printed by every native build; `mix mob.new_plugin` scaffolds starter test suites for every tier.

### Changed
- **Native builds auto-regenerate the static-NIF driver_tab** (was a checked-in artifact whose staleness produced runtime `:nif_not_loaded`).
- **`mix mob.regen_plugin_manifest` loads the host app first** — spec-v2 generators may call host modules (mob_ash), not just read config.

### Fixed
- **Dep detection uses `Mix.Project.deps_paths`**, not stale `_build` dirs — ends the spurious MLX-404 downloads for apps that never dep emlx.
- ExSlop is registered as a credo PLUGIN (it had silently never run).

## [0.5.17]

### Added
- **`mix mob.new_plugin` scaffolds a starter test suite for every tier** (`test/test_helper.exs` + `test/<name>_test.exs`): tiers 1–4 get stdlib-only structural manifest checks (required keys, NIF stub loadable, `native_dir` exists, screen modules compile) with a pointer at `mix mob.validate_plugin` for the full validator; tier 0 gets a compile smoke test. New plugins start covered instead of starting at zero tests.
- **Plugin `host_requirements` manifest key.** A plugin can declare human-readable host-app obligations the build can't automate (e.g. the AndroidManifest `<service android:foregroundServiceType="mediaProjection">` fragment mob_screencast needs, or a capture `FileProvider`). The manifest validator enforces the shape, `MobDev.Plugin.Merge.host_requirements/1` gathers them, and every native build prints them as a warning block — previously forgetting the manual step built + booted clean and only failed at first feature use.
- **`mix mob.doctor` detects pre-plugin build files.** When plugins are activated but a `build.zig`/`build_device.zig` declares no `b.option` for the `-Dplugin_*` flags the native build emits, doctor warns with the exact missing options — previously Zig rejected the unknown flag half a build in.

### Changed
- **`mix mob.deploy --native` regenerates the static-NIF driver table on every build** (whatever formats the project uses, zig and/or c), exactly like the runtime plugin manifest: it's derived state. A stale checked-in `driver_tab_*` used to link a newly activated plugin's `<module>_nif_init` without registering it, so every NIF call raised `:nif_not_loaded` at runtime with nothing pointing at the cause.

### Added
- **`mix mob.new_plugin` scaffolds tiers 3 (multi-screen) and 4 (sub-app)**, not just 0–2. Tier 3 emits two `Mob.Screen` modules + a `:screens`/`:migrations` manifest + a namespaced Ecto migration; tier 4 emits a lifecycle module + supervised worker + notification handler + settings editor screen + a `:lifecycle`/`:settings`/`:notifications` manifest. Generated manifests validate and modules compile against real mob.
- **Cross-plugin conflict detection.** `MobDev.Plugin.Validator.conflict_surface/0` classifies every merge gatherer; `cross_validate/1` fails the build when two activated plugins clash on any shared resource — screen route, component atom, iOS/Android native view key, migration `repo_namespace`, NIF module, Swift/JNI source basename, Android bridge class, iOS plist key, supervised worker name, or notification match. A completeness meta-test forces every new shared-resource field to be classified; a property-based fuzzer checks detection is sound + complete across random N-plugin sets. A single plugin declaring a cross-platform NIF (one iOS + one Android entry sharing a `:module`) is correctly not flagged.

### Changed
- **`mix mob.deploy --native` regenerates the runtime plugin manifest (`priv/generated/mob_plugins.exs`) on every build**, not only when `config :mob, :plugins` changes. Adding/changing a plugin's tier-3/4 sections previously shipped a stale manifest (the new sections silently didn't activate on device); it is now derived state, always rebuilt before bundling — like the driver table.

### Fixed
- **iOS simulator deploy now boots from a clean `mix mob.deploy --native`** (was device-only). Three gaps made the sim deploy incomplete vs the device path, so the sim crashed on boot even though the device worked:
  - The Elixir-distribution apps `elixir`/`logger` were staged only under `lib/<app>/ebin`, which the sim's `mob_beam.m` doesn't add to the code path — boot failed at `ensure_all_started(:elixir)` with "elixir.app not found". They're now flattened into the flat BEAMS_DIR alongside `eex` (which already needed this), where the path resolves.
  - `priv/` was only partially staged (`repo/migrations`), so `Application.app_dir(:<app>, "priv/cacerts.pem")` was `:enoent` and `Mob.Certs.load_cacerts!` crashed the boot. The whole `priv/` is now rsynced into the flat dir (cacerts, `mix`/`hex` ebins, vendored static, …), matching the device release.
  - `Paths.sim_runtime_dir/0` fell back to `/tmp/otp-ios-sim` for zig-based projects (no `ios/build.sh`), but the runtime is synced to `~/.mob/runtime/ios-sim` — so the launcher and staging disagreed. It now recognizes `ios/build.zig` and returns the default runtime dir.
  Verified: a clean `mob.deploy --native` to an iPhone 11 Pro Max sim boots Io, Phoenix endpoint up, embedded Livebook home renders — no manual runtime fixups.

## [0.5.16]

### Fixed
- **Gate the plugin flags on the iOS *device* build path too.** 0.5.15 gated the plugin-flag emission for Android and the iOS *simulator* build, but `zig_build_binary_ios_device` still emitted `-Dplugin_swift_files`/`-Dplugin_frameworks` (and generated the bootstrap, making `plugin_swift_files` always non-empty) unconditionally — so `mix mob.deploy --native` to a physical iPhone broke on an app scaffolded before the plugin system (`invalid option: -Dplugin_swift_files`). The device path now mirrors the sim path: bootstrap + flags only when plugins are activated. Verified `mix mob.deploy --native` to a physical iPhone — full OTP, Phoenix endpoint up, LiveView connected, embedded Livebook home rendered.

## [0.5.15]

### Fixed
- **`mix mob.release --android --no-slim` now actually ships the full OTP tree.** The Android release stripped OTP libs unconditionally (`OtpAssetBundle.build/2` was called with no opts), so `--no-slim` was silently ignored on Android. `slim` is now threaded `build_aab → OtpAssetBundle.build(slim:)`; with `slim: false` the OTP tree ships untouched. Required for apps that run arbitrary user code at runtime (e.g. an embedded Livebook host doing `Mix.install`) — stripping any OTP lib (`inets`, `ssl`, `xmerl`, `runtime_tools`, …) is a latent crash when a user's deps need it. Default stays `slim: true`.
- **iOS `--no-slim` release passes App Store validation.** The always-on Apple-policy strip cleared `erts-*/bin` and `priv/bin` but missed standalone executables inside OTP libs (e.g. `erl_interface/bin/erl_call`), which App Store validation rejects (90171). Now `lib/*/bin/*` executables are stripped too (always on), keeping every lib's `.beam`/`.app` — so a full-OTP `--no-slim` bundle is still Apple-compliant.
- **Native builds no longer break on pre-plugin app scaffolding.** `native_build.ex` emitted `-Dplugin_c_nifs`/`-Dplugin_zig_nifs`/`-Dplugin_jni_sources` (Android) and `-Dplugin_swift_files`/`-Dplugin_frameworks` (iOS) unconditionally, but an app scaffolded before the plugin system has no such options in its `build.zig` and Zig rejects the unknown `-D` flag. These flags (and the iOS plugin bootstrap) are now emitted only when plugins are activated; a plugin-aware `build.zig` defaults them to `""` so behaviour is unchanged there.

## [0.5.14]

### Fixed
- **iOS release: `erl_errno_id_unknown` shim written with a literal `\n`.** The weak-stub line in `release_device.sh` used `printf '%s\\n'` inside the `~S` (raw) heredoc, so bash received both backslashes and `printf` wrote a literal backslash-`n` into `erl_errno_id_compat.c` — clang then rejected the trailing `}\n` and `mix mob.release --ios` failed. Now `printf '%s\n'` (one backslash) emits a real newline. Regression guard added to `release_script_test`.
- **iOS release: clear preflight when `priv/generated/driver_tab_ios.c` is missing.** The release links a per-app static-NIF driver table, but the dev build uses the built-in Zig table and `mix mob.regen_driver_tab` defaults to Zig, so a project that never ran it with `--format c` died deep in `release_device.sh` with a cryptic `cc: no such file`. `build_ipa` now fails early with the exact command to run (`mix mob.regen_driver_tab --format c`).

## [0.5.13]

### Fixed
- **iOS deploy now ships the whole `priv/`, not just `priv/repo/migrations` + `priv/static`.** `MobDev.Release`'s iOS bundler copied only migrations and `priv/static`, so apps that bundle extra runtime assets under `priv/` — `:mix`/`:hex` ebins for on-device `Mix.install`, or a vendored library's own `priv/` (e.g. Livebook's `priv/static` + `priv/livebook`) — silently never reached the device. Now rsyncs all of `priv/`, matching the Android deployer. Unblocks on-device `Mix.install` and embedded Livebook on iOS. Verified on a physical iPhone: `priv/mix/ebin` (103 beams) and `priv/livebook/static` present on device, embedded Livebook serves, and `Mix.install([{:short_uuid, "~> 0.1"}])` returns `:ok`.

## [0.5.12]

### Changed
- **OTP runtime bumped to `7d46fdd4` (Elixir 1.20.0-rc.5).** `@otp_hash` now points at the `otp-7d46fdd4` release: all four platform tarballs (ios-sim, ios-device, android, android-arm32) bundle Elixir 1.20.0-rc.5 matched to the OTP-29 erts. Completes the 1.19.5 to 1.20 runtime migration the bundled-versions manifest was already staged for. Verified end-to-end on a physical iPhone and a physical Android (Moto G): `System.version` 1.20.0-rc.5, OTP 29, `Mix.install([{:short_uuid, "~> 0.1"}])` returns `:ok` with the dep compiled on-device.

### Fixed
- **iOS `{spawn, <linked-in driver>}` now works** (erts `erts_open_driver`). The iOS-build `#ifdef __IOS__` guard returned BADARG for any `open_port` whose spawn_type included the EXECUTABLE bit (i.e. plain `{spawn, Name}`), firing before the linked-in-driver name lookup. This broke `ram_file` (`{spawn, "ram_file_drv"}`), and therefore `file:open(_, [:ram])`, `erl_tar` in-memory extract, `hex_tarball.unpack`, and `Mix.install` on iOS. The guard now fires only when no linked-in driver matched the name. Bundled in the `7d46fdd4` OTP tarballs.

## [0.5.11]

### Added
- **`mob.exs :project_swift_sources` config key** — optional list of extra Swift sources to compile into the iOS app module alongside Mob's bridge sources. Threaded into both `zig_build_binary_ios_sim` and `zig_build_binary_ios_device` as `-Dproject_swift_sources=<absolute,paths>`. Comma-containing entries are rejected at the boundary; nil/[] is a no-op. Pairs with mob_new's `project_swift_sources` build hook (mob_new#5). Originally proposed by @dl-alexandre.

## [0.5.10]

### Added
- **`mix mob.deploy --dist-port N` and `--node-suffix S` flags** — manual
  override path for the BEAM-distribution surface. When set, all targeted
  devices use the same value (use with `--device <id>` to be explicit).
  Nil falls back to per-device auto-allocation
  (`Tunnel.dist_port(idx)` + `Discovery.Android.device_node_suffix` /
  SIMULATOR_UDID-derived suffix). Resolves the
  `register/listen error: no_reg_reply_from_epmd` symptom seen when running
  multiple sims/emulators of the same app concurrently for cross-platform
  visual comparison.
- `MobDev.Device` struct gains a `:node_suffix` field for plumbing the
  override per-device alongside `:dist_port`. Nil keeps auto-derive.
- `MobDev.Discovery.IOS.launch_app/3` accepts `:node_suffix` opt and
  forwards as `SIMCTL_CHILD_MOB_NODE_SUFFIX` to the launched sim. Companion
  to `mob 0.6.10`'s `MOB_NODE_SUFFIX` support in `mob_beam.m`.
- `MobDev.Discovery.IOS.build_simctl_env/2` — pure helper extracted from
  `launch_app/3` so override behaviour is unit-testable without spawning
  `simctl`. 7 new tests cover dist_port + node_suffix override paths.

### Changed
- `MobDev.Connector.restart_app/1` pattern-matches `:node_suffix` from
  `Device` in both Android + iOS-sim variants, threading the value to the
  launchers.
- `MobDev.Deployer.deploy_all/1` accepts top-level `:dist_port` +
  `:node_suffix` opts; threaded through `deploy_android` and
  `deploy_ios_simulator`.

## [0.5.9]

### Changed
- `mix mob.enable tflite` now injects `{:nx_tflite_mob, "~> 0.0.3"}`
  (Hex) instead of the GitHub-branch form. `nx_tflite_mob` v0.0.3 went
  live on Hex with 16 integration tests + a reproducible Mac host
  build path (see
  [its CHANGELOG](https://github.com/GenericJam/nx_tflite_mob/blob/main/CHANGELOG.md)).
  Downstream Mob apps now get version-pinned deps + clean
  `mix deps.tree` output, instead of a transient `github:` checkout.

### Notes
- The Mac host-build path in `nx_tflite_mob` is for that package's own
  test suite, not for downstream consumers — production phone builds
  via `mix mob.deploy --native` continue to use the prebuilt Android
  AAR + iOS xcframework that mob_dev's `MobDev.TfliteDownloader`
  fetches.

## [0.5.8]

### Added
- **End-to-end `mix mob.enable tflite`** — what 0.5.7 promised as
  "lands in 0.5.8". `MobDev.NativeBuild` now auto-detects the
  `:nx_tflite_mob` dep and threads the full TFLite path through
  Android + iOS sim + iOS device build pipelines:
  - `maybe_build_tflite/1` → `MobDev.TfliteDownloader.ensure/1` +
    `MobDev.TfliteNif.build/2` for each target arch
  - `tflite_zig_args_android/1` emits `-Dtflite_static=true
    -Dtflite_lib=…` for the per-ABI Android link
  - `tflite_zig_args_ios/1` emits `-Dtflite_static=true
    -Dtflite_dir=… -Dtflite_framework_dir=…` for the iOS link
  - `copy_tflite_runtime_lib_android/2` drops
    `libtensorflowlite_jni.so` into `android/app/src/main/jniLibs/<abi>/`
    during the assemble step
- `copy_tflite_frameworks_ios/3` (kept as future-compat hook) — see
  the iOS-deploy-fix gotcha below
- 13 new tests covering the public NativeBuild plumbing
  (`native_build_tflite_test.exs`), bringing the TFLite suite to 76
  passing total

### Fixed
- **iOS deploy: TFLite framework binaries are MH_OBJECT, not
  MH_DYLIB.** TFLite's iOS xcframework slices ship their binaries as
  filetype=1 relocatable objects, which the linker statically pulls
  into the app's main Mach-O at build time. Trying to embed them as
  runtime `.framework` bundles tripped iOS install twice during this
  cut: first on missing per-framework Info.plist (which CocoaPods
  generates), then on "code signature version no longer supported"
  (iOS 26+ rejects v1 signatures, and codesign only makes v3 sigs
  for MH_EXECUTE/MH_DYLIB). The fix is to do nothing — the framework
  search-path arg already covers everything at build time.
- **Resolve `:nx_tflite_mob` via `Mix.Project.deps_paths()`** rather
  than `Path.join(deps_path, "nx_tflite_mob")`. The latter assumes
  the dep landed in `deps/` (hex / git deps do), but `path:` deps
  consume in-place from the user's source tree.

### Verified on real hardware
- Moto G Power 5G (BXM-8-256, Android 15): 75-117 ms YOLOv8n via
  NNAPI / `mtk-gpu_shim`
- iPhone SE 3rd gen (A15, iOS 26.4): 24 ms YOLOv8n via Core ML → ANE
  (FP16 model; 214/385 nodes delegated)

## [0.5.7]

### Added
- `mix mob.enable tflite` — wires TensorFlow Lite into a Mob project on
  iOS AND Android. Adds `{:nx_tflite_mob, ...}` to deps and generates
  `<App>.TfliteInit` (returns per-platform default delegate opts —
  NNAPI/`mtk-gpu_shim` on Android, Core ML delegate on iOS). The
  static-NIF table entry `%{module: :tflite_nif, guard: "MOB_STATIC_TFLITE_NIF"}`
  is registered in `MobDev.StaticNifs.default_nifs/0`, so the zig
  build picks it up automatically once `tflite_static=true` is set.
- `MobDev.TfliteDownloader` — fetches `tensorflow-lite-2.16.1.aar`
  (Maven Central, Android) and `TensorFlowLiteC-2.17.0.tar.gz`
  (dl.google.com, iOS) into `~/.mob/cache/`. Honours `MOB_CACHE_DIR`
  for test redirection and `MOB_TFLITE_LOCAL_TARBALL_DIR` for offline
  iteration.
- `MobDev.TfliteNif` — cross-compiles `tflite_nif.c` (from the
  `:nx_tflite_mob` dep) per-arch and archives as `libtflite_nif.a` for
  static linking. Mirrors `MobDev.NxEigenNif` shape. Validates the
  produced symbol (`tflite_nif_nif_init`) before declaring success.

Bundle size impact: ~3-4 MB extracted (Android `libtensorflowlite_jni.so`),
~20-30 MB on iOS (TensorFlowLiteC + CoreML + Metal frameworks). Apps
that don't enable TFLite pay zero size cost — the guard keeps the
static-NIF table entry inactive.

End-to-end deploy (`mob.deploy --native` auto-build + runtime-lib
embedding) lands in 0.5.8; this release ships the building blocks.

## [0.5.6]

### Added
- `CLAUDE.md` "Release flow" section pointing at the canonical process
  in [`mob/RELEASE.md`](https://github.com/GenericJam/mob/blob/master/RELEASE.md)
  (URL form so it resolves without a local mob checkout). mob_dev
  specifics: the pre-push hook additionally runs `mix mob.security_scan`
  here (this is the only repo that ships the scanner), and the OTP
  tarball workflow stays separate from `mix.exs` version bumps.
- `.githooks/pre-push` — same script shipped in mob (cheap preflight
  always, release preflight when `mix.exs` changed). The
  `mob.security_scan` step is gated via `mix help` availability so the
  same hook script works in all three repos.

## [0.5.5]

### Fixed
- Android 15 segfault on launch (Pixel 7+, after the OS rolled out via OTA). Bumps `@otp_hash` from `550d7b78` → `d9045670` to pick up OTP tarballs cross-compiled with `-Wl,-z,max-page-size=16384`. Without the flag, every `.so` in the bundled OTP runtime (`crypto.so`, `asn1rt_nif.so`, `dyntrace.so`, etc.) shipped with 4KB-aligned ELF `PT_LOAD` segments. Android 15 enforces 16KB alignment on devices with 16KB-page kernels and refuses to load misaligned libs, crashing the app at startup. New tarballs are 16KB-aligned (`Align=0x4000`).

## [0.5.4]

### Fixed
- HexDocs source links pointed at the non-existent `main` branch — corrected to `master` so each `</>` glyph in generated docs opens the actual source file.

### Added
- `.github/workflows/test.yml` — runs `mix test`, `mix format --check-formatted`, `mix credo --strict`, and `mix mob.security_scan` on push to master and on every PR.
- `.github/workflows/release.yml` — on tag push, creates a GitHub Release whose body is the matching `## [X.Y.Z]` section from this changelog.

## [0.5.3]

### Changed
- `guides/nifs.md` — rewrote the "Nx backends on mobile" section to match the current state (`mix mob.enable nxeigen` now real, `mix mob.enable mlx` includes the Metal GPU path on iOS device, EXLA "why not" preserved).
- `guides/nifs.md` — restructured the multi-Rust-NIF section to lead with [filmor's](https://github.com/rusterlium/rustler/issues/686) preferred shape (one Rustler crate per app, multiple `#[rustler::nif]` functions inside it). Multi-crate static linking remains supported and documented as an escape hatch, with the specific tradeoffs called out.

## [0.5.2]

### Added
- `mix mob.enable nxeigen` — wires NxEigen (Eigen C++ CPU backend) into a Mob app. Builds as a C++ `:static_nifs` entry, cross-compiled per arch (`arm64-ios`, `arm64-iossim`, `arm64-android`, `armv7a-android`). FFT support uses Eigen's bundled kissfft.
- EMLX Metal GPU enabled on iOS device. `lib/mob_dev/mlx_downloader.ex` now fetches the Metal-enabled `libmlx.a` + `mlx.metallib` bundle; `lib/mob_dev/native_build.ex#maybe_bundle_mlx_metallib/2` copies the precompiled kernel library into the .app at build time, so `EMLX.Backend` with `device: :gpu` works on device without runtime kernel compilation.
- `scripts/release/mlx/ios_device_metal.sh` + supporting build scripts for producing the Metal-enabled tarball; `scripts/release/mlx/patches/0001-ios-metal-build.patch` patches MLX 0.25.1's CMakeLists to switch SDK from `macosx` to `iphoneos` based on `CMAKE_SYSTEM_NAME`.

## [0.5.1] and earlier

Earlier releases predate this changelog; consult the [tag list](https://github.com/genericjam/mob_dev/tags) and the per-tag commit messages for history.
