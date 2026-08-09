defmodule MobDev.ConfigTest do
  # bundle-id resolution reads mob.exs / ios/Info.plist relative to the cwd,
  # so these tests chdir into a fixture project.
  use ExUnit.Case, async: false

  alias MobDev.Config

  setup do
    cwd = File.cwd!()
    tmp = Path.join(System.tmp_dir!(), "mob_config_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    File.cd!(tmp)

    on_exit(fn ->
      File.cd!(cwd)
      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp}
  end

  defp write_mob_exs(tmp, body), do: File.write!(Path.join(tmp, "mob.exs"), body)

  defp write_info_plist(tmp, bundle_id) do
    File.mkdir_p!(Path.join(tmp, "ios"))

    File.write!(Path.join([tmp, "ios", "Info.plist"]), """
    <?xml version="1.0" encoding="UTF-8"?>
    <plist version="1.0">
    <dict>
      <key>CFBundleIdentifier</key>
      <string>#{bundle_id}</string>
    </dict>
    </plist>
    """)
  end

  describe "parse_platforms/1" do
    test "nil (unset) defaults to both platforms" do
      assert Config.parse_platforms(nil) == [:android, :ios]
    end

    test "a single platform is kept" do
      assert Config.parse_platforms([:ios]) == [:ios]
      assert Config.parse_platforms([:android]) == [:android]
    end

    test "both platforms normalize to a stable order" do
      assert Config.parse_platforms([:ios, :android]) == [:android, :ios]
    end

    test "unknown entries are dropped, valid ones kept" do
      assert Config.parse_platforms([:windows, :ios]) == [:ios]
    end

    test "an empty list falls back to both platforms" do
      assert Config.parse_platforms([]) == [:android, :ios]
    end

    test "a list with no valid platforms falls back to both" do
      assert Config.parse_platforms([:bogus, "ios"]) == [:android, :ios]
    end

    test "a non-list value falls back to both platforms" do
      assert Config.parse_platforms(:ios) == [:android, :ios]
      assert Config.parse_platforms("ios") == [:android, :ios]
    end
  end

  # ── ios_bundle_id/0 ───────────────────────────────────────────────────────────
  #
  # Original bug: `MobDev.Deployer` resolved the iOS id with plain
  # `bundle_id/0`, discarding `:ios_bundle_id`. The native build honoured it,
  # so `mix mob.deploy --native --device <iphone>` installed the app under the
  # configured id and then pushed BEAMs to an id that was never installed
  # ("App '...' is not installed on this device").
  #
  # The two ids genuinely differ in real projects: Android's `applicationId`
  # may contain underscores (`com.example.mishka_mob`) which Apple rejects.

  describe "ios_bundle_id/0" do
    test ":ios_bundle_id wins over :bundle_id", %{tmp: tmp} do
      write_mob_exs(tmp, """
      import Config
      config :mob_dev,
        bundle_id: "com.example.mishka_mob",
        ios_bundle_id: "com.genericjam.mishkamob"
      """)

      assert Config.ios_bundle_id() == "com.genericjam.mishkamob"
    end

    test "differs from bundle_id/0 — the Android id is left alone", %{tmp: tmp} do
      write_mob_exs(tmp, """
      import Config
      config :mob_dev,
        bundle_id: "com.example.mishka_mob",
        ios_bundle_id: "com.genericjam.mishkamob"
      """)

      assert Config.bundle_id() == "com.example.mishka_mob"
      refute Config.ios_bundle_id() == Config.bundle_id()
    end

    test "falls back to :bundle_id when :ios_bundle_id is unset", %{tmp: tmp} do
      write_mob_exs(tmp, """
      import Config
      config :mob_dev, bundle_id: "com.example.shared"
      """)

      assert Config.ios_bundle_id() == "com.example.shared"
    end

    test "falls through the whole bundle_id/0 chain to ios/Info.plist", %{tmp: tmp} do
      write_mob_exs(tmp, """
      import Config
      config :mob_dev, platforms: [:ios]
      """)

      write_info_plist(tmp, "com.plisted.app")

      assert Config.ios_bundle_id() == "com.plisted.app"
    end

    test ":ios_bundle_id beats ios/Info.plist", %{tmp: tmp} do
      write_mob_exs(tmp, """
      import Config
      config :mob_dev, ios_bundle_id: "com.genericjam.mishkamob"
      """)

      write_info_plist(tmp, "com.example.mishka_mob")

      assert Config.ios_bundle_id() == "com.genericjam.mishkamob"
    end

    test "no mob.exs at all → same value as bundle_id/0" do
      assert Config.ios_bundle_id() == Config.bundle_id()
    end
  end
end
