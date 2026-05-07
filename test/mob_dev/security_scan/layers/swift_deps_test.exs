defmodule MobDev.SecurityScan.Layers.SwiftDepsTest do
  use ExUnit.Case, async: true

  alias MobDev.SecurityScan.Finding
  alias MobDev.SecurityScan.Layers.SwiftDeps

  @moduletag :tmp_dir

  test ":not_applicable when no ios/ directory", %{tmp_dir: dir} do
    result = SwiftDeps.run(project_root: dir)
    assert result.status == :not_applicable
    assert Enum.any?(result.notes, &String.contains?(&1, "no ios/"))
  end

  test ":not_applicable when ios/ exists but has no Swift manifest", %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "ios"))

    result = SwiftDeps.run(project_root: dir)

    assert result.status == :not_applicable
    assert Enum.any?(result.notes, &String.contains?(&1, "no Package.resolved or Podfile.lock"))
    assert Enum.any?(result.notes, &String.contains?(&1, ":bundled_runtime"))
  end

  describe "when a Swift manifest exists" do
    setup %{tmp_dir: dir} do
      ios = Path.join(dir, "ios")
      File.mkdir_p!(ios)
      File.write!(Path.join(ios, "Package.resolved"), "{}")
      {:ok, project: dir, ios: ios}
    end

    test ":ok when scanner returns findings", %{project: dir} do
      f = %Finding{id: "X", severity: :high, package: "alamofire", layer: :swift_deps}

      result =
        SwiftDeps.run(
          project_root: dir,
          osv_scan_fn: fn _t, _l, _o -> {:ok, [f]} end
        )

      assert result.status == :ok
      assert result.findings == [f]
      assert "osv-scanner" in result.tools_used
    end

    test ":tool_missing when osv-scanner not installed", %{project: dir} do
      result =
        SwiftDeps.run(
          project_root: dir,
          osv_scan_fn: fn _t, _l, _o -> {:error, :not_installed} end
        )

      assert result.status == :tool_missing
    end

    test "Podfile.lock alone is enough to trigger a scan", %{tmp_dir: dir} do
      ios = Path.join(dir, "ios")
      File.rm!(Path.join(ios, "Package.resolved"))
      File.write!(Path.join(ios, "Podfile.lock"), "")

      result =
        SwiftDeps.run(
          project_root: dir,
          osv_scan_fn: fn _t, _l, _o -> {:ok, []} end
        )

      assert result.status == :ok
    end
  end
end
