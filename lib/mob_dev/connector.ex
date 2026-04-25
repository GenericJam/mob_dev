defmodule MobDev.Connector do
  @moduledoc """
  Orchestrates device discovery, tunnel setup, app restart, and node connection.
  """

  alias MobDev.{Device, Tunnel}
  alias MobDev.Discovery.{Android, IOS}

  @android_activity ".MainActivity"

  defp bundle_id,       do: MobDev.Config.bundle_id()
  defp android_package, do: bundle_id()
  defp ios_bundle_id,   do: bundle_id()
  @connect_timeout  25_000   # ms to wait for node to appear
  @connect_interval 500      # ms between polls

  @doc """
  Discovers all connected devices, sets up tunnels, restarts apps, and waits
  for Erlang nodes to come online.

  Returns {connected, failed} lists of %Device{}.
  """
  @spec connect_all(keyword()) :: {[Device.t()], [Device.t()]}
  def connect_all(opts \\ []) do
    cookie = Keyword.get(opts, :cookie, :mob_secret)

    IO.puts("\n#{color(:cyan)}Scanning for devices...#{color(:reset)}\n")

    devices = discover_all()

    if devices == [] do
      IO.puts("  #{color(:yellow)}No devices found.#{color(:reset)}")
      IO.puts("  • Connect an Android device via USB and enable USB debugging")
      IO.puts("  • Start an iOS simulator in Xcode or via xcrun simctl")
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
        IO.puts("\n#{color(:green)}Connected cluster (#{length(connected)} node(s)):#{color(:reset)}")
        Enum.each(connected, fn d ->
          IO.puts("  #{color(:green)}✓#{color(:reset)} #{d.node}  [port #{d.dist_port}]")
        end)
      end

      {connected, all_failed}
    end
  end

  defp discover_all do
    android = Android.list_devices()
    ios     = IOS.list_devices()
    android ++ ios
  end

  defp setup_tunnels(devices) do
    # Track index per platform to assign unique ports
    devices
    |> Enum.with_index()
    |> Enum.reduce({[], []}, fn {device, idx}, {ok, fail} ->
      IO.write("  #{device.name || device.serial}  →  tunneling...")
      case Tunnel.setup(device, idx) do
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
    active = tunneled
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
      _ -> :ok
    end
    :timer.sleep(300)
  end

  defp restart_app(%Device{platform: :android, serial: serial, dist_port: port}) do
    IO.write("  Restarting app on #{serial}...")
    Android.restart_app(serial, android_package(), @android_activity, dist_port: port)
    IO.puts(" done")
  end

  defp restart_app(%Device{platform: :ios, type: :physical, serial: udid}) do
    IO.write("  Restarting app on #{udid}...")
    # mob_beam.m discovers the USB link-local IP via getifaddrs() — no env vars needed.
    IOS.restart_app_physical(udid, ios_bundle_id())
    IO.puts(" done")
  end

  defp restart_app(%Device{platform: :ios, serial: udid, dist_port: port}) do
    IO.write("  Restarting app on #{udid}...")
    IOS.terminate_app(udid, ios_bundle_id())
    :timer.sleep(500)
    IOS.launch_app(udid, ios_bundle_id(), dist_port: port)
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
  def start_epmd do
    System.cmd("epmd", ["-daemon"], stderr_to_stdout: true)
  rescue
    _ -> :ok  # epmd not in PATH — Node.start will surface a clear error
  end

  # Handle the return value of Node.start/2.
  # Public for testing.
  @doc false
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
    tasks = Enum.map(devices, fn device ->
      {device, Task.async(fn -> wait_for_node(device.node, cookie, @connect_timeout) end)}
    end)

    Enum.reduce(tasks, {[], []}, fn {device, task}, {ok, fail} ->
      IO.write("  #{device.node} ...")
      case Task.await(task, @connect_timeout + 2_000) do
        :ok ->
          IO.puts("  #{color(:green)}✓#{color(:reset)}")
          {ok ++ [%{device | status: :connected}], fail}
        {:error, reason} ->
          IO.puts("  #{color(:red)}✗#{color(:reset)}")
          {ok, fail ++ [%{device | status: :error, error: reason}]}
      end
    end)
  end

  defp wait_for_node(node, _cookie, timeout) when timeout <= 0 do
    {:error, "timed out waiting for #{node}"}
  end

  defp wait_for_node(node, cookie, timeout) do
    Node.set_cookie(node, cookie)
    case Node.connect(node) do
      true  -> :ok
      false ->
        :timer.sleep(@connect_interval)
        wait_for_node(node, cookie, timeout - @connect_interval)
      :ignored ->
        {:error, "local node not alive (distribution not started)"}
    end
  end

  defp print_discovered(devices) do
    android = Enum.filter(devices, &(&1.platform == :android))
    ios     = Enum.filter(devices, &(&1.platform == :ios))

    if android != [] do
      IO.puts("  #{color(:blue)}Android#{color(:reset)}")
      Enum.each(android, fn d ->
        status = if d.status == :unauthorized,
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

  defp color(:red),    do: IO.ANSI.red()
  defp color(:green),  do: IO.ANSI.green()
  defp color(:yellow), do: IO.ANSI.yellow()
  defp color(:blue),   do: IO.ANSI.cyan()
  defp color(:cyan),   do: IO.ANSI.cyan()
  defp color(:reset),  do: IO.ANSI.reset()
end
