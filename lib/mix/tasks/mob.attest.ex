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

    * `--app NAME`  — narrow to one application. The default is everything
                      `mix mob.deploy` pushes, which is the only scope that
                      cannot drift from what was actually shipped
    * `--node NAME` — attest one node instead of every connected one
    * `--cookie C`  — dist cookie (default: `mob_secret`, as `Mob.Dist` sets)
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

  @switches [app: :string, node: :string, cookie: :string, json: :boolean]

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches, aliases: [n: :node])

    unless invalid == [] do
      Mix.raise("Unknown option(s): #{invalid |> Enum.map(&elem(&1, 0)) |> Enum.join(", ")}")
    end

    if opts[:json] do
      Process.put(:attest_stdout, Process.group_leader())

      case Process.whereis(:standard_error) do
        nil -> Mix.raise("--json needs :standard_error, which is not registered in this VM")
        pid -> Process.group_leader(self(), pid)
      end
    end

    Mix.Task.run("compile")
    start_dist!(String.to_atom(opts[:cookie] || "mob_secret"))

    case reachable_nodes(opts) do
      {[], _down} ->
        emit(opts, %{"outcome" => "no_nodes", "nodes" => []})

        Mix.raise("""
        No device answered, so nothing was attested.

        Run `mix mob.connect --no-iex` first. Reporting success here would be
        the failure this task exists to catch: a check that could not run is
        not a check that passed.
        """)

      {nodes, down} ->
        results = Enum.map(nodes, &attest_node(&1, opts))
        report(results, down, opts)
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

    # `Node.connect/1` returns `true | false | :ignored`, and `:ignored` — the
    # local node not being alive — is truthy. Matching on `true` keeps a run
    # that could not connect at all from looking like a run that connected to
    # everything.
    Enum.split_with(candidates, &(Node.connect(&1) == true))
  end

  # Use the name discovery already resolved rather than deriving one again.
  # `Device.node_name/1` and the discovery path disagree for WiFi-adb Android:
  # the former builds a suffix from the adb id (`10.0.0.17:5555` ->
  # `app_android_10_0_0_17`), the latter prefers `ro.serialno`
  # (`app_android_zy22k6bsjm`). That divergence is documented in
  # `discovery/android.ex` as a fixed bug; re-deriving reintroduced it, and the
  # symptom was a device silently landing in the unreachable list.
  defp discover_node_names do
    (MobDev.Discovery.Android.list_devices() ++ MobDev.Discovery.IOS.list_devices())
    |> Enum.map(& &1.node)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp start_dist!(cookie) do
    unless Node.alive?() do
      MobDev.Connector.start_epmd()
      MobDev.Connector.handle_dist_start(Node.start(:"mob_attest@127.0.0.1", :longnames), cookie)
    end
  end

  defp attest_node(node, opts) do
    scope = opts[:app] || "everything mob.deploy pushes"
    findings = Enum.map(beams(opts[:app]), &finding(&1, fn m -> remote_digest(node, m) end))

    %{
      node: node,
      app: scope,
      identity: identity(node),
      findings: findings,
      verdict: Attest.verdict(findings)
    }
  end

  # Say WHAT answered, not just that something did.
  #
  # The bug this task was written for is two containers with divergent bundle
  # ids built from one project: both register the same node-name pattern and
  # whichever wins the EPMD slot is what you reach, which may not be the one
  # you deployed to. Physical-device discovery also probes EPMD across the LAN,
  # so a colleague running the same project name is reachable. An attestation
  # that cannot name its subject proves less than it appears to.
  defp identity(node) do
    %{
      root: rpc_string(node, :init, :get_argument, [:root]),
      otp: rpc_string(node, :erlang, :system_info, [:otp_release]),
      code_mode: rpc_string(node, :code, :get_mode, [])
    }
  end

  defp rpc_string(node, m, f, a) do
    case :rpc.call(node, m, f, a, 5_000) do
      {:badrpc, _} -> "unknown"
      value -> value |> inspect() |> String.slice(0, 120)
    end
  end

  @doc false
  # Takes the digest fetcher so the wiring is testable without a device. This
  # was the whole of the task's logic and none of it had a test: replacing
  # `remote_digest` with `expected` would have reported 100% match on every
  # run, with the suite green.
  @spec finding(Path.t(), (module() -> term())) :: Attest.finding()
  def finding(path, fetch) do
    case Attest.local_digest(path) do
      nil -> Attest.compare(module_from_path(path), nil, nil)
      {module, expected} -> Attest.compare(module, expected, fetch.(module))
    end
  end

  # `module_info(:md5)` raises :undef for a module the device cannot find,
  # which arrives here as a badrpc EXIT rather than a value.
  defp remote_digest(node, module), do: :rpc.call(node, module, :module_info, [:md5], 10_000)

  @doc false
  @spec module_from_path(Path.t()) :: module()
  def module_from_path(path), do: path |> Path.basename(".beam") |> String.to_atom()

  # Default to exactly the set `mix mob.deploy` pushes, so what is attested and
  # what was shipped cannot drift apart. Scoping to the project's own app —
  # the first version of this — would have reported :ok on MOB-161, because
  # those twelve stale modules were in `mob`, a dependency. The evidence for
  # this task working was only obtainable with a non-default flag.
  #
  # `--app` narrows that set rather than replacing it, and an --app naming
  # nothing raises: a glob that matches no files produced an empty finding
  # list, and an empty finding list used to be a pass.
  defp beams(nil) do
    MobDev.HotPush.runtime_beam_dirs()
    |> Enum.flat_map(&Path.wildcard(Path.join(&1, "*.beam")))
  end

  defp beams(app) do
    case Enum.filter(beams(nil), &(Path.basename(Path.dirname(Path.dirname(&1))) == app)) do
      [] ->
        Mix.raise("""
        --app #{app} matched no beams in anything mob.deploy pushes.

        Attesting nothing and reporting success is the failure this task
        exists to catch, so this refuses instead. Run without --app to check
        everything, or `mix mob.devices` to confirm you are in the right
        project.
        """)

      beams ->
        beams
    end
  end

  defp report(results, down, opts) do
    Enum.each(results, &say_node/1)
    Enum.each(down, &IO.puts("#{&1}: unreachable — nothing was checked on it"))

    failed = Enum.filter(results, &match?({:error, _}, &1.verdict))

    emit(opts, %{
      "outcome" => outcome(failed, down),
      "nodes" =>
        Enum.map(results, &json_node/1) ++
          Enum.map(down, &%{"node" => to_string(&1), "outcome" => "unreachable"})
    })

    # A device that never answered is not a device that passed. Checking one
    # phone while another sits wedged, and reporting "ok", is the same shape as
    # a deploy that skips a target and exits 0.
    messages =
      Enum.map(failed, fn r -> "#{r.node}: #{elem(r.verdict, 1)}" end) ++
        Enum.map(down, fn n -> "#{n}: unreachable, so it was never checked" end)

    hint =
      if down == [],
        do: "",
        else:
          "\n\nEvery discovered device is a candidate. If you meant to check " <>
            "one, scope it:\n    mix mob.attest --node #{hd(down) |> to_string()}\n" <>
            "or connect the rest with `mix mob.connect --no-iex`."

    unless messages == [], do: Mix.raise(Enum.join(messages, "\n") <> hint)
  end

  @doc false
  # What a CI job reads. An unreachable device must never leave this "ok":
  # checking one phone while another sits wedged and reporting success is the
  # same shape as a deploy that skips a target and exits 0.
  @spec outcome([map()], [node()]) :: String.t()
  def outcome([], []), do: "ok"
  def outcome([], _down), do: "unreachable"
  def outcome(_failed, _down), do: "mismatch"

  defp say_node(%{node: node, findings: findings, verdict: verdict, identity: id}) do
    t = Attest.tally(findings)

    IO.puts(
      "#{node}: #{t.match} match, #{t.stale} stale, #{t.missing} not loaded, " <>
        "#{t.unreadable} unreadable"
    )

    IO.puts("  answered by: root=#{id.root} otp=#{id.otp} code=#{id.code_mode}")

    for f <- findings, f.verdict in [:stale, :unreadable] do
      IO.puts("  #{f.verdict}: #{inspect(f.module)}")
    end

    case verdict do
      :ok -> IO.puts("  the device is running this build")
      {:error, message} -> IO.puts("  #{message}")
    end
  end

  defp json_node(%{node: node, app: app, findings: findings, verdict: verdict, identity: id}) do
    %{
      "node" => to_string(node),
      "app" => to_string(app),
      "identity" => %{"root" => id.root, "otp" => id.otp, "code_mode" => id.code_mode},
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
