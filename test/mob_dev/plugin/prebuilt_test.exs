defmodule MobDev.Plugin.PrebuiltTest do
  # MOB_CACHE_DIR is process-global.
  use ExUnit.Case, async: false

  alias MobDev.Plugin.Prebuilt

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    previous = System.get_env("MOB_CACHE_DIR")
    cache = Path.join(tmp, "cache")
    System.put_env("MOB_CACHE_DIR", cache)

    on_exit(fn ->
      if previous,
        do: System.put_env("MOB_CACHE_DIR", previous),
        else: System.delete_env("MOB_CACHE_DIR")
    end)

    %{cache: cache}
  end

  # A bundle shaped like Filament's: <top>/include/… and per-slice archives.
  defp make_bundle(tmp) do
    src = Path.join(tmp, "src")
    File.mkdir_p!(Path.join(src, "fil/include/fil"))
    File.write!(Path.join(src, "fil/include/fil/Engine.h"), "// header\n")

    for slice <- ["ios-arm64", "ios-arm64_x86_64-simulator"] do
      dir = Path.join(src, "fil/lib/libfil.xcframework/#{slice}")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "libfil.a"), "!<arch>\n#{slice}\n")
    end

    tarball = Path.join(tmp, "fil-v1.0-ios.tgz")
    {_, 0} = System.cmd("tar", ["czf", tarball, "-C", src, "fil"])
    sha = :crypto.hash(:sha256, File.read!(tarball)) |> Base.encode16(case: :lower)

    %{
      url: "file://" <> tarball,
      sha256: sha,
      static_libs: %{
        ios_sim: ["fil/lib/libfil.xcframework/ios-arm64_x86_64-simulator/libfil.a"],
        ios_device: ["fil/lib/libfil.xcframework/ios-arm64/libfil.a"]
      }
    }
  end

  defp spec(prebuilt, includes) do
    %{module: :x_nif, plugin: :p, includes: includes, prebuilt: prebuilt}
  end

  describe "dir/1" do
    test "is keyed by the URL's file name and the sha256 prefix, under MOB_CACHE_DIR", %{
      cache: cache
    } do
      sha = String.duplicate("ab", 32)

      assert Prebuilt.dir(%{url: "https://h/r/filament-v1.75.1-ios.tgz", sha256: sha}) ==
               Path.join([cache, "plugin-prebuilt", "filament-v1.75.1-ios-abababababab"])

      other = String.duplicate("cd", 32)

      refute Prebuilt.dir(%{url: "https://h/r/filament-v1.75.1-ios.tgz", sha256: other}) ==
               Prebuilt.dir(%{url: "https://h/r/filament-v1.75.1-ios.tgz", sha256: sha})
    end
  end

  describe "resolve_includes/2 and static_libs/3" do
    test "only {:prebuilt, _} includes resolve against the bundle root" do
      assert Prebuilt.resolve_includes(
               ["/plug/priv/native/ios", {:prebuilt, "fil/include"}, {:dep, :d, "inc"}],
               "/cache/fil"
             ) == ["/plug/priv/native/ios", "/cache/fil/fil/include", {:dep, :d, "inc"}]
    end

    test "libs are per target; an unlisted target links none" do
      p = %{static_libs: %{ios_sim: ["a/sim.a"], ios_device: ["a/dev.a", "b/dev.a"]}}

      assert Prebuilt.static_libs(p, :ios_sim, "/r") == ["/r/a/sim.a"]
      assert Prebuilt.static_libs(p, :ios_device, "/r") == ["/r/a/dev.a", "/r/b/dev.a"]
      assert Prebuilt.static_libs(p, :android_arm64, "/r") == []
      assert Prebuilt.static_libs(%{}, :ios_sim, "/r") == []
    end
  end

  describe "prepare/2" do
    test "a spec without :prebuilt passes through with no libs" do
      s = %{module: :x, plugin: :p, includes: ["/inc"]}
      assert Prebuilt.prepare(s, :ios_sim) == {:ok, s, []}
    end

    test "a {:prebuilt, _} include without a :prebuilt bundle is an error" do
      s = %{module: :x, plugin: :p, includes: [{:prebuilt, "inc"}]}
      assert {:error, msg} = Prebuilt.prepare(s, :ios_sim)
      assert msg =~ "no :prebuilt declared"
    end

    test "downloads, verifies and extracts once; resolves includes and the target's libs", %{
      tmp_dir: tmp
    } do
      prebuilt = make_bundle(tmp)
      s = spec(prebuilt, ["/plug/ios", {:prebuilt, "fil/include"}])

      assert {:ok, ready, [sim_lib]} = Prebuilt.prepare(s, :ios_sim)
      root = Prebuilt.dir(prebuilt)
      assert ready.includes == ["/plug/ios", Path.join(root, "fil/include")]
      assert File.regular?(Path.join(root, "fil/include/fil/Engine.h"))

      assert sim_lib ==
               Path.join(root, "fil/lib/libfil.xcframework/ios-arm64_x86_64-simulator/libfil.a")

      assert File.read!(sim_lib) =~ "simulator"

      # The second target reuses the cache: the source tarball is gone, so a
      # re-download would fail.
      File.rm!(String.replace_prefix(prebuilt.url, "file://", ""))
      assert {:ok, _, [dev_lib]} = Prebuilt.prepare(s, :ios_device)
      assert File.read!(dev_lib) =~ "ios-arm64\n"
    end

    test "a tarball that doesn't match the pinned sha256 is refused and nothing is cached", %{
      tmp_dir: tmp
    } do
      prebuilt = %{make_bundle(tmp) | sha256: String.duplicate("0", 64)}

      assert {:error, msg} = Prebuilt.prepare(spec(prebuilt, []), :ios_sim)
      assert msg =~ "pins #{String.duplicate("0", 64)}"
      refute File.exists?(Prebuilt.dir(prebuilt))
    end

    test "a cache recorded for another hash is replaced", %{tmp_dir: tmp} do
      prebuilt = make_bundle(tmp)
      root = Prebuilt.dir(prebuilt)
      File.mkdir_p!(root)
      File.write!(Path.join(root, ".mob_prebuilt_sha256"), String.duplicate("f", 64))

      assert {:ok, _, [lib]} = Prebuilt.prepare(spec(prebuilt, []), :ios_sim)
      assert File.regular?(lib)
    end

    test "a listed archive missing from the bundle names it", %{tmp_dir: tmp} do
      prebuilt = make_bundle(tmp)
      prebuilt = put_in(prebuilt, [:static_libs, :ios_sim], ["fil/lib/libnope.a"])

      assert {:error, msg} = Prebuilt.prepare(spec(prebuilt, []), :ios_sim)
      assert msg =~ "has no fil/lib/libnope.a"
    end

    test "a failed download is an error", %{tmp_dir: tmp} do
      prebuilt = %{url: "file://#{tmp}/absent.tgz", sha256: String.duplicate("1", 64)}
      assert {:error, msg} = Prebuilt.prepare(spec(prebuilt, []), :ios_sim)
      assert msg =~ "curl failed"
    end
  end
end
