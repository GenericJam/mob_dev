defmodule MobDev.OtpTrace do
  @moduledoc """
  Runtime call-tracing utility. Wraps `:erlang.trace_pattern/3` and
  `:erlang.trace/3` to capture the set of `{module, function, arity}`
  actually called during a function's execution.

  Used by the characterization harness (`priv/trace/harness.exs`) to
  empirically map what Elixir's runtime calls under the hood — the
  baseline that complements `MobDev.OtpAudit`'s static analysis.

  ## Why this exists

  Static reachability misses dynamic dispatch (`apply/3` with a
  computed atom, `Code.ensure_loaded/1`, NIF lazy load via
  `:erlang.load_nif/2`). Tracing catches everything that *actually
  ran* during the trace window — ground truth, no inference.

  Combined with static analysis: `static ∪ trace` gives a high-confidence
  reachable set; `static ∩ trace` is the "definitely called and
  statically reachable" core.

  ## Usage

      result = MobDev.OtpTrace.capture(fn ->
        # any Elixir code — exercise features you want to measure
        Enum.map(1..10, &(&1 * 2))
      end)

      result.mfas      # MapSet of {module, function, arity}
      result.modules   # MapSet of modules called
      result.elapsed_us # How long the wrapped fn took (incl. trace overhead)

  Trace overhead is real (~10x slowdown for tight loops) — only enable
  for measurement runs, never in production.
  """

  @type mfa_set :: MapSet.t({module(), atom(), arity()})
  @type module_set :: MapSet.t(module())

  @type result :: %{
          mfas: mfa_set(),
          modules: module_set(),
          elapsed_us: non_neg_integer()
        }

  @doc """
  Run `fun` with full call tracing enabled on the calling process and
  any processes it spawns during execution. Returns a `result/0` map.

  ## Options

    * `:exclude_modules` — modules whose calls should NOT be recorded.
      Defaults to `[__MODULE__, MobDev.OtpTrace.Collector, Agent, Task]`
      so we don't pollute the trace with our own machinery.
  """
  @spec capture((-> any()), keyword()) :: result()
  def capture(fun, opts \\ []) when is_function(fun, 0) do
    exclude =
      opts
      |> Keyword.get(:exclude_modules, [__MODULE__, __MODULE__.Collector, Agent, Task])
      |> MapSet.new()

    {:ok, collector} = MobDev.OtpTrace.Collector.start_link(exclude)

    # Trace ALL local function calls across ALL modules.
    # `:local` includes calls within the module too; `:global` would
    # only catch external calls. We want both for full coverage.
    :erlang.trace_pattern({:_, :_, :_}, true, [:local])

    # Trace this process + anything it spawns. Collector receives
    # {:trace, pid, :call, {m, f, a}} messages.
    :erlang.trace(self(), true, [:call, :set_on_spawn, {:tracer, collector}])

    started = System.monotonic_time(:microsecond)

    try do
      fun.()
    after
      :erlang.trace(self(), false, [:all])
      :erlang.trace_pattern({:_, :_, :_}, false, [:local])
    end

    elapsed = System.monotonic_time(:microsecond) - started

    # Give the collector a beat to process pending trace messages.
    Process.sleep(50)
    mfas = MobDev.OtpTrace.Collector.snapshot(collector)
    MobDev.OtpTrace.Collector.stop(collector)

    %{
      mfas: mfas,
      modules: MapSet.new(mfas, fn {m, _, _} -> m end),
      elapsed_us: elapsed
    }
  end
end
