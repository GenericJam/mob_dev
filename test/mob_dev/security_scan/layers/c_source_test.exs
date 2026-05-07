defmodule MobDev.SecurityScan.Layers.CSourceTest do
  use ExUnit.Case, async: true

  alias MobDev.SecurityScan.Finding
  alias MobDev.SecurityScan.Layers.CSource

  @moduletag :tmp_dir

  defp put_c_source(dir) do
    c_src = Path.join([dir, "deps", "mob", "android", "jni"])
    File.mkdir_p!(c_src)
    File.write!(Path.join(c_src, "mob_nif.c"), "int main() { return 0; }\n")
    c_src
  end

  defp empty_runner, do: fn _targets -> {:ok, ~s({"results":[]})} end
  defp not_installed_runner, do: fn _targets -> {:error, :not_installed} end

  defp empty_csv_runner,
    do: fn _targets ->
      {:ok, "File,Line,Column,Level,Category,Name,Warning,Suggestion,Note,CWEs,Context\n"}
    end

  describe "run/1" do
    test ":not_applicable when no C source under project", %{tmp_dir: dir} do
      result =
        CSource.run(
          project_root: dir,
          semgrep_runner: empty_runner(),
          flawfinder_runner: empty_csv_runner()
        )

      assert result.status == :not_applicable
      assert Enum.any?(result.notes, &String.contains?(&1, "no C source"))
    end

    test ":ok with empty findings when both tools find nothing", %{tmp_dir: dir} do
      put_c_source(dir)

      result =
        CSource.run(
          project_root: dir,
          semgrep_runner: empty_runner(),
          flawfinder_runner: empty_csv_runner()
        )

      assert result.status == :ok
      assert result.findings == []
      assert "semgrep" in result.tools_used
      assert "flawfinder" in result.tools_used
    end

    test "soft-warns when both tools missing", %{tmp_dir: dir} do
      put_c_source(dir)

      result =
        CSource.run(
          project_root: dir,
          semgrep_runner: not_installed_runner(),
          flawfinder_runner: not_installed_runner()
        )

      assert result.status == :ok
      assert Enum.any?(result.notes, &String.contains?(&1, "semgrep not installed"))
      assert Enum.any?(result.notes, &String.contains?(&1, "flawfinder not installed"))
      refute "semgrep" in result.tools_used
      refute "flawfinder" in result.tools_used
    end

    test "merges findings from both tools", %{tmp_dir: dir} do
      put_c_source(dir)

      semgrep_json =
        ~s({"results":[{"check_id":"my-rule","path":"f.c","start":{"line":42},"extra":{"severity":"ERROR","message":"Use of unsafe API"}}]})

      flawfinder_csv = """
      File,Line,Column,Level,Category,Name,Warning,Suggestion,Note,CWEs,Context
      f.c,7,1,4,buffer,strcpy,description,note,cwe,context
      """

      result =
        CSource.run(
          project_root: dir,
          semgrep_runner: fn _t -> {:ok, semgrep_json} end,
          flawfinder_runner: fn _t -> {:ok, flawfinder_csv} end
        )

      assert length(result.findings) == 2
      sources = Enum.map(result.findings, & &1.source) |> Enum.sort()
      assert sources == [:flawfinder, :semgrep]
    end
  end

  describe "parse_semgrep/1" do
    test "maps a finding with severity" do
      json =
        ~s({"results":[{"check_id":"r","path":"f.c","start":{"line":3},"extra":{"severity":"WARNING","message":"watch out"}}]})

      assert [
               %Finding{
                 id: "r",
                 severity: :medium,
                 package: "f.c",
                 version: "line 3",
                 source: :semgrep,
                 layer: :c_source
               }
             ] = CSource.parse_semgrep(json)
    end

    test "ERROR maps to :high, CRITICAL to :critical" do
      cases = [
        {"ERROR", :high},
        {"CRITICAL", :critical},
        {"WARNING", :medium},
        {"INFO", :low},
        {"weird", :unknown},
        {nil, :unknown}
      ]

      for {input, expected} <- cases do
        sev_field = if input, do: ~s("severity":"#{input}",), else: ""

        json =
          ~s({"results":[{"check_id":"r","path":"f.c","start":{"line":1},"extra":{#{sev_field}"message":"m"}}]})

        assert [%Finding{severity: ^expected}] = CSource.parse_semgrep(json),
               "expected #{inspect(input)} → #{inspect(expected)}"
      end
    end

    test "returns [] for invalid JSON" do
      assert CSource.parse_semgrep("not-json") == []
    end
  end

  describe "parse_flawfinder/1" do
    test "maps a row with banned-API category" do
      csv = """
      File,Line,Column,Level,Category,Name,Warning,Suggestion,Note,CWEs,Context
      a.c,10,1,5,buffer,gets,"Buffer overflow risk",Avoid,note,CWE-242,ctx
      """

      [finding] = CSource.parse_flawfinder(csv)

      assert finding.id == "flawfinder/gets"
      assert finding.severity == :critical
      assert finding.package == "a.c"
      assert finding.version == "line 10"
      assert finding.source == :flawfinder
      assert finding.layer == :c_source
    end

    test "level → severity mapping" do
      cases = [{5, :critical}, {4, :high}, {3, :medium}, {2, :low}, {1, :low}, {0, :unknown}]

      for {level, expected} <- cases do
        csv = """
        File,Line,Column,Level,Category,Name,Warning,Suggestion
        x.c,1,1,#{level},c,n,"w","s"
        """

        [%Finding{severity: ^expected}] = CSource.parse_flawfinder(csv)
      end
    end

    test "returns [] for header-only or empty input" do
      assert CSource.parse_flawfinder("File,Line,Column\n") == []
      assert CSource.parse_flawfinder("") == []
    end
  end
end
