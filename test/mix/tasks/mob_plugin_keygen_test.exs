defmodule Mix.Tasks.Mob.Plugin.KeygenTest do
  use ExUnit.Case, async: false

  alias MobDev.Plugin.{Crypto, PrivateKeyStore, Verify}

  setup do
    tmp_home =
      Path.join(System.tmp_dir!(), "mob_keygen_home_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_home)
    previous = Application.get_env(:mob_dev, :plugin_key_home)
    Application.put_env(:mob_dev, :plugin_key_home, tmp_home)

    plugin_dir =
      Path.join(System.tmp_dir!(), "mob_keygen_plugin_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(plugin_dir, "priv"))

    manifest = %{name: :mob_keygen_demo, mob_version: "~> 0.6", plugin_spec_version: 1}
    File.write!(Path.join(plugin_dir, "priv/mob_plugin.exs"), inspect(manifest))

    on_exit(fn ->
      if previous,
        do: Application.put_env(:mob_dev, :plugin_key_home, previous),
        else: Application.delete_env(:mob_dev, :plugin_key_home)

      File.rm_rf!(tmp_home)
      File.rm_rf!(plugin_dir)
    end)

    {:ok, home: tmp_home, plugin_dir: plugin_dir}
  end

  test "writes priv key with mode 0600 and pub key in the plugin dir", %{plugin_dir: dir} do
    Mix.Tasks.Mob.Plugin.Keygen.run(["--plugin", dir])

    priv_path = PrivateKeyStore.key_path(:mob_keygen_demo)
    assert File.exists?(priv_path)
    %File.Stat{mode: mode} = File.stat!(priv_path)
    assert Bitwise.band(mode, 0o777) == 0o600

    pub_path = Path.join(dir, "priv/mob_plugin.pub")
    assert File.exists?(pub_path)

    # Pubkey decodes back to a 32-byte key and matches what Verify reads.
    assert {:ok, pub} = Verify.load_pubkey(dir)
    assert byte_size(pub) == 32
    assert Crypto.fingerprint(pub) =~ ~r/^ed25519:/
  end

  test "refuses to overwrite an existing priv key without --force", %{plugin_dir: dir} do
    Mix.Tasks.Mob.Plugin.Keygen.run(["--plugin", dir])

    assert_raise Mix.Error, ~r/already exists/, fn ->
      Mix.Tasks.Mob.Plugin.Keygen.run(["--plugin", dir])
    end
  end

  test "--force allows a key rotation", %{plugin_dir: dir} do
    Mix.Tasks.Mob.Plugin.Keygen.run(["--plugin", dir])
    {:ok, pub1} = Verify.load_pubkey(dir)

    Mix.Tasks.Mob.Plugin.Keygen.run(["--plugin", dir, "--force"])
    {:ok, pub2} = Verify.load_pubkey(dir)

    assert pub1 != pub2
  end

  test "errors when the plugin has no manifest", %{plugin_dir: dir} do
    File.rm!(Path.join(dir, "priv/mob_plugin.exs"))

    assert_raise Mix.Error, ~r/needs a manifest/, fn ->
      Mix.Tasks.Mob.Plugin.Keygen.run(["--plugin", dir])
    end
  end
end
