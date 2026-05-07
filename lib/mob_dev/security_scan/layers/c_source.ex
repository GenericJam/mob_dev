defmodule MobDev.SecurityScan.Layers.CSource do
  @moduledoc """
  Static analysis of every C source file Mob actually compiles into
  the app: Mob's own NIF shims (`mob/android/jni/`, `mob/ios/`), the
  exqlite NIF wrapper (`deps/exqlite/c_src/sqlite3_nif.c`), and any
  C the project itself ships.

  Two tools, run in parallel:

    * [`semgrep`](https://semgrep.dev/) with the community `p/c`
      ruleset — catches unsafe API use, format-string bugs,
      memory-safety patterns, and a few CVE-derived rules.

    * [`flawfinder`](https://dwheeler.com/flawfinder/) — pattern-based
      audit with a long history; catches things semgrep doesn't
      (banned APIs, risky `gets`/`strcpy` use).

  ## What's deliberately excluded

  `deps/exqlite/c_src/sqlite3.c` — SQLite's amalgamated source is
  ~9MB and ~250k LOC. It's battle-tested, ships in millions of
  apps, and would generate thousands of low-value findings if scanned
  with general C rules. SQLite-specific CVE coverage lives in the
  `:bundled_runtime` layer (which fingerprints the version).

  ## Soft-degradation

  If either scanner is missing, the layer reports `:tool_missing`
  rather than failing. Install with `brew install semgrep flawfinder`
  on macOS.
  """

  @behaviour MobDev.SecurityScan.Layer

  alias MobDev.SecurityScan.{Finding, LayerResult}

  @semgrep_binary "semgrep"
  @flawfinder_binary "flawfinder"

  @impl true
  def name, do: :c_source

  @impl true
  def run(opts) do
    project_root = Keyword.get(opts, :project_root, File.cwd!())
    targets = c_targets(project_root)

    if targets == [] do
      %LayerResult{
        name: :c_source,
        status: :not_applicable,
        notes: ["no C source under project — nothing to scan"]
      }
    else
      run_scanners(targets, opts)
    end
  end

  defp c_targets(project_root) do
    # Only include directories that have at least one .c/.h/.m file.
    candidates =
      [
        Path.join([project_root, "deps", "mob", "android", "jni"]),
        Path.join([project_root, "deps", "mob", "ios"]),
        Path.join([project_root, "android", "app", "src", "main", "jni"]),
        Path.join([project_root, "ios"]),
        # Project-local C, if any
        Path.join([project_root, "c_src"]),
        # exqlite NIF wrapper only (sqlite3.c amalgamation excluded — see moduledoc)
        Path.join([project_root, "deps", "exqlite", "c_src", "sqlite3_nif.c"])
      ]

    candidates
    |> Enum.filter(&File.exists?/1)
    |> Enum.filter(&has_c_source?/1)
  end

  defp has_c_source?(path) do
    cond do
      File.regular?(path) -> Path.extname(path) in [".c", ".h", ".m"]
      File.dir?(path) -> Path.wildcard(Path.join(path, "**/*.{c,h,m}")) != []
      true -> false
    end
  end

  defp run_scanners(targets, opts) do
    semgrep_runner = Keyword.get(opts, :semgrep_runner, &default_semgrep_runner/1)
    flawfinder_runner = Keyword.get(opts, :flawfinder_runner, &default_flawfinder_runner/1)

    {semgrep_findings, semgrep_notes, semgrep_tools} = run_semgrep(targets, semgrep_runner)

    {flawfinder_findings, flawfinder_notes, flawfinder_tools} =
      run_flawfinder(targets, flawfinder_runner)

    findings = semgrep_findings ++ flawfinder_findings

    %LayerResult{
      name: :c_source,
      status: :ok,
      findings: findings,
      tools_used: semgrep_tools ++ flawfinder_tools,
      notes: ["scanned #{length(targets)} target(s)"] ++ semgrep_notes ++ flawfinder_notes
    }
  end

  ## ── semgrep ────────────────────────────────────────────────────────────────

  defp run_semgrep(targets, runner) do
    case runner.(targets) do
      {:ok, json} ->
        findings = parse_semgrep(json)
        {findings, ["semgrep: #{length(findings)} finding(s)"], ["semgrep"]}

      {:error, :not_installed} ->
        {[], ["semgrep not installed (skipped); install: brew install semgrep"], []}

      {:error, reason} ->
        {[], ["semgrep failed: #{reason}"], ["semgrep"]}
    end
  end

  defp default_semgrep_runner(targets) do
    if System.find_executable(@semgrep_binary) == nil do
      {:error, :not_installed}
    else
      args = ["--config=p/c", "--json", "--quiet"] ++ targets

      case System.cmd(@semgrep_binary, args, stderr_to_stdout: false) do
        # 0 = no findings, 1 = findings present
        {output, code} when code in [0, 1] -> {:ok, output}
        {output, code} -> {:error, "exit #{code}: #{trim(output)}"}
      end
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc false
  @spec parse_semgrep(String.t()) :: [Finding.t()]
  def parse_semgrep(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{"results" => results}} when is_list(results) ->
        Enum.map(results, &semgrep_to_finding/1)

      _ ->
        []
    end
  end

  defp semgrep_to_finding(r) do
    severity = semgrep_severity(get_in(r, ["extra", "severity"]))
    rule = r["check_id"] || "semgrep"

    %Finding{
      id: rule,
      severity: severity,
      package: r["path"],
      version: location_string(r),
      title: get_in(r, ["extra", "message"]) |> truncate(120),
      description: get_in(r, ["extra", "message"]),
      url: get_in(r, ["extra", "metadata", "source"]) || "https://semgrep.dev/r/#{rule}",
      source: :semgrep,
      layer: :c_source
    }
  end

  defp location_string(%{"start" => %{"line" => line}}), do: "line #{line}"
  defp location_string(_), do: nil

  defp semgrep_severity(nil), do: :unknown

  defp semgrep_severity(s) when is_binary(s) do
    case String.upcase(s) do
      "ERROR" -> :high
      "CRITICAL" -> :critical
      "WARNING" -> :medium
      "INFO" -> :low
      _ -> :unknown
    end
  end

  defp semgrep_severity(_), do: :unknown

  ## ── flawfinder ─────────────────────────────────────────────────────────────

  defp run_flawfinder(targets, runner) do
    case runner.(targets) do
      {:ok, csv} ->
        findings = parse_flawfinder(csv)
        {findings, ["flawfinder: #{length(findings)} finding(s)"], ["flawfinder"]}

      {:error, :not_installed} ->
        {[], ["flawfinder not installed (skipped); install: brew install flawfinder"], []}

      {:error, reason} ->
        {[], ["flawfinder failed: #{reason}"], ["flawfinder"]}
    end
  end

  defp default_flawfinder_runner(targets) do
    if System.find_executable(@flawfinder_binary) == nil do
      {:error, :not_installed}
    else
      args = ["--csv", "--quiet"] ++ targets

      case System.cmd(@flawfinder_binary, args, stderr_to_stdout: false) do
        {output, 0} -> {:ok, output}
        {output, code} -> {:error, "exit #{code}: #{trim(output)}"}
      end
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc false
  @spec parse_flawfinder(String.t()) :: [Finding.t()]
  def parse_flawfinder(csv) when is_binary(csv) do
    csv
    |> String.split("\n", trim: true)
    |> Enum.drop(1)
    |> Enum.flat_map(&flawfinder_row_to_finding/1)
  end

  defp flawfinder_row_to_finding(line) do
    case String.split(line, ",") do
      [file, line_no, _col, level, _category, name, _warning, _suggestion | rest] ->
        # rest holds the description, possibly containing commas
        message =
          rest |> Enum.join(",") |> String.trim_leading("\"") |> String.trim_trailing("\"")

        level_int = parse_int(level)

        [
          %Finding{
            id: "flawfinder/#{name}",
            severity: flawfinder_severity(level_int),
            package: file,
            version: "line #{line_no}",
            title: "#{name}: #{truncate(message, 120)}",
            description: message,
            url: "https://dwheeler.com/flawfinder/",
            source: :flawfinder,
            layer: :c_source
          }
        ]

      _ ->
        []
    end
  end

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> 0
    end
  end

  # Flawfinder levels 0–5; 4–5 are "very risky", 3 is risky, 1–2 is medium-low.
  defp flawfinder_severity(level) when level >= 5, do: :critical
  defp flawfinder_severity(4), do: :high
  defp flawfinder_severity(3), do: :medium
  defp flawfinder_severity(level) when level >= 1, do: :low
  defp flawfinder_severity(_), do: :unknown

  ## ── helpers ────────────────────────────────────────────────────────────────

  defp truncate(nil, _), do: nil

  defp truncate(s, n) when is_binary(s) do
    if String.length(s) > n, do: String.slice(s, 0, n) <> "…", else: s
  end

  defp trim(s) when is_binary(s), do: s |> String.trim() |> String.slice(0, 200)
  defp trim(s), do: inspect(s)
end
