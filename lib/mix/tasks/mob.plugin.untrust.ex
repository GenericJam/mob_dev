defmodule Mix.Tasks.Mob.Plugin.Untrust do
  use Mix.Task

  @shortdoc "Remove a plugin's trust entry from mob.exs"

  @moduledoc """
  Removes the `config :mob, :trusted_plugins` entry for `plugin_name`
  from `mob.exs`. No-op if the plugin wasn't trusted.

      mix mob.plugin.untrust <plugin_name>
  """

  alias MobDev.Plugin.TrustStore

  @impl Mix.Task
  def run(args) do
    run_in(args, File.cwd!())
  end

  @doc false
  # Public for tests: lets a test inject the project dir.
  @spec run_in([String.t()], Path.t()) :: :ok
  def run_in(args, project_dir) do
    name = parse_name!(args)

    if Map.has_key?(TrustStore.load_trusted_plugins(project_dir), name) do
      :ok = TrustStore.remove_trust(name, project_dir)

      Mix.shell().info([
        :green,
        "  untrusted  ",
        :reset,
        "#{name} — removed from mob.exs\n"
      ])

      :ok
    else
      Mix.shell().info("plugin #{inspect(name)} was not trusted — nothing to do")
      :ok
    end
  end

  defp parse_name!([name | _]) when is_binary(name) and name != "",
    do: String.to_atom(name)

  defp parse_name!(_), do: Mix.raise("usage: mix mob.plugin.untrust <plugin_name>")
end
