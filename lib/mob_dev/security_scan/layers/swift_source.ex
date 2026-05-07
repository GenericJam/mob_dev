defmodule MobDev.SecurityScan.Layers.SwiftSource do
  @moduledoc """
  Static analysis of Swift source under `ios/` using
  [swiftlint](https://github.com/realm/SwiftLint).

  ## Why swiftlint, not `xcodebuild analyze`?

  The Clang Static Analyzer (run via `xcodebuild analyze`) is the gold
  standard for Objective-C and Swift correctness checks but requires
  a buildable Xcode project — i.e. a working signing identity, the
  right SDK, and a `.xcodeproj` or `.xcworkspace`. That's a heavy
  prerequisite for a security scan to "just work" out of the box.

  swiftlint operates directly on `.swift` files without compilation,
  produces JSON output, and ships several security-relevant rules
  (`force_cast`, `force_try`, `force_unwrapping`, `implicitly_unwrapped_optional`)
  that flag crash-by-design patterns. It's the pragmatic Swift
  counterpart to detekt.

  ## What this doesn't cover

  Mob's iOS bridge is mostly Objective-C (`.m` / `.c` files), not
  Swift. swiftlint ignores those. ObjC code is covered by the
  `:c_source` layer instead, which runs semgrep+flawfinder over `.m`
  files alongside `.c`/`.h`. The split is unfortunate but follows
  tool boundaries.

  Soft-degrades to `:tool_missing` when swiftlint isn't installed.
  Install on macOS with `brew install swiftlint`.
  """

  @behaviour MobDev.SecurityScan.Layer

  alias MobDev.SecurityScan.{Finding, LayerResult}

  @binary "swiftlint"

  @impl true
  def name, do: :swift_source

  @impl true
  def run(opts) do
    project_root = Keyword.get(opts, :project_root, File.cwd!())
    target = locate_swift_target(project_root)

    cond do
      target == nil ->
        %LayerResult{
          name: :swift_source,
          status: :not_applicable,
          notes: [
            "no .swift files under ios/ — Mob's iOS bridge is .m/.c which is covered by :c_source"
          ]
        }

      true ->
        runner = Keyword.get(opts, :runner, &default_runner/1)
        run_scan(target, runner)
    end
  end

  defp locate_swift_target(project_root) do
    ios = Path.join(project_root, "ios")

    if File.dir?(ios) and Path.wildcard(Path.join(ios, "**/*.swift")) != [] do
      ios
    end
  end

  defp run_scan(target, runner) do
    case runner.(target) do
      {:ok, json} ->
        findings = parse(json)

        %LayerResult{
          name: :swift_source,
          status: :ok,
          findings: findings,
          tools_used: ["swiftlint"],
          notes: ["scanned #{target}", "swiftlint: #{length(findings)} finding(s)"]
        }

      {:error, :not_installed} ->
        %LayerResult{
          name: :swift_source,
          status: :tool_missing,
          notes: [
            "swiftlint not installed; install: brew install swiftlint",
            "without it Swift code is not statically analyzed"
          ]
        }

      {:error, reason} ->
        %LayerResult{
          name: :swift_source,
          status: :error,
          tools_used: ["swiftlint"],
          error: "swiftlint failed: #{reason}"
        }
    end
  end

  defp default_runner(target) do
    if System.find_executable(@binary) == nil do
      {:error, :not_installed}
    else
      args = ["lint", "--quiet", "--reporter", "json", target]

      case System.cmd(@binary, args, stderr_to_stdout: false) do
        # swiftlint exits non-zero when violations exist; treat both as success.
        {output, code} when code in [0, 2] -> {:ok, output}
        {output, code} -> {:error, "exit #{code}: #{trim(output)}"}
      end
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc false
  @spec parse(String.t()) :: [Finding.t()]
  def parse(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, results} when is_list(results) -> Enum.map(results, &result_to_finding/1)
      _ -> []
    end
  end

  defp result_to_finding(r) do
    rule = r["rule_id"] || r["type"] || "swiftlint"

    %Finding{
      id: rule,
      severity: swiftlint_severity(r["severity"]),
      package: r["file"],
      version: r["line"] && "line #{r["line"]}",
      title: truncate(r["reason"], 120),
      description: r["reason"],
      url: "https://realm.github.io/SwiftLint/" <> String.replace(rule, "_", "-") <> ".html",
      source: :swiftlint,
      layer: :swift_source
    }
  end

  defp swiftlint_severity(nil), do: :unknown

  defp swiftlint_severity(s) when is_binary(s) do
    case String.downcase(s) do
      "error" -> :high
      "warning" -> :medium
      _ -> :unknown
    end
  end

  defp swiftlint_severity(_), do: :unknown

  defp truncate(nil, _), do: nil

  defp truncate(s, n) when is_binary(s) do
    if String.length(s) > n, do: String.slice(s, 0, n) <> "…", else: s
  end

  defp trim(s) when is_binary(s), do: s |> String.trim() |> String.slice(0, 200)
  defp trim(s), do: inspect(s)
end
