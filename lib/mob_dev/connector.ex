defmodule MobDev.Connector do
  @moduledoc """
  Orchestrates device discovery, tunnel setup, app restart, and node connection.
  """

  alias MobDev.{Device, Tunnel}
  alias MobDev.Discovery.{Android, IOS}

  @android_activity ".MainActivity"

  defp bundle_id, do: MobDev.Config.bundle_id()
  defp android_package, do: bundle_id()
  defp ios_bundle_id, do: bundle_id()
  # ms to wait for node to appear
  @connect_timeout 25_000
  # ms between polls
  @connect_interval 500

  @doc """
  Discovers all connected devices, sets up tunnels, restarts apps, and waits
  for Erlang nodes to come online.

  Returns {connected, failed} lists of %Device{}.
  """
  @spec connect_all(keyword()) :: {[Device.t()], [Device.t()]}
  def connect_all(opts \\ []) do
    cookie = Keyword.get(opts, :cookie, :mob_secret)

    only = opts |> Keyword.get(:only, []) |> List.wrap()
    platforms = opts |> Keyword.get(:platforms, [:android, :ios]) |> List.wrap()

    IO.puts("\n#{color(:cyan)}Scanning for devices...#{color(:reset)}\n")

    devices = platforms |> discover_all() |> filter_only(only)

    if devices == [] do
      if only != [] do
        IO.puts("  #{color(:yellow)}No devices matched #{Enum.join(only, ", ")}.#{color(:reset)}")

        IO.puts("  • Run `mix mob.connect` with no --only to list all discovered devices")
      else
        IO.puts("  #{color(:yellow)}No devices found.#{color(:reset)}")
        IO.puts("  • Connect an Android device via USB and enable USB debugging")
        IO.puts("  • Start an iOS simulator in Xcode or via xcrun simctl")
      end

      {[], []}
    else
      print_discovered(devices)

      # Set up tunnels (assigns dist_port per device)
      {tunneled, failed_tunnel} = setup_tunnels(devices)

      # Kill any stale simulator processes from previous sessions. A lingering
      # BEAM holds its EPMD slot, blocking new instances from registering.
      kill_stale_simulator_apps(tunneled)

      # Restart apps so they pick up tunnels and use correct node names
      Enum.each(tunneled, &restart_app/1)

      # Start distribution on the Mac side
      ensure_local_dist(cookie)

      # Activate accessibility on iOS simulators so ui_tree() returns elements.
      # SwiftUI lazily populates its a11y tree; this one-time activation persists
      # for the simulator session (survives app restarts).
      tunneled
      |> Enum.filter(&(&1.platform == :ios))
      |> Enum.each(fn d -> IOS.enable_accessibility(d.serial) end)

      # Wait for nodes to come online
      IO.puts("\n  Waiting for nodes...")
      {connected, failed_wait} = wait_for_nodes(tunneled, cookie)

      # Report failures
      all_failed = failed_tunnel ++ failed_wait

      Enum.each(all_failed, fn d ->
        IO.puts("  #{color(:red)}✗ #{d.name || d.serial}: #{d.error}#{color(:reset)}")
        print_fix_hint(d)
      end)

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
  defp discover_all(platforms) do
    android = if :android in platforms, do: Android.list_devices(), else: []
    ios = if :ios in platforms, do: IOS.list_devices(), else: []
    android ++ ios
  end

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
    # Ports are derived from each device's serial (Tunnel.assign_dist_port/2),
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
  defp kill_stale_simulator_apps(tunneled) do
    active =
      tunneled
      |> Enum.filter(&(&1.platform == :ios && &1.type == :simulator))
      |> Enum.map(& &1.serial)
      |> MapSet.new()

    case System.cmd("pgrep", ["-fl", bundle_id()], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.each(fn line ->
          with [pid_str | _] <- String.split(line, " ", parts: 2),
               {pid, ""} <- Integer.parse(pid_str),
               [_, udid] <- Regex.run(~r|/Devices/([0-9A-F-]{36})/|i, line),
               false <- MapSet.member?(active, udid) do
            System.cmd("kill", ["-9", to_string(pid)], stderr_to_stdout: true)
          end
        end)

      _ ->
        :ok
    end

    :timer.sleep(300)
  end

  defp restart_app(%Device{
         platform: :android,
         serial: serial,
         dist_port: port,
         node_suffix: suffix
       }) do
    IO.write("  Restarting app on #{serial}...")
    # node_suffix may be nil — Android.restart_app falls back to
    # device_node_suffix(serial) in that case (auto-derive from serial).
    Android.restart_app(serial, android_package(), @android_activity,
      dist_port: port,
      node_suffix: suffix
    )

    IO.puts(" done")
  end

  defp restart_app(%Device{platform: :ios, type: :physical, serial: udid}) do
    IO.write("  Restarting app on #{udid}...")
    # mob_beam.m discovers the USB link-local IP via getifaddrs() — no env vars needed.
    IOS.restart_app_physical(udid, ios_bundle_id())
    IO.puts(" done")
  end

  defp restart_app(%Device{platform: :ios, serial: udid, dist_port: port, node_suffix: suffix}) do
    IO.write("  Restarting app on #{udid}...")
    IOS.terminate_app(udid, ios_bundle_id())
    :timer.sleep(500)
    # node_suffix nil → IOS.launch_app omits SIMCTL_CHILD_MOB_NODE_SUFFIX
    # → mob_beam.m auto-derives from SIMULATOR_UDID.
    IOS.launch_app(udid, ios_bundle_id(), dist_port: port, node_suffix: suffix)
    IO.puts(" done")
  end

  defp ensure_local_dist(cookie) do
    unless Node.alive?() do
      # On Nix and some Linux setups, EPMD is not started automatically.
      # Try to start it before Node.start so distribution can register.
      start_epmd()
      handle_dist_start(Node.start(:"mob_dev@127.0.0.1", :longnames), cookie)
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

  defp wait_for_nodes(devices, cookie) do
    # Start all connection attempts in parallel so slow starters (simulators
    # that need ~20s to boot their BEAM) don't consume the other devices' budget.
    # Total wall time = max(individual connect times), not sum.
    tasks =
      Enum.map(devices, fn device ->
        candidates = node_candidates(device)

        {device, Task.async(fn -> wait_for_any_node(candidates, cookie, @connect_timeout) end)}
      end)

    Enum.reduce(tasks, {[], []}, fn {device, task}, {ok, fail} ->
      IO.write("  #{device.node} ...")

      case Task.await(task, @connect_timeout + 2_000) do
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
          "(both sides must use :mob_secret)"
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

  defp wait_for_any_node(candidates, _cookie, timeout) when timeout <= 0 do
    {:error, "timed out waiting for any of #{inspect(candidates)}"}
  end

  defp wait_for_any_node(candidates, cookie, timeout) do
    case try_connect_each(candidates, cookie) do
      {:ok, _} = ok ->
        ok

      :none ->
        :timer.sleep(@connect_interval)
        wait_for_any_node(candidates, cookie, timeout - @connect_interval)

      {:error, _} = err ->
        err
    end
  end

  defp try_connect_each([], _cookie), do: :none

  defp try_connect_each([node | rest], cookie) do
    Node.set_cookie(node, cookie)

    case Node.connect(node) do
      true -> {:ok, node}
      false -> try_connect_each(rest, cookie)
      :ignored -> {:error, "local node not alive (distribution not started)"}
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
