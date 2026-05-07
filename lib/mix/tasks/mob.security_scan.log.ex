defmodule Mix.Tasks.Mob.SecurityScan.Log do
  @shortdoc "Run mix mob.security_scan and update SECURITY_SCAN.md / SECURITY_HISTORY.md"

  @moduledoc """
  Scheduled-run helper for the security scan. Designed to be invoked
  by cron, GitHub Actions, or any other recurring trigger.

  Each run does four things:

    1. Runs the full `mix mob.security_scan` against the project.
    2. **Overwrites** `SECURITY_SCAN.md` — a current-state snapshot
       you can point at to answer "what's the situation right now?".
    3. **Prepends** a changelog entry to `SECURITY_HISTORY.md` —
       newest at the top — describing what's New / Resolved / Still
       present since the last logged run.
    4. Updates the JSON state sidecar at `.security_scan/state.json`
       so the next run can compute its diff.

  Commit all three files. The state file is what makes the changelog
  meaningful across machines and CI runs — without it every scheduled
  run reports every finding as "new" and the history loses signal.

  ## Usage

      mix mob.security_scan.log                      # default paths
      mix mob.security_scan.log --scan SECURITY.md \\
          --history HISTORY.md \\
          --state .scan/state.json
      mix mob.security_scan.log --strict             # exit 1 if any high+ finding

  ## Suggested cron entry

      # daily at 06:00 local
      0 6 * * *  cd /path/to/project && mix mob.security_scan.log >> /tmp/security_scan.log 2>&1

  ## Suggested GitHub Actions workflow

      name: security-scan
      on:
        schedule: [{cron: "0 6 * * *"}]
        workflow_dispatch:
      jobs:
        scan:
          runs-on: macos-latest
          steps:
            - uses: actions/checkout@v4
            - uses: erlef/setup-beam@v1
              with: {elixir-version: "1.19", otp-version: "28"}
            - run: brew install osv-scanner semgrep flawfinder detekt swiftlint
            - run: mix deps.get
            - run: mix mob.security_scan.log
            - uses: peter-evans/create-pull-request@v6
              with:
                title: "security: weekly scan update"
                commit-message: "security: weekly scan update"
                branch: security-scan-update
                add-paths: SECURITY_SCAN.md SECURITY_HISTORY.md .security_scan/state.json
  """

  use Mix.Task

  alias MobDev.SecurityScan
  alias MobDev.SecurityScan.{Diff, Formatter, HistoryFormatter, Report, StateFile}

  @switches [
    scan: :string,
    history: :string,
    state: :string,
    project_root: :string,
    strict: :boolean,
    skip: :string
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: @switches)

    project_root = opts[:project_root] || File.cwd!()
    scan_path = opts[:scan] || Path.join(project_root, "SECURITY_SCAN.md")
    history_path = opts[:history] || Path.join(project_root, "SECURITY_HISTORY.md")
    state_path = opts[:state] || Path.join(project_root, ".security_scan/state.json")

    skip = parse_skip(opts[:skip])
    now = DateTime.utc_now()

    Mix.shell().info("→ scanning #{project_root}")
    report = SecurityScan.run(project_root: project_root, skip: skip)

    prev_state = StateFile.load(state_path)
    diff = Diff.compute(prev_state, report, now)

    Mix.shell().info(
      "→ diff: +#{length(diff.new)} new / -#{length(diff.resolved)} resolved / =#{length(diff.still_present)} still present"
    )

    File.write!(scan_path, Formatter.markdown(report))
    Mix.shell().info("→ wrote #{scan_path}")

    HistoryFormatter.prepend_to_file(history_path, HistoryFormatter.entry(report, diff, now))
    Mix.shell().info("→ updated #{history_path}")

    next_state = StateFile.from_report(report, diff, now)
    StateFile.save(state_path, next_state)
    Mix.shell().info("→ saved #{state_path}")

    maybe_exit_strict(report, opts[:strict])
  end

  defp parse_skip(nil), do: []

  defp parse_skip(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&(&1 |> String.trim() |> String.to_atom()))
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
