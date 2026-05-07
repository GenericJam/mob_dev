defmodule MobDev.SecurityScan.OsvScannerTest do
  use ExUnit.Case, async: true

  alias MobDev.SecurityScan.OsvScanner

  @moduletag :tmp_dir

  defp empty_osv_json, do: ~s({"results":[]})

  defp osv_json_with_finding do
    Jason.encode!(%{
      "results" => [
        %{
          "packages" => [
            %{
              "package" => %{"name" => "plug", "version" => "1.10.0", "ecosystem" => "Hex"},
              "groups" => [%{"ids" => ["X"], "max_severity" => "8.2"}],
              "vulnerabilities" => [
                %{"id" => "X", "summary" => "RCE", "aliases" => ["X"]}
              ]
            }
          ]
        }
      ]
    })
  end

  describe "scan/3" do
    test "returns {:error, {:not_found, _}} when target lockfile is missing" do
      assert {:error, {:not_found, "/nope/mix.lock"}} =
               OsvScanner.scan({:lockfile, "/nope/mix.lock"}, :hex_deps,
                 runner: fn _args -> {:ok, empty_osv_json()} end
               )
    end

    test "returns {:error, {:not_found, _}} when target directory is missing" do
      assert {:error, {:not_found, "/nope/dir"}} =
               OsvScanner.scan({:directory, "/nope/dir"}, :hex_deps,
                 runner: fn _args -> {:ok, empty_osv_json()} end
               )
    end

    test "returns {:ok, []} on a clean scan", %{tmp_dir: dir} do
      lockfile = Path.join(dir, "mix.lock")
      File.write!(lockfile, "%{}\n")

      assert {:ok, []} =
               OsvScanner.scan({:lockfile, lockfile}, :hex_deps,
                 runner: fn _args -> {:ok, empty_osv_json()} end
               )
    end

    test "returns {:ok, [finding]} when osv-scanner reports a vulnerability", %{tmp_dir: dir} do
      lockfile = Path.join(dir, "mix.lock")
      File.write!(lockfile, "%{}\n")

      assert {:ok, [finding]} =
               OsvScanner.scan({:lockfile, lockfile}, :hex_deps,
                 runner: fn _args -> {:ok, osv_json_with_finding()} end
               )

      assert finding.id == "X"
      assert finding.severity == :high
      assert finding.layer == :hex_deps
      assert finding.source == :osv_scanner
    end

    test "returns {:error, {:scan_failed, _}} on malformed JSON", %{tmp_dir: dir} do
      lockfile = Path.join(dir, "mix.lock")
      File.write!(lockfile, "%{}\n")

      assert {:error, {:scan_failed, "json decode: " <> _}} =
               OsvScanner.scan({:lockfile, lockfile}, :hex_deps,
                 runner: fn _args -> {:ok, "not-json"} end
               )
    end

    test "returns {:error, {:scan_failed, _}} when runner reports failure", %{tmp_dir: dir} do
      lockfile = Path.join(dir, "mix.lock")
      File.write!(lockfile, "%{}\n")

      assert {:error, {:scan_failed, "exit 127: " <> _}} =
               OsvScanner.scan({:lockfile, lockfile}, :hex_deps,
                 runner: fn _args -> {:error, "exit 127: command not found"} end
               )
    end

    test "passes lockfile arg to runner", %{tmp_dir: dir} do
      lockfile = Path.join(dir, "mix.lock")
      File.write!(lockfile, "%{}\n")
      pid = self()

      OsvScanner.scan({:lockfile, lockfile}, :hex_deps,
        runner: fn args ->
          send(pid, {:args, args})
          {:ok, empty_osv_json()}
        end
      )

      assert_received {:args, args}
      assert "--lockfile=#{lockfile}" in args
      assert "--format=json" in args
    end

    test "passes directory arg to runner", %{tmp_dir: dir} do
      pid = self()

      OsvScanner.scan({:directory, dir}, :gradle_deps,
        runner: fn args ->
          send(pid, {:args, args})
          {:ok, empty_osv_json()}
        end
      )

      assert_received {:args, args}
      assert "--recursive" in args
      assert dir in args
    end
  end

  describe "installed?/0" do
    @tag :integration
    test "returns boolean reflecting PATH" do
      assert OsvScanner.installed?() in [true, false]
    end
  end
end
