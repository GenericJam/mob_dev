# Warn (don't fail) on build vs device-runtime Elixir minor-version skew

- Date: 2026-05-26
- Status: accepted

## Context
`.tool-versions` pinned Elixir 1.20.0-rc.5, but the device OTP tarball shipped
1.19.5. `x in list` compiles to `Enum.__in__/2` under 1.20, which 1.19.5 lacks,
so `Ecto.Migrator` hit `:undef` at boot — a black screen with no error message.
It cost hours to trace because nothing surfaced the mismatch; the build happily
produced an artifact that couldn't run. `mob_dev` already knows both versions at
build time: `System.version()` (the compiling Elixir) and the `elixir.app` vsn
inside the cached OTP tarball.

## Decision
At OTP-dir resolution (`OtpDownloader.ensure/3`), compare the two at
**major.minor** granularity and print a loud stderr warning on mismatch —
**warn, not fail**. The pure comparison (`elixir_skew/2`) and the tarball reader
(`bundled_elixir_version/1`) are public + tested. rc/patch differences within a
minor (1.20.0-rc.5 vs 1.20.0, 1.19.5 vs 1.19.6) are beam-compatible and don't
warn.

## Consequences
- The black-screen class of failure now announces itself in one build line.
- Warn over fail is deliberate: rc/patch toolchain transitions are routine and a
  hard fail would block legitimate builds; the cost is that a warning can be
  scrolled past (acceptable vs. blocking).
- Fires on every build while a skew persists — the nudge to align
  `.tool-versions` with the tarball (or rebuild the tarball).
