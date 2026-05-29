defmodule MobDev.Plugin.TrustStoreTest do
  use ExUnit.Case, async: true

  alias MobDev.Plugin.{Crypto, TrustStore}

  setup do
    dir =
      Path.join(System.tmp_dir!(), "mob_trust_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp seed_mob_exs(dir, contents) do
    File.write!(Path.join(dir, "mob.exs"), contents)
  end

  describe "load_trusted_plugins/1" do
    test "returns empty map when mob.exs is missing", %{dir: dir} do
      assert TrustStore.load_trusted_plugins(dir) == %{}
    end

    test "returns empty map when no :trusted_plugins entry", %{dir: dir} do
      seed_mob_exs(dir, "import Config\nconfig :mob, :plugins, [:mob_foo]\n")
      assert TrustStore.load_trusted_plugins(dir) == %{}
    end

    test "reads the :trusted_plugins map", %{dir: dir} do
      seed_mob_exs(dir, """
      import Config

      config :mob, :trusted_plugins, %{mob_foo: "ed25519:abc=", mob_bar: "ed25519:def="}
      """)

      assert TrustStore.load_trusted_plugins(dir) == %{
               mob_foo: "ed25519:abc=",
               mob_bar: "ed25519:def="
             }
    end
  end

  describe "add_trust/3" do
    test "writes a new entry to a previously empty mob.exs", %{dir: dir} do
      {_priv, pub} = Crypto.generate_keypair()
      seed_mob_exs(dir, "import Config\n")

      assert :ok = TrustStore.add_trust(:mob_foo, pub, dir)
      assert TrustStore.load_trusted_plugins(dir) == %{mob_foo: Crypto.fingerprint(pub)}
    end

    test "creates mob.exs when it doesn't exist", %{dir: dir} do
      {_priv, pub} = Crypto.generate_keypair()
      assert :ok = TrustStore.add_trust(:mob_foo, pub, dir)
      assert File.exists?(Path.join(dir, "mob.exs"))
      assert TrustStore.load_trusted_plugins(dir) == %{mob_foo: Crypto.fingerprint(pub)}
    end

    test "preserves unrelated config and comments", %{dir: dir} do
      seed_mob_exs(dir, """
      import Config

      # User comment that must survive
      config :mob, :plugins, [:mob_foo]
      config :my_app, :unrelated, "value"
      """)

      {_priv, pub} = Crypto.generate_keypair()
      assert :ok = TrustStore.add_trust(:mob_foo, pub, dir)

      contents = File.read!(Path.join(dir, "mob.exs"))
      assert contents =~ "# User comment that must survive"
      assert contents =~ "config :mob, :plugins, [:mob_foo]"
      assert contents =~ ~s(config :my_app, :unrelated, "value")
      assert contents =~ "trusted_plugins"
    end

    test "replaces an existing entry on key rotation", %{dir: dir} do
      {_p1, pub1} = Crypto.generate_keypair()
      {_p2, pub2} = Crypto.generate_keypair()

      seed_mob_exs(dir, "import Config\n")
      :ok = TrustStore.add_trust(:mob_foo, pub1, dir)
      :ok = TrustStore.add_trust(:mob_foo, pub2, dir)

      trust = TrustStore.load_trusted_plugins(dir)
      assert trust == %{mob_foo: Crypto.fingerprint(pub2)}
    end

    test "is idempotent — same fingerprint twice is a no-op", %{dir: dir} do
      {_priv, pub} = Crypto.generate_keypair()
      seed_mob_exs(dir, "import Config\n")

      :ok = TrustStore.add_trust(:mob_foo, pub, dir)
      first = File.read!(Path.join(dir, "mob.exs"))

      :ok = TrustStore.add_trust(:mob_foo, pub, dir)
      second = File.read!(Path.join(dir, "mob.exs"))

      assert first == second
    end

    test "merges a second plugin into the existing trusted_plugins map", %{dir: dir} do
      {_p1, pub1} = Crypto.generate_keypair()
      {_p2, pub2} = Crypto.generate_keypair()

      seed_mob_exs(dir, "import Config\n")
      :ok = TrustStore.add_trust(:mob_foo, pub1, dir)
      :ok = TrustStore.add_trust(:mob_bar, pub2, dir)

      trust = TrustStore.load_trusted_plugins(dir)
      assert Map.keys(trust) |> Enum.sort() == [:mob_bar, :mob_foo]
    end
  end

  describe "remove_trust/2" do
    test "removes an existing entry", %{dir: dir} do
      {_priv, pub} = Crypto.generate_keypair()
      seed_mob_exs(dir, "import Config\n")
      :ok = TrustStore.add_trust(:mob_foo, pub, dir)

      :ok = TrustStore.remove_trust(:mob_foo, dir)
      assert TrustStore.load_trusted_plugins(dir) == %{}
    end

    test "is a no-op when the plugin isn't trusted", %{dir: dir} do
      seed_mob_exs(dir, "import Config\n")
      assert :ok = TrustStore.remove_trust(:mob_foo, dir)
    end
  end

  describe "trusted?/3" do
    test "true when fingerprint matches the trust map" do
      {_priv, pub} = Crypto.generate_keypair()
      map = %{mob_foo: Crypto.fingerprint(pub)}
      assert TrustStore.trusted?(:mob_foo, pub, map)
    end

    test "false when no trust entry" do
      {_priv, pub} = Crypto.generate_keypair()
      refute TrustStore.trusted?(:mob_foo, pub, %{})
    end

    test "false when fingerprint mismatches (key rotation case)" do
      {_p1, pub1} = Crypto.generate_keypair()
      {_p2, pub2} = Crypto.generate_keypair()
      map = %{mob_foo: Crypto.fingerprint(pub1)}
      refute TrustStore.trusted?(:mob_foo, pub2, map)
    end
  end
end
