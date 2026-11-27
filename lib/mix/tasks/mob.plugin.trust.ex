defmodule Mix.Tasks.Mob.Plugin.Trust do
  use Mix.Task

  @shortdoc "Trust a signed mob plugin by fingerprint"

  @moduledoc """
  Records trust in a signed mob plugin by writing
  `config :mob, :trusted_plugins, %{...}` to `mob.exs`.

      mix mob.plugin.trust <plugin_name>

  Resolves the plugin via `Mix.Project.deps_paths/0`, reads its
  `priv/mob_plugin.pub`, verifies its v2 signature envelope
  (`MobDev.Plugin.Verify.load_verified/1`), and only then evaluates the
  manifest. It displays the fingerprint and the capabilities the verified
  manifest declares (frameworks, permissions, gradle deps, plist keys) and
  prompts `y/N` before recording the entry.

  A plugin whose signature is missing, does not verify, or is a legacy v1
  envelope is refused, and a manifest that has not verified is never
  evaluated: there is nothing to trust without a valid signature (MOB-550).
  An unsigned plugin can still be used during development through
  `config :mob, :acknowledge_unsafe_plugins`.

  Key rotation: if a different fingerprint is already trusted for this
  plugin name, this task warns and prompts for explicit confirmation
  before replacing the entry.
  """

  alias MobDev.Plugin.{Crypto, TrustStore, Verify}

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("loadpaths")
    run_with_deps(args, Mix.Project.deps_paths(), File.cwd!(), Mix.Project.deps_path())
  end

  @doc false
  # Public for tests: lets the test inject a deps_paths map, project dir and
  # deps dir without having to fake out Mix.Project. `deps_dir` is the
  # project's `Mix.Project.deps_path/0` (an umbrella child's is the umbrella's,
  # and `deps_path:`/`MIX_DEPS_PATH` move it); a dependency outside it is a
  # path dependency.
  @spec run_with_deps([String.t()], %{atom() => Path.t()}, Path.t(), Path.t()) :: :ok
  def run_with_deps(args, deps_paths, project_dir, deps_dir) do
    name = parse_name!(args)
    plugin_dir = resolve_dep!(name, deps_paths)
    path_dep? = path_dep?(plugin_dir, deps_dir)
    # Verify first: its errors say what the plugin lacks (an unsigned plugin
    # with no key is unsigned, not keyless; a tier-0 one has no manifest), and
    # the key read below is the one that just verified.
    manifest = load_verified_manifest!(plugin_dir, name, path_dep?)
    pub = load_pubkey!(plugin_dir, name, path_dep?)
    fingerprint = Crypto.fingerprint(pub)

    existing = Map.get(TrustStore.load_trusted_plugins(project_dir), name)

    print_summary(
      name,
      manifest,
      version(manifest, plugin_dir, deps_dir),
      fingerprint,
      existing
    )

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

  defp load_pubkey!(plugin_dir, name, path_dep?) do
    case Verify.load_pubkey(plugin_dir) do
      {:ok, pub} ->
        pub

      {:error, :missing} ->
        Mix.raise(refusal_message(name, :missing_pubkey, path_dep?))

      {:error, :malformed} ->
        Mix.raise(
          "plugin #{inspect(name)} has a malformed priv/mob_plugin.pub " <>
            "(expected base64 of raw 32 bytes)"
        )
    end
  end

  # Verification runs before priv/mob_plugin.exs is evaluated; a manifest that
  # has not verified never runs (MOB-550).
  defp load_verified_manifest!(plugin_dir, name, path_dep?) do
    case Verify.load_verified(plugin_dir) do
      {:ok, manifest} when is_map(manifest) ->
        manifest

      {:ok, nil} ->
        Mix.raise("plugin #{inspect(name)} has no priv/mob_plugin.exs manifest")

      {:error, reason} ->
        Mix.raise(refusal_message(name, reason, path_dep?))
    end
  end

  @doc false
  # Why `mix mob.plugin.trust` refuses a plugin, for each
  # `Verify.load_verified/1` error. A binary reason is a manifest that
  # verified but failed to evaluate. A path dependency (a local checkout) is
  # not changed by `deps.get`/`deps.update`, so its remedy is re-signing in
  # place. Public for testing.
  @spec refusal_message(atom(), Verify.verify_error() | String.t(), boolean()) :: String.t()
  def refusal_message(name, :missing_signature, _path_dep?) do
    "plugin #{inspect(name)} is not signed (no priv/mob_plugin.sig), so there is " <>
      "nothing to trust. Ask the author to run `mix mob.plugin.sign` and re-publish. " <>
      "To use it unsigned during development, add\n" <>
      "    config :mob, :acknowledge_unsafe_plugins, [#{inspect(name)}]\n" <>
      "to mob.exs instead. mob.exs is unchanged."
  end

  def refusal_message(name, :missing_pubkey, _path_dep?) do
    "plugin #{inspect(name)} ships no priv/mob_plugin.pub — " <>
      "ask the author to run `mix mob.plugin.keygen` and re-publish"
  end

  def refusal_message(name, :invalid_signature, path_dep?) do
    "the signature for plugin #{inspect(name)} does not verify against its " <>
      "priv/mob_plugin.pub, or a file changed after it was signed. mob.exs is unchanged. " <>
      invalid_signature_remedy(name, path_dep?)
  end

  def refusal_message(name, :envelope_v1_unsupported, path_dep?) do
    "plugin #{inspect(name)} ships a legacy v1 signature, which mob_dev does not " <>
      "accept. mob.exs is unchanged. " <> v1_remedy(name, path_dep?)
  end

  def refusal_message(name, reason, _path_dep?) when is_binary(reason) do
    "could not load manifest for #{inspect(name)}: #{reason}"
  end

  defp invalid_signature_remedy(name, true = _path_dep?), do: resign_in_place(name)

  defp invalid_signature_remedy(name, false = _path_dep?) do
    "Reinstall it (`mix deps.clean #{name} && mix deps.get`); if it still does not " <>
      "verify, report it to the plugin author."
  end

  defp v1_remedy(name, true = _path_dep?), do: resign_in_place(name)

  defp v1_remedy(name, false = _path_dep?) do
    "Update it to a v2-signed release with `mix deps.update #{name}` (a git dependency " <>
      "pinned with ref:/tag: needs a v2-signed ref), or ask the author to re-sign with " <>
      "`mix mob.plugin.sign` on mob_dev 0.7.2 or later."
  end

  defp resign_in_place(name) do
    "It is a path dependency, which deps.get does not change: re-sign it in its " <>
      "directory with `mix mob.plugin.sign` (key: ~/.mob/keys/#{name}.priv)."
  end

  defp print_summary(name, manifest, version, fingerprint, existing) do
    Mix.shell().info([
      "\nReview ",
      :cyan,
      Atom.to_string(name),
      :reset,
      ":\n",
      "  version:      #{version}\n",
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

  @doc false
  # What to show as the plugin's version. Manifests rarely declare one, so
  # this falls back to the package's own version: Hex metadata, else the
  # `version:` in its mix.exs, read without evaluating it (the plugin is not
  # trusted yet). A dependency outside the project's deps dir
  # (`Mix.Project.deps_path/0`) is a path dependency, and its location is
  # shown too (MOB-334). Public for testing.
  @spec version(map(), Path.t(), Path.t()) :: String.t()
  def version(manifest, plugin_dir, deps_dir) do
    declared = manifest[:version] || hex_version(plugin_dir) || mix_exs_version(plugin_dir)

    if path_dep?(plugin_dir, deps_dir) do
      "#{declared || "(not declared)"} (path dependency: #{plugin_dir})"
    else
      declared || "(unset)"
    end
  end

  defp path_dep?(plugin_dir, deps_dir) do
    not String.starts_with?(Path.expand(plugin_dir), Path.expand(deps_dir) <> "/")
  end

  defp hex_version(plugin_dir) do
    with {:ok, terms} <- :file.consult(Path.join(plugin_dir, "hex_metadata.config")),
         {"version", version} <- List.keyfind(terms, "version", 0) do
      version
    else
      _ -> nil
    end
  end

  # `version: "1.2.3"` or `version: @version` with `@version "1.2.3"`.
  defp mix_exs_version(plugin_dir) do
    with {:ok, source} <- File.read(Path.join(plugin_dir, "mix.exs")),
         {:ok, ast} <- Code.string_to_quoted(source) do
      {_ast, {attrs, version}} =
        Macro.prewalk(ast, {%{}, nil}, fn
          {:@, _, [{attr, _, [value]}]} = node, {attrs, version}
          when is_atom(attr) and is_binary(value) ->
            {node, {Map.put(attrs, attr, value), version}}

          {:version, value} = node, {attrs, nil} ->
            {node, {attrs, value}}

          node, acc ->
            {node, acc}
        end)

      case version do
        value when is_binary(value) -> value
        {:@, _, [{attr, _, context}]} when is_atom(context) -> Map.get(attrs, attr)
        _ -> nil
      end
    else
      _ -> nil
    end
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
