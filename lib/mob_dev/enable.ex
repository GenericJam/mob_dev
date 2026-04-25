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
  def mob_hook_js, do: @mob_hook_js

  @doc """
  Returns the hidden bridge `<div>` element that must appear in `root.html.heex`.

  See the module doc for why this element is required.
  """
  def mob_bridge_element, do: @mob_bridge_element

  @doc """
  Injects the MobHook definition and registration into `content` (the full
  text of `assets/js/app.js`).

  - Inserts the hook constant after the last top-level `import` line.
  - Registers `MobHook` in the `hooks:` option passed to `LiveSocket`.

  Returns the patched JS string. Idempotency (skip if already present) is
  handled by the calling task, not by this function.
  """
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
  def inject_mob_bridge_element(content) do
    if String.contains?(content, "mob-bridge") do
      content
    else
      Regex.replace(
        ~r/<body([^>]*)>/,
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
  def read_app_name_from(mix_exs_path) do
    case File.read(mix_exs_path) do
      {:ok, content} ->
        case Regex.run(~r/app:\s+:([a-z0-9_]+)/, content) do
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
  def network_security_config_xml, do: @network_security_config_xml

  @doc """
  Adds `android:networkSecurityConfig="@xml/network_security_config"` to the
  `<application>` tag in an AndroidManifest.xml string.

  Idempotent — returns the content unchanged if the attribute is already present.
  """
  def inject_android_network_security_config(manifest_content) do
    if String.contains?(manifest_content, "networkSecurityConfig") do
      manifest_content
    else
      String.replace(
        manifest_content,
        ~r/(<application\b)/,
        "\\1\n        android:networkSecurityConfig=\"@xml/network_security_config\"",
        global: false
      )
    end
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

      Regex.match?(~r/hooks:\s*\{/, content) ->
        Regex.replace(~r/(hooks:\s*\{)/, content, "\\1MobHook, ", global: false)

      true ->
        Regex.replace(
          ~r/(new LiveSocket\([^)]+)\)/,
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
