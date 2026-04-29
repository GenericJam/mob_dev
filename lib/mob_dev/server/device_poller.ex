defmodule MobDev.Server.DevicePoller do
  @moduledoc """
  Polls adb and simctl every 2 seconds, broadcasting device state changes via PubSub.
  """
  use GenServer

  alias MobDev.Discovery.{Android, IOS}

  @poll_ms 2_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the current device list synchronously."
  @spec get_devices() :: [map()]
  def get_devices do
    GenServer.call(__MODULE__, :get_devices)
  end

  # ── GenServer ────────────────────────────────────────────────────────────────

  @impl GenServer
  @spec init(term()) :: {:ok, map()}
  def init(_opts) do
    schedule_poll()
    devices = poll_devices()
    {:ok, %{devices: devices}}
  end

  @impl GenServer
  @spec handle_call(:get_devices, GenServer.from(), map()) :: {:reply, [map()], map()}
  def handle_call(:get_devices, _from, state) do
    {:reply, state.devices, state}
  end

  @impl GenServer
  @spec handle_info(:poll, map()) :: {:noreply, map()}
  def handle_info(:poll, state) do
    schedule_poll()
    devices = poll_devices()

    if devices != state.devices do
      Phoenix.PubSub.broadcast(MobDev.PubSub, "devices", {:devices_updated, devices})
    end

    {:noreply, %{state | devices: devices}}
  end

  # ── Internals ────────────────────────────────────────────────────────────────

  defp schedule_poll, do: Process.send_after(self(), :poll, @poll_ms)

  defp poll_devices do
    android =
      try do
        Android.list_devices()
        |> Enum.reject(&(&1.status == :unauthorized))
        |> Enum.map(&enrich_android/1)
      rescue
        _ -> []
      end

    ios =
      if macos?() do
        try do
          IOS.list_simulators()
          |> Enum.filter(&(&1.status == :booted))
          |> Enum.map(&enrich_ios/1)
        rescue
          _ -> []
        end
      else
        []
      end

    android ++ ios
  end

  defp enrich_android(device) do
    battery = read_android_battery(device.serial)
    beam_running = beam_running_android?(device.serial)
    Map.merge(device, %{battery: battery, beam_running: beam_running})
  end

  defp enrich_ios(device) do
    Map.merge(device, %{battery: nil, beam_running: nil})
  end

  defp read_android_battery(serial) do
    case System.cmd("adb", ["-s", serial, "shell", "dumpsys battery"], stderr_to_stdout: true) do
      {out, 0} ->
        case Regex.run(Regex.compile!("level:\\s*(\\d+)"), out) do
          [_, pct] -> String.to_integer(pct)
          nil -> nil
        end

      _ ->
        nil
    end
  end

  defp beam_running_android?(serial) do
    # Use pm list packages to find the installed third-party app rather than
    # hardcoding a bundle ID — works for any app name.
    case System.cmd(
           "adb",
           ["-s", serial, "shell", "pidof $(pm list packages -3 | head -1 | cut -d: -f2)"],
           stderr_to_stdout: true
         ) do
      {out, 0} -> String.trim(out) != ""
      _ -> false
    end
  end

  defp macos?, do: match?({:unix, :darwin}, :os.type())
end
