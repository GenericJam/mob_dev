# Deep-link URL schemes: `config :mob_dev, url_schemes`, stamped at build time

- Date: 2026-10-03
- Status: accepted

## Context

MOB-379 makes deep links first-class: an app opened by `myapp://…` gets the URL
on the BEAM. mob 0.9.11 delivers it (`mob_deliver_link/1` from `beam_jni.c` and
the scene delegate, then `{:link, %{url: url, source: :launch | :running}}` to
the root screen). The OS only routes a URL to the app if the app declares the
scheme: an Android `VIEW` intent filter on an activity, an iOS
`CFBundleURLTypes` entry. Until now an app author had to hand-edit
`AndroidManifest.xml` and `ios/Info.plist`, and nothing kept the two in step.

## Decision

- **One build-time key in `mob.exs`: `config :mob_dev, url_schemes:
  ["myapp", …]`.** It sits with `ios_target_devices` / `ios_orientations` /
  `multi_window` (`decisions/2026-10-01-ios-layout-plist-keys.md`): settings
  mob_dev stamps into native files on every build, not runtime config. Nothing
  on the BEAM needs the list, since mob delivers whatever URL the OS hands it.
  Unset, `nil` or `[]` means no scheme (`nil` reads as unset, as it does for
  `IosLayoutPlist`'s keys). `MobDev.UrlSchemes` owns validation and both
  transforms.
- **Validation, at build time.** Each entry must be a lowercase RFC 3986
  scheme (`[a-z][a-z0-9+.-]*`). Lowercase is required because Android matches
  intent-filter schemes case-sensitively and URLs carry the scheme in
  lowercase. A filter for `MyApp` would never match. `http` and `https` are
  refused: Android App Links and iOS universal links need a host and domain
  verification (`assetlinks.json`, `apple-app-site-association`, an
  associated-domains entitlement), which a bare scheme can't express. A bare
  `https` filter would also offer the app for every web link. Those are a
  separate feature. An invalid value raises `Mix.Error` from the build, the
  release and `mix mob.doctor` (a `:fail` row; an `:ok` row lists the schemes).
  A chosen setting is never silently ignored.
- **Android: a managed block inside the launcher activity.**
  `android/app/src/main/AndroidManifest.xml` gets one `<intent-filter>`
  (`android.intent.action.VIEW`, categories `DEFAULT` and `BROWSABLE`, one
  `<data android:scheme>` per scheme) just before the launcher activity's
  `</activity>`, fenced by `mob:url-schemes` markers
  (`MobDev.Plugin.ManagedBlock`, the mechanism behind `mob:plugin-permissions`
  / `mob:plugin-components`). The launcher activity is the first `<activity>`
  or `<activity-alias>` with a `MAIN` + `LAUNCHER` intent filter. Commented-out
  markup doesn't count. The block is regenerated every build (applying twice
  equals applying once), removed when the key is unset or empty, and the file
  is written only when it changed. Both Android build paths run it through
  `NativeBuild.apply_android_url_schemes!/1`: the dev build
  (`NativeBuild.build_android/2`, after the plugin manifest merge) and
  `mix mob.release --android` (`ReleaseAndroid.build_aab/1`, before Gradle).
  The plugin manifest merges don't run in a release. This one does, so a
  release never depends on an earlier dev build having stamped the current
  setting. With schemes set and no launcher activity, the build raises.
  It also raises when the launcher's `</activity>` shares a line with other
  markup: a managed block occupies whole lines, and splitting the host's line
  would make removal leave the file changed.
- **iOS: one appended `CFBundleURLTypes` entry in the built bundle.** The sim
  and device builds (`NativeBuild.write_bundle_info_plist!/3`, which both
  share, calls `apply_plist!/3` after `IosLayoutPlist.apply!/2`) and
  `mix mob.release --ios` (`Release.url_types_plist_env/2` →
  `MOB_IOS_URL_TYPES_PLIST_COMMANDS`, a loop in `release_device.sh` after the
  layout loop) run the same PlistBuddy `Add` commands. Elixir computes them
  from the plist's current `CFBundleURLTypes`: the release reads
  `ios/Info.plist`, which the script copies into the bundle with
  `CFBundleURLTypes` untouched. `ios/Info.plist` is never rewritten. Each
  build starts from a fresh copy, so removing the key removes the entry.
  The plist is read through `plutil -convert xml1`, so a binary plist works.
- **PlistBuddy facts behind the command shape** (checked 2026-10-03 on this
  Mac). `Add :CFBundleURLTypes array` fails ("Entry Already Exists", exit 1)
  when the key exists. `Add :CFBundleURLTypes:<n> dict` inserts at `<n>`,
  shifting existing entries, and appends when `<n>` is the count or larger.
  On a missing key it creates a dict named `CFBundleURLTypes`, not an array.
  So the array is added only when the plist has none, and the new entry goes
  at index = the existing entry count, after the app's own entries (an OAuth
  reversed client id stays at index 0). Every command must succeed, in both
  `apply_plist!/3` and the shell loop (`set -e`). Unlike the layout commands,
  no failure is tolerated, because none is expected. A `CFBundleURLTypes` that
  isn't an array raises.
