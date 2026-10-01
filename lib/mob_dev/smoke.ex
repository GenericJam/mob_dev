defmodule MobDev.Smoke do
  @moduledoc """
  The decisions behind `mix mob.smoke`, kept free of I/O so each can be
  tested against the shapes `agent-device` and `Mob.Diag` really return.

  A replayed flow passing is the tool's opinion. The app's own counters say
  whether it held up: a store that lost its table or reset, events the
  listener could not deliver, or no receipts at all while a flow ran (the taps
  landed somewhere other than this app). So the verdict combines both, and a
  device that could not be checked never counts as a pass.

  `agent-device test --json` reports `"success": true` even when scripts
  fail; only `data.failed` and `data.notRun` say what happened.

  The counters live in the app's BEAM and start from zero when it boots, and a
  flow that begins with `open --relaunch` boots a new one. So health is read
  around each flow, and a snapshot from a different BEAM (its OS pid changed)
  is compared against zero rather than against the old BEAM's counters.
  """

  alias MobDev.Device

  @uiautomation_conflict "Android snapshot helper output could not be parsed"

  @typedoc "One failed script from `agent-device test --json`."
  @type failure :: %{
          file: String.t() | nil,
          status: String.t() | nil,
          attempts: non_neg_integer(),
          artifacts_dir: String.t() | nil,
          code: String.t() | nil,
          message: String.t() | nil,
          hint: String.t() | nil
        }

  @typedoc "The parts of a suite report the verdict reads."
  @type report :: %{
          total: non_neg_integer(),
          executed: non_neg_integer(),
          passed: non_neg_integer(),
          failed: non_neg_integer(),
          skipped: non_neg_integer(),
          not_run: non_neg_integer(),
          duration_ms: non_neg_integer(),
          failures: [failure()]
        }

  @typedoc "`agent-device` refused to run (`\"success\": false`)."
  @type cli_error :: %{code: String.t() | nil, message: String.t(), hint: String.t() | nil}

  @typedoc "Another session's lease on a device."
  @type claim :: %{
          device_key: String.t() | nil,
          classification: String.t() | nil,
          session: String.t() | nil,
          workspace: String.t() | nil
        }

  @typedoc "An RPC reply sorted by what it means for the check."
  @type reply ::
          {:ok, term()}
          | {:unreachable, String.t()}
          | {:unsupported, String.t()}
          | {:error, String.t()}

  @typedoc "`Mob.Diag.health/0` and the BEAM's OS pid, read together."
  @type snapshot :: %{health: reply(), beam: reply()}

  @type finding :: {:failure | :warning | :note, String.t()}

  @type outcome :: {:blocked, String.t()} | {:ran, report(), integer()}

  @typedoc "Everything `mix mob.smoke` learned about one device."
  @type result :: %{
          device: String.t(),
          outcome: outcome(),
          findings: [finding()],
          receipts_delta: integer() | nil
        }

  @doc false
  @spec recording_recipe(Path.t()) :: String.t()
  def recording_recipe(flows_dir) do
    """
    Record a flow by hand with agent-device. The app must already be installed
    and running on the device:

        agent-device open <app-id> --relaunch --serial <serial> --session rec \\
          --save-script "$PWD/#{flows_dir}/<name>.ad"
        agent-device snapshot -i --session rec        # find element refs
        agent-device click @e3 --session rec          # drive the app
        agent-device wait text "Saved" --session rec  # assert what must appear
        agent-device close --session rec --save-script

    Use `--udid <udid>` instead of `--serial` for iOS. `--save-script` needs an
    absolute path: a relative one is resolved by the agent-device daemon, not
    this directory, and the script silently lands somewhere else. `--relaunch`
    starts every flow from a fresh app.
    """
  end

  @doc false
  @spec no_flows_message(Path.t()) :: String.t()
  def no_flows_message(flows_dir) do
    "No smoke flows (*.ad) in #{flows_dir}/.\n\n" <> recording_recipe(flows_dir)
  end

  @doc false
  # agent-device addresses Android by adb serial and iOS by UDID. An iPhone
  # found only over the LAN carries its IP as the serial, which agent-device
  # cannot address.
  @spec device_target(Device.t()) :: {:ok, [String.t()]} | {:error, String.t()}
  def device_target(%Device{platform: :android, serial: serial}), do: {:ok, ["--serial", serial]}

  def device_target(%Device{platform: :ios, serial: serial}) do
    if Regex.match?(Regex.compile!("^\\d{1,3}(\\.\\d{1,3}){3}$"), serial) do
      {:error,
       "found over the network only (#{serial}), so its UDID is unknown; connect it by USB"}
    else
      {:ok, ["--udid", serial]}
    end
  end

  @doc false
  # Device ids and flow names become path components; an adb-over-WiFi serial
  # carries a `:`. A name that had to be rewritten carries a hash of the
  # original, so `log in.ad` and `log_in.ad` cannot share a directory or a
  # JUnit file and overwrite each other's results.
  @spec slug(String.t()) :: String.t()
  def slug(name) do
    case Regex.replace(Regex.compile!("[^A-Za-z0-9._-]"), name, "_") do
      ^name -> name
      safe -> safe <> "-" <> Integer.to_string(:erlang.crc32(name), 16)
    end
  end

  @doc false
  # Where one `agent-device test` run writes. `flow` is nil for a whole-suite
  # run (`--no-health`), else the flow's file name: per-flow runs get their own
  # artifacts directory and JUnit file so they cannot overwrite each other.
  @spec run_paths(Path.t(), Path.t() | nil, String.t(), Path.t() | nil) ::
          %{artifacts_dir: Path.t(), junit: Path.t() | nil}
  def run_paths(artifacts_root, junit, device_id, flow) do
    suffix = [device_id | List.wrap(flow && Path.basename(flow, ".ad"))] |> Enum.map(&slug/1)

    %{
      artifacts_dir: Path.join([artifacts_root | suffix]),
      junit: junit && junit_path(junit, Enum.join(suffix, "-"))
    }
  end

  defp junit_path(path, suffix) do
    ext = Path.extname(path)
    Path.rootname(path, ext) <> "-" <> suffix <> ext
  end

  @doc false
  # `script` is a flow file or the quoted glob for a whole suite; agent-device
  # expands globs itself. Paths should be absolute, because the agent-device
  # daemon does not share our cwd. `--retries` is always passed, 0 included:
  # without it agent-device falls back to the script's own `context retries=`.
  @spec test_argv(Path.t(), [String.t()], keyword()) :: [String.t()]
  def test_argv(script, target, opts) do
    retries = Keyword.get(opts, :retries, 0)

    ["test", script] ++
      target ++
      ["--json", "--artifacts-dir", Keyword.fetch!(opts, :artifacts_dir)] ++
      ["--retries", Integer.to_string(retries)] ++
      if(opts[:junit], do: ["--reporter", "junit:" <> opts[:junit]], else: []) ++
      if(opts[:fail_fast], do: ["--fail-fast"], else: [])
  end

  @doc false
  @spec parse_report(String.t()) :: {:ok, report()} | {:error, cli_error()}
  def parse_report(output) do
    case Jason.decode(String.trim(output)) do
      {:ok, %{"success" => true, "data" => %{"total" => _} = data}} ->
        {:ok, report(data)}

      {:ok, %{"success" => false, "error" => %{} = error}} ->
        {:error, cli_error(error)}

      {:ok, _other} ->
        {:error,
         %{code: nil, message: "agent-device printed JSON that is not a test report", hint: nil}}

      {:error, _} ->
        {:error,
         %{
           code: nil,
           message: "agent-device did not print a JSON report: " <> String.slice(output, 0, 300),
           hint: nil
         }}
    end
  end

  defp report(data) do
    %{
      total: count(data, "total"),
      executed: count(data, "executed"),
      passed: count(data, "passed"),
      failed: count(data, "failed"),
      skipped: count(data, "skipped"),
      not_run: count(data, "notRun"),
      duration_ms: count(data, "durationMs"),
      failures: Enum.map(Map.get(data, "failures", []), &failure/1)
    }
  end

  defp count(data, key) do
    case data[key] do
      n when is_integer(n) -> n
      _ -> 0
    end
  end

  defp failure(entry) do
    error = entry["error"] || %{}

    %{
      file: entry["file"],
      status: entry["status"],
      attempts: count(entry, "attempts"),
      artifacts_dir: entry["artifactsDir"],
      code: error["code"],
      message: error["message"],
      hint: error["hint"]
    }
  end

  defp cli_error(error) do
    %{
      code: error["code"],
      message: error["message"] || "agent-device failed without a message",
      hint: error["hint"]
    }
  end

  @doc false
  # A run agent-device refused counts as one flow not run, with the refusal
  # kept as a failure entry (status "refused") so it is printed and named.
  @spec refused_report(Path.t(), cli_error()) :: report()
  def refused_report(script, error) do
    %{
      empty_report()
      | total: 1,
        not_run: 1,
        failures: [
          %{
            file: script,
            status: "refused",
            attempts: 0,
            artifacts_dir: nil,
            code: error.code,
            message: error.message,
            hint: error.hint
          }
        ]
    }
  end

  @doc false
  # Flows `--fail-fast` stopped before running.
  @spec not_run_report(non_neg_integer()) :: report()
  def not_run_report(flows), do: %{empty_report() | total: flows, not_run: flows}

  @doc false
  @spec merge_reports([report()]) :: report()
  def merge_reports(reports) do
    Enum.reduce(reports, empty_report(), fn report, acc ->
      Map.new(acc, fn
        {:failures, failures} -> {:failures, failures ++ report.failures}
        {key, n} -> {key, n + Map.fetch!(report, key)}
      end)
    end)
  end

  defp empty_report do
    %{
      total: 0,
      executed: 0,
      passed: 0,
      failed: 0,
      skipped: 0,
      not_run: 0,
      duration_ms: 0,
      failures: []
    }
  end

  @doc false
  # Reads `agent-device device status --json`. Stale claims are hidden from
  # that listing (`hiddenStaleClaims`), so any listed claim is live.
  @spec find_claim(String.t(), String.t()) :: {:ok, claim() | nil} | {:error, String.t()}
  def find_claim(output, device_id) do
    case Jason.decode(String.trim(output)) do
      {:ok, %{"success" => true, "data" => %{"claims" => claims}}} when is_list(claims) ->
        {:ok, claims |> Enum.find(&claims_device?(&1, device_id)) |> claim()}

      {:ok, %{"success" => false, "error" => %{} = error}} ->
        {:error, cli_error(error).message}

      _ ->
        {:error, "agent-device device status did not print a claims report"}
    end
  end

  defp claims_device?(claim, device_id) do
    id = String.downcase(device_id)
    claimed = dig(claim, ["device", "id"])
    key = claim["deviceKey"]

    (is_binary(claimed) and String.downcase(claimed) == id) or
      (is_binary(key) and String.ends_with?(String.downcase(key), ":" <> id))
  end

  defp claim(nil), do: nil

  defp claim(raw) do
    owner = raw["owner"] || %{}

    %{
      device_key: raw["deviceKey"],
      classification: raw["classification"],
      session: owner["session"],
      workspace: owner["workspace"]
    }
  end

  @doc false
  @spec claim_message(claim()) :: String.t()
  def claim_message(%{session: session, workspace: workspace}) do
    "in use by session #{session || "?"} (workspace #{workspace || "?"})"
  end

  @doc false
  # Android allows one UiAutomation client. mobile-mcp's DeviceServer holding
  # it makes every agent-device snapshot fail with this text, which says
  # nothing about the cause. It is not killed for the user: it may be in use.
  @spec failure_hints(failure(), Device.t()) :: [String.t()]
  def failure_hints(failure, %Device{platform: platform, serial: serial}) do
    conflict? =
      platform == :android and is_binary(failure.message) and
        String.contains?(failure.message, @uiautomation_conflict)

    Enum.reject([failure.hint], &is_nil/1) ++
      if conflict? do
        [
          "another UiAutomation client (mobile-mcp's DeviceServer) holds the device; " <>
            "stop it with: adb -s #{serial} shell pkill -f mobilecli.DeviceServer"
        ]
      else
        []
      end
  end

  @doc false
  @spec classify_reply(term()) :: reply()
  def classify_reply({:badrpc, :nodedown}), do: {:unreachable, "node not reachable"}

  def classify_reply({:badrpc, {:EXIT, {:undef, [{mod, fun, args, _} | _]}}}) do
    arity = if is_list(args), do: length(args), else: args
    {:unsupported, "#{inspect(mod)}.#{fun}/#{arity} is not on the device"}
  end

  def classify_reply({:badrpc, reason}), do: {:error, inspect(reason, limit: 20)}
  def classify_reply(value), do: {:ok, value}

  @doc false
  # The two snapshots come from different BEAMs: the app was relaunched (or
  # crashed and came back) in between, so the later one counts from zero.
  @spec restarted?(snapshot(), snapshot()) :: boolean()
  def restarted?(%{beam: {:ok, before}}, %{beam: {:ok, after_flow}}), do: before != after_flow
  def restarted?(_before, _after), do: false

  @doc false
  # Compares `Mob.Diag.health/0` around one flow. Older mob lacks the function
  # (< 0.9.5) or the listener section (< 0.9.7); those are notes, because the
  # check could not run rather than found something. Health that cannot be
  # read after the flow is a warning: the flow is not shown to be clean.
  @spec health_findings(snapshot(), snapshot()) :: [finding()]
  def health_findings(before, after_flow) do
    case {health_map(before), health_map(after_flow)} do
      {{:ok, was}, {:ok, now}} ->
        if restarted?(before, after_flow) do
          [{:note, "the app restarted during a flow; its counters are compared from zero"}] ++
            counter_findings(%{}, now)
        else
          counter_findings(was, now)
        end

      {{:ok, _was}, {_kind, reason}} ->
        [{:warning, "health unavailable after the flow: #{reason}"}]

      {{:unsupported, reason}, _after} ->
        [{:note, "health check skipped: #{reason} (needs mob >= 0.9.5)"}]

      {{_kind, reason}, _after} ->
        [{:note, "health check skipped: #{reason}"}]
    end
  end

  defp health_map(%{health: {:ok, map}}) when is_map(map), do: {:ok, map}

  defp health_map(%{health: {:ok, other}}),
    do: {:error, "Mob.Diag.health/0 returned #{inspect(other, limit: 10)}"}

  defp health_map(%{health: reply}), do: reply

  defp counter_findings(was, now), do: store_findings(was, now) ++ listener_findings(was, now)

  defp store_findings(was, now) do
    for {store, stats} <- sorted(Map.get(now, :stores)),
        is_map(stats),
        key <- [:lost, :resets],
        is_integer(stats[key]),
        before = baseline(dig(was, [:stores, store, key])),
        stats[key] > before do
      {:failure, "#{inspect(store)}: #{key} #{before} → #{stats[key]}"}
    end
  end

  defp listener_findings(was, now) do
    before = baseline(dig(was, [:listener, :undeliverable]))
    current = dig(now, [:listener, :undeliverable])

    cond do
      not is_integer(current) ->
        [{:note, "listener not reported (needs mob >= 0.9.7); undeliverable events not checked"}]

      current > before ->
        [{:failure, "listener: undeliverable #{before} → #{current}"}]

      true ->
        []
    end
  end

  defp sorted(map) when is_map(map), do: Enum.sort(map)
  defp sorted(_), do: []

  defp baseline(n) when is_integer(n), do: n
  defp baseline(_), do: 0

  # get_in/2 raises on a non-map step (a store's `store: :stale`).
  defp dig(value, []), do: value
  defp dig(%{} = map, [key | rest]), do: dig(Map.get(map, key), rest)
  defp dig(_value, _path), do: nil

  @doc false
  # Receipts recorded during one flow. `Mob.Agent.Receipts.count/0` is the
  # number of rows retained (capped at 256), so a busy app reads the same
  # before and after; the receipt store's cumulative `recorded` counter in
  # `Mob.Diag.health/0` is what moves.
  @spec receipts_delta(snapshot(), snapshot()) :: integer() | nil
  def receipts_delta(before, after_flow) do
    with {:ok, now} <- recorded(after_flow),
         {:ok, was} <-
           if(restarted?(before, after_flow), do: {:ok, 0}, else: recorded(before)) do
      now - was
    else
      :error -> nil
    end
  end

  # A freshly booted app's receipt store has no state until its first write,
  # so health reports the entry without `:store`: nothing recorded yet, i.e.
  # 0. Only a missing entry (older mob) or an unreadable store means the
  # count is unknown.
  defp recorded(snapshot) do
    with {:ok, map} <- health_map(snapshot),
         %{} = entry <- dig(map, [:stores, Mob.Agent.Receipts]) do
      case entry do
        %{store: %{recorded: n}} when is_integer(n) -> {:ok, n}
        %{store: %{} = store} when not is_map_key(store, :recorded) -> {:ok, 0}
        %{store: _unreadable} -> :error
        _no_state_yet -> {:ok, 0}
      end
    else
      _ -> :error
    end
  end

  @doc false
  # A flow that taps a different app, or a launcher that never brought ours up,
  # replays cleanly. No new receipts while the flow executed is the trace of it,
  # but only on mob >= 0.9.7: before it, native taps reached `handle_info/2`
  # without a receipt, so a flow that worked also left none. The `listener`
  # section in health arrived in the same release, so it is the version signal.
  @spec receipt_findings(snapshot(), snapshot(), non_neg_integer()) :: [finding()]
  def receipt_findings(before, after_flow, executed) do
    case {receipts_delta(before, after_flow), health_map(before), health_map(after_flow)} do
      {0, _, {:ok, now}} when executed > 0 ->
        if is_map_key(now, :listener),
          do: [{:warning, "the flow did not reach the app (no new receipts)"}],
          else: [{:note, "reach not checked: mob < 0.9.7 records no receipts for native taps"}]

      {nil, {:ok, _}, {:ok, _}} ->
        [
          {:note,
           "receipts not counted: Mob.Diag.health/0 reports no Mob.Agent.Receipts recorded"}
        ]

      _ ->
        []
    end
  end

  @doc false
  # Why one device fails the run, or `[]`. A clean report from a non-zero exit
  # still fails: something went wrong that the report does not describe.
  @spec device_failures(result()) :: [String.t()]
  def device_failures(%{device: id, outcome: outcome, findings: findings}) do
    (outcome_failures(outcome) ++ for({:failure, message} <- findings, do: message))
    |> Enum.map(&"#{id}: #{&1}")
  end

  @doc false
  # The verdict's criterion, applied to one device or one flow: what
  # `--fail-fast` halts on. Warnings and notes never fail.
  @spec failed?(result()) :: boolean()
  def failed?(result), do: device_failures(result) != []

  defp outcome_failures({:blocked, reason}), do: ["blocked, #{reason}"]

  defp outcome_failures({:ran, report, status}) do
    refusals =
      for %{status: "refused", message: message} <- report.failures,
          do: "agent-device refused: #{message}"

    found =
      refusals ++
        Enum.reject(
          [
            report.failed > 0 && "#{report.failed} flow(s) failed",
            report.not_run > 0 && "#{report.not_run} flow(s) not run",
            report.executed == 0 && "no flows executed"
          ],
          &(&1 == false)
        )

    if found == [] and status != 0, do: ["agent-device exited #{status}"], else: found
  end

  @doc false
  @spec verdict([result()]) :: :ok | {:error, [String.t()]}
  def verdict([]), do: {:error, ["no device was smoke-tested"]}

  def verdict(results) do
    case Enum.flat_map(results, &device_failures/1) do
      [] -> :ok
      failures -> {:error, failures}
    end
  end

  @doc false
  @spec summary_lines([result()]) :: [String.t()]
  def summary_lines(results) do
    rows =
      Enum.map(results, fn %{device: id, outcome: outcome, findings: findings} = result ->
        {passed, failed, not_run} = counts(outcome)
        failures = Enum.count(findings, &match?({:failure, _}, &1))
        warnings = Enum.count(findings, &match?({:warning, _}, &1))

        [
          id,
          passed,
          failed,
          not_run,
          "#{failures} failure(s), #{warnings} warning(s)",
          status_label(outcome, device_failures(result))
        ]
      end)

    table = [["device", "passed", "failed", "not run", "health", "status"] | rows]

    widths =
      Enum.zip_with(table, fn column -> column |> Enum.map(&String.length/1) |> Enum.max() end)

    Enum.map(table, fn row ->
      row
      |> Enum.zip(widths)
      |> Enum.map_join("  ", fn {cell, w} -> String.pad_trailing(cell, w) end)
      |> String.trim_trailing()
    end)
  end

  defp counts({:ran, report, _}),
    do: {to_string(report.passed), to_string(report.failed), to_string(report.not_run)}

  defp counts(_outcome), do: {"-", "-", "-"}

  defp status_label({:blocked, _}, _failures), do: "BLOCKED"
  defp status_label(_outcome, []), do: "ok"
  defp status_label(_outcome, _failures), do: "FAILED"
end
