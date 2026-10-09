defmodule MobDev.Plugin.HostPlistConflictsTest do
  # Changes the cwd, so not async.
  use ExUnit.Case, async: false

  alias MobDev.Plugin.Validator

  @base %{name: :p, mob_version: "~> 0.6", plugin_spec_version: 1}

  # A scalar key that isn't a usage description: those combine (MOB-421), so
  # the host exemption only matters for keys like this one.
  @plugins [
    {:a, Map.put(@base, :ios, %{plist_keys: %{"UIStatusBarStyle" => "A"}})},
    {:b, Map.put(%{@base | name: :b}, :ios, %{plist_keys: %{"UIStatusBarStyle" => "B"}})}
  ]

  @host_plist """
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  <plist version="1.0">
  <dict>
      <key>UIStatusBarStyle</key>
      <string>host</string>
  </dict>
  </plist>
  """

  @tag :tmp_dir
  test "the native build's gate reads the project's ios/Info.plist", %{tmp_dir: dir} do
    File.cd!(dir, fn ->
      assert_raise Mix.Error,
                   ~r/"UIStatusBarStyle".*once the project's own ios\/Info.plist sets it/s,
                   fn ->
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
      assert Validator.host_plist_keys(path) == ["UIStatusBarStyle"]
    else
      File.write!(path, "bplist00garbage")
      assert Validator.host_plist_keys(path) == []
    end
  end
end
