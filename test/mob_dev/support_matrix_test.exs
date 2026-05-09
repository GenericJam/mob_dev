defmodule MobDev.SupportMatrixTest do
  use ExUnit.Case, async: true

  alias MobDev.{Device, SupportMatrix}

  describe "feature_requirements/1" do
    test ":base returns the universal Mob floor" do
      reqs = SupportMatrix.feature_requirements(:base)
      assert "arm64-v8a" in reqs.android.abis
      assert "x86_64" in reqs.android.abis
      refute "armeabi-v7a" in reqs.android.abis
      assert reqs.android.min_sdk >= 28
      assert "arm64" in reqs.ios.abis
      assert reqs.ios.min_sdk >= 13
    end

    test ":pythonx names Chaquopy as the upstream constraint" do
      reqs = SupportMatrix.feature_requirements(:pythonx)
      assert "arm64-v8a" in reqs.android.abis
      assert "x86_64" in reqs.android.abis
      refute "armeabi-v7a" in reqs.android.abis
      assert reqs.android.reason =~ "Chaquopy"
      # The reason needs to call out the upstream-vendor cause — silent
      # "out of scope" doesn't honor users who lose access.
      assert reqs.android.reason =~ "32-bit"
    end

    test "unknown feature returns nil" do
      assert SupportMatrix.feature_requirements(:nonexistent_feature) == nil
    end
  end

  describe "enabled_features/1" do
    setup do
      dir =
        Path.join(System.tmp_dir!(), "mob_smatrix_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "returns [] for a vanilla project", %{dir: dir} do
      File.write!(Path.join(dir, "mix.exs"), """
      defmodule My.MixProject do
        use Mix.Project
        def project, do: [app: :my_app, version: "0.1.0"]
        def application, do: [extra_applications: []]
        defp deps, do: [{:mob, "~> 0.1"}]
      end
      """)

      assert SupportMatrix.enabled_features(dir) == []
    end

    test "detects :pythonx via the dep entry", %{dir: dir} do
      File.write!(Path.join(dir, "mix.exs"), """
      defmodule My.MixProject do
        use Mix.Project
        defp deps do
          [
            {:mob, "~> 0.1"},
            {:pythonx, "~> 0.4"}
          ]
        end
      end
      """)

      assert SupportMatrix.enabled_features(dir) == [:pythonx]
    end

    test "no mix.exs ⇒ no features (degrades quietly, doesn't raise)", %{dir: dir} do
      assert SupportMatrix.enabled_features(dir) == []
    end
  end

  describe "check_device/2" do
    test "passes for an arm64 phone with the base requirements" do
      device = %Device{
        platform: :android,
        serial: "ZY22K6BSJM",
        name: "moto g power 5G - 2024",
        abi: "arm64-v8a",
        sdk_level: 34
      }

      assert SupportMatrix.check_device(device, []) == :ok
      assert SupportMatrix.check_device(device, [:pythonx]) == :ok
    end

    test "fails the Moto e (armeabi-v7a) on Pythonx with a Chaquopy citation" do
      device = %Device{
        platform: :android,
        serial: "10.0.0.82:5555",
        name: "moto e",
        abi: "armeabi-v7a",
        sdk_level: 29
      }

      assert {:error, issues} = SupportMatrix.check_device(device, [:pythonx])

      # Two issues: pythonx (named with vendor reason) AND the base
      # Mob runtime (which also doesn't ship armv7).
      assert Enum.any?(issues, fn %{feature: f, reason: r} ->
               f == :pythonx and r =~ "Chaquopy" and r =~ "armeabi-v7a"
             end)

      assert Enum.any?(issues, fn %{feature: f, reason: r} ->
               f == :base and r =~ "armeabi-v7a"
             end)
    end

    test "fails an old Android (SDK 26) on the base SDK floor" do
      device = %Device{
        platform: :android,
        serial: "ancient",
        name: "Old Android",
        abi: "arm64-v8a",
        sdk_level: 26
      }

      assert {:error, issues} = SupportMatrix.check_device(device, [])
      assert Enum.any?(issues, fn %{reason: r} -> r =~ "SDK" end)
    end

    test "passes an iOS arm64 device on the base requirement" do
      device = %Device{
        platform: :ios,
        serial: "00008110-001E1C3A34F8401E",
        abi: "arm64",
        sdk_level: 17
      }

      assert SupportMatrix.check_device(device, []) == :ok
      assert SupportMatrix.check_device(device, [:pythonx]) == :ok
    end

    test "missing abi/sdk on a device skips the check (don't false-positive)" do
      # Older mob_dev installs may produce devices without the new fields.
      # Better to silently let those through than to red-light a perfectly
      # good arm64 phone because discovery didn't query the prop yet.
      device = %Device{platform: :android, serial: "old"}
      assert SupportMatrix.check_device(device, [:pythonx]) == :ok
    end
  end

  describe "format_error/1" do
    test "groups issues by device with the device summary as a header" do
      device = %Device{
        platform: :android,
        serial: "10.0.0.82:5555",
        name: "moto e",
        abi: "armeabi-v7a",
        sdk_level: 29,
        type: :physical,
        status: :discovered
      }

      issues = [
        %{
          device: device,
          feature: :pythonx,
          reason: "pythonx requires Android arm64-v8a or x86_64; this device is armeabi-v7a."
        },
        %{
          device: device,
          feature: :base,
          reason: "Mob requires Android arm64-v8a or x86_64; this device is armeabi-v7a."
        }
      ]

      output = SupportMatrix.format_error(issues)
      # One header per device
      assert output |> String.split("\n") |> Enum.count(&String.contains?(&1, "moto e")) == 1
      # Both reasons listed
      assert output =~ "pythonx requires"
      assert output =~ "Mob requires"
    end
  end
end
