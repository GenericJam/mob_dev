defmodule MobDev.Adopt.Patcher do
  @moduledoc """
  Pure helpers for the `mix mob.adopt` Elixir-source patches and
  content generators: the LiveView bridge patches (`assets/js/app.js`
  MobHook + `root.html.heex` bridge div), the `mix.exs` dep injection,
  and the generated `mob_screen.ex` / `mob_app.ex` / `mob.exs` /
  `src/<app>.erl` contents.

  Duplicated from `MobNew.LiveViewPatcher` (mob_new, the project
  generator archive). Only the transitive closure `mix mob.adopt`
  actually exercises was copied — `mob.new`'s notes-app generators
  (`repo_content`, `note_content`, the LiveView starter screens, …)
  stay in mob_new. Phase 5 of `build_system_migration.md` reunifies the
  two copies behind a single Igniter-based path; until then both repos
  carry their own copy (mob_new can't depend on mob_dev — it's a
  self-contained Mix archive; see `ArchiveSelfContainedTest`).

  ## Compile-time regex

  Like the mob_new original, this module compiles regexes at runtime via
  `Regex.compile!/1` rather than `~r//` literals — the `~r//` form bakes
  a bytecode pattern that calls `:re.import/1`, removed in OTP 28.0 (the
  version Mob's bundled iOS/Android tarballs ship). See mob `AGENTS.md`
  rule #9.
  """

  @mob_hook_js ~S"""
  // MobHook — Mob LiveView bridge. Added by `mix mob.new --liveview`.
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

  @mob_bridge_element ~s(<div id="mob-bridge" phx-hook="MobHook" style="display:none"></div>)

  # ── Public API ────────────────────────────────────────────────────────────────

  @doc "Returns the hidden bridge element string (for test assertions)."
  @spec mob_bridge_element() :: String.t()
  def mob_bridge_element, do: @mob_bridge_element

  @doc "Returns the MobHook JS string (for tests and warning messages)."
  @spec mob_hook_js() :: String.t()
  def mob_hook_js, do: @mob_hook_js

  @doc """
  Injects the MobHook definition and registration into the given `app.js` content.

  Idempotent: returns unchanged content if MobHook is already present.
  """
  @spec inject_mob_hook(String.t()) :: String.t()
  def inject_mob_hook(content) do
    if String.contains?(content, "MobHook") do
      content
    else
      content
      |> insert_hook_definition()
      |> register_hook_in_live_socket()
    end
  end

  @doc """
  Injects the hidden bridge `<div>` immediately after the opening `<body>` tag.

  Idempotent: returns unchanged content if mob-bridge is already present.
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
  Injects mob / mob_dev dependencies into the `deps/0` function in `mix.exs` content.

  `mob_dep` and `mob_dev_dep` are dependency tuple strings (already formatted —
  e.g. `~s({:mob, "~> 0.5"})` or `~s({:mob, path: "/path"})`). They are parsed
  back to AST and inserted at the end of the user's deps list.

  Idempotent: no-op if `:mob` is already declared in the user's deps list,
  regardless of indentation or trailing-comma shape.

  ## Implementation note

  Deps are injected by an AST walk (robust against Phoenix-version / formatter
  variation), then serialized with **stdlib only** (`Macro.to_string` +
  `Code.format_string!`). The mob_new original is reachable from `mix mob.new`
  running as a Mix *archive*, and archives don't bundle runtime deps — so it
  must not call any non-stdlib module (Sourceror). Preserved here verbatim.
  """
  @spec inject_deps(String.t(), String.t(), String.t()) :: String.t()
  def inject_deps(content, mob_dep, mob_dev_dep) do
    case inject_deps_via_ast(content, mob_dep, mob_dev_dep) do
      {:ok, patched} -> patched
      :unchanged -> content
    end
  end

  defp inject_deps_via_ast(content, mob_dep, mob_dev_dep) do
    with {:ok, ast} <- Code.string_to_quoted(content),
         false <- mob_already_present?(ast),
         {:ok, mob_quoted} <- parse_dep_tuple(mob_dep),
         {:ok, mob_dev_quoted} <- parse_dep_tuple(mob_dev_dep),
         {:ok, patched_ast} <- append_to_deps(ast, [mob_quoted, mob_dev_quoted]) do
      {:ok, quoted_to_source(patched_ast)}
    else
      # mob already declared — no-op for idempotency
      true ->
        :unchanged

      # No deps/0 function, a parse failure, or anything unexpected — bail out
      # without mangling the file. Callers see `content` unchanged.
      _ ->
        :unchanged
    end
  end

  defp parse_dep_tuple(tuple_str), do: Code.string_to_quoted(tuple_str)

  # Serialize the patched AST back to source with **stdlib only** — NOT Sourceror.
  # Trade-off: Macro.to_string reformats and drops comments — acceptable for a
  # freshly generated mix.exs (no user comments to preserve yet); format_string!
  # normalizes the rest.
  defp quoted_to_source(ast) do
    ast
    |> Macro.to_string()
    |> Code.format_string!()
    |> IO.iodata_to_binary()
    |> Kernel.<>("\n")
  end

  defp mob_already_present?(ast) do
    {_, found?} =
      Macro.prewalk(ast, false, fn
        # A dep tuple whose first element is :mob — both `{:mob, "~> 0.5"}` and
        # `{:mob, path: "…"}` parse to a 2-tuple `{:mob, _}` in standard quoted form.
        {:mob, _} = node, _acc ->
          {node, true}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  defp append_to_deps(ast, new_dep_asts) do
    {patched, found?} =
      Macro.prewalk(ast, false, fn
        # Find `def(p) deps do <body> end` (the `, do:` shorthand desugars to the
        # same `[do: body]`) and append the new deps to the list in <body>.
        {defp_or_def, meta, [{:deps, _, args} = head, [{:do, body}]]}, found?
        when defp_or_def in [:def, :defp] and (is_nil(args) or args == []) ->
          new_body = append_to_list_node(body, new_dep_asts)
          {{defp_or_def, meta, [head, [{:do, new_body}]]}, found? or new_body != body}

        node, acc ->
          {node, acc}
      end)

    if found?, do: {:ok, patched}, else: {:error, :no_deps_function}
  end

  defp append_to_list_node(list, new_items) when is_list(list), do: list ++ new_items
  defp append_to_list_node(other, _new_items), do: other

  @doc """
  Adds `{:ecto_sqlite3, "~> 0.18"}` to the deps list in `mix.exs` content
  if not already present. The generated `mob_app.ex` (LiveView flavour)
  calls `Application.ensure_all_started(:ecto_sqlite3)` and runs
  `Ecto.Migrator` on-device, so the dep is required whenever that
  template is emitted.

  Idempotent — no-op when `ecto_sqlite3` is already in the deps string.
  """
  @spec inject_ecto_sqlite3(String.t()) :: String.t()
  def inject_ecto_sqlite3(content) do
    if String.contains?(content, "ecto_sqlite3") do
      content
    else
      Regex.replace(
        Regex.compile!("(defp deps do\\s*\\[)"),
        content,
        ~s[\\1\n      {:ecto_sqlite3, "~> 0.18"},],
        global: false
      )
    end
  end

  @doc """
  Generates `MobScreen` content for `mix mob.adopt`.

  The generated module reads the WebView URL from application config:

      config :mob, host_url: "https://your-app.example.com/"

  Default if unset is `http://127.0.0.1:4000/`, suitable for on-device
  BEAM hitting a local Phoenix endpoint. `mix mob.adopt --host-url
  <URL>` writes the config entry so the user doesn't need to edit
  `config/config.exs` by hand.
  """
  @spec mob_screen_content_install(String.t()) :: String.t()
  def mob_screen_content_install(module_name) do
    """
    defmodule #{module_name}.MobScreen do
      @moduledoc \"\"\"
      Mob.Screen that wraps the host Phoenix app in a native WebView.

      Reads the URL from `config :mob, :host_url` (default
      `http://127.0.0.1:4000/`) so the same module works for the
      on-device BEAM (localhost) or a remote deployment (set
      `config :mob, host_url: "https://your-app.example.com/"`).
      \"\"\"
      use Mob.Screen

      @default_host_url "http://127.0.0.1:4000/"

      def host_url do
        Application.get_env(:mob, :host_url, @default_host_url)
      end

      def mount(_params, _session, socket) do
        {:ok, socket}
      end

      def render(_assigns) do
        Mob.UI.webview(
          url: host_url(),
          show_url: false
        )
      end
    end
    """
  end

  @doc """
  Generates a thin-client `<App>.MobApp` for projects where the BEAM on
  device does NOT host Phoenix/Hologram/game state — instead the WebView
  points at a deployed Phoenix server and the device's BEAM is just the
  native interop layer.

  Produced when `mix mob.adopt --no-live-view` is invoked. The thin
  variant uses `use Mob.App` with `navigation/1` + `on_start/0`
  callbacks (the same shape `mix mob.new` generates for native mode),
  rather than the LV-flavored `def start do ... end` that boots the
  host Phoenix endpoint on-device.
  """
  @spec mob_app_content_thin(String.t(), String.t()) :: String.t()
  def mob_app_content_thin(module_name, app_name) do
    """
    defmodule #{module_name}.MobApp do
      @moduledoc \"\"\"
      Thin-client on-device BEAM entry. The native shell launches the
      BEAM, this module configures DNS, opens `MobScreen` (which loads
      a WebView at `config :mob, :host_url`), and starts Erlang
      distribution so `mix mob.connect` can attach.

      Does NOT call `Application.ensure_all_started(:#{app_name})` — the
      host's `#{module_name}.Application` belongs on the deployed server,
      not on the phone. If you later decide you DO want the host app
      running on-device (full on-device Phoenix), swap this for the
      LiveView-flavoured `mob_app.ex` template generated by
      `mix mob.adopt` without `--no-live-view`.
      \"\"\"

      use Mob.App

      @impl Mob.App
      def navigation(_platform) do
        stack(:main, root: #{module_name}.MobScreen)
      end

      @impl Mob.App
      def on_start do
        # Pure-BEAM DNS — iOS's `inet_gethost` port program is broken;
        # this flips Erlang's lookup chain to `[:file, :dns]` with
        # Google + Cloudflare as fallback resolvers. See
        # `Mob.DNS.configure_pure_beam/1` for tuning.
        Mob.DNS.configure_pure_beam()

        # Open the WebView pointed at the configured host URL.
        Mob.Screen.start_root(#{module_name}.MobScreen)

        # Distribution for `mix mob.connect`. Optional; remove if you
        # don't need on-device IEx.
        Mob.Dist.ensure_started(
          node: :"#{app_name}_android@127.0.0.1",
          cookie: :mob_secret
        )
      end
    end
    """
  end

  @doc """
  Generates mob.exs config content for a LiveView project.
  """
  @spec mob_exs_content(String.t(), String.t()) :: String.t()
  def mob_exs_content(mob_exs_mob_dir, mob_exs_elixir_lib) do
    """
    # mob.exs — Mob build environment configuration.
    # Set these paths for your machine. Not committed to version control.
    # (Add mob.exs to .gitignore if you share this project.)
    #
    # OTP runtimes for Android and iOS are downloaded automatically by `mix mob.install`.

    import Config

    config :mob_dev,
      # Path to the mob library repo (native source files for iOS/Android builds).
      mob_dir: #{mob_exs_mob_dir},

      # Path to your Elixir lib dir (e.g. ~/.local/share/mise/installs/elixir/1.18.4-otp-28/lib).
      elixir_lib: #{mob_exs_elixir_lib}

    # The on-device LiveView endpoint port. Defaults to a deterministic
    # value derived from the app name (4200..4999) so multiple Mob LV apps
    # installed on the same device don't collide on a single hardcoded
    # port. Uncomment + set this only if you need a fixed value (e.g.
    # because your test harness pins one).
    # config :mob, liveview_port: 4200
    """
  end

  @doc """
  Generates the `mob_app.ex` entry point for a LiveView project.

  This module is called from the Erlang bootstrap (`src/app_name.erl`) instead
  of a native `Mob.App` module. It starts the Phoenix OTP application (which
  boots the endpoint) and then starts `MobScreen` to open the WebView.

  Unlike native Mob apps, this does NOT `use Mob.App` — Phoenix owns the
  supervision tree. Mob is wired in at the BEAM entry level only.

  `secret_key_base` and `signing_salt` are embedded directly because Mix config
  files (`config/*.exs`) are not loaded on-device — `Application.put_env/3` is
  the only way to configure the endpoint before `ensure_all_started/1` runs.
  The on-device port defaults to a per-app hash (4200..4999) — see
  `default_liveview_port/0` for the collision rationale.
  """
  @spec mob_live_app_content(String.t(), String.t(), String.t(), String.t()) :: String.t()
  def mob_live_app_content(module_name, app_name, secret_key_base, signing_salt) do
    """
    defmodule #{module_name}.MobApp do
      @moduledoc \"\"\"
      BEAM entry point for the LiveView Mob app.

      Called from `src/#{app_name}.erl` by the iOS/Android native launcher.
      Starts the Phoenix OTP application (which boots the endpoint and all
      supervision trees), then opens the MobScreen WebView pointing at
      http://127.0.0.1:<liveview_port>/ (port set in mob.exs).

      This module is the LiveView equivalent of `Mob.App`. It does not use
      `use Mob.App` because Phoenix owns the supervision tree. Mob is added
      only as a WebView wrapper around the running Phoenix endpoint.
      \"\"\"

      def start do
        Mob.NativeLogger.install()

        # On-device, Mix config files are not loaded — set Phoenix endpoint
        # config explicitly before starting applications so the endpoint knows
        # its port, adapter, and secret key base. Watchers and code reload
        # are omitted (no dev tools on-device).
        #
        # Port default is hashed from the app name into 4200..4999 so two
        # Mob LV apps installed on the same device don't fight over a
        # single hardcoded port (Bandit returns :eaddrinuse, the endpoint
        # supervisor crashes, BEAM dies). With 800 candidate ports and
        # `phash2`'s good distribution, collision odds are p<0.5% even
        # at five installed apps. Override in mob.exs by setting
        # `config :mob, liveview_port: <port>` if you need a specific value.
        liveview_port = Application.get_env(:mob, :liveview_port, default_liveview_port())
        Application.put_env(:mob, :liveview_port, liveview_port)
        Application.put_env(:#{app_name}, #{module_name}Web.Endpoint,
          adapter: Bandit.PhoenixAdapter,
          http: [ip: {127, 0, 0, 1}, port: liveview_port],
          check_origin: false,
          debug_errors: true,
          server: true,
          secret_key_base: "#{secret_key_base}",
          pubsub_server: #{module_name}.PubSub,
          live_view: [signing_salt: "#{signing_salt}"],
          code_reloader: false,
          watchers: [],
          live_reload: [patterns: []]
        )

        # esbuild + tailwind are dev-time asset compilers. They get pulled in
        # as runtime apps but don't have access to their host config (which
        # lives in `config/dev.exs`, not bundled). Set their versions here so
        # the on-device boot log stays clean — they never actually run.
        # Versions match Phoenix 1.7's defaults; bump alongside `mix phx.new`.
        Application.put_env(:esbuild, :version, "0.25.0")
        Application.put_env(:tailwind, :version, "3.4.6")

        # ecto_sqlite3 must be started before #{app_name} so its NIF is loaded
        # before the Repo supervisor tries to open the database.
        {:ok, _} = Application.ensure_all_started(:ecto_sqlite3)

        # Start the Phoenix application and all its children.
        # This boots the endpoint, repo, pubsub, telemetry, etc.
        {:ok, _} = Application.ensure_all_started(:#{app_name})

        # Run any pending Ecto migrations. MOB_BEAMS_DIR is set by the native
        # launcher to the flat deploy directory; migrations are copied there at
        # build time. Falls back to Application.app_dir when running in dev.
        Ecto.Migrator.with_repo(#{module_name}.Repo, fn _repo ->
          Ecto.Migrator.run(#{module_name}.Repo, migrations_dir(), :up, all: true)
        end)

        # ComponentRegistry is normally started by Mob.App but we bypass that.
        # Start it standalone so Mob.Screen.start_root can render components.
        {:ok, _} = Mob.ComponentRegistry.start_link()

        # Start the MobScreen WebView pointing at the local Phoenix endpoint.
        # The WebView loads http://127.0.0.1:<liveview_port>/ (see mob.exs).
        Mob.Screen.start_root(#{module_name}.MobScreen)

        # Start Erlang distribution so `mix mob.connect` can attach.
        Mob.Dist.ensure_started(node: :"#{app_name}_android@127.0.0.1", cookie: :mob_secret)
      end

      defp migrations_dir do
        case System.get_env("MOB_BEAMS_DIR") do
          nil -> Application.app_dir(:#{app_name}, "priv/repo/migrations")
          beams_dir -> Path.join([beams_dir, "priv", "repo", "migrations"])
        end
      end

      # 4200..4999 inclusive — small enough to leave room above the standard
      # dev range, large enough that birthday-paradox collisions are rare for
      # any reasonable number of installed Mob LV apps. Deterministic, so the
      # WebView URL stays stable across restarts.
      defp default_liveview_port do
        4200 + :erlang.phash2(:#{app_name}, 800)
      end
    end
    """
  end

  @doc """
  Generates the Erlang bootstrap for a LiveView project.

  Calls `ModuleName.MobApp.start()` instead of `ModuleName.App.start()`.
  """
  @spec erlang_entry_content(String.t(), String.t()) :: String.t()
  def erlang_entry_content(module_name, app_name) do
    """
    %% #{app_name}.erl — BEAM bootstrap for #{module_name} (LiveView mode).
    %% Called by the iOS/Android native launcher via -eval '#{app_name}:start().'.
    %% Starts the OTP ecosystem, then starts Phoenix + MobScreen via MobApp.
    -module(#{app_name}).
    -export([start/0]).

    start() ->
        step(1, fun() -> application:start(compiler) end),
        step(2, fun() -> application:start(elixir)   end),
        step(3, fun() -> application:start(logger)   end),
        step(4, fun() -> mob_nif:platform()          end),
        step(5, fun() -> 'Elixir.#{module_name}.MobApp':start() end),
        timer:sleep(infinity).

    step(N, Fun) ->
        mob_nif:log("step " ++ integer_to_list(N) ++ " starting"),
        Result = (catch Fun()),
        mob_nif:log("step " ++ integer_to_list(N) ++ " => " ++
                    lists:flatten(io_lib:format("~p", [Result]))).
    """
  end

  # ── Private ───────────────────────────────────────────────────────────────────

  # Insert `hooks: {MobHook}` before the closing `})` of the LiveSocket call.
  # Works by tracking brace depth line by line — avoids regex fights with nested braces.
  defp insert_hooks_before_closing(content) do
    lines = String.split(content, "\n")

    {result_lines, _} =
      Enum.reduce(lines, {[], :before}, fn line, {acc, state} ->
        reduce_line(line, acc, state)
      end)

    Enum.join(result_lines, "\n")
  end

  defp reduce_line(line, acc, :before) do
    if String.contains?(line, "new LiveSocket(") do
      depth = count_brace_depth(line)

      if depth <= 0 do
        patched =
          Regex.replace(Regex.compile!("\\)\\s*$"), line, ", {hooks: {MobHook}})", global: false)

        {acc ++ [patched], :done}
      else
        {acc ++ [line], {:in_call, depth}}
      end
    else
      {acc ++ [line], :before}
    end
  end

  defp reduce_line(line, acc, {:in_call, depth}) do
    new_depth = depth + count_brace_depth(line)
    trimmed = String.trim(line)

    if new_depth <= 0 and (trimmed == "})" or String.starts_with?(trimmed, "})")) do
      {insert_hooks_line(acc, line), :done}
    else
      {acc ++ [line], {:in_call, new_depth}}
    end
  end

  defp reduce_line(line, acc, :done), do: {acc ++ [line], :done}

  defp insert_hooks_line(acc, closing_line) do
    last_acc = List.last(acc)
    last_trimmed = if last_acc, do: String.trim_trailing(last_acc), else: ""

    acc_with_comma =
      if String.ends_with?(last_trimmed, ",") do
        acc
      else
        List.update_at(acc, -1, fn l -> String.trim_trailing(l) <> "," end)
      end

    acc_with_comma ++ ["  hooks: {MobHook}", closing_line]
  end

  # Returns the net brace depth change for a line (opens minus closes).
  defp count_brace_depth(line) do
    opens = line |> :binary.matches("{") |> length()
    closes = line |> :binary.matches("}") |> length()
    opens - closes
  end

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
        # hooks key already exists — prepend MobHook to it
        Regex.replace(
          Regex.compile!("(hooks:\\s*\\{)"),
          content,
          "\\1MobHook, ",
          global: false
        )

      true ->
        # No hooks key. Insert `hooks: {MobHook}` into the LiveSocket options.
        #
        # Strategy: process line by line. Once we see `new LiveSocket(`, track
        # nesting depth. When we find the line that closes the options object
        # (depth goes to 0 with `})`), insert `hooks: {MobHook}` before it.
        #
        # This handles both single-line and multiline LiveSocket calls correctly
        # without fighting nested-brace regex limitations.
        insert_hooks_before_closing(content)
    end
  end
end
