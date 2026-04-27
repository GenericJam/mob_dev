defmodule MobDev.Bench.Reconnector do
  @moduledoc """
  Auto-reconnect logic for the bench's BEAM dist connection.

  When a probe says the dist connection has dropped (`:alive_epmd_only` or
  `:alive_dist_only` after an RPC timeout), we want to attempt to reconnect
  automatically rather than leaving the bench in a stuck state for the rest
  of the run.

  This module is *pure logic* — no GenServer, no timers. The bench polling
  loop calls `tick/2` once per cycle, which decides whether to attempt a
  reconnect based on the current reachability and elapsed time since the
  last attempt. This keeps the reconnect logic testable and lets the
  caller control the cadence.

  ## Backoff schedule (defaults)

      1st attempt: immediate
      2nd attempt: 2 s after 1st
      3rd attempt: 4 s after 2nd
      4th attempt: 8 s after 3rd
      Subsequent: 30 s cap

  Reset to immediate on a successful reconnect.
  """

  alias MobDev.Bench.Probe

  defstruct [
    :node,
    :cookie,
    :attempts,
    :last_attempt_ms,
    :total_reconnects,
    :max_backoff_ms
  ]

  @type t :: %__MODULE__{
          node: atom(),
          cookie: atom(),
          attempts: non_neg_integer(),
          last_attempt_ms: integer() | nil,
          total_reconnects: non_neg_integer(),
          max_backoff_ms: pos_integer()
        }

  @default_backoffs [0, 2_000, 4_000, 8_000, 16_000]
  @default_max_backoff_ms 30_000

  @doc """
  Initialise a reconnector for `node` with cookie. Optional `:max_backoff_ms`.
  """
  @spec new(atom(), atom(), keyword()) :: t()
  def new(node, cookie, opts \\ []) do
    %__MODULE__{
      node: node,
      cookie: cookie,
      attempts: 0,
      last_attempt_ms: nil,
      total_reconnects: 0,
      max_backoff_ms: Keyword.get(opts, :max_backoff_ms, @default_max_backoff_ms)
    }
  end

  @doc """
  Decide whether the caller should attempt a reconnect right now, given the
  current probe state and current time. Returns `{action, updated_reconnector}`.

  Actions:
  - `:no_action` — connection is healthy or it's not time yet
  - `:attempt` — caller should try `Node.connect(reconnector.node)` now

  After a successful reconnect, call `record_success/1` to reset the backoff.
  """
  @spec tick(t(), Probe.t() | atom(), integer()) :: {:no_action | :attempt, t()}
  def tick(reconnector, %Probe{} = probe, now_ms) do
    tick(reconnector, probe.reachability, now_ms)
  end

  def tick(%__MODULE__{} = r, reachability, now_ms) when is_atom(reachability) do
    cond do
      # Connection is healthy — reset attempts.
      reachability == :alive_rpc ->
        {:no_action, %{r | attempts: 0}}

      # Not enough time has passed since the last attempt.
      r.last_attempt_ms != nil and now_ms - r.last_attempt_ms < current_backoff_ms(r) ->
        {:no_action, r}

      # Time to try.
      true ->
        {:attempt, %{r | attempts: r.attempts + 1, last_attempt_ms: now_ms}}
    end
  end

  @doc """
  Record that the most recent reconnect attempt succeeded — resets the
  backoff counter and bumps the total_reconnects counter.
  """
  @spec record_success(t()) :: t()
  def record_success(%__MODULE__{} = r) do
    %{r | attempts: 0, total_reconnects: r.total_reconnects + 1}
  end

  @doc """
  Returns the backoff (in ms) that applies to the *next* attempt.

      iex> r = MobDev.Bench.Reconnector.new(:node@host, :secret)
      iex> MobDev.Bench.Reconnector.current_backoff_ms(r)
      0

      iex> r = %{MobDev.Bench.Reconnector.new(:node@host, :secret) | attempts: 3}
      iex> MobDev.Bench.Reconnector.current_backoff_ms(r)
      8000
  """
  @spec current_backoff_ms(t()) :: non_neg_integer()
  def current_backoff_ms(%__MODULE__{attempts: attempts, max_backoff_ms: max}) do
    case Enum.at(@default_backoffs, attempts) do
      nil -> max
      ms -> min(ms, max)
    end
  end
end
