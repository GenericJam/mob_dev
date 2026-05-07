defmodule MobDev.SecurityScan.Layers.KotlinSource do
  @moduledoc """
  Static analysis of Kotlin/Java source under `android/app/src/main/`
  using [detekt](https://detekt.dev/).

  Detekt is the de-facto Kotlin static analyzer. We invoke its CLI
  with `--report json:<out>` and parse the SARIF-like output.

  Coverage notes:

    * The default detekt ruleset emphasizes code quality more than
      security per se — but several built-in rules do cover concrete
      vulnerability classes (`HardCodedDispatcher`, unsafe-call
      patterns, regex DoS).
    * For deeper security coverage, projects can configure a
      `detekt-security.yml` and pass it via `MOB_DETEKT_CONFIG=path`
      (read by `default_runner/1`).

  Soft-degrades to `:tool_missing` when detekt isn't installed.
  Install on macOS with `brew install detekt`.
  """

  @behaviour MobDev.SecurityScan.Layer

  alias MobDev.SecurityScan.{Finding, LayerResult}

  @binary "detekt"

  @impl true
  def name, do: :kotlin_source

  @impl true
  def run(opts) do
    project_root = Keyword.get(opts, :project_root, File.cwd!())
    target = locate_kotlin_target(project_root)

    cond do
      target == nil ->
        %LayerResult{
          name: :kotlin_source,
          status: :not_applicable,
          notes: ["no Kotlin/Java source under android/app/src/main/"]
        }

      true ->
        runner = Keyword.get(opts, :runner, &default_runner/1)
        run_scan(target, runner)
    end
  end

  defp locate_kotlin_target(project_root) do
    candidates = [
      Path.join([project_root, "android", "app", "src", "main", "java"]),
      Path.join([project_root, "android", "app", "src", "main", "kotlin"])
    ]

    Enum.find(candidates, &has_jvm_source?/1)
  end

  defp has_jvm_source?(path) do
    File.dir?(path) and Path.wildcard(Path.join(path, "**/*.{kt,java}")) != []
  end

  defp run_scan(target, runner) do
    case runner.(target) do
      {:ok, json} ->
        findings = parse(json)

        %LayerResult{
          name: :kotlin_source,
          status: :ok,
          findings: findings,
          tools_used: ["detekt"],
          notes: ["scanned #{target}", "detekt: #{length(findings)} finding(s)"]
        }

      {:error, :not_installed} ->
        %LayerResult{
          name: :kotlin_source,
          status: :tool_missing,
          notes: [
            "detekt not installed; install: brew install detekt",
            "without it Kotlin/Java code is not statically analyzed"
          ]
        }

      {:error, reason} ->
        %LayerResult{
          name: :kotlin_source,
          status: :error,
          tools_used: ["detekt"],
          error: "detekt failed: #{reason}"
        }
    end
  end

  defp default_runner(target) do
    if System.find_executable(@binary) == nil do
      {:error, :not_installed}
    else
      report_path =
        Path.join(
          System.tmp_dir!(),
          "mob_security_scan_detekt_#{System.unique_integer([:positive])}.json"
        )

      args = ["--input", target, "--report", "json:#{report_path}"]
      args = maybe_add_config(args)

      result = System.cmd(@binary, args, stderr_to_stdout: true)

      finally =
        case result do
          # 0 = no findings, 1 or 2 = findings/build issues but JSON written
          {_output, code} when code in [0, 1, 2] -> read_report(report_path)
          {output, code} -> {:error, "exit #{code}: #{trim(output)}"}
        end

      File.rm(report_path)
      finally
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp maybe_add_config(args) do
    case System.get_env("MOB_DETEKT_CONFIG") do
      nil -> args
      "" -> args
      path -> args ++ ["--config", path]
    end
  end

  defp read_report(path) do
    case File.read(path) do
      {:ok, body} -> {:ok, body}
      {:error, _} -> {:ok, "{}"}
    end
  end

  @doc false
  @spec parse(String.t()) :: [Finding.t()]
  def parse(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{"runs" => runs}} when is_list(runs) ->
        Enum.flat_map(runs, &parse_run/1)

      _ ->
        []
    end
  end

  defp parse_run(%{"results" => results}) when is_list(results) do
    Enum.map(results, &result_to_finding/1)
  end

  defp parse_run(_), do: []

  defp result_to_finding(r) do
    rule = r["ruleId"] || "detekt"

    location =
      r
      |> Map.get("locations", [])
      |> List.first()
      |> get_in([
        Access.key("physicalLocation", %{}),
        Access.key("artifactLocation", %{}),
        Access.key("uri")
      ])

    line =
      r
      |> Map.get("locations", [])
      |> List.first()
      |> get_in([
        Access.key("physicalLocation", %{}),
        Access.key("region", %{}),
        Access.key("startLine")
      ])

    severity = detekt_severity(r["level"])
    message = get_in(r, ["message", "text"])

    %Finding{
      id: rule,
      severity: severity,
      package: location,
      version: line && "line #{line}",
      title: truncate(message, 120),
      description: message,
      url: "https://detekt.dev/docs/rules/" <> rule_doc_path(rule),
      source: :detekt,
      layer: :kotlin_source
    }
  end

  defp rule_doc_path(rule) do
    rule
    |> String.split(".", parts: 2)
    |> case do
      [_only_one] -> rule |> String.downcase()
      [category, _name] -> String.downcase(category) <> "/" <> rule
    end
  end

  defp detekt_severity(nil), do: :unknown

  defp detekt_severity(level) when is_binary(level) do
    case String.downcase(level) do
      "error" -> :high
      "warning" -> :medium
      "note" -> :low
      "info" -> :low
      _ -> :unknown
    end
  end

  defp detekt_severity(_), do: :unknown

  defp truncate(nil, _), do: nil

  defp truncate(s, n) when is_binary(s) do
    if String.length(s) > n, do: String.slice(s, 0, n) <> "…", else: s
  end

  defp trim(s) when is_binary(s), do: s |> String.trim() |> String.slice(0, 200)
  defp trim(s), do: inspect(s)
end
