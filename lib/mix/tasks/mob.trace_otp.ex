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
        strict: [phase: :string, json: :string]
      )

    phase = parse_phase(opts[:phase] || "all")

    Mix.Task.run("loadpaths")
    Mix.Task.run("compile")

    # Force-load the harness so its compile-time work doesn't appear
    # in the trace — we want runtime behaviour only.
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
    Mix.shell().info("  Wall time:        #{format_us(result.elapsed_us)}")

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

  defp format_us(us) when us < 1_000, do: "#{us}μs"
  defp format_us(us) when us < 1_000_000, do: "#{Float.round(us / 1_000, 1)}ms"
  defp format_us(us), do: "#{Float.round(us / 1_000_000, 2)}s"
end
