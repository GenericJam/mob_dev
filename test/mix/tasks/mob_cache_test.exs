defmodule Mix.Tasks.Mob.CacheTest do
  use ExUnit.Case, async: true

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
