defmodule MobDev.OtpTrace.Collector do
  @moduledoc false
  # GenServer that receives `{:trace, pid, :call, {m, f, a}}` messages
  # from `:erlang.trace/3` and accumulates the unique MFAs into a MapSet.
  #
  # Used by `MobDev.OtpTrace.capture/2`. Excludes a configurable set of
  # modules (the trace machinery itself) so we don't poison the result
  # with our own bookkeeping.

  use GenServer

  @spec start_link(MapSet.t(module())) :: {:ok, pid()}
  def start_link(exclude_modules) when is_struct(exclude_modules, MapSet) do
    GenServer.start_link(__MODULE__, exclude_modules)
  end

  @spec snapshot(pid()) :: MapSet.t(mfa())
  def snapshot(pid), do: GenServer.call(pid, :snapshot, 5_000)

  @spec stop(pid()) :: :ok
  def stop(pid), do: GenServer.stop(pid)

  @impl true
  def init(exclude) do
    {:ok, %{mfas: MapSet.new(), exclude: exclude}}
  end

  @impl true
  def handle_info({:trace, _pid, :call, {m, f, args_or_arity}}, state) do
    # `:erlang.trace/3` reports the call payload as either an integer arity
    # (when invoked via apply/3) or a list of actual args (the common case).
    # Normalize to arity so the MapSet entry is comparable across calls.
    arity = if is_list(args_or_arity), do: length(args_or_arity), else: args_or_arity

    state =
      if MapSet.member?(state.exclude, m) do
        state
      else
        %{state | mfas: MapSet.put(state.mfas, {m, f, arity})}
      end

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, state.mfas, state}
  end
end
