defmodule MobDev.Bench.DeviceObserver do
  @moduledoc """
  Subscribes to `Mob.Device` events on the running app over Erlang
  distribution and tracks ground-truth screen/app state for the bench.

  Without this, the bench only knows what *it* asked the device to do
  ("we just ran lock_screen, so the screen *should* be off"). With this,
  the bench learns from the device what's actually happening
  (`{:mob_device, :did_enter_background}`, `{:mob_device, :screen_off}`),
  and the probe snapshots reflect reality.

  ## Lifecycle

      observer = DeviceObserver.subscribe(node, categories: [:app, :display])
      ...
      observer = DeviceObserver.consume_messages(observer)  # call each tick
      observer.screen   # => :on | :off | :unknown
      observer.app      # => :running | :background | :suspended | :unknown
      observer.events   # => list of recent events (most recent first)

  Subscription is best-effort — if the device's BEAM doesn't have
  `Mob.Device.subscribe/1` exported (older app build), `subscribe/2`
  returns an observer that just passes through the caller's expected
  state.
  """

  require Logger

  defstruct [
    :node,
    :subscribed?,
    :screen,
    :app,
    :last_event_ts_ms,
    :events
  ]

  @type screen_state :: :on | :off | :unknown
  @type app_state :: :running | :background | :suspended | :unknown

  @type t :: %__MODULE__{
          node: atom() | nil,
          subscribed?: boolean(),
          screen: screen_state(),
          app: app_state(),
          last_event_ts_ms: integer() | nil,
          events: [{integer(), atom(), term()}]
        }

  @max_events_kept 100

  @doc """
  Try to subscribe the calling process to `Mob.Device` events on `node`.
  Returns an observer struct, possibly with `subscribed?: false` if the
  device's app doesn't support it (older build).
  """
  @spec subscribe(atom() | nil, keyword()) :: t()
  def subscribe(nil, _opts) do
    %__MODULE__{
      node: nil,
      subscribed?: false,
      screen: :unknown,
      app: :unknown,
      last_event_ts_ms: nil,
      events: []
    }
  end

  def subscribe(node, opts) when is_atom(node) do
    categories = Keyword.get(opts, :categories, [:app, :display])
    pid = self()

    subscribed? =
      try do
        case :rpc.call(node, Mob.Device, :subscribe, [categories], 3_000) do
          :ok -> true
          {:badrpc, _} -> false
          _ -> false
        end
      rescue
        _ -> false
      catch
        _, _ -> false
      end

    # Touching pid intentionally so dialyzer doesn't whine (it's where the
    # device sends events).
    _ = pid

    %__MODULE__{
      node: node,
      subscribed?: subscribed?,
      screen: :unknown,
      app: :unknown,
      last_event_ts_ms: nil,
      events: []
    }
  end

  @doc """
  Drain the calling process's mailbox of pending Mob.Device messages and
  update the observer's tracked state. Returns the updated observer.

  Call this at the top of each poll cycle. Non-blocking — uses `receive`
  with `after 0`.
  """
  @spec consume_messages(t()) :: t()
  def consume_messages(%__MODULE__{} = obs) do
    do_consume(obs)
  end

  defp do_consume(obs) do
    receive do
      {:mob_device, event} when is_atom(event) ->
        obs
        |> apply_event(event, nil)
        |> do_consume()

      {:mob_device, event, payload} when is_atom(event) ->
        obs
        |> apply_event(event, payload)
        |> do_consume()
    after
      0 ->
        obs
    end
  end

  @doc false
  def apply_event(obs, event, payload) do
    now = System.monotonic_time(:millisecond)

    obs = %{
      obs
      | last_event_ts_ms: now,
        events: [{now, event, payload} | obs.events] |> Enum.take(@max_events_kept)
    }

    case event do
      :screen_off -> %{obs | screen: :off}
      :screen_on -> %{obs | screen: :on}
      :did_enter_background -> %{obs | app: :background}
      :will_resign_active -> obs
      :will_enter_foreground -> obs
      :did_become_active -> %{obs | app: :running}
      :will_terminate -> %{obs | app: :suspended}
      :memory_warning -> obs
      _ -> obs
    end
  end

  @doc """
  Merge the observer's ground-truth state into a Probe snapshot. If the
  observer has authoritative state, prefer it over what the probe inferred;
  fall back to the probe's view otherwise.
  """
  @spec apply_to_probe(t(), MobDev.Bench.Probe.t()) :: MobDev.Bench.Probe.t()
  def apply_to_probe(%__MODULE__{} = obs, %MobDev.Bench.Probe{} = probe) do
    screen =
      case obs.screen do
        :unknown -> probe.screen
        observed -> observed
      end

    app_process =
      case obs.app do
        :running -> :app_running
        :background -> :app_running
        :suspended -> :app_suspended
        :unknown -> probe.app_process
      end

    %{probe | screen: screen, app_process: app_process}
  end
end
