defmodule Mix.Tasks.Mob.Plugin.Keygen do
  use Mix.Task

  @shortdoc "Generate an Ed25519 keypair for signing a mob plugin"

  @moduledoc """
  Generates a per-plugin Ed25519 keypair and writes:

  - `~/.mob/keys/<plugin_name>.priv` — base64-encoded raw 32-byte private
    key, mode 0600.
  - `priv/mob_plugin.pub` in the plugin directory — base64-encoded raw
    32-byte public key.

  The public key file ships with the plugin (committed to source
  control); the private key never leaves the author's machine.

      mix mob.plugin.keygen [--plugin <dir>] [--force]

  ## Options

    * `--plugin <dir>` — plugin directory; defaults to the current
      working directory.
    * `--force` — overwrite an existing `~/.mob/keys/<name>.priv`.
      Refused by default to prevent an accidental key rotation.
  """

  alias MobDev.Plugin.{Crypto, Manifest, PrivateKeyStore}

  @switches [plugin: :string, force: :boolean]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: @switches)
    plugin_dir = opts[:plugin] || File.cwd!()
    force? = Keyword.get(opts, :force, false)

    name = plugin_name!(plugin_dir)
    refuse_if_exists!(name, force?)

    {priv, pub} = Crypto.generate_keypair()

    :ok = PrivateKeyStore.write_key(name, priv)
    pub_path = write_pubkey!(plugin_dir, pub)

    Mix.shell().info([
      :green,
      "  generated  ",
      :reset,
      "ed25519 keypair for #{name}\n",
      "  private key: #{PrivateKeyStore.key_path(name)} (mode 0600)\n",
      "  public key:  #{pub_path}\n",
      "  fingerprint: ",
      :cyan,
      Crypto.fingerprint(pub),
      :reset,
      "\n\nNext: run `mix mob.plugin.sign` to produce priv/mob_plugin.sig.\n"
    ])
  end

  defp plugin_name!(plugin_dir) do
    case Manifest.load(plugin_dir) do
      {:ok, %{name: name}} when is_atom(name) and not is_nil(name) ->
        name

      {:ok, _} ->
        Mix.raise(
          "#{plugin_dir}/priv/mob_plugin.exs is missing a :name field — " <>
            "a plugin needs a manifest before it can be signed"
        )

      {:error, reason} ->
        Mix.raise("could not load plugin manifest at #{plugin_dir}: #{reason}")
    end
  end

  defp refuse_if_exists!(name, false) do
    path = PrivateKeyStore.key_path(name)

    if File.exists?(path) do
      Mix.raise(
        "private key already exists at #{path} — pass --force to overwrite " <>
          "(this is a key rotation; existing hosts will need to re-run " <>
          "mix mob.plugin.trust)"
      )
    end
  end

  defp refuse_if_exists!(_name, true), do: :ok

  defp write_pubkey!(plugin_dir, pub) do
    path = Path.join(plugin_dir, "priv/mob_plugin.pub")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Base.encode64(pub) <> "\n")
    path
  end
end
