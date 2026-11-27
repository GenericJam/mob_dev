# Plugin Info.plist keys: project wins on conflict, plugins fill gaps

- Date: 2026-05-28
- Status: accepted

## Context
Tier-1/tier-2 mob plugins can declare iOS `Info.plist` keys in their manifest
(`ios.plist_keys: %{...}`). The plugin extraction epic needs mob_dev's iOS
bundle path to merge these into the generated `.app/Info.plist` — without that,
plugins that depend on entitlements / privacy strings (e.g. a camera plugin
needing `NSCameraUsageDescription`) don't actually work end-to-end.

The non-obvious question is **precedence**: when both the project's
`ios/Info.plist` and one (or more) activated plugins declare the same key,
who wins?

Two reasonable answers:
- **Plugin wins** — guarantees the plugin works the way its author intended.
  Project author must read every plugin's manifest to know which of their own
  keys will be silently overridden.
- **Project wins** — the project author always sees the value they set. A
  plugin's declaration acts as a *default* for keys the project hasn't
  customised.

## Decision
**Project's `ios/Info.plist` wins; plugins fill gaps.** Implemented in
`MobDev.NativeBuild.apply_plugin_plist_keys!/1` via PlistBuddy `Add`, which
fails (non-zero exit) when a key is already present. We swallow that failure
and treat it as "project already declared this — leave it alone."

When multiple plugins declare the same key, `MobDev.Plugin.Merge.plist_keys/1`
already resolves it ("later plugins win on conflict" per its docstring), and
the resulting single value is what gets `Add`-attempted against the project
plist.

Initial value-type support: `:string`, `:bool`, `:integer`. Other types log
a "skipping :<key>" message via `Mix.shell().info/1` rather than failing the
build — extending this is a future ergonomics task driven by real plugin
needs.

## Consequences
- The project author's `ios/Info.plist` is always authoritative — no plugin can
  silently change a privacy string the user set themselves. This matches the
  least-surprise principle for app submission: what the author sees in
  `ios/Info.plist` is what App Store Connect will see.

  > **Correction (2026-10-25):** what App Store Connect sees is
  > `ios/Info.plist` plus the plugins' keys for the gaps, and mob_dev's own
  > stamps. The release left the plugins' keys out until the addendum below.
- Plugins ship sensible defaults that "just work" for the common case. A camera
  plugin can include a generic `NSCameraUsageDescription` default; an app
  author who never touches their `Info.plist` still gets a functioning camera
  permission prompt.
- PlistBuddy's exit code conflates "key already present" with "value malformed"
  / "type mismatch" / etc. We currently can't distinguish them, so genuine
  failures pass silently. Acceptable for the first cut; a follow-up can parse
  stderr to surface non-duplicate failures explicitly.
- Setting `CFBundleIdentifier`/`CFBundleExecutable`/`CFBundleName` in the
  device path still uses `Set` (overwrite) — those are mob_dev's own
  derivations, not plugin contributions, and must take precedence over any
  literal value the project's `ios/Info.plist` happens to carry over from a
  template.

## Addendum 2026-10-25: the iOS release merges them too

`mix mob.release --ios` never called `apply_plugin_plist_keys!`:
`release_device.sh` copied `ios/Info.plist` into the bundle as written. A
release therefore lost every plugin's `ios.plist_keys`, the privacy strings
and Bonjour service types the sim and device builds carried, and iOS refused
what the plugin needed (a Bluetooth plugin's first scan ends the app without
`NSBluetoothAlwaysUsageDescription`; a browse for a service type missing from
`NSBonjourServices` finds nothing).

- `apply_plugin_plist_keys!/2` now takes the activated plugins and is public:
  `write_bundle_info_plist!/3` passes `MobDev.Plugin.activated()`, the release
  passes the list `build_ipa/1` already gated.
- `Release.write_release_info_plist!/2` writes the project's plist with the
  plugins' keys to the device build-inputs dir (`release_Info.plist`), and
  `release_env/5` takes its path as a required argument: the script bundles
  that file (`MOB_IOS_INFO_PLIST`; an unset variable stops the script rather
  than bundling the bare plist), and the URL-types and UIAppFonts commands
  are computed from it, as the dev build computes them from the bundle's
  merged file. Computed from `ios/Info.plist`, they would not see a key a
  plugin added (an `Add :CFBundleURLTypes array` the merged file already has
  aborts the script). The bundle id, layout and DT* stamps are pure over
  `mob.exs` or `Set`, so they behave the same either way.
- `release_Info.plist` sits beside the device build's generated sources but
  is not one of them: zig never reads it, and each release overwrites it
  before the script runs, so one left by an earlier release is never bundled.
  It is written in place rather than with `write_build_input!/2`; two
  releases of one project at once are not supported anyway (they share
  `_build/mob_release`).
- Why a merged copy and not PlistBuddy commands passed to the script like
  `MOB_IOS_LAYOUT_PLIST_COMMANDS`: the merge reads the plist it writes (host
  keys to leave alone, array entries already present), so it has to run
  against the file. Running the same function keeps the precedence rule above
  identical in both paths.
