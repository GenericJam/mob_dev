defmodule Mix.Tasks.Mob.Plugin.Trust do
  use Mix.Task

  @shortdoc "Trust a signed mob plugin by fingerprint"

  @moduledoc """
  Records trust in a signed mob plugin by writing
  `config :mob, :trusted_plugins, %{...}` to `mob.exs`.

      mix mob.plugin.trust <plugin_name>

  Resolves the plugin via `Mix.Project.deps_paths/0`, reads its
  `priv/mob_plugin.pub` + manifest, displays the declared capabilities
  (frameworks, permissions, gradle deps, plist keys) plus the
  fingerprint, and prompts `y/N` before recording the entry.

  Key rotation: if a different fingerprint is already trusted for this
  plugin name, this task warns and prompts for explicit confirmation
  before replacing the entry.
  """

  alias MobDev.Plugin.{Crypto, Manifest, TrustStore, Verify}

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("loadpaths")
    run_with_deps(args, Mix.Project.deps_paths(), File.cwd!())
  end

  @doc false
  # Public for tests: lets the test inject a deps_paths map and project
  # dir without having to fake out Mix.Project.
  @spec run_with_deps([String.t()], %{atom() => Path.t()}, Path.t()) :: :ok
  def run_with_deps(args, deps_paths, project_dir) do
    name = parse_name!(args)
    plugin_dir = resolve_dep!(name, deps_paths)
    pub = load_pubkey!(plugin_dir, name)
    manifest = load_manifest!(plugin_dir, name)
    fingerprint = Crypto.fingerprint(pub)

    existing = Map.get(TrustStore.load_trusted_plugins(project_dir), name)
    print_summary(name, manifest, fingerprint, existing)

    prompt = trust_prompt(existing, fingerprint)

    if Mix.shell().yes?(prompt) do
      :ok = TrustStore.add_trust(name, pub, project_dir)

      Mix.shell().info([
        :green,
        "  trusted  ",
        :reset,
        "#{name} (",
        :cyan,
        fingerprint,
        :reset,
        ") — recorded in mob.exs\n"
      ])

      :ok
    else
      Mix.shell().info("aborted — mob.exs unchanged")
      :ok
    end
  end

  defp parse_name!([name | _]) when is_binary(name) and name != "",
    do: String.to_atom(name)

  defp parse_name!(_), do: Mix.raise("usage: mix mob.plugin.trust <plugin_name>")

  defp resolve_dep!(name, deps_paths) do
    case Map.get(deps_paths, name) do
      nil ->
        Mix.raise(
          "no dependency named #{inspect(name)} — add it to mix.exs deps " <>
            "and run `mix deps.get` first"
        )

      dir ->
        dir
    end
  end

  defp load_pubkey!(plugin_dir, name) do
    case Verify.load_pubkey(plugin_dir) do
      {:ok, pub} ->
        pub

      {:error, :missing} ->
        Mix.raise(
          "plugin #{inspect(name)} ships no priv/mob_plugin.pub — " <>
            "ask the author to run `mix mob.plugin.keygen` and re-publish"
        )

      {:error, :malformed} ->
        Mix.raise(
          "plugin #{inspect(name)} has a malformed priv/mob_plugin.pub " <>
            "(expected base64 of raw 32 bytes)"
        )
    end
  end

  defp load_manifest!(plugin_dir, name) do
    case Manifest.load(plugin_dir) do
      {:ok, manifest} when is_map(manifest) ->
        manifest

      {:ok, nil} ->
        Mix.raise("plugin #{inspect(name)} has no priv/mob_plugin.exs manifest")

      {:error, reason} ->
        Mix.raise("could not load manifest for #{inspect(name)}: #{reason}")
    end
  end

  defp print_summary(name, manifest, fingerprint, existing) do
    Mix.shell().info([
      "\nReview ",
      :cyan,
      Atom.to_string(name),
      :reset,
      ":\n",
      "  version:      #{manifest[:version] || "(unset)"}\n",
      "  fingerprint:  ",
      :cyan,
      fingerprint,
      :reset,
      "\n",
      existing_line(existing, fingerprint),
      capability_lines(manifest),
      "\n"
    ])
  end

  defp existing_line(nil, _new), do: ""

  defp existing_line(existing, new) when existing == new do
    "  trust state:  already trusted (no change)\n"
  end

  defp existing_line(existing, _new) do
    [
      "  ",
      IO.ANSI.yellow(),
      "trust state:  KEY ROTATION — currently trusted: #{existing}",
      IO.ANSI.reset(),
      "\n"
    ]
  end

  defp capability_lines(manifest) do
    [
      list_line("ios frameworks", get_in(manifest, [:ios, :frameworks])),
      list_line("android permissions", get_in(manifest, [:android, :permissions])),
      list_line("android gradle_deps", get_in(manifest, [:android, :gradle_deps])),
      plist_line(get_in(manifest, [:ios, :plist_keys]))
    ]
  end

  defp list_line(_label, nil), do: ""
  defp list_line(_label, []), do: ""

  defp list_line(label, list) when is_list(list) do
    "  #{label}: #{inspect(list)}\n"
  end

  defp plist_line(map) when is_map(map) and map_size(map) > 0 do
    "  ios plist_keys: #{inspect(Map.keys(map))}\n"
  end

  defp plist_line(_), do: ""

  defp trust_prompt(nil, _new), do: "Trust this plugin? [y/N]"

  defp trust_prompt(existing, new) when existing == new, do: "Re-confirm trust? [y/N]"

  defp trust_prompt(_existing, _new),
    do: "This replaces a previously trusted key (key rotation). Trust the new key? [y/N]"
end
