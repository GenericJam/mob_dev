# iOS app icons are flattened opaque; Android keeps transparency

- Date: 2026-07-08
- Status: accepted

## Context

App Store upload validation rejects an app whose 1024×1024 marketing icon
carries an alpha channel:

```
ITMS/altool error 90717: Invalid large app icon. The large app icon in the
asset catalog … can't be transparent or contain an alpha channel.
```

`MobDev.IconGenerator.write_ios_icons/2` simply `Image.thumbnail!`'d the source
into each iOS size, so a source PNG with transparency (a very common icon design
— a rounded badge on transparent corners) produced transparent iOS icons and
tripped 90717. The bundled fallback `mob_logo` iOS assets had the same problem.

Android must **not** be flattened: adaptive-icon foreground layers and legacy
launcher icons rely on transparency, and a flat background renders badly on some
launchers/versions. So the fix has to be platform-specific, not a blanket strip.

## Decision

Flatten **iOS only**. `write_ios_icons/3` now runs the source through
`flatten_for_ios/2` before resizing: if the source has an alpha channel it's
composited onto an opaque background via `Image.flatten!/2`; otherwise it's left
untouched. The background colour is the explicit `:background_color` option when
given, else sampled from the source with the same `extract_background_color/1`
the adaptive Android background uses — so the opaque iOS icon and the Android
adaptive background share one colour. `mix mob.icon` threads `--adaptive-bg` to
both platforms.

Android paths (`write_android_icons/2`, `write_adaptive_foregrounds/2`) are
unchanged and keep the source's transparency.

The bundled fallback `mob_logo` iOS-size PNGs (used when the `image` dep is
absent, so they can't be flattened at runtime) were pre-flattened opaque in
`priv/mob_logo/`. iOS and Android icon sizes are disjoint files there, so the
Android-size assets keep their transparency.

## Consequences

- Any mob app that ships a transparent source icon (or the default placeholder)
  now produces an App-Store-valid opaque iOS icon set, while Android keeps its
  adaptive transparency. Verified on Sloppy Joe (rounded-badge icon): the
  rebuilt IPA passed App Store validation and reached TestFlight.
- Tests (`icon_generator_test.exs`): a transparent source yields alpha-free iOS
  icons and alpha-bearing Android icons; an explicit `:background_color` fills
  the flattened icon; an opaque source is left unflattened.
- The iOS icons are full-bleed opaque squares (iOS applies its own corner mask),
  which is the platform-correct treatment — not the rounded-badge-with-margin
  look that suits transparent Android/desktop contexts.
