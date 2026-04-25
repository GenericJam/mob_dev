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

  # ── integration: list_devices/0 ──────────────────────────────────────────────

  @tag :integration
  test "list_devices returns a list" do
    result = Android.list_devices()
    assert Enum.all?(result, &match?(%Device{}, &1))
  end
end
