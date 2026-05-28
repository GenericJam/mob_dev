defmodule Mix.Tasks.Mob.NewPlugin do
  use Mix.Task

  @shortdoc "Scaffold a new mob plugin (tier 0–2)"

  @moduledoc """
  Generates the skeleton for a new mob plugin under `plugins/<name>/`.

      mix mob.new_plugin <name> [--tier <0|1|2>] [--dest <DIR>]

  Tiers (per `MOB_PLUGINS.md`):

  - `0` (default) — pure-Elixir helpers. No manifest, no native code.
  - `1` — native NIF + Elixir wrapper. Manifest with `:nifs`; ships an Erlang
    NIF stub and the matching C source. Wired into the build by
    `MobDev.Plugin.Merge.nifs/1` + the build.zig `-Dplugin_c_nifs` arg.
  - `2` — native UI component via `Mob.UI.native_view` + `Mob.Component`.
    Manifest with `:ui_components`; ships an Elixir `Mob.Component` module,
    the matching Kotlin Composable, and a Swift View placeholder.

  ## Options

    * `--tier <0|1|2>` — plugin tier; defaults to `0`.
    * `--dest <DIR>` — destination directory; defaults to `plugins/<name>`
      relative to the current working directory.

  ## Activating

  After scaffolding:

      # mix.exs
      defp deps, do: [{:<name>, path: "plugins/<name>"} | …]

      # mob.exs
      config :mob, :plugins, [:<name>]
  """

  alias MobDev.Plugin.Scaffold

  @switches [tier: :integer, dest: :string]

  @impl Mix.Task
  def run(args) do
    {opts, positional, _} = OptionParser.parse(args, strict: @switches)

    name = parse_name!(positional)
    tier = Keyword.get(opts, :tier, 0)

    with :ok <- Scaffold.validate_name(name),
         :ok <- Scaffold.validate_tier(tier) do
      dest = opts[:dest] || Path.join([File.cwd!(), "plugins", name])
      refuse_if_exists!(dest)
      write_files!(dest, Scaffold.files_for(tier, name))
      print_next_steps(name, tier)
    else
      {:error, reason} -> Mix.raise(reason)
    end
  end

  defp parse_name!([name | _]) when is_binary(name) and name != "", do: name
  defp parse_name!(_), do: Mix.raise("usage: mix mob.new_plugin <name> [--tier 0|1|2]")

  defp refuse_if_exists!(dest) do
    if File.exists?(dest) do
      Mix.raise("refusing to overwrite existing directory: #{dest}")
    end
  end

  defp write_files!(dest, files) do
    Enum.each(files, fn {rel, content} ->
      path = Path.join(dest, rel)
      path |> Path.dirname() |> File.mkdir_p!()
      File.write!(path, content)
      Mix.shell().info([:green, "  create  ", :reset, Path.relative_to_cwd(path)])
    end)
  end

  defp print_next_steps(name, tier) do
    Mix.shell().info([
      :cyan,
      "\nNext steps:\n",
      :reset,
      "  1. Add the plugin to your host's deps in `mix.exs`:\n",
      "       {:#{name}, path: \"plugins/#{name}\"}\n",
      "  2. Activate it in `mob.exs`:\n",
      "       config :mob, :plugins, [:#{name}]\n",
      "  3. Run `mix deps.get && mix mob.plugins` to verify.\n",
      tier_specific_hint(tier, name)
    ])
  end

  defp tier_specific_hint(1, name) do
    nif = "#{name}_nif"

    "  4. Tier 1: the C NIF in priv/native/jni/#{nif}.c compiles + links via\n" <>
      "     mob_dev's plugin merge engine. Run `mix mob.deploy --native` to\n" <>
      "     pick it up; verify with `mix mob.validate_plugin` from the plugin dir.\n"
  end

  defp tier_specific_hint(2, name) do
    mod = MobDev.Plugin.Scaffold.module_name(name)

    "  4. Tier 2: copy priv/native/android/#{mod}.kt into the host's MobBridge.kt\n" <>
      "     (paste the @Composable + the #{mod}Plugin object), and call\n" <>
      "     #{mod}Plugin.register() from MobNativeViewRegistry's init {} block.\n" <>
      "     (Mix automation of this step is a future merge-engine slice.)\n"
  end

  defp tier_specific_hint(_, _), do: ""
end
