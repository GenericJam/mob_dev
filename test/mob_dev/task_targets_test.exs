defmodule MobDev.TaskTargetsTest do
  use ExUnit.Case, async: true

  alias MobDev.{Device, TaskTargets}

  defp device(serial, platform, type) do
    %Device{serial: serial, name: serial, platform: platform, type: type, status: :discovered}
  end

  test "default selection chooses the sole development device and leaves phones alone" do
    emulator = device("emulator-5554", :android, :emulator)
    android_phone = device("PHONE", :android, :physical)
    iphone = device("IPHONE", :ios, :physical)

    assert {:ok, [^emulator]} = TaskTargets.resolve([emulator, android_phone, iphone], [], [])
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
