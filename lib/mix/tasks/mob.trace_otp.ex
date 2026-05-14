defmodule Mix.Tasks.Mob.TraceOtp do
  @shortdoc "Run the Elixir characterization harness under trace, dump touched MFAs"

  @moduledoc """
  Runs `MobDev.OtpTrace.Harness` under full call tracing and reports
  the runtime modules + MFAs actually exercised.

  This is the empirical complement to `mix mob.audit_otp` (which uses
  static reachability). Combined, they give a high-confidence answer
  to "what does any Elixir runtime actually need."

  ## Usage

      mix mob.trace_otp                 # Run all phases, summary report
      mix mob.trace_otp --phase otp     # Just one phase
      mix mob.trace_otp --json out.json # Machine-readable dump

      # Trace a real running app on a connected device for 30s.
      # First run `mix mob.connect` in another terminal.
      mix mob.trace_otp --remote pigeon_ios_defd4bdc@127.0.0.1 --duration 30000

  Local mode (default) runs a synthetic Elixir/OTP characterization
  harness inside the host BEAM. Remote mode wraps `:erlang.trace_pattern`
  on a connected device node and captures the MFAs hit during a real
  user session — drive the app interactively while the trace runs.

  ## Phases

      language     — pattern match, comprehensions, structs, protocols
      collections  — Enum, List, Map, MapSet, Stream, Range
      strings      — String, Binary, charlist, codepoints
      processes    — spawn, send/receive, monitor, link, Task
      otp          — GenServer, Supervisor, Application, Logger
      data         — ETS, persistent_term, Date/Time, System
      errors       — raise/rescue, throw/catch, exit, exception structs
      all          — every phase (default)

  ## Output

  Plain mode prints a summary + sorted module list. `--json` writes a
  JSON file with the full MFA set, suitable for cross-referencing
  against the static audit (`mix mob.audit_otp`) to find modules
  shipped-but-never-called.
  """

  use Mix.Task

  alias MobDev.OtpTrace
  alias MobDev.OtpTrace.Harness

  @phases ~w(language collections strings processes otp data errors all)a

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [phase: :string, json: :string, remote: :string, duration: :integer]
      )

    Mix.Task.run("loadpaths")
    Mix.Task.run("compile")

    if opts[:remote] do
      run_remote(opts)
    else
      run_local(opts)
    end
  end

  # ── Local synthetic-harness trace ────────────────────────────────────────────

  defp run_local(opts) do
    phase = parse_phase(opts[:phase] || "all")

    Code.ensure_all_loaded([
      Harness,
      Harness.HarnessStruct,
      Harness.HarnessProto,
      Harness.HarnessGS,
      Harness.HarnessApp
    ])

    Mix.shell().info("Running Elixir characterization harness under trace…")
    Mix.shell().info("  Phase: #{phase}\n")

    result = OtpTrace.capture(fn -> apply(Harness, phase, []) end)

    if opts[:json] do
      write_json(result, opts[:json])
      Mix.shell().info("Wrote #{opts[:json]}")
    else
      print_summary(result, phase)
    end
  end

  # ── Remote (real-app) trace ──────────────────────────────────────────────────

  defp run_remote(opts) do
    node_str = opts[:remote]
    duration = opts[:duration] || 30_000
    node = String.to_atom(node_str)

    ensure_distribution_started!()

    Mix.shell().info("Tracing #{node_str} for #{duration / 1000}s…")
    Mix.shell().info("  Drive the app on the device while the window is open.\n")

    case :rpc.call(node, Mob.Diag, :mfa_trace, [duration]) do
      {:badrpc, reason} ->
        Mix.shell().error("RPC failed: #{inspect(reason)}")

        Mix.shell().error("""

        Is the device connected?  Try `mix mob.connect` in another
        terminal first, then re-run this command.
        """)

        exit({:shutdown, 1})

      result ->
        if opts[:json] do
          write_remote_json(result, opts[:json])
          Mix.shell().info("Wrote #{opts[:json]}")
        else
          print_remote_summary(result, node)
        end
    end
  end

  defp print_remote_summary(result, node) do
    h1 = IO.ANSI.bright()
    dim = IO.ANSI.faint()
    reset = IO.ANSI.reset()

    Mix.shell().info("#{h1}=== Remote trace summary ==={reset}")
    Mix.shell().info("  Node:             #{node}")
    Mix.shell().info("  Duration:         #{result.duration_ms / 1000}s")
    Mix.shell().info("  Modules touched:  #{result.module_count}")
    Mix.shell().info("  Unique MFAs:      #{result.mfa_count}")

    Mix.shell().info("\n#{h1}=== Modules touched (sorted) ==={reset}\n")

    {elixir, erlang} =
      result.modules
      |> Enum.split_with(&String.starts_with?(to_string(&1), "Elixir."))

    Mix.shell().info("  #{dim}Elixir modules (#{length(elixir)}):#{reset}")
    for m <- elixir, do: Mix.shell().info("    #{inspect(m)}")
    Mix.shell().info("\n  #{dim}Erlang modules (#{length(erlang)}):#{reset}")
    for m <- erlang, do: Mix.shell().info("    #{inspect(m)}")
    Mix.shell().info("")
  end

  # mix doesn't start distribution by default. Without it, :rpc.call
  # returns {:badrpc, :nodedown} even though the target node is alive
  # and registered in EPMD. Self-name into a unique node so multiple
  # invocations don't collide.
  defp ensure_distribution_started! do
    if Node.alive?() do
      :ok
    else
      name = :"mob_trace_otp_#{System.unique_integer([:positive])}@127.0.0.1"

      case Node.start(name, :longnames) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Mix.raise("Failed to start distribution: #{inspect(reason)}")
      end
    end

    Node.set_cookie(:mob_secret)
  end

  defp write_remote_json(result, path) do
    payload = %{
      mfas:
        result.mfas
        |> Enum.map(fn {m, f, a} -> [to_string(m), to_string(f), a] end),
      modules: Enum.map(result.modules, &to_string/1),
      mfa_count: result.mfa_count,
      module_count: result.module_count,
      duration_ms: result.duration_ms,
      captured_at: DateTime.to_iso8601(result.captured_at)
    }

    File.write!(path, Jason.encode!(payload, pretty: true))
  end

  defp parse_phase(name) do
    atom = String.to_existing_atom(name)

    if atom in @phases do
      atom
    else
      Mix.raise("Unknown phase: #{name}. Valid: #{Enum.join(@phases, ", ")}")
    end
  rescue
    ArgumentError ->
      Mix.raise("Unknown phase: #{name}. Valid: #{Enum.join(@phases, ", ")}")
  end

  defp print_summary(result, phase) do
    h1 = IO.ANSI.bright()
    dim = IO.ANSI.faint()
    reset = IO.ANSI.reset()

    Mix.shell().info("#{h1}=== Trace summary ==={reset}")
    Mix.shell().info("  Phase exercised:  #{phase}")
    Mix.shell().info("  Modules touched:  #{MapSet.size(result.modules)}")
    Mix.shell().info("  Unique MFAs:      #{MapSet.size(result.mfas)}")
    Mix.shell().info("  Wall time:        #{MobDev.Duration.format_us(result.elapsed_us)}")

    Mix.shell().info("\n#{h1}=== Modules touched (sorted) ==={reset}")

    {elixir, erlang} =
      result.modules
      |> Enum.sort()
      |> Enum.split_with(fn m -> String.starts_with?(to_string(m), "Elixir.") end)

    Mix.shell().info("\n  #{dim}Elixir modules (#{length(elixir)}):#{reset}")

    for m <- elixir do
      Mix.shell().info("    #{inspect(m)}")
    end

    Mix.shell().info("\n  #{dim}Erlang modules (#{length(erlang)}):#{reset}")

    for m <- erlang do
      Mix.shell().info("    #{inspect(m)}")
    end

    Mix.shell().info("")
  end

  defp write_json(result, path) do
    payload = %{
      modules: result.modules |> Enum.sort() |> Enum.map(&to_string/1),
      mfas:
        result.mfas
        |> Enum.sort()
        |> Enum.map(fn {m, f, a} -> [to_string(m), to_string(f), a] end),
      elapsed_us: result.elapsed_us,
      module_count: MapSet.size(result.modules),
      mfa_count: MapSet.size(result.mfas)
    }

    File.write!(path, Jason.encode!(payload, pretty: true))
  end
end
