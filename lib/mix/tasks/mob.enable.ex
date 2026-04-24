defmodule Mix.Tasks.Mob.Enable do
  use Mix.Task

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
    - Updates `mob.exs` with `liveview_port` so `Mob.LiveView.local_url/1` works

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

  - iOS: runtime only — no plist key needed
  - Android: adds `POST_NOTIFICATIONS` permission (API 33+)
  """

  @valid_features ~w(liveview camera photo_library file_sharing location notifications)

  @impl Mix.Task
  def run([]) do
    Mix.shell().error("Usage: mix mob.enable FEATURE [FEATURE ...]")
    Mix.shell().info("Valid features: #{Enum.join(@valid_features, ", ")}")
    Mix.raise("No features specified")
  end

  def run(argv) do
    {_opts, features, _} = OptionParser.parse(argv, strict: [])

    project_dir = File.cwd!()

    unless File.exists?(Path.join(project_dir, "mix.exs")) do
      Mix.raise("No mix.exs found. Run mix mob.enable from your project root.")
    end

    unknown = features -- @valid_features

    if unknown != [] do
      Mix.raise("Unknown feature(s): #{Enum.join(unknown, ", ")}. " <>
                "Valid: #{Enum.join(@valid_features, ", ")}")
    end

    app_name = read_app_name(project_dir)

    Enum.each(features, fn feature ->
      Mix.shell().info([:cyan, "\nEnabling #{feature}...", :reset])
      enable(feature, project_dir, app_name)
    end)

    Mix.shell().info([:green, "\nDone.", :reset])
  end

  # ── Feature handlers ──────────────────────────────────────────────────────

  defp enable("liveview", project_dir, app_name) do
    generate_mob_screen(project_dir, app_name)
    inject_mob_hook(project_dir)
    update_mob_exs(project_dir)
  end

  defp enable("camera", project_dir, _app_name) do
    ios_add_plist_key(project_dir, "NSCameraUsageDescription",
      "This app uses the camera.")
    android_add_permission(project_dir, "android.permission.CAMERA")
  end

  defp enable("photo_library", project_dir, _app_name) do
    ios_add_plist_key(project_dir, "NSPhotoLibraryAddUsageDescription",
      "This app saves photos to your library.")
    android_noop("photo_library", "no manifest change needed on API 29+")
  end

  defp enable("file_sharing", project_dir, _app_name) do
    ios_add_plist_key(project_dir, "UIFileSharingEnabled", "true", type: :bool)
    ios_add_plist_key(project_dir, "LSSupportsOpeningDocumentsInPlace", "true", type: :bool)
    android_add_file_provider(project_dir)
  end

  defp enable("location", project_dir, _app_name) do
    ios_add_plist_key(project_dir, "NSLocationWhenInUseUsageDescription",
      "This app uses your location.")
    android_add_permission(project_dir, "android.permission.ACCESS_FINE_LOCATION")
  end

  defp enable("notifications", _project_dir, _app_name) do
    android_noop("notifications", "POST_NOTIFICATIONS is requested at runtime, no manifest key needed")
    ios_noop("notifications", "iOS notification permission is requested at runtime, no plist key needed")
  end

  # ── LiveView: generate MobScreen ─────────────────────────────────────────

  defp generate_mob_screen(project_dir, app_name) do
    module_name = Macro.camelize(app_name)
    dir = Path.join([project_dir, "lib", app_name])
    path = Path.join(dir, "mob_screen.ex")

    if File.exists?(path) do
      Mix.shell().info("  * skip #{path} (already exists)")
    else
      File.mkdir_p!(dir)
      File.write!(path, mob_screen_template(module_name))
      Mix.shell().info([:green, "  * create ", :reset, path])
    end
  end

  defp mob_screen_template(module_name) do
    """
    defmodule #{module_name}.MobScreen do
      @moduledoc \"\"\"
      Mob.Screen that wraps the Phoenix LiveView app in a native WebView.

      Add this to your supervision tree or call from Mob.App.on_start/0:

          Mob.Screen.start_root(#{module_name}.MobScreen)
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
    end
    """
  end

  # ── LiveView: inject MobHook into assets/js/app.js ───────────────────────

  defp inject_mob_hook(project_dir) do
    path = Path.join([project_dir, "assets", "js", "app.js"])

    unless File.exists?(path) do
      Mix.shell().info("  * skip MobHook injection (#{path} not found)")
      Mix.shell().info("    Add the hook manually — see `Mob.LiveView` docs.")
      return(nil)
    end

    content = File.read!(path)

    if String.contains?(content, "MobHook") do
      Mix.shell().info("  * skip #{path} (MobHook already present)")
    else
      patched = MobDev.Enable.inject_mob_hook(content)
      File.write!(path, patched)
      Mix.shell().info([:green, "  * patch ", :reset, path, " (added MobHook)"])
    end
  end

  # ── LiveView: update mob.exs ──────────────────────────────────────────────

  defp update_mob_exs(project_dir) do
    path = Path.join(project_dir, "mob.exs")
    liveview_line = "config :mob, liveview_port: 4000"

    if File.exists?(path) do
      content = File.read!(path)

      if String.contains?(content, "liveview_port") do
        Mix.shell().info("  * skip #{path} (liveview_port already set)")
      else
        File.write!(path, content <> "\n#{liveview_line}\n")
        Mix.shell().info([:green, "  * patch ", :reset, path, " (added liveview_port)"])
      end
    else
      File.write!(path, """
      import Config

      #{liveview_line}
      """)
      Mix.shell().info([:green, "  * create ", :reset, path])
    end
  end

  # ── iOS plist helpers ─────────────────────────────────────────────────────

  defp ios_add_plist_key(project_dir, key, value, opts \\ []) do
    plist = find_ios_plist(project_dir)

    if plist do
      content = File.read!(plist)

      if String.contains?(content, key) do
        Mix.shell().info("  * skip #{plist} (#{key} already present)")
      else
        entry = build_plist_entry(key, value, opts)
        patched = String.replace(content, "</dict>\n</plist>",
          "#{entry}\n</dict>\n</plist>")
        File.write!(plist, patched)
        Mix.shell().info([:green, "  * patch ", :reset, plist, " (added #{key})"])
      end
    else
      Mix.shell().info("  * skip iOS (no Info.plist found under ios/)")
    end
  end

  defp build_plist_entry(key, value, opts) do
    MobDev.Enable.build_plist_entry(key, value, opts)
  end

  defp find_ios_plist(project_dir) do
    Path.wildcard(Path.join(project_dir, "ios/**/*.xcodeproj/../*.plist"))
    |> Enum.find(&String.ends_with?(&1, "Info.plist"))
    |> then(fn
      nil ->
        Path.wildcard(Path.join(project_dir, "ios/**/Info.plist"))
        |> List.first()
      path -> path
    end)
  end

  defp ios_noop(feature, reason) do
    Mix.shell().info("  * iOS #{feature}: #{reason}")
  end

  # ── Android manifest helpers ──────────────────────────────────────────────

  defp android_add_permission(project_dir, permission) do
    manifest = find_android_manifest(project_dir)

    if manifest do
      content = File.read!(manifest)
      tag = ~s(<uses-permission android:name="#{permission}"/>)

      if String.contains?(content, permission) do
        Mix.shell().info("  * skip #{manifest} (#{permission} already present)")
      else
        patched = String.replace(content, "<application", "#{tag}\n    <application", global: false)
        File.write!(manifest, patched)
        Mix.shell().info([:green, "  * patch ", :reset, manifest, " (added #{permission})"])
      end
    else
      Mix.shell().info("  * skip Android (AndroidManifest.xml not found)")
    end
  end

  defp android_add_file_provider(project_dir) do
    manifest = find_android_manifest(project_dir)

    if manifest do
      content = File.read!(manifest)

      if String.contains?(content, "FileProvider") do
        Mix.shell().info("  * skip #{manifest} (FileProvider already present)")
      else
        provider_xml =
          "        <provider\n" <>
          "            android:name=\"androidx.core.content.FileProvider\"\n" <>
          "            android:authorities=\"${applicationId}.fileprovider\"\n" <>
          "            android:exported=\"false\"\n" <>
          "            android:grantUriPermissions=\"true\">\n" <>
          "            <meta-data\n" <>
          "                android:name=\"android.support.FILE_PROVIDER_PATHS\"\n" <>
          "                android:resource=\"@xml/file_provider_paths\"/>\n" <>
          "        </provider>"
        patched = String.replace(content, "</application>",
          "#{provider_xml}\n    </application>", global: false)
        File.write!(manifest, patched)
        Mix.shell().info([:green, "  * patch ", :reset, manifest, " (added FileProvider)"])

        write_file_provider_paths(project_dir)
      end
    else
      Mix.shell().info("  * skip Android (AndroidManifest.xml not found)")
    end
  end

  defp write_file_provider_paths(project_dir) do
    xml_dir = Path.join([project_dir, "android", "app", "src", "main", "res", "xml"])
    path = Path.join(xml_dir, "file_provider_paths.xml")

    if File.exists?(path) do
      Mix.shell().info("  * skip #{path} (already exists)")
    else
      File.mkdir_p!(xml_dir)
      File.write!(path, """
      <?xml version="1.0" encoding="utf-8"?>
      <paths>
          <files-path name="mob_files" path="." />
          <cache-path name="mob_cache" path="." />
          <external-files-path name="mob_external" path="." />
      </paths>
      """)
      Mix.shell().info([:green, "  * create ", :reset, path])
    end
  end

  defp find_android_manifest(project_dir) do
    Path.wildcard(Path.join(project_dir, "android/**/AndroidManifest.xml"))
    |> Enum.reject(&String.contains?(&1, "androidTest"))
    |> List.first()
  end

  defp android_noop(feature, reason) do
    Mix.shell().info("  * Android #{feature}: #{reason}")
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp read_app_name(project_dir) do
    MobDev.Enable.read_app_name_from(Path.join(project_dir, "mix.exs"))
  rescue
    e -> Mix.raise(Exception.message(e))
  end

  defp return(val), do: val
end
