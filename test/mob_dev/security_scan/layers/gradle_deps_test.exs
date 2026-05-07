defmodule MobDev.SecurityScan.Layers.GradleDepsTest do
  use ExUnit.Case, async: true

  alias MobDev.SecurityScan.Finding
  alias MobDev.SecurityScan.Layers.GradleDeps

  @moduletag :tmp_dir

  test "returns :not_applicable when no android/ directory", %{tmp_dir: dir} do
    result = GradleDeps.run(project_root: dir)
    assert result.status == :not_applicable
    assert Enum.any?(result.notes, &String.contains?(&1, "no android/"))
  end

  describe "with android/ directory" do
    setup %{tmp_dir: dir} do
      android = Path.join(dir, "android")
      File.mkdir_p!(android)
      {:ok, android: android, project: dir}
    end

    test ":ok with no findings + lockfile-guidance note when stub returns []", %{project: dir} do
      result =
        GradleDeps.run(
          project_root: dir,
          osv_scan_fn: fn _t, _l, _o -> {:ok, []} end
        )

      assert result.status == :ok
      assert result.findings == []
      assert "osv-scanner" in result.tools_used

      assert Enum.any?(result.notes, &String.contains?(&1, "no gradle.lockfile present"))
    end

    test ":ok with findings when stub returns vulns", %{project: dir} do
      f = %Finding{id: "X", severity: :high, package: "okhttp", layer: :gradle_deps}

      result =
        GradleDeps.run(
          project_root: dir,
          osv_scan_fn: fn _t, _l, _o -> {:ok, [f]} end
        )

      assert result.status == :ok
      assert result.findings == [f]
    end

    test ":tool_missing when osv-scanner not installed", %{project: dir} do
      result =
        GradleDeps.run(
          project_root: dir,
          osv_scan_fn: fn _t, _l, _o -> {:error, :not_installed} end
        )

      assert result.status == :tool_missing
      assert Enum.any?(result.notes, &String.contains?(&1, "brew install osv-scanner"))
    end

    test ":error when scan fails for a real reason", %{project: dir} do
      result =
        GradleDeps.run(
          project_root: dir,
          osv_scan_fn: fn _t, _l, _o -> {:error, {:scan_failed, "exit 137"}} end
        )

      assert result.status == :error
      assert result.error =~ "exit 137"
    end

    test "lockfile-guidance note flips when gradle.lockfile is present", %{
      project: dir,
      android: android
    } do
      app = Path.join(android, "app")
      File.mkdir_p!(app)
      File.write!(Path.join(app, "gradle.lockfile"), "")

      result =
        GradleDeps.run(
          project_root: dir,
          osv_scan_fn: fn _t, _l, _o -> {:ok, []} end
        )

      assert Enum.any?(result.notes, &String.contains?(&1, "scanned manifests including gradle.lockfile"))
    end
  end
end
