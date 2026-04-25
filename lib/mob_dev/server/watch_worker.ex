defmodule MobDev.Server.WatchWorker do
  @moduledoc """
  GenServer that runs the mob.watch loop inside the mob.server process.

  Polls `lib/**/*.ex` for changes every 500ms. When files change it
  debounces, recompiles, and hot-pushes changed modules to all connected
  device nodes via Erlang dist — same logic as `mix mob.watch` but driven
  from the dashboard UI instead of a terminal.

  Events broadcast to the `"watch"` PubSub topic:
    {:watch_status,  :watching | :idle}
    {:watch_push,    %{pushed: n, failed: [...], nodes: [...], files: [...]}}
  """

  use GenServer
  require Logger

  alias MobDev.HotPush

  @pubsub MobDev.PubSub
  @topic "watch"
  @cookie :mob_secret
  # ms between source polls
  @interval 500
  # ms to wait after first change before compiling
  @debounce 300

  # ── Public API ──────────────────────────────────────────────────────────────

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Start watching. Idempotent — safe to call when already watching."
  @spec start_watching() :: term()
  def start_watching, do: GenServer.call(__MODULE__, :start)

  @doc "Stop watching."
  @spec stop_watching() :: term()
  def stop_watching, do: GenServer.call(__MODULE__, :stop)

  @doc "Returns %{watching: bool, nodes: [node()], last_push: map | nil}."
  @spec status() :: map()
  def status, do: GenServer.call(__MODULE__, :status)

  @doc "Subscribe the calling process to watch PubSub events."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(@pubsub, @topic)

  # ── GenServer ────────────────────────────────────────────────────────────────

  @impl GenServer
  def init(:ok) do
    {:ok, %{watching: false, sources: %{}, nodes: [], timer: nil, last_push: nil}}
  end

  @impl GenServer
  def handle_call(:start, _from, %{watching: true} = state) do
    {:reply, :already_watching, state}
  end

  def handle_call(:start, _from, state) do
    nodes = connect_nodes()
    sources = snapshot_sources()
    timer = schedule_tick()
    state = %{state | watching: true, sources: sources, nodes: nodes, timer: timer}
    broadcast({:watch_status, :watching})
    Logger.info("WatchWorker: started, #{length(nodes)} node(s) connected")
    {:reply, :ok, state}
  end

  def handle_call(:stop, _from, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    broadcast({:watch_status, :idle})
    Logger.info("WatchWorker: stopped")
    {:reply, :ok, %{state | watching: false, nodes: [], timer: nil}}
  end

  def handle_call(:status, _from, state) do
    {:reply, %{watching: state.watching, nodes: state.nodes, last_push: state.last_push}, state}
  end

  @impl GenServer
  def handle_info(:tick, %{watching: false} = state), do: {:noreply, state}

  def handle_info(:tick, state) do
    current = snapshot_sources()
    changed = changed_files(state.sources, current)

    state =
      if changed == [] do
        state
      else
        # Debounce — let format-on-save and multi-file saves settle.
        Process.sleep(@debounce)
        current2 = snapshot_sources()

        nodes = reconnect(state.nodes)

        if nodes == [] do
          Logger.warning("WatchWorker: files changed but no nodes connected — skipping push")
          %{state | sources: current2, nodes: nodes}
        else
          snapshot = HotPush.snapshot_beams()
          compile()
          {pushed, failed} = HotPush.push_changed(nodes, snapshot)

          push_info = %{
            pushed: pushed,
            failed: failed,
            nodes: nodes,
            files: Enum.map(changed, &Path.relative_to_cwd/1),
            at: DateTime.utc_now()
          }

          if pushed > 0 or failed != [] do
            broadcast({:watch_push, push_info})
            Logger.info("WatchWorker: pushed #{pushed} module(s) to #{length(nodes)} node(s)")
          end

          %{state | sources: current2, nodes: nodes, last_push: push_info}
        end
      end

    {:noreply, %{state | timer: schedule_tick()}}
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp schedule_tick, do: Process.send_after(self(), :tick, @interval)

  defp connect_nodes do
    try do
      HotPush.connect(cookie: @cookie)
    rescue
      _ -> []
    end
  end

  defp reconnect(nodes) do
    alive = Enum.filter(nodes, &(Node.connect(&1) == true))
    new = connect_nodes()
    Enum.uniq(alive ++ new)
  end

  defp compile do
    mix = System.find_executable("mix") || "mix"
    System.cmd(mix, ["compile"], cd: File.cwd!(), stderr_to_stdout: true)
  end

  defp snapshot_sources do
    Path.wildcard("lib/**/*.ex")
    |> Map.new(fn path ->
      mtime =
        case File.stat(path, time: :posix) do
          {:ok, %{mtime: t}} -> t
          _ -> 0
        end

      {path, mtime}
    end)
  end

  defp changed_files(old, current) do
    Enum.flat_map(current, fn {path, mtime} ->
      if Map.get(old, path) != mtime, do: [path], else: []
    end)
  end

  defp broadcast(msg), do: Phoenix.PubSub.broadcast(@pubsub, @topic, msg)
end
