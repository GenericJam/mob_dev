defmodule MobDev.DeviceLeasesTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias MobDev.{Device, DeviceLeases}

  # The shape `agent-device device status --json` prints (0.21).
  @status ~S"""
  {
    "success": true,
    "data": {
      "claims": [
        {
          "deviceKey": "local:android:none:emulator-5560",
          "classification": "live",
          "device": {"id": "emulator-5560", "kind": "emulator", "name": "Pixel 8", "platform": "android"},
          "owner": {"session": "OtherAgent", "workspace": "/Users/k/code/app", "pid": 3838}
        },
        {
          "deviceKey": "local:apple:ios:00008110-001A2C3E0E8B801E",
          "classification": "uncertain",
          "owner": {"session": "Phone", "pid": 7}
        }
      ],
      "hiddenStaleClaims": 0
    }
  }
  """

  defp device(serial, platform \\ :android),
    do: %Device{serial: serial, name: serial, platform: platform, type: :emulator}

  defp leases(session) do
    {:ok, claims} = DeviceLeases.parse_status(@status)
    %DeviceLeases{claims: claims, session: session}
  end

  describe "parse_status/1" do
    test "reads each claim's device, platform, session and workspace" do
      assert {:ok, [pixel, phone]} = DeviceLeases.parse_status(@status)

      assert pixel == %{
               id: "emulator-5560",
               platform: :android,
               session: "OtherAgent",
               workspace: "/Users/k/code/app"
             }

      # No "device" object: the id comes from the device key.
      assert %{id: "00008110-001A2C3E0E8B801E", platform: nil, session: "Phone"} = phone
    end

    test "a refusal or unreadable output is an error, never an empty claim list" do
      assert {:error, "daemon unavailable"} =
               DeviceLeases.parse_status(
                 ~S({"success": false, "error": {"code": "X", "message": "daemon unavailable"}})
               )

      assert {:error, _} = DeviceLeases.parse_status("")
      assert {:error, _} = DeviceLeases.parse_status("Usage: agent-device ...")
    end
  end

  describe "foreign_claim/2" do
    test "a claim held by another session blocks the device it names, and only that one" do
      assert %{session: "OtherAgent"} =
               DeviceLeases.foreign_claim(device("emulator-5560"), leases("Me"))

      assert DeviceLeases.foreign_claim(device("emulator-5556"), leases("Me")) == nil
      assert DeviceLeases.foreign_claim(device("emulator-556"), leases("Me")) == nil
    end

    test "your own session's claim does not block you" do
      assert DeviceLeases.foreign_claim(device("emulator-5560"), leases("OtherAgent")) == nil
    end

    test "with no session of your own, every claim belongs to someone else" do
      assert %{session: "OtherAgent"} =
               DeviceLeases.foreign_claim(device("emulator-5560"), leases(nil))
    end

    test "matches iOS UDIDs case-insensitively but not across platforms" do
      assert %{session: "Phone"} =
               DeviceLeases.foreign_claim(
                 device("00008110-001a2c3e0e8b801e", :ios),
                 leases("Me")
               )

      assert DeviceLeases.foreign_claim(device("emulator-5560", :ios), leases("Me")) == nil
    end
  end

  test "current_session/1 treats an empty AGENT_DEVICE_SESSION as unset" do
    assert DeviceLeases.current_session(nil) == nil
    assert DeviceLeases.current_session("  ") == nil
    assert DeviceLeases.current_session(" Me ") == "Me"
  end

  test "exclude_claimed/2 drops claimed devices and says who holds each" do
    free = device("emulator-5556")

    output =
      capture_io(fn ->
        assert DeviceLeases.exclude_claimed([device("emulator-5560"), free], leases("Me")) ==
                 [free]
      end)

    assert output =~ "Skipping emulator-5560"
    assert output =~ ~s(session "OtherAgent" \(in /Users/k/code/app\))
  end

  test "warn_claimed/2 keeps a named device and warns about its claim" do
    claimed = device("emulator-5560")

    output =
      capture_io(fn ->
        assert DeviceLeases.warn_claimed([claimed], leases("Me")) == [claimed]
      end)

    assert output =~ "WARNING: emulator-5560 is claimed by agent-device session \"OtherAgent\""
  end
end
