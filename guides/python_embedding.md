# Embedded CPython

`mix mob.enable python` adds [Pythonx](https://hex.pm/packages/pythonx)
support to a Mob app and bundles a real CPython interpreter into the
iOS app artifact. Once enabled you can call `Pythonx.eval/2` from BEAM
to run Python code that ships inside the app, no network, no
sandbox-escape required.

This guide is the contract between what Mob owns and what it doesn't.
Read the **scope** section before deciding to use it.

---

## Scope

Mob's Python support is deliberately narrow.

**In scope (Mob owns this):**

- A working CPython interpreter on iOS device + iOS simulator
- The Python standard library (the pure-Python bits)
- Standard arch-specific C extensions: `_ssl`, `_ctypes`, `_hashlib`,
  `_socket`, `_md5`, `_sha*`, `_decimal`, `_ctypes_test`, …
  (~68 extensions ship in BeeWare's bundle)
- Build pipeline: cross-compiling `libpythonx.so`, bundling
  `Python.framework`, codesigning every dylib bottom-up before the
  final `.app` sign

**Out of scope (Mob does not own this):**

- **Android.** Python on Android needs a totally different toolchain
  (Chaquopy or python-for-android), neither compatible with iOS's
  BeeWare bundle. If your app runs on both platforms, your
  `Pythonx.eval` calls will only succeed on iOS — guard with
  `Mob.platform/0` accordingly. Android Python may land later but
  is not on the roadmap.
- **Third-party wheels.** Anything beyond the standard library —
  `cryptography`, `numpy`, `RNS`, etc. — requires a cross-compiled
  wheel for iOS. [BeeWare's `mobile-forge`](https://github.com/beeware/mobile-forge)
  ships some pre-built; for anything else you build the wheel
  yourself and drop it into your project. Mob does not manage a
  wheel registry, does not know what wheels are compatible, and
  does not field bug reports about specific Python packages
  failing to import.
- **iOS App Store review for Python apps.** The Mob iOS template
  passes review for vanilla apps; CPython embedding adds dynamic
  libraries Apple's reviewers may flag. We've validated dev signing
  on physical devices; an actual TestFlight upload of a
  Pythonx-enabled app hasn't been smoke-tested by the Mob team yet.

If you need wheels or Android Python, that's fine — you just can't
expect Mob to be the place that solves it for you.

---

## Quick start

### From scratch

```bash
mix mob.new my_app --ios --python
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

The first `mob.deploy --native` downloads BeeWare's
`Python-Apple-support` bundle (~70 MB) into `~/.mob/cache/` and
caches it across projects.

---

## Wiring it up

`mix mob.enable python` writes `lib/<app>/python_paths.ex` — a pure
detection module — and patches `config/config.exs` so the desktop
`uv_init` path is gated on `MOB_TARGET=ios`. You still need to wire
`Pythonx.init/4` into your app's `on_start/0` for the iOS branch.
The recipe:

```elixir
defmodule MyApp.App do
  use Mob.App

  @impl Mob.App
  def navigation(_platform), do: stack(:main, root: MyApp.HomeScreen)

  @impl Mob.App
  def on_start do
    {:ok, _} = Application.ensure_all_started(:pythonx)

    # On iOS, Pythonx.Application's auto-init via uv doesn't work
    # (no uv on device, no internet at compile time). Initialize
    # against the bundled framework manually.
    case MyApp.PythonPaths.detect(to_string(:code.root_dir())) do
      :desktop ->
        # Pythonx already auto-init'd via uv (config.exs).
        :ok

      {:ios, %{dl_path: dl, home_path: home}} ->
        # iOS device or simulator — bundle is at <App>.app/otp/python/.
        Pythonx.init(dl, home, dl, sys_paths: [])

      {:partial, missing} ->
        # The directory exists but artifacts are missing. Means the
        # build pipeline broke somewhere between cross-compile and
        # bundling. Surface this to the user — don't let the screen
        # try to call into a half-initialized interpreter.
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
during `mix mob.deploy --native`. It dlopens `Python.framework/Python`
at runtime when `Pythonx.init/4` is called.

`mix mob.deploy --native` orchestrates this:

| Step | Module |
|---|---|
| Download + cache BeeWare bundle | `MobDev.PythonAppleSupport.ensure/0` |
| Detect Pythonx in user's project | `MobDev.NativeBuild.pythonx_in_project?/1` |
| Generate `ios/build_device.sh` (with Pythonx blocks) | `MobDev.NativeBuild.generate_build_device_sh/2` |
| Cross-compile `libpythonx.so` | `xcrun -sdk iphoneos clang++` (in script) |
| Bundle framework + stdlib + lib-dynload | `cp -R` into `<otp_root>/python/` (in script) |
| Codesign every dylib bottom-up | `codesign` per `.so` + framework binary (in script) |
| Sign the `.app` | final `codesign` (in script) |

The build script's Pythonx work is gated on
`if [ -d "_build/dev/lib/pythonx" ]` — so projects that have never
run `mix mob.enable python` see the gate as a no-op and pay no
overhead.

---

## Bundle size

The Python bundle adds **~67–70 MB** to your `.app`:

| Piece | Size |
|---|---|
| `Python.framework/Python` (libpython + libssl + libcrypto) | ~5.2 MB |
| Python stdlib | ~61 MB |
| 68 lib-dynload extensions | ~3 MB |
| `libpythonx.so` | ~150 KB |

This is one-time, not per-feature. If your app already ships Python
support, adding more Python code (your own `.py` files, additional
imports from stdlib) doesn't grow the bundle further.

A vanilla Mob app (no Python) is ~3 MB. Adding Python takes you to
~70 MB — apply this only when you actually want to call Python from
BEAM.

---

## When not to use this

- **You only want one or two pure functions implemented in Python.**
  Port them. The bundle cost dwarfs the productivity win for small
  uses.
- **You want a Python web framework or async runtime.** BEAM is the
  better runtime for that on Mob — Phoenix is a dep away.
- **You want Python on Android too.** Out of scope. Pick a different
  approach (or land Android support upstream).
- **You're targeting App Store distribution and your timeline is
  tight.** We've validated dev signing on physical devices; App
  Store review of a CPython-bundled app is unproven by the Mob
  team. Budget time for unknown rejection categories.

---

## Going further: third-party wheels

If you need a Python package beyond stdlib (the original push for
this feature was Reticulum, which depends on `cryptography`):

1. Use [BeeWare's `mobile-forge`](https://github.com/beeware/mobile-forge)
   to cross-compile the wheel for iOS. Some wheels are pre-built;
   for others you'll need to set up the forge yourself.
2. Place the wheel in your project at `priv/python_wheels/<name>.whl`.
3. Patch your `mix mob.deploy --native` flow to extract the wheel
   into `<App>.app/otp/python/lib/python3.13/site-packages/` and
   codesign any `.so` files inside it before the final app sign.

Mob does not currently script step 3. You'll need to maintain a
post-`mob.deploy --native` patch step in your project (a shell
script, a custom mix task, or a fork of `MobDev.NativeBuild`) that
handles the wheels you need. Each wheel is its own per-platform
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
The arch-specific `lib-dynload/` wasn't bundled. Check that
`<App>.app/otp/python/lib/python3.13/lib-dynload/` exists in your
build output — `mix mob.deploy --native` should print
`lib-dynload:  68 extensions` during the bundling step.

**Build fails with `pythonx in deps but PYTHON_APPLE_SUPPORT not set`.**
You ran `bash ios/build_device.sh` directly. Use `mix mob.deploy
--native` instead — it calls `MobDev.PythonAppleSupport.ensure/0` to
download the BeeWare bundle and exposes the path to the script.

**Codesign failure on `libpythonx.so` or a lib-dynload `.so`.** Likely
your signing identity doesn't match the team in your provisioning
profile. `mix mob.doctor` flags this; otherwise, regenerate
provisioning via `mix mob.provision`.
