defmodule MobDev.SecurityScan.HistoryFormatterTest do
  use ExUnit.Case, async: true

  alias MobDev.SecurityScan.{Diff, Finding, HistoryFormatter, LayerResult, Report, StateFile}

  @moduletag :tmp_dir

  defp report(findings, opts \\ []) do
    %Report{
      started_at: opts[:started_at] || ~U[2026-05-07 00:00:00Z],
      finished_at: opts[:finished_at] || ~U[2026-05-07 00:00:01Z],
      project_root: opts[:project_root] || "/p",
      layers: [%LayerResult{name: :hex_deps, status: :ok, findings: findings}]
    }
  end

  defp finding(opts \\ []) do
    %Finding{
      id: opts[:id] || "GHSA-1",
      severity: opts[:severity] || :high,
      package: opts[:package] || "plug",
      version: opts[:version] || "1.10.0",
      fixed_in: opts[:fixed_in] || "1.11.0",
      title: opts[:title] || "RCE in plug",
      url: opts[:url] || "https://example.com",
      source: :osv_scanner,
      layer: :hex_deps
    }
  end

  describe "entry/3" do
    @now ~U[2026-05-07 12:00:00Z]

    test "renders timestamp, severity counts, and a New section for first run" do
      diff = Diff.compute(StateFile.empty(), report([finding()]), @now)
      out = HistoryFormatter.entry(report([finding()]), diff, @now)

      assert out =~ "## 2026-05-07T12:00:00Z"
      assert out =~ "**Total findings:** 1 (0 critical, 1 high"
      assert out =~ "### New since last scan (1)"
      assert out =~ "**HIGH** `plug@1.10.0`"
      assert out =~ "GHSA-1"
      assert out =~ "fixed in 1.11.0"
      assert out =~ "RCE in plug"
      assert out =~ "Resolved since last scan _(none)_"
      assert out =~ "Still present from last scan _(none)_"
    end

    test "renders Resolved section with previous-state entries" do
      prev = %{
        version: 1,
        last_run_at: ~U[2026-05-06 00:00:00Z],
        findings: [
          %{
            key: "OLD|plug|1.10.0",
            id: "OLD",
            severity: :critical,
            package: "plug",
            version: "1.10.0",
            title: "Was a critical bug",
            url: nil,
            fixed_in: "1.11.0",
            source: :mix_audit,
            layer: :hex_deps,
            first_seen_at: ~U[2026-04-01 00:00:00Z]
          }
        ]
      }

      diff = Diff.compute(prev, report([]), @now)
      out = HistoryFormatter.entry(report([]), diff, @now)

      assert out =~ "Resolved since last scan (1) ✓"
      assert out =~ "**CRITICAL** `plug@1.10.0`"
      assert out =~ "Was a critical bug"
    end

    test "Still-present section shows age suffix" do
      prev = %{
        version: 1,
        last_run_at: ~U[2026-05-06 00:00:00Z],
        findings: [
          %{
            key: "GHSA-1|plug|1.10.0",
            id: "GHSA-1",
            severity: :high,
            package: "plug",
            version: "1.10.0",
            title: "RCE in plug",
            url: nil,
            fixed_in: "1.11.0",
            source: :osv_scanner,
            layer: :hex_deps,
            first_seen_at: ~U[2026-04-01 00:00:00Z]
          }
        ]
      }

      diff = Diff.compute(prev, report([finding()]), @now)
      out = HistoryFormatter.entry(report([finding()]), diff, @now)

      assert out =~ "Still present from last scan (1)"
      assert out =~ "first seen 36 days ago"
    end
  end

  describe "prepend_to_file/2" do
    test "creates the file with header on first call", %{tmp_dir: dir} do
      path = Path.join(dir, "HISTORY.md")
      HistoryFormatter.prepend_to_file(path, "## 2026-05-07T12:00:00Z\n\nbody\n\n")

      content = File.read!(path)
      assert content =~ "# Security scan history"
      assert content =~ "## 2026-05-07T12:00:00Z"
    end

    test "newer entry is added above older entries", %{tmp_dir: dir} do
      path = Path.join(dir, "HISTORY.md")

      HistoryFormatter.prepend_to_file(path, "## 2026-05-06T00:00:00Z\n\nold body\n\n")
      HistoryFormatter.prepend_to_file(path, "## 2026-05-07T00:00:00Z\n\nnew body\n\n")

      content = File.read!(path)
      idx_new = :binary.match(content, "2026-05-07") |> elem(0)
      idx_old = :binary.match(content, "2026-05-06") |> elem(0)
      assert idx_new < idx_old
    end

    test "header is not duplicated on repeated calls", %{tmp_dir: dir} do
      path = Path.join(dir, "HISTORY.md")

      HistoryFormatter.prepend_to_file(path, "## 2026-05-06T00:00:00Z\n\na\n\n")
      HistoryFormatter.prepend_to_file(path, "## 2026-05-07T00:00:00Z\n\nb\n\n")

      content = File.read!(path)
      occurrences = content |> :binary.matches("# Security scan history") |> length()
      assert occurrences == 1
    end
  end
end
