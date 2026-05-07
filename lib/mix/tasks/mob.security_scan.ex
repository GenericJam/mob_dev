defmodule Mix.Tasks.Mob.SecurityScan do
  @shortdoc "Comprehensive security scan of a Mob app's dependencies, bundled runtime, and source"

  @moduledoc """
  Audits the project for known vulnerabilities and unsafe code across
  every surface a Mob app actually ships:

    * Hex dependency CVEs (`mix_audit`, `osv-scanner` over `mix.lock`)
    * Android Gradle dependency CVEs (`osv-scanner`)
    * iOS Swift Package dependency CVEs (`osv-scanner`)
    * Bundled-runtime CVEs — OpenSSL/SQLite/OTP/Elixir baked into
      Mob's pre-built OTP tarballs (manifest + fingerprint verification +
      OpenSSL/SQLite/Erlef advisory feeds)
    * C source static analysis (semgrep, flawfinder)
    * Kotlin static analysis (detekt)
    * Swift static analysis (`xcodebuild analyze`)

  Layers run sequentially. A missing external scanner is a soft warning,
  not a failure — the layer reports `tool missing` and the rest of the
  scan continues.

  ## Usage

      mix mob.security_scan                       # full scan, pretty terminal output
      mix mob.security_scan --json                # machine-readable JSON to stdout
      mix mob.security_scan --skip hex,gradle     # skip named layers
      mix mob.security_scan --strict              # exit 1 if any high+ finding
      mix mob.security_scan --write-report PATH   # also write a markdown report

  ## External tools

  Recommended one-time install on macOS:

      brew install osv-scanner semgrep flawfinder detekt

  Each layer prints which tool produced its findings so the report
  is fully sourced.

  ## Why "security_scan" not "audit"

  `mix mob.audit_otp` already exists and does something else — it
  reports which OTP libs your bundled app doesn't use so they can be
  stripped to shrink the binary. That's a *binary-size* audit. This
  task is the *security* counterpart, deliberately named differently.
  """

  use Mix.Task

  alias MobDev.SecurityScan
  alias MobDev.SecurityScan.{Formatter, Report}

  @switches [
    json: :boolean,
    strict: :boolean,
    skip: :string,
    write_report: :string,
    project_root: :string
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: @switches)

    skip = parse_skip(opts[:skip])
    project_root = opts[:project_root] || File.cwd!()

    run_opts = [
      project_root: project_root,
      skip: skip,
      on_layer_start: &on_layer_start(&1, opts),
      on_layer_done: &on_layer_done(&1, opts)
    ]

    report = SecurityScan.run(run_opts)

    cond do
      opts[:json] ->
        IO.puts(Formatter.json(report))

      true ->
        IO.write(Formatter.terminal(report))
    end

    if path = opts[:write_report] do
      Mix.shell().info(
        "(markdown report writer not yet implemented; --write-report #{path} ignored)"
      )
    end

    maybe_exit_strict(report, opts[:strict])
  end

  defp parse_skip(nil), do: []

  defp parse_skip(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&(&1 |> String.trim() |> String.to_atom()))
  end

  defp on_layer_start(_name, opts) do
    if opts[:json], do: :ok, else: :ok
  end

  defp on_layer_done(_layer, opts) do
    if opts[:json], do: :ok, else: :ok
  end

  defp maybe_exit_strict(_report, nil), do: :ok
  defp maybe_exit_strict(_report, false), do: :ok

  defp maybe_exit_strict(report, true) do
    case Report.worst_severity(report) do
      sev when sev in [:critical, :high, :medium] ->
        Mix.shell().error("--strict: #{sev} finding(s) present")
        exit({:shutdown, 1})

      _ ->
        :ok
    end
  end
end
