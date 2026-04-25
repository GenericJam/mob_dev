defmodule MobDev.Discovery.IOSTest do
  use ExUnit.Case, async: true

  alias MobDev.Discovery.IOS
  alias MobDev.Device

  # ── parse_simctl_json/1 ───────────────────────────────────────────────────────

  describe "parse_simctl_json/1" do
    test "parses a booted simulator" do
      json = Jason.encode!(%{
        "devices" => %{
          "com.apple.CoreSimulator.SimRuntime.iOS-18-0" => [
            %{"udid" => "ABC-123", "name" => "iPhone 15", "state" => "Booted"}
          ]
        }
      })
      [device] = IOS.parse_simctl_json(json)
      assert device.serial == "ABC-123"
      assert device.name == "iPhone 15"
      assert device.platform == :ios
      assert device.type == :simulator
      assert device.status == :booted
      assert device.version == "iOS 18.0"
    end

    test "skips non-booted simulators" do
      json = Jason.encode!(%{
        "devices" => %{
          "com.apple.CoreSimulator.SimRuntime.iOS-18-0" => [
            %{"udid" => "ABC-123", "name" => "iPhone 15", "state" => "Shutdown"},
            %{"udid" => "DEF-456", "name" => "iPhone 16", "state" => "Booted"}
          ]
        }
      })
      devices = IOS.parse_simctl_json(json)
      assert length(devices) == 1
      assert hd(devices).serial == "DEF-456"
    end

    test "returns empty list when no devices object" do
      json = Jason.encode!(%{"devices" => %{}})
      assert IOS.parse_simctl_json(json) == []
    end

    test "parses multiple booted simulators across runtimes" do
      json = Jason.encode!(%{
        "devices" => %{
          "com.apple.CoreSimulator.SimRuntime.iOS-17-0" => [
            %{"udid" => "A1", "name" => "iPhone 14", "state" => "Booted"}
          ],
          "com.apple.CoreSimulator.SimRuntime.iOS-18-0" => [
            %{"udid" => "B2", "name" => "iPhone 15", "state" => "Booted"}
          ]
        }
      })
      devices = IOS.parse_simctl_json(json)
      assert length(devices) == 2
      serials = Enum.map(devices, & &1.serial)
      assert "A1" in serials
      assert "B2" in serials
    end

    test "assigns node name to each device" do
      app = Mix.Project.config()[:app]
      # UDID "ABC-123" → strip hyphens "ABC123" → first 8 lowercase → "abc123"
      json = Jason.encode!(%{
        "devices" => %{
          "com.apple.CoreSimulator.SimRuntime.iOS-18-0" => [
            %{"udid" => "ABC-123", "name" => "iPhone 15", "state" => "Booted"}
          ]
        }
      })
      [device] = IOS.parse_simctl_json(json)
      assert device.node == :"#{app}_ios_abc123@127.0.0.1"
    end
  end

  # ── parse_simctl_text/1 ───────────────────────────────────────────────────────

  describe "parse_simctl_text/1" do
    test "parses booted simulator line" do
      text = """
      == Booted ==
          iPhone 17 (78354490-EF38-44D7-A437-DD941C20524D) (Booted)
      """
      [device] = IOS.parse_simctl_text(text)
      assert device.serial == "78354490-EF38-44D7-A437-DD941C20524D"
      assert device.name == "iPhone 17"
      assert device.platform == :ios
    end

    test "skips shutdown simulator lines" do
      text = """
      == Shutdown ==
          iPhone 14 (AABB-CCDD-1234-5678-ABCDEFABCDEF) (Shutdown)
      """
      assert IOS.parse_simctl_text(text) == []
    end

    test "parses multiple booted simulators" do
      text = """
          iPhone 15 (AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEFFFFFF) (Booted)
          iPad Pro  (FFFFFFFF-EEEE-DDDD-CCCC-BBBBBBAAAAA1) (Booted)
      """
      devices = IOS.parse_simctl_text(text)
      assert length(devices) == 2
    end
  end

  # ── parse_runtime_version/1 ───────────────────────────────────────────────────

  describe "parse_runtime_version/1" do
    test "parses iOS-18-0 style" do
      assert IOS.parse_runtime_version("com.apple.CoreSimulator.SimRuntime.iOS-18-0") == "iOS 18.0"
    end

    test "parses iOS-17-4 style" do
      assert IOS.parse_runtime_version("com.apple.CoreSimulator.SimRuntime.iOS-17-4") == "iOS 17.4"
    end

    test "falls back gracefully for unknown format" do
      assert IOS.parse_runtime_version("some.unknown.runtime.foo") == "foo"
    end
  end

  # ── integration: list_simulators/0 ───────────────────────────────────────────

  @tag :integration
  test "list_simulators returns a list" do
    result = IOS.list_simulators()
    assert Enum.all?(result, &match?(%Device{}, &1))
  end
end
