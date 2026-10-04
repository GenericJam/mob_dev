# cpp_archive: C sources, unique object names, the x86_64 emulator ABI

- Date: 2026-10-03
- Status: accepted
- Issue: MOB-381 (mob_whisper, the first cpp_archive plugin that isn't Eigen)

## Context

`MobDev.Plugin.CppArchive` was written for NxEigen: a handful of `.cpp` files
compiled by `clang++`, for arm64/armv7 Android and iOS. whisper.cpp's ggml broke
three of its assumptions at once:

1. ggml mixes C and C++. Its `.c` files (`ggml.c`, `ggml-quants.c`,
   `ggml-cpu.c`, …) are not valid C++ (implicit `void *` conversions, C99
   designated initialisers out of order), and `clang++` compiles `.c` as C++.
2. ggml has same-named sources in different directories
   (`ggml-cpu/quants.c` and `ggml-cpu/arch/arm/quants.c`, likewise
   `repack.cpp`). Objects were named `<basename>.o`, so the second overwrote
   the first and its symbols vanished from the archive without an error until
   link time.
3. `native_build.ex` builds every Android ABI (arm64, armv7, x86_64) on every
   `--native` deploy, and an active cpp_archive plugin hard-failed the whole
   build on x86_64 ("no target for this ABI"). That was safe while the only
   cpp_archive plugin was opt-in Nx tooling; a speech plugin in a normal app
   would make every Android build fail.

## Decision

- `.c` sources go to the target's C driver (`clang`, Android
  `<triple><api>-clang`) with new `:cflags` / `:cflags_android` / `:cflags_ios`
  manifest keys; every other extension stays on `clang++` (which picks C++ or
  Objective-C++ by extension). The forced `-fPIC`, target ABI flags and `-I`
  includes apply to both. Separate flag lists, rather than reusing CXXFLAGS,
  because C++-only flags (`-std=c++17`) are errors for the C driver.
- Objects are named `<basename>-<first 8 hex of sha256(source path)>.o`:
  stable across builds, unique per path.
- `:android_x86_64` is a CppArchive target (`x86_64-linux-android28-clang++`).
  The hard-error path for "plugin active on an ABI CppArchive can't build"
  (`cpp_archive_target_decision/2`, `unsupported_cpp_archive_target_error/2`)
  is removed: every ABI the Android build produces now maps to a target, so it
  was unreachable. A plugin whose sources are architecture-specific has to pick
  per target in the source (mob_whisper's `ggml_arch_*.c[pp]` wrappers
  `#include` the ARM or x86 kernels by `__aarch64__`/`__x86_64__`), since one
  source list serves all Android ABIs.
- One `:cxxflags_android` list serves every Android ABI, and some Android
  hardening is Arm-only: clang rejects `-mbranch-protection=` for x86_64
  (mob_nx_eigen sets it). The builder drops `-mbranch-protection=*` on
  `:android_x86_64` rather than adding per-ABI flag keys: the flag has no x86
  meaning, and per-ABI keys would make every plugin author track ABIs.
- Sources compile in parallel (`Task.async_stream`, one per scheduler, results
  in source order); a 30-file archive builds in ~5 s per ABI instead of ~30 s.

## Consequences

- mob_nx_eigen's archive now also builds for x86_64 (checked: the cpp_archive
  build of its manifest succeeds for `:android_x86_64`); it isn't run on an
  emulator.
- There's still no incremental cache: every `--native` deploy rebuilds every
  cpp_archive for every ABI (~15 s for mob_whisper's three Android ABIs).
