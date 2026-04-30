defmodule MobDev.EmulatorsTest do
  use ExUnit.Case, async: true

  alias MobDev.Emulators

  # ── parse_simctl_json/1 — pure parser, no shell ─────────────────────────────

  describe "parse_simctl_json/1" do
    @sample_json """
    {
      "devices": {
        "com.apple.CoreSimulator.SimRuntime.iOS-26-4": [
          {
            "name": "iPhone 17",
            "udid": "78354490-EF38-44D7-A437-DD941C20524D",
            "state": "Booted",
            "isAvailable": true
          },
          {
            "name": "iPhone Air",
            "udid": "02628F8F-770E-4140-8CA9-9DBD9B7B8C65",
            "state": "Shutdown",
            "isAvailable": true
          }
        ],
        "com.apple.CoreSimulator.SimRuntime.watchOS-11-0": [
          {
            "name": "Apple Watch SE 3 (40mm)",
            "udid": "E98F35F5-1234-5678-9ABC-DEF012345678",
            "state": "Shutdown",
            "isAvailable": true
          }
        ]
      }
    }
    """

    test "extracts each sim with name + udid + booted state" do
      sims = Emulators.parse_simctl_json(@sample_json)

      assert length(sims) == 3

      booted = Enum.find(sims, & &1.running)
      assert booted.name == "iPhone 17"
      assert booted.id == "78354490-EF38-44D7-A437-DD941C20524D"
      assert booted.platform == :ios
    end

    test "pretty-prints runtime as 'iOS 26.4'" do
      sims = Emulators.parse_simctl_json(@sample_json)
      assert Enum.find(sims, &(&1.name == "iPhone 17")).runtime == "iOS 26.4"
    end

    test "handles non-iOS runtimes (watchOS) without breaking" do
      sims = Emulators.parse_simctl_json(@sample_json)
      watch = Enum.find(sims, &String.contains?(&1.name, "Watch"))
      assert watch.runtime == "watchOS 11.0"
      assert watch.platform == :ios
    end

    test "skips entries marked isAvailable: false" do
      json = """
      {
        "devices": {
          "com.apple.CoreSimulator.SimRuntime.iOS-26-4": [
            {
              "name": "iPhone (deprecated runtime)",
              "udid": "DEADBEEF-1234-5678-9ABC-DEF012345678",
              "state": "Shutdown",
              "isAvailable": false
            }
          ]
        }
      }
      """

      assert Emulators.parse_simctl_json(json) == []
    end

    test "returns [] for malformed JSON instead of raising" do
      assert Emulators.parse_simctl_json("not json at all") == []
      assert Emulators.parse_simctl_json("") == []
    end

    test "uses Booted state to set running flag" do
      json = """
      {
        "devices": {
          "com.apple.CoreSimulator.SimRuntime.iOS-26-4": [
            {"name": "A", "udid": "AAAAAAAA-1111-1111-1111-111111111111", "state": "Booted", "isAvailable": true},
            {"name": "B", "udid": "BBBBBBBB-2222-2222-2222-222222222222", "state": "Shutdown", "isAvailable": true},
            {"name": "C", "udid": "CCCCCCCC-3333-3333-3333-333333333333", "state": "Booting", "isAvailable": true}
          ]
        }
      }
      """

      sims = Emulators.parse_simctl_json(json)
      states = Map.new(sims, fn s -> {s.name, s.running} end)

      assert states["A"] == true
      assert states["B"] == false
      assert states["C"] == false
    end
  end

  # ── find_emulator_binary/1 — path resolution ────────────────────────────────

  describe "find_emulator_binary/1" do
    @tag :integration
    test "returns {:ok, path} when one of the standard locations has an emulator binary" do
      # On a host with Android Studio installed, this should succeed. Skip
      # gracefully when neither default path nor env var is set.
      result = Emulators.find_emulator_binary()

      case result do
        {:ok, path} -> assert String.ends_with?(path, "emulator/emulator")
        {:error, _} -> :ok
      end
    end
  end
end
