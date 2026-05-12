# credo:disable-for-this-file Credo.Check.Readability.Specs
#
# This is a characterization fixture: every public function exercises a
# slice of Elixir/OTP and returns whatever the last expression
# evaluates to (often a tuple of locals). Spec'ing each as `:: any()`
# adds noise without information. The module is internal tooling for
# `MobDev.OtpTrace.capture/1` — never an API surface third parties
# build against.
defmodule MobDev.OtpTrace.Harness do
  @moduledoc """
  Characterization harness: a curated set of Elixir features exercised
  in tight blocks. Designed to be wrapped in `MobDev.OtpTrace.capture/1`
  to record the runtime modules touched by typical Elixir code.

  ## Phases

  Run individually or together. Each phase exercises a coherent slice
  so the trace can be partitioned into "what does X actually need."

    * `language/0`    — pattern match, comprehension, anonymous fns,
                        struct + protocol dispatch, exception handling
    * `collections/0` — Enum, Stream, List, Map, MapSet, Tuple, Range
    * `strings/0`     — String, Binary, charlist conversion, sigils
    * `processes/0`   — spawn, send/receive, monitor, link
    * `otp/0`         — GenServer, Supervisor, Application boot, Logger
    * `data/0`        — ETS, :persistent_term, Date/Time
    * `errors/0`      — raise, rescue, throw/catch, exit/trap_exit
    * `all/0`         — runs everything sequentially

  ## What this is NOT

  - Not a benchmark — timings are meaningless under trace overhead
  - Not exhaustive — covers common Elixir, not every language corner
  - Not production-safe — runs `:erlang.trace/3` system-wide

  ## How modules are defined

  Modules used by the harness are defined at compile time of THIS module,
  NOT inside the traced functions. That's deliberate: tracing inside a
  `defmodule` block captures the entire compiler call graph (~80 modules
  of `:elixir_*`, `:erl_lint`, `:sys_core_*`). Production apps don't run
  the compiler at runtime, so we exclude that surface from the baseline.
  """

  require Logger

  # ── Modules used by the exercises (defined at compile time) ──────────

  defmodule HarnessStruct do
    @moduledoc false
    defstruct [:a, :b, :c]
    def with_a(s, a), do: %{s | a: a}
  end

  defprotocol HarnessProto do
    @moduledoc false
    def describe(thing)
  end

  defimpl HarnessProto, for: Integer do
    def describe(n), do: "int:#{n}"
  end

  defimpl HarnessProto, for: BitString do
    def describe(s), do: "str:#{s}"
  end

  defimpl HarnessProto, for: HarnessStruct do
    def describe(%HarnessStruct{a: a}), do: "struct:#{a}"
  end

  defmodule HarnessGS do
    @moduledoc false
    use GenServer

    def start_link(arg), do: GenServer.start_link(__MODULE__, arg)
    def get(pid), do: GenServer.call(pid, :get)
    def set(pid, v), do: GenServer.cast(pid, {:set, v})

    @impl true
    def init(arg), do: {:ok, arg}
    @impl true
    def handle_call(:get, _from, state), do: {:reply, state, state}
    @impl true
    def handle_cast({:set, v}, _state), do: {:noreply, v}
  end

  defmodule HarnessApp do
    @moduledoc false
    use Application

    @impl true
    def start(_type, _args) do
      Supervisor.start_link([], strategy: :one_for_one)
    end
  end

  # ── Phases ────────────────────────────────────────────────────────────

  def language do
    # pattern match
    {a, b} = {1, 2}
    [_h | _t] = [1, 2, 3]
    %{x: x} = %{x: 10, y: 20}
    <<n::8, _rest::binary>> = <<42, 1, 2>>
    _ = {a, b, x, n}

    # case + guards
    _ =
      case 5 do
        n when n > 10 -> :big
        n when n > 0 -> :positive
        _ -> :nonpositive
      end

    # cond
    _ =
      cond do
        1 == 2 -> :no
        true -> :yes
      end

    # anonymous fn + capture
    add = fn a, b -> a + b end
    add.(1, 2)
    inc = &(&1 + 1)
    inc.(5)

    # comprehension
    _ = for i <- 1..5, j <- 1..3, rem(i + j, 2) == 0, do: {i, j}

    # struct + protocol
    s = %HarnessStruct{a: 1, b: 2, c: 3}
    HarnessProto.describe(s)
    HarnessProto.describe(42)
    HarnessProto.describe("hi")

    # try/rescue
    _ =
      try do
        raise ArgumentError, "boom"
      rescue
        e in [ArgumentError] -> e.message
      end

    :ok
  end

  def collections do
    list = [1, 2, 3, 4, 5]

    # Enum (the workhorse)
    Enum.map(list, &(&1 * 2))
    Enum.filter(list, &(&1 > 2))
    Enum.reduce(list, 0, &+/2)
    Enum.sort(list)
    Enum.zip(list, [:a, :b, :c, :d, :e])
    Enum.into(list, MapSet.new())
    Enum.group_by(list, &rem(&1, 2))

    # List
    List.flatten([[1], [2, [3]], 4])
    List.first(list)
    List.last(list)
    List.delete(list, 3)
    List.keyfind([{:a, 1}, {:b, 2}], :b, 0)

    # Map
    m = %{a: 1, b: 2, c: 3}
    Map.put(m, :d, 4)
    Map.delete(m, :a)
    Map.merge(m, %{b: 20})
    Map.update(m, :a, 0, &(&1 + 100))

    # MapSet
    s = MapSet.new([1, 2, 3])
    MapSet.put(s, 4)
    MapSet.union(s, MapSet.new([3, 4, 5]))

    # Stream + Range
    Stream.map(1..1000, &(&1 * 2)) |> Stream.take(10) |> Enum.to_list()

    # Tuple. Calls below are intentional probes — the return value is
    # discarded; we just want each MFA to land in the trace.
    Tuple.insert_at({1, 2}, 2, 3)
    _ = Tuple.to_list({1, 2, 3})

    # Keyword
    kw = [a: 1, b: 2, c: 3]
    Keyword.get(kw, :b)
    Keyword.put(kw, :d, 4)

    :ok
  end

  def strings do
    # String basics
    String.upcase("hello")
    String.split("a,b,c,d", ",")
    String.replace("foo bar baz", " ", "_")
    String.contains?("hello world", "world")
    String.length("héllo")
    String.slice("hello", 1, 3)
    String.trim("  spaced  ")

    # Binary ops. `_ =` on byte_size / binary_part because the return
    # is discarded — we're probing the trace surface.
    <<a, b, c>> = "abc"
    bin = <<a, b, c>>
    _ = byte_size(bin)
    _ = binary_part(bin, 0, 2)
    :binary.copy("xy", 5)

    # IO data
    IO.iodata_to_binary(["one", " ", "two"])

    # Charlists
    String.to_charlist("hello")
    List.to_string(~c"world")

    # Codepoints
    String.codepoints("aé🌍")
    String.graphemes("aé🌍")

    :ok
  end

  def processes do
    parent = self()

    # spawn + receive
    pid = spawn(fn -> send(parent, {self(), :hello}) end)

    receive do
      {^pid, :hello} -> :ok
    after
      1_000 -> :timeout
    end

    # link
    {:ok, _} = Task.start_link(fn -> :ok end)

    # monitor
    pid2 = spawn(fn -> :ok end)
    ref = Process.monitor(pid2)

    receive do
      {:DOWN, ^ref, :process, ^pid2, _} -> :ok
    after
      1_000 -> :timeout
    end

    # Task
    task = Task.async(fn -> 21 * 2 end)
    Task.await(task)

    # Process dictionary (rarely used but still common)
    Process.put(:test_key, :test_val)
    Process.get(:test_key)
    Process.delete(:test_key)

    :ok
  end

  def otp do
    # GenServer round-trip
    {:ok, gs} = HarnessGS.start_link(:initial)
    HarnessGS.get(gs)
    HarnessGS.set(gs, :updated)
    HarnessGS.get(gs)
    GenServer.stop(gs)

    # Supervisor (in-process)
    children = [
      Supervisor.child_spec({Task, fn -> Process.sleep(:infinity) end}, id: :worker_a),
      Supervisor.child_spec({Task, fn -> Process.sleep(:infinity) end}, id: :worker_b)
    ]

    {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_one)
    Supervisor.stop(sup)

    # Logger calls (ensure logger backend gets exercised)
    Logger.info("trace harness — info")
    Logger.warning("trace harness — warning")

    :ok
  end

  def data do
    # ETS
    table = :ets.new(:harness_table, [:set, :public])
    :ets.insert(table, {:key1, "value1"})
    :ets.insert(table, {:key2, "value2"})
    :ets.lookup(table, :key1)
    :ets.match(table, {:_, :_})
    :ets.delete(table)

    # persistent_term
    :persistent_term.put({__MODULE__, :test}, 42)
    :persistent_term.get({__MODULE__, :test})
    :persistent_term.erase({__MODULE__, :test})

    # Date/Time/DateTime
    Date.utc_today()
    Time.utc_now()
    DateTime.utc_now()
    DateTime.add(DateTime.utc_now(), 60, :second)
    Calendar.ISO.day_of_week(2026, 5, 2, :default)

    # NaiveDateTime
    NaiveDateTime.utc_now()

    # System
    System.os_time(:millisecond)
    System.monotonic_time()

    :ok
  end

  def errors do
    # raise/rescue
    _ =
      try do
        raise RuntimeError, "boom"
      rescue
        e -> Exception.message(e)
      end

    # throw/catch
    _ =
      try do
        throw(:my_throw)
      catch
        :throw, val -> val
      end

    # exit/trap_exit
    Process.flag(:trap_exit, true)
    pid = spawn_link(fn -> exit(:bye) end)

    receive do
      {:EXIT, ^pid, :bye} -> :ok
    after
      1_000 -> :timeout
    end

    Process.flag(:trap_exit, false)

    # Stream of standard exceptions to ensure their __struct__/2 etc fire
    _ = %ArgumentError{message: "x"}
    _ = %ArithmeticError{}
    _ = %FunctionClauseError{}
    _ = %KeyError{key: :x, term: %{}}
    _ = %MatchError{term: nil}
    _ = %RuntimeError{message: "x"}
    _ = %UndefinedFunctionError{}

    :ok
  end

  def all do
    language()
    collections()
    strings()
    processes()
    otp()
    data()
    errors()
    :ok
  end
end
