defmodule MobDev.SecurityScan.StateFileTest do
  use ExUnit.Case, async: true

  alias MobDev.SecurityScan.{Diff, Finding, LayerResult, Report, StateFile}

  @moduletag :tmp_dir

  defp finding(opts \\ []) do
    %Finding{
      id: opts[:id] || "GHSA-1",
      severity: opts[:severity] || :high,
      package: opts[:package] || "plug",
      version: opts[:version] || "1.10.0",
      title: opts[:title] || "title",
      url: opts[:url] || "https://example.com",
      source: :osv_scanner,
      layer: :hex_deps
    }
  end

  defp report(findings) do
    %Report{
      started_at: ~U[2026-05-07 00:00:00Z],
      finished_at: ~U[2026-05-07 00:00:01Z],
      project_root: "/p",
      layers: [%LayerResult{name: :hex_deps, status: :ok, findings: findings}]
    }
  end

  test "load/1 returns empty state when file is missing", %{tmp_dir: dir} do
    assert StateFile.empty() == StateFile.load(Path.join(dir, "missing.json"))
  end

  test "save/2 then load/1 round-trips", %{tmp_dir: dir} do
    path = Path.join(dir, "state.json")
    now = ~U[2026-05-07 12:00:00Z]

    diff = Diff.compute(StateFile.empty(), report([finding()]), now)
    state = StateFile.from_report(report([finding()]), diff, now)

    StateFile.save(path, state)
    loaded = StateFile.load(path)

    assert loaded.version == state.version
    assert loaded.last_run_at == state.last_run_at
    assert length(loaded.findings) == 1
    [entry] = loaded.findings
    assert entry.id == "GHSA-1"
    assert entry.severity == :high
    assert entry.first_seen_at == now
  end

  test "save/2 writes valid JSON", %{tmp_dir: dir} do
    path = Path.join(dir, "state.json")
    now = ~U[2026-05-07 12:00:00Z]

    diff = Diff.compute(StateFile.empty(), report([finding()]), now)
    state = StateFile.from_report(report([finding()]), diff, now)

    StateFile.save(path, state)

    {:ok, raw} = File.read(path)
    assert {:ok, decoded} = Jason.decode(raw)
    assert decoded["version"] == 1
    assert decoded["last_run_at"] == "2026-05-07T12:00:00Z"
    assert is_list(decoded["findings"]) and length(decoded["findings"]) == 1
  end

  test "from_report/3 preserves first_seen_at for known findings", %{tmp_dir: _dir} do
    earlier = ~U[2026-04-01 00:00:00Z]
    now = ~U[2026-05-07 00:00:00Z]

    initial =
      StateFile.from_report(
        report([finding(id: "X")]),
        Diff.compute(StateFile.empty(), report([finding(id: "X")]), earlier),
        earlier
      )

    diff_now = Diff.compute(initial, report([finding(id: "X")]), now)
    new_state = StateFile.from_report(report([finding(id: "X")]), diff_now, now)

    [entry] = new_state.findings
    assert entry.first_seen_at == earlier
  end

  test "from_report/3 stamps first_seen_at = now for genuinely new findings" do
    now = ~U[2026-05-07 00:00:00Z]

    diff = Diff.compute(StateFile.empty(), report([finding(id: "X")]), now)
    state = StateFile.from_report(report([finding(id: "X")]), diff, now)

    [entry] = state.findings
    assert entry.first_seen_at == now
  end

  test "save/2 sorts findings by key for stable diffs", %{tmp_dir: dir} do
    path = Path.join(dir, "state.json")
    now = ~U[2026-05-07 00:00:00Z]

    findings = [finding(id: "Z"), finding(id: "A"), finding(id: "M")]
    diff = Diff.compute(StateFile.empty(), report(findings), now)
    state = StateFile.from_report(report(findings), diff, now)

    StateFile.save(path, state)

    {:ok, raw} = File.read(path)
    {:ok, %{"findings" => f}} = Jason.decode(raw)
    ids = Enum.map(f, & &1["id"])
    assert ids == Enum.sort(ids)
  end
end
