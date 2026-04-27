defmodule Mix.Tasks.Mob.Devices do
  use Mix.Task

  @shortdoc "List all connected Android and iOS devices"

  @moduledoc """
  Scans for connected Android devices (via adb) and iOS simulators/physical
  devices (via xcrun simctl / ideviceinfo) and prints their status.

      mix mob.devices

  Each device is shown with a short **ID** you can pass to `--device`:

      mix mob.deploy --device emulator-5554
      mix mob.deploy --native --device 78354490

  Gracefully skips platforms whose tools are not installed (adb / xcrun).

  ## Under the hood

      # Android
      adb devices -l
      # → parses serial numbers, device/emulator state, and manufacturer/model

      # iOS (macOS only)
      xcrun simctl list devices booted --json
      ideviceinfo -k UniqueDeviceID   (if libimobiledevice is installed)
  """

  alias MobDev.Discovery.{Android, IOS}
  alias MobDev.Device

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.config")

    android = list_android()
    ios = list_ios()

    IO.puts("")
    print_section("Android", android)
    IO.puts("")
    print_section("iOS", ios)

    all = device_list(android) ++ device_list(ios)

    if all != [] do
      IO.puts("")
      IO.puts("Pass the ID to --device to target a specific device:")
      IO.puts("  mix mob.deploy --device #{Device.display_id(hd(all))}")

      print_bench_hints(all)
    end

    IO.puts("")
  end

  defp print_bench_hints(all) do
    physical_ios_with_ip =
      Enum.find(all, fn d ->
        d.platform == :ios and d.type == :physical and d.host_ip
      end)

    physical_android =
      Enum.find(all, fn d -> d.platform == :android and d.type == :physical end)

    if physical_ios_with_ip do
      IO.puts("")
      IO.puts("For an iOS battery bench, use --wifi-ip with the device IP:")

      IO.puts(
        "  mix mob.battery_bench_ios --no-build --wifi-ip #{physical_ios_with_ip.host_ip}"
      )
    end

    if physical_android do
      IO.puts("")
      IO.puts("For an Android battery bench, target the device by serial:")

      IO.puts(
        "  mix mob.battery_bench_android --no-build --device #{physical_android.serial}"
      )
    end
  end

  # ── Device discovery (returns tagged list or a reason atom) ──────────────────

  defp list_android do
    case System.find_executable("adb") do
      nil -> {:unavailable, "adb not found — install Android platform-tools"}
      _ -> {:ok, Android.list_devices()}
    end
  end

  defp list_ios do
    cond do
      not macos?() ->
        {:unavailable, "iOS deployment requires macOS"}

      System.find_executable("xcrun") == nil ->
        {:unavailable, "xcrun not found — install Xcode command-line tools"}

      true ->
        {:ok, IOS.list_devices()}
    end
  end

  # ── Output ───────────────────────────────────────────────────────────────────

  defp print_section(title, result) do
    IO.puts("#{IO.ANSI.cyan()}#{title}#{IO.ANSI.reset()}")

    case result do
      {:unavailable, reason} ->
        IO.puts("  (#{reason})")

      {:ok, []} ->
        IO.puts("  (none)")

      {:ok, devices} ->
        print_table(devices)
        Enum.each(devices, &print_hints/1)
    end
  end

  defp print_table(devices) do
    max_name = devices |> Enum.map(&name_len/1) |> Enum.max()
    max_ver = devices |> Enum.map(&ver_len/1) |> Enum.max()
    max_type = devices |> Enum.map(&type_len/1) |> Enum.max()
    max_id = devices |> Enum.map(&id_len/1) |> Enum.max()
    any_ip = Enum.any?(devices, & &1.host_ip)

    Enum.each(devices, fn d ->
      icon = status_icon(d)
      name = pad(d.name || d.serial, max_name)
      ver = pad(d.version || "", max_ver)
      type = pad(type_label(d), max_type)

      id_str = Device.display_id(d)
      id_padded = pad(id_str, max_id)
      id = IO.ANSI.bright() <> id_padded <> IO.ANSI.reset()

      ip_part =
        cond do
          d.host_ip -> "  " <> IO.ANSI.faint() <> d.host_ip <> IO.ANSI.reset()
          any_ip -> "  " <> IO.ANSI.faint() <> "(no IP)" <> IO.ANSI.reset()
          true -> ""
        end

      IO.puts("  #{icon}  #{name}  #{ver}  #{type}  #{id}#{ip_part}")
    end)
  end

  defp name_len(d), do: String.length(d.name || d.serial)
  defp ver_len(d), do: String.length(d.version || "")
  defp type_len(d), do: String.length(type_label(d))
  defp id_len(d), do: String.length(Device.display_id(d))

  defp type_label(%{type: :emulator}), do: "emulator"
  defp type_label(%{type: :simulator}), do: "simulator"
  defp type_label(%{type: :physical}), do: "physical"
  defp type_label(_), do: "device"

  defp status_icon(%{status: :connected}), do: "✓"
  defp status_icon(%{status: :booted}), do: "·"
  defp status_icon(%{status: :discovered}), do: "·"
  defp status_icon(%{status: :unauthorized}), do: "✗"
  defp status_icon(%{status: :error}), do: "!"
  defp status_icon(_), do: "·"

  defp pad(str, width), do: String.pad_trailing(str, width)

  # ── Hints ────────────────────────────────────────────────────────────────────

  defp print_hints(%{status: :unauthorized}) do
    IO.puts(
      "    #{IO.ANSI.yellow()}→ Check device for 'Allow USB debugging?' prompt#{IO.ANSI.reset()}"
    )
  end

  defp print_hints(%{platform: :android, serial: serial}) do
    case Android.developer_mode(serial) do
      :disabled ->
        IO.puts(
          "    #{IO.ANSI.yellow()}→ Enable Developer Mode: Settings → About → tap Build Number 7×#{IO.ANSI.reset()}"
        )

      _ ->
        :ok
    end
  end

  defp print_hints(_), do: :ok

  defp device_list({:ok, devices}), do: devices
  defp device_list({:unavailable, _}), do: []

  defp macos?, do: match?({:unix, :darwin}, :os.type())
end
