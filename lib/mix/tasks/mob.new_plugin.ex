defmodule Mix.Tasks.Mob.NewPlugin do
  use Mix.Task

  @shortdoc "Scaffold a new mob plugin (tier 0–4)"

  @moduledoc """
  Generates the skeleton for a new mob plugin under `plugins/<name>/`.

      mix mob.new_plugin <name> [--tier <0|1|2|3|4>] [--dest <DIR>]

  Tiers (per `MOB_PLUGINS.md`):

  - `0` (default) — pure-Elixir helpers. No manifest, no native code.
  - `1` — native NIF + Elixir wrapper. Manifest with `:nifs`; ships an Erlang
    NIF stub and the matching C source. Wired into the build by
    `MobDev.Plugin.Merge.nifs/1` + the build.zig `-Dplugin_c_nifs` arg.
  - `2` — native UI component via `Mob.UI.native_view` + `Mob.Component`.
    Manifest with `:ui_components`; ships an Elixir `Mob.Component` module,
    the matching Kotlin Composable, and a Swift View placeholder.
  - `3` — multi-screen plugin. Manifest with `:screens` + `:migrations` (and
    optionally `:assets`); ships two `Mob.Screen` modules and an Ecto migration
    the host applies on device.
  - `4` — embedded sub-app. Manifest with `:lifecycle` + `:settings` +
    `:notifications`; ships a lifecycle module, a supervised worker, a
    notification handler, and a settings editor screen.

  ## Options

    * `--tier <0|1|2|3|4>` — plugin tier; defaults to `0`.
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
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)

    refuse_invalid!(invalid)
    name = parse_name!(positional)
    tier = Keyword.get(opts, :tier, 0)

    with :ok <- Scaffold.validate_name(name),
         :ok <- Scaffold.validate_tier(tier) do
      dest = opts[:dest] || Path.join([File.cwd!(), "plugins", name])
      refuse_if_exists!(dest)
      write_files!(dest, Scaffold.files_for(tier, name, Scaffold.detect_mob_requirement()))
      print_next_steps(name, tier)
    else
      {:error, reason} -> Mix.raise(reason)
    end
  end

  defp parse_name!([name | _]) when is_binary(name) and name != "", do: name
  defp parse_name!(_), do: Mix.raise("usage: mix mob.new_plugin <name> [--tier 0|1|2]")

  # OptionParser's third element holds switches it could not parse: an unknown
  # flag, or a bad value for a typed switch (e.g. `--tier abc` for an :integer).
  # Without this guard those are silently dropped, so `mix mob.new_plugin foo
  # --tier two` would scaffold a tier-0 plugin instead of erroring — the user's
  # requested tier vanishes with no signal.
  defp refuse_invalid!(invalid) do
    case invalid_option_message(invalid) do
      :ok -> :ok
      {:error, msg} -> Mix.raise(msg)
    end
  end

  @doc false
  # Pure decision kernel for the `invalid` element of OptionParser.parse/2.
  # Returns `:ok` for an empty list, or `{:error, message}` describing the
  # unrecognized/badly-typed switches. `@doc false` — extracted for testing.
  @spec invalid_option_message([{String.t(), String.t() | nil}]) :: :ok | {:error, String.t()}
  def invalid_option_message([]), do: :ok

  def invalid_option_message(invalid) do
    flags =
      Enum.map_join(invalid, ", ", fn
        {flag, nil} -> flag
        {flag, val} -> "#{flag} #{val}"
      end)

    {:error,
     "unrecognized or invalid option(s): #{flags}\n" <>
       "usage: mix mob.new_plugin <name> [--tier 0|1|2|3|4] [--dest DIR]"}
  end

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

  defp tier_specific_hint(3, _name) do
    "  4. Tier 3: implement the two Mob.Screen modules + the Ecto migration.\n" <>
      "     The host registers your screens (by default_route) and applies the\n" <>
      "     migration on `mix mob.deploy --native`. Rename the migration file\n" <>
      "     with a real timestamp; add fonts/images under :assets when ready.\n"
  end

  defp tier_specific_hint(4, name) do
    "  4. Tier 4: flesh out lib/#{name}.ex (lifecycle), the supervised Worker,\n" <>
      "     the Notifications handler, and the settings schema. on_start +\n" <>
      "     supervised children run at boot under the host's plugin supervisor;\n" <>
      "     settings round-trip via Mob.Plugins get_setting/3 + put_setting/4.\n"
  end

  defp tier_specific_hint(_, _), do: ""
end
