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
  WiFi-first since mob_beam.m prefers a stable LAN address) — only for the
  current project's app (`select_ios_node/2`); another Mob app's node on the
  same phone is not this project's device. The USB scan provides the UDID and
  device name. Results are merged: one device with the correct WiFi IP and
  full USB metadata.

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
    devicectl_devices()
    |> Enum.flat_map(&device_ipv4_candidates/1)
    |> Enum.uniq()
  end

  # The `result.devices` of `xcrun devicectl list devices --json-output`, or
  # [] when xcrun is missing, devicectl fails or its JSON doesn't parse.
  defp devicectl_devices do
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

  @doc """
  The USB link-local IPv4 (`169.254.x.x`) of the physical iPhone `udid`,
  looked up from the phone's own mDNS name, or nil.

  devicectl lists each paired phone's CoreDevice hostnames
  (`connectionProperties.localHostnames`, e.g.
  `Kevins-iPhone.coredevice.local`); the phone answers mDNS as the same
  label under `.local` (`Kevins-iPhone.local`) with its USB link-local
  address and its WiFi address. Picking the link-local one from the names of
  this UDID ties the address to the phone being connected, which an ARP scan
  (the first resolved `169.254.*` neighbour of any device) does not, and it
  works where ARP can't be read: on macOS 27 `arp` spawned from the BEAM
  sees an empty table (MOB-428).

  The lookups share one deadline (`:timeout_ms`, 3 s); `:devices` (decoded
  devicectl devices) and `:resolve` (name → IPv4 strings) replace the real
  calls in tests.
  """
  @spec usb_link_local_ip(String.t(), keyword()) :: String.t() | nil
  def usb_link_local_ip(udid, opts \\ []) do
    devices = Keyword.get_lazy(opts, :devices, &devicectl_devices/0)
    resolve = Keyword.get(opts, :resolve, &resolve_hostname_to_ipv4/1)
    names = usb_mdns_names(devices, udid)

    task = Task.async(fn -> Enum.find_value(names, &link_local_ipv4(resolve.(&1))) end)

    case Task.yield(task, Keyword.get(opts, :timeout_ms, 3_000)) ||
           Task.shutdown(task, :brutal_kill) do
      {:ok, ip} -> ip
      _ -> nil
    end
  end

  @doc """
  The `.local` names the phone `udid` answers mDNS under, from devicectl's
  device list: each `<label>.coredevice.local` hostname of that device as
  `<label>.local`, skipping the labels that are the UDID or a CoreDevice
  identifier (those only resolve to the IPv6 tunnel). Other devices' names
  are never returned.
  """
  @spec usb_mdns_names([map()], String.t()) :: [String.t()]
  def usb_mdns_names(devices, udid) do
    devices
    |> Enum.filter(&(get_in(&1, ["hardwareProperties", "udid"]) == udid))
    |> Enum.flat_map(fn dev ->
      conn = Map.get(dev, "connectionProperties") || %{}
      List.wrap(conn["localHostnames"]) ++ List.wrap(conn["potentialHostnames"])
    end)
    |> Enum.flat_map(fn
      host when is_binary(host) ->
        case Regex.run(~r/^(.+)\.coredevice\.local\.?$/i, host) do
          [_, label] -> if identifier_label?(label, udid), do: [], else: ["#{label}.local"]
          nil -> []
        end

      _ ->
        []
    end)
    |> Enum.uniq()
  end

  defp identifier_label?(label, udid) do
    String.downcase(label) == String.downcase(udid) or
      label =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i or
      label =~ ~r/^[0-9a-f]{8}-[0-9a-f]{16}$/i or
      label =~ ~r/^[0-9a-f]{40}$/i
  end

  @doc "The first link-local (`169.254.x.x`) address in `ips`, or nil."
  @spec link_local_ipv4([String.t()]) :: String.t() | nil
  def link_local_ipv4(ips), do: Enum.find(ips, &String.starts_with?(&1, "169.254."))

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

  @typedoc "What EPMD at one IP says about the project's iOS node."
  @type epmd_probe :: {:ok, String.t(), pos_integer()} | {:error, atom()}

  @doc """
  Queries EPMD at a specific IP for the current project's iOS node (see
  `select_ios_node/2`) and returns a Device, or nil if that node is not
  reachable there. Used for direct connection when the IP is already known
  (e.g. from xcrun devicectl) and ARP may not be warm.
  """
  @spec find_physical_at(String.t()) :: Device.t() | nil
  def find_physical_at(ip) do
    case query_ios_epmd(ip, Device.ios_node_base()) do
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

  @doc """
  Resolves where a USB-discovered iPhone's node is registered: probes EPMD on
  `link_local_ip` (the phone's USB address, or nil if unknown) and on the
  phone's other IPv4 addresses, then decides with `choose_usb_node/2`.

  The other addresses are looked up from the phone, not collected from the
  LAN: the link-local IP reverse-resolves to the phone's mDNS name
  (`kevins-iphone.local`), which forward-resolves to the addresses registered
  under that name, its WiFi IP included. Scanning ARP neighbours instead
  finds any phone running this app, and every phone's BEAM listens on the same
  dist port (mob_beam.m's 9101 default), so EPMD cannot tell them apart.

  This narrows the candidates but does not prove they are the same phone. The
  lookups are not scoped to the USB interface, and mDNS allows the same
  `.local` name on different links (RFC 6762 §14). A known limitation: if two
  phones share a `.local` name, one USB-only and one on the LAN running the
  same app, the LAN phone's address can be taken for the USB phone's. Scoping
  the lookups to the USB interface (`dns-sd -i <enN>`) would close that.

  The lookups are native and synchronous, and each can take seconds, so they
  share a deadline (`same_phone_ipv4s/3`); running out means no other
  addresses, and the link-local IP is used.
  """
  @spec resolve_usb_node(String.t() | nil) ::
          {:registered, String.t(), String.t(), pos_integer()} | {:predicted, String.t()} | :none
  def resolve_usb_node(nil), do: choose_usb_node(nil, [])

  def resolve_usb_node(link_local_ip) do
    base = Device.ios_node_base()
    same_phone = Enum.map(same_phone_ipv4s(link_local_ip), &{&1, query_ios_epmd(&1, base)})
    choose_usb_node({link_local_ip, query_ios_epmd(link_local_ip, base)}, same_phone)
  end

  @doc false
  @spec same_phone_ipv4s(String.t(), (String.t() -> [String.t()]), timeout()) :: [String.t()]
  def same_phone_ipv4s(link_local_ip, resolve \\ &mdns_ipv4s/1, timeout_ms \\ 3_000) do
    task = Task.async(fn -> resolve.(link_local_ip) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, ips} -> List.delete(ips, link_local_ip)
      _ -> []
    end
  end

  defp mdns_ipv4s(link_local_ip) do
    with {:ok, addr} <- :inet.parse_ipv4_address(String.to_charlist(link_local_ip)),
         {:ok, {:hostent, name, _, _, _, _}} <- :inet.gethostbyaddr(addr),
         {:ok, addrs} <- :inet.getaddrs(name, :inet) do
      Enum.map(addrs, &(&1 |> :inet.ntoa() |> to_string()))
    else
      _ -> []
    end
  end

  @doc """
  Picks the IP a USB-attached iPhone's node is registered at, from EPMD
  probes (`{ip, epmd_probe}`) of the phone's USB link-local IP and of the
  phone's own other addresses (see `resolve_usb_node/1`).

  mob_beam.m names the node after the phone's WiFi/LAN IP whenever it has one
  and uses the link-local IP only without WiFi. The phone's EPMD binds
  0.0.0.0, so the link-local probe lists the node even when its name carries
  the WiFi IP. The link-local probe is the one that reached the phone on the
  cable, so it is the reference: another address is taken only if its EPMD
  lists the same node at the same dist port — the same BEAM, seen twice — and
  it is the only such address. Anything else (another address's entry
  disagrees, several agree, or the link-local EPMD lists nothing) keeps the
  link-local IP, because nothing proves the other entry is this phone's.

  Returns `{:registered, ip, name, dist_port}` from EPMD,
  `{:predicted, link_local_ip}` when the link-local EPMD does not list the
  node yet (the app is not running; `mix mob.connect` launches it after
  tunnel setup), or `:none` without a link-local IP.
  """
  @spec choose_usb_node({String.t(), epmd_probe()} | nil, [{String.t(), epmd_probe()}]) ::
          {:registered, String.t(), String.t(), pos_integer()} | {:predicted, String.t()} | :none
  def choose_usb_node(nil, _same_phone_probes), do: :none

  def choose_usb_node({link_local_ip, {:ok, name, port}}, same_phone_probes) do
    case for({ip, {:ok, ^name, ^port}} <- same_phone_probes, do: ip) do
      [ip] -> {:registered, ip, name, port}
      _ -> {:registered, link_local_ip, name, port}
    end
  end

  def choose_usb_node({link_local_ip, _not_registered}, _same_phone_probes),
    do: {:predicted, link_local_ip}

  @doc """
  Every `{name, port}` in an EPMD `NAMES_REQ` reply — a 4-byte EPMD port, then
  one `name <node> at port <port>` line per registered node — in EPMD order.
  An iPhone's EPMD can list more than one Mob app, so all entries matter.
  """
  @spec parse_epmd_names(binary()) :: [{String.t(), pos_integer()}]
  def parse_epmd_names(<<_epmd_port::32, names::binary>>) do
    ~r/^name (\S+) at port (\d+)$/m
    |> Regex.scan(names, capture: :all_but_first)
    |> Enum.map(fn [name, port] -> {name, String.to_integer(port)} end)
  end

  def parse_epmd_names(_reply), do: []

  @doc """
  The EPMD entry that is the project's iOS node, or nil.

  `base` is `Device.ios_node_base/0` (`<app>_ios`). The entry must be `base`
  itself or `base_<suffix>` (mob_beam.m appends `MOB_NODE_SUFFIX` when set);
  the unsuffixed name wins when both are listed. Another app's node on the
  same EPMD never matches — taking the first `*_ios` entry attached
  `mix mob.connect` to a different app on the same phone (MOB-283).

  `base` is nil only outside a Mix project, where no app is known; then the
  first `*_ios` entry is the only choice there is.
  """
  @spec select_ios_node([{String.t(), pos_integer()}], String.t() | nil) ::
          {String.t(), pos_integer()} | nil
  def select_ios_node(entries, nil) do
    Enum.find(entries, fn {name, _port} -> Regex.match?(~r/^[a-z0-9_]+_ios/i, name) end)
  end

  def select_ios_node(entries, base) do
    Enum.find(entries, fn {name, _port} -> name == base end) ||
      Enum.find(entries, fn {name, _port} -> String.starts_with?(name, base <> "_") end)
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

  # Every LAN ARP neighbour whose EPMD lists the current project's iOS node,
  # as a Device carrying the node name and IP EPMD reported.
  defp scan_lan_for_physical do
    lan_ips()
    |> Enum.map(&find_physical_at/1)
    |> Enum.reject(&is_nil/1)
  end

  # Resolved IPv4 neighbours from the ARP table, minus link-local and the
  # Mac's own addresses. `-n`: only the IPs are used, and `arp -a`'s
  # reverse-DNS lookups took 15 s per scan on a LAN with a slow resolver.
  defp lan_ips do
    own_ips = local_ipv4_addresses()

    case System.cmd("arp", ["-an"], stderr_to_stdout: true) do
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
  end

  # Query EPMD at ip:4369 for the project's iOS node (`select_ios_node/2`).
  # Returns {:ok, short_name, dist_port} with the name EPMD actually lists.
  #
  # Validates the dist port to avoid a phantom hit: an Android phone with
  # `adb reverse tcp:4369 tcp:4369` configured will forward LAN connections
  # to its port 4369 *back to Mac's EPMD*, so we'd see the simulator's
  # entries and think they live on the Android device. The simulator's dist
  # port isn't tunneled the same way, so probing it tells us whether the
  # EPMD entry actually corresponds to a reachable BEAM at this IP.
  defp query_ios_epmd(ip, base) do
    with {:ok, reply} <- epmd_names(ip) do
      case reply |> parse_epmd_names() |> select_ios_node(base) do
        nil ->
          {:error, :not_ios_node}

        {short_name, dist_port} ->
          if dist_port_reachable?(ip, dist_port) do
            {:ok, short_name, dist_port}
          else
            {:error, :dist_phantom}
          end
      end
    end
  end

  # Whole NAMES_REQ exchange, not per read: a peer that trickles bytes would
  # otherwise reset a per-recv timeout forever and hang discovery.
  @epmd_reply_deadline_ms 2_000

  @doc false
  @spec epmd_names(String.t(), :inet.port_number(), pos_integer()) ::
          {:ok, binary()} | {:error, term()}
  def epmd_names(ip, port \\ 4369, deadline_ms \\ @epmd_reply_deadline_ms) do
    case :gen_tcp.connect(String.to_charlist(ip), port, [:binary, active: false], 1000) do
      {:ok, s} ->
        deadline = System.monotonic_time(:millisecond) + deadline_ms

        try do
          with :ok <- :gen_tcp.send(s, <<0, 1, ?n>>), do: recv_until_closed(s, <<>>, deadline)
        after
          :gen_tcp.close(s)
        end

      {:error, _} ->
        {:error, :epmd_unreachable}
    end
  end

  # EPMD sends the 4-byte header and each name line as separate writes, then
  # closes (erts/epmd/src/epmd_srv.c, EPMD_NAMES_REQ). One recv can return
  # just the header, so read until close to see every registered node.
  defp recv_until_closed(s, acc, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    with true <- remaining > 0,
         {:ok, data} <- :gen_tcp.recv(s, 0, remaining) do
      recv_until_closed(s, acc <> data, deadline)
    else
      {:error, :closed} -> {:ok, acc}
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
    * `MOB_DIST_COOKIE`      — private development distribution cookie.
    * `MOB_SIM_RUNTIME_DIR`  — directory the OTP runtime was written
      to; `mob_beam.m` reads from the same place `ios/build.sh` wrote.

  Options:

    * `:dist_port`    — pin the dist listen port (default `9100`).
    * `:node_suffix`  — override the BEAM node-name suffix. `nil` lets
      `mob_beam.m` auto-derive from `SIMULATOR_UDID`.
    * `:dist_cookie`  — private development distribution cookie.
  """
  @spec launch_app(String.t(), String.t(), keyword()) :: {String.t(), non_neg_integer()}
  def launch_app(udid, bundle_id, opts \\ []) do
    runtime_dir = MobDev.Paths.sim_runtime_dir()
    env = build_simctl_env(opts, runtime_dir)

    System.cmd("xcrun", ["simctl", "launch", udid, bundle_id],
      stderr_to_stdout: true,
      env: env
    )
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

    base
    |> maybe_add_env("SIMCTL_CHILD_MOB_NODE_SUFFIX", node_suffix)
    |> maybe_add_env("SIMCTL_CHILD_MOB_DIST_COOKIE", Keyword.get(opts, :dist_cookie))
  end

  defp maybe_add_env(env, _key, nil), do: env
  defp maybe_add_env(env, _key, ""), do: env
  defp maybe_add_env(env, key, value), do: env ++ [{key, value}]

  @spec terminate_app(String.t(), String.t()) :: {String.t(), non_neg_integer()}
  def terminate_app(udid, bundle_id) do
    System.cmd("xcrun", ["simctl", "terminate", udid, bundle_id], stderr_to_stdout: true)
  end

  @doc """
  Restarts the app on a physical iOS device via xcrun devicectl.

  First clears other Mob apps that `mob_dev` installed on this device — they
  each hold EPMD 4369 and only one can run at a time — then launches the
  target app fresh. Apps `mob_dev` did not install are never touched, whoever
  they belong to. See `MobDev.IOSInstalls` and MOB-70.
  """
  @spec restart_app_physical(String.t(), String.t(), keyword()) ::
          {String.t(), non_neg_integer()}
  def restart_app_physical(udid, bundle_id, opts \\ []) do
    kill_other_user_apps_physical(udid, bundle_id)

    # --terminate-existing kills any remaining instance of *this* app atomically.
    System.cmd(
      "xcrun",
      [
        "devicectl",
        "device",
        "process",
        "launch",
        "--device",
        udid,
        "--terminate-existing",
        bundle_id
      ],
      stderr_to_stdout: true,
      env: physical_launch_env(opts)
    )
  end

  @doc """
  The `devicectl device process launch` environment for a physical iPhone
  (`DEVICECTL_CHILD_*` reaches the app): the dist cookie (`:dist_cookie`) and
  the host the node must be named after (`:node_host`, an IPv4 the Mac
  reaches the phone at). mob_beam.m (mob ≥ 0.9.16) takes `MOB_NODE_HOST`
  when it is one of the phone's own addresses; without it the phone names
  its node after its WiFi address, which the Mac can't dial when that WiFi is
  a network the Mac isn't on (MOB-428). Older mob ignores it.
  """
  @spec physical_launch_env(keyword()) :: [{String.t(), String.t()}]
  def physical_launch_env(opts) do
    cookie =
      case Keyword.get(opts, :dist_cookie) do
        c when is_binary(c) and c != "" -> [{"DEVICECTL_CHILD_MOB_DIST_COOKIE", c}]
        _ -> []
      end

    host =
      case Keyword.get(opts, :node_host) do
        ip when is_binary(ip) ->
          if match?({:ok, _}, :inet.parse_ipv4strict_address(String.to_charlist(ip))),
            do: [{"DEVICECTL_CHILD_MOB_NODE_HOST", ip}],
            else: []

        _ ->
          []
      end

    cookie ++ host
  end

  @doc """
  Process ids on the device that belong to Mob apps we may kill.

  Pure, so the decision that used to be untestable is now the testable part.
  `process_output` is `devicectl device info processes` output; `ours` is what
  `MobDev.IOSInstalls` says we installed on this device; `except_app_name` is
  the app about to be launched, which the caller launches with
  `--terminate-existing` anyway.

  Matching is on the `.app` bundle name in the executable path, because that
  is the only identifier the process listing carries — it has no bundle ids.

  **Anything not in `ours` is left alone.** The bug this replaced matched every
  process under `Bundle/Application/`, which is where *all* third-party apps
  live, so running `mix mob.connect` with a personal iPhone attached force-quit
  every app the owner had open (MOB-70). An empty `ours` returns `[]`: not
  knowing what is ours means killing nothing.
  """
  @spec mob_pids_to_kill(String.t(), [String.t()], String.t() | nil) :: [pos_integer()]
  def mob_pids_to_kill(process_output, ours, except_app_name \\ nil) do
    killable = MapSet.new(ours) |> MapSet.delete(except_app_name)

    process_output
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      # Anchored to Bundle/Application/, which is where third-party apps live.
      # Without the anchor this matches system processes too — SpringBoard,
      # Preferences, Spotlight, News — and the only thing standing between us
      # and killing one is that no project happens to camelize to its name.
      # That is not a safety property. A project named `news` produces
      # `News.app`; Apple ships `News.app` too, and `MobileCal.app` really does
      # run from Bundle/Application/, so a project named `mobile_cal` would
      # collide exactly. The registry is what protects the user here — the
      # anchor only removes the 24 system processes that were never candidates.
      case Regex.run(~r{^\s*(\d+)\s+.*/Bundle/Application/[^/]+/([^/]+)\.app/}, line) do
        [_, pid_str, app_name] ->
          if MapSet.member?(killable, app_name), do: [String.to_integer(pid_str)], else: []

        _ ->
          []
      end
    end)
  end

  @doc """
  The `.app` name for `bundle_id`, or `nil` if we have no record of it.

  Extracted so the translation is testable. Getting it wrong is not
  cosmetic: returning `nil` for the app about to be launched puts that app
  back in the kill set, so mob_dev `--kill`s it moments before `devicectl
  launch` targets it — the exact race the caller avoids by excluding it.
  """
  @spec except_app_name_for([MobDev.IOSInstalls.app()], String.t() | nil) :: String.t() | nil
  def except_app_name_for(ours, bundle_id) do
    Enum.find_value(ours, &if(&1.bundle_id == bundle_id, do: &1.app_name))
  end

  # Clear other Mob apps off the device before launching.
  #
  # Physical-device Mob apps each start an in-process EPMD on 0.0.0.0:4369
  # (mob/ios/mob_beam.m), so only one can run at a time — a second gets
  # EADDRINUSE and never boots. Clearing the others is genuinely required.
  #
  # What is not required is guessing. See `mob_pids_to_kill/3`.
  defp kill_other_user_apps_physical(udid, except_bundle) do
    ours = MobDev.IOSInstalls.installed(udid)
    app_names = Enum.map(ours, & &1.app_name)

    # The trade this fix makes, said out loud. A Mob app installed by some
    # other route — Xcode, TestFlight, a colleague's build — is no longer
    # cleared, so it keeps EPMD 4369 and the incoming app's BEAM dies inside a
    # launch that otherwise reports success. Left unexplained that is a worse
    # failure than the one being fixed, because it is silent.
    if app_names == [] do
      IO.puts(
        "  ⚠  No record of mob_dev installs on this device — nothing was cleared.\n" <>
          "     If the app launches but never joins the network, another Mob app may\n" <>
          "     be holding EPMD 4369; quit it on the device and retry."
      )
    end

    except_app_name = except_app_name_for(ours, except_bundle)

    {out, 0} =
      System.cmd("xcrun", ["devicectl", "device", "info", "processes", "--device", udid],
        stderr_to_stdout: true
      )

    out
    |> mob_pids_to_kill(app_names, except_app_name)
    |> Enum.each(fn pid ->
      System.cmd(
        "xcrun",
        [
          "devicectl",
          "device",
          "process",
          "terminate",
          "--device",
          udid,
          "--pid",
          to_string(pid),
          "--kill"
        ],
        stderr_to_stdout: true
      )
    end)

    :ok
  rescue
    _ -> :ok
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
