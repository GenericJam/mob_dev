# iOS release links dead-strip like the dev links; plugin archives get a no-dead-strip link check
- Date: 2026-10-13
- Status: accepted
- Issue: MOB-471 (found by MOB-470)

## Context

mob_new's `ios/build.zig` and `ios/build_device.zig` (every
`mix mob.deploy --native --ios`) link with `-Xlinker -dead_strip`;
`release_device.sh` (`mix mob.release --ios`) did not. ld64 reports an
undefined symbol only from code that survives dead-stripping, so a reference
in code the app never reaches linked on every dev build and failed only the
release. mob_whisper 0.1.1 shipped that way: ggml-backend-reg.cpp's `dl_*`
helpers were declared but their source (`ggml-backend-dl.cpp`) was not in
the manifest (MOB-470). Users would meet it at App Store time.

The two ways to make the paths agree:

1. Drop `-dead_strip` from the dev links: the same failure everywhere, but
   the dev binaries grow, the dev and release builds still differ from what
   ships, and Mob's slim-build flags (`-ffunction-sections -fdata-sections`,
   `guides/slim_release.md`) exist to be dead-stripped.
2. Add `-dead_strip` to the release link: smaller `.ipa`, but it hides the
   bug class on both paths.

## Decision

Both paths dead-strip, and the bug class is caught by a separate check that
runs on every path, before any link.

- `release_device.sh` passes `-Xlinker -dead_strip` to the final `swiftc`
  link, as the dev links do. `release_script_test.exs` asserts the release
  script and both mob_new templates agree on the flag.
- `MobDev.Plugin.IosLinkCheck.check/5` runs on every `cpp_archive` plugin
  archive built for `:ios_sim` or `:ios_device`
  (`NativeBuild.build_plugin_static_archives/4`, which the simulator build,
  the device build and `mix mob.release --ios` all call). It links the
  archive into a throwaway dylib without `-dead_strip` (`-force_load` of the
  plugin's own `lib<module>.a`; its prebuilt archives contribute what those
  members pull in, as in the app link) with `-undefined dynamic_lookup`, and
  lists what stayed unresolved. Each of those must be defined by something
  the app's link supplies:
  - the BEAM: symbols the target's ERTS static libraries define
    (`<otp>/erts-*/lib/*.a`, `lib/internal/*.a`), which covers `enif_*`;
  - mob core: the external functions, globals and `@implementation` classes
    in `<mob_dir>/ios/*.{m,mm,c}` (e.g. `mob_register_permission_handler`),
    found by a text scan because `mob_nif.m` imports a Swift header only the
    full build generates;
  - the iOS SDK: names exported by any `.tbd` stub of the target SDK.

  Anything else fails the build, naming the plugin, the symbols and the
  archive members that reference them. On mob_whisper 0.1.1 it reports
  `dl_get_sym`, `dl_load_library` and `dl_error` from
  `ggml-backend-reg.o`.

The allow-list is derived from those inputs rather than written down. The
SDK is in it whole, not just the frameworks a manifest names, because the
app also links frameworks through clang module autolinking from mob core:
mob_scene3d's prebuilt Filament references OpenGL ES, which no manifest
declares and which the app gets that way.

## Consequences

- A `mix mob.release --ios` binary keeps what a dev build keeps. A blank
  host with the default plugins plus mob_whisper 0.1.2 and mob_scene3d 0.2.0
  (2026-10-13): the app binary in the `.ipa` went from 14,437,328 to
  12,631,520 bytes (−12.5 %), the `.ipa` from 54,319,714 to 53,581,889 bytes.
- Every iOS build with a `cpp_archive` plugin does one extra link and a scan
  of the SDK's `.tbd` files per plugin: about 0.5 s each for mob_whisper and
  mob_scene3d on the Mac mini.
- Not covered: plugin C/ObjC NIFs (`lang: :c` / `:objc`) and project NIFs,
  which are compiled straight into the app link rather than into an archive
  on this path; a symbol one plugin's archive expects another plugin to
  define (none do today); and a framework symbol the app doesn't link (the
  check accepts any SDK export; the real link still fails on a live one).
- `-undefined dynamic_lookup` is deprecated on iOS (ld prints a warning,
  captured with the probe's output). If a future ld drops it, the check fails
  loudly with the link output rather than passing.
