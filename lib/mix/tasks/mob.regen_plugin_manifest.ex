defmodule Mix.Tasks.Mob.RegenPluginManifest do
  use Mix.Task

  alias MobDev.Plugin.RuntimeManifest

  @shortdoc "Regenerate priv/generated/mob_plugins.exs from the activated plugins"

  @moduledoc """
  Regenerates `priv/generated/mob_plugins.exs` — the host's **runtime plugin
  manifest** — from the activated plugins' tier-3/4 manifest sections.

      mix mob.regen_plugin_manifest          # regenerate the file
      mix mob.regen_plugin_manifest --check  # verify on-disk matches, non-zero on drift

  Tiers 3 (multi-screen) and 4 (sub-app) are pure-Elixir and runtime-wired: the
  on-device `Mob.Plugins` module reads this file at boot to learn which screens,
  lifecycle hooks, settings, and notification handlers the activated plugins
  declared (`MobDev.Plugin.activated/0` is compile-time only). Spec-v2
  `:screens_generator`s run here, under the host-config audit.

  Like `mix mob.regen_driver_tab`, the output is committed so reviewers see the
  runtime surface, and the file is regenerated whenever `config :mob, :plugins`
  changes. `mob.doctor` runs `--check` to report drift.
  """

  @rel_path "priv/generated/mob_plugins.exs"

  @impl Mix.Task
  def run(args) do
    # Spec-v2 generators may call HOST modules (mob_ash introspects the host's
    # Ash domains), not just read config values — make sure the host app is
    # compiled, its config loaded, and its ebin on the code path. (Surfaced by
    # mob_ash: gen_screens only ever read config, masking this.)
    Mix.Task.run("app.config")

    {opts, _, _} = OptionParser.parse(args, strict: [check: :boolean])

    manifest = RuntimeManifest.build(MobDev.Plugin.activated())
    rendered = RuntimeManifest.render(manifest)
    path = Path.join(File.cwd!(), @rel_path)

    if opts[:check] do
      check_mode(path, rendered)
    else
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, rendered)
      Mix.shell().info("  ✓ #{@rel_path} (#{summary(manifest)})")
    end
  end

  defp check_mode(path, rendered) do
    case File.read(path) do
      {:ok, ^rendered} ->
        Mix.shell().info("  ✓ #{@rel_path} up to date")

      _ ->
        Mix.raise("#{@rel_path} is out of date — run `mix mob.regen_plugin_manifest`")
    end
  end

  defp summary(m) do
    "#{length(m.screens)} screens, #{length(m.lifecycle)} lifecycle, " <>
      "#{length(m.settings)} settings, #{length(m.notification_handlers)} handlers"
  end
end
