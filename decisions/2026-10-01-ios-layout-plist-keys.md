# iPad / Split View plist keys: `mob.exs` overrides at bundle time, doctor warns

- Date: 2026-10-01
- Status: accepted

## Context

MOB-206 (iPhone Duo prep) and MOB-165 (iPad letterbox). mob_new's
`ios/Info.plist` declared no `UIDeviceFamily`, so a generated app ran on iPad
in iPhone compatibility mode: 320x480 on a 13-inch iPad Pro, no rotation-driven
resize, no Split View or Slide Over. mob_new now generates `UIDeviceFamily`
`[1, 2]`, `UIRequiresFullScreen` `false` and all four orientations for iPhone
and `~ipad`. That fixes new apps only, and gives apps no supported way to say
"iPhone only" or "portrait only".

Every mob_dev iOS build copies `ios/Info.plist` into the bundle and patches the
copy: plugin keys, fonts, `CFBundleIdentifier` (`NativeBuild.bundle_ios_app/3`,
`bundle_ios_device_app/4`) and, for `mix mob.release`, the DT* keys and an
iPhone-only `UIDeviceFamily` default when the key is absent
(`release_device.sh`). The project file itself is never rewritten.

Facts this rests on, checked 2026-10-01 against Xcode 27.0:

- The iOS 27.0 SDK defines two device families: `SDKSettings.plist`
  `DeviceFamilies` lists `1` (iPhone) and `2` (iPad), and
  `SUPPORTED_DEVICE_FAMILIES` is `"1,2"`. `UIUserInterfaceIdiom` has no Duo
  case. Whether the iOS 27.1 SDK adds a family for iPhone Duo is **unknown**
  until Xcode 27.1 ships; Apple's material so far treats Duo as an iPhone, and
  no value is invented here.
- TN3192: `UIRequiresFullScreen` is deprecated since iPadOS 26. Built with the
  iOS 27 SDK, an app that sets it is resized anyway (discretely), and from iOS
  27 the key also applies to iPhone. Resizable apps should support all four
  orientations and omit the key; `false` is equivalent to omitting it.

## Decision

- **Two `config :mob_dev` keys (a third, `multi_window`, in the addendum
  below), applied to the bundle at build time**:
  `ios_target_devices` (`[:iphone, :ipad]` or `[:iphone]`) sets
  `UIDeviceFamily`; `ios_orientations` (`:all`, `:portrait`, `:landscape`) sets
  the iPhone `UISupportedInterfaceOrientations` (removing any `~iphone`
  variant, which would otherwise win on iPhone) and always writes all four to
  `UISupportedInterfaceOrientations~ipad`. iPad-only (`[:ipad]`) is rejected:
  mob doesn't offer it. `MobDev.IosLayoutPlist` turns them
  into PlistBuddy commands; the sim and device bundles run them
  (`apply!/2`), and `mix mob.release` passes the same commands to
  `release_device.sh` (`MOB_IOS_LAYOUT_PLIST_COMMANDS`) ahead of its
  `UIDeviceFamily` default. An invalid value raises before anything is
  stamped.
- **Bundle time, not generation time.** The setting has to work for apps that
  already exist, and mob_dev builds every bundle from a copy, so the override
  reaches existing and new apps alike without rewriting a file the user owns.
  A generator-only option would have fixed new apps and nothing else.
- **Unset keys leave `ios/Info.plist` as written.** mob_dev doesn't turn on
  iPad for an existing app by default: an App Store app that has shipped iPad
  support can't drop it in an update, and iPad screenshots become mandatory,
  so it has to be the app author's call. mob_new's `mob.exs` sets both keys
  explicitly (universal, all orientations), so new apps are universal through
  both the plist and the config.
- **iPad always gets all four orientations.** iPadOS 26 rotates resizable apps
  freely, so an iPad orientation lock doesn't hold anyway; iPad multitasking
  has required all four.
- **No override for `UIRequiresFullScreen`.** Its only supported value is
  `false`; an app that sets it `true` is told to delete it.
- **`mix mob.doctor` warns, never fails**, when the effective plist (project
  file plus `mob.exs` overrides) leaves iPad out, locks iPhone to portrait or
  landscape, restricts iPad orientations, or sets `UIRequiresFullScreen`. Each
  warning gives the `mob.exs` line and the plist XML that fix it. A choice
  made in `mob.exs` (`ios_target_devices: [:iphone]`,
  `ios_orientations: :portrait`) is deliberate and isn't warned about. An
  invalid `mob.exs` value fails, since the build refuses it. The plist is read
  with `:xmerl` (top-level `<dict>` only), so the check also runs off macOS; a
  binary plist gets a "couldn't check" warning.

## Consequences

- An existing app that deploys with an unchanged `mob.exs` builds exactly as
  before; `mix mob.doctor` tells it how to become universal.
- With either key set, editing those keys in `ios/Info.plist` has no effect on
  the built app: `mob.exs` wins. The template comment and the module doc say so.
- If Xcode 27.1 introduces a Duo device family, `ios_target_devices` gains a
  value and the template gains an entry; until then Duo runs an iPhone app.
- Not covered: Android (no manifest change in MOB-206), and the iOS 27.1 SDK
  behaviours (edge-to-edge, side toolbar), which come from building against
  that SDK rather than from a plist key.

## Addendum 2026-10-02: `multi_window` (MOB-245)

A third key uses the same mechanism: `multi_window: true` stamps
`UIApplicationSceneManifest` → `UIApplicationSupportsMultipleScenes` `true`,
`false` deletes it (iOS reads an absent key as `false`), unset leaves the plist
alone. The runtime side, one `Mob.Router` per window scene, is mob's
(`decisions/2026-10-02-one-router-per-window-scene.md` in mob, PR #184).

PlistBuddy's `Add` creates a missing parent dict, so on a plist with no scene
manifest it would put the app on the scene lifecycle with no delegate (a blank
window). The commands therefore start with `Print
:UIApplicationSceneManifest:UISceneConfigurations:UIWindowSceneSessionRoleApplication:0`
(an application scene configuration, i.e. the `SceneDelegate`), which must
succeed: the dev build raises and `release_device.sh` exits with the fix, and
`mix mob.doctor` fails the same combination. Every app mob_new has generated
has the manifest.
