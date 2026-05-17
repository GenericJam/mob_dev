defmodule Mix.Tasks.Mob.Enable do
  use Igniter.Mix.Task

  @shortdoc "Enable optional Mob features in this project"

  @moduledoc """
  Enables one or more optional Mob features by patching `mix.exs`, manifest
  files, and generating any required source files.

  ## Usage

      mix mob.enable FEATURE [FEATURE ...]

  Multiple features can be enabled in a single command:

      mix mob.enable camera photo_library
      mix mob.enable camera photo_library file_sharing liveview

  ## Features

  ### `liveview`

  Enables LiveView mode — the Mob app runs a local Phoenix endpoint and displays
  it in a native WebView. Web developers can ship a mobile app with zero native
  UI code.

  What it does:

    - Generates `lib/<app>/mob_screen.ex` — a `Mob.Screen` that opens a WebView
      at `http://127.0.0.1:PORT/`
    - Injects the `MobHook` LiveView hook into `assets/js/app.js`
    - Injects a hidden `<div id="mob-bridge" phx-hook="MobHook">` into
      `root.html.heex` — **this is required for the hook to mount**
    - Updates `mob.exs` with `liveview_port` so `Mob.LiveView.local_url/1` works

  ### Why the hidden div is required

  Phoenix LiveView hooks only execute when a DOM element carrying
  `phx-hook="MobHook"` exists in the rendered page. Registering `MobHook` in
  `app.js` is necessary but not sufficient — without a matching DOM element the
  hook never mounts and `window.mob` is never replaced with the LiveView-backed
  version. Messages would silently route through the native NIF bridge instead
  of the LiveView WebSocket, so `handle_event/3` would never fire.

  See `MobDev.Enable` module doc and `guides/liveview.md` for the full
  two-bridge architecture explanation.

  After running:

    1. Add `MyApp.MobScreen` to your supervision tree (or call
       `Mob.Screen.start_root(MyApp.MobScreen)` from your `Mob.App.on_start/0`)
    2. Ensure Phoenix is running on the port set in `mob.exs` (default: 4000)

  ### `camera`

  Adds camera permission declarations to platform manifests.

  - iOS: adds `NSCameraUsageDescription` to `ios/*/Info.plist`
  - Android: adds `<uses-permission android:name="android.permission.CAMERA"/>`
    to `android/app/src/main/AndroidManifest.xml`

  ### `photo_library`

  - iOS: adds `NSPhotoLibraryAddUsageDescription` to Info.plist
  - Android: no manifest change needed (API 29+)

  ### `file_sharing`

  - iOS: adds `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace`
    to Info.plist
  - Android: adds `<provider android:name="FileProvider">` with paths config

  ### `location`

  - iOS: adds `NSLocationWhenInUseUsageDescription` to Info.plist
  - Android: adds `ACCESS_FINE_LOCATION` permission

  ### `notifications`

  - iOS: creates `ios/<app>.entitlements` with `aps-environment: development`.
    After running, execute `mix mob.provision` so Xcode downloads a push-capable
    provisioning profile. Then call `Mob.Permissions.request(socket, :notifications)`
    and `Mob.Notify.register_push(socket)` at runtime to obtain a device token.
  - Android: runtime only — `POST_NOTIFICATIONS` is requested at runtime, no
    manifest key needed.

  ### `pythonx`

  Enables embedded CPython via [Pythonx](https://hex.pm/packages/pythonx)
  on iOS **and** Android.

  - **iOS:** BeeWare's [`Python-Apple-support`](https://github.com/beeware/Python-Apple-support)
    `Python.xcframework` is bundled by `mix mob.deploy --native`.
  - **Android:** [Chaquopy](https://chaquo.com/chaquopy/)'s prebuilt CPython
    is unpacked at first launch. `libpythonx.so` (the Pythonx NIF) is
    cross-compiled with the Android NDK against a stub `libpython3.13.so`
    so the BEAM dynamic loader is satisfied; the real lib resolves at
    runtime via SONAME match.
  - **Bare CPython only.** Bundles ship the interpreter, stdlib, and
    standard C extensions (`_ssl`, `_ctypes`, `_hashlib`, …). Third-party
    wheels (`cryptography`, `numpy`, `RNS`, …) are out of scope —
    produce your own (BeeWare's [`mobile-forge`](https://github.com/beeware/mobile-forge)
    on iOS, Chaquopy's wheel pipeline on Android) and drop them into
    your project.

  What it does:

    - Adds `{:pythonx, "~> 0.4"}` to `mix.exs` deps.
    - Generates `lib/<app>/python_paths.ex` — pure detection module that
      locates the bundled framework at runtime (`:desktop` /
      `{:ios, paths}` / `{:android, paths}` / `{:partial, missing}`).
    - **No `:uv_init` config patch.** Pythonx ships an Application
      that auto-runs uv at boot if `:uv_init` is in compile-time config,
      and uv doesn't exist on device. Instead the on_start template
      inlines `pyproject_toml` and calls `Pythonx.Uv.fetch/2 +
      Pythonx.Uv.init/2` only on the `:desktop` branch. Same code path
      `iex -S mix` would use, just opt-in.

  Bundle size impact: ~70 MB on iOS, ~30 MB on Android (interpreter +
  stdlib + arch-specific C extensions). Apply this only when you actually
  want to call Python from BEAM — non-Python apps stay vanilla.

  After running, your `Mob.App.on_start/0` should:

    - call `Application.ensure_all_started(:pythonx)` (starts the
      `Pythonx.Janitor`, required for `Pythonx.eval/3`);
    - case-match `<App>.PythonPaths.detect/1` and call `Pythonx.Uv.fetch
      + init` on `:desktop` (provisioning a uv-managed CPython on first
      run) or `Pythonx.init/4` on `{:ios, _}` / `{:android, _}`.

  See `guides/python_embedding.md` for the full template.

  ### `mlx`

  Enables Apple's [MLX](https://github.com/ml-explore/mlx) library + the
  [EMLX](https://hex.pm/packages/emlx) Nx backend on iOS. Gives the app
  fast on-device tensor math (matmul, FFT, linalg, etc.) backed by
  Apple's Accelerate framework (vectorized BLAS/LAPACK).

  - **iOS device + simulator:** `libmlx.a` + `libemlx.a` are
    cross-compiled and statically linked into the app binary. The
    pre-built bundle (~5 MB compressed, ~30 MB on disk per arch) is
    downloaded once and cached at `~/.mob/cache/libmlx-<ver>-ios-<slice>/`
    by `MobDev.MLXDownloader`. `MOB_STATIC_EMLX_NIF` flips on
    automatically — the EMLX NIF is registered in the static-NIF table
    so `load_nif/2` resolves it without dlopen.
  - **Android:** not supported in v1. No Metal on Android — a CPU-only
    NDK build via OpenBLAS is the path forward but isn't shipped yet.
  - **CPU-only for v1.** Metal-on-iOS needs the iOS-Metal CMakeLists
    patch and Xcode 16's optional Metal Toolchain — deferred to a v2
    tarball variant.

  What it does:

    - Adds `{:nx, "~> 0.10"}` and `{:emlx, "~> 0.2"}` to `mix.exs` deps.
    - Generates `lib/<app>/ml_init.ex` — a one-call helper that sets
      `EMLX.Backend` as Nx's global default, with a clean
      `Nx.BinaryBackend` fallback if the NIF can't load.

  After running, your `Mob.App.on_start/0` should call
  `<App>.MLInit.configure()` once `Mob.Screen.start_root/1` and
  `Mob.Dist.ensure_started/1` have run.
  """

  @valid_features ~w(liveview camera photo_library file_sharing location notifications pythonx mlx nxeigen tflite)

  @impl Igniter.Mix.Task
  def info(_argv, _composing_task) do
    %Igniter.Mix.Task.Info{
      group: :mob,
      schema: [],
      # mob.enable takes a variable list of feature names; we parse those
      # from `igniter.args.argv` ourselves rather than declaring a single
      # positional binding.
      positional: []
    }
  end

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    features = parse_features(igniter.args.argv)
    unknown = features -- @valid_features

    cond do
      features == [] ->
        Igniter.add_issue(
          igniter,
          "Usage: mix mob.enable FEATURE [FEATURE ...]\nValid features: #{Enum.join(@valid_features, ", ")}"
        )

      unknown != [] ->
        Igniter.add_issue(
          igniter,
          "Unknown feature(s): #{Enum.join(unknown, ", ")}. Valid: #{Enum.join(@valid_features, ", ")}"
        )

      not File.exists?("mix.exs") ->
        Igniter.add_issue(igniter, "No mix.exs found. Run mix mob.enable from your project root.")

      true ->
        # Read app name from Igniter's view of mix.exs (which respects
        # `test_project(files: %{"mix.exs" => ...})` virtualization).
        # Falls back to the on-disk read when the igniter doesn't have a
        # mix.exs source yet (real invocation outside a test harness).
        app_name =
          case Igniter.Project.Application.app_name(igniter) do
            nil -> read_app_name(File.cwd!())
            atom -> Atom.to_string(atom)
          end

        Enum.reduce(features, igniter, fn feature, acc ->
          dispatch(acc, feature, app_name)
        end)
    end
  end

  # ── Feature dispatch (Phase 4 iter 1: all features routed through Igniter) ──

  alias MobDev.Enable.Igniter, as: EI

  defp dispatch(igniter, "camera", app_name), do: EI.enable_camera(igniter, app_name)

  defp dispatch(igniter, "photo_library", app_name),
    do: EI.enable_photo_library(igniter, app_name)

  defp dispatch(igniter, "location", app_name), do: EI.enable_location(igniter, app_name)
  defp dispatch(igniter, "file_sharing", app_name), do: EI.enable_file_sharing(igniter, app_name)

  defp dispatch(igniter, "notifications", app_name),
    do: EI.enable_notifications(igniter, app_name)

  defp dispatch(igniter, "liveview", app_name), do: EI.enable_liveview(igniter, app_name)

  defp dispatch(igniter, "pythonx", app_name) do
    igniter
    |> EI.enable_python(app_name)
    |> Igniter.add_notice(pythonx_next_steps(app_name))
  end

  defp dispatch(igniter, "mlx", app_name) do
    igniter
    |> EI.enable_mlx(app_name)
    |> Igniter.add_notice(mlx_next_steps(app_name))
  end

  defp dispatch(igniter, "nxeigen", app_name) do
    igniter
    |> EI.enable_nxeigen(app_name)
    |> Igniter.add_notice(nxeigen_next_steps(app_name))
  end

  defp dispatch(igniter, "tflite", app_name) do
    igniter
    |> EI.enable_tflite(app_name)
    |> Igniter.add_notice(tflite_next_steps(app_name))
  end

  defp parse_features(argv) do
    {_opts, features, _} = OptionParser.parse(argv, strict: [yes: :boolean])
    features
  end

  defp mlx_next_steps(app_name) do
    module = Macro.camelize(app_name)

    """
    Next steps for mlx:
      1. Run `mix deps.get` to fetch :nx + :emlx.
      2. In your `Mob.App.on_start/0`, call:
           #{module}.MLInit.configure()
         after `Mob.Screen.start_root/1` and `Mob.Dist.ensure_started/1`.
         It picks EMLX as Nx's global backend (CPU + Apple Accelerate on
         iOS) and falls back to Nx.BinaryBackend if EMLX can't load.
      3. `mix mob.deploy --native --device <udid>` to cross-compile and
         install the app. The first build downloads ~5 MB of pre-built
         MLX (libmlx.a + libemlx.a) into ~/.mob/cache/.

    Bundle size impact: ~5 MB compressed (~30 MB on disk per arch).
    Apply this only when you actually want fast on-device tensor math.

    iOS-only for v1. Android MLX support is a separate cross-compile
    (no Metal — CPU + NDK BLAS); not shipped yet.
    """
  end

  defp nxeigen_next_steps(app_name) do
    module = Macro.camelize(app_name)

    """
    Next steps for nxeigen:
      1. Run `mix deps.get` to fetch :nx + :nx_eigen.
      2. Run `mix deps.compile nx_eigen` once on host — this triggers
         the auto-download of the Eigen 3.4.0 header tarball into
         deps/nx_eigen/eigen-3.4.0/, which mob_dev's cross-compile
         then references.
      3. In your `Mob.App.on_start/0`, call:
           #{module}.NxEigenInit.configure()
         after `Mob.Screen.start_root/1` and `Mob.Dist.ensure_started/1`.
         It picks NxEigen as Nx's global backend (Eigen CPU, header-only,
         NEON-vectorised on ARM) and falls back to Nx.BinaryBackend if
         the NIF can't load.
      4. `mix mob.deploy --native --device <udid>` to cross-compile and
         install the app. The first build cross-compiles libnx_eigen.a
         (two .cpp files: NxEigen's main NIF + our Eigen-FFT bridge)
         per target arch into `_build/<env>/nxeigen/`.

    Works on BOTH iOS (device + sim) and Android (arm64 + arm32) —
    Eigen is header-only C++. FFT support uses Eigen's built-in
    kissfft (header-only); swap to a FFTW variant later if needed.
    """
  end

  defp tflite_next_steps(app_name) do
    module = Macro.camelize(app_name)

    """
    Next steps for tflite:
      1. Run `mix deps.get` to fetch :nx + :nx_tflite_mob.
      2. Drop a `.tflite` model into `priv/` (e.g. exported from Ultralytics:
           yolo export model=yolov8n.pt format=tflite int8=True
         produces `yolov8n_full_integer_quant.tflite`).
      3. Use in app code:
           tflite = File.read!(Path.join(:code.priv_dir(:#{app_name}), "yolov8n_full_integer_quant.tflite"))
           {:ok, m} = NxTfliteMob.load_module(tflite, #{module}.TfliteInit.default_opts())
           {:ok, [out]} = NxTfliteMob.call(m, [input_bytes])
      4. `mix mob.deploy --native --device <udid>` to cross-compile and install.
         First build downloads:
           - Android: tensorflow-lite-2.16.1.aar (~6 MB) into ~/.mob/cache/
           - iOS:     TensorFlowLiteC-2.17.0.tar.gz (~77 MB) into ~/.mob/cache/

    Bundle size impact: ~3-4 MB compressed (Android `libtensorflowlite_jni.so`);
    ~20-30 MB on iOS (TensorFlowLiteC + CoreML/Metal frameworks). Apply this
    only when you actually want to run TFLite models.

    Cross-platform: same `.tflite` model + same `NxTfliteMob.call/2` Elixir
    code on iOS and Android. The per-platform delegate is picked by
    `#{module}.TfliteInit.default_opts/0` automatically.
    """
  end

  defp pythonx_next_steps(app_name) do
    module = Macro.camelize(app_name)

    """
    Next steps for pythonx:
      1. Run `mix deps.get` to fetch :pythonx
      2. In your `Mob.App.on_start/0`:
           {:ok, _} = Application.ensure_all_started(:pythonx)
           case #{module}.PythonPaths.detect(to_string(:code.root_dir())) do
             :desktop                               -> Pythonx.Uv.fetch(toml, false); Pythonx.Uv.init(toml, false)
             {:ios, %{dl_path: dl, home_path: home}}     -> Pythonx.init(dl, home, dl, sys_paths: [])
             {:android, %{dl_path: dl, home_path: home}} -> Pythonx.init(dl, home, dl, sys_paths: [Path.join([home, "lib", "python3.13"])])
             {:partial, missing}                    -> # log + bail out
           end
         pyproject_toml stays inline so Pythonx.Application doesn't auto-run uv
         on device (where uv doesn't exist).
      3. `mix mob.deploy --native --device <udid>` to bundle CPython +
         install on device. iOS downloads the BeeWare framework on first
         run; Android pulls Chaquopy's prebuilt distribution.
    """
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp read_app_name(project_dir) do
    MobDev.Enable.read_app_name_from(Path.join(project_dir, "mix.exs"))
  rescue
    e -> Mix.raise(Exception.message(e))
  end
end
