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

    test "x86_64 drops Arm-only hardening; Arm targets keep it" do
      x86 = CppArchive.cxxflags(spec(), :android_x86_64, [])
      refute Enum.any?(x86, &String.starts_with?(&1, "-mbranch-protection"))
      assert "-std=c++17" in x86

      assert "-mbranch-protection=standard" in CppArchive.cxxflags(spec(), :android_arm64, [])

      c =
        CppArchive.cflags(
          spec(%{cflags_android: ["-mbranch-protection=standard"]}),
          :android_x86_64,
          []
        )

      refute "-mbranch-protection=standard" in c
    end
  end

  describe "cflags/3" do
    test "takes :cflags + the platform's cflags, never the C++ flags" do
      s =
        spec(%{
          cflags: ["-std=c11", "-O3"],
          cflags_android: ["-android-c"],
          cflags_ios: ["-ios-c"]
        })

      flags = CppArchive.cflags(s, :android_arm64, ["/inc"])

      assert hd(flags) == "-fPIC"
      assert "-std=c11" in flags
      assert "-android-c" in flags
      assert "-I/inc" in flags
      refute "-std=c++17" in flags
      refute "-mbranch-protection=standard" in flags
      refute "-ios-c" in flags

      assert "-ios-c" in CppArchive.cflags(s, :ios_sim, [])
    end

    test "android_arm32 C objects get the armv7 ABI flags too" do
      assert "-mfloat-abi=softfp" in CppArchive.cflags(spec(), :android_arm32, [])
    end
  end

  describe "object_name/1" do
    test "same basename in different directories gives different objects" do
      a = CppArchive.object_name("/p/ggml-cpu/quants.c")
      b = CppArchive.object_name("/p/ggml-cpu/arch/arm/quants.c")

      assert a =~ ~r/^quants-[0-9a-f]{8}\.o$/
      assert b =~ ~r/^quants-[0-9a-f]{8}\.o$/
      refute a == b
      assert a == CppArchive.object_name("/p/ggml-cpu/quants.c")
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
      assert [_, _] = info.objects
    end

    test "a .c source compiles with clang and CFLAGS; same-named sources keep separate objects" do
      s =
        spec(%{
          sources: ["/p/ggml.c", "/p/cpu/quants.c", "/p/cpu/arm/quants.c", "/p/whisper.cpp"],
          cflags: ["-std=c11"]
        })

      Mox.stub(MobDev.Release.ShellMock, :file?, fn _ -> true end)
      Mox.stub(MobDev.Release.ShellMock, :mkdir_p, fn _ -> :ok end)
      Mox.stub(MobDev.Release.ShellMock, :rm_f, fn _ -> :ok end)
      test_pid = self()

      Mox.stub(MobDev.Release.ShellMock, :cmd, fn argv, _ ->
        cond do
          "-c" in argv ->
            send(test_pid, {:compile, Enum.at(argv, 3), List.last(argv), argv})
            {:ok, ""}

          Enum.at(argv, 3) == "nm" ->
            {:ok, "0000000000000000 T _nx_eigen_nif_init\n"}

          true ->
            {:ok, ""}
        end
      end)

      assert {:ok, info} =
               CppArchive.build(s, :ios_device,
                 out_dir: "/o",
                 erts_include: "/e",
                 deps_path: "/d"
               )

      compiles =
        for _ <- 1..4 do
          assert_receive {:compile, driver, src, argv}
          {src, {driver, argv}}
        end
        |> Map.new()

      for c <- ["/p/ggml.c", "/p/cpu/quants.c", "/p/cpu/arm/quants.c"] do
        {driver, argv} = compiles[c]
        assert driver == "clang"
        assert "-std=c11" in argv
        refute "-std=c++17" in argv
        refute "-stdlib=libc++" in argv
      end

      {driver, argv} = compiles["/p/whisper.cpp"]
      assert driver == "clang++"
      assert "-std=c++17" in argv
      refute "-std=c11" in argv

      assert [_, _, _, last] = Enum.uniq(info.objects)
      assert Path.basename(last) =~ ~r/^whisper-/
    end

    test "an Objective-C .m source compiles with clang and CFLAGS, .mm with clang++" do
      # An ObjC NIF archived beside an ObjC++ renderer (mob_scene3d, MOB-427):
      # through clang++ the .m would be Objective-C handed -std=gnu++17, which
      # clang rejects.
      s =
        spec(%{
          sources: ["/p/scene_nif.m", "/p/SceneView.mm"],
          cxxflags: ["-std=gnu++17"],
          cflags_ios: ["-fobjc-arc"]
        })

      Mox.stub(MobDev.Release.ShellMock, :file?, fn _ -> true end)
      Mox.stub(MobDev.Release.ShellMock, :mkdir_p, fn _ -> :ok end)
      Mox.stub(MobDev.Release.ShellMock, :rm_f, fn _ -> :ok end)
      test_pid = self()

      Mox.stub(MobDev.Release.ShellMock, :cmd, fn argv, _ ->
        cond do
          "-c" in argv ->
            send(test_pid, {:compile, Enum.at(argv, 3), List.last(argv), argv})
            {:ok, ""}

          Enum.at(argv, 3) == "nm" ->
            {:ok, "0000000000000000 T _nx_eigen_nif_init\n"}

          true ->
            {:ok, ""}
        end
      end)

      assert {:ok, _} =
               CppArchive.build(s, :ios_sim, out_dir: "/o", erts_include: "/e", deps_path: "/d")

      compiles =
        for _ <- 1..2, into: %{} do
          assert_receive {:compile, driver, src, argv}
          {src, {driver, argv}}
        end

      {driver, argv} = compiles["/p/scene_nif.m"]
      assert driver == "clang"
      assert "-fobjc-arc" in argv
      refute "-std=gnu++17" in argv

      {driver, argv} = compiles["/p/SceneView.mm"]
      assert driver == "clang++"
      assert "-std=gnu++17" in argv
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
