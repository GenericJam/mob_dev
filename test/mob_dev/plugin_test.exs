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
end
