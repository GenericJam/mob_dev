defmodule MobDev.Plugin.RuntimeManifest do
  @moduledoc """
  Builds the host's **runtime plugin manifest** — the device-readable record of
  the activated plugins' tier-3/4 contributions.

  Tiers 3 and 4 are pure-Elixir and runtime-wired: the host needs to know, on
  device, which screens exist, what lifecycle/settings/notification declarations
  each plugin made — but `MobDev.Plugin.activated/0` is compile-time only. So at
  build time this module gathers those sections (running any spec-v2
  `:screens_generator` under the host-config audit) and emits a terms file
  (`priv/generated/mob_plugins.exs`) that the core `Mob.Plugins` module reads at
  boot. It mirrors the `driver_tab` / `MobPluginBootstrap` codegen pattern, but
  for serializable Elixir data instead of native symbols.

  Only the behavioral data lives here. Migration files and font/image assets are
  physically copied into the host at build time (see `native_build`), not carried
  in this manifest.

  Everything emitted must be serializable terms — atoms, tuples, maps, strings,
  integers. The manifest validator forbids closures in plugin sections so this
  always holds.
  """

  alias MobDev.Plugin.Merge

  @doc """
  Builds the merged runtime manifest map from `{plugin_dir, manifest}` pairs.

  Static `:screens` and spec-v2 `:screens_generator` output are combined (each
  tagged with its plugin); generators run under `MobDev.Plugin.with_host_config_audit/3`
  so an undeclared host-config read fails the build.
  """
  @spec build([{Path.t(), map() | nil}]) :: map()
  def build(plugins) do
    # Styles ride the same runtime manifest (MOB_STYLES.md shares the plugin
    # infrastructure): the activated token-only style packages + the
    # configured default, applied by core at boot (Mob.Plugins.apply_default_style).
    %{styles: styles, default_style: default_style} = MobDev.Style.runtime_entries!()

    %{
      screens: Merge.screens(plugins) ++ generated_screens(plugins),
      lifecycle: Merge.lifecycle(plugins),
      settings: Merge.settings(plugins),
      notification_handlers: Merge.notification_handlers(plugins),
      nifs: nif_modules(plugins),
      composites: composites(plugins),
      styles: styles,
      default_style: default_style
    }
  end

  # Pure-Elixir composite components (the ui_components expand: form) — core
  # registers each into Mob.Composite at boot.
  defp composites(plugins) do
    for c <- Merge.ui_components(plugins),
        match?({m, f} when is_atom(m) and is_atom(f), c[:expand]) do
      %{plugin: c[:plugin], atom: c[:atom], expand: c[:expand]}
    end
  end

  # The activated plugins' NIF module atoms (deduped, platform-agnostic — the
  # same module name backs both the iOS and Android NIF). Core loads these at
  # boot so an iOS plugin NIF's `load` callback fires eagerly, registering any
  # permission handler it owns before a screen can request that permission.
  # (Android registers permissions eagerly via MobPluginBootstrap, so this is
  # the iOS counterpart; loading on both platforms is harmless and fail-fast.)
  @spec nif_modules([{Path.t(), map() | nil}]) :: [atom()]
  defp nif_modules(plugins) do
    Merge.nifs(plugins)
    |> Enum.map(& &1[:module])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp generated_screens(plugins) do
    for {_dir, manifest} <- plugins,
        is_map(manifest),
        gen = manifest[:screens_generator],
        not is_nil(gen) do
      {m, f, a} = gen
      allowed = manifest[:host_config_keys] || []
      name = manifest[:name]

      {screens, _reads} =
        MobDev.Plugin.with_host_config_audit(name, allowed, fn -> apply(m, f, a) end)

      screens
      |> validate_generated_screens(name)
      |> Enum.map(&Map.put(&1, :plugin, name))
    end
    |> List.flatten()
  end

  @doc """
  Validates a `:screens_generator`'s output, raising on malformed specs.

  A generator must return a list of `%{module: atom, default_route: binary}`
  maps (a bare map is wrapped). This mirrors `MobDev.Plugin.Manifest`'s static
  `:screens` validation so generator-produced screens are held to the same
  shape contract — otherwise a typo'd or wrong-typed spec would be written into
  `mob_plugins.exs` and silently dropped at boot (`Mob.Plugins.register_screens/0`
  pattern-matches `%{module:, default_route:}` and skips non-matching maps),
  making the plugin's screen vanish with no build-time error.

  Returns the validated screen list (without the `:plugin` tag, which the caller
  adds). Public for testing.
  """
  @spec validate_generated_screens(term(), atom() | nil) :: [map()]
  def validate_generated_screens(screens, plugin_name) do
    screens
    |> List.wrap()
    |> Enum.with_index()
    |> Enum.map(fn {entry, i} -> validate_screen_entry(entry, i, plugin_name) end)
  end

  defp validate_screen_entry(%{module: m, default_route: r} = entry, _i, _plugin)
       when is_atom(m) and not is_nil(m) and is_binary(r),
       do: entry

  defp validate_screen_entry(entry, i, plugin) do
    raise ArgumentError,
          "plugin #{inspect(plugin)} :screens_generator produced an invalid screen at " <>
            "index #{i}: expected a %{module: atom, default_route: binary} map, got: " <>
            "#{inspect(entry)}. Fix the generator to emit valid screen specs."
  end

  @doc """
  Renders the manifest map to the contents of `priv/generated/mob_plugins.exs` —
  a self-describing `.exs` that evaluates back to the map.
  """
  @spec render(map()) :: String.t()
  def render(manifest) do
    rendered =
      inspect(manifest,
        limit: :infinity,
        printable_limit: :infinity,
        pretty: true,
        custom_options: [sort_maps: true]
      )

    """
    # Generated by `mix mob.regen_plugin_manifest` — do not edit by hand.
    #
    # The activated plugins' tier-3/4 contributions, read at boot by Mob.Plugins.
    # Regenerated whenever `config :mob, :plugins` changes (the deploy/regen hook).
    #{rendered}
    """
  end

  @doc """
  Writes the rendered manifest to `<host_root>/priv/generated/mob_plugins.exs`
  and returns the path.
  """
  @spec write(Path.t(), map()) :: Path.t()
  def write(host_root, manifest) do
    path = Path.join([host_root, "priv", "generated", "mob_plugins.exs"])
    rendered = render(manifest)
    File.mkdir_p!(Path.dirname(path))

    if File.read(path) != {:ok, rendered} do
      File.write!(path, rendered)
    end

    path
  end
end
