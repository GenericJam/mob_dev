defmodule MobDev.Plugin.Validator do
  @moduledoc """
  Validates plugin manifests, in two stages (see `MOB_PLUGINS.md`).

  **Single-plugin** (`validate_plugin/3`, behind `mix mob.validate_plugin`): a
  plugin author's pre-publish check — required fields, referenced files exist,
  `mob_version` satisfied by the installed mob, plus advisory warnings.

  **Cross-plugin** (`cross_validate/1`, run by mob_dev when activating): the
  collision checks that only make sense across the *set* of activated plugins —
  no two may claim the same component atom, screen route, or migration namespace.

  Every result is `%{errors: [...], warnings: [...]}`. Errors fail loud;
  warnings are advisory. Both stages are pure given their inputs (the only I/O
  is `File.exists?/1` for path checks, isolated in `validate_plugin/3`).
  """

  alias MobDev.Plugin.Manifest

  @type result :: %{errors: [String.t()], warnings: [String.t()]}

  @doc """
  Collects the file paths a manifest references, relative to the plugin root.

  Pure. Covers the concrete file declarations (`nifs.native_dir`,
  `android.bridge_kt`, `android.jni_source`, `ios.swift_files`). Component
  `view_module`/`composable` are type/function names, not paths, so they are
  not included here.
  """
  @spec referenced_paths(map() | nil) :: [String.t()]
  def referenced_paths(nil), do: []

  def referenced_paths(manifest) when is_map(manifest) do
    nif_dirs = for n <- Map.get(manifest, :nifs, []), is_map(n), do: n[:native_dir]
    android = Map.get(manifest, :android, %{})
    ios = Map.get(manifest, :ios, %{})

    [
      nif_dirs,
      [android[:bridge_kt], android[:jni_source]],
      List.wrap(ios[:swift_files])
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Single-plugin validation, run from the plugin's own project directory.

  `installed_mob_version` is the version of `:mob` resolved in the plugin's
  deps (a string), or `nil` to skip the compatibility check.
  """
  @spec validate_plugin(map() | nil, Path.t(), String.t() | nil) :: result()
  def validate_plugin(manifest, plugin_dir, installed_mob_version \\ nil) do
    %{errors: structural_errors(manifest), warnings: []}
    |> add_path_errors(manifest, plugin_dir)
    |> add_mob_version_error(manifest, installed_mob_version)
    |> add_nif_module_errors(manifest)
    |> add_warnings(manifest)
  end

  @doc """
  Cross-plugin collision validation across the activated set.

  `plugins` is a list of `{name, manifest}` for the activated plugins (tier-0
  no-manifest plugins, i.e. `manifest == nil`, contribute nothing and are
  ignored).
  """
  @spec cross_validate([{atom(), map() | nil}]) :: result()
  def cross_validate(plugins) do
    manifests = for {_name, m} <- plugins, is_map(m), do: m

    errors =
      collisions(manifests, &component_atoms/1, "component atom (ui_components.atom)") ++
        collisions(manifests, &screen_routes/1, "screen route (screens.default_route)") ++
        collisions(manifests, &repo_namespaces/1, "migration repo_namespace")

    %{errors: errors, warnings: []}
  end

  # ── single-plugin checks ──────────────────────────────────────────────────

  defp structural_errors(manifest) do
    case Manifest.validate(manifest) do
      {:ok, _} -> []
      {:error, errs} -> errs
    end
  end

  defp add_path_errors(result, manifest, plugin_dir) do
    missing =
      manifest
      |> referenced_paths()
      |> Enum.reject(&File.exists?(Path.join(plugin_dir, &1)))
      |> Enum.map(&"declared path does not exist: #{&1}")

    %{result | errors: result.errors ++ missing}
  end

  defp add_mob_version_error(result, %{mob_version: req}, installed)
       when is_binary(req) and is_binary(installed) do
    case Version.parse_requirement(req) do
      {:ok, _} ->
        if Version.match?(installed, req) do
          result
        else
          err = "installed :mob #{installed} does not satisfy mob_version #{inspect(req)}"
          %{result | errors: result.errors ++ [err]}
        end

      :error ->
        # The bad-requirement string is already reported by structural validation.
        result
    end
  end

  defp add_mob_version_error(result, _manifest, _installed), do: result

  # `nif :module` is the Erlang module name used by ERL_NIF_INIT both as the
  # registered module atom and as the prefix of the static-init symbol
  # (`<module>_nif_init`). It must therefore be a valid C token shape — a
  # lowercase ASCII atom — not an Elixir module alias. Catch this at validate
  # time rather than at link time. See MOB_PLUGINS.md (nifs section).
  @nif_module_pattern ~r/^[a-z][a-z0-9_]*$/

  defp add_nif_module_errors(result, manifest) when is_map(manifest) do
    errs =
      for n <- Map.get(manifest, :nifs, []),
          is_map(n),
          Map.has_key?(n, :module),
          err = nif_module_error(n[:module]),
          do: err

    %{result | errors: result.errors ++ errs}
  end

  defp add_nif_module_errors(result, _manifest), do: result

  defp nif_module_error(mod) when is_atom(mod) and not is_nil(mod) do
    if Regex.match?(@nif_module_pattern, Atom.to_string(mod)),
      do: nil,
      else: bad_nif_module_message(mod)
  end

  defp nif_module_error(other), do: bad_nif_module_message(other)

  defp bad_nif_module_message(value) do
    "nifs :module #{inspect(value)} must be a C-token atom matching " <>
      "/^[a-z][a-z0-9_]*$/ (e.g. :mob_bluetooth_nif), not an Elixir module — " <>
      "ERL_NIF_INIT uses it as the static-init symbol prefix"
  end

  defp add_warnings(result, manifest) do
    %{result | warnings: result.warnings ++ warnings(manifest)}
  end

  defp warnings(nil), do: []

  defp warnings(manifest) do
    single_platform_components(manifest) ++
      permission_review(manifest) ++
      plist_review(manifest)
  end

  defp single_platform_components(manifest) do
    for c <- Map.get(manifest, :ui_components, []),
        is_map(c),
        xor?(Map.has_key?(c, :ios), Map.has_key?(c, :android)) do
      "ui_components #{inspect(c[:atom] || c[:tag])} declares only one platform — " <>
        "the other platform will silently render nothing"
    end
  end

  defp permission_review(manifest) do
    case get_in(manifest, [:android, :permissions]) do
      [_ | _] = perms ->
        [
          "declares Android permissions #{inspect(perms)} — review before publishing (opt-in via activation)"
        ]

      _ ->
        []
    end
  end

  defp plist_review(manifest) do
    case get_in(manifest, [:ios, :plist_keys]) do
      m when is_map(m) and map_size(m) > 0 ->
        ["declares iOS plist_keys #{inspect(Map.keys(m))} — review before publishing"]

      _ ->
        []
    end
  end

  defp xor?(a, b), do: a != b

  # ── cross-plugin collision detection ──────────────────────────────────────

  defp collisions(manifests, extractor, label) do
    manifests
    |> Enum.flat_map(extractor)
    |> Enum.frequencies()
    |> Enum.filter(fn {_value, count} -> count > 1 end)
    |> Enum.map(fn {value, count} ->
      "#{count} activated plugins declare the same #{label}: #{inspect(value)}"
    end)
  end

  defp component_atoms(manifest) do
    for c <- Map.get(manifest, :ui_components, []), is_map(c), c[:atom], do: c[:atom]
  end

  defp screen_routes(manifest) do
    for s <- Map.get(manifest, :screens, []), is_map(s), s[:default_route], do: s[:default_route]
  end

  defp repo_namespaces(manifest) do
    case get_in(manifest, [:migrations, :repo_namespace]) do
      nil -> []
      ns -> [ns]
    end
  end
end
