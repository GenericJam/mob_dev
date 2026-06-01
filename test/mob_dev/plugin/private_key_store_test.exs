defmodule MobDev.Plugin.PrivateKeyStoreTest do
  use ExUnit.Case, async: false

  alias MobDev.Plugin.{Crypto, PrivateKeyStore}

  setup do
    # PrivateKeyStore reads the home dir via the :mob_dev / :plugin_key_home
    # Application env (HOME env-var is cached by Erlang at boot and can't
    # be overridden mid-process). Point it at a tmpdir for the test so we
    # don't touch the developer's real key store. async: false because
    # we mutate process-wide env.
    tmp_home =
      Path.join(System.tmp_dir!(), "mob_keystore_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_home)
    previous = Application.get_env(:mob_dev, :plugin_key_home)
    Application.put_env(:mob_dev, :plugin_key_home, tmp_home)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:mob_dev, :plugin_key_home, previous),
        else: Application.delete_env(:mob_dev, :plugin_key_home)

      File.rm_rf!(tmp_home)
    end)

    {:ok, home: tmp_home}
  end

  describe "key_path/1" do
    test "lives under ~/.mob/keys/", %{home: home} do
      path = PrivateKeyStore.key_path(:mob_foo)
      assert path == Path.join([home, ".mob/keys", "mob_foo.priv"])
    end
  end

  describe "write_key/2 + read_key/1 round-trip" do
    test "writes a base64-encoded key and reads it back", %{home: _home} do
      {priv, _pub} = Crypto.generate_keypair()
      :ok = PrivateKeyStore.write_key(:mob_foo, priv)
      assert {:ok, ^priv} = PrivateKeyStore.read_key(:mob_foo)
    end

    test "writes the file with mode 0600", %{home: _home} do
      {priv, _pub} = Crypto.generate_keypair()
      :ok = PrivateKeyStore.write_key(:mob_foo, priv)

      %File.Stat{mode: mode} = File.stat!(PrivateKeyStore.key_path(:mob_foo))
      # Lower 9 bits are the rwx mask; 0o600 = owner rw, no group/other.
      assert Bitwise.band(mode, 0o777) == 0o600
    end

    test "creates the keys directory if missing", %{home: home} do
      File.rm_rf!(Path.join(home, ".mob"))
      {priv, _pub} = Crypto.generate_keypair()
      :ok = PrivateKeyStore.write_key(:mob_bar, priv)
      assert File.dir?(Path.join([home, ".mob/keys"]))
    end
  end

  describe "read_key/1 error cases" do
    test "returns :missing when no key file exists" do
      assert {:error, :missing} = PrivateKeyStore.read_key(:nonexistent)
    end

    test "returns :malformed when the file isn't base64" do
      path = PrivateKeyStore.key_path(:mob_bad)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "not base64!!!\n")
      assert {:error, :malformed} = PrivateKeyStore.read_key(:mob_bad)
    end

    test "returns :malformed when the decoded key is the wrong size" do
      path = PrivateKeyStore.key_path(:mob_short)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, Base.encode64(<<1, 2, 3>>) <> "\n")
      assert {:error, :malformed} = PrivateKeyStore.read_key(:mob_short)
    end
  end
end
