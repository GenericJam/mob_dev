defmodule MobDev.PluginTest do
  # async: false — mutates global Application env
  use ExUnit.Case, async: false

  alias MobDev.Plugin

  @host :mob_dev_plugin_test_host

  describe "host_config/3" do
    test "reads a configured key from the host app's env" do
      Application.put_env(@host, :ash_domains, [:blog, :auth])
      on_exit(fn -> Application.delete_env(@host, :ash_domains) end)

      assert Plugin.host_config(@host, :ash_domains, []) == [:blog, :auth]
    end

    test "returns the supplied default when the key is unset" do
      assert Plugin.host_config(@host, :never_set, []) == []
    end

    test "defaults to nil when no default is given" do
      assert Plugin.host_config(@host, :never_set) == nil
    end
  end

  describe "activated_names/1" do
    setup do
      dir = Path.join(System.tmp_dir!(), "mob_plugin_names_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "reads config :mob, :plugins from mob.exs", %{dir: dir} do
      File.write!(Path.join(dir, "mob.exs"), "import Config\nconfig :mob, :plugins, [:mob_foo]\n")
      assert Plugin.activated_names(dir) == [:mob_foo]
    end

    test "falls back to the Application env when mob.exs is missing", %{dir: dir} do
      original = Application.get_env(:mob, :plugins)
      Application.put_env(:mob, :plugins, [:mob_from_env])

      on_exit(fn ->
        if original,
          do: Application.put_env(:mob, :plugins, original),
          else: Application.delete_env(:mob, :plugins)
      end)

      assert Plugin.activated_names(dir) == [:mob_from_env]
    end

    # MOB-280: a broken mob.exs used to read as "no plugins", so the native
    # build linked no plugin NIFs and every call hit :nif_not_loaded.
    test "raises when mob.exs fails to evaluate", %{dir: dir} do
      File.write!(Path.join(dir, "mob.exs"), "import Config\nconfig :mob, :plugins, [:mob_foo\n")

      assert_raise TokenMissingError, fn -> Plugin.activated_names(dir) end
    end
  end
end
