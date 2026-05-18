defmodule MobDev.Enable.Igniter do
  @moduledoc """
  Igniter-aware feature handlers for `mix mob.enable`.

  One function per `<feature>` returning `igniter -> igniter`. Phase 4 of
  the build-system migration moves each handler off the legacy
  string-mutation path (where each helper writes files immediately) and
  onto Igniter's `update_file` / `create_new_file` flow (where every
  change rolls into a single dry-run-able diff before any file is
  written).

  Per-feature state:

  | Feature        | Igniter-routed (iter 1) | Elixir AST-aware  |
  |----------------|-------------------------|-------------------|
  | camera         | yes                     | (no Elixir surface) |
  | photo_library  | yes                     | (no Elixir surface) |
  | location       | yes                     | (no Elixir surface) |
  | file_sharing   | yes                     | (no Elixir surface) |
  | notifications  | yes                     | (no Elixir surface) |
  | liveview       | yes                     | mob_screen.ex via `create_module` (iter 1) |
  | python         | yes                     | dep via `add_dep` (iter 2); paths module via `create_module` (iter 1) |

  iter 1 wrapped every feature in Igniter so the diff preview + atomic
  apply flow applies uniformly. iter 2 swapped python's mix.exs
  dep-injection from `MobDev.Enable.inject_pythonx_dep` (regex) to
  `Igniter.Project.Deps.add_dep` (AST). The remaining text-level
  patches (assets/js/app.js, root.html.heex) are non-Elixir source
  and stay text-level — AST tooling for those isn't a win.

  All handlers are called with the project root as cwd (Igniter expects
  paths relative to cwd). The `app_name` arg is the project's :app
  Mix config (a string like "my_app") for any feature that needs to
  template it into generated source.
  """

  alias MobDev.Enable

  # ── camera ────────────────────────────────────────────────────────────────

  @spec enable_camera(Igniter.t(), String.t()) :: Igniter.t()
  def enable_camera(igniter, _app_name) do
    igniter
    |> add_ios_plist_key("NSCameraUsageDescription", "This app uses the camera.")
    |> add_android_permission("android.permission.CAMERA")
  end

  # ── photo_library ─────────────────────────────────────────────────────────

  @spec enable_photo_library(Igniter.t(), String.t()) :: Igniter.t()
  def enable_photo_library(igniter, _app_name) do
    igniter
    |> add_ios_plist_key(
      "NSPhotoLibraryAddUsageDescription",
      "This app saves photos to your library."
    )
    |> Igniter.add_notice("photo_library: no Android manifest change needed on API 29+.")
  end

  # ── location ──────────────────────────────────────────────────────────────

  @spec enable_location(Igniter.t(), String.t()) :: Igniter.t()
  def enable_location(igniter, _app_name) do
    igniter
    |> add_ios_plist_key(
      "NSLocationWhenInUseUsageDescription",
      "This app uses your location."
    )
    |> add_android_permission("android.permission.ACCESS_FINE_LOCATION")
  end

  # ── file_sharing ──────────────────────────────────────────────────────────

  @spec enable_file_sharing(Igniter.t(), String.t()) :: Igniter.t()
  def enable_file_sharing(igniter, _app_name) do
    igniter
    |> add_ios_plist_key("UIFileSharingEnabled", "true", type: :bool)
    |> add_ios_plist_key("LSSupportsOpeningDocumentsInPlace", "true", type: :bool)
    |> add_android_file_provider()
  end

  # ── notifications ─────────────────────────────────────────────────────────

  @spec enable_notifications(Igniter.t(), String.t()) :: Igniter.t()
  def enable_notifications(igniter, app_name) do
    igniter
    |> create_ios_push_entitlements(app_name)
    |> Igniter.add_notice(
      "notifications: Android POST_NOTIFICATIONS is requested at runtime, no manifest key needed."
    )
    |> Igniter.add_notice(
      "notifications: run `mix mob.provision` to download a push-capable provisioning profile."
    )
  end

  # ── liveview ──────────────────────────────────────────────────────────────

  @spec enable_liveview(Igniter.t(), String.t()) :: Igniter.t()
  def enable_liveview(igniter, app_name) do
    igniter
    |> create_mob_screen_module(app_name)
    |> inject_mob_hook()
    |> inject_mob_bridge_element(app_name)
    |> ensure_mob_exs_liveview_port()
    |> add_android_liveview_network_config()
  end

  # ── mlx ───────────────────────────────────────────────────────────────────

  @doc """
  Enables MLX + EMLX (Apple's MLX numerics + the EMLX Nx backend) for
  iOS. Adds `:nx` and `:emlx` to deps; generates a tiny
  `<App>.MLInit` helper that picks `EMLX.Backend` at boot with a clean
  fallback to `Nx.BinaryBackend` if the NIF can't load.

  The `:emlx_nif` static NIF entry is already in `MobDev.StaticNifs`
  defaults — `MobDev.NativeBuild` auto-detects the `:emlx` dep, downloads
  the cross-compiled MLX bundle, and sets `MOB_STATIC_EMLX_NIF` so the
  driver_tab + linker include EMLX. So `mob.enable mlx` is mostly about
  the dep wiring and the helper module.
  """
  @spec enable_mlx(Igniter.t(), String.t()) :: Igniter.t()
  def enable_mlx(igniter, app_name) do
    igniter
    |> inject_mlx_deps()
    |> create_ml_init_module(app_name)
  end

  # ── nxeigen ───────────────────────────────────────────────────────────────

  @doc """
  Enables the NxEigen Nx backend (Eigen-backed C++ NIF) on both iOS and
  Android. mob_dev cross-compiles `libnx_eigen.a` per arch from the
  `:nx_eigen` Hex dep + the Eigen header tarball it auto-downloads.

  The `:nx_eigen` static-NIF entry is already in
  `MobDev.StaticNifs` defaults — `MobDev.NativeBuild` auto-detects the
  `:nx_eigen` dep and sets `MOB_STATIC_NX_EIGEN_NIF` so the driver_tab
  + linker include it. `mob.enable nxeigen` does the dep wiring + the
  helper module.
  """
  @spec enable_nxeigen(Igniter.t(), String.t()) :: Igniter.t()
  def enable_nxeigen(igniter, app_name) do
    igniter
    |> inject_nxeigen_deps()
    |> create_nxeigen_init_module(app_name)
  end

  # ── tflite ────────────────────────────────────────────────────────────────

  @doc """
  Enables the TensorFlow Lite NIF (`:nx_tflite_mob`) on both iOS and
  Android. Adds the dep, generates a small `<App>.TfliteInit` helper that
  surfaces per-platform default opts (NNAPI accelerator on Android, Core
  ML delegate on iOS), and registers the static-NIF guard via the
  build pipeline.

  Unlike `mlx` / `nxeigen`, this is not an Nx backend — `NxTfliteMob`
  wraps TFLite's model-inference API directly. The user loads a
  `.tflite` model and calls `NxTfliteMob.call(handle, inputs)`. The
  generated `<App>.TfliteInit` only provides convenience helpers for
  picking the right delegate + accelerator for the host platform.
  """
  @spec enable_tflite(Igniter.t(), String.t()) :: Igniter.t()
  def enable_tflite(igniter, app_name) do
    igniter
    |> inject_tflite_deps()
    |> create_tflite_init_module(app_name)
  end

  # ── python ────────────────────────────────────────────────────────────────

  @spec enable_python(Igniter.t(), String.t()) :: Igniter.t()
  def enable_python(igniter, app_name) do
    igniter
    |> inject_pythonx_dep()
    |> create_python_paths_module(app_name)
    |> python_native_template_check(app_name)
  end

  # ── Shared helpers (text-level, but rolled into Igniter's diff) ───────────
  #
  # Plist + AndroidManifest patches stay text-level for now — the AST-based
  # XML/plist tools are out of scope for Phase 4. The win we're after here
  # is the diff-preview + atomic-apply, which Igniter.update_file gives us
  # without touching the patch logic itself.

  @doc """
  Adds an iOS Info.plist `<key>...<string>...` pair if not already present.

  No-op (with a notice) when no Info.plist is found under `ios/`. The
  insertion is idempotent — runs that find the key already present skip
  the patch silently.
  """
  @spec add_ios_plist_key(Igniter.t(), String.t(), String.t(), keyword()) :: Igniter.t()
  def add_ios_plist_key(igniter, key, value, opts \\ []) do
    case find_ios_plist(igniter) do
      nil ->
        Igniter.add_notice(igniter, "iOS: no Info.plist found under ios/ — skipped #{key}.")

      plist ->
        igniter
        |> Igniter.include_existing_file(plist)
        |> Igniter.update_file(plist, fn source ->
          content = Rewrite.Source.get(source, :content)

          if String.contains?(content, key) do
            source
          else
            entry = Enable.build_plist_entry(key, value, opts)
            patched = String.replace(content, "</dict>\n</plist>", "#{entry}\n</dict>\n</plist>")
            Rewrite.Source.update(source, :content, patched)
          end
        end)
    end
  end

  @doc """
  Adds an Android `<uses-permission>` line to AndroidManifest.xml.

  No-op (with a notice) when no AndroidManifest.xml is found. Idempotent
  on the permission name — re-running with the same permission skips
  the patch silently.
  """
  @spec add_android_permission(Igniter.t(), String.t()) :: Igniter.t()
  def add_android_permission(igniter, permission) do
    case find_android_manifest(igniter) do
      nil ->
        Igniter.add_notice(
          igniter,
          "Android: no AndroidManifest.xml found — skipped permission #{permission}."
        )

      manifest ->
        igniter
        |> Igniter.include_existing_file(manifest)
        |> Igniter.update_file(manifest, fn source ->
          content = Rewrite.Source.get(source, :content)

          if String.contains?(content, permission) do
            source
          else
            tag = ~s(<uses-permission android:name="#{permission}"/>)

            patched =
              String.replace(content, "<application", "#{tag}\n    <application", global: false)

            Rewrite.Source.update(source, :content, patched)
          end
        end)
    end
  end

  # ── file_sharing: Android FileProvider ────────────────────────────────────

  defp add_android_file_provider(igniter) do
    case find_android_manifest(igniter) do
      nil ->
        Igniter.add_notice(
          igniter,
          "Android: no AndroidManifest.xml found — skipped FileProvider."
        )

      manifest ->
        igniter
        |> Igniter.include_existing_file(manifest)
        |> Igniter.update_file(manifest, fn source ->
          content = Rewrite.Source.get(source, :content)

          if String.contains?(content, "FileProvider") do
            source
          else
            patched =
              String.replace(
                content,
                "</application>",
                file_provider_xml() <> "\n    </application>",
                global: false
              )

            Rewrite.Source.update(source, :content, patched)
          end
        end)
        |> create_file_provider_paths_xml()
    end
  end

  defp create_file_provider_paths_xml(igniter) do
    path = "android/app/src/main/res/xml/file_provider_paths.xml"

    if File.exists?(path) do
      igniter
    else
      Igniter.create_new_file(igniter, path, """
      <?xml version="1.0" encoding="utf-8"?>
      <paths>
          <files-path name="mob_files" path="." />
          <cache-path name="mob_cache" path="." />
          <external-files-path name="mob_external" path="." />
      </paths>
      """)
    end
  end

  defp file_provider_xml do
    "        <provider\n" <>
      "            android:name=\"androidx.core.content.FileProvider\"\n" <>
      "            android:authorities=\"${applicationId}.fileprovider\"\n" <>
      "            android:exported=\"false\"\n" <>
      "            android:grantUriPermissions=\"true\">\n" <>
      "            <meta-data\n" <>
      "                android:name=\"android.support.FILE_PROVIDER_PATHS\"\n" <>
      "                android:resource=\"@xml/file_provider_paths\"/>\n" <>
      "        </provider>"
  end

  # ── notifications: iOS push entitlements file ─────────────────────────────

  defp create_ios_push_entitlements(igniter, app_name) do
    path = "ios/#{app_name}.entitlements"

    if File.exists?(path) do
      igniter
    else
      Igniter.create_new_file(igniter, path, """
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
          <key>aps-environment</key>
          <string>development</string>
      </dict>
      </plist>
      """)
    end
  end

  # ── liveview: helpers ─────────────────────────────────────────────────────

  defp create_mob_screen_module(igniter, app_name) do
    module_name = Macro.camelize(app_name)
    module = Module.concat([module_name, "MobScreen"])
    {exists?, igniter} = Igniter.Project.Module.module_exists(igniter, module)

    if exists? do
      igniter
    else
      body = mob_screen_body()
      Igniter.Project.Module.create_module(igniter, module, body)
    end
  end

  defp mob_screen_body do
    """
    @moduledoc \"\"\"
    Mob.Screen that wraps the Phoenix LiveView app in a native WebView.

    Add this to your supervision tree or call from Mob.App.on_start/0:

        Mob.Screen.start_root(__MODULE__)
    \"\"\"
    use Mob.Screen

    def mount(_params, _session, socket) do
      {:ok, socket}
    end

    def render(_assigns) do
      Mob.UI.webview(
        url: Mob.LiveView.local_url("/"),
        show_url: false
      )
    end
    """
  end

  defp inject_mob_hook(igniter) do
    path = "assets/js/app.js"

    if not File.exists?(path) do
      Igniter.add_notice(
        igniter,
        "liveview: assets/js/app.js not found — add MobHook manually (see `Mob.LiveView` docs)."
      )
    else
      igniter
      |> Igniter.include_existing_file(path)
      |> Igniter.update_file(path, fn source ->
        content = Rewrite.Source.get(source, :content)

        if String.contains?(content, "MobHook") do
          source
        else
          Rewrite.Source.update(source, :content, Enable.inject_mob_hook(content))
        end
      end)
    end
  end

  defp inject_mob_bridge_element(igniter, app_name) do
    case Enable.find_root_html(File.cwd!(), app_name) do
      nil ->
        Igniter.add_notice(igniter, """
        liveview: root.html.heex not found. Add this manually inside <body>:
          #{Enable.mob_bridge_element()}

        Without this element MobHook never mounts and window.mob will not
        route through LiveView. See guides/liveview.md.
        """)

      abs_path ->
        rel = Path.relative_to(abs_path, File.cwd!())

        igniter
        |> Igniter.include_existing_file(rel)
        |> Igniter.update_file(rel, fn source ->
          content = Rewrite.Source.get(source, :content)

          if String.contains?(content, "mob-bridge") do
            source
          else
            Rewrite.Source.update(source, :content, Enable.inject_mob_bridge_element(content))
          end
        end)
    end
  end

  defp ensure_mob_exs_liveview_port(igniter) do
    line = "config :mob, liveview_port: 4000"

    igniter
    |> Igniter.create_or_update_file("mob.exs", "import Config\n\n#{line}\n", fn source ->
      content = Rewrite.Source.get(source, :content)

      cond do
        String.contains?(content, "liveview_port") ->
          {:ok, source}

        true ->
          {:ok, Rewrite.Source.update(source, :content, content <> "\n#{line}\n")}
      end
    end)
  end

  defp add_android_liveview_network_config(igniter) do
    case find_android_manifest(igniter) do
      nil ->
        Igniter.add_notice(
          igniter,
          "Android: no AndroidManifest.xml found — skipped LiveView networkSecurityConfig."
        )

      manifest ->
        igniter
        |> Igniter.include_existing_file(manifest)
        |> Igniter.update_file(manifest, fn source ->
          content = Rewrite.Source.get(source, :content)

          if String.contains?(content, "networkSecurityConfig") do
            source
          else
            Rewrite.Source.update(
              source,
              :content,
              Enable.inject_android_network_security_config(content)
            )
          end
        end)
    end
  end

  # ── mlx: helpers ──────────────────────────────────────────────────────────

  defp inject_mlx_deps(igniter) do
    igniter
    |> Igniter.Project.Deps.add_dep({:nx, "~> 0.10"})
    |> Igniter.Project.Deps.add_dep({:emlx, "~> 0.2"})
  end

  # ── nxeigen: helpers ──────────────────────────────────────────────────────

  defp inject_nxeigen_deps(igniter) do
    igniter
    |> Igniter.Project.Deps.add_dep({:nx, "~> 0.10"})
    |> Igniter.Project.Deps.add_dep({:nx_eigen, "~> 0.1"})
  end

  defp create_nxeigen_init_module(igniter, app_name) do
    module_name = Macro.camelize(app_name)
    module = Module.concat([module_name, "NxEigenInit"])
    {exists?, igniter} = Igniter.Project.Module.module_exists(igniter, module)

    if exists? do
      igniter
    else
      Igniter.Project.Module.create_module(igniter, module, nxeigen_init_module_body())
    end
  end

  # ── tflite: helpers ───────────────────────────────────────────────────────

  defp inject_tflite_deps(igniter) do
    igniter
    |> Igniter.Project.Deps.add_dep({:nx, "~> 0.10"})
    |> Igniter.Project.Deps.add_dep({:nx_tflite_mob, "~> 0.0.3"})
  end

  defp create_tflite_init_module(igniter, app_name) do
    module_name = Macro.camelize(app_name)
    module = Module.concat([module_name, "TfliteInit"])
    {exists?, igniter} = Igniter.Project.Module.module_exists(igniter, module)

    if exists? do
      igniter
    else
      Igniter.Project.Module.create_module(igniter, module, tflite_init_module_body())
    end
  end

  # Body for the generated `<App>.TfliteInit` module. Picks per-platform
  # default TFLite delegate options — NNAPI/mtk-gpu_shim on Android (the
  # vendor GPU HAL path, ~155 ms YOLOv8n on the Moto BXM-8-256), Core ML
  # delegate on iOS (Apple Neural Engine when available, ~30-80 ms YOLOv8n
  # depending on op coverage).
  defp tflite_init_module_body do
    """
    @moduledoc \"\"\"
    Default TFLite delegate options per platform. Surface convenience for
    `NxTfliteMob.load_module/2` callers — pass the result of `default_opts/0`
    and you get the best-available accelerator on this device.

      tflite = File.read!("priv/yolov8n_full_integer_quant.tflite")
      {:ok, m} = NxTfliteMob.load_module(tflite, MyApp.TfliteInit.default_opts())
    \"\"\"

    require Logger

    @doc \"Best-available TFLite delegate opts for this platform.\"
    def default_opts do
      case :os.type() do
        {:unix, :darwin} ->
          # iOS (or Mac dev host). Core ML delegate hits Apple Neural Engine
          # when ops are supported; falls back to CPU/GPU otherwise.
          [delegate: "coreml", coreml_ane_only: false]

        {:unix, :linux} ->
          # Android (or Linux dev host). NNAPI's mtk-gpu_shim is the
          # MediaTek-blessed name on Dimensity-class devices. On other
          # OEMs the accelerator name may differ — qti-gpu (Qualcomm),
          # samsung-gpu (Exynos), google-edgetpu (Pixel).
          [delegate: "nnapi", accelerator: "mtk-gpu_shim", allow_fp16: true]

        _ ->
          # Desktop dev (Windows or other Unix). Stay on the bundled CPU path.
          [delegate: "xnnpack"]
      end
    end

    @doc \"Log whether the NIF appears loadable. Call once at app boot.\"
    def configure do
      case Code.ensure_loaded?(NxTfliteMob) do
        true ->
          Logger.info("NxTfliteMob loaded; default delegate opts: \#\{inspect(default_opts())\}")
          :ok

        false ->
          Logger.warning("NxTfliteMob not loaded — TFLite inference will fail until built")
          {:error, :not_loaded}
      end
    end
    """
  end

  # Body for the generated `<App>.NxEigenInit` module. Picks NxEigen as
  # the Nx global default with a clean fall-back to `Nx.BinaryBackend`.
  # Parallel to MLInit but used on Android (where EMLX isn't an option)
  # or on iOS apps that want NxEigen's specific behaviour.
  defp nxeigen_init_module_body do
    """
    @moduledoc \"\"\"
    Picks NxEigen as the Nx backend. Called from `Mob.App.on_start/0`
    once the app and its deps have started.

    NxEigen is an Eigen-backed CPU Nx backend (C++ template library,
    vectorised via NEON on ARM). Works on both iOS and Android — Eigen
    is header-only, so mob_dev cross-compiles a single libnx_eigen.a
    per arch and statically links it into the app.

    Falls back to `Nx.BinaryBackend` (pure Elixir) when the NIF can't
    load — keeps the app running on builds that haven't cross-compiled
    NxEigen yet.
    \"\"\"
    require Logger

    @doc \"Configure the global Nx backend. Returns the chosen backend module.\"
    def configure do
      case Application.ensure_all_started(:nx_eigen) do
        {:ok, _} ->
          Nx.global_default_backend(NxEigen.Backend)
          Logger.info("Nx backend: NxEigen (Eigen CPU)")
          NxEigen.Backend

        {:error, reason} ->
          Logger.warning(\"NxEigen failed to start: \#\{inspect(reason)\}; using Nx.BinaryBackend\")
          Nx.global_default_backend(Nx.BinaryBackend)
          Nx.BinaryBackend
      end
    end
    """
  end

  defp create_ml_init_module(igniter, app_name) do
    module_name = Macro.camelize(app_name)
    module = Module.concat([module_name, "MLInit"])
    {exists?, igniter} = Igniter.Project.Module.module_exists(igniter, module)

    if exists? do
      igniter
    else
      Igniter.Project.Module.create_module(igniter, module, ml_init_module_body())
    end
  end

  # Body for the generated `<App>.MLInit` module. Kept inline because the
  # template is small and doesn't need a separate `.eex` file. The string is
  # the *body* — `Igniter.Project.Module.create_module/3` wraps it in
  # `defmodule <module> do ... end`.
  defp ml_init_module_body do
    """
    @moduledoc \"\"\"
    Picks the right Nx backend for this build. Called from
    `Mob.App.on_start/0` once the app and its deps have started.

    On iOS device + simulator: EMLX (Apple's MLX, statically linked into the
    app via mob_dev's MLX integration). Falls back to `Nx.BinaryBackend`
    (pure Elixir) when the NIF can't load — keeps the app running even if
    MLX isn't available on this build (e.g. an Android build that hasn't
    cross-compiled MLX yet).

    The default device is `:cpu` because v1 of the EMLX iOS integration
    ships CPU-only. Update to `:gpu` once the Metal variant lands.
    \"\"\"
    require Logger

    @doc \"Configure the global Nx backend. Returns the chosen backend module.\"
    def configure do
      case Application.ensure_all_started(:emlx) do
        {:ok, _} ->
          Nx.global_default_backend({EMLX.Backend, device: :cpu})
          Logger.info("Nx backend: EMLX (cpu)")
          EMLX.Backend

        {:error, reason} ->
          Logger.warning(\"EMLX failed to start: \#\{inspect(reason)\}; using Nx.BinaryBackend\")
          Nx.global_default_backend(Nx.BinaryBackend)
          Nx.BinaryBackend
      end
    end
    """
  end

  # ── python: helpers ───────────────────────────────────────────────────────

  defp inject_pythonx_dep(igniter) do
    # AST-aware (Phase 4 iter 2) — `Igniter.Project.Deps.add_dep` parses
    # the project's mix.exs, locates the `defp deps do [...]` list, and
    # appends the dep tuple in-place. Idempotent: a duplicate
    # `{:pythonx, ...}` is detected and skipped. Replaces the previous
    # regex sweep in `MobDev.Enable.inject_pythonx_dep/1` which had to
    # guess at indentation + trailing comma shape.
    Igniter.Project.Deps.add_dep(igniter, {:pythonx, "~> 0.4"})
  end

  defp create_python_paths_module(igniter, app_name) do
    module_name = Macro.camelize(app_name)
    module = Module.concat([module_name, "PythonPaths"])
    {exists?, igniter} = Igniter.Project.Module.module_exists(igniter, module)

    if exists? do
      igniter
    else
      # The existing template renders a full `defmodule ... do ... end` —
      # strip the wrapper so `Igniter.Project.Module.create_module` can
      # apply its own `defmodule` shell.
      body = strip_defmodule_wrapper(Enable.python_paths_module_template(module_name))
      Igniter.Project.Module.create_module(igniter, module, body)
    end
  end

  defp strip_defmodule_wrapper(source) do
    source
    |> String.split("\n")
    |> Enum.drop(1)
    |> Enum.drop(-1)
    |> Enum.drop(-1)
    |> Enum.join("\n")
  end

  defp python_native_template_check(igniter, app_name) do
    case Enable.detect_stale_pythonx_templates(File.cwd!(), app_name) do
      [] ->
        Igniter.add_notice(igniter, "python: native templates look up to date.")

      stale ->
        files =
          Enum.map_join(stale, "\n", fn {file, marker} -> "  - #{file} (missing: #{marker})" end)

        Igniter.add_warning(igniter, """
        Native build templates are stale — Pythonx requires extra build steps that aren't present:
        #{files}

        Either generate a fresh project with `mix mob.new` and copy your app code over,
        or copy the missing blocks from ~/.mix/archives/mob_new-*/priv/templates/mob.new/.
        """)
    end
  end

  # ── File discovery (Igniter-aware so test_project virtual files work) ────

  defp find_ios_plist(igniter) do
    cwd = File.cwd!()

    abs =
      cwd
      |> Path.join("ios/**/Info.plist")
      |> Path.wildcard()
      |> List.first()

    cond do
      # Disk hit (real project) — return relative path so Igniter's diff
      # matches what the user sees.
      abs ->
        Path.relative_to(abs, cwd)

      # No disk hit — check Igniter's known sources for ios/**/Info.plist
      # (covers Igniter.test_project where files are virtualized in
      # `igniter.rewrite` rather than written to disk).
      true ->
        igniter.rewrite
        |> Rewrite.paths()
        |> Enum.find(&String.match?(&1, ~r{^ios/.*Info\.plist$}))
    end
  end

  defp find_android_manifest(igniter) do
    path = "android/app/src/main/AndroidManifest.xml"

    cond do
      File.exists?(path) -> path
      Igniter.exists?(igniter, path) -> path
      true -> nil
    end
  end
end
