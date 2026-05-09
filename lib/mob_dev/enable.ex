defmodule MobDev.Enable do
  @moduledoc """
  Pure helpers for `mix mob.enable` — extracted for testability.

  ## LiveView bridge architecture

  Enabling LiveView mode involves three coordinated patches. Understanding why
  all three are necessary prevents subtle bugs when setting up projects manually.

  ### The two bridges

  The native WebView (iOS WKWebView / Android WebView) injects a `window.mob`
  JavaScript object into every page it loads. This object routes calls through
  the NIF bridge:

      window.mob.send(data)      // JS → NIF → Elixir handle_info
      window.mob.onMessage(fn)   // registers handler for NIF → JS messages
      window.mob._dispatch(json) // called by the NIF to deliver messages to JS

  In LiveView mode you want a different routing: JS messages should travel over
  the LiveView WebSocket so that `handle_event/3` in your LiveView receives them
  and `push_event/3` delivers server messages to JS. The MobHook replaces
  `window.mob` with a LiveView-backed version on mount:

      window.mob.send(data)      // JS → pushEvent("mob_message") → handle_event/3
      window.mob.onMessage(fn)   // registers handler for handleEvent("mob_push")
      window.mob._dispatch       // no-op: server messages arrive via handleEvent

  ### Why a DOM element is required (the non-obvious part)

  Phoenix LiveView hooks only execute their `mounted()` callback when an element
  carrying `phx-hook="MobHook"` is present in the rendered HTML *and* the
  LiveView WebSocket has connected. Registering MobHook in the `hooks:` map in
  `app.js` is necessary but not sufficient — the hook is dormant until LiveView
  finds a matching DOM element.

  Without the element:
  - MobHook never mounts
  - `window.mob` is never replaced with the LiveView version
  - `window.mob.send()` routes through the native NIF bridge instead of LiveView
  - `handle_event/3` never fires; your LiveView cannot receive JS messages

  The element is a hidden `<div>` placed immediately after the opening `<body>`
  tag in `root.html.heex`:

      <div id="mob-bridge" phx-hook="MobHook" style="display:none"></div>

  Placing it at the top of `<body>` ensures the hook mounts as early as possible,
  so `window.mob` is overridden before any page-specific JS runs.

  ### Android timing note

  iOS injects the native `window.mob` shim via `WKUserScript` at
  `.atDocumentStart` — before any page JS runs. Android injects it via
  `evaluateJavascript` in `onPageFinished` — after the page has loaded. Between
  page load and `onPageFinished` on Android, `window.mob` is undefined. In
  practice LiveView connects after `onPageFinished`, so both shims are available
  by the time the MobHook mounts. If you call `window.mob` during
  `DOMContentLoaded`, guard with `if (window.mob)`.
  """

  @mob_hook_js ~S"""
  // MobHook — Mob LiveView bridge. Added by `mix mob.enable liveview`.
  //
  // WHY THIS EXISTS: The native WebView injects window.mob pointing at the NIF
  // bridge (postMessage on iOS, JavascriptInterface on Android). In LiveView
  // mode we want window.mob to route through the LiveView WebSocket instead so
  // handle_event/3 in your LiveView receives JS messages and push_event/3
  // delivers server messages back to JS.
  //
  // This hook replaces window.mob on mount. It requires a DOM element with
  // phx-hook="MobHook" — see root.html.heex. Without that element this hook
  // never runs and messages silently use the native bridge instead.
  const MobHook = {
    mounted() {
      window.mob = {
        // JS → LiveView: arrives as handle_event("mob_message", data, socket)
        send: (data) => this.pushEvent("mob_message", data),
        // LiveView → JS: push_event(socket, "mob_push", data) calls all handlers
        onMessage: (handler) => this.handleEvent("mob_push", handler),
        // No-op in LiveView mode. The native bridge calls this to deliver
        // webview_post_message results, but in LiveView mode server messages
        // arrive via handleEvent("mob_push") instead.
        _dispatch: () => {}
      }
    }
  }
  """

  # The hidden bridge element injected into root.html.heex.
  # id="mob-bridge" is used as the idempotency sentinel — do not change it.
  @mob_bridge_element ~s(<div id="mob-bridge" phx-hook="MobHook" style="display:none"></div>)

  @doc """
  Returns the MobHook JS constant to inject into app.js.
  """
  @spec mob_hook_js() :: String.t()
  def mob_hook_js, do: @mob_hook_js

  @doc """
  Returns the hidden bridge `<div>` element that must appear in `root.html.heex`.

  See the module doc for why this element is required.
  """
  @spec mob_bridge_element() :: String.t()
  def mob_bridge_element, do: @mob_bridge_element

  @doc """
  Injects the MobHook definition and registration into `content` (the full
  text of `assets/js/app.js`).

  - Inserts the hook constant after the last top-level `import` line.
  - Registers `MobHook` in the `hooks:` option passed to `LiveSocket`.

  Returns the patched JS string. Idempotency (skip if already present) is
  handled by the calling task, not by this function.
  """
  @spec inject_mob_hook(String.t()) :: String.t()
  def inject_mob_hook(content) do
    content
    |> insert_hook_definition()
    |> register_hook_in_live_socket()
  end

  @doc """
  Injects the hidden bridge `<div>` into `content` (a `root.html.heex` file).

  The element is placed immediately after the opening `<body>` tag. This is
  the mount point for MobHook — without it the hook never executes and
  `window.mob` is never replaced with the LiveView version. See the module doc
  for the full explanation.

  Returns the patched HTML string unchanged if `id="mob-bridge"` is already
  present.
  """
  @spec inject_mob_bridge_element(String.t()) :: String.t()
  def inject_mob_bridge_element(content) do
    if String.contains?(content, "mob-bridge") do
      content
    else
      Regex.replace(
        Regex.compile!("<body([^>]*)>"),
        content,
        "<body\\1>\n    #{@mob_bridge_element}",
        global: false
      )
    end
  end

  @doc """
  Finds `root.html.heex` in a Phoenix project rooted at `project_dir`.

  Checks both the Phoenix 1.7+ convention:

      lib/<app_name>_web/components/layouts/root.html.heex

  and the pre-1.7 convention:

      lib/<app_name>_web/templates/layout/root.html.heex

  Returns the path string or `nil` if neither file exists.
  """
  @spec find_root_html(String.t(), String.t()) :: String.t() | nil
  def find_root_html(project_dir, app_name) do
    web = app_name <> "_web"

    candidates = [
      Path.join([project_dir, "lib", web, "components", "layouts", "root.html.heex"]),
      Path.join([project_dir, "lib", web, "templates", "layout", "root.html.heex"])
    ]

    Enum.find(candidates, &File.exists?/1)
  end

  @doc """
  Reads the `app:` atom from the given `mix.exs` path and returns the app
  name as a string, or raises.
  """
  @spec read_app_name_from(String.t()) :: String.t()
  def read_app_name_from(mix_exs_path) do
    case File.read(mix_exs_path) do
      {:ok, content} ->
        case Regex.run(Regex.compile!("app:\\s+:([a-z0-9_]+)"), content) do
          [_, name] -> name
          _ -> raise "Could not read app name from #{mix_exs_path}"
        end

      _ ->
        raise "Could not read #{mix_exs_path}"
    end
  end

  @doc """
  Builds a plist `<key>/<value>` entry for Info.plist injection.

  Options:
    - `type: :bool` — emits `<true/>` or `<false/>` instead of `<string>`
  """
  @spec build_plist_entry(String.t(), term(), keyword()) :: String.t()
  def build_plist_entry(key, value, opts \\ []) do
    if opts[:type] == :bool do
      "\t<key>#{key}</key>\n\t<#{value}/>"
    else
      "\t<key>#{key}</key>\n\t<string>#{value}</string>"
    end
  end

  @network_security_config_xml """
  <?xml version="1.0" encoding="utf-8"?>
  <network-security-config>
      <domain-config cleartextTrafficPermitted="true">
          <domain includeSubdomains="false">127.0.0.1</domain>
          <domain includeSubdomains="false">localhost</domain>
      </domain-config>
  </network-security-config>
  """

  @doc "Returns the XML content for the Android network security config."
  @spec network_security_config_xml() :: String.t()
  def network_security_config_xml, do: @network_security_config_xml

  @doc """
  Adds `android:networkSecurityConfig="@xml/network_security_config"` to the
  `<application>` tag in an AndroidManifest.xml string.

  Idempotent — returns the content unchanged if the attribute is already present.
  """
  @spec inject_android_network_security_config(String.t()) :: String.t()
  def inject_android_network_security_config(manifest_content) do
    if String.contains?(manifest_content, "networkSecurityConfig") do
      manifest_content
    else
      String.replace(
        manifest_content,
        Regex.compile!("(<application\\b)"),
        "\\1\n        android:networkSecurityConfig=\"@xml/network_security_config\"",
        global: false
      )
    end
  end

  # ── Pythonx feature ───────────────────────────────────────────────────────

  @pythonx_dep_version "~> 0.4"

  @doc """
  Patches `mix.exs` content to add `{:pythonx, "#{@pythonx_dep_version}"}` to the
  `deps` list when missing. Idempotent.

  Returns the (possibly-modified) content. Returns the original content
  unchanged when there's no recognizable `defp deps do [` block — caller is
  expected to fall back to a friendly "couldn't find deps block" message.
  """
  @spec inject_pythonx_dep(String.t()) :: String.t()
  def inject_pythonx_dep(content) do
    cond do
      String.contains?(content, ":pythonx") ->
        content

      Regex.match?(~r/defp\s+deps\s+do\s*\[/, content) ->
        Regex.replace(
          ~r/(defp\s+deps\s+do\s*\[)/,
          content,
          ~s(\\1\n      {:pythonx, "#{@pythonx_dep_version}"},),
          global: false
        )

      true ->
        content
    end
  end

  @doc """
  Patches `config/config.exs` content with the Pythonx `:uv_init` desktop
  venv config.

  No gate — the same `:uv_init` value lands at compile time AND runtime,
  so Pythonx's `validate_compile_env` check is satisfied unconditionally.
  On mobile, the user's `Mob.App.on_start/0` skips
  `Application.ensure_all_started(:pythonx)` and calls `Pythonx.init/4`
  directly, which doesn't trigger uv. See the next-steps message printed
  by `mix mob.enable python`.

  Idempotent — returns content unchanged when `:pythonx` config already
  present.
  """
  @spec inject_pythonx_uv_init_gate(String.t(), String.t()) :: String.t()
  def inject_pythonx_uv_init_gate(content, app_name) when is_binary(app_name) do
    if String.contains?(content, ":pythonx") do
      content
    else
      content <> pythonx_uv_init_default_block(app_name)
    end
  end

  defp pythonx_uv_init_default_block(app_name) do
    """

    # Pythonx desktop venv setup (added by `mix mob.enable python`).
    # The same value lands at compile time AND runtime so Pythonx's
    # validate_compile_env check is satisfied. On mobile,
    # `Mob.App.on_start/0` skips `Application.ensure_all_started(:pythonx)`
    # and calls `Pythonx.init/4` directly with bundled paths — uv never
    # runs on device.
    config :pythonx, :uv_init,
      pyproject_toml: \"\"\"
      [project]
      name = "#{app_name}"
      version = "0.1.0"
      requires-python = "==3.13.*"
      dependencies = []
      \"\"\"
    """
  end

  @doc """
  Inspects the project's existing native build templates for the markers
  `mix mob.deploy --native` expects when Pythonx is enabled. Returns a
  list of `{relative_path, missing_marker}` tuples for every file that
  exists but is missing the marker. An empty list means everything looks
  fresh.

  We deliberately do not auto-patch — these files are typically
  hand-customized after `mix mob.new`, and silently inserting blocks is
  riskier than asking the user to copy from the template.

  Files that don't exist yet (e.g. a project that never generated an
  ios/build.sh) are skipped — this is "stale-template detection," not
  "missing-platform detection."
  """
  @spec detect_stale_pythonx_templates(Path.t(), String.t()) ::
          [{String.t(), String.t()}]
  def detect_stale_pythonx_templates(project_dir, _app_name) do
    fixed = [
      {Path.join(["ios", "build.sh"]), "Cross-compiling libpythonx.so"},
      {Path.join(["ios", "build_device.sh"]), "Cross-compiling libpythonx.so"},
      {Path.join(["android", "app", "src", "main", "jni", "CMakeLists.txt"]), "enif_keepalive.c"}
    ]

    # Java package layout varies by app. Glob instead of guessing.
    main_activities =
      Path.wildcard(Path.join(project_dir, "android/app/src/main/java/**/MainActivity.kt"))

    activity_checks =
      Enum.map(main_activities, fn abs ->
        rel = Path.relative_to(abs, project_dir)
        {rel, "extractPythonAssetsIfNeeded"}
      end)

    (fixed ++ activity_checks)
    |> Enum.flat_map(fn {rel, marker} ->
      abs =
        if Path.type(rel) == :absolute,
          do: rel,
          else: Path.join(project_dir, rel)

      cond do
        not File.exists?(abs) -> []
        File.read!(abs) =~ marker -> []
        true -> [{to_string(rel), marker}]
      end
    end)
  end

  @doc """
  Returns the source for the `<App>.PythonPaths` module that
  `mix mob.enable python` writes to `lib/<app>/python_paths.ex`.

  Pure — no filesystem access. The generated module supports iOS
  (paths under `<otp_root>/python/`) and Android (paths from
  `MOB_PYTHON_HOME` / `MOB_PYTHON_DL` env vars set by the user's
  `MainActivity.kt` before BEAM startup).
  """
  @spec python_paths_module_template(String.t()) :: String.t()
  def python_paths_module_template(module_name) when is_binary(module_name) do
    """
    defmodule #{module_name}.PythonPaths do
      @moduledoc \"\"\"
      Detects bundled CPython at runtime and reports the paths needed
      for `Pythonx.init/4` (dl_path, home_path, stdlib_path).

      Pure detection logic — see your app's `App` module for how the
      result is fed into `Pythonx.init/4` at boot.

      ## Per-platform layout

        * **iOS**: ios/build_device.sh bundles `Python.framework`,
          stdlib, and lib-dynload at `<App>.app/otp/python/`. Detection
          reads `:code.root_dir/0` and inspects that subtree.

        * **Android**: `mix mob.deploy --native` bundles libpython.so
          into the APK's `jniLibs/<abi>/` (auto-extracted by the
          installer to `applicationInfo.nativeLibraryDir`) and
          stdlib + lib-dynload into `assets/python/` (extracted to
          `filesDir/python/` by `MainActivity.onCreate` on first
          launch). MainActivity exports the resolved paths via
          `MOB_PYTHON_DL` and `MOB_PYTHON_HOME` env vars before
          starting the BEAM.

      ## Returns

        * `:desktop` — no platform bundle found. Pythonx's
          `Application.start/2` handles desktop init via `:uv_init`.
        * `{:ios, paths}` — iOS bundle present; pass into
          `Pythonx.init/4`.
        * `{:android, paths}` — Android bundle present; pass into
          `Pythonx.init/4`.
        * `{:partial, missing}` — bundle is incomplete; surface to
          the user.
      \"\"\"

      @type python_paths :: %{
              dl_path: String.t(),
              home_path: String.t(),
              stdlib_path: String.t()
            }

      @type detection ::
              :desktop
              | {:ios, python_paths()}
              | {:android, python_paths()}
              | {:partial, [atom()]}

      @python_version "python3.13"

      @doc \"\"\"
      Decide which platform's bundle (if any) is present. `otp_root` is
      typically `to_string(:code.root_dir())` and is used for the iOS
      layout — Android resolution comes from env vars MainActivity
      exports.
      \"\"\"
      @spec detect(String.t()) :: detection()
      def detect(otp_root) when is_binary(otp_root) do
        cond do
          File.dir?(Path.join(otp_root, "python")) ->
            paths = build_ios_paths(otp_root)

            case missing(paths) do
              [] -> {:ios, paths}
              missing -> {:partial, missing}
            end

          android_python?() ->
            paths = build_android_paths()

            case missing(paths) do
              [] -> {:android, paths}
              missing -> {:partial, missing}
            end

          true ->
            :desktop
        end
      end

      @doc \"\"\"
      Construct the iOS path map under `<otp_root>/python/`. Pure —
      no filesystem access.
      \"\"\"
      @spec build_ios_paths(String.t()) :: python_paths()
      def build_ios_paths(otp_root) when is_binary(otp_root) do
        python_dir = Path.join(otp_root, "python")

        %{
          dl_path: Path.join([python_dir, "Python.framework", "Python"]),
          home_path: python_dir,
          stdlib_path: Path.join([python_dir, "lib", @python_version])
        }
      end

      @doc \"\"\"
      Construct the Android path map from `MOB_PYTHON_HOME` and
      `MOB_PYTHON_DL` env vars. Returns the empty-string default when
      vars aren't set so callers see :partial rather than crashing.

      Android stdlib lives at `<home>/lib/python3.13/` to match
      Python's PYTHONHOME bootstrap contract (Python looks for
      `encodings/` and friends at that path before sys.path is set up).
      \"\"\"
      @spec build_android_paths() :: python_paths()
      def build_android_paths do
        home = System.get_env("MOB_PYTHON_HOME") || ""
        dl = System.get_env("MOB_PYTHON_DL") || ""

        %{
          dl_path: dl,
          home_path: home,
          stdlib_path: if(home == "", do: "", else: Path.join([home, "lib", @python_version]))
        }
      end

      @doc \"\"\"
      Returns the keys (`:dl_path` / `:home_path` / `:stdlib_path`)
      whose artifacts are absent on disk. Empty list means the bundle
      is complete.
      \"\"\"
      @spec missing(python_paths()) :: [atom()]
      def missing(%{dl_path: dl, home_path: home, stdlib_path: stdlib}) do
        [
          {:dl_path, File.exists?(dl)},
          {:home_path, File.dir?(home)},
          {:stdlib_path, File.dir?(stdlib)}
        ]
        |> Enum.reject(fn {_, present?} -> present? end)
        |> Enum.map(&elem(&1, 0))
      end

      defp android_python? do
        System.get_env("MOB_PYTHON_HOME") != nil
      end
    end
    """
  end

  # ── Private ───────────────────────────────────────────────────────────────

  defp insert_hook_definition(content) do
    lines = String.split(content, "\n")

    last_import_idx =
      lines
      |> Enum.with_index()
      |> Enum.filter(fn {line, _} -> String.starts_with?(String.trim(line), "import ") end)
      |> Enum.map(fn {_, idx} -> idx end)
      |> List.last()

    insert_at = (last_import_idx || -1) + 1
    hook_lines = String.split(@mob_hook_js, "\n")

    (Enum.take(lines, insert_at) ++ [""] ++ hook_lines ++ Enum.drop(lines, insert_at))
    |> Enum.join("\n")
  end

  defp register_hook_in_live_socket(content) do
    cond do
      String.contains?(content, "hooks: {}") ->
        String.replace(content, "hooks: {}", "hooks: {MobHook}")

      Regex.match?(Regex.compile!("hooks:\\s*\\{"), content) ->
        Regex.replace(Regex.compile!("(hooks:\\s*\\{)"), content, "\\1MobHook, ", global: false)

      true ->
        Regex.replace(
          Regex.compile!("(new LiveSocket\\([^)]+)\\)"),
          content,
          fn full, prefix ->
            if String.contains?(full, "{") do
              String.replace(full, "}", ", hooks: {MobHook}}", global: false)
            else
              "#{prefix}, {hooks: {MobHook}})"
            end
          end,
          global: false
        )
    end
  end
end
