defmodule MobDev.SecurityScan.Layers.SwiftSourceTest do
  use ExUnit.Case, async: true

  alias MobDev.SecurityScan.Finding
  alias MobDev.SecurityScan.Layers.SwiftSource

  @moduletag :tmp_dir

  defp put_swift_source(dir) do
    ios = Path.join(dir, "ios")
    File.mkdir_p!(ios)
    File.write!(Path.join(ios, "Hello.swift"), "import Foundation\n")
  end

  test ":not_applicable when no Swift files in ios/", %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "ios"))
    File.write!(Path.join([dir, "ios", "AppDelegate.m"]), "// objc only\n")

    assert %{status: :not_applicable} =
             SwiftSource.run(project_root: dir, runner: fn _ -> {:ok, "[]"} end)
  end

  test ":tool_missing when swiftlint not installed", %{tmp_dir: dir} do
    put_swift_source(dir)

    result = SwiftSource.run(project_root: dir, runner: fn _ -> {:error, :not_installed} end)

    assert result.status == :tool_missing
    assert Enum.any?(result.notes, &String.contains?(&1, "brew install swiftlint"))
  end

  test "parses swiftlint JSON into findings", %{tmp_dir: dir} do
    put_swift_source(dir)

    json =
      Jason.encode!([
        %{
          "rule_id" => "force_unwrapping",
          "severity" => "Warning",
          "file" => "/path/Hello.swift",
          "line" => 7,
          "reason" => "Force unwrapping should be avoided"
        }
      ])

    result = SwiftSource.run(project_root: dir, runner: fn _ -> {:ok, json} end)

    assert [
             %Finding{
               id: "force_unwrapping",
               severity: :medium,
               package: "/path/Hello.swift",
               version: "line 7",
               source: :swiftlint,
               layer: :swift_source
             }
           ] = result.findings
  end

  test "severity normalization" do
    json =
      Jason.encode!([
        %{"rule_id" => "r1", "severity" => "Error", "reason" => "x"},
        %{"rule_id" => "r2", "severity" => "Warning", "reason" => "x"}
      ])

    findings = SwiftSource.parse(json)
    assert Enum.map(findings, & &1.severity) == [:high, :medium]
  end
end
