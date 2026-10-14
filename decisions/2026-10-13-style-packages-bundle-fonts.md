# Style packages bundle fonts through the plugin font path

- Date: 2026-10-13
- Status: accepted
- Issue: MOB-476

## Context

A style package (`priv/mob_style.exs`, `MobDev.Style`) could only declare
tokens: a theme module. A typographic style (mob_bezalel: EB Garamond,
Instrument Sans, Frank Ruhl Libre) names its faces in the theme's `fonts:`
map through `Mob.Theme.font/2`, and those names resolve only if the files are
in the app: the iOS `.app` root plus `UIAppFonts`, and Android `res/font/`.
Before this, the files had to come from the host's `priv/fonts/` or from a
plugin manifest's `assets.fonts`, so a style could not be self-contained.

## Decision

`priv/mob_style.exs` takes an optional `assets: %{fonts: [path]}`, with paths
relative to the style package root. It is the same key and shape as the plugin
manifest's, so authors write one thing.

- **Fonts only.** Any other key in a style's `assets`, `:images` included, is a
  validation error. Images belong to plugins, which get the
  `plugin://<plugin>/<file>` resolver. A style has no image resolver to use them
  with, so accepting the key would validate and then ship nothing.
- **One font pipeline.** `MobDev.Style.fonts!/1` resolves the activated styles'
  fonts to absolute paths, and `NativeBuild.collect_all_fonts/0` appends them to
  the app and plugin fonts. Dedup and the iOS basename / Android
  resource-name collision checks are the existing ones, so a style font that
  collides with an app or plugin font fails the build the same way.
- **A missing file fails the build** with the style name, the declared path and
  the resolved path, the same rule `runtime_entries!/0` applies to an invalid
  manifest. Without that check the build would crash in `File.cp!` with
  nothing pointing at the style. An invalid manifest raises here too, rather
  than contributing no fonts.
- `style_spec_version` stays `1`: the key is optional and additive, and an
  older mob_dev ignores it (styles have no unknown-key check). The reverse is
  accepted: a v1 style that carried some other `assets` value, ignored before,
  fails validation now. No published style does; the CHANGELOG says so.

## Consequences

- A style that uses `assets` needs a mob_dev with this change to ship its
  fonts. On an older mob_dev the manifest still validates, the fonts are not
  bundled, and the theme's font names fall back to the system face.
- `mix mob.release --ios` bundles the same fonts: its `release_device.sh` used
  to build the `.app` without any custom fonts (app, plugin or style), found in
  the 0.7.25 release review and fixed in MOB-480 through
  `NativeBuild.ios_font_copies!/1` and `Release.ios_fonts_release_env/2`.
- Style fonts are not signed. Styles have no signature scheme, and fonts are
  data, not code.
- An app that copied a style's fonts into its own `priv/fonts/` hits a
  bundle-name collision once the style lists the same files, since app fonts
  and style fonts are different paths. That is the existing collision rule;
  the fix is to delete the app's copies.
- The guarantee covers styles that `MobDev.Style.activated/0` resolved and
  loaded. An activated name that isn't a dep, or whose manifest fails to
  evaluate, is still skipped there (pre-existing behaviour), so it ships no
  fonts and raises nothing here.
