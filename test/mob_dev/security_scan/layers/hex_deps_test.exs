defmodule MobDev.SecurityScan.Layers.HexDepsTest do
  use ExUnit.Case, async: true

  alias MobDev.SecurityScan.Finding
  alias MobDev.SecurityScan.Layers.HexDeps

  @moduletag :tmp_dir

  # mix_audit 2.1.5 (current pin) precompiles a sigil regex into its beam
  # file using a bytecode format that calls `:re.import/1`. That function
  # is missing on OTP 28.0 — fixed in OTP 28.1+ and present in OTP 27.
  # Until the host upgrades off 28.0 (or mix_audit ships a release without
  # the precompiled sigil), these tests crash with
  # `function :re.import/1 is undefined or private` deep inside mix_audit
  # code we don't control. Skip rather than ship a red signal that would
  # mask actual regressions. test_helper.exs excludes this tag whenever
  # System.otp_release/0 returns "28" — drops the moment the host moves.
  @moduletag :mix_audit_otp28_broken

  defp write_lockfile(dir, contents) do
    File.write!(Path.join(dir, "mix.lock"), contents)
  end

  defp no_osv, do: fn _target, _layer, _opts -> {:error, :not_installed} end

  defp lockfile_with_plug(version) do
    """
    %{
      "plug": {:hex, :plug, "#{version}", "abc123", [:mix], [], "hexpm", "deadbeef"},
    }
    """
  end

  defp advisory(opts) do
    %MixAudit.Advisory{
      id: opts[:id] || "GHSA-test",
      package: opts[:package] || "plug",
      url: opts[:url] || "https://example.com",
      title: opts[:title] || "Test advisory",
      description: opts[:description] || "desc",
      vulnerable_version_ranges: opts[:vulnerable] || ["< 1.11.0"],
      first_patched_versions: opts[:patched] || ["1.11.0"],
      severity: Keyword.get(opts, :severity, "high")
    }
  end

  test "returns :not_applicable when no mix.lock", %{tmp_dir: dir} do
    result =
      HexDeps.run(project_root: dir, advisories_fn: fn -> [] end, osv_scan_fn: no_osv())

    assert result.status == :not_applicable
    assert result.findings == []
    assert Enum.any?(result.notes, &String.contains?(&1, "no mix.lock"))
  end

  test "returns :ok with no findings when no advisories match", %{tmp_dir: dir} do
    write_lockfile(dir, lockfile_with_plug("1.12.0"))

    result =
      HexDeps.run(
        project_root: dir,
        advisories_fn: fn -> [advisory(vulnerable: ["< 1.11.0"], patched: ["1.11.0"])] end,
        osv_scan_fn: no_osv()
      )

    assert result.status == :ok
    assert result.findings == []
    assert "mix_audit" in result.tools_used
  end

  test "returns :ok with mapped finding when advisory matches", %{tmp_dir: dir} do
    write_lockfile(dir, lockfile_with_plug("1.10.0"))

    result =
      HexDeps.run(
        project_root: dir,
        advisories_fn: fn ->
          [
            advisory(
              id: "GHSA-9999",
              vulnerable: ["< 1.11.0"],
              patched: ["1.11.0"],
              severity: "critical",
              title: "RCE",
              url: "https://example.com/9999"
            )
          ]
        end,
        osv_scan_fn: no_osv()
      )

    assert result.status == :ok

    assert [
             %Finding{
               id: "GHSA-9999",
               severity: :critical,
               package: "plug",
               version: "1.10.0",
               fixed_in: "1.11.0",
               title: "RCE",
               url: "https://example.com/9999",
               source: :mix_audit,
               layer: :hex_deps
             }
           ] = result.findings
  end

  test "normalizes vendor severity scales", %{tmp_dir: dir} do
    write_lockfile(dir, lockfile_with_plug("1.10.0"))

    cases = [
      {"critical", :critical},
      {"high", :high},
      {"important", :high},
      {"medium", :medium},
      {"moderate", :medium},
      {"low", :low},
      {"", :unknown},
      {nil, :unknown},
      {"weird-string", :unknown}
    ]

    for {input, expected} <- cases do
      result =
        HexDeps.run(
          project_root: dir,
          advisories_fn: fn -> [advisory(severity: input)] end,
          osv_scan_fn: no_osv()
        )

      assert [%Finding{severity: ^expected}] = result.findings,
             "expected #{inspect(input)} to normalize to #{inspect(expected)}"
    end
  end

  test "returns :tool_missing if the advisory fetch raises", %{tmp_dir: dir} do
    write_lockfile(dir, lockfile_with_plug("1.10.0"))

    result =
      HexDeps.run(
        project_root: dir,
        advisories_fn: fn -> raise "GitHub down" end,
        osv_scan_fn: no_osv()
      )

    assert result.status == :tool_missing
    assert Enum.any?(result.notes, &String.contains?(&1, "GitHub down"))
  end

  describe "osv-scanner integration" do
    test "merges osv findings with mix_audit findings", %{tmp_dir: dir} do
      write_lockfile(dir, lockfile_with_plug("1.10.0"))

      audit_advisory =
        advisory(id: "AUDIT-1", vulnerable: ["< 1.11.0"], patched: ["1.11.0"])

      osv_finding = %Finding{
        id: "OSV-1",
        severity: :high,
        package: "plug",
        version: "1.10.0",
        source: :osv_scanner,
        layer: :hex_deps
      }

      result =
        HexDeps.run(
          project_root: dir,
          advisories_fn: fn -> [audit_advisory] end,
          osv_scan_fn: fn _target, _layer, _opts -> {:ok, [osv_finding]} end
        )

      ids = Enum.map(result.findings, & &1.id) |> Enum.sort()
      assert ids == ["AUDIT-1", "OSV-1"]
    end

    test "dedupes a finding reported by both sources, keeping the osv-tagged one", %{tmp_dir: dir} do
      write_lockfile(dir, lockfile_with_plug("1.10.0"))

      same_id = "GHSA-DUPE"

      audit_advisory =
        advisory(id: same_id, vulnerable: ["< 1.11.0"], patched: ["1.11.0"], severity: "high")

      osv_finding = %Finding{
        id: same_id,
        severity: :critical,
        package: "plug",
        version: "1.10.0",
        source: :osv_scanner,
        layer: :hex_deps
      }

      result =
        HexDeps.run(
          project_root: dir,
          advisories_fn: fn -> [audit_advisory] end,
          osv_scan_fn: fn _target, _layer, _opts -> {:ok, [osv_finding]} end
        )

      assert [%Finding{id: ^same_id, source: :osv_scanner, severity: :critical}] = result.findings
    end

    test "records osv 'not installed' as a note without crashing", %{tmp_dir: dir} do
      write_lockfile(dir, lockfile_with_plug("1.12.0"))

      result =
        HexDeps.run(
          project_root: dir,
          advisories_fn: fn -> [] end,
          osv_scan_fn: fn _target, _layer, _opts -> {:error, :not_installed} end
        )

      assert result.status == :ok
      assert Enum.any?(result.notes, &String.contains?(&1, "osv-scanner not installed"))
      refute "osv-scanner" in result.tools_used
    end

    test "tools_used includes osv-scanner when it ran", %{tmp_dir: dir} do
      write_lockfile(dir, lockfile_with_plug("1.12.0"))

      result =
        HexDeps.run(
          project_root: dir,
          advisories_fn: fn -> [] end,
          osv_scan_fn: fn _target, _layer, _opts -> {:ok, []} end
        )

      assert "osv-scanner" in result.tools_used
      assert "mix_audit" in result.tools_used
    end
  end
end
