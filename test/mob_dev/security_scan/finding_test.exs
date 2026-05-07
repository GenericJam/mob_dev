defmodule MobDev.SecurityScan.FindingTest do
  use ExUnit.Case, async: true

  alias MobDev.SecurityScan.Finding

  describe "sort_key/1" do
    test "ranks severities critical → unknown" do
      findings = [
        %Finding{id: "B", severity: :low},
        %Finding{id: "A", severity: :critical},
        %Finding{id: "C", severity: :high},
        %Finding{id: "D", severity: :medium},
        %Finding{id: "E", severity: :unknown}
      ]

      sorted = Enum.sort_by(findings, &Finding.sort_key/1)
      assert Enum.map(sorted, & &1.severity) == [:critical, :high, :medium, :low, :unknown]
    end

    test "tie-breaks on id within the same severity" do
      findings = [
        %Finding{id: "B", severity: :high},
        %Finding{id: "A", severity: :high},
        %Finding{id: "C", severity: :high}
      ]

      assert findings
             |> Enum.sort_by(&Finding.sort_key/1)
             |> Enum.map(& &1.id) == ["A", "B", "C"]
    end

    test "treats nil id as empty string for stable sort" do
      a = %Finding{id: nil, severity: :high}
      b = %Finding{id: "X", severity: :high}

      assert Enum.sort_by([b, a], &Finding.sort_key/1) == [a, b]
    end
  end

  describe "dedupe_key/1" do
    test "two findings for the same advisory + package + version share a key" do
      a = %Finding{id: "GHSA-1", package: "plug", version: "1.10.0", source: :mix_audit}
      b = %Finding{id: "GHSA-1", package: "plug", version: "1.10.0", source: :osv_scanner}

      assert Finding.dedupe_key(a) == Finding.dedupe_key(b)
    end

    test "different versions produce different keys" do
      a = %Finding{id: "GHSA-1", package: "plug", version: "1.10.0"}
      b = %Finding{id: "GHSA-1", package: "plug", version: "1.11.0"}

      refute Finding.dedupe_key(a) == Finding.dedupe_key(b)
    end
  end
end
