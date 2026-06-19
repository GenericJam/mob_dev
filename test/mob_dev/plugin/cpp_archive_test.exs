defmodule MobDev.Plugin.CppArchiveTest do
  use ExUnit.Case, async: false

  import Mox

  alias MobDev.Plugin.CppArchive

  setup :verify_on_exit!

  setup do
    Application.put_env(:mob_dev, :release_shell, MobDev.Release.ShellMock)
    on_exit(fn -> Application.delete_env(:mob_dev, :release_shell) end)
    :ok
  end

  defp spec(extra \\ %{}) do
    Map.merge(
      %{
        module: :nx_eigen_nif,
        sources: ["/plug/c_src/nx_eigen_nif.cpp", "/plug/c_src/fft.cpp"],
        includes: ["/plug/c_src"],
        cxxflags: ["-std=c++17", "-DSTATIC_ERLANG_NIF_LIBNAME=nx_eigen"],
        cxxflags_android: ["-mbranch-protection=standard"],
        cxxflags_ios: [],
        nm_symbol: "nx_eigen_nif_init"
      },
      extra
    )
  end

  # ── Pure surface ──────────────────────────────────────────────────────

  describe "cxxflags/3" do
    test "forces -fPIC first, then base, then android flags, then -I includes" do
      flags = CppArchive.cxxflags(spec(), :android_arm64, ["/inc/a", "/inc/b"])

      assert hd(flags) == "-fPIC"
      assert "-std=c++17" in flags
      assert "-DSTATIC_ERLANG_NIF_LIBNAME=nx_eigen" in flags
      assert "-mbranch-protection=standard" in flags
      assert "-I/inc/a" in flags
      assert "-I/inc/b" in flags
    end

    test "uses cxxflags_ios (not android) on an iOS target" do
      s = spec(%{cxxflags_android: ["-android-only"], cxxflags_ios: ["-ios-only"]})
      flags = CppArchive.cxxflags(s, :ios_device, [])

      assert "-ios-only" in flags
      refute "-android-only" in flags
    end

    test "preserves include order" do
      flags = CppArchive.cxxflags(spec(), :ios_sim, ["/first", "/second", "/third"])
      includes = Enum.filter(flags, &String.starts_with?(&1, "-I"))
      assert includes == ["-I/first", "-I/second", "-I/third"]
    end

    test "android_arm32 gets the armv7 ABI flags; arm64 does not" do
      arm32 = CppArchive.cxxflags(spec(), :android_arm32, [])
      arm64 = CppArchive.cxxflags(spec(), :android_arm64, [])

      assert "-march=armv7-a" in arm32
      assert "-mfloat-abi=softfp" in arm32
      assert "-mthumb" in arm32

      refute "-march=armv7-a" in arm64
    end
  end

  describe "resolve_deps/2" do
    test "resolves {:dep, name, sub} tokens against deps_path, passes strings through" do
      entries = ["/plug/c_src", {:dep, :nx_eigen, "eigen-3.4.0"}, {:dep, :fine, "c_include"}]

      assert CppArchive.resolve_deps(entries, "/proj/deps") == [
               "/plug/c_src",
               "/proj/deps/nx_eigen/eigen-3.4.0",
               "/proj/deps/fine/c_include"
             ]
    end

    test "resolves a dep-sourced .cpp path (NxEigen's NIF lives in the nx_eigen dep)" do
      assert CppArchive.resolve_deps([{:dep, :nx_eigen, "c_src/nx_eigen_nif.cpp"}], "/d") ==
               ["/d/nx_eigen/c_src/nx_eigen_nif.cpp"]
    end
  end

  describe "archive_name/1" do
    test "is lib<module>.a" do
      assert CppArchive.archive_name(:nx_eigen_nif) == "libnx_eigen_nif.a"
    end
  end

  describe "check_symbol_present/3" do
    test ":ok when the T symbol is present" do
      assert CppArchive.check_symbol_present(
               "0000000000000000 T nx_eigen_nif_init\n",
               "nx_eigen_nif_init",
               "/x/lib.a"
             ) == :ok
    end

    test "precondition_failed when missing" do
      assert {:error, {:precondition_failed, msg}} =
               CppArchive.check_symbol_present("0000 t other\n", "nx_eigen_nif_init", "/x/lib.a")

      assert msg =~ "nx_eigen_nif_init"
    end
  end

  # ── build/3 option + spec validation ──────────────────────────────────

  describe "build/3 — required options/fields" do
    test "missing :out_dir is a precondition_failed" do
      assert {:error, {:precondition_failed, msg}} = CppArchive.build(spec(), :ios_device, [])
      assert msg =~ ":out_dir"
    end

    test "missing :erts_include is a precondition_failed" do
      assert {:error, {:precondition_failed, msg}} =
               CppArchive.build(spec(), :ios_device, out_dir: "/o")

      assert msg =~ ":erts_include"
    end

    test "missing :nm_symbol in spec is a precondition_failed" do
      s = Map.delete(spec(), :nm_symbol)

      assert {:error, {:precondition_failed, msg}} =
               CppArchive.build(s, :ios_device, out_dir: "/o", erts_include: "/e")

      assert msg =~ ":nm_symbol"
    end
  end

  # ── build/3 full sequence ─────────────────────────────────────────────

  describe "build/3 — ios_device full sequence" do
    test "xcrun clang++ compile per source, archive, verify Mach-O (underscored) symbol" do
      Mox.stub(MobDev.Release.ShellMock, :file?, fn _ -> true end)
      Mox.expect(MobDev.Release.ShellMock, :mkdir_p, 2, fn _ -> :ok end)

      # one compile per source (2)
      Mox.expect(MobDev.Release.ShellMock, :cmd, 2, fn argv, _ ->
        assert Enum.take(argv, 4) == ["xcrun", "-sdk", "iphoneos", "clang++"]
        assert "-fPIC" in argv
        assert "-c" in argv
        assert "-std=c++17" in argv
        {:ok, ""}
      end)

      Mox.expect(MobDev.Release.ShellMock, :rm_f, fn _ -> :ok end)
      # ar
      Mox.expect(MobDev.Release.ShellMock, :cmd, fn argv, _ ->
        assert "rcs" in argv
        {:ok, ""}
      end)

      # ranlib
      Mox.expect(MobDev.Release.ShellMock, :cmd, fn _argv, _ -> {:ok, ""} end)
      # nm — Mach-O underscored symbol
      Mox.expect(MobDev.Release.ShellMock, :cmd, fn argv, _ ->
        assert List.last(argv) =~ "libnx_eigen_nif.a"
        {:ok, "0000000000000000 T _nx_eigen_nif_init\n"}
      end)

      assert {:ok, info} =
               CppArchive.build(spec(), :ios_device,
                 out_dir: "/fake/out",
                 erts_include: "/fake/erts/include",
                 deps_path: "/fake/deps"
               )

      assert info.module == :nx_eigen_nif
      assert info.archive == "/fake/out/libnx_eigen_nif.a"
      assert length(info.objects) == 2
    end
  end

  describe "build/3 — android source precheck" do
    # The android happy-path compile sequence isn't unit-tested: android_precheck
    # validates the real NDK toolchain on disk (File.dir? + NdkVersion.installed?),
    # which would make the test non-hermetic in CI — same reason MobDev.NxEigenNif
    # only unit-tests its iOS sequence. The android compile argv + flags are
    # covered by cxxflags/3; here we cover the source precheck, which runs first.

    test "missing source files short-circuits to precondition_failed" do
      Mox.stub(MobDev.Release.ShellMock, :file?, fn _ -> false end)
      Mox.stub(MobDev.Release.ShellMock, :dir?, fn _ -> true end)

      assert {:error, {:precondition_failed, msg}} =
               CppArchive.build(spec(), :android_arm64,
                 out_dir: "/o",
                 erts_include: "/e",
                 deps_path: "/d",
                 ndk_root: "/fake/ndk"
               )

      assert msg =~ "sources missing"
    end
  end
end
