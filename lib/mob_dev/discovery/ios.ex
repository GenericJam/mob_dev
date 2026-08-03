defmodule MobDev.Discovery.IOS do
  @moduledoc """
  Discovers iOS simulators via xcrun simctl.

  Physical iOS device support requires libimobiledevice (ideviceinfo, iproxy).
  Best-effort: works if tools are installed, degrades gracefully if not.
  """

  alias MobDev.Device

  @doc "Returns booted iOS simulators."
  @spec list_simulators() :: [Device.t()]
  def list_simulators do
    case System.find_executable("xcrun") do
      nil -> []
      _ -> do_list_simulators()
    end
  end

  @doc """
  Returns connected physical iOS devices.

  Always runs both USB discovery (`ideviceinfo`) and a LAN EPMD scan in
  parallel. The LAN scan finds the device's actual node IP (which is
  WiFi-first since mob_beam.m prefers a stable LAN address). The USB scan
  provides the UDID and device name. Results are merged: one device with the
  correct WiFi IP and full USB metadata.

  If only one path finds the device, that result is used directly — so this
  works on USB-only setups and WiFi-only setups equally. When USB finds a
  device but LAN scan doesn't (cold ARP, rapid app launch, etc.), the
  result is enriched via `xcrun devicectl` — we ask for the device's known
  hostnames + tunnel IPs, resolve to IPv4, and probe each with EPMD. Single
  TCP probe per candidate, so it costs ~50 ms in the success case and
  doesn't slow down the no-iOS path.
  """
  @spec list_physical() :: [Device.t()]
  def list_physical do
    lan = scan_lan_for_physical()
    usb = if System.find_executable("ideviceinfo"), do: do_list_physical(), else: []

    case {lan, usb} do
      # Both found exactly one device — merge: keep WiFi IP for dist, use USB serial for devicectl.
      {[lan_dev], [usb_dev]} ->
        [%{lan_dev | serial: usb_dev.serial, name: usb_dev.name, version: usb_dev.version}]

      # Multiple LAN devices + USB devices — can't auto-correlate IPs to UDIDs.
      # Return USB devices (have proper UDIDs for devicectl) plus any LAN devices
      # whose IP doesn't match a USB device. LAN-only devices will fall back to
      # dist-only in the deployer.
      {[_ | _], [_ | _]} ->
        usb_serials = MapSet.new(usb, & &1.serial)
        lan_only = Enum.reject(lan, fn d -> MapSet.member?(usb_serials, d.serial) end)
        usb ++ lan_only

      # LAN found devices, USB didn't (WiFi-only environment).
      {[_ | _], []} ->
        lan

      # USB found devices, LAN didn't — try devicectl-driven enrichment so the
      # IP shows up in `mix mob.devices` and the bench can short-circuit to
      # `--wifi-ip <ip>` next time.
      {[], [_ | _]} ->
        enrich_with_devicectl(usb)

      {[], []} ->
        []
    end
  end

  # For each USB-discovered device, ask devicectl for known hostnames and
  # tunnel IPs, resolve them to IPv4, and probe each with EPMD. The first
  # successful probe attaches host_ip + node + dist_port to the USB device.
  # If no probe succeeds, return the USB device unchanged.
  defp enrich_with_devicectl(usb_devices) do
    ips = devicectl_ipv4_addresses()

    if ips == [] do
      usb_devices
    else
      Enum.map(usb_devices, fn d ->
        Enum.find_value(ips, d, fn ip ->
          case find_physical_at(ip) do
            %Device{} = lan_d ->
              %{d | host_ip: ip, node: lan_d.node, dist_port: lan_d.dist_port}

            _ ->
              nil
          end
        end)
      end)
    end
  end

  @doc """
  Returns the IPv4 addresses every connected physical device is known to
  reach Mac at, derived from `xcrun devicectl list devices --json-output`.
  Sources, in order:

    1. `connectionProperties.tunnelIPAddress` if it's an IPv4 (CoreDevice
       USB tunnel; sometimes IPv6, which Erlang dist doesn't speak)
    2. `connectionProperties.localHostnames` resolved via `:inet.gethostbyname/1`
       (mDNS hostnames like `Kevins-iPhone.coredevice.local`, which usually
       resolve to the device's WiFi IPv4)

  Returns `[]` if `xcrun` isn't installed, the JSON parse fails, or no
  device has any IPv4. Pure of side effects beyond the temp file used to
  capture devicectl's JSON output.
  """
  @spec devicectl_ipv4_addresses() :: [String.t()]
  def devicectl_ipv4_addresses do
    if System.find_executable("xcrun") do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "mob_devs_ipv4_#{System.unique_integer([:positive])}.json"
        )

      try do
        case System.cmd("xcrun", ["devicectl", "list", "devices", "--json-output", tmp],
               stderr_to_stdout: true
             ) do
          {_, 0} ->
            tmp
            |> File.read!()
            |> Jason.decode!()
            |> get_in(["result", "devices"])
            |> List.wrap()
            |> Enum.flat_map(&device_ipv4_candidates/1)
            |> Enum.uniq()

          _ ->
            []
        end
      rescue
        _ -> []
      after
        File.rm(tmp)
      end
    else
      []
    end
  end

  defp device_ipv4_candidates(dev) do
    conn = Map.get(dev, "connectionProperties", %{})

    tunnel =
      case conn["tunnelIPAddress"] do
        ip when is_binary(ip) ->
          if String.contains?(ip, ":"), do: nil, else: ip

        _ ->
          nil
      end

    hostname_ips =
      conn["localHostnames"]
      |> List.wrap()
      |> Enum.flat_map(&resolve_hostname_to_ipv4/1)

    [tunnel | hostname_ips] |> Enum.reject(&is_nil/1)
  end

  defp resolve_hostname_to_ipv4(hostname) when is_binary(hostname) do
    case :inet.gethostbyname(String.to_charlist(hostname)) do
      {:ok, {:hostent, _, _, :inet, 4, addrs}} when is_list(addrs) ->
        Enum.map(addrs, fn addr -> addr |> Tuple.to_list() |> Enum.join(".") end)

      _ ->
        []
    end
  end

  defp resolve_hostname_to_ipv4(_), do: []

  @doc "Returns all iOS devices (simulators + physical)."
  @spec list_devices() :: [Device.t()]
  def list_devices do
    list_simulators() ++ list_physical()
  end

  @doc """
  Queries EPMD at a specific IP for any `*_ios` node and returns a Device, or
  nil if no iOS BEAM node is reachable there. Used for direct connection when
  the IP is already known (e.g. from xcrun devicectl) and ARP may not be warm.
  """
  @spec find_physical_at(String.t()) :: Device.t() | nil
  def find_physical_at(ip) do
    case query_ios_epmd(ip) do
      {:ok, short_name, dist_port} ->
        %Device{
          platform: :ios,
          type: :physical,
          serial: ip,
          name: "iPhone (#{ip})",
          host_ip: ip,
          dist_port: dist_port,
          status: :discovered,
          node: :"#{short_name}@#{ip}"
        }

      _ ->
        nil
    end
  end

  defp do_list_simulators do
    case System.cmd("xcrun", ["simctl", "list", "devices", "booted", "--json"],
           stderr_to_stdout: true
         ) do
      {output, 0} -> parse_simctl_json(output)
      _ -> []
    end
  rescue
    # Jason not available — fall back to simpler text parsing
    _ -> list_simulators_text()
  end

  @doc """
  Parses the JSON output of `xcrun simctl list devices booted --json`.
  Exposed for testing.
  """
  @spec parse_simctl_json(String.t()) :: [Device.t()]
  def parse_simctl_json(json_string) do
    json_string
    |> Jason.decode!()
    |> Map.get("devices", %{})
    |> Enum.flat_map(fn {runtime, devices} ->
      version = parse_runtime_version(runtime)
      Enum.map(devices, &sim_to_device(&1, version))
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp list_simulators_text do
    case System.cmd("xcrun", ["simctl", "list", "devices", "booted"], stderr_to_stdout: true) do
      {output, 0} -> parse_simctl_text(output)
      _ -> []
    end
  end

  @doc """
  Parses the plain-text output of `xcrun simctl list devices booted`.
  Exposed for testing.
  """
  @spec parse_simctl_text(String.t()) :: [Device.t()]
  def parse_simctl_text(output) do
    output
    |> String.split("\n")
    |> Enum.flat_map(&parse_simctl_text_line/1)
  end

  # Parse lines like:
  #   iPhone 17 (78354490-EF38-44D7-A437-DD941C20524D) (Booted)
  defp parse_simctl_text_line(line) do
    case Regex.run(Regex.compile!("^\\s+(.+?) \\(([0-9A-F-]{36})\\) \\(Booted\\)", "i"), line) do
      [_, name, udid] ->
        d = %Device{
          platform: :ios,
          serial: udid,
          name: name,
          type: :simulator,
          status: :booted
        }

        [%{d | node: Device.node_name(d)}]

      _ ->
        []
    end
  end

  defp sim_to_device(%{"udid" => udid, "name" => name, "state" => "Booted"}, version) do
    d = %Device{
      platform: :ios,
      serial: udid,
      name: name,
      version: version,
      type: :simulator,
      status: :booted
    }

    %{d | node: Device.node_name(d)}
  end

  defp sim_to_device(_, _), do: nil

  @doc "Parses a CoreSimulator runtime key into a human-readable version string. Exposed for testing."
  @spec parse_runtime_version(String.t()) :: String.t()
  def parse_runtime_version(runtime) do
    case Regex.run(Regex.compile!("iOS-(\\d+)-(\\d+)"), runtime) do
      [_, major, minor] ->
        "iOS #{major}.#{minor}"

      _ ->
        # "com.apple.CoreSimulator.SimRuntime.iOS-18-0" style
        runtime |> String.split(".") |> List.last() |> String.replace("-", ".")
    end
  end

  defp do_list_physical do
    case System.cmd("ideviceinfo", ["-k", "UniqueDeviceID"], stderr_to_stdout: true) do
      {udid, 0} ->
        udid = String.trim(udid)
        name = ideviceinfo(udid, "DeviceName")
        version = ideviceinfo(udid, "ProductVersion")

        d = %Device{
          platform: :ios,
          serial: udid,
          name: name,
          version: "iOS #{version}",
          type: :physical,
          status: :discovered
        }

        [%{d | node: Device.node_name(d)}]

      _ ->
        []
    end
  end

  defp ideviceinfo(_udid, key) do
    case System.cmd("ideviceinfo", ["-k", key], stderr_to_stdout: true) do
      {val, 0} -> String.trim(val)
      _ -> nil
    end
  end

  # Scan the local ARP table for any host running an iOS EPMD node (*_ios).
  # Builds a Device using the node name and IP directly from the EPMD response,
  # so the app name in the Mix project running mob_dev is irrelevant.
  defp scan_lan_for_physical do
    own_ips = local_ipv4_addresses()

    lan_ips =
      case System.cmd("arp", ["-a"], stderr_to_stdout: true) do
        {out, 0} ->
          out
          |> String.split("\n")
          |> Enum.flat_map(fn line ->
            case Regex.run(
                   Regex.compile!("\\((\\d+\\.\\d+\\.\\d+\\.\\d+)\\) at [0-9a-f]{2}:[0-9a-f]{2}"),
                   line
                 ) do
              [_, ip] ->
                cond do
                  String.starts_with?(ip, "169.254.") -> []
                  ip in own_ips -> []
                  true -> [ip]
                end

              _ ->
                []
            end
          end)

        _ ->
          []
      end

    Enum.flat_map(lan_ips, fn ip ->
      case query_ios_epmd(ip) do
        {:ok, short_name, dist_port} ->
          node = :"#{short_name}@#{ip}"

          d = %Device{
            platform: :ios,
            type: :physical,
            serial: ip,
            name: "iPhone (#{ip})",
            host_ip: ip,
            dist_port: dist_port,
            status: :discovered,
            node: node
          }

          [d]

        _ ->
          []
      end
    end)
  end

  # Query EPMD at ip:4369 for any *_ios node.
  # Returns {:ok, short_name, dist_port} using the actual name from EPMD,
  # so the result is independent of which Mix project is running mob_dev.
  #
  # Validates the dist port to avoid a phantom hit: an Android phone with
  # `adb reverse tcp:4369 tcp:4369` configured will forward LAN connections
  # to its port 4369 *back to Mac's EPMD*, so we'd see the simulator's
  # entries and think they live on the Android device. The simulator's dist
  # port isn't tunneled the same way, so probing it tells us whether the
  # EPMD entry actually corresponds to a reachable BEAM at this IP.
  defp query_ios_epmd(ip) do
    host = String.to_charlist(ip)

    with {:ok, s} <- :gen_tcp.connect(host, 4369, [:binary, active: false], 1000),
         :ok <- :gen_tcp.send(s, <<0, 1, ?n>>),
         {:ok, <<_::32, names::binary>>} = recv <- :gen_tcp.recv(s, 0, 1000) do
      :gen_tcp.close(s)

      candidate =
        names
        |> String.split("\n")
        |> Enum.find_value(fn line ->
          case Regex.run(Regex.compile!("name ([a-z0-9_]+_ios[^\\s]*) at port (\\d+)", "i"), line) do
            [_, short_name, port] -> {short_name, String.to_integer(port)}
            _ -> nil
          end
        end)

      _ = recv

      case candidate do
        nil ->
          {:error, :not_ios_node}

        {short_name, dist_port} ->
          if dist_port_reachable?(ip, dist_port) do
            {:ok, short_name, dist_port}
          else
            {:error, :dist_phantom}
          end
      end
    else
      _ -> {:error, :epmd_unreachable}
    end
  end

  # TCP-probe the claimed dist port to confirm the EPMD entry isn't a phantom
  # (e.g. tunneled-EPMD case described above). 500 ms is plenty for a LAN
  # connect and short enough that scanning N hosts stays under a second total.
  defp dist_port_reachable?(ip, port) do
    case :gen_tcp.connect(String.to_charlist(ip), port, [:binary, active: false], 500) do
      {:ok, s} ->
        :gen_tcp.close(s)
        true

      _ ->
        false
    end
  end

  # Returns the Mac's own IPv4 addresses, used to filter the LAN scan so we
  # don't mistake the Mac's local EPMD (which may have a simulator registered)
  # for a physical iPhone.
  defp local_ipv4_addresses do
    case :inet.getifaddrs() do
      {:ok, ifs} ->
        for {_name, props} <- ifs,
            {:addr, {a, b, c, d}} <- props,
            a in 0..255,
            "#{a}.#{b}.#{c}.#{d}" != "127.0.0.1" do
          "#{a}.#{b}.#{c}.#{d}"
        end

      _ ->
        []
    end
  end

  @doc """
  Launches the app on a booted simulator.

  Passes env vars through to the simulator app via `simctl`'s
  `SIMCTL_CHILD_*` mechanism (the prefix is stripped before delivery
  to the child process):

    * `MOB_DIST_PORT`        — Erlang dist listen port
    * `MOB_NODE_SUFFIX`      — appended to the BEAM node name. When
      absent, `mob_beam.m` falls back to deriving a suffix from
      `SIMULATOR_UDID` so concurrent sims still get unique names.
    * `MOB_SIM_RUNTIME_DIR`  — directory the OTP runtime was written
      to; `mob_beam.m` reads from the same place `ios/build.sh` wrote.

  Options:

    * `:dist_port`    — pin the dist listen port (default `9100`).
    * `:node_suffix`  — override the BEAM node-name suffix. `nil` lets
      `mob_beam.m` auto-derive from `SIMULATOR_UDID`.
  """
  @spec launch_app(String.t(), String.t(), keyword()) :: {String.t(), non_neg_integer()}
  def launch_app(udid, bundle_id, opts \\ []) do
    runtime_dir = MobDev.Paths.sim_runtime_dir()
    env = build_simctl_env(opts, runtime_dir)

    System.cmd("xcrun", build_simctl_launch_args(udid, bundle_id),
      stderr_to_stdout: true,
      env: env
    )
  end

  @doc false
  @spec build_simctl_launch_args(String.t(), String.t()) :: [String.t()]
  def build_simctl_launch_args(udid, bundle_id)
      when is_binary(udid) and is_binary(bundle_id) do
    ["simctl", "launch", "--terminate-running-process", udid, bundle_id]
  end

  @doc """
  Builds the `SIMCTL_CHILD_*` env-var list `launch_app/3` passes to
  simctl. Extracted as a pure function so the override behaviour can be
  unit-tested without spawning subprocesses.

  Always emits:

    * `SIMCTL_CHILD_MOB_DIST_PORT`        — `:dist_port` opt, default 9100
    * `SIMCTL_CHILD_MOB_SIM_RUNTIME_DIR`  — runtime_dir arg

  Conditionally emits:

    * `SIMCTL_CHILD_MOB_NODE_SUFFIX`      — only when `:node_suffix` is a
      non-empty string. nil / "" → mob_beam.m auto-derives from
      SIMULATOR_UDID.
  """
  @spec build_simctl_env(keyword(), String.t()) :: [{String.t(), String.t()}]
  def build_simctl_env(opts, runtime_dir) do
    dist_port = Keyword.get(opts, :dist_port, 9100)
    node_suffix = Keyword.get(opts, :node_suffix)

    base = [
      {"SIMCTL_CHILD_MOB_DIST_PORT", to_string(dist_port)},
      {"SIMCTL_CHILD_MOB_SIM_RUNTIME_DIR", runtime_dir}
    ]

    if node_suffix && node_suffix != "" do
      base ++ [{"SIMCTL_CHILD_MOB_NODE_SUFFIX", node_suffix}]
    else
      base
    end
  end

  @spec terminate_app(String.t(), String.t()) :: {String.t(), non_neg_integer()}
  def terminate_app(udid, bundle_id) do
    System.cmd("xcrun", ["simctl", "terminate", udid, bundle_id], stderr_to_stdout: true)
  end

  @doc """
  Restarts only the target app on a physical iOS device via xcrun devicectl.
  `--terminate-existing` atomically replaces an existing instance of that exact
  bundle without terminating unrelated user applications.
  """
  @spec restart_app_physical(String.t(), String.t()) :: {String.t(), non_neg_integer()}
  def restart_app_physical(udid, bundle_id) do
    restart_app_physical(udid, bundle_id, &System.cmd/3)
  end

  @doc false
  @spec restart_app_physical(String.t(), String.t(), function()) ::
          {String.t(), non_neg_integer()}
  def restart_app_physical(udid, bundle_id, runner)
      when is_binary(udid) and is_binary(bundle_id) and is_function(runner, 3) do
    runner.(
      "xcrun",
      build_devicectl_launch_args(udid, bundle_id),
      stderr_to_stdout: true
    )
  end

  @doc false
  @spec build_devicectl_launch_args(String.t(), String.t()) :: [String.t()]
  def build_devicectl_launch_args(udid, bundle_id)
      when is_binary(udid) and is_binary(bundle_id) do
    [
      "devicectl",
      "device",
      "process",
      "launch",
      "--device",
      udid,
      "--terminate-existing",
      bundle_id
    ]
  end

  @doc """
  Enables the iOS accessibility system for the given simulator (or "booted").

  SwiftUI lazily populates its accessibility tree only when an accessibility
  service is active. `pegleg_nif:ui_tree/0` requires this to be called once
  per simulator session before it can return elements. Writes the VoiceOver
  preference into the simulator's preference store and posts the Darwin
  notification that UIKit listens to.

  Safe to call repeatedly — idempotent.
  """
  @spec enable_accessibility(String.t()) :: :ok
  def enable_accessibility(udid) do
    System.cmd(
      "xcrun",
      [
        "simctl",
        "spawn",
        udid,
        "defaults",
        "write",
        "com.apple.Accessibility",
        "VoiceOverTouchEnabled",
        "-bool",
        "YES"
      ],
      stderr_to_stdout: true
    )

    System.cmd(
      "xcrun",
      [
        "simctl",
        "spawn",
        udid,
        "notifyutil",
        "-p",
        "com.apple.accessibility.voiceover.status.changed"
      ],
      stderr_to_stdout: true
    )

    :ok
  end
end
