defmodule Mix.Tasks.Mob.Plugins do
  use Mix.Task

  @shortdoc "List installed Mob plugins and their activation status"

  @moduledoc """
  Lists the Mob plugins this project depends on, with tier, hot-push status,
  and whether each is activated.

      mix mob.plugins

  A dependency is shown as a plugin if it ships a `priv/mob_plugin.exs`
  manifest, or if it is named in `config :mob, :plugins` in `mob.exs`.
  Tier-0 plugins (pure Elixir, no manifest) are indistinguishable from
  ordinary libraries until activated, so they appear only once listed in
  `config :mob, :plugins`.

  Activation is two-step by design (see `MOB_PLUGINS.md`): adding a plugin to
  `deps` makes it *installed*; adding it to `config :mob, :plugins` makes it
  *activated* — only then are its contributions merged into the build.
  """

  alias MobDev.Plugin.{Manifest, Report, Validator}

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("loadpaths")

    deps = load_all_manifests()
    activated = activated_plugins()
    dep_dirs = Mix.Project.deps_paths()

    deps
    |> Report.rows(activated)
    |> Report.with_vetting(dep_dirs)
    |> Report.render()
    |> then(&IO.puts("\n" <> &1 <> "\n"))

    report_conflicts(deps, activated)
  end

  defp report_conflicts(deps, activated) do
    activated_manifests = for {name, manifest} <- deps, name in activated, do: {name, manifest}

    case Validator.cross_validate(activated_manifests) do
      %{errors: []} ->
        :ok

      %{errors: errors} ->
        Mix.shell().error("Plugin activation conflicts:")
        Enum.each(errors, &Mix.shell().error("  ✗ #{&1}"))
        IO.puts("")
    end
  end

  defp load_all_manifests do
    Mix.Project.deps_paths()
    |> Enum.map(fn {app, path} ->
      case Manifest.load(path) do
        {:ok, manifest} ->
          {app, manifest}

        {:error, reason} ->
          Mix.shell().info([:yellow, "[mob.plugins] skipping #{app}: #{reason}", :reset])
          {app, nil}
      end
    end)
  end

  # Reads `config :mob, :plugins` from mob.exs (the build config). Falls back
  # to the loaded Application env, then an empty list.
  defp activated_plugins do
    config_file = Path.join(File.cwd!(), "mob.exs")

    raw =
      if File.exists?(config_file) do
        config_file
        |> Config.Reader.read!()
        |> Keyword.get(:mob, [])
        |> Keyword.get(:plugins, [])
      else
        Application.get_env(:mob, :plugins, [])
      end

    normalize_activated(raw)
  rescue
    _ -> normalize_activated(Application.get_env(:mob, :plugins, []))
  end

  @doc false
  # Pure kernel: coerces a `config :mob, :plugins` value into a clean list of
  # atom plugin names. A misconfigured value (a non-list, or a list carrying
  # non-atom entries like a stray string typo `"mob_haptic"`) must not crash
  # `mix mob.plugins` — `name in activated` raises Protocol.UndefinedError on a
  # non-list, and downstream `name in activated` silently mismatches string
  # entries. Non-list → `[]`; lists are filtered down to their atom entries.
  @spec normalize_activated(term()) :: [atom()]
  def normalize_activated(plugins) when is_list(plugins),
    do: Enum.filter(plugins, &is_atom/1)

  def normalize_activated(_other), do: []
end
