# `mix mob.doctor` reports the Xcode and iOS SDK, and warns when they can't build for iPhone Duo

- Date: 2026-10-01
- Status: accepted

## Context

MOB-201 (epic MOB-200): iPhone Duo ships 2026-10-23 with iOS 27.1. Its API
(`ReservedRegion`, `ArrangementView`, …) and its simulator come with Xcode 27.1
and the iOS 27.1 SDK; the 27.0 SDK's `.swiftinterface` files don't expose them.
The dev Mac has Xcode 27.0 (27A266a) and Xcode 26.6 (17F113, iOS SDK 26.5)
only, so this change covers what can be built and checked without 27.1.

`mix mob.doctor` printed the first line of `xcodebuild -version` and failed
only below Xcode 15. It didn't show the iOS SDK, and an unparseable version
line counted as Xcode 99.

## Decision

- The Tools section has three rows for the selected Xcode: `Xcode` (version,
  build, app path), `iOS SDK` (`xcrun --sdk iphoneos --show-sdk-version`) and
  `iPhone Duo`. The Xcode is the one `DEVELOPER_DIR` selects, else
  `xcode-select -s`: every probe goes through `xcodebuild`, `xcrun` and
  `xcode-select -p`, which resolve it the same way.
- `iPhone Duo` warns `unsupported (needs Xcode 27.1+)` when the Xcode or its
  iOS SDK is older than 27.1. It is OK only when both versions were read and
  both are 27.1 or later; if the one that was read is 27.1+ and the other
  couldn't be read, it warns `unconfirmed`. It is never a failure: an older
  Xcode still builds every app, only without Duo support.
- Xcode older than 15 still fails. A missing iOS SDK (the iOS platform is a
  separate download since Xcode 15) and an unparseable `xcodebuild -version`
  warn; neither stops the run.
- Versions are compared as integer tuples, so 27.10 is newer than 27.9. The
  parser reads the `Xcode N[.N[.N]]` line wherever it is in the output and
  ignores text after the version (`27.1 beta 3`); the SDK version is the first
  output line that is only a version, so warnings xcrun prints first (stderr is
  merged) are skipped. Apple's beta build numbers can't be told from release
  ones (16.2 shipped as 16C5032a), so the row says `beta` only when the
  version line or the selected app's name does (`Xcode-beta.app`). No regex
  literals: this repo avoids them for OTP 28.0.
- SDK detection in `MobDev.NativeBuild` needs no change. It asks
  `xcrun -sdk iphonesimulator|iphoneos --show-sdk-path` for every build (sim
  app, device app, exqlite/pythonx and Zigler NIF cross-compiles); the
  `ios/build.zig` it drives compiles and links through `xcrun -sdk … swiftc`
  and `xcrun cc`; `MobDev.Release` reads the SDK and Xcode versions it stamps
  into `DT*` keys from `xcrun` and `xcodebuild` too. Nothing names an Xcode
  path or SDK version, so selecting Xcode 27.1 makes builds use the 27.1 SDK.
  Checked on 2026-10-01 with one generated app (`mix mob.new --local`, mob,
  mob_new master): `mix mob.deploy --native --ios` on Xcode 27.0 linked a
  binary with `LC_BUILD_VERSION sdk 27.0`; the same command with
  `DEVELOPER_DIR` set to Xcode 26.6, on the warm zig cache, recompiled the
  Swift step (new `swift_mob.o`, `sdk 26.5`) and linked `sdk 26.5`; both apps
  ran on an iOS 27.0 and an iOS 26.5 simulator. `minos` stayed 17.0.
- Deployment target: keep the iOS 17 floor and gate Duo API at each use site
  with `@available` (`iOS 27.1` for `ReservedRegion` and `ArrangementView`), as
  MOB-201 recommends. It is recorded with the rest of the fold design in mob's
  `decisions/2026-10-01-fold-aware-layouts.md`, section 8 (MOB-208).
- CI: GitHub's `xcode-27` image (preview, macOS 27) has Xcode 27.0, 27.1
  (27A9269) and 27.2 beta with their iOS SDKs, but only the iOS 27.0
  simulator runtime and no iPhone Duo simulator. The `xcode` job in
  `.github/workflows/test.yml` runs `test/mob_dev/xcode_live_test.exs`
  (`:xcode_live`, excluded by default) against Xcode 27.1 and 27.0 on
  `xcode-27` and Xcode 26.6 on `macos-26`. It runs `mix mob.doctor` itself
  and asserts the Xcode, iOS SDK and Duo rows it prints from the real tools.

## Consequences

- Every doctor run on Xcode before 27.1 shows one more warning.
- The CI lane proves doctor's reading of Xcode 27.1, not that an app builds
  against the 27.1 SDK; mob_dev's suite has no iOS build. A build lane needs
  the pinned zig, the OTP iOS runtime and mob/mob_new checkouts on a macOS
  runner.
- Open under MOB-201, blocked on Xcode 27.1 on a dev Mac: verifying the 27.1
  SDK build and the Duo simulator. Also open: the compile-time guard that lets
  mob's Swift name Duo types only when the SDK has them. `@available` doesn't
  help when the symbol is missing from the SDK. ObjC can test
  `__IPHONE_OS_VERSION_MAX_ALLOWED`; Swift has no SDK-version condition, so the
  build would pass one (for example `-D MOB_IOS_SDK_27_1` from the SDK version
  doctor now reads). That needs an `ios/build.zig` option, which existing
  apps' build files don't declare.
