defmodule Mix.Tasks.Mob.CacheTest do
  # async: false because tests mutate process-global env vars (MOB_CACHE_DIR
  # and MOB_SIM_RUNTIME_DIR) — running them in parallel with PathsTest would
  # race.
  use ExUnit.Case, async: false

  alias Mix.Tasks.Mob.Cache

  describe "format_size/1" do
    test "bytes" do
      assert Cache.format_size(0) == "0 B"
      assert Cache.format_size(512) == "512 B"
      assert Cache.format_size(1023) == "1023 B"
    end

    test "kilobytes" do
      assert Cache.format_size(1024) == "1.0 KB"
      assert Cache.format_size(1536) == "1.5 KB"
    end

    test "megabytes" do
      assert Cache.format_size(1024 * 1024) == "1.0 MB"
      assert Cache.format_size(round(458.5 * 1024 * 1024)) == "458.5 MB"
    end

    test "gigabytes" do
      assert Cache.format_size(round(2.5 * 1024 * 1024 * 1024)) == "2.50 GB"
    end
  end

  describe "our_cache/0" do
    test "honors MOB_CACHE_DIR" do
      System.put_env("MOB_CACHE_DIR", "/tmp/explicitly_set_cache")

      try do
        assert %{path: "/tmp/explicitly_set_cache", kind: :ours} = Cache.our_cache()
      after
        System.delete_env("MOB_CACHE_DIR")
      end
    end

    test "falls back to ~/.mob/cache when MOB_CACHE_DIR is unset" do
      System.delete_env("MOB_CACHE_DIR")
      home = System.user_home!()
      assert %{path: path, kind: :ours} = Cache.our_cache()
      assert path == Path.join([home, ".mob", "cache"])
    end
  end

  describe "elixir_make_cache_path/0" do
    test "macOS path layout when on Darwin" do
      path = Cache.elixir_make_cache_path()
      home = System.user_home!()

      case :os.type() do
        {:unix, :darwin} ->
          assert path == Path.join([home, "Library", "Caches", "elixir_make"])

        _ ->
          assert path == Path.join([home, ".cache", "elixir_make"])
      end
    end
  end

  describe "sim_runtime_targets/0" do
    test "always lists the new default and the legacy /tmp path" do
      System.delete_env("MOB_SIM_RUNTIME_DIR")
      targets = Cache.sim_runtime_targets()
      paths = Enum.map(targets, & &1.path)

      assert MobDev.Paths.default_runtime_dir() in paths
      assert MobDev.Paths.legacy_tmp_path() in paths
    end

    test "adds MOB_SIM_RUNTIME_DIR override when it differs from defaults" do
      System.put_env("MOB_SIM_RUNTIME_DIR", "/somewhere/exotic")

      try do
        targets = Cache.sim_runtime_targets()
        paths = Enum.map(targets, & &1.path)
        assert "/somewhere/exotic" in paths
        # All three present, deduplicated, no duplicates.
        assert length(paths) == length(Enum.uniq(paths))
      after
        System.delete_env("MOB_SIM_RUNTIME_DIR")
      end
    end

    test "deduplicates when override matches the default" do
      default = MobDev.Paths.default_runtime_dir()
      System.put_env("MOB_SIM_RUNTIME_DIR", default)

      try do
        targets = Cache.sim_runtime_targets()
        paths = Enum.map(targets, & &1.path)
        # Default + legacy, no duplicate of default.
        assert length(paths) == 2
        assert default in paths
        assert MobDev.Paths.legacy_tmp_path() in paths
      after
        System.delete_env("MOB_SIM_RUNTIME_DIR")
      end
    end

    test "every target has a name, path, kind, and hint" do
      System.delete_env("MOB_SIM_RUNTIME_DIR")

      Enum.each(Cache.sim_runtime_targets(), fn t ->
        assert is_binary(t.name) and t.name =~ "iOS simulator runtime"
        assert is_binary(t.path) and String.starts_with?(t.path, "/")
        assert t.kind == :ours
        assert is_binary(t.hint) and byte_size(t.hint) > 0
      end)
    end
  end

  describe "path_status/1" do
    setup do
      tmp =
        Path.join(System.tmp_dir!(), "mob_cache_test_#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf!(tmp) end)
      {:ok, tmp: tmp}
    end

    test "missing path", %{tmp: tmp} do
      assert {false, "(not present)"} = Cache.path_status(Path.join(tmp, "nope"))
    end

    test "directory size sums regular files", %{tmp: tmp} do
      File.mkdir_p!(tmp)
      File.write!(Path.join(tmp, "a"), String.duplicate("x", 1024))
      File.write!(Path.join(tmp, "b"), String.duplicate("y", 2048))
      File.mkdir_p!(Path.join(tmp, "sub"))
      File.write!(Path.join([tmp, "sub", "c"]), String.duplicate("z", 4096))

      assert {true, size_str} = Cache.path_status(tmp)
      # 7168 bytes = 7.0 KB
      assert size_str == "7.0 KB"
    end

    test "single file size", %{tmp: tmp} do
      File.mkdir_p!(tmp)
      file = Path.join(tmp, "f")
      File.write!(file, String.duplicate("x", 100))
      assert {true, "100 B"} = Cache.path_status(file)
    end

    test "empty directory reports 0 B", %{tmp: tmp} do
      File.mkdir_p!(tmp)
      assert {true, "0 B"} = Cache.path_status(tmp)
    end
  end
end
