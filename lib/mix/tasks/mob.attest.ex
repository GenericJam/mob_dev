defmodule Mix.Tasks.Mob.Attest do
  @shortdoc "Prove the device is running the code you just pushed"

  @moduledoc """
  Compare a connected device's loaded modules against this build.

      mix mob.connect --no-iex      # set up the tunnel first
      mix mob.attest
      mix mob.attest --json
      mix mob.attest --app my_app   # only this application's modules

  ## Why

  `mix mob.deploy` reports what it did, not what is now true. The case this
  was written for: two bundle ids diverged, the BEAM push addressed one app's
  container while another app was running, and it **succeeded** — a tick, no
  error, and the app carrying on with the old code. Both containers existed, so
  every step was honest about itself and the run as a whole was a lie.

  `module_info(:md5)` on the device is the same digest `:beam_lib.md5/1` gives
  for the local `.beam`. Comparing them catches a push that never landed, landed
  in the wrong place, or landed and was never loaded.

  ## Options

    * `--app NAME`  — restrict to one application (default: the project's own)
    * `--node NAME` — attest one node instead of every connected one
    * `--json`      — machine-readable result on stdout, progress on stderr

  ## Exit status

  Non-zero when any module on the device differs from this build, or when the
  check could not run — a check that could not run must not report success.

  Modules the device has not loaded yet are reported and are **not** a failure.
  Interactive BEAM loads a module when something first calls it, so most of a
  bundle is legitimately unloaded at any moment.
  """

  use Mix.Task

  alias MobDev.Attest

  @switches [app: :string, node: :string, json: :boolean]

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches, aliases: [n: :node])

    unless invalid == [] do
      Mix.raise("Unknown option(s): #{invalid |> Enum.map(&elem(&1, 0)) |> Enum.join(", ")}")
    end

    if opts[:json] do
      Process.put(:attest_stdout, Process.group_leader())
      Process.group_leader(self(), Process.whereis(:standard_error))
    end

    Mix.Task.run("compile")
    start_dist!()

    case reachable_nodes(opts) do
      [] ->
        emit(opts, %{"outcome" => "no_nodes", "nodes" => []})

        Mix.raise("""
        No device answered, so nothing was attested.

        Run `mix mob.connect --no-iex` first. Reporting success here would be
        the failure this task exists to catch: a check that could not run is
        not a check that passed.
        """)

      nodes ->
        results = Enum.map(nodes, &attest_node(&1, opts))
        report(results, opts)
    end
  end

  # Connect without restarting anything. `Connector.connect_all/1` restarts the
  # app, which reloads every module and would destroy the very evidence this
  # task exists to read. The tunnels a previous `mix mob.connect` set up are
  # device-level and outlive it, so a plain `Node.connect/1` is enough.
  defp reachable_nodes(opts) do
    candidates =
      case opts[:node] do
        nil -> discover_node_names()
        name -> [String.to_atom(name)]
      end

    {up, down} = Enum.split_with(candidates, &Node.connect/1)

    for node <- down do
      IO.puts("#{node}: unreachable — run `mix mob.connect --no-iex` first")
    end

    up
  end

  defp discover_node_names do
    (MobDev.Discovery.Android.list_devices() ++ MobDev.Discovery.IOS.list_devices())
    |> Enum.map(&MobDev.Device.node_name/1)
    |> Enum.uniq()
  end

  defp start_dist!() do
    unless Node.alive?() do
      MobDev.Connector.start_epmd()

      MobDev.Connector.handle_dist_start(
        Node.start(:"mob_attest@127.0.0.1", :longnames),
        :mob_secret
      )
    end
  end

  defp attest_node(node, opts) do
    app = String.to_atom(opts[:app] || to_string(Mix.Project.config()[:app]))
    findings = Enum.map(beams(app), &finding(node, &1))

    %{node: node, app: app, findings: findings, verdict: Attest.verdict(findings)}
  end

  defp finding(node, path) do
    case Attest.local_digest(path) do
      nil ->
        Attest.compare(module_from_path(path), nil, nil)

      {module, expected} ->
        Attest.compare(module, expected, remote_digest(node, module))
    end
  end

  # `module_info(:md5)` raises :undef for a module the device has never
  # loaded, which arrives here as a badrpc EXIT rather than a value.
  defp remote_digest(node, module), do: :rpc.call(node, module, :module_info, [:md5], 10_000)

  defp module_from_path(path), do: path |> Path.basename(".beam") |> String.to_atom()

  defp beams(app) do
    Mix.Project.build_path()
    |> Path.join("lib/#{app}/ebin/*.beam")
    |> Path.wildcard()
  end

  defp report(results, opts) do
    Enum.each(results, &say_node/1)

    failed = Enum.filter(results, &match?({:error, _}, &1.verdict))

    emit(opts, %{
      "outcome" => if(failed == [], do: "ok", else: "mismatch"),
      "nodes" => Enum.map(results, &json_node/1)
    })

    unless failed == [] do
      Mix.raise(
        failed
        |> Enum.map(fn r -> "#{r.node}: #{elem(r.verdict, 1)}" end)
        |> Enum.join("\n")
      )
    end
  end

  defp say_node(%{node: node, findings: findings, verdict: verdict}) do
    t = Attest.tally(findings)

    IO.puts(
      "#{node}: #{t.match} match, #{t.stale} stale, #{t.missing} not loaded, " <>
        "#{t.unreadable} unreadable"
    )

    for f <- findings, f.verdict in [:stale, :unreadable] do
      IO.puts("  #{f.verdict}: #{inspect(f.module)}")
    end

    case verdict do
      :ok -> IO.puts("  the device is running this build")
      {:error, message} -> IO.puts("  #{message}")
    end
  end

  defp json_node(%{node: node, app: app, findings: findings, verdict: verdict}) do
    %{
      "node" => to_string(node),
      "app" => to_string(app),
      "outcome" => if(verdict == :ok, do: "ok", else: "mismatch"),
      "message" => if(verdict == :ok, do: nil, else: elem(verdict, 1)),
      "tally" => Map.new(Attest.tally(findings), fn {k, v} -> {to_string(k), v} end),
      "modules" =>
        for f <- findings, f.verdict != :match do
          %{"module" => inspect(f.module), "verdict" => to_string(f.verdict)}
        end
    }
  end

  defp emit(opts, payload) do
    if opts[:json] do
      IO.puts(Process.get(:attest_stdout, :standard_io), Jason.encode!(payload, pretty: true))
    end
  end
end
