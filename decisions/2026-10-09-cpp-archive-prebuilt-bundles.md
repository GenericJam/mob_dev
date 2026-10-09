# cpp_archive prebuilt bundles: plugins link third-party static libraries

- Date: 2026-10-09
- Status: accepted
- Issue: MOB-427 (mob_scene3d did not build into a blank iOS host)

## Context

mob_scene3d's iOS renderer, `MobScene3dView.mm`, is Objective-C++ against
Filament, which ships as a release tarball of headers plus one static-library
xcframework per component (about 30 MB compressed). The plugin manifest had no
way to say "compile this ObjC++ file against these headers and link these
prebuilt archives", so the plugin listed it as a host requirement: hand-edit
`ios/build.zig` and `ios/build_device.zig` to add an ObjC++ step and the
Filament archives, and import the plugin's headers into the bridging header. A
user who activated the plugin as documented got
`cannot find type 'MobScene3dView'` from swiftc, and mob_ci's iOS cells failed.

What the build already had:

- `lang: :cpp_archive` (`MobDev.Plugin.CppArchive`) compiles a plugin's sources,
  `.mm` included, into `lib<module>.a` with the plugin's flags and includes,
  and `-Dplugin_static_libs` / `MOB_PLUGIN_STATIC_LIBS` link every path it
  returns on the simulator, device and `mix mob.release --ios` link lines.
- Nothing fetched or linked a prebuilt library for a plugin. Prebuilts mob_dev
  downloads (MLX, TFLite, Python) each have their own downloader and bespoke
  zig flags.

## Decision

- A cpp_archive entry may declare `prebuilt: %{url, sha256, static_libs}`.
  `MobDev.Plugin.Prebuilt` downloads the tarball once per hash into
  `~/.mob/cache/plugin-prebuilt/` (`MOB_CACHE_DIR` honoured), refuses it unless
  it hashes to `sha256`, and extracts it. `{:prebuilt, subpath}` in
  `:includes` becomes a `-I` into the bundle; `static_libs` maps each
  CppArchive target to archives inside it, which
  `build_plugin_static_archives/3` returns right after the plugin's own
  `lib<module>.a`. They ride the existing `plugin_static_libs` inputs, so no
  host `build.zig` changes, and every app generated since those inputs exist
  links them.
- The hash is required and validated (64 lowercase hex), and the URL must be
  https. The plugin signature covers the manifest but cannot cover a download,
  so the pin is what carries the signature's trust to the bundle.
- `.m` sources in a cpp_archive go to the C driver with `:cflags*`, like `.c`.
  `clang++` compiles `.m` as Objective-C and rejects `-std=gnu++17` for it, so
  an ObjC NIF could not share an archive with an ObjC++ renderer.
- One generic mechanism instead of a Filament downloader: the plugin owns the
  version, URL and file list, so a Filament bump is a plugin release and the
  next plugin with a prebuilt dependency needs no mob_dev change.

mob_scene3d's side (its own PR): the NIF and the renderer are one iOS
cpp_archive; the Swift view creates `MobScene3dView` by class name, so the
host bridging header no longer needs the plugin's headers; the NIF calls into
the renderer at load, which keeps the renderer's object in the link (a static
archive member nothing references is not linked, and a class looked up by name
is no reference).

## Consequences

- An older mob_dev ignores `prebuilt:` and fails to compile the renderer for
  want of the Filament headers. mob_scene3d declares
  `{:mob_dev, "~> 0.7.20", optional: true}`: an optional dependency adds
  nothing to a host, but a host that has mob_dev (every Mob app) must resolve a
  version that satisfies it.
- Bundle archives link after OTP's. ld64 takes the first archive that defines
  an undefined symbol, so where both ship a library (Filament and OTP each have
  `libzstd.a`) OTP's members win and Filament's only fill gaps; this is how the
  hand-wired spike linked too.
- The whole tarball is fetched even when a target needs only some of it, once
  per machine and hash.
- Verified on a blank `mix mob.new --blank` host (mob_new 0.6.7): simulator
  deploy (iOS 27, iPhone 17) and physical deploy (iPhone SE 3rd gen) render a
  glTF model and pass `mix mob.selftest`; `mix mob.release --ios` builds an
  `.ipa` whose binary defines `_OBJC_CLASS_$_MobScene3dView`; the Android
  emulator build is unchanged and passes the self-test.
