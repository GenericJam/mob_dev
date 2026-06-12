defmodule MobDev.Style do
  @moduledoc """
  The styles lane (MOB_STYLES.md), minimum-viable slice: token-only style
  packages. A style package ships `priv/mob_style.exs` declaring a theme
  module; activation is `config :mob, :styles, [...]` plus
  `config :mob, :default_style, :name` in `mob.exs`, and the runtime manifest
  carries the resolved set so core can apply the default style's theme at boot.

  Tokens-only is the doc's smallest tier ("repalette-only styles"); the
  per-component native-override tier (cascade, `_style` dispatch — the mob_m3
  case) is NOT implemented yet.
  """

  @manifest_path "priv/mob_style.exs"
  @supported_spec_versions [1]

  @doc """
  Loads a style manifest from `style_dir`. `{:ok, map}`, or `{:error, reason}`
  when the file is missing/unreadable/not a map (styles REQUIRE a manifest —
  there is no tier-0 equivalent).
  """
  @spec load(Path.t()) :: {:ok, map()} | {:error, String.t()}
  def load(style_dir) do
    path = Path.join(style_dir, @manifest_path)

    if File.exists?(path) do
      case Code.eval_file(path) do
        {map, _} when is_map(map) -> {:ok, map}
        {other, _} -> {:error, "#{@manifest_path} must evaluate to a map, got: #{inspect(other)}"}
      end
    else
      {:error, "missing #{@manifest_path}"}
    end
  rescue
    e -> {:error, "could not evaluate #{@manifest_path}: #{Exception.message(e)}"}
  end

  @doc """
  Validates the four required fields (MOB_STYLES.md "Minimum viable
  manifest"): `:name` atom, `:mob_version` requirement string,
  `:style_spec_version` integer, `:theme` module atom.
  """
  @spec validate(map()) :: {:ok, map()} | {:error, [String.t()]}
  def validate(manifest) when is_map(manifest) do
    errors =
      []
      |> check(
        manifest,
        :name,
        &(is_atom(&1) and not is_nil(&1)),
        ":name is required and must be an atom"
      )
      |> check_version(manifest)
      |> check_spec_version(manifest)
      |> check(
        manifest,
        :theme,
        &(is_atom(&1) and not is_nil(&1)),
        ":theme is required and must be a theme module atom"
      )

    case errors do
      [] -> {:ok, manifest}
      errs -> {:error, Enum.reverse(errs)}
    end
  end

  def validate(other),
    do:
      {:error,
       ["style manifest must be a map (the priv/mob_style.exs data), got: #{inspect(other)}"]}

  @doc """
  Activated style names from `mob.exs`'s `config :mob, :styles` (Application
  env fallback, mirroring `MobDev.Plugin.activated_names/0`).
  """
  @spec activated_names() :: [atom()]
  def activated_names, do: read_mob_config(:styles, [])

  @doc "The configured `:default_style` name (or nil)."
  @spec default_style() :: atom() | nil
  def default_style, do: read_mob_config(:default_style, nil)

  @doc """
  The activated styles as `{style_dir, manifest}` pairs. Names that don't
  resolve to a dep or whose manifest fails to load are skipped (surfaced by
  validation at build).
  """
  @spec activated() :: [{Path.t(), map()}]
  def activated do
    deps = Mix.Project.deps_paths()

    for name <- activated_names(), dir = deps[name], not is_nil(dir) do
      case load(dir) do
        {:ok, manifest} -> {dir, manifest}
        {:error, _} -> nil
      end
    end
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  The runtime-manifest entries for the activated styles:
  `[%{name, theme}]`. Raises at build when an activated style's manifest is
  invalid or the configured `:default_style` isn't among the activated styles
  — a misconfigured style must fail the BUILD, not silently render baseline.
  """
  @spec runtime_entries!() :: %{styles: [map()], default_style: atom() | nil}
  def runtime_entries! do
    entries =
      for {dir, manifest} <- activated() do
        case validate(manifest) do
          {:ok, m} ->
            %{name: m.name, theme: m.theme}

          {:error, errs} ->
            raise ArgumentError,
                  "invalid style manifest in #{dir}:\n  " <> Enum.join(errs, "\n  ")
        end
      end

    default = default_style()

    if default != nil and not Enum.any?(entries, &(&1.name == default)) do
      raise ArgumentError,
            ":default_style #{inspect(default)} is not among the activated styles " <>
              "#{inspect(Enum.map(entries, & &1.name))} — add it to config :mob, :styles"
    end

    %{styles: entries, default_style: default}
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp check(errors, manifest, key, pred, msg) do
    if pred.(Map.get(manifest, key)), do: errors, else: [msg | errors]
  end

  defp check_version(errors, %{mob_version: req}) when is_binary(req) do
    case Version.parse_requirement(req) do
      {:ok, _} -> errors
      :error -> [":mob_version #{inspect(req)} is not a valid version requirement" | errors]
    end
  end

  defp check_version(errors, _),
    do: [":mob_version is required and must be a version requirement string" | errors]

  defp check_spec_version(errors, %{style_spec_version: v}) when is_integer(v) do
    if v in @supported_spec_versions do
      errors
    else
      [
        "style_spec_version #{v} is not supported (this mob_dev knows #{inspect(@supported_spec_versions)})"
        | errors
      ]
    end
  end

  defp check_spec_version(errors, _),
    do: [":style_spec_version is required and must be an integer" | errors]

  defp read_mob_config(key, default) do
    config_file = Path.join(File.cwd!(), "mob.exs")

    if File.exists?(config_file) do
      config_file
      |> Config.Reader.read!()
      |> Keyword.get(:mob, [])
      |> Keyword.get(key, default)
    else
      Application.get_env(:mob, key, default)
    end
  rescue
    _ -> Application.get_env(:mob, key, default)
  end
end
