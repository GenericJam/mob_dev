defmodule MobDev.Connector do
  @moduledoc """
  Orchestrates device discovery, tunnel setup, app restart, and node connection.

  By default each app is restarted so it registers in the Mac's EPMD through
  the tunnels just set up, under the node name and dist port mob_dev expects
  (an app started before `adb reverse tcp:4369` existed never registered at
  all). `restart: false` attaches to the running app instead and leaves its
  state alone; on Android it looks the node up in EPMD under either the
  deploy-time name or the bare `<app>_android` a launcher start uses, and
  forwards the port that node actually registered.
  """

  alias MobDev.{Device, DeviceLeases, DistCookie, Tunnel}
  alias MobDev.Discovery.{Android, IOS}

  @android_activity ".MainActivity"

  defp bundle_id, do: MobDev.Config.bundle_id()
  defp android_package, do: bundle_id()
  @doc false
  @spec ios_bundle_id() :: String.t() | nil
  def ios_bundle_id, do: MobDev.Config.ios_bundle_id()
  # ms to wait for node to appear
  @connect_timeout 25_000
  # ms to wait when attaching to an app that is already running
  @attach_timeout 3_000
  # ms between polls
  @connect_interval 500
  # ms to let SwiftUI's accessibility tree rebuild after enable_accessibility's
  # notifyutil broadcast — see MOB-99.
  @ios_accessibility_settle_ms 500

  @doc """
  Discovers all connected devices, sets up tunnels, restarts apps (unless
  `restart: false`), and waits for Erlang nodes to come online.

  Returns {connected, failed} lists of %Device{}.
  """
  @spec connect_all(keyword()) :: {[Device.t()], [Device.t()]}
  def connect_all(opts \\ []) do
    platforms = opts |> Keyword.get(:platforms, [:android, :ios]) |> List.wrap()
    # The private cookie first; the legacy public one only for apps built
    # against a pre-MOB-49 mob (see MobDev.DistCookie).
    cookies = opts |> Keyword.get(:cookie) |> DistCookie.candidates()
    launch_cookie = hd(cookies)

    # The `mob.connect --name` option is documented for the multi-session
    # workflow (one IEx per developer, distinct EPMD names). Before MOB-69
    # this arg was accepted at the Mix-task layer, but connect_all/1
    # unconditionally started distribution under `mob_dev@127.0.0.1` — so
    # by the time `start_iex/3` tried to honor `--name`, `Node.alive?/0`
    # was already true and the Node.start was skipped. Threading the name
    # here fixes it end-to-end.
    local_name = local_name_from_opts(opts)

    only = opts |> Keyword.get(:only, []) |> List.wrap()
    restart = Keyword.get(opts, :restart, true)

    IO.puts("\n#{color(:cyan)}Scanning for devices...#{color(:reset)}\n")

    discovered = platforms |> discover_all(only) |> filter_only(only)

    # Without --device/--only every device is a target, so another
    # agent-device session's claimed devices are left alone; a named one is
    # used with a warning (MOB-330).
    leases = Keyword.get_lazy(opts, :leases, &DeviceLeases.load/0)

    devices =
      if only == [],
        do: DeviceLeases.exclude_claimed(discovered, leases),
        else: DeviceLeases.warn_claimed(discovered, leases)

    if devices == [] do
      cond do
        discovered != [] ->
          IO.puts(
            "  #{color(:yellow)}Every device found is claimed by another session.#{color(:reset)}"
          )

        only != [] ->
          IO.puts(
            "  #{color(:yellow)}No devices matched #{Enum.join(only, ", ")}.#{color(:reset)}"
          )

          IO.puts("  • Run `mix mob.connect` with no --only to list all discovered devices")

        true ->
          IO.puts("  #{color(:yellow)}No devices found.#{color(:reset)}")
          IO.puts("  • Connect an Android device via USB and enable USB debugging")
          IO.puts("  • Start an iOS simulator in Xcode or via xcrun simctl")
      end

      {[], []}
    else
      print_discovered(devices)

      # Set up tunnels (assigns dist_port per device)
      {tunneled, failed_tunnel} = setup_tunnels(devices)

      tunneled =
        if restart do
          # Kill any stale simulator processes from previous sessions. A lingering
          # BEAM holds its EPMD slot, blocking new instances from registering.
          kill_stale_simulator_apps(tunneled, leases)

          # Restart apps so they pick up tunnels and use correct node names
          Enum.each(tunneled, &restart_app(&1, launch_cookie))
          tunneled
        else
          Enum.map(tunneled, &attach_target/1)
        end

      # Start distribution on the Mac side
      ensure_local_dist(local_name, launch_cookie)

      # Activate accessibility on iOS simulators so ui_tree() returns elements.
      # SwiftUI lazily populates its a11y tree; this one-time activation persists
      # for the simulator session (survives app restarts). MOB-99: give it a
      # beat to propagate before any caller can start driving taps — the app
      # itself is still booting (wait_for_nodes below) and SwiftUI needs a
      # moment after the notifyutil broadcast to actually rebuild its tree.
      #
      # Simulator only, not just iOS: IOS.enable_accessibility/1 shells out to
      # `xcrun simctl spawn <udid> ...`, which is simulator-only tooling — a
      # no-op (or error) against a physical device's UDID. Same predicate
      # kill_stale_simulator_apps/1 above already uses for the same reason.
      ios_sim_targets = Enum.filter(tunneled, &(&1.platform == :ios && &1.type == :simulator))
      Enum.each(ios_sim_targets, fn d -> IOS.enable_accessibility(d.serial) end)
      if ios_sim_targets != [], do: Process.sleep(@ios_accessibility_settle_ms)

      # Wait for nodes to come online. A running app is either registered or
      # not, so attaching doesn't wait out a boot.
      IO.puts("\n  Waiting for nodes...")
      timeout = if restart, do: @connect_timeout, else: @attach_timeout
      {connected, failed_wait} = wait_for_nodes(tunneled, cookies, timeout)

      # Report failures
      all_failed = failed_tunnel ++ failed_wait

      Enum.each(all_failed, fn d ->
        IO.puts("  #{color(:red)}✗ #{d.name || d.serial}: #{d.error}#{color(:reset)}")
        print_fix_hint(d)
      end)

      if not restart and all_failed != [] do
        IO.puts(
          "    → attaching needs the app to have registered in EPMD through these tunnels; " <>
            "run without --no-restart to restart it"
        )
      end

      if connected != [] do
        IO.puts(
          "\n#{color(:green)}Connected cluster (#{length(connected)} node(s)):#{color(:reset)}"
        )

        Enum.each(connected, fn d ->
          IO.puts("  #{color(:green)}✓#{color(:reset)} #{d.node}  [port #{d.dist_port}]")
        end)
      end

      {connected, all_failed}
    end
  end

  # Only scan the platforms the project targets. An iOS-only Mac (no Android
  # platform-tools) skips Android discovery entirely — both so it never shells
  # out to a missing `adb`, and so a plugged-in Android phone for some *other*
  # project isn't swept into this session.
  defp discover_all(platforms, only) do
    android = if :android in platforms, do: Android.list_devices(), else: []

    ios =
      if :ios in platforms and ios_scan_needed?(android, only),
        do: IOS.list_devices(),
        else: []

    android ++ ios
  end

  @doc false
  # Whether `--device`/`--only` can still match something only an iOS scan
  # would find. The scan probes EPMD across the LAN for physical iPhones and
  # took ~17 s of a ~33 s `mix mob.connect --device emulator-5556`; when every
  # pattern already names an Android device there is nothing left for it to find.
  @spec ios_scan_needed?([Device.t()], [String.t()]) :: boolean()
  def ios_scan_needed?(_android, []), do: true

  def ios_scan_needed?(android, patterns),
    do: Enum.any?(patterns, &(filter_only(android, [&1]) == []))

  # Restrict the discovered set to devices whose serial/udid contains any of the
  # given substrings (case-insensitive). Empty list = no filter (connect to all).
  @doc false
  @spec filter_only([Device.t()], [String.t()]) :: [Device.t()]
  def filter_only(devices, []), do: devices

  def filter_only(devices, patterns) do
    pats = Enum.map(patterns, &String.downcase/1)

    Enum.filter(devices, fn d ->
      serial = String.downcase(to_string(d.serial))
      Enum.any?(pats, &String.contains?(serial, &1))
    end)
  end

  defp setup_tunnels(devices) do
    # Ports are derived from each device's serial and the app (Tunnel.dist_port_for/1),
    # not a per-run index — so they're stable and don't collide across projects.
    # Sequential so each device's freshly-added forward is visible as "in use"
    # to the next device's collision check.
    devices
    |> Enum.reduce({[], []}, fn device, {ok, fail} ->
      IO.write("  #{device.name || device.serial}  →  tunneling...")

      case Tunnel.setup(device) do
        {:ok, d} ->
          IO.puts("  #{color(:green)}✓#{color(:reset)}")
          {ok ++ [d], fail}

        {:error, reason} ->
          IO.puts("  #{color(:red)}✗#{color(:reset)}")
          {ok, fail ++ [%{device | status: :error, error: reason}]}
      end
    end)
  end

  # Kill any app processes running in simulators that are NOT in our current
  # tunneled set. A stale BEAM from a previous session holds its EPMD slot,
  # blocking new instances of the same node name from registering.
  defp kill_stale_simulator_apps(tunneled, leases) do
    active =
      tunneled
      |> Enum.filter(&(&1.platform == :ios && &1.type == :simulator))
      |> Enum.map(& &1.serial)

    case System.cmd("pgrep", ["-fl", ios_bundle_id()], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> stale_simulator_pids(active, leases)
        |> Enum.each(&System.cmd("kill", ["-9", to_string(&1)], stderr_to_stdout: true))

      _ ->
        :ok
    end

    :timer.sleep(300)
  end

  @doc false
  # The pids in `pgrep -fl <bundle id>` output that run the app on a
  # simulator outside `active` (UDIDs). A simulator another agent-device
  # session has claimed is never one of them: it is outside `active` because
  # selection left it alone, and the app on it is that agent's (MOB-330).
  @spec stale_simulator_pids(String.t(), [String.t()], DeviceLeases.t()) :: [pos_integer()]
  def stale_simulator_pids(pgrep_output, active, leases) do
    active = MapSet.new(active, &String.upcase/1)

    pgrep_output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      with [pid_str | _] <- String.split(line, " ", parts: 2),
           {pid, ""} <- Integer.parse(pid_str),
           [_, udid] <- Regex.run(~r|/Devices/([0-9A-F-]{36})/|i, line),
           false <- MapSet.member?(active, String.upcase(udid)),
           nil <- DeviceLeases.foreign_claim(simulator(udid), leases) do
        [pid]
      else
        _ -> []
      end
    end)
  end

  defp simulator(udid), do: %Device{platform: :ios, type: :simulator, serial: udid}

  # Attach mode: point the device at the node its running app registered —
  # the deploy-time name, or the bare `<app>_android` of a launcher start
  # (no intent extras, so no suffix and port 9100).
  defp attach_target(%Device{platform: :android, serial: serial, node: node} = device) do
    expected = node |> Atom.to_string() |> String.split("@") |> hd()
    candidates = Enum.uniq([expected, "#{Mix.Project.config()[:app]}_android"])

    with {name, port} <- Android.pick_registered_node(Tunnel.epmd_names(), candidates),
         :ok <- Tunnel.attach_forward(serial, port) do
      %{device | node: :"#{name}@127.0.0.1", dist_port: port}
    else
      nil ->
        device

      {:error, reason} ->
        IO.puts("  #{color(:yellow)}#{serial}: #{reason}#{color(:reset)}")
        device
    end
  end

  defp attach_target(device), do: device

  defp restart_app(
         %Device{
           platform: :android,
           serial: serial,
           dist_port: port,
           node_suffix: suffix
         },
         cookie
       ) do
    IO.write("  Restarting app on #{serial}...")

    # Before the start: Mob.Dist reads the cookie once, when the app boots.
    case Android.write_dist_cookie(serial, android_package(), Mix.Project.config()[:app], cookie) do
      :ok ->
        :ok

      {:error, reason} ->
        IO.write(" #{color(:yellow)}(could not write the dist cookie: #{reason})#{color(:reset)}")
    end

    # node_suffix may be nil — Android.restart_app falls back to
    # device_node_suffix(serial) in that case (auto-derive from serial).
    Android.restart_app(serial, android_package(), @android_activity,
      dist_port: port,
      node_suffix: suffix
    )

    IO.puts(" done")
  end

  defp restart_app(%Device{platform: :ios, type: :physical, serial: udid}, cookie) do
    IO.write("  Restarting app on #{udid}...")
    # mob_beam.m picks its node IP via getifaddrs() (WiFi first). devicectl
    # passes the cookie in the child environment, never on a command line.
    IOS.restart_app_physical(udid, ios_bundle_id(), dist_cookie: Atom.to_string(cookie))
    IO.puts(" done")
  end

  defp restart_app(
         %Device{platform: :ios, serial: udid, dist_port: port, node_suffix: suffix},
         cookie
       ) do
    IO.write("  Restarting app on #{udid}...")
    IOS.terminate_app(udid, ios_bundle_id())
    :timer.sleep(500)
    # node_suffix nil → IOS.launch_app omits SIMCTL_CHILD_MOB_NODE_SUFFIX
    # → mob_beam.m auto-derives from SIMULATOR_UDID.
    IOS.launch_app(udid, ios_bundle_id(),
      dist_port: port,
      node_suffix: suffix,
      dist_cookie: Atom.to_string(cookie)
    )

    IO.puts(" done")
  end

  @doc """
  Reads the `:name` option from `connect_all/1`'s keyword list and returns
  it as an atom, or nil when unset: the host node is then
  `mob_dev@127.0.0.1`, or a per-process name when that one is taken (see
  `MobDev.NodeUtil.start_host_dist/3`).

  Public so the option-plumbing is unit-testable without needing to actually
  call `Node.start/2` (which would mutate BEAM-global distribution state
  and require an `async: false` test module). See MOB-69.
  """
  @spec local_name_from_opts(keyword()) :: node() | nil
  def local_name_from_opts(opts) when is_list(opts) do
    case Keyword.get(opts, :name) do
      nil -> nil
      name when is_atom(name) -> name
      name when is_binary(name) -> String.to_atom(name)
    end
  end

  defp ensure_local_dist(local_name, cookie) do
    # On Nix and some Linux setups, EPMD is not started automatically.
    # Try to start it before Node.start so distribution can register.
    unless Node.alive?(), do: start_epmd()

    case MobDev.NodeUtil.start_host_dist(local_name, cookie) do
      {:ok, node} ->
        if local_name == nil and node != :"mob_dev@127.0.0.1",
          do: IO.puts("  Local node: #{node} (mob_dev@127.0.0.1 is held by another process)")

      {:error, reason} ->
        handle_dist_start({:error, reason}, cookie)
    end
  end

  # Attempt to start EPMD in daemon mode. Safe to call when already running —
  # epmd -daemon exits 0 immediately in that case.
  # Public for testing.
  @doc false
  @spec start_epmd() :: {String.t(), non_neg_integer()} | :ok
  def start_epmd do
    System.cmd("epmd", ["-daemon"], stderr_to_stdout: true)
  rescue
    # epmd not in PATH — Node.start will surface a clear error
    _ -> :ok
  end

  # Handle the return value of Node.start/2.
  # Public for testing.
  @doc false
  @spec handle_dist_start({:ok, term()} | {:error, term()}, atom()) :: :ok
  def handle_dist_start({:ok, _}, cookie),
    do: Node.set_cookie(cookie)

  def handle_dist_start({:error, {:already_started, _}}, cookie),
    do: Node.set_cookie(cookie)

  def handle_dist_start({:error, reason}, _cookie) do
    Mix.raise("""
    Failed to start Erlang distribution: #{inspect(reason)}

    EPMD (Erlang Port Mapper Daemon) may not be running or reachable.
    Try starting it manually:

        epmd -daemon

    Then retry: mix mob.connect
    Run `mix mob.doctor` for a full environment diagnosis.
    """)
  end

  defp wait_for_nodes(devices, cookies, timeout) do
    # Start all connection attempts in parallel so slow starters (simulators
    # that need ~20s to boot their BEAM) don't consume the other devices' budget.
    # Total wall time = max(individual connect times), not sum.
    tasks =
      Enum.map(devices, fn device ->
        candidates = fn -> node_candidates(device) end

        {device, Task.async(fn -> wait_for_any_node(candidates, cookies, timeout) end)}
      end)

    Enum.reduce(tasks, {[], []}, fn {device, task}, {ok, fail} ->
      IO.write("  #{device.node} ...")

      case Task.await(task, timeout + 2_000) do
        {:ok, connected_node} ->
          if connected_node == device.node do
            IO.puts("  #{color(:green)}✓#{color(:reset)}")
            {ok ++ [%{device | status: :connected}], fail}
          else
            # Fallback name responded — surface it so the user knows what to
            # use with `mix mob.connect --no-iex` and friends.
            IO.puts("  #{color(:green)}✓#{color(:reset)} (registered as #{connected_node})")
            {ok ++ [%{device | status: :connected, node: connected_node}], fail}
          end

        {:error, reason} ->
          IO.puts("  #{color(:red)}✗#{color(:reset)}")
          diagnosis = connect_diagnosis(device)
          error = if diagnosis, do: "#{reason} — #{diagnosis}", else: reason
          {ok, fail ++ [%{device | status: :error, error: error}]}
      end
    end)
  end

  # iOS sim — issues.md #14: mob_beam.m derives the node name from
  # SIMULATOR_UDID at startup, but in some launch contexts that env var isn't
  # set and the BEAM falls back to the suffix-less form. Probe both names so
  # `mix mob.connect` works regardless of which was actually registered.
  # Other platforms (physical iOS over LAN, Android over adb tunnel) always
  # use a single deterministic name; the candidate list is just `[device.node]`.
  defp node_candidates(%Device{platform: :ios, type: :simulator, node: node} = device) do
    fallback = ios_sim_fallback_node(device)

    if fallback && fallback != node do
      [node, fallback]
    else
      [node]
    end
  end

  # Android: the deploy-time name, plus whatever registered on this device's
  # dist port. An app whose Mob.Dist base name isn't `<app>_android` (e.g.
  # `crosscourt@127.0.0.1` → `crosscourt_<serial>`) registers a name mob_dev
  # can't predict, but the port is the one mob_dev launched it with and is
  # unique per device and app, so the EPMD entry on it is this app's node.
  defp node_candidates(%Device{platform: :android, node: node, dist_port: port})
       when is_integer(port) do
    case Android.registered_at_port(Tunnel.epmd_names(), port) do
      {name, ^port} -> Enum.uniq([node, :"#{name}@127.0.0.1"])
      nil -> [node]
    end
  end

  defp node_candidates(%Device{node: node}), do: [node]

  # Turn a black-box "timed out" into an actionable reason by inspecting the
  # actual EPMD / forward / app state. Android only (the path users hit); other
  # platforms fall through to nil and keep the bare reason.
  @spec connect_diagnosis(Device.t()) :: String.t() | nil
  defp connect_diagnosis(%Device{platform: :android, serial: serial, node: node, dist_port: port}) do
    name = node |> Atom.to_string() |> String.split("@") |> hd()
    registered_port = epmd_port_for(name)

    cond do
      not android_app_running?(serial) ->
        "app not running on #{serial} (crashed, or Android App Standby killed its " <>
          "network while backgrounded) — foreground it and retry"

      registered_port == nil ->
        "node #{name} never registered in EPMD — distribution didn't start on the " <>
          "device. Check `adb -s #{serial} logcat` for the dist boot step"

      registered_port != port ->
        "node #{name} registered at port #{registered_port} but mob.connect uses " <>
          "#{port} — re-run mob.connect to realign the forward"

      not android_forwarded?(serial, port) ->
        "no adb forward localhost:#{port} → #{serial}:#{port} — re-run mob.connect"

      true ->
        "registered + forwarded but Node.connect failed — likely a cookie mismatch " <>
          "(an app with a custom cookie needs `--cookie`; one started before mob_dev " <>
          "wrote its private cookie needs a restart)"
    end
  end

  defp connect_diagnosis(_device), do: nil

  defp epmd_port_for(name) do
    case System.cmd("epmd", ["-names"], stderr_to_stdout: true) do
      {out, 0} ->
        case Regex.run(~r/name #{Regex.escape(name)} at port (\d+)/, out) do
          [_, p] -> String.to_integer(p)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp android_forwarded?(serial, port) do
    case System.cmd("adb", ["forward", "--list"], stderr_to_stdout: true) do
      {out, 0} -> String.contains?(out, "#{serial} tcp:#{port} ")
      _ -> false
    end
  end

  defp android_app_running?(serial) do
    case System.cmd("adb", ["-s", serial, "shell", "pidof", android_package()],
           stderr_to_stdout: true
         ) do
      {out, 0} -> String.trim(out) != ""
      _ -> false
    end
  end

  defp ios_sim_fallback_node(%Device{node: node}) do
    case Atom.to_string(node) |> String.split("@", parts: 2) do
      [name, host] ->
        # Strip the `_<8-char>` suffix that Device.node_name appends for
        # simulators — yields the suffix-less `<app>_ios@<host>` form.
        case Regex.run(~r/^(.+_ios)_[0-9a-f]{1,8}$/, name) do
          [_, base] -> :"#{base}@#{host}"
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp wait_for_any_node(candidates, cookies, timeout) do
    wait_for_any_node(candidates, cookies, timeout, candidates.())
  end

  defp wait_for_any_node(_candidates, _cookies, timeout, tried) when timeout <= 0 do
    {:error, "timed out waiting for any of #{inspect(tried)}"}
  end

  defp wait_for_any_node(candidates, cookies, timeout, _tried) do
    current = candidates.()

    case try_connect_each(current, cookies) do
      {:ok, _} = ok ->
        ok

      :none ->
        :timer.sleep(@connect_interval)
        wait_for_any_node(candidates, cookies, timeout - @connect_interval, current)

      {:error, _} = err ->
        err
    end
  end

  defp try_connect_each(candidates, cookies) do
    if Node.alive?() do
      Enum.find_value(candidates, :none, fn node ->
        if match?({:ok, _}, DistCookie.connect(node, cookies)), do: {:ok, node}
      end)
    else
      {:error, "local node not alive (distribution not started)"}
    end
  end

  defp print_discovered(devices) do
    android = Enum.filter(devices, &(&1.platform == :android))
    ios = Enum.filter(devices, &(&1.platform == :ios))

    if android != [] do
      IO.puts("  #{color(:blue)}Android#{color(:reset)}")

      Enum.each(android, fn d ->
        status =
          if d.status == :unauthorized,
            do: "#{color(:red)}unauthorized#{color(:reset)}",
            else: "found"

        IO.puts("  ├── #{d.name || d.serial}  #{d.serial}  #{status}")
        if d.status == :unauthorized, do: IO.puts("  │   #{d.error}")
      end)
    end

    if ios != [] do
      IO.puts("  #{color(:blue)}iOS#{color(:reset)}")

      Enum.each(ios, fn d ->
        IO.puts("  ├── #{d.name || d.serial}  #{d.serial}  found")
      end)
    end

    IO.puts("")
  end

  defp print_fix_hint(%Device{status: :unauthorized}) do
    IO.puts("    → Check your device for a 'Allow USB debugging?' prompt")
    IO.puts("    → If no prompt: Settings → Developer Options → Revoke USB debugging")
  end

  defp print_fix_hint(%Device{platform: :android, error: error})
       when is_binary(error) do
    if String.contains?(error, "timed out") do
      IO.puts("    → Is the app installed? Run: mix mob.deploy")
      IO.puts("    → Android distribution starts 3s after app launch")
    end
  end

  defp print_fix_hint(_), do: :ok

  defp color(:red), do: IO.ANSI.red()
  defp color(:green), do: IO.ANSI.green()
  defp color(:yellow), do: IO.ANSI.yellow()
  defp color(:blue), do: IO.ANSI.cyan()
  defp color(:cyan), do: IO.ANSI.cyan()
  defp color(:reset), do: IO.ANSI.reset()
end
