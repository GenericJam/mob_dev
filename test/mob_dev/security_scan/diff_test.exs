defmodule MobDev.SecurityScan.DiffTest do
  use ExUnit.Case, async: true

  alias MobDev.SecurityScan.{Diff, Finding, LayerResult, Report, StateFile}

  defp report(findings) do
    %Report{
      started_at: ~U[2026-05-07 00:00:00Z],
      finished_at: ~U[2026-05-07 00:00:01Z],
      project_root: "/p",
      layers: [%LayerResult{name: :hex_deps, status: :ok, findings: findings}]
    }
  end

  defp finding(opts) do
    %Finding{
      id: opts[:id] || "GHSA-1",
      severity: opts[:severity] || :high,
      package: opts[:package] || "plug",
      version: opts[:version] || "1.10.0",
      layer: :hex_deps
    }
  end

  defp state_entry(opts) do
    %{
      key: "#{opts[:id] || "GHSA-1"}|#{opts[:package] || "plug"}|#{opts[:version] || "1.10.0"}",
      id: opts[:id] || "GHSA-1",
      severity: opts[:severity] || :high,
      package: opts[:package] || "plug",
      version: opts[:version] || "1.10.0",
      title: opts[:title],
      url: nil,
      fixed_in: nil,
      source: :osv_scanner,
      layer: :hex_deps,
      first_seen_at: opts[:first_seen_at] || ~U[2026-05-01 00:00:00Z]
    }
  end

  @now ~U[2026-05-07 12:00:00Z]

  test "first run: every finding is :new" do
    diff = Diff.compute(StateFile.empty(), report([finding(id: "X")]), @now)

    assert length(diff.new) == 1
    assert diff.resolved == []
    assert diff.still_present == []
  end

  test "second run: identical findings are :still_present, none :new or :resolved" do
    state = %{
      version: 1,
      last_run_at: ~U[2026-05-06 00:00:00Z],
      findings: [state_entry(id: "X")]
    }

    diff = Diff.compute(state, report([finding(id: "X")]), @now)

    assert diff.new == []
    assert diff.resolved == []
    assert length(diff.still_present) == 1
  end

  test "vanished finding is :resolved" do
    state = %{
      version: 1,
      last_run_at: ~U[2026-05-06 00:00:00Z],
      findings: [state_entry(id: "X"), state_entry(id: "Y")]
    }

    diff = Diff.compute(state, report([finding(id: "X")]), @now)

    assert [%{id: "X"}] = diff.still_present
    assert [%{id: "Y"}] = diff.resolved
    assert diff.new == []
  end

  test "newly-appearing finding is :new" do
    state = %{
      version: 1,
      last_run_at: ~U[2026-05-06 00:00:00Z],
      findings: [state_entry(id: "X")]
    }

    diff = Diff.compute(state, report([finding(id: "X"), finding(id: "Z")]), @now)

    new_ids = Enum.map(diff.new, & &1.id)
    assert "Z" in new_ids
    refute "X" in new_ids
  end

  test "first_seen is preserved across runs for already-known findings" do
    state = %{
      version: 1,
      last_run_at: ~U[2026-05-06 00:00:00Z],
      findings: [state_entry(id: "X", first_seen_at: ~U[2026-04-01 00:00:00Z])]
    }

    diff = Diff.compute(state, report([finding(id: "X")]), @now)

    [%Finding{} = f] = diff.still_present
    assert Map.get(diff.first_seen, Finding.dedupe_key(f)) == ~U[2026-04-01 00:00:00Z]
  end

  test "first_seen for genuinely new findings defaults to `now`" do
    diff = Diff.compute(StateFile.empty(), report([finding(id: "Z")]), @now)

    [%Finding{} = f] = diff.new
    assert Map.get(diff.first_seen, Finding.dedupe_key(f)) == @now
  end

  test "different versions of the same advisory are different findings" do
    state = %{
      version: 1,
      last_run_at: nil,
      findings: [state_entry(id: "X", version: "1.10.0")]
    }

    diff = Diff.compute(state, report([finding(id: "X", version: "1.11.0")]), @now)

    assert length(diff.resolved) == 1
    assert length(diff.new) == 1
    assert diff.still_present == []
  end
end
