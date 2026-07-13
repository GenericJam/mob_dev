# Changelog

All notable changes to **mob_dev** are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

Full module documentation: [hexdocs.pm/mob_dev](https://hexdocs.pm/mob_dev).

---

## [0.6.23] - 2026-07-12

### Fixed
- **`cpp_archive` / nx_eigen NDK resolution honors `ANDROID_HOME`.**
  `MobDev.Plugin.CppArchive` and `MobDev.NxEigenNif` hardcoded
  `~/Library/Android/sdk/ndk/<ver>` (+ the `darwin-x86_64` host), ignoring
  `ANDROID_HOME` / `ANDROID_SDK_ROOT` — so a `lang: :cpp_archive` plugin build
  failed with `NDK toolchain not found` wherever the NDK lives elsewhere (CI, a
  shared SDK), unlike the main `NativeBuild` path. Extracted shared
  `MobDev.NdkVersion.{root,host,toolchain_bin,sysroot}/0` (on the existing
  env-aware `sdk_root/0`) and routed `cpp_archive`, `nx_eigen_nif`, and
  `native_build`'s `ndk_sysroot` through them — one source of truth, so the NDK
  path can't diverge again. (MOB-89)

---

## [0.6.22] - 2026-07-11

### Added
- **`ios_release_screenshot` config — opt mob's public-API `screenshot` NIF into
  release builds.** Companion to mob 0.7.20 (mob#71), which carves `screenshot/3`
  into `#if !MOB_RELEASE || defined(MOB_ENABLE_SCREENSHOT)`. Setting
  `config :mob_dev, ios_release_screenshot: true` exports `MOB_ENABLE_SCREENSHOT=1`,
  and the generated `release_device.sh` compiles `mob_nif.m` with
  `${MOB_ENABLE_SCREENSHOT:+-DMOB_ENABLE_SCREENSHOT}` — so a release build can ship the
  screenshot NIF (letting an agent SEE a shipped app's screen to error-correct) while
  the private synthetic-input NIFs (tap/type) stay stripped. Default is unchanged and
  byte-identical (screenshot stays stripped); enabling it is a deliberate choice because
  the NIF captures the app's own window with no OS prompt or indicator. (#39)

## [0.6.21] - 2026-07-08

### Fixed
- **iOS app icons are flattened opaque so App Store upload validation accepts
  them.** A transparent source icon (a common design — a rounded badge on
  transparent corners) produced transparent iOS icons and tripped altool error
  90717 ("Invalid large app icon … can't be transparent or contain an alpha
  channel"). `IconGenerator.write_ios_icons` now composites an alpha-bearing
  source onto an opaque background (`Image.flatten!`) before resizing — using the
  explicit `--adaptive-bg` colour when given, else the same colour sampled for
  the Android adaptive background, so both platforms stay consistent; an opaque
  source is left untouched. **Android icons keep their transparency** (adaptive
  foregrounds + legacy launcher icons need it), and the bundled fallback
  `mob_logo` iOS assets were pre-flattened. Verified: a transparent-badge icon
  now passes App Store validation and reaches TestFlight. (#37)

---

## [0.6.20] - 2026-07-07

### Fixed
- **iOS release builds now compile + link activated-plugin NIFs.** `mix
  mob.release --ios` produced a binary that failed to link for any app with NIF
  plugins — `Undefined symbols: _<module>_nif_init, referenced from
  _erts_static_nif_tab in driver_tab_ios.o`. iOS statically links every NIF into
  the single app binary (no `dlopen` under the App Store sandbox), so the
  generated `driver_tab_ios.c` references each activated plugin's
  `<module>_nif_init`, but the release path (`release.ex` → `release_device.sh`)
  hand-compiled a fixed object list and never touched plugins (the dev path
  already compiled them via `build.zig -Dplugin_c_nifs`). `release_env/2` now
  emits `MOB_PLUGIN_IOS_NIF_SOURCES` + `MOB_PLUGIN_IOS_FRAMEWORKS` from
  `MobDev.Plugin.activated()` (via the new pure, tested
  `MobDev.Release.plugin_ios_build_env/1`); `release_device.sh` compiles each
  plugin NIF source with `-DSTATIC_ERLANG_NIF_LIBNAME=<basename>` + `-fmodules`
  (framework autolink) and links the objects plus the declared frameworks.
  Verified end-to-end: a 10-plugin app links and the IPA validates against its
  App Store distribution profile. Scope: covers `nif_sources` (`lang: :c |
  :objc`) + `ios_frameworks`; plugin `swift_files` and `:cpp_archive` static
  archives on the release path remain a follow-up. (#36)
- **Test: `MobDev.Release.HelpersTest`'s git fixture no longer inherits the
  ambient git environment.** Run inside a git hook (`.githooks/pre-push`), git
  exports `GIT_DIR`/`GIT_WORK_TREE`/`GIT_INDEX_FILE`; the fixture's `git`
  commands inherited them and operated on the outer repo instead of their
  tmpdir, crashing setup — so the suite passed standalone but failed only on
  push. The fixture now clears those vars on every `git` invocation. (#36)

---

## [0.6.19] - 2026-07-07

### Added
- **Plugins can contribute AndroidManifest `<application>` components and `res/`
  files.** Two new optional `android:` manifest keys —
  `manifest_application_snippets` (XML fragments spliced into the app's
  `<application>` block, idempotent per `android:name`) and `res_files`
  (plugin-relative paths copied into the app `res/` tree at their derived
  `res/<type>/<file>` destination, path-contained + host-clobber-guarded +
  signed). This closes the gap that forced plugins needing a
  `<service>`/`<receiver>`/`<provider>` + resource (e.g. `mob_nfc`'s HCE
  `HostApduService` + `apduservice.xml`) to make it a manual `host_requirement`.
  New `MobDev.Plugin.Merge.android_manifest_snippets/1` + `android_res_files/1`
  gatherers (classified in the cross-plugin conflict surface), manifest-schema
  validation, and `NativeBuild` splice + copy (ledger-pruned like `bridge_kt`).
  (MOB-39)

### Changed
- **Plugin contributions merged into host-owned build files are now reversible
  (going forward).** Plugin `<uses-permission>`s, `<application>` components, and
  Gradle deps are fenced in a regenerated-each-build managed region
  (`MobDev.Plugin.ManagedBlock`) in `AndroidManifest.xml` / `build.gradle`, so
  removing a plugin drops its **fenced** contributions (no more dangling
  `<service>` / orphan permission / orphan dep) while hand-authored content
  outside the fence is untouched. Idempotent (`strip(place(x)) == x`); de-dupes
  against existing entries; `strip` is orphan-BEGIN-safe (never deletes host
  lines between a stray marker and a real region). **Forward-only:** entries an
  older mob_dev already appended *unfenced* are indistinguishable from
  hand-authored ones, so they're left in place (not double-added, not
  auto-removed) — regenerate the app, or remove them by hand, to fence them.
  (MOB-40)

### Fixed
- **`mix mob.new_plugin` no longer scaffolds plugins pinned to the abandoned
  `mob ~> 0.6`.** `MobDev.Plugin.Scaffold` hard-coded `{:mob, "~> 0.6"}` in the
  generated `mix.exs` and `mob_version: "~> 0.6"` in every tier's manifest, so a
  freshly scaffolded plugin could not activate against the published mob 0.7.x
  (`installed :mob 0.7.x does not satisfy mob_version "~> 0.6"`). The requirement
  is now derived at scaffold time from the mob actually resolved in the project
  (`Scaffold.detect_mob_requirement/0`), falling back to a single
  `@fallback_mob_requirement` constant (`"~> 0.7"`) when mob isn't loadable.
  `mix.exs` and the manifest always agree. A `Scaffold` test pins the default and
  asserts a generated manifest validates against a matching mob version, so the
  pin can't silently lag a future mob release. (#21)

---

## [0.6.18] - 2026-07-05

### Added
- **`mix mob.provision` can authenticate via an App Store Connect API key**, so
  an unattended user — a CI runner or a headless agent account with no GUI login
  — can provision without a signed-in Xcode Apple ID account. Set `APP_STORE_CONNECT_KEY_ID`,
  `APP_STORE_CONNECT_ISSUER_ID`, and `APP_STORE_CONNECT_API_KEY_PATH` (the downloaded `AuthKey_<id>.p8`)
  and the task passes them to `xcodebuild` as `-authenticationKeyID` /
  `-authenticationKeyIssuerID` / `-authenticationKeyPath`. All three or none
  (a partial set raises, naming what's missing); with none set the signed-in
  Xcode account is used exactly as before. Pure, tested `Mix.Tasks.Mob.Provision.asc_auth_args/1`.
  Signing still needs the certificate + private key in an unlocked keychain — the
  API key only authorizes the profile/device calls. (#31)

## [0.6.17] - 2026-06-29

### Fixed
- **`mix mob.connect` crashed on a Mac set up only for iOS.** The dist-port
  collision check shelled out to `adb forward --list`, and `System.cmd("adb", …)`
  *raises* `:enoent` for a missing binary rather than returning a non-zero exit —
  inside a linked `Task`, so the crash propagated and killed the whole connect.
  `MobDev.Tunnel.run_adb/1` now resolves `adb` via `System.find_executable/1`
  first (mirroring `Discovery.Android.list_devices/0`) and returns `{:error, …}`
  when it's absent, so the port scan degrades to "no forwards" and iOS-only
  Macs work with no Android platform-tools installed. (#29)

### Added
- **`mix mob.connect --ios-only` / `--android-only`** restrict discovery to one
  platform — handy when a phone for another project is plugged in. Set it
  project-wide in `mob.exs` with `config :mob_dev, platforms: [:ios]`. New pure
  helpers `MobDev.Config.parse_platforms/1` and
  `Mix.Tasks.Mob.Connect.resolve_platforms/2`. (#29)

---

## [0.6.16] - 2026-06-24

### Added
- **Plugins can contribute array-valued iOS plist keys** (e.g.
  `UIBackgroundModes`). `apply_plugin_plist_keys!` previously skipped any
  non-scalar `ios.plist_keys` value as unsupported; a list value now **merges**
  into the host Info.plist array (creating it if absent, appending only the
  missing string entries, deduped) instead of clobbering it. So one plugin can
  add `bluetooth-central` while another (e.g. `mob_background`) keeps `audio`.
  Merge decision extracted to the pure, tested `NativeBuild.plist_array_additions/2`.

---

## [0.6.15] - 2026-06-23

### Security
- **Bumped `req` 0.5.18 → 0.6.2** (pulls `finch` 0.22.0 → 0.23.0), clearing
  EEF-CVE-2026-49755 (HIGH) and EEF-CVE-2026-49756 (LOW) flagged by
  `mix mob.security_scan`. `req` is a transitive dep (via `igniter`); the bump
  stays within `igniter`'s `~> 0.5` requirement.

---

## [0.6.14] - 2026-06-23

### Added
- **`:extra_static_libs` hook on `:static_nifs` entries** — a Mob app can now
  link external per-ABI static archives alongside its project NIF archives.
  Some project NIFs intentionally declare `extern` symbols and don't host-link
  their backing archive (avoiding a host/device archive mismatch during `mix
  compile`); this lets the native app link resolve those symbols against the
  correct per-ABI `.a`. Entries require concrete per-ABI keys (`:ios_sim`,
  `:ios_device`, `:android_arm64`, `:android_arm32`, `:android_x86_64`), and the
  matching archive paths are appended to the existing `-Dproject_rust_libs=`
  link argument. `-D<module>_static=true` is emitted only on the ABIs where the
  entry applies, and iOS project-NIF filtering is now per-ABI so a device-only
  guarded entry doesn't leak into simulator args. Also passes Zigler 0.16's
  required generated-build flags when re-driving staged Zig NIF builds and
  resolves Zigler dotfile sources with `match_dot: true`. Verified on a physical
  SM-T577U (arm64-v8a) tablet via a Ghostty VT NIF. (#24)

---

## [0.6.13] - 2026-06-20

### Changed
- **`mix mob.deploy --native` now preserves on-device app data when the signing
  key matches.** The Android install path previously ran an unconditional
  `adb uninstall` before `adb install`, which wiped `MOB_DATA_DIR` (on-device
  identity, screen stores) on **every** native deploy — even an in-place update
  signed with the same (e.g. committed) debug keystore. It now attempts
  `adb install -r` first and only falls back to uninstall + install when the
  in-place update is genuinely rejected (`INSTALL_FAILED_UPDATE_INCOMPATIBLE`
  from a signature mismatch, `INSTALL_FAILED_VERSION_DOWNGRADE`, etc.). Apps that
  pin a committed debug keystore now keep their identity across `--native`
  redeploys. Decision logic extracted to `NativeBuild.needs_clean_reinstall?/2`
  and unit-tested.

### Fixed
- **`mix mob.deploy --native --android` now fails fast with the real cause when
  `zig` is missing** (landed in code before 0.6.13; previously undocumented).
  The Android JNI build is driven by `build.zig`; with `zig` off PATH it used to
  print a yellow "skipping build.zig step" warning and fall through to a CMake
  fallback that references C sources mob 0.7+ no longer ships, dying ~150 lines
  later with a misleading `Cannot find source file: .../mob_nif.c`. It now aborts
  before Gradle with an actionable message (install zig 0.15.x, verify with
  `mix mob.doctor`) when `build.zig` is present, `zig` is absent, and the legacy
  C sources are gone. Decision extracted to `NativeBuild.zig_build_plan/3`. (#20)

---

## [0.6.12] - 2026-06-19

### Fixed
- **16 KB page-size alignment enforced at build time for every app.** Android
  15+ devices use 16 KB memory pages and Google Play requires every bundled
  `.so` to have 16 KB-aligned LOAD segments. The `-Wl,-z,max-page-size=16384`
  link flag lives in the app's `build.zig`, which is copied once at `mix mob.new`
  and never regenerated — so apps generated before the template carried the flag
  kept linking 4 KB-aligned `.so` and failed Play. `mix mob.deploy --native` now
  reads the app's `build.zig` and, if its `-shared` link lacks the flag, injects
  it before linking (idempotent — a no-op when already present, e.g. the current
  mob_new template or a hand-fixed app). Pure core in `inject_page_size_flag/1`.

---

## [0.6.11] - 2026-06-19

### Added
- **`mix mob.adopt`** — installs Mob into an *existing* Phoenix project,
  the Igniter-based install-into-existing counterpart to `mix mob.new`
  (which generates from scratch). Composable: the orchestrator runs the
  sub-installers `mob.adopt.{deps,bridge,screen,mob_app,mob_exs,native,finalize}`,
  each invokable independently. Default LV-bridge mode wires `window.mob`
  through a LiveView `phx-hook` and generates a `mob_app.ex` that boots the
  host Phoenix endpoint on-device (SQLite Repo assumed); `--no-live-view`
  generates a thin-client shell whose WebView opens a deployed server.
  Pre-1.0: refuses loudly (via Igniter issues) on umbrella / non-Phoenix /
  heavily-customised `app.js` or root layout / non-SQLite LV hosts rather
  than risk breaking the app. The native Android/iOS trees (`--android` /
  `--ios`) render from mob_new's templates and require the **mob_new archive
  installed** (`mix archive.install hex mob_new`) — mob_new stays the single
  source of native templates; the Elixir-side adoption needs no archive.
  Contributed as [mob_new#8](https://github.com/GenericJam/mob_new/pull/8)
  by [@ken-kost](https://github.com/ken-kost) and relocated here — adopt is
  an Igniter task that mutates an existing project (like `mob.add_nif` /
  `mob.enable`), so it belongs in mob_dev (a Hex dep), not in mob_new (a
  self-contained Mix archive that can't carry Igniter). See
  `decisions/2026-06-19-mob-adopt-lives-in-mob_dev.md`. The shared
  patcher/generator helpers are duplicated from mob_new into
  `MobDev.Adopt.{Patcher,Generator}` pending the Phase-5 Igniter
  reunification.

---

## [0.6.10] - 2026-06-19

### Added
- **Plugin `:cpp_archive` NIFs** — ship a C++ static library (e.g. an Nx
  backend) from a plugin. Manifest-driven cross-compile + `--whole-archive`
  static link (rule #11), with `<module>_nif_init` symbol verification and
  duplicate-init cross-validation. (#18)

### Fixed
- cpp_archive builds now **fail fast with a named error** on an unsupported
  Android ABI (e.g. the x86_64 emulator) instead of silently skipping — which
  previously deferred an unresolved `<module>_nif_init` to an on-device link
  failure.
- The plugin manifest now requires a lowercase `:module` atom for
  `:cpp_archive` entries (fail-loud instead of fail-open / `libnil.a`).

---

## [0.6.9] - 2026-06-18

### Fixed
- **`mix mob.publish --android` now commits when Google requires
  `changesNotSentForReview=true`.** Uploading a release while the app is under
  policy review (or otherwise can't auto-send for review) made the Play Edits
  `:commit` fail with HTTP 400 ("Please set the query parameter
  changesNotSentForReview to true"), discarding the whole edit so nothing
  reached the track. `commit_edit/3` now detects that 400 and retries the commit
  with `?changesNotSentForReview=true`; the changes land on the track and are
  sent for review from the Play Console UI. Verified uploading Io v13 to the
  internal track.

---

## [0.6.8] - 2026-06-18

### Added
- **`mix mob.connect --only <serial>` (alias `--device`/`-d`, repeatable).**
  Restricts the run to devices whose serial/udid contains the given substring.
  Without it, connect attaches to *every* running device, so one slow or locked
  device (typically a plugged-in physical iPhone whose app restart blocks) could
  stall the whole session before any node connected. Verified end-to-end against
  a single Android phone: `mix mob.connect --only ZY22CRLMWK` tunnels, restarts,
  and connects `livebook_mob_android_zy22crlmwk@127.0.0.1` on its serial-derived
  port 9633, then RPC into the device BEAM works (read live state, eval code).

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
