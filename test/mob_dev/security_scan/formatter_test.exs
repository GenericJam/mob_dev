defmodule MobDev.SecurityScan.FormatterTest do
  use ExUnit.Case, async: true

  alias MobDev.SecurityScan.{Finding, Formatter, LayerResult, Report}

  defp sample_report(layers) do
    %Report{
      started_at: ~U[2026-01-01 00:00:00Z],
      finished_at: ~U[2026-01-01 00:00:01Z],
      project_root: "/tmp/proj",
      layers: layers
    }
  end

  test "terminal/1 includes header, layer name, and summary" do
    report =
      sample_report([
        %LayerResult{
          name: :hex_deps,
          status: :ok,
          findings: [],
          tools_used: ["mix_audit"],
          duration_ms: 100,
          notes: ["audited 5 deps"]
        }
      ])

    out = Formatter.terminal(report)

    assert out =~ "mob security scan"
    assert out =~ "hex_deps"
    assert out =~ "ok"
    assert out =~ "mix_audit"
    assert out =~ "audited 5 deps"
    assert out =~ "Summary"
    assert out =~ "total findings: 0"
  end

  test "terminal/1 renders findings sorted by severity, with id and fix info" do
    finding = %Finding{
      id: "GHSA-XXXX",
      severity: :critical,
      package: "plug",
      version: "1.10.0",
      fixed_in: "1.11.0",
      title: "RCE in plug",
      source: :mix_audit,
      layer: :hex_deps
    }

    report =
      sample_report([
        %LayerResult{name: :hex_deps, status: :ok, findings: [finding]}
      ])

    out = Formatter.terminal(report)

    assert out =~ "CRITICAL"
    assert out =~ "plug"
    assert out =~ "1.10.0"
    assert out =~ "GHSA-XXXX"
    assert out =~ "fixed in 1.11.0"
    assert out =~ "RCE in plug"
  end

  test "terminal/1 shows tool_missing status with notes" do
    report =
      sample_report([
        %LayerResult{
          name: :gradle_deps,
          status: :tool_missing,
          tools_used: ["osv-scanner"],
          notes: ["install: brew install osv-scanner"]
        }
      ])

    out = Formatter.terminal(report)

    assert out =~ "tool missing"
    assert out =~ "brew install osv-scanner"
  end

  test "terminal/1 shows skipped layers as skipped" do
    report =
      sample_report([
        %LayerResult{name: :c_source, status: :skipped, notes: ["skipped via --skip flag"]}
      ])

    out = Formatter.terminal(report)
    assert out =~ "skipped"
  end

  test "markdown/1 produces a readable report with severity table and findings table" do
    finding = %Finding{
      id: "CVE-2024-1",
      severity: :critical,
      package: "openssl",
      version: "3.4.0",
      fixed_in: "3.4.1",
      title: "Use after free in HTTP parser",
      source: :openssl_feed,
      layer: :bundled_runtime
    }

    report =
      sample_report([
        %LayerResult{
          name: :bundled_runtime,
          status: :ok,
          findings: [finding],
          tools_used: ["fingerprint"],
          notes: ["scanned 1 tarball"]
        }
      ])

    md = Formatter.markdown(report)

    assert md =~ "# Mob Security Scan"
    assert md =~ "**Total findings:** 1"
    assert md =~ "## Severity counts"
    assert md =~ "| Critical | High | Medium | Low | Unknown |"
    assert md =~ "### `bundled_runtime` — ok"
    assert md =~ "**Tools:** fingerprint"
    assert md =~ "scanned 1 tarball"
    assert md =~ "**Findings**"

    assert md =~
             "| CRITICAL | CVE-2024-1 | openssl | 3.4.0 | 3.4.1 | Use after free in HTTP parser |"
  end

  test "markdown/1 escapes pipes inside titles" do
    report =
      sample_report([
        %LayerResult{
          name: :hex_deps,
          status: :ok,
          findings: [
            %Finding{
              id: "X",
              severity: :high,
              title: "this | breaks | tables",
              package: "p",
              version: "1.0"
            }
          ]
        }
      ])

    md = Formatter.markdown(report)
    refute md =~ "this | breaks"
    assert md =~ "this \\| breaks \\| tables"
  end

  test "json/1 returns a parsable JSON string" do
    report =
      sample_report([
        %LayerResult{
          name: :hex_deps,
          status: :ok,
          findings: [%Finding{id: "X", severity: :low, package: "p", version: "1.0"}]
        }
      ])

    json = Formatter.json(report)
    assert is_binary(json) and byte_size(json) > 0
    {:ok, decoded} = Jason.decode(json)

    assert decoded["project_root"] == "/tmp/proj"
    assert [%{"name" => "hex_deps", "findings" => [%{"id" => "X"}]}] = decoded["layers"]
  end
end
