defmodule MobDev.Plugin.HostPlistConflictsTest do
  # Changes the cwd, so not async.
  use ExUnit.Case, async: false

  alias MobDev.Plugin.Validator

  @base %{name: :p, mob_version: "~> 0.6", plugin_spec_version: 1}

  @plugins [
    {:a, Map.put(@base, :ios, %{plist_keys: %{"NSBluetoothAlwaysUsageDescription" => "A"}})},
    {:b,
     Map.put(%{@base | name: :b}, :ios, %{
       plist_keys: %{"NSBluetoothAlwaysUsageDescription" => "B"}
     })}
  ]

  @host_plist """
  <?xml version="1.0" encoding="UTF-8"?>
  <plist version="1.0">
  <dict>
      <key>NSBluetoothAlwaysUsageDescription</key>
      <string>host</string>
  </dict>
  </plist>
  """

  @tag :tmp_dir
  test "the native build's gate reads the project's ios/Info.plist", %{tmp_dir: dir} do
    File.cd!(dir, fn ->
      assert_raise Mix.Error, ~r/NSBluetoothAlwaysUsageDescription/, fn ->
        Validator.raise_on_cross_plugin_conflicts!(@plugins)
      end

      File.mkdir_p!("ios")
      File.write!("ios/Info.plist", @host_plist)
      assert Validator.raise_on_cross_plugin_conflicts!(@plugins) == :ok
    end)
  end

  @tag :tmp_dir
  test "host_plist_keys/1 reads a binary plist via plutil", %{tmp_dir: dir} do
    plutil = System.find_executable("plutil")
    path = Path.join(dir, "Info.plist")
    File.write!(path, @host_plist)

    if plutil do
      {_, 0} = System.cmd(plutil, ["-convert", "binary1", path])
      assert File.read!(path) =~ ~r/\Abplist/
      assert Validator.host_plist_keys(path) == ["NSBluetoothAlwaysUsageDescription"]
    else
      File.write!(path, "bplist00garbage")
      assert Validator.host_plist_keys(path) == []
    end
  end
end
