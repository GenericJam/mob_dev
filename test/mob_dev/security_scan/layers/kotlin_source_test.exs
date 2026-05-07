defmodule MobDev.SecurityScan.Layers.KotlinSourceTest do
  use ExUnit.Case, async: true

  alias MobDev.SecurityScan.Finding
  alias MobDev.SecurityScan.Layers.KotlinSource

  @moduletag :tmp_dir

  defp put_kotlin_source(dir) do
    src = Path.join([dir, "android", "app", "src", "main", "java"])
    File.mkdir_p!(src)
    File.write!(Path.join(src, "Hello.kt"), "fun main() {}\n")
    src
  end

  test ":not_applicable when no kotlin/java source", %{tmp_dir: dir} do
    assert %{status: :not_applicable} =
             KotlinSource.run(project_root: dir, runner: fn _ -> {:ok, "{}"} end)
  end

  test ":tool_missing when detekt not installed", %{tmp_dir: dir} do
    put_kotlin_source(dir)

    result = KotlinSource.run(project_root: dir, runner: fn _ -> {:error, :not_installed} end)

    assert result.status == :tool_missing
    assert Enum.any?(result.notes, &String.contains?(&1, "brew install detekt"))
  end

  test "parses SARIF output into findings", %{tmp_dir: dir} do
    put_kotlin_source(dir)

    sarif =
      Jason.encode!(%{
        "runs" => [
          %{
            "results" => [
              %{
                "ruleId" => "complexity.LongMethod",
                "level" => "warning",
                "message" => %{"text" => "method too long"},
                "locations" => [
                  %{
                    "physicalLocation" => %{
                      "artifactLocation" => %{"uri" => "src/main/Hello.kt"},
                      "region" => %{"startLine" => 42}
                    }
                  }
                ]
              }
            ]
          }
        ]
      })

    result = KotlinSource.run(project_root: dir, runner: fn _ -> {:ok, sarif} end)

    assert [
             %Finding{
               id: "complexity.LongMethod",
               severity: :medium,
               package: "src/main/Hello.kt",
               version: "line 42",
               source: :detekt,
               layer: :kotlin_source
             }
           ] = result.findings
  end

  test "level normalization" do
    sarif =
      Jason.encode!(%{
        "runs" => [
          %{
            "results" => [
              %{"ruleId" => "r1", "level" => "error", "message" => %{"text" => "m"}},
              %{"ruleId" => "r2", "level" => "warning", "message" => %{"text" => "m"}},
              %{"ruleId" => "r3", "level" => "note", "message" => %{"text" => "m"}}
            ]
          }
        ]
      })

    findings = KotlinSource.parse(sarif)
    severities = Enum.map(findings, & &1.severity)
    assert severities == [:high, :medium, :low]
  end

  test "returns [] for invalid JSON" do
    assert KotlinSource.parse("nope") == []
  end
end
