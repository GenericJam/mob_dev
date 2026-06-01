defmodule Mix.Tasks.Mob.ValidatePlugin do
  use Mix.Task

  @shortdoc "Validate this project's mob plugin manifest (priv/mob_plugin.exs)"

  @moduledoc """
  Validates the `priv/mob_plugin.exs` manifest of the plugin project in the
  current directory — a plugin author's pre-publish check.

      mix mob.validate_plugin

  Checks (see `MOB_PLUGINS.md`): required top-level fields, every declared file
  path exists, and the installed `:mob` satisfies the manifest's `mob_version`.
  Advisory warnings cover single-platform components and declared
  permissions/plist keys. Exits non-zero if any error is found — never silent.

  A project with no `priv/mob_plugin.exs` is a tier-0 plugin (nothing to
  validate) and the task says so.
  """

  alias MobDev.Plugin.{Manifest, Validator}

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("loadpaths")
    dir = File.cwd!()

    case Manifest.load(dir) do
      {:ok, nil} ->
        Mix.shell().info(
          "No priv/mob_plugin.exs — this is a tier-0 plugin (no manifest to validate)."
        )

      {:ok, manifest} ->
        manifest
        |> Validator.validate_plugin(dir, installed_mob_version())
        |> report()

      {:error, reason} ->
        Mix.raise("could not read priv/mob_plugin.exs: #{reason}")
    end
  end

  defp installed_mob_version do
    _ = Application.load(:mob)

    case Application.spec(:mob, :vsn) do
      nil -> nil
      vsn -> to_string(vsn)
    end
  end

  defp report(%{errors: errors, warnings: warnings}) do
    Enum.each(warnings, &Mix.shell().info([:yellow, "⚠ ", &1, :reset]))

    case errors do
      [] ->
        suffix = if warnings == [], do: "", else: " (#{length(warnings)} warning(s))"
        Mix.shell().info([:green, "✓ manifest valid#{suffix}", :reset])

      _ ->
        Enum.each(errors, &Mix.shell().error("✗ #{&1}"))
        Mix.raise("plugin manifest validation failed with #{length(errors)} error(s)")
    end
  end
end