- **The entry is `CFBundleURLName` = the iOS bundle id, `CFBundleTypeRole` =
  `Viewer`.** The bundle id (`NativeBuild.ios_bundle_id/1`) is the id every
  iOS build path already stamps, and Apple recommends a reverse-DNS name for
  a URL type. Apple's Info.plist key reference marks `CFBundleTypeRole` as
  required in each `CFBundleURLTypes` dictionary. `Viewer` is the role for an
  app that opens the URL.
- **Android de-dupe: only full coverage on the launcher suppresses the
  managed filter.** A scheme is skipped only when the launcher activity
  itself, outside the managed block, has a `VIEW` filter with both the
  `DEFAULT` and `BROWSABLE` categories whose `<data>` elements declare the
  scheme and set no other `android:` attribute (no host, port, path*, ssp* or
  MIME type). Android merges every `<data>` in a filter, so a single
  `android:host` anywhere in it narrows all of its schemes. Such a filter
  routes every URI of the scheme to the launcher, which is exactly what the
  managed filter would add. Anything less doesn't suppress it: a host- or
  path-restricted filter covers part of the scheme, a filter without
  `DEFAULT` doesn't match ordinary implicit intents, one without
  `BROWSABLE` doesn't match links from a browser, and a filter on another
  activity routes the scheme to that activity, not to the one mob delivers
  from. Silently skipping in those cases would leave `url_schemes` set and
  some of its URLs unroutable, which was the defect in the first version of
  this rule. It treated a scheme in any `VIEW` filter, in any activity, as
  declared.
- **A scheme another activity also declares is added anyway, with a
  warning.** The build prints one line per scheme
  (`UrlSchemes.declared_elsewhere/2`). Android may then show a chooser
  between two activities of the same app. That is the host's arrangement to
  resolve, and the setting still has to take effect on the launcher.
  Plugin-contributed activities (the `mob:plugin-components` block) count as
  other activities. `<queries>` entries and commented-out markup are not
  declarations.
- **iOS de-dupe:** a scheme found in any existing `CFBundleURLTypes` entry is
  skipped, compared case-insensitively as iOS matches schemes. There is one
  app target, so any entry routes the scheme to the app. When every scheme is
  already covered, nothing is added: no Android block, no iOS entry.
- **`launchMode` is enforced, not rewritten.** With `url_schemes` set, the
  launcher activity must be `android:launchMode="singleTask"` or
  `singleInstance`. For an `<activity-alias>` launcher this means the
  launch mode of its `android:targetActivity`. Both Android build paths
  (`apply_android_manifest!/2`) raise otherwise, and `mix mob.doctor` fails
  the same manifest (`UrlSchemes.launch_mode_error/2`). The reason: a `VIEW`
  intent from another app's task (a QR scanner, a browser that doesn't add
  `FLAG_ACTIVITY_NEW_TASK`) would otherwise create a second `MainActivity` in
  that task, and two activities would compose against one `MobBridge` and
  BEAM. `singleTask` has a cost, though: an intent that reaches the existing
  instance, including a tap on the launcher icon, finishes every activity
  stacked above `MainActivity` (an open picker or scanner). So mob_new's
  template stays `singleTop`, and an app that takes deep links opts in by
  setting `singleTask` itself. mob_dev doesn't rewrite `launchMode`: the
  change alters back-stack behaviour for the whole app, so it is the
  author's decision, and the error says what to set and why. The check runs
  only while `url_schemes` is non-empty, so an app can drop the key and go
  back to `singleTop`. The managed block is still stripped then. An earlier
  draft of this record only recommended `singleTask`, assuming the template
  set it. On iOS the URL reaches the existing scene through
  `scene:openURLContexts:`, so there is no equivalent.

## Consequences

- After a build with `url_schemes` set, `AndroidManifest.xml` (host-owned and
  committed) carries the managed block, as it already does for plugin
  permissions and components. Editing inside the markers is lost on the next
  build. A broad filter on the launcher written outside them takes over its
  scheme. A narrower one sits alongside the managed filter, and both apply.
- The marker lines are matched exactly. Re-indenting them by hand (an IDE
  reformat) stops the build from recognising the old block and adds a second
  one. This risk is shared with every `ManagedBlock` region.
- The launcher-activity search is textual, like the other manifest merges. A
  `>` inside an attribute value of an `<activity>` start tag would end the tag
  early. No real manifest does that.
- Verified App Links and universal links (`https://example.com/…` with
  verification) remain out of scope. They need host config, an entitlement on
  iOS, and files served from the domain.
