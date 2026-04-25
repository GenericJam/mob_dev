defmodule MobDev.Tunnel do
  @moduledoc """
  Manages port tunnels for Android and physical iOS devices.

  Android (adb):
    adb reverse tcp:4369 tcp:4369   — Android BEAM registers in Mac's EPMD
    adb forward tcp:<dist> tcp:9100 — Mac reaches device's dist port

  Physical iOS (direct USB networking — no iproxy):
    The device has a USB Ethernet interface with a link-local 169.254.x.x IP.
    mob_beam.m finds this IP via getifaddrs() and starts the BEAM as
    mob_qa_ios@<device-ip>. The device's in-process EPMD binds 0.0.0.0:4369
    so the Mac can query it at <device-ip>:4369 directly over USB. The dist
    port is also directly reachable. Mac connects to mob_qa_ios@<device-ip>.
    The device IP is discovered from the Mac's ARP table.

  iOS simulator:
    Shares Mac network stack — no tunnels needed.
  """

  alias MobDev.Device

  # EPMD port — shared across all devices (same Mac EPMD).
  @epmd_port 4369

  # Base dist port — each device gets an offset so they don't collide.
  @base_dist_port 9100

  @doc """
  Assigns a dist port and sets up tunnels for a device.
  Returns {:ok, %Device{}} with dist_port and host_ip filled in, or {:error, reason}.
  """
  @spec setup(Device.t(), non_neg_integer()) :: {:ok, Device.t()} | {:error, String.t()}
  def setup(device, index \\ 0)

  def setup(%Device{platform: :android, serial: serial} = device, index) do
    dist_port = @base_dist_port + index

    with :ok <- reverse(serial, @epmd_port, @epmd_port),
         :ok <- forward(serial, dist_port, @base_dist_port) do
      {:ok, %{device | dist_port: dist_port, status: :tunneled}}
    end
  end

  def setup(%Device{platform: :ios, type: :physical, serial: _udid} = device, index) do
    dist_port = @base_dist_port + index
    # Physical device: BEAM finds its own USB link-local (169.254.x.x) IP via
    # getifaddrs() and uses it as the node hostname. The device's in-process EPMD
    # binds on 0.0.0.0:4369 so Mac can query it directly at the device's USB IP.
    # The dist port is also directly reachable — no iproxy required.
    case device_usb_ip() do
      {:ok, device_ip} ->
        d = %{device | dist_port: dist_port, host_ip: device_ip, status: :tunneled}
        {:ok, %{d | node: Device.node_name(d)}}

      {:error, reason} ->
        {:error, "device usb ip: #{reason}"}
    end
  end

  def setup(%Device{platform: :ios} = device, index) do
    # iOS simulator shares Mac network stack — no tunnels needed.
    # Port is offset by index so iOS and Android don't share the same dist port.
    dist_port = @base_dist_port + index
    {:ok, %{device | dist_port: dist_port, status: :tunneled}}
  end

  @doc "Returns the dist port for a given device index (same formula used in setup/2)."
  @spec dist_port(non_neg_integer()) :: non_neg_integer()
  def dist_port(index), do: @base_dist_port + index

  @doc "Tears down tunnels for a device."
  @spec teardown(Device.t()) :: :ok
  def teardown(%Device{platform: :android, serial: serial, dist_port: dist_port}) do
    run_adb(["-s", serial, "reverse", "--remove", "tcp:#{@epmd_port}"])
    run_adb(["-s", serial, "forward", "--remove", "tcp:#{dist_port}"])
    :ok
  end

  def teardown(%Device{platform: :ios, type: :physical, dist_port: dist_port})
      when not is_nil(dist_port) do
    kill_iproxy(dist_port)
    :ok
  end

  def teardown(%Device{platform: :ios}), do: :ok

  # ── iproxy cleanup ────────────────────────────────────────────────────────────

  # Kill any stale iproxy process on a given port. Called from teardown to clean
  # up any lingering iproxy from previous sessions (before the direct USB approach).
  defp kill_iproxy(port) do
    System.cmd("sh", ["-c", "lsof -ti tcp:#{port} | xargs kill -9 2>/dev/null; true"],
      stderr_to_stdout: true
    )

    :ok
  end

  # Find the physical iOS device's own USB link-local (169.254.x.x) IP.
  #
  # When an iOS device is connected via USB, macOS creates a USB Ethernet
  # interface (e.g. en11). The device has its own 169.254.x.x address on that
  # interface; macOS discovers it via mDNS and caches it in the ARP table as
  # "<device-name>.local (169.254.x.x) at <mac>".
  #
  # ARP entries start as "(incomplete)" until traffic triggers MAC resolution.
  # We ping any incomplete 169.254 entries first, then re-read the ARP table.
  # The device's own EPMD binds 0.0.0.0:4369, making it directly reachable
  # from Mac at that IP — no iproxy needed.
  defp device_usb_ip do
    case read_resolved_usb_ip() do
      {:ok, _} = ok ->
        ok

      {:error, _} ->
        ping_incomplete_usb_ips()

        case read_resolved_usb_ip() do
          {:ok, _} = ok ->
            ok

          {:error, _} ->
            {:error, "no device USB IP in ARP — is the device connected via USB?"}
        end
    end
  end

  defp read_resolved_usb_ip do
    case System.cmd("arp", ["-a"], stderr_to_stdout: true) do
      {out, 0} ->
        ip =
          out
          |> String.split("\n")
          |> Enum.find_value(fn line ->
            # Match resolved entries: kevins-iphone.local (169.254.x.x) at aa:bb:cc... on enN
            case Regex.run(~r/\((169\.254\.\d+\.\d+)\) at [0-9a-f]{2}:[0-9a-f]{2}/, line) do
              [_, found_ip] -> found_ip
              _ -> nil
            end
          end)

        case ip do
          nil -> {:error, :not_found}
          ip -> {:ok, ip}
        end

      _ ->
        {:error, :arp_failed}
    end
  end

  defp ping_incomplete_usb_ips do
    case System.cmd("arp", ["-a"], stderr_to_stdout: true) do
      {out, 0} ->
        out
        |> String.split("\n")
        |> Enum.each(fn line ->
          case Regex.run(~r/\((169\.254\.\d+\.\d+)\) at \(incomplete\)/, line) do
            [_, ip] ->
              System.cmd("ping", ["-c", "1", "-t", "2", ip], stderr_to_stdout: true)

            _ ->
              :ok
          end
        end)

      _ ->
        :ok
    end
  end

  # ── adb helpers ───────────────────────────────────────────────────────────────

  # adb reverse tcp:remote tcp:local  (device→Mac)
  defp reverse(serial, device_port, local_port) do
    case run_adb(["-s", serial, "reverse", "tcp:#{device_port}", "tcp:#{local_port}"]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, "reverse #{device_port}: #{reason}"}
    end
  end

  # adb forward tcp:local tcp:remote  (Mac→device)
  defp forward(serial, local_port, device_port) do
    case run_adb(["-s", serial, "forward", "tcp:#{local_port}", "tcp:#{device_port}"]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, "forward #{local_port}→#{device_port}: #{reason}"}
    end
  end

  defp run_adb(args) do
    cmd = Enum.join(["adb" | args], " ")

    case System.cmd("sh", ["-c", "timeout 8 #{cmd}"], stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {_output, 124} -> {:error, "adb timed out"}
      {output, _} -> {:error, String.trim(output)}
    end
  end
end
