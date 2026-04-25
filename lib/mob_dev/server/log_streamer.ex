defmodule MobDev.Server.LogStreamer do
  @moduledoc """
  Streams logcat from connected Android devices and iOS simulator console,
  broadcasting parsed lines via PubSub.

  One Port per device. Automatically starts/stops ports as devices
  connect and disconnect (driven by :devices_updated PubSub events).
  """
  use GenServer

  @topic "logs"

  # serial => port
  defstruct ports: %{}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # ── GenServer ────────────────────────────────────────────────────────────────

  @impl GenServer
  @spec init(term()) :: {:ok, %__MODULE__{}}
  def init(_opts) do
    Phoenix.PubSub.subscribe(MobDev.PubSub, "devices")
    devices = MobDev.Server.DevicePoller.get_devices()
    # If there are already-connected devices, this is a streamer restart — mark it.
    Enum.each(devices, fn d -> broadcast_restart(d.serial) end)
    ports = Enum.reduce(devices, %{}, &open_port_for/2)
    {:ok, %__MODULE__{ports: ports}}
  end

  @impl GenServer
  @spec handle_info(term(), %__MODULE__{}) :: {:noreply, %__MODULE__{}}
  def handle_info({:devices_updated, devices}, state) do
    current_serials = MapSet.new(Map.keys(state.ports))
    new_serials = MapSet.new(Enum.map(devices, & &1.serial))

    # Stop ports for disconnected devices
    removed = MapSet.difference(current_serials, new_serials)

    ports =
      Enum.reduce(removed, state.ports, fn serial, acc ->
        if port = acc[serial] do
          Port.close(port)
        end

        Map.delete(acc, serial)
      end)

    # Open ports for newly connected devices
    added = MapSet.difference(new_serials, current_serials)
    new_devices = Enum.filter(devices, &MapSet.member?(added, &1.serial))
    ports = Enum.reduce(new_devices, ports, &open_port_for/2)

    {:noreply, %{state | ports: ports}}
  end

  # Data from a logcat/simctl port.
  # With {:line, N} port option, data arrives as {:eol, line} or {:noeol, partial}.
  def handle_info({port, {:data, {:eol, line}}}, state) do
    broadcast_line(port, line, state)
    {:noreply, state}
  end

  def handle_info({port, {:data, {:noeol, _partial}}}, state) do
    # Partial line (buffer full) — drop it, logcat lines are never this long
    _ = port
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, _}}, state) do
    serial = Enum.find_value(state.ports, fn {s, p} -> if p == port, do: s end)
    ports = if serial, do: Map.delete(state.ports, serial), else: state.ports
    # Schedule a reopen attempt — logcat exits when the app is force-stopped,
    # but the device is usually still connected and will restart shortly.
    if serial, do: Process.send_after(self(), {:reopen, serial}, 2_000)
    {:noreply, %{state | ports: ports}}
  end

  def handle_info({:reopen, serial}, state) do
    # Only reopen if device is still connected and we don't already have a port.
    if Map.has_key?(state.ports, serial) do
      {:noreply, state}
    else
      devices = MobDev.Server.DevicePoller.get_devices()

      case Enum.find(devices, &(&1.serial == serial)) do
        nil ->
          {:noreply, state}

        device ->
          broadcast_restart(serial)
          ports = open_port_for(device, state.ports)
          {:noreply, %{state | ports: ports}}
      end
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  defp broadcast_line(port, line, state) do
    serial = Enum.find_value(state.ports, fn {s, p} -> if p == port, do: s end)

    if serial do
      parsed = parse_line(line, serial)
      MobDev.Server.LogBuffer.push(parsed)
      Phoenix.PubSub.broadcast(MobDev.PubSub, @topic, {:log_line, serial, parsed})
    end
  end

  defp broadcast_restart(serial) do
    line = %{
      id: unique_id(),
      serial: serial,
      level: "I",
      tag: nil,
      message: "── Restart ──",
      raw: "",
      mob: true,
      restart: true,
      ts: time_string()
    }

    MobDev.Server.LogBuffer.push(line)
    Phoenix.PubSub.broadcast(MobDev.PubSub, @topic, {:log_line, serial, line})
  end

  # ── Port management ──────────────────────────────────────────────────────────

  defp open_port_for(%{platform: :android, serial: serial}, ports) do
    args = ["-s", serial, "logcat", "-v", "brief", "-T", "1"]
    port = open_port("adb", args)
    Map.put(ports, serial, port)
  end

  defp open_port_for(%{platform: :ios, serial: udid}, ports) do
    # Stream iOS simulator log, filter to mob-relevant output.
    # Process name is the binary name ("MobDemo"), not the bundle ID.
    args = [
      "simctl",
      "spawn",
      udid,
      "log",
      "stream",
      "--predicate",
      "process == 'MobDemo'",
      "--style",
      "syslog"
    ]

    port = open_port("xcrun", args)
    Map.put(ports, udid, port)
  end

  defp open_port_for(_, ports), do: ports

  defp open_port(cmd, args) do
    executable = System.find_executable(cmd) || cmd

    Port.open(
      {:spawn_executable, executable},
      [:binary, :exit_status, {:args, args}, {:line, 4096}]
    )
  end

  # ── Log line parsing ─────────────────────────────────────────────────────────

  @doc """
  Parses a logcat brief-format line into a map.

  Brief format: `I/TagName(PID): message`
  """
  @spec parse_line(String.t(), String.t()) :: map()
  def parse_line(raw, serial) do
    # Android logcat brief: "I/MobBeam( 1234): message text"
    case Regex.run(~r/^([EWIDVF])\/([^\(]+)\(\s*\d+\):\s*(.*)$/, String.trim(raw)) do
      [_, level, tag, message] ->
        %{
          id: unique_id(),
          serial: serial,
          level: level,
          tag: String.trim(tag),
          message: message,
          raw: raw,
          mob: mob_tag?(tag),
          ts: time_string()
        }

      nil ->
        # iOS syslog or unparsed line
        %{
          id: unique_id(),
          serial: serial,
          level: "I",
          tag: nil,
          message: String.trim(raw),
          raw: raw,
          mob: mob_line?(raw),
          ts: time_string()
        }
    end
  end

  defp mob_tag?(tag) do
    tag = String.trim(tag)

    tag in ["MobBeam", "MobNif", "MobDist", "MobBridge", "Elixir"] or
      String.starts_with?(tag, "Mob")
  end

  defp mob_line?(line) do
    app = Mix.Project.config()[:app] |> to_string()
    app_camel = app |> Macro.camelize()

    String.contains?(line, "MobBeam") or
      String.contains?(line, "MobNIF") or
      String.contains?(line, "MobBridge") or
      String.contains?(line, app) or
      String.contains?(line, app_camel)
  end

  defp unique_id, do: :erlang.unique_integer([:monotonic, :positive])

  defp time_string do
    {{_y, _mo, _d}, {h, m, s}} = :calendar.local_time()
    :io_lib.format("~2..0B:~2..0B:~2..0B", [h, m, s]) |> IO.iodata_to_binary()
  end
end
