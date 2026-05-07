defmodule MobDev.SecurityScan.ReportTest do
  use ExUnit.Case, async: true

  alias MobDev.SecurityScan.{Finding, LayerResult, Report}

  defp report(layers) do
    %Report{
      started_at: ~U[2026-01-01 00:00:00Z],
      finished_at: ~U[2026-01-01 00:00:01Z],
      project_root: "/tmp",
      layers: layers
    }
  end

  defp finding(severity), do: %Finding{severity: severity}

  describe "all_findings/1" do
    test "flattens findings across layers" do
      r =
        report([
          %LayerResult{name: :a, findings: [finding(:high), finding(:low)]},
          %LayerResult{name: :b, findings: [finding(:critical)]}
        ])

      assert length(Report.all_findings(r)) == 3
    end

    test "returns empty list when no layers" do
      assert Report.all_findings(report([])) == []
    end
  end

  describe "severity_counts/1" do
    test "counts each severity, defaults zeros for empty" do
      r =
        report([
          %LayerResult{
            name: :a,
            findings: [
              finding(:critical),
              finding(:critical),
              finding(:high),
              finding(:low),
              finding(:unknown)
            ]
          }
        ])

      assert Report.severity_counts(r) == %{
               critical: 2,
               high: 1,
               medium: 0,
               low: 1,
               unknown: 1
             }
    end

    test "every key present even when no findings" do
      r = report([])
      assert Report.severity_counts(r) == %{critical: 0, high: 0, medium: 0, low: 0, unknown: 0}
    end
  end

  describe "worst_severity/1" do
    test "returns :none for empty report" do
      assert Report.worst_severity(report([])) == :none
    end

    test "picks the worst present" do
      r = report([%LayerResult{name: :a, findings: [finding(:medium), finding(:low)]}])
      assert Report.worst_severity(r) == :medium
    end

    test "critical wins over everything else" do
      r =
        report([
          %LayerResult{
            name: :a,
            findings: [
              finding(:low),
              finding(:critical),
              finding(:high),
              finding(:unknown)
            ]
          }
        ])

      assert Report.worst_severity(r) == :critical
    end
  end

  describe "duration_ms/1" do
    test "computes wall-clock duration" do
      r = report([])
      assert Report.duration_ms(r) == 1000
    end

    test "returns nil if not finished" do
      r = %Report{started_at: ~U[2026-01-01 00:00:00Z], finished_at: nil, layers: []}
      assert Report.duration_ms(r) == nil
    end
  end
end
