# iOS release links the project's Swift and NIFs and plugin cpp_archive NIFs

- Date: 2026-10-03
- Status: accepted
- Issue: MOB-373

## Context

After MOB-372 (`2026-10-03-ios-release-compiles-plugin-swift-and-bootstrap.md`),
`mix mob.release --ios` still skipped three build inputs the device build
(`NativeBuild.zig_build_binary_ios_device`) passes to `build_device.zig`:

- the project's own Swift sources (`mob.exs` `project_swift_sources`,
  `-Dproject_swift_sources`);
- the project's own NIFs (`mob.exs` `:static_nifs`, `project_nif_zig_args/1`:
  `c_src/<name>.c`, cross-compiled Rust/Zig staticlibs, `:extra_static_libs`,
  and `-D<module>_static=true` for guarded entries);
- plugin `:cpp_archive` NIFs (`build_plugin_static_archives/3`,
  `-Dplugin_static_libs`).

The release links `priv/generated/driver_tab_ios.c`, which declares every
project NIF's and cpp_archive plugin NIF's `<module>_nif_init`. Verified on
mob_dev 0.7.10 with a fresh app carrying a cpp_archive plugin, a guarded
project C NIF and a project Swift file: the link failed on
`_relcpp_nif_nif_init`, and the guarded NIF's row was compiled out
(`#ifdef MOB_STATIC_RELC_NIF` undefined), so that NIF would have shipped
missing without any error. The project Swift file was simply not compiled.

Separately, the plugin gate's error messages and several moduledocs pointed at
`MOB_PLUGIN_SECURITY.md` / `MOB_PLUGINS.md`, which live in the mob repo and
ship nowhere a mob_dev user can see them.

## Decision

The release computes each input with the device build's own function and
passes it to `release_device.sh` as an env var:

- `NativeBuild.project_swift_sources/1` (the list behind
  `__project_swift_sources_arg__/1`) → `MOB_PROJECT_SWIFT_SOURCES`, compiled in
  the same `swiftc` call as mob's and the plugins' Swift.
- `NativeBuild.project_nif_build_inputs/1`, split out of `project_nif_zig_args/1`
  (which now renders its `-D` args from it) → `MOB_PROJECT_NIF_SOURCES` (through
  the existing NIF compile loop, with `-DSTATIC_ERLANG_NIF_LIBNAME=<name>`),
  `MOB_PROJECT_STATIC_LIBS` (link line) and `MOB_DRIVER_TAB_DEFINES`
  (`-D<guard>` on the driver-table compile, the C-table equivalent of the zig
  build's `-D<module>_static=true`).
- `NativeBuild.build_plugin_static_archives(:ios_device, :ios, otp_root)` →
  `MOB_PLUGIN_STATIC_LIBS` (link line).

`Release.project_release_env/3` maps the three results to env vars (pure,
tested). `build_ipa/1` calls the builders after the OTP download, since the
cpp_archive build needs the device ERTS headers; the Rust/Zig cross-compiles
and archive builds report errors through the same `with` chain as signing.

Docs: the user-facing error and warning strings and the moduledocs now link
the docs' GitHub URLs. Internal code comments keep the bare names.

## Consequences

- An app with project Swift, project C/Rust/Zig NIFs (guarded or not) or
  cpp_archive plugins releases with the same native code as a device build.
- One rule per input: a change to how the device build gathers project NIFs or
  plugin archives changes the release with it.
- Still not in the release path: the MLX / NxEigen / TFLite archives the
  device build adds through `mlx_zig_args/1`, `nxeigen_zig_args_ios/1` and
  `tflite_zig_args_ios/1` (the pre-plugin hooks; their driver-table rows are
  guarded, so a release drops those NIFs rather than failing to link).
- Same word-splitting as the other path lists (see the MOB-372 record).
