defmodule Mix.Tasks.Mob.Smoke do
  @shortdoc "Replay recorded UI flows on devices and check the app held up"

  @moduledoc """
  Replay the `agent-device` flows in `smoke/` on each selected device, then
  check the app's own diagnostics agree that nothing broke.

      mix mob.smoke                         # the one connected emulator/simulator
      mix mob.smoke --device emulator-5554
      mix mob.smoke --all-devices --junit _build/smoke.xml

  Needs the `agent-device` CLI (`npm i -g agent-device`) and the app installed
  and running on the device. Flows are `.ad` scripts recorded by hand; see the
  "Smoke flows on devices" section of the README for the recipe.

  ## What is checked

  1. **The device is free.** A device another `agent-device` session holds is
     skipped and reported with that session and workspace. The run fails.
  2. **The flows pass.** `agent-device test` runs the `<flows>/*.ad` scripts.
     Its JSON says `"success": true` even when scripts fail, so the counts are
     what is judged: any failed or not-run flow, or none executed, fails.
  3. **The app held up** (unless `--no-health`). `Mob.Diag.health/0` is read
     over dist before the first flow and after each one, attaching without
     restarting the app. A store whose `lost` or `resets` rose, or a rise in
     the listener's undeliverable events, fails the run. On mob 0.9.7 or
     later, which receipts native taps, no new receipts during a flow is a
     warning: its taps did not reach this app (on older mob it is a note). An
     unreachable node, or a mob too old for these functions, is a note.

  The counters belong to the app's BEAM, and a flow that opens with
  `--relaunch` starts a new one. So with health on each flow is its own
  `agent-device test` run, health is read between flows (waiting up to 15 s
  for a relaunched app's node to come back), and a reading from a new BEAM is
  compared against zero. Health that cannot be read after a flow is a warning
  naming that flow. With `--no-health` the flows run as one suite.

  ## Options

    * `--device` / `--only` (`-d`) — target a device by serial/udid. Repeatable
    * `--all-devices`  — every emulator and simulator
    * `--all-physical` — every physical device (with `--all-devices`: everything)
    * `--ios-only` / `--android-only` — restrict discovery to one platform
    * `--flows DIR`    — directory of `.ad` flows (default: `smoke`)
    * `--retries N`    — retry each failed flow up to N times (default: 0).
      Always passed to agent-device, so it overrides a script's own
      `context retries=`
    * `--artifacts-dir DIR` — agent-device artifacts under `DIR/<device>/`
      (per flow, `DIR/<device>/<flow>/`; default: `_build/mob_smoke`)
    * `--junit PATH`   — JUnit reports, the device id (and, per flow, the flow
      name) appended to the file name
    * `--no-health`    — skip the `Mob.Diag` comparison
    * `--fail-fast`    — stop a device's flows at the first one that fails the
      run: a failed replay, a non-zero exit, or a health failure
    * `--cookie C`     — dist cookie (default: the app's private cookie)

  With no selection flags exactly one emulator/simulator is picked; a lone
  phone needs `--device` or `--all-physical`, because the flows drive it.

  ## Exit status

  Non-zero when any device failed a flow, was blocked or could not be
  addressed, or had a health failure.

  ## Android and mobile-mcp

  Android allows one UiAutomation client. While mobile-mcp's
  `com.mobilenext.mobilecli.DeviceServer` runs on the phone, agent-device
  snapshots fail with "Android snapshot helper output could not be parsed".
  The report then names the command that stops it; it is not stopped for you.
  """

  use Mix.Task

  alias Mix.Tasks.Mob.Connect
  alias Mix.Tasks.Mob.Deploy
  alias MobDev.{Connector, Device, Smoke, TaskHelp, TaskTargets}

  @switches [
    device: :keep,
    only: :keep,
    all_devices: :boolean,
    all_physical: :boolean,
    ios_only: :boolean,
    android_only: :boolean,
    flows: :string,
    retries: :integer,
    artifacts_dir: :string,
    junit: :string,
    health: :boolean,
    fail_fast: :boolean,
    cookie: :string
  ]

  @rpc_timeout 5_000
  # Mob.Dist starts distribution about 3 s after a relaunched BEAM boots.
  @await_node_ms 15_000
  @await_interval_ms 500

  @impl Mix.Task
  def run(args), do: run(args, %{})

  @doc false
  # `deps` replaces the I/O: `:find_executable`, `:cmd` (exe, argv ->
  # {stdout, status}), `:discover` (platforms -> devices), `:connect`
  # (devices, cookie -> %{serial => node}), `:await_node` (device, node,
  # cookie -> node | nil, after a flow) and `:rpc` (node, m, f, a -> reply).
  @spec run([String.t()], map()) :: :ok
  def run(args, deps) do
    if TaskHelp.help_requested?(args) do
      TaskHelp.print_module_help(__MODULE__)
    else
      smoke(parse!(args), Map.merge(default_deps(), deps))
    end
  end

  defp parse!(args) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: @switches, aliases: [d: :device])

    unless invalid == [] and argv == [] do
      bad = Enum.map(invalid, &elem(&1, 0)) ++ argv
      Mix.raise("Unknown option(s) or argument(s): #{Enum.join(bad, ", ")}")
    end

    if Keyword.get(opts, :retries, 0) < 0, do: Mix.raise("--retries must be 0 or more")
    opts
  end

  defp smoke(opts, deps) do
    flows_arg = opts[:flows] || "smoke"
    flows = Path.expand(flows_arg)
    flow_files = flows |> Path.join("*.ad") |> Path.wildcard() |> Enum.sort()

    if flow_files == [], do: Mix.raise(Smoke.no_flows_message(flows_arg))

    exe =
      deps.find_executable.("agent-device") ||
        Mix.raise("agent-device is not on PATH. Install it with: npm i -g agent-device")

    Mix.Task.run("app.config")
    devices = select_devices!(opts, deps)
    health? = Keyword.get(opts, :health, true)
    cookie = opts[:cookie]

    ctx = %{
      exe: exe,
      flows: flows,
      flow_files: flow_files,
      deps: deps,
      cookie: cookie,
      health?: health?,
      nodes: if(health?, do: deps.connect.(devices, cookie), else: %{}),
      artifacts_root: Path.expand(opts[:artifacts_dir] || "_build/mob_smoke"),
      junit: opts[:junit] && Path.expand(opts[:junit]),
      retries: Keyword.get(opts, :retries, 0),
      fail_fast?: opts[:fail_fast] == true
    }

    results = Enum.map(devices, &smoke_device(&1, ctx))

    IO.puts("\nSummary")
    Enum.each(Smoke.summary_lines(results), &IO.puts("  " <> &1))

    case Smoke.verdict(results) do
      :ok -> IO.puts("\nAll flows passed and the app held up.")
      {:error, failures} -> Mix.raise("mob.smoke failed:\n  " <> Enum.join(failures, "\n  "))
    end

    :ok
  end

  defp select_devices!(opts, deps) do
    platforms =
      case Connect.resolve_platforms(opts, MobDev.Config.platforms()) do
        {:ok, platforms} -> platforms
        {:error, message} -> Mix.raise(message)
      end

    ids = Keyword.get_values(opts, :device) ++ Keyword.get_values(opts, :only)

    case TaskTargets.resolve(deps.discover.(platforms), ids, opts) do
      {:ok, devices} -> devices
      {:error, reason, context} -> Mix.raise(Deploy.target_error(reason, context, ids))
    end
  end

  defp smoke_device(%Device{serial: id} = device, ctx) do
    IO.puts("\n#{device.name || id} (#{id})")

    with {:ok, target} <- Smoke.device_target(device),
         :ok <- preflight(id, ctx) do
      if ctx.health?, do: run_each_flow(device, target, ctx), else: run_suite(device, target, ctx)
    else
      {:error, reason} ->
        IO.puts("  skipped: #{reason}")
        %{device: id, outcome: {:blocked, reason}, findings: [], receipts_delta: nil}
    end
  end

  # `agent-device test` takes a claim per script itself, so this only looks.
  # Holding a lease here would make every script's own session refuse the
  # device (REPLAY_DIVERGENCE "owned by session …").
  defp preflight(id, ctx) do
    {output, _status} = ctx.deps.cmd.(ctx.exe, ["device", "status", "--json"])

    case Smoke.find_claim(output, id) do
      {:ok, nil} -> :ok
      {:ok, claim} -> {:error, Smoke.claim_message(claim)}
      {:error, reason} -> {:error, "could not read device claims: #{reason}"}
    end
  end

  defp run_suite(%Device{serial: id} = device, target, ctx) do
    {report, status} = run_script(Path.join(ctx.flows, "*.ad"), nil, device, target, ctx)
    %{device: id, outcome: {:ran, report, status}, findings: [], receipts_delta: nil}
  end

  defp run_each_flow(%Device{serial: id} = device, target, ctx) do
    node = Map.get(ctx.nodes, id)
    start = %{node: node, snapshot: snapshot(node, ctx.deps), runs: []}

    acc =
      Enum.reduce_while(ctx.flow_files, start, fn flow, acc ->
        run = run_flow(flow, device, target, acc, ctx)
        acc = %{node: run.node || acc.node, snapshot: run.snapshot, runs: [run | acc.runs]}

        flow_result = %{
          device: device.serial,
          outcome: {:ran, run.report, run.status},
          findings: run.findings,
          receipts_delta: run.delta
        }

        if ctx.fail_fast? and Smoke.failed?(flow_result),
          do: {:halt, acc},
          else: {:cont, acc}
      end)

    runs = Enum.reverse(acc.runs)
    skipped = length(ctx.flow_files) - length(runs)

    reports =
      Enum.map(runs, & &1.report) ++
        if(skipped > 0, do: [Smoke.not_run_report(skipped)], else: [])

    deltas = runs |> Enum.map(& &1.delta) |> Enum.reject(&is_nil/1)

    %{
      device: id,
      outcome: {:ran, Smoke.merge_reports(reports), runs |> Enum.map(& &1.status) |> Enum.max()},
      findings: runs |> Enum.flat_map(& &1.findings) |> Enum.uniq(),
      receipts_delta: if(deltas == [], do: nil, else: Enum.sum(deltas))
    }
  end

  defp run_flow(flow, device, target, %{node: node, snapshot: before}, ctx) do
    name = Path.basename(flow)
    {report, status} = run_script(flow, flow, device, target, ctx)
    node_after = node && ctx.deps.await_node.(device, node, ctx.cookie)
    after_flow = snapshot(node_after, ctx.deps)
    delta = Smoke.receipts_delta(before, after_flow)

    findings =
      (Smoke.health_findings(before, after_flow) ++
         Smoke.receipt_findings(before, after_flow, report.executed))
      |> Enum.map(fn
        {:note, message} -> {:note, message}
        {kind, message} -> {kind, "#{name}: #{message}"}
      end)

    Enum.each(findings, fn {kind, message} -> IO.puts("  #{kind}: #{message}") end)
    if delta, do: IO.puts("  #{name}: receipts +#{delta}")

    %{
      report: report,
      status: status,
      findings: findings,
      delta: delta,
      node: node_after,
      snapshot: after_flow
    }
  end

  defp run_script(script, flow, device, target, ctx) do
    paths = Smoke.run_paths(ctx.artifacts_root, ctx.junit, device.serial, flow)

    argv =
      Smoke.test_argv(script, target,
        artifacts_dir: paths.artifacts_dir,
        junit: paths.junit,
        retries: ctx.retries,
        # Per-flow runs are one script each; the stop is decided here.
        fail_fast: ctx.fail_fast? and flow == nil
      )

    IO.puts("  agent-device " <> Enum.join(argv, " "))
    {output, status} = ctx.deps.cmd.(ctx.exe, argv)

    report =
      case Smoke.parse_report(output) do
        {:ok, report} -> report
        {:error, error} -> Smoke.refused_report(script, error)
      end

    print_report(report, device)
    {report, status}
  end

  defp snapshot(nil, _deps) do
    unreachable = {:unreachable, "node not reachable"}
    %{health: unreachable, beam: unreachable}
  end

  defp snapshot(node, deps) do
    %{
      health: Smoke.classify_reply(deps.rpc.(node, Mob.Diag, :health, [])),
      beam: Smoke.classify_reply(deps.rpc.(node, :os, :getpid, []))
    }
  end

  defp print_report(report, device) do
    IO.puts(
      "  #{report.passed} passed, #{report.failed} failed, #{report.not_run} not run " <>
        "of #{report.total} (#{report.duration_ms} ms)"
    )

    Enum.each(report.failures, fn failure ->
      IO.puts("  ✗ #{failure.file} [#{failure.code}] #{failure.message}")
      Enum.each(Smoke.failure_hints(failure, device), &IO.puts("    hint: " <> &1))
      if failure.artifacts_dir, do: IO.puts("    artifacts: " <> failure.artifacts_dir)
    end)
  end

  defp default_deps do
    %{
      find_executable: &System.find_executable/1,
      cmd: fn exe, argv -> System.cmd(exe, argv) end,
      discover: &Deploy.discover_devices/1,
      connect: &connect/2,
      await_node: &await_node/3,
      rpc: fn node, mod, fun, args -> :rpc.call(node, mod, fun, args, @rpc_timeout) end
    }
  end

  # Attach without restarting: the flows expect the running app, and the
  # first comparison is against the BEAM that is up now.
  defp connect(devices, cookie) do
    {connected, _failed} =
      Connector.connect_all(
        cookie: cookie,
        only: Enum.map(devices, & &1.serial),
        platforms: devices |> Enum.map(& &1.platform) |> Enum.uniq(),
        restart: false
      )

    Map.new(connected, &{&1.serial, &1.node})
  end

  # A relaunched app comes back under the same node name when the deploy-time
  # environment survives; a launcher start on Android can register the bare
  # `<app>_android` on another port, which only re-attaching (EPMD lookup plus
  # a new forward) finds.
  defp await_node(device, node, cookie) do
    poll_node(node, @await_node_ms) || Map.get(connect([device], cookie), device.serial)
  end

  defp poll_node(_node, remaining) when remaining <= 0, do: nil

  defp poll_node(node, remaining) do
    if Node.connect(node) == true do
      node
    else
      Process.sleep(@await_interval_ms)
      poll_node(node, remaining - @await_interval_ms)
    end
  end
end
