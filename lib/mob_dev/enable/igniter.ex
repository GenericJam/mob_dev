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

  | Feature        | Igniter-routed (iter 1) | AST-aware (later iter) |
  |----------------|-------------------------|------------------------|
  | camera         | yes                     | (no Elixir to AST)     |
  | photo_library  | yes                     | (no Elixir to AST)     |
  | location       | yes                     | (no Elixir to AST)     |
  | file_sharing   | yes                     | (no Elixir to AST)     |
  | notifications  | yes                     | (no Elixir to AST)     |
  | liveview       | yes                     | iter 4 — Elixir AST    |
  | python         | yes                     | iter 5 — Elixir AST    |

  iter 1 wraps every feature in Igniter so the diff preview + atomic
  apply flow applies uniformly. The "AST-aware" column tracks the
  follow-up work for features that touch Elixir source: liveview's
  `lib/<app>/mob_screen.ex` generation + `assets/js/app.js` /
  `root.html.heex` patches still go through Sourceror text replace
  today; python's dep injection + paths module generation likewise.

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
                file_provider_xml() <> "\n    </application>", global: false)

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

  # ── python: helpers ───────────────────────────────────────────────────────

  defp inject_pythonx_dep(igniter) do
    path = "mix.exs"

    igniter
    |> Igniter.include_existing_file(path)
    |> Igniter.update_file(path, fn source ->
      content = Rewrite.Source.get(source, :content)
      patched = Enable.inject_pythonx_dep(content)

      if patched == content do
        source
      else
        Rewrite.Source.update(source, :content, patched)
      end
    end)
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
