defmodule MobDev.Plugin.Manifest do
  @moduledoc """
  Reads, validates, and classifies a plugin's `priv/mob_plugin.exs` manifest.

  The manifest is data, not code (see `MOB_PLUGINS.md`): a plain Elixir map
  describing what a plugin contributes. This module is the single place that
  turns that map into a validated, classified description — tier, hot-push
  status, activation — that `mix mob.plugins` reports and the compile-time
  merge will later consume.

  A tier-0 plugin has no manifest at all; `load/1` returns `{:ok, nil}` for
  that case, and `tier(nil)` is `0`.
  """

  @manifest_path "priv/mob_plugin.exs"

  # Spec versions this mob_dev understands. Bumped when MOB_PLUGINS.md makes a
  # breaking schema change; old plugins keep validating against old specs.
  @supported_spec_versions [1, 2]

  @native_sections [
    :nifs,
    :nifs_generator,
    :android,
    :ios,
    :permissions,
    :ui_components,
    :ui_components_generator
  ]
  @screen_sections [:screens, :screens_generator, :migrations, :assets]
  @subapp_sections [:lifecycle, :settings, :notifications]
  @visual_sections [:ui_components, :ui_components_generator]
  @tier1_sections [:nifs, :nifs_generator, :android, :ios, :permissions]
  # Sections whose Elixir half can still hot-push even when the plugin has
  # native code (the partial case).
  @pushable_sections [:screens, :screens_generator, :lifecycle, :migrations]

  @doc """
  Loads the manifest for a plugin checked out at `plugin_dir`.

  Returns `{:ok, nil}` when there is no `priv/mob_plugin.exs` (a tier-0
  plugin), `{:ok, map}` when one is present and evaluates to a map, or
  `{:error, reason}` when the file is unreadable or doesn't yield a map.
  Does not validate field contents — call `validate/1` for that.
  """
  @spec load(Path.t()) :: {:ok, map() | nil} | {:error, String.t()}
  def load(plugin_dir) do
    path = Path.join(plugin_dir, @manifest_path)

    if File.exists?(path) do
      eval(path)
    else
      {:ok, nil}
    end
  end

  defp eval(path) do
    case Code.eval_file(path) do
      {map, _bindings} when is_map(map) ->
        {:ok, map}

      {other, _bindings} ->
        {:error, "#{path} must evaluate to a map, got: #{inspect(other)}"}
    end
  rescue
    e -> {:error, "#{path} failed to evaluate: #{Exception.message(e)}"}
  end

  @doc """
  Validates a manifest map against the spec's required top-level fields.

  Returns `{:ok, manifest}` or `{:error, reasons}` with a list of every
  problem found (validation never stops at the first error). `nil` (no
  manifest) is valid — a tier-0 plugin has nothing to validate.
  """
  @spec validate(map() | nil) :: {:ok, map() | nil} | {:error, [String.t()]}
  def validate(nil), do: {:ok, nil}

  def validate(manifest) when is_map(manifest) do
    errors =
      []
      |> check_name(manifest)
      |> check_mob_version(manifest)
      |> check_spec_version(manifest)
      |> check_permissions(manifest)
      |> check_nifs(manifest)

    case errors do
      [] -> {:ok, manifest}
      errs -> {:error, Enum.reverse(errs)}
    end
  end

  def validate(other),
    do:
      {:error, ["manifest must be a map (the priv/mob_plugin.exs data), got: #{inspect(other)}"]}

  defp check_name(errors, %{name: name}) when is_atom(name) and not is_nil(name), do: errors
  defp check_name(errors, _), do: [":name is required and must be an atom" | errors]

  defp check_mob_version(errors, %{mob_version: req}) when is_binary(req) do
    case Version.parse_requirement(req) do
      {:ok, _} -> errors
      :error -> [":mob_version #{inspect(req)} is not a valid version requirement" | errors]
    end
  end

  defp check_mob_version(errors, _),
    do: [
      ":mob_version is required and must be a version requirement string (e.g. \"~> 0.6\")"
      | errors
    ]

  defp check_spec_version(errors, %{plugin_spec_version: v}) when is_integer(v) do
    if v in @supported_spec_versions do
      errors
    else
      [
        "plugin_spec_version #{v} is not supported (this mob_dev knows #{inspect(@supported_spec_versions)})"
        | errors
      ]
    end
  end

  defp check_spec_version(errors, _),
    do: [":plugin_spec_version is required and must be an integer" | errors]

  # `:permissions` is optional. When present it must be a list of maps, each with
  # a `:capability` atom (the value `Mob.Permissions.request/2` accepts) and an
  # optional `:ios` map carrying a `:handler` string (the cdecl symbol the
  # plugin self-registers). Android needs nothing here — its provider is
  # auto-discovered by interface at bootstrap (see the permission-registry ADR).
  defp check_permissions(errors, %{permissions: perms}) when is_list(perms) do
    perms
    |> Enum.with_index()
    |> Enum.reduce(errors, fn {entry, i}, acc -> check_permission_entry(acc, entry, i) end)
  end

  defp check_permissions(errors, %{permissions: other}),
    do: ["permissions must be a list, got: #{inspect(other)}" | errors]

  defp check_permissions(errors, _), do: errors

  defp check_permission_entry(errors, %{capability: cap} = entry, _i) when is_atom(cap) do
    case entry[:ios] do
      nil ->
        errors

      %{handler: h} when is_binary(h) ->
        errors

      %{} ->
        ["permissions entry #{inspect(cap)}: ios must declare a :handler string" | errors]

      other ->
        ["permissions entry #{inspect(cap)}: :ios must be a map, got: #{inspect(other)}" | errors]
    end
  end

  defp check_permission_entry(errors, %{} = entry, i),
    do: ["permissions entry ##{i} requires a :capability atom, got: #{inspect(entry)}" | errors]

  defp check_permission_entry(errors, other, i),
    do: ["permissions entry ##{i} must be a map, got: #{inspect(other)}" | errors]

  # `:nifs` is optional. When present, each entry's optional `:platform` (used by
  # cross-platform plugins that ship a separate iOS + Android source for the same
  # module) must be `:ios` or `:android`. Other fields are validated at build /
  # link time, not here.
  defp check_nifs(errors, %{nifs: nifs}) when is_list(nifs) do
    nifs
    |> Enum.with_index()
    |> Enum.reduce(errors, fn {nif, i}, acc -> check_nif_platform(acc, nif, i) end)
  end

  defp check_nifs(errors, %{nifs: other}),
    do: ["nifs must be a list, got: #{inspect(other)}" | errors]

  defp check_nifs(errors, _), do: errors

  defp check_nif_platform(errors, %{platform: p}, i) when p not in [:ios, :android],
    do: ["nifs entry ##{i}: :platform must be :ios or :android, got: #{inspect(p)}" | errors]

  defp check_nif_platform(errors, _nif, _i), do: errors

  @doc """
  Classifies the plugin tier (0–4) from which capability sections are present.

  Highest matching section wins. `nil` (no manifest) is tier 0. A manifest
  with required fields but no capability sections is the tier-1 floor (the
  "minimum viable manifest").
  """
  @spec tier(map() | nil) :: 0..4
  def tier(nil), do: 0

  def tier(m) when is_map(m) do
    cond do
      has_any?(m, @subapp_sections) -> 4
      has_any?(m, @screen_sections) -> 3
      has_any?(m, @visual_sections) -> 2
      has_any?(m, @tier1_sections) -> 1
      true -> 1
    end
  end

  @doc """
  Whether the plugin's contributions can be hot-pushed without a native rebuild.

  Computed from populated sections, not from tier: `true` for pure-Elixir
  plugins, `false` for native-only ones (NIFs / components), and `:partial`
  when a plugin mixes native code with hot-pushable Elixir (screens, lifecycle).
  """
  @spec hot_pushable(map() | nil) :: true | false | :partial
  def hot_pushable(nil), do: true

  def hot_pushable(m) when is_map(m) do
    cond do
      not has_any?(m, @native_sections) -> true
      has_any?(m, @pushable_sections) -> :partial
      true -> false
    end
  end

  defp has_any?(map, keys), do: Enum.any?(keys, &Map.has_key?(map, &1))
end
