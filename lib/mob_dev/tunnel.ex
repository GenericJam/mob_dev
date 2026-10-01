defmodule MobDev.Tunnel do
  @moduledoc """
  Manages port tunnels for Android and physical iOS devices.

  Android (adb):
    adb reverse tcp:4369 tcp:4369     — Android BEAM registers in Mac's EPMD
    adb forward tcp:<dist> tcp:<dist> — Mac reaches the device's dist port (1:1)

  Physical iOS (direct networking — WiFi/LAN preferred, USB link-local fallback):
    mob_beam.m finds the device's own IP via getifaddrs() and starts the BEAM
    as <app>_ios@<device-ip>. The in-process EPMD binds 0.0.0.0:4369 so Mac
    can query it at any of the device's IPs. The dist port is directly reachable.
    A USB-discovered device's node is read from EPMD, not predicted
    (`MobDev.Discovery.IOS.resolve_usb_node/1`).

  iOS simulator:
    Shares Mac network stack — no tunnels needed.

  ## Dist ports are keyed by device serial and app, not run index

  The Mac runs ONE EPMD (port 4369) that every device — across every project
  and every `mix mob.connect` run — registers into. Assigning dist ports by
  per-run index (`9100 + index`) meant project A's device-0 and project B's
  device-0 both claimed 9100: two nodes at the same port in the shared EPMD,
  but `adb forward tcp:9100` can only point at one device → the other resolved
  to the wrong phone or nothing (silent timeout). Keying on the serial alone
  then gave two apps on the SAME device the same port, and the second one's
  dist failed with `:nodistribution`. Now the port is derived from the device
  serial and the app name (`base_port/2`, a crc32 hash into 9100..9899), so a
  given app on a given device always gets the same port regardless of run, and
  `assign_dist_port/3` bumps past any port another live node or another
  device's forward already holds (a hash collision or a non-mob node).
  """

  alias MobDev.Device
  alias MobDev.Discovery.IOS

  # EPMD port — shared across all devices (same Mac EPMD).
  @epmd_port 4369

  # Dist port window. crc32(serial) spreads phones across [9100, 9100+span).
  @base_dist_port 9100
  @port_span 800

  @doc """
  Assigns the device's dist port for the current project's app and sets up
  tunnels for it.

  Cleans this device's stale dist forwards first (never one a live node of
  another app on the same device is using), then picks a port that no other
  live node or other device's forward on this Mac is using. Returns
  `{:ok, %Device{}}` with `dist_port` (and `host_ip` for USB iOS) filled in,
  or `{:error, reason}`.
  """
  @spec setup(Device.t()) :: {:ok, Device.t()} | {:error, String.t()}
  def setup(%Device{platform: :android, serial: serial} = device) do
    clean_android_forwards(serial, device.node)
    port = dist_port_for(device)

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

  def setup(%Device{platform: :ios, type: :physical} = device) do
    # Discovered over USB, so no IP yet. The BEAM names itself after the WiFi
    # IP when it has one, so the USB link-local IP is only the prediction for
    # when EPMD lists nothing yet.
    case IOS.resolve_usb_node(usb_link_local_ip()) do
      {:registered, ip, name, dist_port} ->
        {:ok,
         %{device | host_ip: ip, node: :"#{name}@#{ip}", dist_port: dist_port, status: :tunneled}}

      {:predicted, ip} ->
        port = dist_port_for(device)
        d = %{device | dist_port: port, host_ip: ip, status: :tunneled}
        {:ok, %{d | node: Device.node_name(d)}}

      :none ->
        {:error, "device usb ip: no device USB IP in ARP — is the device connected via USB?"}
    end
  end

  def setup(%Device{platform: :ios} = device) do
    # iOS simulator shares Mac network stack — no tunnels needed, but it still
    # needs a unique dist port (multiple sims / Android share the Mac EPMD).
    port = dist_port_for(device)
    {:ok, %{device | dist_port: port, status: :tunneled}}
  end

  @doc """
  The dist port this project's app uses on `device`: `assign_dist_port/3` over
  the live state of this Mac (EPMD and `adb forward --list`), ignoring the
  app's own node and the device's own forwards so a redeploy reclaims its port.
  `mix mob.deploy` and `mix mob.connect` both resolve the port through here, so
  they agree.
  """
  @spec dist_port_for(Device.t()) :: pos_integer()
  def dist_port_for(%Device{serial: serial, node: node}) do
    forwards =
      case run_adb(["forward", "--list"]) do
        {:ok, out} -> out
        _ -> ""
      end

    assign_dist_port(serial, project_app(), in_use_ports(epmd_names(), forwards, node, serial))
  end

  @doc """
  Stable, deterministic dist port for `app` on the device `serial` — a crc32
  hash of both into `[9100, 9100 + 800)`. Same serial and app → same port
  across runs; two apps on one device → (almost always) different ports.
  """
  @spec base_port(String.t(), String.t()) :: pos_integer()
  def base_port(serial, app) when is_binary(serial) and is_binary(app) do
    @base_dist_port + base_offset(serial, app)
  end

  @doc """
  `base_port/2`, bumped to the next free slot if `in_use` already claims it (a
  crc32 collision with another app/device, or a node mob_dev didn't start).
  Walks the window from the base; falls back to the base if the whole window
  is somehow taken. Pure — `in_use` is gathered by the caller.
  """
  @spec assign_dist_port(String.t(), String.t(), MapSet.t()) :: pos_integer()
  def assign_dist_port(serial, app, in_use \\ MapSet.new()) do
    base_off = base_offset(serial, app)

    Enum.find_value(0..(@port_span - 1), base_port(serial, app), fn off ->
      port = @base_dist_port + rem(base_off + off, @port_span)
      if MapSet.member?(in_use, port), do: false, else: port
    end)
  end

  defp base_offset(serial, app), do: rem(:erlang.crc32("#{app}@#{serial}"), @port_span)

  defp project_app, do: to_string(Mix.Project.config()[:app])

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
  # Host-side ports already claimed on this Mac: by any node in the shared EPMD
  # other than `own_node` (this app on this device, so a redeploy reclaims its
  # port), or by an adb forward to a DIFFERENT device. This device's own
  # forwards don't count: one to a port another app on it uses is already in
  # EPMD, and any other is stale. Pure over `epmd -names` / `adb forward --list`.
  @spec in_use_ports([{String.t(), pos_integer()}], String.t(), atom() | nil, String.t()) ::
          MapSet.t()
  def in_use_ports(epmd_names, forward_list, own_node, serial) do
    own = own_node && own_node |> Atom.to_string() |> String.split("@") |> hd()
    epmd = for {name, port} <- epmd_names, name != own, into: MapSet.new(), do: port

    others =
      for {owner, port} <- tcp_forwards(forward_list),
          owner != serial,
          into: MapSet.new(),
          do: port

    MapSet.union(epmd, others)
  end

  @doc false
  # This device's dist forwards (`tcp:P tcp:P` in the dist window) that no live
  # node other than `own_node` is registered on — safe to remove. A forward
  # another app on the same device is using, and non-dist forwards (other
  # tools' `localabstract:` ones), are left alone. Pure.
  @spec stale_dist_forwards(String.t(), [{String.t(), pos_integer()}], atom() | nil, String.t()) ::
          [pos_integer()]
  def stale_dist_forwards(forward_list, epmd_names, own_node, serial) do
    live = in_use_ports(epmd_names, "", own_node, serial)

    for {^serial, port} <- tcp_forwards(forward_list),
        port in @base_dist_port..(@base_dist_port + @port_span - 1),
        not MapSet.member?(live, port),
        do: port
  end

  # `{serial, host_port}` for each `<serial> tcp:P tcp:P` line.
  defp tcp_forwards(forward_list) do
    for line <- String.split(forward_list, "\n", trim: true),
        [owner, "tcp:" <> host, "tcp:" <> remote] <- [String.split(line)],
        host == remote,
        {port, ""} <- [Integer.parse(host)],
        do: {owner, port}
  end

  @doc """
  The `{name, port}` pairs registered in the Mac's EPMD, which every Android
  device and iOS simulator registers into. Empty when EPMD isn't reachable.
  """
  @spec epmd_names() :: [{String.t(), pos_integer()}]
  def epmd_names do
    case System.cmd("epmd", ["-names"], stderr_to_stdout: true) do
      {out, 0} ->
        for [_, name, port] <- Regex.scan(Regex.compile!("name (\\S+) at port (\\d+)"), out),
            do: {name, String.to_integer(port)}

      _ ->
        []
    end
  end

  @doc """
  Makes sure an Android app started now can join distribution: `adb reverse`
  for EPMD (so the device BEAM registers in the Mac's EPMD) and a forward of
  the dist `port`. Both are gone after an emulator reboot or an adbd restart,
  and an app launched without them gives up on dist after 10 s. Idempotent.
  """
  @spec ensure_android(String.t(), pos_integer()) :: :ok | {:error, String.t()}
  def ensure_android(serial, port) do
    with :ok <- reverse(serial, @epmd_port, @epmd_port), do: attach_forward(serial, port)
  end

  @doc """
  Forwards host `port` to the same port on `serial`, to reach a node that is
  already running there. Refuses (`{:error, _}`) when the host port already
  forwards to a different device, rather than taking it from that session.
  """
  @spec attach_forward(String.t(), pos_integer()) :: :ok | {:error, String.t()}
  def attach_forward(serial, port) do
    owner =
      case run_adb(["forward", "--list"]) do
        {:ok, out} -> forward_owner(out, port)
        _ -> nil
      end

    if owner in [nil, serial],
      do: forward(serial, port, port),
      else: {:error, "host port #{port} already forwards to #{owner}; not taking it over"}
  end

  @doc false
  # The serial `adb forward --list` output forwards host tcp:`port` to, or nil.
  @spec forward_owner(String.t(), pos_integer()) :: String.t() | nil
  def forward_owner(forward_list, port) do
    forward_list
    |> String.split("\n", trim: true)
    |> Enum.find_value(fn line ->
      case String.split(line) do
        [owner, "tcp:" <> host_port | _] -> if host_port == to_string(port), do: owner
        _ -> nil
      end
    end)
  end

  # Remove this device's stale dist forwards (an old port of this app) so its
  # port is free to reclaim and forwards don't accumulate. Scoped to this
  # serial, and keeps a forward another app on the same device is live on, so
  # connecting to one app doesn't cut off a session with the other.
  defp clean_android_forwards(serial, own_node) do
    with {:ok, out} <- run_adb(["forward", "--list"]) do
      out
      |> stale_dist_forwards(epmd_names(), own_node, serial)
      |> Enum.each(&run_adb(["-s", serial, "forward", "--remove", "tcp:#{&1}"]))
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
  defp usb_link_local_ip do
    case read_resolved_usb_ip() do
      {:ok, ip} ->
        ip

      {:error, _} ->
        ping_incomplete_usb_ips()

        case read_resolved_usb_ip() do
          {:ok, ip} -> ip
          {:error, _} -> nil
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
