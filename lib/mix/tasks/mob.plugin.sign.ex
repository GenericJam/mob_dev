defmodule Mix.Tasks.Mob.Plugin.Sign do
  use Mix.Task

  @shortdoc "Sign a mob plugin's manifest + source files"

  @moduledoc """
  Signs the plugin in `<dir>` (default: cwd) and writes
  `priv/mob_plugin.sig`. The signature covers the loaded manifest
  plus SHA-256 hashes of every file the manifest references.

      mix mob.plugin.sign [--plugin <dir>]

  Reads the private key for the plugin's `:name` from
  `~/.mob/keys/<name>.priv`. Run `mix mob.plugin.keygen` first if you
  haven't already.

  After signing, the printed fingerprint can be shared with host
  operators so they can run `mix mob.plugin.trust <name>` to record
  trust in their `mob.exs`.
  """

  alias MobDev.Plugin.{Crypto, Manifest, PrivateKeyStore, Sign, Verify}

  @switches [plugin: :string]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: @switches)
    plugin_dir = opts[:plugin] || File.cwd!()

    {name, manifest} = load_manifest!(plugin_dir)
    priv = read_priv_key!(name)

    case Sign.sign_plugin(plugin_dir, priv) do
      :ok ->
        sig_path = Sign.signature_path(plugin_dir)
        print_success(plugin_dir, name, manifest, sig_path)

      {:error, reason} ->
        Mix.raise("signing failed: #{inspect(reason)}")
    end
  end

  defp load_manifest!(plugin_dir) do
    case Manifest.load(plugin_dir) do
      {:ok, %{name: name} = manifest} when is_atom(name) and not is_nil(name) ->
        {name, manifest}

      {:ok, nil} ->
        Mix.raise(
          "no priv/mob_plugin.exs in #{plugin_dir} — a plugin needs a manifest before it can be signed"
        )

      {:ok, _} ->
        Mix.raise("#{plugin_dir}/priv/mob_plugin.exs is missing a :name field")

      {:error, reason} ->
        Mix.raise("could not load plugin manifest at #{plugin_dir}: #{reason}")
    end
  end

  defp read_priv_key!(name) do
    case PrivateKeyStore.read_key(name) do
      {:ok, priv} ->
        priv

      {:error, :missing} ->
        Mix.raise(
          "no private key for #{name} at #{PrivateKeyStore.key_path(name)} — " <>
            "run `mix mob.plugin.keygen` first"
        )

      {:error, :malformed} ->
        Mix.raise(
          "private key at #{PrivateKeyStore.key_path(name)} is malformed " <>
            "(expected base64 of raw 32 bytes)"
        )
    end
  end

  defp print_success(plugin_dir, name, _manifest, sig_path) do
    fingerprint =
      case Verify.load_pubkey(plugin_dir) do
        {:ok, pub} -> Crypto.fingerprint(pub)
        _ -> "(no priv/mob_plugin.pub; run mix mob.plugin.keygen)"
      end

    Mix.shell().info([
      :green,
      "  signed  ",
      :reset,
      "#{name}\n",
      "  signature:   #{sig_path}\n",
      "  fingerprint: ",
      :cyan,
      fingerprint,
      :reset,
      "\n\nShare the fingerprint with host operators so they can run\n",
      "  mix mob.plugin.trust #{name}\n",
      "in their host project to record trust in mob.exs.\n"
    ])
  end
end
