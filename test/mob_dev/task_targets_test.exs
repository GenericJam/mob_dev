defmodule MobDev.TaskTargetsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias MobDev.{Device, DeviceLeases, TaskTargets}

  defp device(serial, platform, type) do
    %Device{serial: serial, name: serial, platform: platform, type: type, status: :discovered}
  end

  # `session` holds the claims; the caller is always session "Me".
  defp claimed_by(session, serials) do
    claims =
      Enum.map(serials, &%{id: &1, platform: :android, session: session, workspace: "/w"})

    %DeviceLeases{claims: claims, session: "Me"}
  end

  # resolve/3 prints what it skipped and picked; returns {result, output}.
  defp resolve(all, ids, opts), do: with_io(fn -> TaskTargets.resolve(all, ids, opts) end)

  test "default selection chooses the sole development device and leaves phones alone" do
    emulator = device("emulator-5554", :android, :emulator)
    android_phone = device("PHONE", :android, :physical)
    iphone = device("IPHONE", :ios, :physical)

    assert {{:ok, [^emulator]}, output} = resolve([emulator, android_phone, iphone], [], [])
    assert output =~ "Auto-selected emulator-5554"
  end

  describe "agent-device leases" do
    test "auto-selection picks the free emulator over one another session claimed" do
      held = device("emulator-5560", :android, :emulator)
      free = device("emulator-5556", :android, :emulator)

      assert {{:ok, [^free]}, output} =
               resolve([held, free], [], leases: claimed_by("OtherAgent", ["emulator-5560"]))

      assert output =~ ~s(Skipping emulator-5560: claimed by agent-device session "OtherAgent")
      assert output =~ "Auto-selected emulator-5556"
    end

    test "a sole emulator that is claimed is refused, not deployed to" do
      held = device("emulator-5560", :android, :emulator)

      assert {{:error, :all_claimed, _}, _} =
               resolve([held], [], leases: claimed_by("OtherAgent", ["emulator-5560"]))
    end

    test "a claimed emulator next to a phone reports the claim, not 'only physical devices'" do
      held = device("emulator-5560", :android, :emulator)
      phone = device("PHONE", :android, :physical)

      assert {{:error, :all_claimed, _}, _} =
               resolve([held, phone], [], leases: claimed_by("OtherAgent", ["emulator-5560"]))
    end

    test "with one of three emulators claimed the other two are still ambiguous" do
      devices =
        Enum.map(~w(emulator-5554 emulator-5556 emulator-5560), &device(&1, :android, :emulator))

      assert {{:error, :ambiguous_devices, %{non_physical: 2}}, _} =
               resolve(devices, [], leases: claimed_by("OtherAgent", ["emulator-5560"]))
    end

    test "a device your own session claimed is selectable" do
      mine = device("emulator-5560", :android, :emulator)

      assert {{:ok, [^mine]}, _} =
               resolve([mine], [], leases: claimed_by("Me", ["emulator-5560"]))
    end

    test "--all-devices sweeps only the unclaimed emulators" do
      held = device("emulator-5560", :android, :emulator)
      free = device("emulator-5556", :android, :emulator)

      assert {{:ok, [^free]}, output} =
               resolve([held, free], [],
                 all_devices: true,
                 leases: claimed_by("OtherAgent", ["emulator-5560"])
               )

      assert output =~ "Skipping emulator-5560"
    end

    test "--all-physical leaves a LAN iPhone alone while another session holds an iPhone" do
      # An iPhone found over the LAN is known by its IP; the claim names its UDID.
      lan_iphone = %{device("192.168.1.42", :ios, :physical) | host_ip: "192.168.1.42"}
      android_phone = device("PHONE", :android, :physical)

      leases = %DeviceLeases{
        claims: [
          %{
            id: "00008110-001A2C3E0E8B801E",
            platform: :ios,
            kind: :device,
            session: "OtherAgent",
            workspace: "/w"
          }
        ],
        session: "Me"
      }

      assert {{:ok, [^android_phone]}, output} =
               resolve([lan_iphone, android_phone], [], all_physical: true, leases: leases)

      assert output =~ "Skipping 192.168.1.42: possibly claimed"
    end

    test "a claimed device named explicitly is used, with a loud warning" do
      held = device("emulator-5560", :android, :emulator)

      assert {{:ok, [^held]}, output} =
               resolve([held], ["emulator-5560"],
                 leases: claimed_by("OtherAgent", ["emulator-5560"])
               )

      assert output =~ ~s(WARNING: emulator-5560 is claimed by agent-device session "OtherAgent")
    end
  end

  test "default selection refuses multiple development devices" do
    devices = [
      device("emulator-5554", :android, :emulator),
      device("SIM-UDID", :ios, :simulator)
    ]

    assert {:error, :ambiguous_devices, %{non_physical: 2}} =
             TaskTargets.resolve(devices, [], [])
  end

  test "broad scopes keep physical and development targets separate" do
    emulator = device("emulator-5554", :android, :emulator)
    simulator = device("SIM-UDID", :ios, :simulator)
    phone = device("PHONE", :android, :physical)
    all = [emulator, simulator, phone]

    assert TaskTargets.select(all, [], all_devices: true) == [emulator, simulator]
    assert TaskTargets.select(all, [], all_physical: true) == [phone]

    assert TaskTargets.select(all, [], all_devices: true, all_physical: true) == all
  end

  test "an explicit identifier can select one physical device" do
    emulator = device("emulator-5554", :android, :emulator)
    phone = device("PHONE", :android, :physical)

    assert {:ok, [^phone]} = TaskTargets.resolve([emulator, phone], ["phone"], [])
  end
end
