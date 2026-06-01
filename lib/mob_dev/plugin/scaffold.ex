defmodule MobDev.Plugin.Scaffold do
  @moduledoc """
  Pure templates + name conversions behind `mix mob.new_plugin`.

  Inputs are a snake_case plugin name (e.g. `"mob_demo_widget"`) and a tier
  (0–2). Output is a list of `{relative_path, content_string}` pairs the Mix
  task writes to disk. All conversions live here so the task stays thin and
  the templates are unit-testable without filesystem I/O.

  Templates mirror the three on-device-verified prototypes
  (`mob_palette_demo`, `mob_demo_haptic_extras`, `mob_demo_signature_pad`) so
  a freshly scaffolded plugin compiles + activates by the same path the
  prototypes already prove.
  """

  @type tier :: 0 | 1 | 2
  @type file :: {Path.t(), String.t()}

  @supported_tiers [0, 1, 2]

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

      true ->
        :ok
    end
  end

  def validate_name(_), do: {:error, "plugin name must be a string"}

  @doc "Validates a tier (0, 1, or 2)."
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
  Returns the file list for a given tier + name. Each entry is
  `{relative_path, content}`. `relative_path` is relative to the plugin's
  root directory.
  """
  @spec files_for(tier(), String.t()) :: [file()]
  def files_for(0, name) do
    [
      {"mix.exs", mix_exs(name)},
      {"lib/#{name}.ex", tier0_lib(name)}
    ]
  end

  def files_for(1, name) do
    nif_name = "#{name}_nif"

    [
      {"mix.exs", mix_exs(name)},
      {"lib/#{name}.ex", tier1_lib(name, nif_name)},
      {"src/#{nif_name}.erl", tier1_erl_stub(nif_name)},
      {"priv/mob_plugin.exs", tier1_manifest(name, nif_name)},
      {"priv/native/jni/#{nif_name}.c", tier1_c(nif_name)}
    ]
  end

  def files_for(2, name) do
    mod = module_name(name)
    registry_name = "#{mod}_View"

    [
      {"mix.exs", mix_exs(name)},
      {"lib/#{name}.ex", tier2_lib(name, mod)},
      {"lib/#{name}/view.ex", tier2_view(mod)},
      {"priv/mob_plugin.exs", tier2_manifest(name, mod, registry_name)},
      {"priv/native/android/#{mod}.kt", tier2_kt(mod, registry_name)},
      {"priv/native/ios/#{mod}View.swift", tier2_swift(mod)}
    ]
  end

  # ── mix.exs (same for all tiers) ──────────────────────────────────────────

  defp mix_exs(name) do
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
          {:mob, "~> 0.6"}
        ]
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

  defp tier1_manifest(name, nif_name) do
    """
    %{
      name: :#{name},
      mob_version: "~> 0.6",
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

  defp tier2_manifest(name, mod, registry_name) do
    """
    %{
      name: :#{name},
      mob_version: "~> 0.6",
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
end
