defmodule MobDev.MLXDownloaderTest do
  # async: false — these tests put/delete MOB_CACHE_DIR and
  # MOB_MLX_LOCAL_TARBALL_DIR, which are process-global. Running async with
  # any other test that reads MOB_CACHE_DIR can cause one test to
  # extract into the real ~/.mob/cache/ (overwriting actual cached
  # tarballs with 17-byte test stubs — seen in the wild once already
  # during this session's iPhone device deploy).
  use ExUnit.Case, async: false

  alias MobDev.MLXDownloader

  # ── dir/1, cache_dir/0 ──────────────────────────────────────────────────────

  describe "dir/1" do
    test "honors MOB_CACHE_DIR env var" do
      System.put_env("MOB_CACHE_DIR", "/tmp/mob_test_cache_mlx")

      try do
        assert MLXDownloader.dir(:ios_device) =~ "/tmp/mob_test_cache_mlx/libmlx-"
        assert MLXDownloader.dir(:ios_sim) =~ "/tmp/mob_test_cache_mlx/libmlx-"
      after
        System.delete_env("MOB_CACHE_DIR")
      end
    end

    test "defaults to ~/.mob/cache when MOB_CACHE_DIR unset" do
      System.delete_env("MOB_CACHE_DIR")
      home = System.get_env("HOME")
      assert String.starts_with?(MLXDownloader.dir(:ios_device), "#{home}/.mob/cache/")
    end

    test "uses different paths for device vs sim" do
      System.put_env("MOB_CACHE_DIR", "/tmp/mob_test_cache_mlx")

      try do
        refute MLXDownloader.dir(:ios_device) == MLXDownloader.dir(:ios_sim)
      after
        System.delete_env("MOB_CACHE_DIR")
      end
    end
  end

  # ── name/1, tarball_name/1, download_url/1 ──────────────────────────────────

  describe "name/1" do
    test "ios_device" do
      assert MLXDownloader.name(:ios_device) == "libmlx-#{MLXDownloader.mlx_version()}-ios-device"
    end

    test "ios_sim" do
      assert MLXDownloader.name(:ios_sim) == "libmlx-#{MLXDownloader.mlx_version()}-ios-sim"
    end
  end

  describe "tarball_name/1" do
    test "appends .tar.gz" do
      assert MLXDownloader.tarball_name(:ios_device) =~
               ~r/^libmlx-\d+\.\d+\.\d+-ios-device\.tar\.gz$/
    end
  end

  describe "download_url/1" do
    test "points at the mob release surface for the pinned MLX tag" do
      url = MLXDownloader.download_url(:ios_device)

      assert String.starts_with?(
               url,
               "https://github.com/GenericJam/mob/releases/download/"
             )

      assert String.ends_with?(url, ".tar.gz")
      assert url =~ MLXDownloader.release_tag()
    end
  end

  describe "release_tag/0" do
    test "embeds the MLX version" do
      assert MLXDownloader.release_tag() == "mlx-#{MLXDownloader.mlx_version()}"
    end
  end

  # ── valid_dir?/1 ────────────────────────────────────────────────────────────

  describe "valid_dir?/1" do
    @tag :tmp_dir
    test "returns false when dir doesn't exist", %{tmp_dir: tmp} do
      refute MLXDownloader.valid_dir?(Path.join(tmp, "nonexistent"))
    end

    @tag :tmp_dir
    test "returns false on empty dir", %{tmp_dir: tmp} do
      refute MLXDownloader.valid_dir?(tmp)
    end

    @tag :tmp_dir
    test "returns false when only libmlx.a present", %{tmp_dir: tmp} do
      File.mkdir_p!(Path.join(tmp, "lib"))
      File.write!(Path.join([tmp, "lib", "libmlx.a"]), "stub")
      refute MLXDownloader.valid_dir?(tmp)
    end

    @tag :tmp_dir
    test "returns false when libemlx.a missing", %{tmp_dir: tmp} do
      File.mkdir_p!(Path.join(tmp, "lib"))
      File.mkdir_p!(Path.join([tmp, "include", "mlx"]))
      File.write!(Path.join([tmp, "lib", "libmlx.a"]), "stub")
      File.write!(Path.join(tmp, "VERSION"), "mlx_version=0.25.1")
      refute MLXDownloader.valid_dir?(tmp)
    end

    @tag :tmp_dir
    test "returns true on a complete bundle", %{tmp_dir: tmp} do
      stub_complete_bundle(tmp)
      assert MLXDownloader.valid_dir?(tmp)
    end
  end

  # ── ensure/1 against a local tarball (the MOB_MLX_LOCAL_TARBALL_DIR path) ──

  describe "ensure/1 with MOB_MLX_LOCAL_TARBALL_DIR" do
    @tag :tmp_dir
    test "uses a locally-built tarball when env var is set", %{tmp_dir: tmp} do
      # Stage a fake tarball under tmp/, point MOB_MLX_LOCAL_TARBALL_DIR at it,
      # and confirm ensure/1 unpacks it into the cache.
      tarball_dir = Path.join(tmp, "local")
      File.mkdir_p!(tarball_dir)
      stage_tarball(tarball_dir, :ios_device)

      cache = Path.join(tmp, "cache")
      System.put_env("MOB_CACHE_DIR", cache)
      System.put_env("MOB_MLX_LOCAL_TARBALL_DIR", tarball_dir)

      try do
        assert {:ok, dir} = MLXDownloader.ensure(:ios_device)
        assert MLXDownloader.valid_dir?(dir)
        assert File.read!(Path.join(dir, "VERSION")) =~ "mlx_version="
      after
        System.delete_env("MOB_CACHE_DIR")
        System.delete_env("MOB_MLX_LOCAL_TARBALL_DIR")
      end
    end

    @tag :tmp_dir
    test "returns error when local tarball is missing", %{tmp_dir: tmp} do
      empty_dir = Path.join(tmp, "empty")
      File.mkdir_p!(empty_dir)

      System.put_env("MOB_CACHE_DIR", Path.join(tmp, "cache"))
      System.put_env("MOB_MLX_LOCAL_TARBALL_DIR", empty_dir)

      try do
        assert {:error, msg} = MLXDownloader.ensure(:ios_device)
        assert msg =~ "MOB_MLX_LOCAL_TARBALL_DIR"
      after
        System.delete_env("MOB_CACHE_DIR")
        System.delete_env("MOB_MLX_LOCAL_TARBALL_DIR")
      end
    end

    @tag :tmp_dir
    test "returns valid cache without re-extracting on second call", %{tmp_dir: tmp} do
      tarball_dir = Path.join(tmp, "local")
      File.mkdir_p!(tarball_dir)
      stage_tarball(tarball_dir, :ios_device)

      cache = Path.join(tmp, "cache")
      System.put_env("MOB_CACHE_DIR", cache)
      System.put_env("MOB_MLX_LOCAL_TARBALL_DIR", tarball_dir)

      try do
        assert {:ok, dir1} = MLXDownloader.ensure(:ios_device)

        # Touch a marker file to detect re-extraction.
        marker = Path.join(dir1, "marker.txt")
        File.write!(marker, "x")

        assert {:ok, ^dir1} = MLXDownloader.ensure(:ios_device)
        assert File.read!(marker) == "x", "second ensure/1 should reuse cache, not re-extract"
      after
        System.delete_env("MOB_CACHE_DIR")
        System.delete_env("MOB_MLX_LOCAL_TARBALL_DIR")
      end
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  # Build the layout MLXDownloader.valid_dir?/1 expects, directly on disk.
  defp stub_complete_bundle(dir) do
    File.mkdir_p!(Path.join(dir, "lib"))
    File.mkdir_p!(Path.join([dir, "include", "mlx"]))
    File.write!(Path.join([dir, "lib", "libmlx.a"]), "stub-mlx-archive")
    File.write!(Path.join([dir, "lib", "libemlx.a"]), "stub-emlx-archive")
    File.write!(Path.join(dir, "VERSION"), "mlx_version=stub\nvariant=test\n")
  end

  # Stage a real tarball with the same name MLXDownloader expects, so
  # the local-tarball path can extract + verify_layout it end-to-end.
  defp stage_tarball(target_dir, target) do
    stage_root = Path.join(target_dir, "stage")
    bundle_dir = Path.join(stage_root, MLXDownloader.name(target))
    stub_complete_bundle(bundle_dir)

    tar_out = Path.join(target_dir, MLXDownloader.tarball_name(target))

    {_, 0} =
      System.cmd("tar", ["-czf", tar_out, "-C", stage_root, MLXDownloader.name(target)])

    File.rm_rf!(stage_root)
    tar_out
  end
end
