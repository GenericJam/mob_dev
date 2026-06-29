defmodule MobDev.Tunnel do
  @moduledoc """
  Manages port tunnels for Android and physical iOS devices.

  Android (adb):
    adb reverse tcp:4369 tcp:4369     — Android BEAM registers in Mac's EPMD
    adb forward tcp:<dist> tcp:<dist> — Mac reaches the device's dist port (1:1)

  Physical iOS (direct networking — USB preferred, WiFi/LAN fallback):
    mob_beam.m finds the device's own IP via getifaddrs() and starts the BEAM
    as mob_qa_ios@<device-ip>. The in-process EPMD binds 0.0.0.0:4369 so Mac
    can query it at <device-ip>:4369. The dist port is directly reachable.

  iOS simulator:
    Shares Mac network stack — no tunnels needed.

  ## Dist ports are keyed by device serial, not run index

  The Mac runs ONE EPMD (port 4369) that every device — across every project
  and every `mix mob.connect` run — registers into. Assigning dist ports by
  per-run index (`9100 + index`) meant project A's device-0 and project B's
  device-0 both claimed 9100: two nodes at the same port in the shared EPMD,
  but `adb forward tcp:9100` can only point at one device → the other resolved
  to the wrong phone or nothing (silent timeout). Now the port is derived from
  the device serial (`serial_base_port/1`, a crc32 hash into 9100..9899), so a
  given phone always gets the same unique port regardless of project/run, and
  `assign_dist_port/2` bumps past any port another live node/forward already
  holds (cross-project or hash collision).
  """

  alias MobDev.Device

  # EPMD port — shared across all devices (same Mac EPMD).
  @epmd_port 4369

  # Dist port window. crc32(serial) spreads phones across [9100, 9100+span).
  @base_dist_port 9100
  @port_span 800

  @doc """
  Assigns a serial-derived dist port and sets up tunnels for a device.

  Cleans the device's own stale forwards first, then picks a port that no other
  live node/forward on this Mac is using. Returns `{:ok, %Device{}}` with
  `dist_port` (and `host_ip` for USB iOS) filled in, or `{:error, reason}`.
  """
  @spec setup(Device.t()) :: {:ok, Device.t()} | {:error, String.t()}
  def setup(%Device{platform: :android, serial: serial} = device) do
    clean_android_forwards(serial)
    port = assign_dist_port(serial, ports_in_use(device.node))

    with :ok <- reverse(serial, @epmd_port, @epmd_port),
         :ok <- forward(serial, port, port) do
      {:ok, %{device | dist_port: port, status: :tunneled}}
    end
  end

  def setup(%Device{platform: :ios, type: :physical, host_ip: ip} = device)
      when not is_nil(ip) do
    # IP already known from WiFi/LAN discovery — no ARP lookup needed.
    # dist_port was set during discovery (parsed from EPMD). Node name already set.
    {:ok, %{device | status: :tunneled}}
  end

  def setup(%Device{platform: :ios, type: :physical, serial: udid} = device) do
    # IP not yet known — device was discovered via USB. Find the USB link-local IP.
    port = assign_dist_port(udid, ports_in_use(device.node))

    case device_usb_ip() do
      {:ok, device_ip} ->
        d = %{device | dist_port: port, host_ip: device_ip, status: :tunneled}
        {:ok, %{d | node: Device.node_name(d)}}

      {:error, reason} ->
        {:error, "device usb ip: #{reason}"}
    end
  end

  def setup(%Device{platform: :ios, serial: udid} = device) do
    # iOS simulator shares Mac network stack — no tunnels needed, but it still
    # needs a unique dist port (multiple sims / Android share the Mac EPMD).
    port = assign_dist_port(udid, ports_in_use(device.node))
    {:ok, %{device | dist_port: port, status: :tunneled}}
  end

  @doc """
  Stable, deterministic dist port for a device serial — a crc32 hash into
  `[9100, 9100 + 800)`. Same serial → same port across runs and projects, so
  the port a device is *deployed* to listen on matches what `mix mob.connect`
  later forwards to.
  """
  @spec serial_base_port(String.t()) :: pos_integer()
  def serial_base_port(serial) when is_binary(serial) do
    @base_dist_port + rem(:erlang.crc32(serial), @port_span)
  end

  @doc """
  The serial's base port, bumped to the next free slot if `in_use` already
  claims it (a cross-project collision or a crc32 hash collision between two
  serials). Walks the window from the base; falls back to the base if the whole
  window is somehow taken. Pure — `in_use` is gathered by the caller.
  """
  @spec assign_dist_port(String.t(), MapSet.t()) :: pos_integer()
  def assign_dist_port(serial, in_use \\ MapSet.new()) do
    base_off = rem(:erlang.crc32(serial), @port_span)

    Enum.find_value(0..(@port_span - 1), serial_base_port(serial), fn off ->
      port = @base_dist_port + rem(base_off + off, @port_span)
      if MapSet.member?(in_use, port), do: false, else: port
    end)
  end

  @doc "Tears down tunnels for a device."
  @spec teardown(Device.t()) :: :ok
  def teardown(%Device{platform: :android, serial: serial, dist_port: dist_port}) do
    run_adb(["-s", serial, "reverse", "--remove", "tcp:#{@epmd_port}"])
    if dist_port, do: run_adb(["-s", serial, "forward", "--remove", "tcp:#{dist_port}"])
    :ok
  end

  def teardown(%Device{platform: :ios, type: :physical, dist_port: dist_port})
      when not is_nil(dist_port) do
    kill_iproxy(dist_port)
    :ok
  end

  def teardown(%Device{platform: :ios}), do: :ok

  # ── port bookkeeping ──────────────────────────────────────────────────────────

  @doc false
  # Host-side ports already claimed on this Mac — by another node in the shared
  # EPMD or by an existing adb forward — so a device's serial-derived port can
  # dodge a cross-project collision. `exclude_node` drops this device's own
  # registration so re-running reclaims its port.
  @spec ports_in_use(atom() | nil) :: MapSet.t()
  def ports_in_use(exclude_node \\ nil) do
    MapSet.union(epmd_ports(exclude_node), forward_host_ports())
  end

  defp epmd_ports(exclude_node) do
    exclude = exclude_node && exclude_node |> Atom.to_string() |> String.split("@") |> hd()

    case System.cmd("epmd", ["-names"], stderr_to_stdout: true) do
      {out, 0} ->
        ~r/name (\S+) at port (\d+)/
        |> Regex.scan(out)
        |> Enum.reject(fn [_, name, _] -> name == exclude end)
        |> Enum.map(fn [_, _, port] -> String.to_integer(port) end)
        |> MapSet.new()

      _ ->
        MapSet.new()
    end
  end

  defp forward_host_ports do
    case run_adb(["forward", "--list"]) do
      {:ok, out} ->
        ~r/tcp:(\d+) tcp:\d+/
        |> Regex.scan(out)
        |> Enum.map(fn [_, port] -> String.to_integer(port) end)
        |> MapSet.new()

      _ ->
        MapSet.new()
    end
  end

  # Remove this device's own stale forwards (old per-run ports) so its
  # serial-derived port is free to reclaim and we don't accumulate duplicates.
  # Scoped to this serial — never touches other devices' forwards.
  defp clean_android_forwards(serial) do
    case run_adb(["forward", "--list"]) do
      {:ok, out} ->
        out
        |> String.split("\n")
        |> Enum.each(fn line ->
          case String.split(line) do
            [^serial, "tcp:" <> host_port | _] ->
              run_adb(["-s", serial, "forward", "--remove", "tcp:#{host_port}"])

            _ ->
              :ok
          end
        end)

      _ ->
        :ok
    end

    :ok
  end

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
            case Regex.run(
                   Regex.compile!("\\((169\\.254\\.\\d+\\.\\d+)\\) at [0-9a-f]{2}:[0-9a-f]{2}"),
                   line
                 ) do
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
          case Regex.run(
                 Regex.compile!("\\((169\\.254\\.\\d+\\.\\d+)\\) at \\(incomplete\\)"),
                 line
               ) do
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

  # Pure-Elixir timeout via Task — avoids depending on the GNU `timeout`
  # binary, which doesn't ship with macOS or BSD by default. Calls adb
  # directly via System.cmd/3 (no shell, no quoting concerns).
  #
  # Resolves `adb` up front via System.find_executable/1: an iOS-only Mac
  # has no Android platform-tools, and `System.cmd("adb", ...)` *raises*
  # `:enoent` for a missing binary (it does not return a non-zero exit). That
  # raise inside the linked Task would propagate an exit to the caller and
  # crash the whole `mix mob.connect`. Returning `{:error, ...}` instead lets
  # every caller's existing error branch degrade gracefully (no forwards →
  # empty port set, no-op cleanup), so iOS-only setups never touch adb.
  defp run_adb(args) do
    case System.find_executable("adb") do
      nil ->
        {:error, "adb not found on PATH"}

      adb ->
        task = Task.async(fn -> System.cmd(adb, args, stderr_to_stdout: true) end)

        case Task.yield(task, 8_000) || Task.shutdown(task, :brutal_kill) do
          {:ok, {output, 0}} -> {:ok, String.trim(output)}
          {:ok, {output, _rc}} -> {:error, String.trim(output)}
          nil -> {:error, "adb timed out"}
          {:exit, reason} -> {:error, "adb crashed: #{inspect(reason)}"}
        end
    end
  end
end
