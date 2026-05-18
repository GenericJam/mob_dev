# Changelog

All notable changes to **mob_dev** are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

Full module documentation: [hexdocs.pm/mob_dev](https://hexdocs.pm/mob_dev).

---

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
- 3 new tests in `MobDev.DeviceTest` pin the `:node_suffix` field contract.

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
