defmodule Mix.Tasks.Mob.SnapshotLoaded do
  @shortdoc "Snapshot what's loaded on a connected device — empirical strip candidates"

  @moduledoc """
  Asks a connected device's BEAM what modules it has loaded right now.
  In interactive mode (Mob's default), a module is loaded only when
  something calls into it — so the loaded set after a real user session
  is the empirical "actually used" set.

  Anything **shipped but never loaded** is a strong strip candidate.
  Combine with `mix mob.audit_otp` (static reachability) for the
  highest-confidence strip set:

      shipped ∩ statically-reachable ∩ NEVER-loaded = safe to strip

  ## Workflow

      mix mob.deploy                    # deploy the app
      # Use the app — every flow you care about
      mix mob.connect --no-iex          # set up the dist tunnel
      mix mob.snapshot_loaded           # snapshot
      mix mob.snapshot_loaded --json out.json  # machine-readable

  ## What the report shows

    * Total .beam files shipped
    * Modules currently loaded
    * Modules in the bundle that have never been loaded
    * Per-OTP-lib breakdown (which libs have any module loaded vs not)

  ## What this is NOT

  Not a trace — it doesn't tell you *which* function was called or how
  often. Just whether the module was touched. For per-function or
  per-call-frequency data, use `mix mob.trace_otp` (host-side harness)
  or extend `Mob.Diag` with `:recon_trace`-based on-device tracing.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [node: :string, json: :string])

    Mix.Task.run("loadpaths")
    Mix.Task.run("compile")

    node = resolve_node(opts[:node])

    case :rpc.call(node, Mob.Diag, :loaded_snapshot, []) do
      {:badrpc, reason} ->
        Mix.shell().error("RPC failed: #{inspect(reason)}")

        Mix.shell().error("""

        Is the device's mob library new enough to have Mob.Diag.loaded_snapshot/0?
        Push the latest BEAMs:  mix mob.push
        """)

        exit({:shutdown, 1})

      snapshot ->
        if opts[:json] do
          File.write!(opts[:json], encode_json(snapshot))
          Mix.shell().info("Wrote snapshot to #{opts[:json]}")
        else
          print_summary(snapshot)
        end
    end
  end

  defp resolve_node(nil) do
    case Node.list() do
      [] ->
        Mix.raise("""
        No connected nodes found. Run `mix mob.connect --no-iex` first
        in another terminal so the device's BEAM is reachable.

        Or pass --node <name@host> explicitly.
        """)

      [single] ->
        single

      multiple ->
        Mix.raise("""
        Multiple nodes connected — specify with --node:

        #{Enum.map_join(multiple, "\n", &"  #{&1}")}
        """)
    end
  end

  defp resolve_node(node_str), do: String.to_atom(node_str)

  defp encode_json(snapshot) do
    %{
      otp_root: snapshot.otp_root,
      captured_at: DateTime.to_iso8601(snapshot.captured_at),
      loaded_count: snapshot.loaded_count,
      shipped_count: snapshot.shipped_count,
      loaded: Enum.map(snapshot.loaded, &to_string/1),
      unloaded_in_bundle: Enum.map(snapshot.unloaded_in_bundle, &to_string/1)
    }
    |> Jason.encode!(pretty: true)
  end

  defp print_summary(s) do
    h1 = IO.ANSI.bright()
    yellow = IO.ANSI.yellow()
    green = IO.ANSI.green()
    reset = IO.ANSI.reset()

    Mix.shell().info("#{h1}=== Loaded-modules snapshot ==={reset}")
    Mix.shell().info("  OTP root:     #{s.otp_root || "(not detected)"}")
    Mix.shell().info("  Captured at:  #{DateTime.to_iso8601(s.captured_at)}")
    Mix.shell().info("  Shipped:      #{s.shipped_count} .beam files")
    Mix.shell().info("  Loaded:       #{s.loaded_count} modules")

    Mix.shell().info(
      "  Strip candidates (shipped, never loaded): #{length(s.unloaded_in_bundle)}\n"
    )

    by_lib = group_by_lib(s.unloaded_in_bundle)

    if by_lib == %{} do
      Mix.shell().info(
        "  #{green}Every shipped module has been loaded — no strip candidates from this snapshot.#{reset}"
      )
    else
      Mix.shell().info("#{h1}Strip candidates by lib (top 20):#{reset}")

      by_lib
      |> Enum.sort_by(fn {_lib, mods} -> -length(mods) end)
      |> Enum.take(20)
      |> Enum.each(fn {lib, mods} ->
        Mix.shell().info(
          "  #{yellow}#{String.pad_trailing(to_string(lib), 25)}#{reset}  " <>
            "#{length(mods)} unused module(s)"
        )
      end)
    end

    Mix.shell().info("""

    Cross-reference with `mix mob.audit_otp` for the highest-confidence
    strip set:  shipped + statically-reachable + NEVER loaded.
    """)
  end

  # Heuristic lib grouping from module name patterns. Not perfect, but
  # good enough for a summary view.
  defp group_by_lib(modules) do
    Enum.group_by(modules, fn mod ->
      mod
      |> to_string()
      |> guess_lib()
    end)
  end

  defp guess_lib(name) do
    cond do
      String.starts_with?(name, "Elixir.") ->
        # "Elixir.Logger.Foo" → "elixir/logger"
        rest = String.replace_prefix(name, "Elixir.", "")
        rest |> String.split(".") |> List.first() |> Macro.underscore()

      true ->
        # "logger_h_common" → "logger" by stripping after first underscore
        case String.split(name, "_", parts: 2) do
          [head | _] -> head
          _ -> name
        end
    end
  end
end
