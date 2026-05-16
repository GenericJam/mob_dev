defmodule MobDev.NxEigenNifTest do
  use ExUnit.Case, async: false

  import Mox

  alias MobDev.NxEigenNif

  setup :verify_on_exit!

  setup do
    Application.put_env(:mob_dev, :release_shell, MobDev.Release.ShellMock)
    on_exit(fn -> Application.delete_env(:mob_dev, :release_shell) end)
    :ok
  end

  # ── Source list — surface lock ────────────────────────────────────────

  describe "sources/0" do
    test "compiles the main NIF (from nx_eigen) + the Eigen-FFT bridge (from mob_dev priv)" do
      srcs = NxEigenNif.sources()

      assert {:nx_eigen, "nx_eigen_nif.cpp"} in srcs
      assert {:bridge, "nx_eigen_fft_eigen.cpp"} in srcs

      # NxEigen's own FFT variants are NOT compiled — we use Eigen's
      # built-in kissfft via our own bridge file instead.
      basenames = Enum.map(srcs, fn {_root, name} -> name end)
      refute "nx_eigen_fft_fftw.cpp" in basenames
      refute "nx_eigen_fft_none.cpp" in basenames
    end

    test "all entries are .cpp files" do
      assert Enum.all?(NxEigenNif.sources(), fn {_root, name} ->
               String.ends_with?(name, ".cpp")
             end)
    end
  end

  # ── target_spec/1 — pinned surface per target ─────────────────────────

  describe "target_spec/1" do
    test "android_arm64 — aarch64 arch dir, Android hardening, ELF symbol" do
      spec = NxEigenNif.target_spec(:android_arm64)

      assert spec.arch_dir == "aarch64-unknown-linux-android"
      assert spec.nm_symbol == "nx_eigen_nif_init"
      assert "-mbranch-protection=standard" in spec.extra_cxxflags
      assert "-fstack-clash-protection" in spec.extra_cxxflags
      assert "-D_GNU_SOURCE" in spec.extra_cxxflags

      refute "-march=armv7-a" in spec.extra_cxxflags
    end

    test "android_arm32 — ABI flags AND Android hardening" do
      spec = NxEigenNif.target_spec(:android_arm32)

      assert spec.arch_dir == "arm-unknown-linux-androideabi"
      assert spec.nm_symbol == "nx_eigen_nif_init"

      assert "-march=armv7-a" in spec.extra_cxxflags
      assert "-mfloat-abi=softfp" in spec.extra_cxxflags
      assert "-mthumb" in spec.extra_cxxflags

      assert "-mbranch-protection=standard" in spec.extra_cxxflags
      assert "-D_GNU_SOURCE" in spec.extra_cxxflags
    end

    test "ios_sim — Mach-O symbol with leading underscore, no Android flags" do
      spec = NxEigenNif.target_spec(:ios_sim)

      assert spec.arch_dir == "aarch64-apple-iossimulator"
      assert spec.nm_symbol == "_nx_eigen_nif_init"
      assert spec.extra_cxxflags == []
    end

    test "ios_device — distinct from sim (different arch_dir)" do
      sim = NxEigenNif.target_spec(:ios_sim)
      device = NxEigenNif.target_spec(:ios_device)

      assert sim.arch_dir != device.arch_dir
      assert device.arch_dir == "aarch64-apple-ios"
      assert device.nm_symbol == "_nx_eigen_nif_init"
    end

    test "targets/0 enumerates all four" do
      assert NxEigenNif.targets() == [:android_arm64, :android_arm32, :ios_sim, :ios_device]
    end
  end

  # ── cxxflags/2 — pure assembly ────────────────────────────────────────

  describe "cxxflags/2" do
    @no_includes []

    test "every target starts with the same base CXXFLAGS" do
      base = NxEigenNif.base_cxxflags()

      for target_id <- NxEigenNif.targets() do
        spec = NxEigenNif.target_spec(target_id)
        flags = NxEigenNif.cxxflags(spec, @no_includes)

        for base_flag <- base do
          assert base_flag in flags, "target #{target_id} missing base flag #{base_flag}"
        end
      end
    end

    test "every target compiles as C++17" do
      for target_id <- NxEigenNif.targets() do
        spec = NxEigenNif.target_spec(target_id)
        flags = NxEigenNif.cxxflags(spec, @no_includes)
        assert "-std=c++17" in flags
      end
    end

    test "every target keeps exceptions and RTTI enabled" do
      # Fine + NxEigen rely on exception-based error handling
      # (std::runtime_error / std::invalid_argument from FINE_INIT and
      # decode helpers). Disabling these breaks compilation immediately.
      # Test pins the surface so a future "size optimization" attempt has
      # to actually revisit the dep code before flipping the flag.
      for target_id <- NxEigenNif.targets() do
        spec = NxEigenNif.target_spec(target_id)
        flags = NxEigenNif.cxxflags(spec, @no_includes)
        refute "-fno-exceptions" in flags
        refute "-fno-rtti" in flags
      end
    end

    test "STATIC_ERLANG_NIF_LIBNAME=nx_eigen is set on every target" do
      # This is what forces FINE_INIT to emit nx_eigen_nif_init instead
      # of the literal `NAME_nif_init` symbol Fine's macro produces.
      # Dropping it breaks the entire static-link approach.
      for target_id <- NxEigenNif.targets() do
        spec = NxEigenNif.target_spec(target_id)
        flags = NxEigenNif.cxxflags(spec, @no_includes)
        assert "-DSTATIC_ERLANG_NIF_LIBNAME=nx_eigen" in flags
      end
    end

    test "android targets include the Android hardening flags" do
      for target_id <- [:android_arm64, :android_arm32] do
        spec = NxEigenNif.target_spec(target_id)
        flags = NxEigenNif.cxxflags(spec, @no_includes)

        assert "-mbranch-protection=standard" in flags
        assert "-D_GNU_SOURCE" in flags
      end
    end

    test "iOS targets do NOT include Android hardening flags" do
      for target_id <- [:ios_sim, :ios_device] do
        spec = NxEigenNif.target_spec(target_id)
        flags = NxEigenNif.cxxflags(spec, @no_includes)

        refute "-mbranch-protection=standard" in flags
        refute "-D_GNU_SOURCE" in flags
        refute "-fstack-clash-protection" in flags
      end
    end

    test "include paths are prefixed with -I, in given order, after the flags" do
      spec = NxEigenNif.target_spec(:android_arm64)
      flags = NxEigenNif.cxxflags(spec, ["/eigen", "/fine/c_include", "/erts/include"])

      assert "-I/eigen" in flags
      assert "-I/fine/c_include" in flags
      assert "-I/erts/include" in flags

      eigen_idx = Enum.find_index(flags, &(&1 == "-I/eigen"))
      fine_idx = Enum.find_index(flags, &(&1 == "-I/fine/c_include"))
      erts_idx = Enum.find_index(flags, &(&1 == "-I/erts/include"))

      assert eigen_idx < fine_idx
      assert fine_idx < erts_idx
    end

    test "arm32 emits -march=armv7-a BEFORE Android hardening flags" do
      spec = NxEigenNif.target_spec(:android_arm32)
      flags = NxEigenNif.cxxflags(spec, @no_includes)

      march_idx = Enum.find_index(flags, &(&1 == "-march=armv7-a"))
      branch_idx = Enum.find_index(flags, &(&1 == "-mbranch-protection=standard"))

      assert is_integer(march_idx), "-march=armv7-a not present in #{inspect(flags)}"

      assert is_integer(branch_idx),
             "-mbranch-protection=standard not present in #{inspect(flags)}"

      assert march_idx < branch_idx
    end
  end

  # ── check_symbol_present/3 — pure nm output parser ────────────────────

  describe "check_symbol_present/3" do
    test "accepts ELF nm output with the symbol" do
      output = """
      0000000000000000 T nx_eigen_nif_init
      0000000000000018 T some_helper
      """

      assert :ok =
               NxEigenNif.check_symbol_present(output, "nx_eigen_nif_init", "/path/libnx_eigen.a")
    end

    test "accepts Mach-O nm output (leading underscore)" do
      output = "0000000000000000 T _nx_eigen_nif_init\n"

      assert :ok =
               NxEigenNif.check_symbol_present(
                 output,
                 "_nx_eigen_nif_init",
                 "/path/libnx_eigen.a"
               )
    end

    test "rejects when symbol is undefined (U flag, not T)" do
      # This is the failure mode if FINE_INIT didn't emit the symbol —
      # something else's reference to nx_eigen_nif_init shows up as U.
      output = "                 U nx_eigen_nif_init\n"

      assert {:error, {:precondition_failed, msg}} =
               NxEigenNif.check_symbol_present(output, "nx_eigen_nif_init", "/p/libnx_eigen.a")

      assert msg =~ "T nx_eigen_nif_init"
      assert msg =~ "STATIC_ERLANG_NIF_LIBNAME"
    end

    test "rejects when symbol is missing entirely" do
      output = """
      0000000000000000 T some_other_init
      """

      assert {:error, {:precondition_failed, _}} =
               NxEigenNif.check_symbol_present(output, "nx_eigen_nif_init", "/p/libnx_eigen.a")
    end

    test "rejects when only `NAME_nif_init` is present (LIBNAME wasn't set)" do
      # This is the specific failure mode if -DSTATIC_ERLANG_NIF_LIBNAME
      # gets dropped: Fine's FINE_INIT macro passes the literal token
      # NAME to ERL_NIF_INIT_DECL, which then emits NAME_nif_init as
      # the symbol name. Catch this regression class explicitly.
      output = "0000000000000000 T NAME_nif_init\n"

      assert {:error, {:precondition_failed, _}} =
               NxEigenNif.check_symbol_present(output, "nx_eigen_nif_init", "/p/libnx_eigen.a")
    end

    test "doesn't false-match a leading-substring suffix" do
      output = "0000000000000000 T _nx_eigen_nif_init\n"

      assert {:error, {:precondition_failed, _}} =
               NxEigenNif.check_symbol_present(output, "nx_eigen_nif_init", "/p/libnx_eigen.a")
    end
  end

  # ── build/2 — required-option checking ────────────────────────────────

  describe "build/2 — required options" do
    test "missing :nx_eigen_dir is a precondition_failed" do
      assert {:error, {:precondition_failed, msg}} = NxEigenNif.build(:ios_device, [])
      assert msg =~ ":nx_eigen_dir"
    end

    test "missing :fine_dir is a precondition_failed" do
      assert {:error, {:precondition_failed, msg}} =
               NxEigenNif.build(:ios_device, nx_eigen_dir: "/d")

      assert msg =~ ":fine_dir"
    end

    test "missing :erts_include is a precondition_failed" do
      assert {:error, {:precondition_failed, msg}} =
               NxEigenNif.build(:ios_device, nx_eigen_dir: "/d", fine_dir: "/f")

      assert msg =~ ":erts_include"
    end

    test "missing :out_dir is a precondition_failed" do
      assert {:error, {:precondition_failed, msg}} =
               NxEigenNif.build(:ios_device,
                 nx_eigen_dir: "/d",
                 fine_dir: "/f",
                 erts_include: "/e"
               )

      assert msg =~ ":out_dir"
    end
  end

  # ── build/2 against the Mox — full sequence ───────────────────────────

  describe "build/2 — ios_device full sequence" do
    test "uses xcrun -sdk iphoneos clang++ with -stdlib=libc++, archives, verifies Mach-O symbol" do
      stub_all_dir_checks_true()
      Mox.expect(MobDev.Release.ShellMock, :mkdir_p, 2, fn _ -> :ok end)

      # 2 compile calls (one per source).
      Mox.expect(MobDev.Release.ShellMock, :cmd, 2, fn argv, _opts ->
        # iOS cxx argv: ["xcrun", "-sdk", "iphoneos", "clang++",
        #   "-arch", "arm64", "-miphoneos-version-min=17.0", "-stdlib=libc++", ...flags, "-c", "-o", obj, src]
        assert Enum.take(argv, 8) == [
                 "xcrun",
                 "-sdk",
                 "iphoneos",
                 "clang++",
                 "-arch",
                 "arm64",
                 "-miphoneos-version-min=17.0",
                 "-stdlib=libc++"
               ]

        assert "-c" in argv
        assert "-std=c++17" in argv
        assert "-DSTATIC_ERLANG_NIF_LIBNAME=nx_eigen" in argv
        {:ok, ""}
      end)

      Mox.expect(MobDev.Release.ShellMock, :rm_f, fn _ -> :ok end)

      # ar rcs
      Mox.expect(MobDev.Release.ShellMock, :cmd, fn argv, _opts ->
        assert Enum.take(argv, 3) == ["xcrun", "-sdk", "iphoneos", "ar"] |> Enum.take(3)
        assert "rcs" in argv
        {:ok, ""}
      end)

      # ranlib
      Mox.expect(MobDev.Release.ShellMock, :cmd, fn argv, _opts ->
        assert Enum.take(argv, 3) == ["xcrun", "-sdk", "iphoneos", "ranlib"] |> Enum.take(3)
        {:ok, ""}
      end)

      # nm — return Mach-O underscored symbol
      Mox.expect(MobDev.Release.ShellMock, :cmd, fn argv, _opts ->
        assert Enum.take(argv, 3) == ["xcrun", "-sdk", "iphoneos", "nm"] |> Enum.take(3)
        {:ok, "0000000000000000 T _nx_eigen_nif_init\n"}
      end)

      assert {:ok, info} =
               NxEigenNif.build(:ios_device,
                 nx_eigen_dir: "/fake/nx_eigen",
                 fine_dir: "/fake/fine",
                 erts_include: "/fake/erts/include",
                 out_dir: "/fake/out"
               )

      assert info.target == :ios_device
      assert info.archive == "/fake/out/libnx_eigen.a"
      assert length(info.objects) == 2
    end
  end

  describe "build/2 — android_arm64 full sequence" do
    # The NDK precheck inspects the real filesystem (NdkVersion.installed?)
    # — it's not behind the Shell mock. Skip the full-sequence assertion
    # when the right NDK isn't installed locally (CI without an NDK,
    # dev machines on a different NDK version). The flag-pinning tests
    # in cxxflags/2 cover the surface this test was guarding.
    @tag :android_ndk
    test "uses NDK clang++, archives, verifies ELF symbol" do
      if MobDev.NdkVersion.installed?(MobDev.NdkVersion.effective()) do
        stub_all_dir_checks_true()
        Mox.expect(MobDev.Release.ShellMock, :mkdir_p, 2, fn _ -> :ok end)

        Mox.expect(MobDev.Release.ShellMock, :cmd, 2, fn argv, _opts ->
          assert hd(argv) =~ "aarch64-linux-android28-clang++"
          assert "-c" in argv
          assert "-DSTATIC_ERLANG_NIF_LIBNAME=nx_eigen" in argv
          assert "-mbranch-protection=standard" in argv
          {:ok, ""}
        end)

        Mox.expect(MobDev.Release.ShellMock, :rm_f, fn _ -> :ok end)

        Mox.expect(MobDev.Release.ShellMock, :cmd, fn argv, _opts ->
          assert hd(argv) =~ "llvm-ar"
          assert "rcs" in argv
          {:ok, ""}
        end)

        Mox.expect(MobDev.Release.ShellMock, :cmd, fn argv, _opts ->
          assert hd(argv) =~ "llvm-ranlib"
          {:ok, ""}
        end)

        Mox.expect(MobDev.Release.ShellMock, :cmd, fn argv, _opts ->
          assert hd(argv) =~ "llvm-nm"
          {:ok, "0000000000000000 T nx_eigen_nif_init\n"}
        end)

        assert {:ok, info} =
                 NxEigenNif.build(:android_arm64,
                   nx_eigen_dir: "/fake/nx_eigen",
                   fine_dir: "/fake/fine",
                   erts_include: "/fake/erts/include",
                   out_dir: "/fake/out"
                 )

        assert info.target == :android_arm64
        assert info.archive == "/fake/out/libnx_eigen.a"
      else
        # No NDK — bail before installing Mox expectations so
        # verify_on_exit doesn't complain.
        :skipped
      end
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────

  defp stub_all_dir_checks_true do
    # Every dir? check in the precheck path returns true so we exercise
    # the happy path through compile/archive/verify without touching
    # the real filesystem.
    Mox.stub(MobDev.Release.ShellMock, :dir?, fn _ -> true end)
    Mox.stub(MobDev.Release.ShellMock, :file?, fn _ -> true end)
  end
end
