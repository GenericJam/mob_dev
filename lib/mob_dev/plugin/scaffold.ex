defmodule MobDev.Plugin.Scaffold do
  @moduledoc """
  Pure templates + name conversions behind `mix mob.new_plugin`.

  Inputs are a snake_case plugin name (e.g. `"mob_demo_widget"`) and a tier
  (0–4). Output is a list of `{relative_path, content_string}` pairs the Mix
  task writes to disk. All conversions live here so the task stays thin and
  the templates are unit-testable without filesystem I/O.

  Templates mirror the on-device-verified prototypes (`mob_palette_demo` t0,
  `mob_demo_haptic_extras` t1, `mob_demo_signature_pad` t2,
  `mob_demo_kv_browser` t3, `mob_demo_subapp` t4) so a freshly scaffolded plugin
  compiles + activates by the same path the prototypes already prove.
  """

  @type tier :: 0 | 1 | 2 | 3 | 4
  @type file :: {Path.t(), String.t()}

  @supported_tiers [0, 1, 2, 3, 4]

  # Mob version requirement baked into a freshly scaffolded plugin when the
  # installed mob can't be detected (e.g. scaffolding outside a host app).
  # `detect_mob_requirement/0` prefers the real installed version; this is the
  # floor. Keep it tracking the current published mob major.minor — a Scaffold
  # test pins it so it can't silently lag a mob release (see issue #21).
  @fallback_mob_requirement "~> 0.7"

  # Names that pass the snake_case regex but produce a broken or non-buildable
  # plugin project. `nil`/`true`/`false` are the killers: the scaffold emits
  # `app: :<name>` in mix.exs, and Mix treats `:nil`/`:false` as "no app name"
  # (`mix compile` then dies with "Cannot access build without an application
  # name"); `:true` builds a project whose `config :mob, :plugins, [:true]`
  # entry is the boolean. The remaining entries are Elixir reserved words —
  # rejected to mirror `mix new`'s `check_application_name!/2`, since a module
  # or atom named after a keyword is a footgun for downstream `alias`/match.
  @reserved_names ~w(
    nil true false
    when and or not in fn do end catch rescue after else
    case cond if unless try receive with for
    def defp defmodule defmacro defmacrop defprotocol defimpl
    import alias require use quote unquote super
  )

  @doc """
  Validates a plugin name (must be a snake_case atom-friendly identifier).
  """
  @spec validate_name(String.t()) :: :ok | {:error, String.t()}
  def validate_name(name) when is_binary(name) do
    cond do
      name == "" ->
        {:error, "plugin name is required"}

      not Regex.match?(~r/^[a-z][a-z0-9_]*$/, name) ->
        {:error,
         "plugin name #{inspect(name)} must be snake_case (lowercase ASCII letters, digits, underscores; starts with a letter)"}

      name in @reserved_names ->
        {:error,
         "plugin name #{inspect(name)} is a reserved word; choose another name — " <>
           "it is used verbatim as the OTP app atom and module, so it would produce " <>
           "a project that does not build (e.g. mix treats `app: :nil`/`:false` as no app name)"}

      true ->
        :ok
    end
  end

  def validate_name(_), do: {:error, "plugin name must be a string"}

  @doc "Validates a tier (0 through 4)."
  @spec validate_tier(integer()) :: :ok | {:error, String.t()}
  def validate_tier(t) when t in @supported_tiers, do: :ok

  def validate_tier(t),
    do: {:error, "tier #{inspect(t)} not supported; expected one of #{inspect(@supported_tiers)}"}

  @doc """
  Converts `"mob_demo_widget"` → `"MobDemoWidget"`.
  """
  @spec module_name(String.t()) :: String.t()
  def module_name(name) when is_binary(name) do
    name
    |> String.split("_", trim: true)
    |> Enum.map(&String.capitalize/1)
    |> Enum.join()
  end

  @doc """
  Builds a `"~> MAJOR.MINOR"` mob version requirement from a concrete version.

  `nil` (mob not detectable) yields the compiled `@fallback_mob_requirement`.
  Pure so the derivation is unit-testable independent of what's installed.
  """
  @spec mob_requirement(String.t() | Version.t() | nil) :: String.t()
  def mob_requirement(nil), do: @fallback_mob_requirement
  def mob_requirement(%Version{major: major, minor: minor}), do: "~> #{major}.#{minor}"

  def mob_requirement(version) when is_binary(version),
    do: mob_requirement(Version.parse!(version))

  @doc """
  Resolves the mob version requirement for a freshly scaffolded plugin.

  Prefers the version of `:mob` actually resolved in the current project (so a
  plugin scaffolded inside a mob 0.7.x app pins `"~> 0.7"`), falling back to
  the compiled `@fallback_mob_requirement` when mob isn't loadable (scaffolding
  standalone). Impure — the Mix task calls this and threads the result into
  `files_for/3`; the templates themselves stay pure.
  """
  @spec detect_mob_requirement() :: String.t()
  def detect_mob_requirement do
    _ = Application.load(:mob)

    case Application.spec(:mob, :vsn) do
      nil -> mob_requirement(nil)
      vsn -> mob_requirement(List.to_string(vsn))
    end
  end

  @doc """
  Returns the file list for a given tier + name. Each entry is
  `{relative_path, content}`. `relative_path` is relative to the plugin's
  root directory.

  `mob_req` is the `mob` version requirement to embed in the generated
  `mix.exs` and manifest; defaults to `@fallback_mob_requirement`. The Mix
  task passes `detect_mob_requirement/0` so a scaffolded plugin pins the mob
  it's being generated against.
  """
  @spec files_for(tier(), String.t(), String.t()) :: [file()]
  def files_for(tier, name, mob_req \\ @fallback_mob_requirement)

  def files_for(0, name, mob_req) do
    [
      {"mix.exs", mix_exs(name, mob_req)},
      {"lib/#{name}.ex", tier0_lib(name)},
      {"test/test_helper.exs", test_helper()},
      {"test/#{name}_test.exs", tier0_test(name)}
    ]
  end

  def files_for(1, name, mob_req) do
    nif_name = "#{name}_nif"

    [
      {"mix.exs", mix_exs(name, mob_req)},
      {"lib/#{name}.ex", tier1_lib(name, nif_name)},
      {"src/#{nif_name}.erl", tier1_erl_stub(nif_name)},
      {"priv/mob_plugin.exs", tier1_manifest(name, nif_name, mob_req)},
      {"priv/native/jni/#{nif_name}.c", tier1_c(nif_name)},
      {"test/test_helper.exs", test_helper()},
      {"test/#{name}_test.exs", plugin_test(name)}
    ]
  end

  def files_for(2, name, mob_req) do
    mod = module_name(name)
    registry_name = "#{mod}_View"

    [
      {"mix.exs", mix_exs(name, mob_req)},
      {"lib/#{name}.ex", tier2_lib(name, mod)},
      {"lib/#{name}/view.ex", tier2_view(mod)},
      {"priv/mob_plugin.exs", tier2_manifest(name, mod, registry_name, mob_req)},
      {"priv/native/android/#{mod}.kt", tier2_kt(mod, registry_name)},
      {"priv/native/ios/#{mod}View.swift", tier2_swift(mod)},
      {"test/test_helper.exs", test_helper()},
      {"test/#{name}_test.exs", plugin_test(name)}
    ]
  end

  def files_for(3, name, mob_req) do
    mod = module_name(name)

    [
      {"mix.exs", mix_exs(name, mob_req)},
      {"lib/#{name}/list_screen.ex", tier3_list_screen(mod)},
      {"lib/#{name}/detail_screen.ex", tier3_detail_screen(mod)},
      {"priv/mob_plugin.exs", tier3_manifest(name, mod, mob_req)},
      {"priv/repo/migrations/20260101000000_create_#{name}_items.exs", tier3_migration(mod)},
      {"test/test_helper.exs", test_helper()},
      {"test/#{name}_test.exs", plugin_test(name)}
    ]
  end

  def files_for(4, name, mob_req) do
    mod = module_name(name)

    [
      {"mix.exs", mix_exs(name, mob_req)},
      {"lib/#{name}.ex", tier4_lib(mod)},
      {"lib/#{name}/worker.ex", tier4_worker(mod)},
      {"lib/#{name}/notifications.ex", tier4_notifications(mod)},
      {"lib/#{name}/settings_screen.ex", tier4_settings_screen(mod)},
      {"priv/mob_plugin.exs", tier4_manifest(name, mod, mob_req)},
      {"test/test_helper.exs", test_helper()},
      {"test/#{name}_test.exs", plugin_test(name)}
    ]
  end

  # ── mix.exs (same for all tiers) ──────────────────────────────────────────

  defp mix_exs(name, mob_req) do
    mod = module_name(name)

    """
    defmodule #{mod}.MixProject do
      use Mix.Project

      def project do
        [
          app: :#{name},
          version: "0.1.0",
          elixir: "~> 1.17",
          deps: deps()
        ]
      end

      def application do
        [extra_applications: [:logger]]
      end

      defp deps do
        [
          {:mob, "#{mob_req}"}
        ]
      end
    end
    """
  end

  # ── Test scaffolding (all tiers) ──────────────────────────────────────────
  # Stdlib-only on purpose: a scaffolded plugin can live anywhere, so it can't
  # assume a path to mob_dev. The full validator still runs from a host app
  # via `mix mob.validate_plugin`.

  defp test_helper, do: "ExUnit.start()\n"

  defp tier0_test(name) do
    mod = module_name(name)

    """
    defmodule #{mod}Test do
      use ExUnit.Case, async: true

      # Tier 0 ships no manifest — the contract is just "the module compiles
      # against mob". Grow this suite alongside your plugin's pure logic.
      test "the plugin module compiles" do
        assert Code.ensure_loaded?(#{mod})
      end
    end
    """
  end

  defp plugin_test(name) do
    mod = module_name(name)

    """
    defmodule #{mod}Test do
      use ExUnit.Case, async: true

      # Structural checks that run with no extra deps. For the full pre-publish
      # validation (path/NIF/permission rules + cross-plugin collisions) run
      # `mix mob.validate_plugin` from a host app that has mob_dev. Grow this
      # suite alongside your plugin's pure logic (option builders, parsers, …).
      @plugin_dir Path.expand("..", __DIR__)
      @manifest_path Path.join(@plugin_dir, "priv/mob_plugin.exs")

      test "manifest evaluates to a map with the required keys" do
        assert {%{} = m, _} = Code.eval_file(@manifest_path)
        assert m.name == :#{name}
        assert is_binary(m.mob_version)
        assert is_integer(m.plugin_spec_version)
      end

      test "every NIF entry has a loadable stub module and an existing native_dir" do
        {m, _} = Code.eval_file(@manifest_path)

        for %{module: nif_mod, native_dir: dir} <- Map.get(m, :nifs, []) do
          assert Code.ensure_loaded?(nif_mod), "src/\#{nif_mod}.erl stub missing or broken"
          assert File.dir?(Path.join(@plugin_dir, dir)), "\#{dir} missing"
        end
      end

      test "every screen module the manifest references compiles" do
        {m, _} = Code.eval_file(@manifest_path)

        for %{module: screen_mod} <- Map.get(m, :screens, []) do
          assert Code.ensure_loaded?(screen_mod)
        end
      end
    end
    """
  end

  # ── Tier 0 ────────────────────────────────────────────────────────────────

  defp tier0_lib(name) do
    mod = module_name(name)

    """
    defmodule #{mod} do
      @moduledoc \"\"\"
      Tier-0 mob plugin: pure-Elixir, no manifest, hot-pushable.

      A regular Hex package depending on `:mob`. mob_dev treats it as an
      ordinary dependency; it shows in `mix mob.plugins` only once activated
      in the host's `mob.exs`:

          config :mob, :plugins, [:#{name}]

      Replace `hello/0` with your plugin's API.
      \"\"\"

      @doc "Example helper — replace with your plugin's real API."
      def hello, do: :ok
    end
    """
  end

  # ── Tier 1 ────────────────────────────────────────────────────────────────

  defp tier1_lib(name, nif_name) do
    mod = module_name(name)

    """
    defmodule #{mod} do
      @moduledoc \"\"\"
      Tier-1 mob plugin: native NIF + Elixir wrapper.

      The NIF lives in `src/#{nif_name}.erl` (Erlang stub with tolerant
      on_load) + `priv/native/jni/#{nif_name}.c` (the C side, ERL_NIF_INIT
      under static linking). This Elixir wrapper delegates to it.

      Activate in your host's `mob.exs`:

          config :mob, :plugins, [:#{name}]
      \"\"\"

      defdelegate ping, to: :#{nif_name}
    end
    """
  end

  defp tier1_erl_stub(nif_name) do
    """
    %% #{nif_name} — Erlang NIF stub for the tier-1 plugin.
    %%
    %% The C side (priv/native/jni/#{nif_name}.c) registers functions under
    %% this module name via ERL_NIF_INIT. On device the NIF is statically
    %% linked into the host binary; on a host dev build it isn't linked, so
    %% on_load tolerates the load failure (returning ok keeps the module
    %% loadable) and ping/0 falls back to nif_error until the native merge
    %% links it.
    -module(#{nif_name}).
    -export([ping/0]).
    -on_load(init/0).

    init() ->
        case erlang:load_nif("#{nif_name}", 0) of
            ok -> ok;
            {error, _} -> ok
        end.

    ping() ->
        erlang:nif_error(nif_not_loaded).
    """
  end

  defp tier1_manifest(name, nif_name, mob_req) do
    """
    %{
      name: :#{name},
      mob_version: "#{mob_req}",
      plugin_spec_version: 1,
      description: "TODO: describe your plugin",
      nifs: [
        # :module is the C/Erlang NIF name (a valid C token), NOT an Elixir
        # module — ERL_NIF_INIT uses it as both the registered module name
        # and the static-init C symbol prefix.
        %{module: :#{nif_name}, native_dir: "priv/native/jni"}
      ]
    }
    """
  end

  defp tier1_c(nif_name) do
    """
    /* #{nif_name} — tier-1 plugin NIF.
     *
     * The compile-time merge engine compiles this with
     * -DSTATIC_ERLANG_NIF -DSTATIC_ERLANG_NIF_LIBNAME=#{nif_name},
     * so ERL_NIF_INIT emits the static init symbol #{nif_name}_nif_init()
     * that the driver_tab generated by `mix mob.regen_driver_tab` references.
     */
    #include <erl_nif.h>

    static ERL_NIF_TERM ping(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
      (void)argc;
      (void)argv;
      return enif_make_atom(env, "ok");
    }

    static ErlNifFunc nif_funcs[] = {
        {"ping", 0, ping},
    };

    ERL_NIF_INIT(#{nif_name}, nif_funcs, NULL, NULL, NULL, NULL)
    """
  end

  # ── Tier 2 ────────────────────────────────────────────────────────────────

  defp tier2_lib(_name, mod) do
    """
    defmodule #{mod} do
      @moduledoc \"\"\"
      Tier-2 mob plugin: a native UI component.

      Wraps `Mob.UI.native_view` so a host screen can write:

          use Mob.Sigil

          ~MOB\"""
          <Column>
            {#{mod}.widget(id: :w)}
          </Column>
          \"""

      The matching `#{mod}.View` (`use Mob.Component`) owns Elixir-side state.
      The host's `MobBridge.kt` registers the Kotlin factory under
      `"#{mod}_View"` (Elixir-module name stripped of `Elixir.` with dots →
      underscores — the convention `Mob.Component` documents).
      \"\"\"

      @doc \"\"\"
      Returns a `Mob.UI.native_view` node for the component. `:id` is required
      and must be unique on the screen.
      \"\"\"
      def widget(opts \\\\ []) do
        {id, props} = Keyword.pop(opts, :id)

        unless is_atom(id) and not is_nil(id) do
          raise ArgumentError, "#{mod}.widget/1 requires an :id atom"
        end

        Mob.UI.native_view(#{mod}.View, [{:id, id} | props])
      end
    end
    """
  end

  defp tier2_view(mod) do
    """
    defmodule #{mod}.View do
      @moduledoc \"\"\"
      `Mob.Component` for #{mod}. Native registration key is
      `"#{mod}_View"` (the convention in `Mob.Component`'s docs).
      \"\"\"
      use Mob.Component

      @impl true
      def mount(props, socket) do
        {:ok, Mob.Socket.assign(socket, :label, props[:label] || "Hello from #{mod}")}
      end

      @impl true
      def update(props, socket) do
        {:ok, Mob.Socket.assign(socket, :label, props[:label] || socket.assigns.label)}
      end

      @impl true
      def render(assigns) do
        %{label: assigns.label}
      end
    end
    """
  end

  defp tier2_manifest(name, mod, registry_name, mob_req) do
    """
    %{
      name: :#{name},
      mob_version: "#{mob_req}",
      plugin_spec_version: 1,
      description: "TODO: describe your plugin",

      ui_components: [
        %{
          tag: "#{mod}",
          atom: :#{name},
          props: [:label],
          # Native registration name = `<Elixir module>`, stripped of `Elixir.`
          # with dots → `_`. Matches what `Mob.Component` emits as the
          # `:module` prop at render time, and what `MobNativeViewRegistry`
          # looks up.
          ios: %{view_module: "#{registry_name}"},
          android: %{composable: "#{registry_name}"}
        }
      ]
    }
    """
  end

  defp tier2_kt(mod, registry_name) do
    """
    // #{mod} — tier-2 plugin Compose factory.
    //
    // Until the plugin merge engine wires plugin Kotlin into the build
    // automatically, the host app developer copies this content into
    // MobBridge.kt (alongside the MobNativeViewRegistry definition) and
    // arranges #{mod}Plugin.register() to run at startup — the documented
    // workflow for native components today.

    object #{mod}Plugin {
        fun register() {
            MobNativeViewRegistry.register("#{registry_name}") { props, _send ->
                #{mod}Composable(props)
            }
        }
    }

    @Composable
    private fun #{mod}Composable(props: Map<String, Any?>) {
        val label = (props["label"] as? String) ?: "#{mod}"
        Text(label)
    }
    """
  end

  defp tier2_swift(mod) do
    """
    // #{mod}View — tier-2 plugin SwiftUI view.
    // Mirrors the Android Compose factory in priv/native/android/#{mod}.kt.
    // Once the host iOS init wires plugin views into the native_view
    // dispatch, this is registered under `"#{mod}_View"` (the Mob.Component
    // module-name encoding).
    import SwiftUI

    struct #{mod}View: View {
        let props: [String: Any]

        var body: some View {
            let label = props["label"] as? String ?? "#{mod}"
            Text(label)
        }
    }
    """
  end

  # ── Tier 3 — multi-screen + migration ─────────────────────────────────────

  defp tier3_list_screen(mod) do
    """
    defmodule #{mod}.ListScreen do
      @moduledoc \"\"\"
      Tier-3 plugin screen. The host registers it as a navigable destination at
      boot (by `default_route`); tapping a row pushes the detail screen.
      \"\"\"
      use Mob.Screen

      @items ["alpha", "beta", "gamma"]

      def mount(_params, _session, socket), do: {:ok, socket}

      def render(_assigns) do
        ~MOB\"""
        <Scroll background={:background}>
          <Column background={:background} padding={:space_lg}>
            <Text text="#{mod}" text_size={:xl} text_color={:on_surface} padding={:space_sm} />
            {for item <- @items, do: row(item)}
          </Column>
        </Scroll>
        \"""
      end

      def handle_event("open", %{"key" => key}, socket) do
        {:noreply, Mob.Socket.push_screen(socket, #{mod}.DetailScreen, %{key: key})}
      end

      defp row(item) do
        ~MOB\"""
        <Button text={item} background={:primary} text_color={:on_primary}
                padding={:space_md} fill_width={true} on_tap={{self(), {:open, item}}} />
        \"""
      end
    end
    """
  end

  defp tier3_detail_screen(mod) do
    """
    defmodule #{mod}.DetailScreen do
      @moduledoc "Tier-3 plugin detail screen, pushed from the list screen."
      use Mob.Screen

      def mount(params, _session, socket) do
        {:ok, Mob.Socket.assign(socket, :key, params[:key] || params["key"] || "?")}
      end

      def render(assigns) do
        ~MOB\"""
        <Scroll background={:background}>
          <Column background={:background} padding={:space_lg}>
            <Text text={"key: " <> assigns.key} text_size={:lg} text_color={:on_surface} padding={4} />
            <Button text="Back" background={:primary} text_color={:on_primary}
                    padding={:space_md} on_tap={{self(), :back}} />
          </Column>
        </Scroll>
        \"""
      end

      def handle_event("back", _params, socket), do: {:noreply, Mob.Socket.pop_screen(socket)}
    end
    """
  end

  defp tier3_manifest(name, mod, mob_req) do
    """
    %{
      name: :#{name},
      mob_version: "#{mob_req}",
      plugin_spec_version: 1,
      description: "TODO: describe your plugin",

      # Whole screens the host can navigate to. Registered by default_route at
      # boot; two distinct plugins may not claim the same route (cross-plugin
      # validation rejects it — see MOB_PLUGINS.md "Cross-plugin conflict detection").
      screens: [
        %{module: #{mod}.ListScreen, default_route: "/#{name}/list"},
        %{module: #{mod}.DetailScreen, default_route: "/#{name}/detail"}
      ],

      # Ecto migrations the plugin ships. mob_dev copies them into the host's
      # migrations dir at `--native` build, prefixing each with repo_namespace
      # (so vendors don't collide); the host's Ecto.Migrator runs them. The
      # repo_namespace must be unique across activated plugins.
      migrations: %{
        repo_namespace: "#{name}_",
        migrations_dir: "priv/repo/migrations"
      }

      # Optional tier-3 assets — add real files then uncomment:
      #
      #   assets: %{
      #     fonts: ["priv/fonts/MyFont.ttf"],   # registered (iOS UIAppFonts / Android res/font)
      #     images: ["priv/assets/icon.png"]    # addressable via plugin://#{name}/icon.png
      #   }
    }
    """
  end

  defp tier3_migration(mod) do
    """
    defmodule #{mod}.Migrations.CreateItems do
      # Rename this file with a real timestamp before publishing (the leading
      # integer is the Ecto version). mob_dev namespaces the copied filename by
      # the plugin's repo_namespace so it can't collide with other plugins'.
      use Ecto.Migration

      def change do
        create table(:#{Macro.underscore(mod)}_items) do
          add(:name, :string, null: false)
        end
      end
    end
    """
  end

  # ── Tier 4 — embedded sub-app (lifecycle + settings + notifications) ───────

  defp tier4_lib(mod) do
    """
    defmodule #{mod} do
      @moduledoc \"\"\"
      Tier-4 sub-app plugin: lifecycle hooks + a supervised worker + settings +
      a notification handler. The host runs `on_start` at boot (under the plugin
      supervisor), starts the `supervised` children, and calls `on_resume` /
      `on_background` on OS foreground/background transitions.
      \"\"\"

      @doc "lifecycle.on_start — runs once at boot under the plugin supervisor."
      def start, do: :ok

      @doc "lifecycle.on_resume — host came to the foreground."
      def on_resume, do: :ok

      @doc "lifecycle.on_background — host went to the background."
      def on_background, do: :ok
    end
    """
  end

  defp tier4_worker(mod) do
    """
    defmodule #{mod}.Worker do
      @moduledoc "Supervised background worker for the tier-4 plugin."
      use GenServer

      def start_link(_arg), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

      @impl GenServer
      def init(:ok), do: {:ok, %{}}
    end
    """
  end

  defp tier4_notifications(mod) do
    """
    defmodule #{mod}.Notifications do
      @moduledoc "Notification handler — invoked when an incoming payload matches."

      @doc "Handles a notification payload routed here by the host dispatcher."
      def handle(_payload), do: :ok
    end
    """
  end

  defp tier4_settings_screen(mod) do
    """
    defmodule #{mod}.SettingsScreen do
      @moduledoc "Settings editor screen the host pushes for this plugin."
      use Mob.Screen

      def mount(_params, _session, socket), do: {:ok, socket}

      def render(_assigns) do
        ~MOB\"""
        <Column background={:background} padding={:space_lg}>
          <Text text="#{mod} settings" text_size={:xl} text_color={:on_surface} />
        </Column>
        \"""
      end
    end
    """
  end

  defp tier4_manifest(name, mod, mob_req) do
    """
    %{
      name: :#{name},
      mob_version: "#{mob_req}",
      plugin_spec_version: 1,
      description: "TODO: describe your plugin",

      # Lifecycle hooks + supervised children. on_start/on_resume/on_background
      # are {Module, fun, args} MFAs; supervised children join the host's plugin
      # supervisor. A supervised worker's registered name must be unique across
      # activated plugins.
      lifecycle: %{
        on_start: {#{mod}, :start, []},
        on_resume: {#{mod}, :on_resume, []},
        on_background: {#{mod}, :on_background, []},
        supervised: [#{mod}.Worker]
      },

      # Typed, per-plugin-namespaced settings (read/written via Mob.Plugins
      # get_setting/3 + put_setting/4, validated against :type). editor_screen
      # is the screen the host pushes to let the user change them.
      settings: %{
        schema: [%{key: :enabled, type: :boolean, default: true}],
        editor_screen: #{mod}.SettingsScreen
      },

      # Notification handlers. `match` is a map prefix-matched against the
      # payload (or a 1-arity predicate); the first matching handler across all
      # plugins wins, so two plugins may not declare the identical match.
      notifications: %{
        handlers: [
          %{match: %{type: "#{name}"}, handler: {#{mod}.Notifications, :handle, 1}}
        ]
      }
    }
    """
  end
end
