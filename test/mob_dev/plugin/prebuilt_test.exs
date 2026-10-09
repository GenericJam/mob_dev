defmodule MobDev.Plugin.PrebuiltTest do
  # MOB_CACHE_DIR / MOB_PLUGIN_PREBUILT_DIR are process-global.
  use ExUnit.Case, async: false

  alias MobDev.Plugin.Prebuilt

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    saved = for k <- ["MOB_CACHE_DIR", "MOB_PLUGIN_PREBUILT_DIR"], do: {k, System.get_env(k)}
    cache = Path.join(tmp, "cache")
    mirror = Path.join(tmp, "mirror")
    File.mkdir_p!(mirror)
    System.put_env("MOB_CACHE_DIR", cache)
    System.put_env("MOB_PLUGIN_PREBUILT_DIR", mirror)

    on_exit(fn ->
      for {k, v} <- saved, do: if(v, do: System.put_env(k, v), else: System.delete_env(k))
    end)

    %{cache: cache, mirror: mirror}
  end

  # A bundle shaped like Filament's (<top>/include/…, per-slice archives),
  # placed in the MOB_PLUGIN_PREBUILT_DIR mirror under its URL's file name.
  defp make_bundle(tmp, mirror) do
    src = Path.join(tmp, "src")
    File.mkdir_p!(Path.join(src, "fil/include/fil"))
    File.write!(Path.join(src, "fil/include/fil/Engine.h"), "// header\n")

    for slice <- ["ios-arm64", "ios-arm64_x86_64-simulator"] do
      dir = Path.join(src, "fil/lib/libfil.xcframework/#{slice}")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "libfil.a"), "!<arch>\n#{slice}\n")
    end

    tarball = Path.join(mirror, "fil-v1.0-ios.tgz")
    {_, 0} = System.cmd("tar", ["czf", tarball, "-C", src, "fil"])

    %{
      url: "https://example.invalid/releases/fil-v1.0-ios.tgz",
      sha256: :crypto.hash(:sha256, File.read!(tarball)) |> Base.encode16(case: :lower),
      static_libs: %{
        ios_sim: ["fil/lib/libfil.xcframework/ios-arm64_x86_64-simulator/libfil.a"],
        ios_device: ["fil/lib/libfil.xcframework/ios-arm64/libfil.a"]
      }
    }
  end

  defp spec(prebuilt, includes \\ []),
    do: %{module: :x_nif, plugin: :p, includes: includes, prebuilt: prebuilt}

  describe "errors/1" do
    test "a well-formed bundle has none" do
      assert Prebuilt.errors(%{
               url: "https://h/f.tgz",
               sha256: String.duplicate("a1", 32),
               static_libs: %{ios_sim: ["lib/a.a"], android_arm64: []}
             }) == []
    end

    test "names each malformed field" do
      errs =
        Prebuilt.errors(%{
          url: "file:///tmp/f.tgz",
          sha256: "ABC",
          static_libs: %{ios: ["a.a"], ios_sim: ["../a.a"], ios_device: ["/abs/a.a"]}
        })

      assert Enum.any?(errs, &(&1 =~ ":url must be an https:// URL"))
      assert Enum.any?(errs, &(&1 =~ "64 lowercase hex"))
      assert Enum.any?(errs, &(&1 =~ "key :ios is not one of"))
      assert Enum.count(errs, &(&1 =~ "relative paths inside the bundle")) == 2

      assert Prebuilt.errors("https://h/f.tgz") == [
               ~s(:prebuilt must be a map, got: "https://h/f.tgz")
             ]
    end
  end

  describe "dir/1" do
    test "is keyed by the URL's file name and the sha256 prefix, under MOB_CACHE_DIR", %{
      cache: cache
    } do
      a = %{url: "https://h/r/filament-v1.75.1-ios.tgz", sha256: String.duplicate("ab", 32)}
      b = %{a | sha256: String.duplicate("cd", 32)}

      assert Prebuilt.dir(a) ==
               Path.join([cache, "plugin-prebuilt", "filament-v1.75.1-ios-abababababab"])

      refute Prebuilt.dir(a) == Prebuilt.dir(b)
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

    test "fetches, verifies and extracts once; resolves includes and the target's libs", %{
      tmp_dir: tmp,
      mirror: mirror
    } do
      prebuilt = make_bundle(tmp, mirror)
      s = spec(prebuilt, ["/plug/ios", {:prebuilt, "fil/include"}])

      assert {:ok, ready, [sim_lib]} = Prebuilt.prepare(s, :ios_sim)
      root = Prebuilt.dir(prebuilt)
      assert ready.includes == ["/plug/ios", Path.join(root, "fil/include")]
      assert File.regular?(Path.join(root, "fil/include/fil/Engine.h"))

      assert sim_lib ==
               Path.join(root, "fil/lib/libfil.xcframework/ios-arm64_x86_64-simulator/libfil.a")

      assert File.read!(sim_lib) =~ "simulator"

      # The second target reuses the cache: with the source tarball gone a
      # fresh fetch would fail.
      File.rm!(Path.join(mirror, "fil-v1.0-ios.tgz"))
      assert {:ok, _, [dev_lib]} = Prebuilt.prepare(s, :ios_device)
      assert File.read!(dev_lib) =~ "ios-arm64\n"
      assert Path.wildcard(root <> ".partial-*") == []
    end

    test "a malformed :prebuilt or an escaping include is refused before any fetch", %{
      tmp_dir: tmp,
      mirror: mirror
    } do
      prebuilt = make_bundle(tmp, mirror)

      assert {:error, msg} = Prebuilt.prepare(spec(%{prebuilt | url: "http://h/f.tgz"}), :ios_sim)
      assert msg =~ "plugin cpp_archive p/x_nif: :prebuilt :url must be an https:// URL"

      assert {:error, msg} = Prebuilt.prepare(spec(prebuilt, [{:prebuilt, "../etc"}]), :ios_sim)
      assert msg =~ "must stay inside the bundle"

      refute File.exists?(Prebuilt.dir(prebuilt))
    end

    test "a tarball that doesn't match the pinned sha256 is refused and nothing is cached", %{
      tmp_dir: tmp,
      mirror: mirror
    } do
      prebuilt = %{make_bundle(tmp, mirror) | sha256: String.duplicate("0", 64)}

      assert {:error, msg} = Prebuilt.prepare(spec(prebuilt), :ios_sim)
      assert msg =~ "pins #{String.duplicate("0", 64)}"
      refute File.exists?(Prebuilt.dir(prebuilt))
    end

    test "a cache recorded for another hash is replaced", %{tmp_dir: tmp, mirror: mirror} do
      prebuilt = make_bundle(tmp, mirror)
      root = Prebuilt.dir(prebuilt)
      File.mkdir_p!(root)
      File.write!(Path.join(root, ".mob_prebuilt_sha256"), String.duplicate("f", 64))

      assert {:ok, _, [lib]} = Prebuilt.prepare(spec(prebuilt), :ios_sim)
      assert File.regular?(lib)
    end

    test "stale partial extractions are swept, recent ones (a running build's) are kept", %{
      tmp_dir: tmp,
      mirror: mirror
    } do
      prebuilt = make_bundle(tmp, mirror)
      root = Prebuilt.dir(prebuilt)
      stale = root <> ".partial-111-1"
      live = root <> ".partial-222-2"
      for d <- [stale, live], do: File.mkdir_p!(d)
      File.touch!(stale, System.os_time(:second) - 7200)

      assert {:ok, _, _} = Prebuilt.prepare(spec(prebuilt), :ios_sim)
      refute File.exists?(stale)
      assert File.dir?(live)
    end

    test "a listed archive missing from the bundle names it", %{tmp_dir: tmp, mirror: mirror} do
      prebuilt = make_bundle(tmp, mirror)
      prebuilt = put_in(prebuilt, [:static_libs, :ios_sim], ["fil/lib/libnope.a"])

      assert {:error, msg} = Prebuilt.prepare(spec(prebuilt), :ios_sim)
      assert msg =~ "has no fil/lib/libnope.a"
    end

    test "a tarball missing from MOB_PLUGIN_PREBUILT_DIR is an error naming it" do
      prebuilt = %{url: "https://h/absent.tgz", sha256: String.duplicate("1", 64)}
      assert {:error, msg} = Prebuilt.prepare(spec(prebuilt), :ios_sim)
      assert msg =~ "absent.tgz is not there"
    end

    test "an unreadable local tarball is an error message, not a crash", %{
      tmp_dir: tmp,
      mirror: mirror
    } do
      prebuilt = make_bundle(tmp, mirror)
      local = Path.join(mirror, "fil-v1.0-ios.tgz")
      File.chmod!(local, 0o000)
      on_exit(fn -> File.chmod(local, 0o644) end)

      assert {:error, msg} = Prebuilt.prepare(spec(prebuilt), :ios_sim)
      assert msg =~ "could not open #{local}"
    end

    test "an unwritable cache is an error message, not a crash", %{tmp_dir: tmp, mirror: mirror} do
      prebuilt = make_bundle(tmp, mirror)
      # A file where the cache's plugin-prebuilt directory must go.
      File.mkdir_p!(Path.join(tmp, "cache"))
      File.write!(Path.join(tmp, "cache/plugin-prebuilt"), "not a dir")

      assert {:error, msg} = Prebuilt.prepare(spec(prebuilt), :ios_sim)
      assert msg =~ "could not create"
    end
  end
end
