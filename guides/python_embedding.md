# Embedded CPython

`mix mob.enable python` adds [Pythonx](https://hex.pm/packages/pythonx)
support to a Mob app and bundles a real CPython interpreter into both
the iOS and Android app artifacts. Once enabled you can call
`Pythonx.eval/2` from BEAM to run Python code that ships inside the
app — no network, no sandbox-escape required, same API on either
platform.

This guide is the contract between what Mob owns and what it doesn't.
Read the **scope** section before deciding to use it.

---

## Scope

Mob's Python support is deliberately narrow.

**In scope (Mob owns this):**

- A working CPython 3.13 interpreter on:
  - iOS device + iOS simulator (BeeWare's
    [`Python-Apple-support`](https://github.com/beeware/Python-Apple-support))
  - Android arm64 emulator + arm64 device ([Chaquopy](https://chaquo.com/chaquopy/)'s
    prebuilt distribution)
- The Python standard library (the pure-Python bits)
- Standard arch-specific C extensions: `_ssl`, `_ctypes`, `_hashlib`,
  `_socket`, `_md5`, `_sha*`, `_decimal`, `_ctypes_test`, …
- Build pipeline: cross-compiling `libpythonx.so` (the Pythonx NIF)
  for each target, bundling the interpreter + stdlib + dynload
  extensions, codesigning on iOS, asset extraction on Android first
  launch.

**Out of scope (Mob does not own this):**

- **Third-party wheels.** Anything beyond the standard library —
  `cryptography`, `numpy`, `RNS`, etc. — requires a cross-compiled
  wheel for the right target.
  - iOS: [BeeWare's `mobile-forge`](https://github.com/beeware/mobile-forge)
    ships some pre-built; for anything else you build the wheel
    yourself.
  - Android: Chaquopy has its own wheel pipeline (see
    [Chaquopy's docs on package compatibility](https://chaquo.com/chaquopy/doc/current/android.html)).

  Mob does not manage a wheel registry, does not know what wheels are
  compatible, and does not field bug reports about specific Python
  packages failing to import.
- **Android x86/x86_64.** The Android pipeline is wired for
  `arm64-v8a` only. Most modern devices and the default Android
  Studio emulator are arm64; if you specifically need to run on a
  legacy x86 emulator you'll need to extend the build yourself.
- **App Store / Play Store review for Python apps.** The Mob
  templates pass review for vanilla apps; CPython embedding adds
  dynamic libraries store reviewers may flag. We've validated dev
  signing on physical devices on both platforms; an actual
  TestFlight or Play Console upload of a Pythonx-enabled app hasn't
  been smoke-tested by the Mob team yet.

If you need wheels or non-arm64 Android, that's fine — you just can't
expect Mob to be the place that solves it for you.

---

## Quick start

### From scratch

```bash
mix mob.new my_app --python
cd my_app
mix mob.deploy --native --device <udid>
```

### In an existing project

```bash
cd my_app
mix mob.enable python
mix deps.get
mix mob.deploy --native --device <udid>
```

The first `mob.deploy --native` downloads the per-platform CPython
distribution into `~/.mob/cache/` and reuses it across projects:

| Platform | Source | Cache key |
|---|---|---|
| iOS | BeeWare's `Python-Apple-support` (~70 MB) | `python-apple-support-<vsn>/` |
| Android | Chaquopy prebuilts (~30 MB after pruning) | `python-android-support-<vsn>/` |

`mix mob.enable python` runs a freshness check on existing projects
and warns if `ios/build.sh`, `android/.../CMakeLists.txt`, or
`MainActivity.kt` are missing the build-time hooks the deploy
expects. If you see that warning, regenerate from the latest
`mob_new` archive or copy the bracketed regions across.

---

## Wiring it up

`mix mob.enable python` writes:

- `lib/<app>/python_paths.ex` — a pure detection module that returns
  `:desktop` / `{:ios, paths}` / `{:android, paths}` /
  `{:partial, missing}` based on what artifacts it finds at runtime.
- A `:pythonx, :uv_init` block in `config/config.exs`. The same
  config lands at compile and runtime, so Pythonx's
  `validate_compile_env` check is satisfied unconditionally — no
  env-var gate.

You still need to wire `Pythonx.init/4` into your app's `on_start/0`
for the mobile branches. The recipe:

```elixir
defmodule MyApp.App do
  use Mob.App

  @impl Mob.App
  def navigation(_platform), do: stack(:main, root: MyApp.HomeScreen)

  @impl Mob.App
  def on_start do
    case MyApp.PythonPaths.detect(to_string(:code.root_dir())) do
      :desktop ->
        # Desktop: uv handles venv setup at app start. This is the
        # only branch that calls ensure_all_started — on device,
        # `Pythonx.UvInit.init/1` would shell out to `uv` and fail.
        {:ok, _} = Application.ensure_all_started(:pythonx)

      {:ios, %{dl_path: dl, home_path: home}} ->
        # iOS: bundle is at <App>.app/otp/python/. Pythonx.init/4
        # loads the NIF directly against the bundled framework.
        Pythonx.init(dl, home, dl, sys_paths: [])

      {:android, %{dl_path: dl, home_path: home}} ->
        # Android: MainActivity has unpacked Chaquopy's distribution
        # to filesDir/python/ and exported MOB_PYTHON_HOME +
        # MOB_PYTHON_DL before BEAM startup. Add stdlib explicitly
        # because Chaquopy's layout doesn't auto-resolve it.
        Pythonx.init(dl, home, dl,
          sys_paths: [Path.join([home, "lib", "python3.13"])])

      {:partial, missing} ->
        # The directory exists but artifacts are missing. Means the
        # build pipeline broke between cross-compile and bundling.
        # Surface this — don't let the screen try to call into a
        # half-initialized interpreter.
        Logger.error("Python bundle incomplete; missing: #{inspect(missing)}")
    end

    Mob.Screen.start_root(MyApp.HomeScreen)
  end
end
```

After `Pythonx.init/4` returns, `Pythonx.eval/2` is callable from any
screen. A minimal HomeScreen that proves the interpreter works:

```elixir
defmodule MyApp.HomeScreen do
  use Mob.Screen

  def mount(_params, _session, socket) do
    version =
      try do
        {result, _} = Pythonx.eval("import sys; sys.version", %{})
        Pythonx.decode(result) |> to_string() |> String.split("\n", parts: 2) |> hd()
      rescue
        e -> "eval failed: " <> Exception.message(e)
      end

    {:ok, Mob.Socket.assign(socket, :python_version, version)}
  end

  def render(assigns) do
    ~MOB"""
    <Column padding={:space_lg}>
      <Label text={"Python: " <> @python_version} />
    </Column>
    """
  end
end
```

---

## How it works

### iOS

Three pieces ship in your `<App>.app` bundle:

1. **`<App>.app/otp/python/Python.framework/Python`** — the CPython
   interpreter binary (a Mach-O dylib with libpython statically
   linked, plus libssl/libcrypto for `_ssl` / `_hashlib`).
2. **`<App>.app/otp/python/lib/python3.13/`** — the pure-Python
   standard library (`os.py`, `urllib/`, `email/`, …) following the
   `PYTHONHOME` contract.
3. **`<App>.app/otp/python/lib/python3.13/lib-dynload/*.so`** —
   arch-specific compiled C extensions, codesigned individually with
   your dev/distribution identity.

The fourth piece — **`<App>.app/otp/lib/pythonx-VSN/priv/libpythonx.so`** —
is the Pythonx NIF, cross-compiled for iphoneos/iphonesimulator arm64
during `mix mob.deploy --native`. It dlopens
`Python.framework/Python` at runtime when `Pythonx.init/4` is called.

`mix mob.deploy --native` orchestrates this:

| Step | Module |
|---|---|
| Download + cache BeeWare bundle | `MobDev.PythonAppleSupport.ensure/0` |
| Detect Pythonx in user's project | `MobDev.NativeBuild.pythonx_in_project?/1` |
| Generate `ios/build_device.sh` (with Pythonx blocks) | `MobDev.NativeBuild.generate_build_device_sh/2` |
| Cross-compile `libpythonx.so` | `xcrun -sdk iphoneos clang++` (in script) |
| Generate `enif_keepalive.c` (174 enif_* refs) | `MobDev.NativeBuild.generate_ios_enif_keepalive/2` |
| Bundle framework + stdlib + lib-dynload | `cp -R` into `<otp_root>/python/` (in script) |
| Codesign every dylib bottom-up | `codesign` per `.so` + framework binary (in script) |
| Sign the `.app` | final `codesign` (in script) |

### Android

Three pieces ship in your APK:

1. **`jniLibs/arm64-v8a/libpython3.13.so`** + **`libpythonx.so`** —
   the CPython interpreter and the Pythonx NIF, packaged into the
   APK's native lib directory. Android's installer auto-extracts to
   the app's `nativeLibraryDir`. `libpythonx.so` was cross-compiled
   with the NDK against a stub `libpython3.13.so` carrying the right
   SONAME, so the dynamic loader's `NEEDED` entry resolves at
   runtime.
2. **`assets/python/lib/python3.13/`** — the stdlib, packed into the
   APK as assets. `MainActivity.extractPythonAssetsIfNeeded()`
   unpacks to `filesDir/python/lib/python3.13/` on first launch
   (idempotent via a `.extracted` marker).
3. **`assets/python/lib/python3.13/lib-dynload/<abi>/*.so`** —
   arch-specific C extensions. Chaquopy ships them per-abi;
   `MainActivity.flattenLibDynload()` picks the device's primary ABI
   and moves the files up to `lib-dynload/` to match CPython's
   expected flat layout.

`MainActivity.onCreate` exports `MOB_PYTHON_DL` (path to
`libpython3.13.so` in `nativeLibraryDir`) and `MOB_PYTHON_HOME` (path
to the extracted stdlib root) before calling `nativeStartBeam`. The
`<App>.PythonPaths.build_android_paths/0` function reads those vars
back and feeds them to `Pythonx.init/4`.

| Step | Module |
|---|---|
| Download + cache Chaquopy distribution | `MobDev.PythonAndroidSupport.ensure/0` |
| Detect Pythonx in user's project | `MobDev.NativeBuild.pythonx_in_project?/1` |
| Build stub `libpython3.13.so` for cross-link | `MobDev.NativeBuild.build_libpython_android_test_stub_so/1` |
| Cross-compile `libpythonx.so` (NDK) | `aarch64-linux-android28-clang++` |
| Generate `enif_keepalive.c` (NDK llvm-nm scan) | `MobDev.NativeBuild.generate_android_enif_keepalive/2` |
| Install Pythonx as OTP lib (mirrors exqlite) | `MobDev.NativeBuild.install_pythonx_otp_lib_android/2` |
| Bundle stdlib + lib-dynload as assets | `MobDev.NativeBuild.bundle_python_android_assets/2` |
| Symlink Pythonx NIF into nativeLibraryDir | `mob_beam.c` (at app launch) |

The build script's Pythonx work is gated on
`if [ -d "_build/dev/lib/pythonx" ]` — projects that have never run
`mix mob.enable python` see the gate as a no-op and pay no overhead.

---

## Bundle size

| Piece | iOS | Android |
|---|---|---|
| Interpreter binary | ~5.2 MB (`Python.framework/Python`) | ~6 MB (`libpython3.13.so`) |
| Stdlib | ~61 MB | ~22 MB (Chaquopy ships pyc-only) |
| C extensions (lib-dynload) | ~3 MB (68 extensions) | ~2 MB (per-arch only) |
| `libpythonx.so` (Pythonx NIF) | ~150 KB | ~150 KB |
| **Total Python overhead** | **~70 MB** | **~30 MB** |

This is one-time, not per-feature. If your app already ships Python,
adding more Python code (your own `.py` files, additional imports
from stdlib) doesn't grow the bundle further.

A vanilla Mob app (no Python) is ~3 MB. Apply this only when you
actually want to call Python from BEAM.

---

## When not to use this

- **You only want one or two pure functions implemented in Python.**
  Port them. The bundle cost dwarfs the productivity win for small
  uses.
- **You want a Python web framework or async runtime.** BEAM is the
  better runtime for that on Mob — Phoenix is a dep away.
- **You're targeting App Store / Play Store distribution and your
  timeline is tight.** We've validated dev signing on physical
  devices; store review of a CPython-bundled app is unproven by the
  Mob team. Budget time for unknown rejection categories.

---

## Going further: third-party wheels

If you need a Python package beyond stdlib (the original push for
this feature was Reticulum, which depends on `cryptography`):

**iOS**

1. Use [BeeWare's `mobile-forge`](https://github.com/beeware/mobile-forge)
   to cross-compile the wheel for iOS.
2. Place the wheel in your project at `priv/python_wheels/<name>.whl`.
3. Patch your `mix mob.deploy --native` flow to extract the wheel
   into `<App>.app/otp/python/lib/python3.13/site-packages/` and
   codesign any `.so` files inside it before the final app sign.

**Android**

1. Build the wheel via Chaquopy's own pipeline, or grab a prebuilt
   one from their package index.
2. Place the wheel at `priv/python_wheels/<name>.whl`.
3. Extract into `assets/python/lib/python3.13/site-packages/` (so it
   gets bundled at build time and unpacked by
   `extractPythonAssetsIfNeeded`).

Mob does not currently script step 3 on either platform. You'll need
to maintain a post-`mob.deploy --native` patch step in your project
that handles the wheels you need. Each wheel is its own per-platform
compatibility problem; Mob explicitly does not own that surface.

If you find yourself building this for your own project and it
generalizes well, please share your approach upstream — we may
revisit the scope decision if there's a clean abstraction that
doesn't lock Mob into wheel ecosystem maintenance.

---

## Troubleshooting

**App crashes silently on launch with no Python output.** First check
for OTP version mismatch — your local Erlang must match the device
runtime's ERTS (currently OTP 29 / erts-17.0). `mise` reads
`.tool-versions`; if `mise current` disagrees with `mise exec -- erl`,
your shell hasn't picked up the project's pinned version.

**`Pythonx.eval` raises `ModuleNotFoundError: No module named '_ctypes'`.**

- *iOS:* the arch-specific `lib-dynload/` wasn't bundled. Check that
  `<App>.app/otp/python/lib/python3.13/lib-dynload/` exists in your
  build output — `mix mob.deploy --native` should print
  `lib-dynload:  68 extensions` during the bundling step.
- *Android:* `flattenLibDynload` didn't run, or the device's primary
  ABI didn't match what was bundled. Check
  `filesDir/python/lib/python3.13/lib-dynload/` after first launch
  and confirm `_ctypes.cpython-313.so` is present (flat, not nested
  under `arm64-v8a/`).

**Python `Failed to import encodings`.** The stdlib path doesn't
match `PYTHONHOME`'s `lib/python3.13/` expectation. On Android, the
extracted assets must land at `filesDir/python/lib/python3.13/`
(*not* `filesDir/python/stdlib/`); the `MainActivity` template ships
the right layout — if you patched it, double-check.

**Build fails with `pythonx in deps but PYTHON_APPLE_SUPPORT not
set`.** You ran `bash ios/build_device.sh` directly. Use
`mix mob.deploy --native` instead — it calls
`MobDev.PythonAppleSupport.ensure/0` to download the BeeWare bundle
and exposes the path to the script.

**Android `dlopen` fails with `library "libpython3.13.so" not
found`.** The Pythonx NIF's `NEEDED` entry isn't resolving at
runtime. This usually means `libpython3.13.so` didn't get packaged
into `jniLibs/arm64-v8a/`. Check the APK with
`unzip -l build/outputs/apk/debug/app-debug.apk | grep libpython`.

**Codesign failure on `libpythonx.so` or a lib-dynload `.so` (iOS).**
Likely your signing identity doesn't match the team in your
provisioning profile. `mix mob.doctor` flags this; otherwise,
regenerate provisioning via `mix mob.provision`.

**Compile-env mismatch error: `the application :pythonx has a
different value set for key :uv_init during runtime compared to
compile time`.** Old projects had a `MOB_TARGET=ios`-gated
`:uv_init` block in `config/config.exs`. Mob no longer uses a gate —
delete the `if System.get_env("MOB_TARGET") in [nil, ""] do`
wrapper and leave the `config :pythonx, :uv_init, ...` block at
top level. The mobile-vs-desktop split lives in `on_start/0` now
(the desktop branch calls `Application.ensure_all_started(:pythonx)`,
mobile branches don't).
