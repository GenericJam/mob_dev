defmodule MobDev.Discovery.AndroidTest do
  use ExUnit.Case, async: true

  alias MobDev.Discovery.Android
  alias MobDev.Device

  # ── parse_devices_output/1 ───────────────────────────────────────────────────

  describe "parse_devices_output/1" do
    test "parses authorized emulator" do
      output = """
      List of devices attached
      emulator-5554\tdevice product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 transport_id:1
      """

      [device] = Android.parse_devices_output(output)
      assert device.serial == "emulator-5554"
      assert device.platform == :android
      assert device.type == :emulator
      assert device.status == :discovered
    end

    test "parses authorized physical device" do
      output = """
      List of devices attached
      R5CW3089HVB\tdevice product:moto transport_id:2
      """

      [device] = Android.parse_devices_output(output)
      assert device.serial == "R5CW3089HVB"
      assert device.type == :physical
      assert device.status == :discovered
    end

    test "parses unauthorized device" do
      output = """
      List of devices attached
      R5CW3089HVB\tunauthorized
      """

      [device] = Android.parse_devices_output(output)
      assert device.serial == "R5CW3089HVB"
      assert device.status == :unauthorized
      assert device.error =~ "authorized"
    end

    test "skips offline devices" do
      output = """
      List of devices attached
      emulator-5556\toffline
      """

      assert Android.parse_devices_output(output) == []
    end

    test "skips empty header-only output" do
      output = "List of devices attached\n"
      assert Android.parse_devices_output(output) == []
    end

    test "parses multiple devices" do
      output = """
      List of devices attached
      emulator-5554\tdevice product:sdk transport_id:1
      R5CW3089HVB\tdevice product:moto transport_id:2
      """

      devices = Android.parse_devices_output(output)
      assert length(devices) == 2
      serials = Enum.map(devices, & &1.serial)
      assert "emulator-5554" in serials
      assert "R5CW3089HVB" in serials
    end

    test "parses TCP/IP connected device" do
      output = """
      List of devices attached
      192.168.1.5:5555\tdevice product:moto transport_id:3
      """

      [device] = Android.parse_devices_output(output)
      assert device.serial == "192.168.1.5:5555"
      assert device.type == :physical
    end

    test "emulator serial prefix determines type" do
      output = """
      List of devices attached
      emulator-5554\tdevice transport_id:1
      ABCD1234\tdevice transport_id:2
      """

      devices = Android.parse_devices_output(output)
      emulator = Enum.find(devices, &(&1.serial == "emulator-5554"))
      physical = Enum.find(devices, &(&1.serial == "ABCD1234"))
      assert emulator.type == :emulator
      assert physical.type == :physical
    end

    test "returns %Device{} structs" do
      output = """
      List of devices attached
      emulator-5554\tdevice transport_id:1
      """

      [device] = Android.parse_devices_output(output)
      assert %Device{} = device
    end
  end

  # ── node_suffix_for/1 ────────────────────────────────────────────────────────

  describe "node_suffix_for/1" do
    test "lowercases an alphanumeric USB serial" do
      assert Android.node_suffix_for("ZY22CRLMWK") == "zy22crlmwk"
    end

    test "strips :port and replaces dots with underscores for WiFi-adb" do
      assert Android.node_suffix_for("10.0.0.82:5555") == "10_0_0_82"
    end

    test "replaces hyphens with underscores in emulator serials" do
      assert Android.node_suffix_for("emulator-5554") == "emulator_5554"
    end

    test "collapses runs of non-alphanumeric chars" do
      assert Android.node_suffix_for("abc.--..def") == "abc_def"
    end

    test "trims leading and trailing underscores" do
      assert Android.node_suffix_for("---abc---") == "abc"
    end
  end

  describe "device_node_suffix/1" do
    test "emulator adb id short-circuits without adb-shell call" do
      # If the function tried to shell out to adb in the test env it would
      # either time out or fail; the short-circuit keeps it pure for any
      # adb id beginning with `emulator-`. Two separate emulators map to
      # two distinct suffixes — fixing the EPMD `eaddrinuse` collision
      # we hit with the AOSP placeholder serial `EMULATOR36X5X10X0`,
      # which is identical for every running emulator.
      assert Android.device_node_suffix("emulator-5554") == "emulator_5554"
      assert Android.device_node_suffix("emulator-5556") == "emulator_5556"

      refute Android.device_node_suffix("emulator-5554") ==
               Android.device_node_suffix("emulator-5556")
    end

    test "emulator suffix matches what Mob.Dist registers on-device" do
      # `Mob.Dist.apply_suffix/2` on the device side reads `MOB_NODE_SUFFIX`
      # from the launch intent (set by `restart_app/4` from this same
      # function) and appends it to the base node name. mob_dev's
      # `mix mob.connect` must compute the *same* suffix to construct a
      # node atom that actually exists in EPMD — otherwise it times out
      # waiting for a node that was never registered under that name.
      # Regression test for the old bug where `enrich/1` derived the
      # node from raw `ro.serialno` (= `EMULATOR36X5X10X0` placeholder)
      # while `restart_app/4` sent `emulator_5554` to the device.
      assert Android.device_node_suffix("emulator-5554") == "emulator_5554"
      refute Android.device_node_suffix("emulator-5554") == "emulator36x5x10x0"
    end

    test "Device.node_name/1 agrees with device_node_suffix/1 for emulator serials" do
      # The atom produced for `mix mob.connect`'s connection target and the
      # suffix sent via `MOB_NODE_SUFFIX` must yield the same final node
      # name on both sides of the EPMD lookup.
      app = Mix.Project.config()[:app]
      device = %Device{platform: :android, serial: "emulator-5554"}
      expected_suffix = Android.device_node_suffix("emulator-5554")
      assert Device.node_name(device) == :"#{app}_android_#{expected_suffix}@127.0.0.1"
    end
  end

  # ── emulator detection ──────────────────────────────────────────────────────

  describe "emulator_adb_id?/1" do
    test "matches the canonical emulator-NNNN adb id" do
      assert Android.emulator_adb_id?("emulator-5554")
      assert Android.emulator_adb_id?("emulator-5556")
    end

    test "does not match physical USB serials" do
      refute Android.emulator_adb_id?("ZY22CRLMWK")
      refute Android.emulator_adb_id?("00008110-001E1C3A34F8401E")
    end

    test "does not match WiFi-adb identifiers" do
      refute Android.emulator_adb_id?("10.0.0.82:5555")
    end
  end

  describe "emulator_serial?/1" do
    test "matches the AOSP emulator placeholder serial" do
      assert Android.emulator_serial?("EMULATOR36X5X10X0")
    end

    test "matches other EMULATOR-prefixed vendor variants" do
      # Defensive — different system images may report different
      # post-prefix values, but they all start with EMULATOR.
      assert Android.emulator_serial?("EMULATOR12345")
      assert Android.emulator_serial?("EMULATORabc")
    end

    test "does not match real hardware serials" do
      refute Android.emulator_serial?("ZY22CRLMWK")
      refute Android.emulator_serial?("RZ8N8090ABC")
    end
  end

  # ── integration: list_devices/0 ──────────────────────────────────────────────

  @tag :integration
  test "list_devices returns a list" do
    result = Android.list_devices()
    assert Enum.all?(result, &match?(%Device{}, &1))
  end
end
