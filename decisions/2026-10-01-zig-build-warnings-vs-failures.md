# Native `zig build`: warnings stop looking like failures, failures name the plugin
- Date: 2026-10-01
- Status: accepted

## Context

MOB-344: an iOS-simulator native build of mob_plugin_demo printed nine
`failed command: xcrun -sdk iphonesimulator cc ...` blocks for plugin NIF `.m`
compiles, then `✓ iOS native build complete`, and deployed.

None of those compiles failed. Re-run by hand, all nine exit 0 and their
objects export `<module>_nif_init`; the installed app binary exports all nine
init symbols. Each one printed a clang warning — the demo's `ios/build.zig`
predates the mob_new template fix and passes `-DSTATIC_ERLANG_NIF` beside
`-DSTATIC_ERLANG_NIF_LIBNAME`, which `erl_nif.h` redefines
(`-Wmacro-redefined`); mob_camera also uses APIs deprecated in iOS 17. zig's
build runner (0.17.0-dev.269, the pinned version) prints every step that wrote
to stderr in its failure layout: the step tree, a ` w` marker and
`failed command: <argv>`, whether or not the step failed.

A real compile error did fail the deploy, but looked the same as the eight
warnings around it, and the closing line said only
`zig build binary (iOS sim) exited 1`.

## Decision

- Every native `zig build` mob_dev runs (iOS simulator, iOS device, Android
  per-ABI, Zigler NIF cross-compiles) goes through `MobDev.ZigBuild.run/4`.
- It sets `ZIG_BUILD_ERROR_STYLE=minimal` unless the environment already
  sets a style. Minimal is zig's own style that omits the command line and
  step-tree context; warnings print as the step name plus clang's output. An
  environment variable rather than `--error-style` because a zig that doesn't
  know it ignores it.
- Output is still streamed live and captured too. On success, steps zig marked
  ` w` are listed once as "compiler warnings (not failures; the build
  succeeded)".
- On failure the error names each plugin whose NIF source failed — matched by
  the failing step name containing the NIF name, or a compiler diagnostic in
  the NIF source file — with its `error:` and `fatal error:` lines, then any
  other failing step and error. That is what `✗ <platform> native build
  failed:` prints.

## Consequences

- A real failure no longer prints `failed command:`; the failing step name
  and the compiler error remain. To get zig's full context back, set
  `ZIG_BUILD_ERROR_STYLE=verbose`.
- Attribution reads zig's text output (step headers, `error:` lines). If a
  later zig changes that layout, failures still fail on the exit code; only
  the plugin attribution would degrade to the bare exit line.
- The warnings themselves are left to the projects and plugins that emit
  them. A project on an old `ios/build.zig` keeps the macro-redefined warning
  until it drops `-DSTATIC_ERLANG_NIF` from its plugin NIF flags (the mob_new
  template already does).
