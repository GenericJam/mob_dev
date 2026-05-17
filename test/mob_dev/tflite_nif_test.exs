defmodule MobDev.TfliteNifTest do
  use ExUnit.Case, async: true

  alias MobDev.TfliteNif
  alias MobDev.TfliteNif.Target

  describe "targets/0" do
    test "lists the four expected slices" do
      assert TfliteNif.targets() == [:android_arm64, :android_arm32, :ios_sim, :ios_device]
    end
  end

  describe "target_spec/1" do
    test "android_arm64 picks aarch64-linux-android clang and no underscore prefix" do
      spec = TfliteNif.target_spec(:android_arm64)
      assert %Target{id: :android_arm64, nm_symbol: "tflite_nif_nif_init"} = spec
    end

    test "android_arm32 carries the armv7 ABI flags" do
      spec = TfliteNif.target_spec(:android_arm32)
      assert "-march=armv7-a" in spec.extra_cflags
      assert "-mfloat-abi=softfp" in spec.extra_cflags
      assert "-mthumb" in spec.extra_cflags
      # Android hardening still applies on top of armv7.
      assert "-D_GNU_SOURCE" in spec.extra_cflags
      assert "-D__ANDROID__" in spec.extra_cflags
    end

    test "ios targets use Mach-O symbol convention (leading underscore)" do
      assert TfliteNif.target_spec(:ios_sim).nm_symbol == "_tflite_nif_nif_init"
      assert TfliteNif.target_spec(:ios_device).nm_symbol == "_tflite_nif_nif_init"
    end

    test "ios targets have empty extra_cflags" do
      # iOS doesn't get Android hardening (PAC is set up differently;
      # branch-protect uses different syntax). Keeping this asserted so
      # silent drift doesn't suddenly add Android-specific flags to iOS.
      assert TfliteNif.target_spec(:ios_sim).extra_cflags == []
      assert TfliteNif.target_spec(:ios_device).extra_cflags == []
    end
  end

  describe "base_cflags/0" do
    test "carries the static-NIF macro that produces tflite_nif_nif_init" do
      flags = TfliteNif.base_cflags()
      assert "-DSTATIC_ERLANG_NIF_LIBNAME=tflite_nif" in flags

      # Optimisation + warnings + position-independent stay required —
      # silently dropping any of these would silently produce binaries
      # that don't match what Mob's static-link contract expects.
      assert "-fPIC" in flags
      assert "-O2" in flags
      assert "-Wall" in flags
    end
  end

  describe "cflags/3" do
    test "appends -I for each include and -F for each framework dir" do
      target = TfliteNif.target_spec(:ios_device)

      flags =
        TfliteNif.cflags(target, ["/path/erts/include", "/path/aar/headers"], [
          "/path/Frameworks/X"
        ])

      assert "-I/path/erts/include" in flags
      assert "-I/path/aar/headers" in flags
      assert "-F/path/Frameworks/X" in flags
    end

    test "preserves include order (CFLAGS ordering can shadow headers)" do
      target = TfliteNif.target_spec(:android_arm64)
      flags = TfliteNif.cflags(target, ["/a", "/b", "/c"], [])
      include_flags = Enum.filter(flags, &String.starts_with?(&1, "-I"))
      assert include_flags == ["-I/a", "-I/b", "-I/c"]
    end

    test "android targets ignore framework dirs" do
      target = TfliteNif.target_spec(:android_arm64)
      flags = TfliteNif.cflags(target, ["/erts"], ["/Frameworks/X"])
      # We don't filter -F flags out — clang on android silently ignores
      # them. The test pins that fact so future readers know.
      assert "-F/Frameworks/X" in flags
    end
  end

  describe "build/2 (preconditions)" do
    test "requires nx_tflite_mob_dir" do
      result =
        TfliteNif.build(:android_arm64,
          tflite_dir: "/tmp/nope",
          erts_include: "/tmp/nope",
          out_dir: "/tmp/nope"
        )

      assert {:error, {:precondition_failed, msg}} = result
      assert msg =~ "required option missing"
      assert msg =~ "nx_tflite_mob_dir"
    end

    test "rejects unknown target id" do
      assert_raise FunctionClauseError, fn ->
        TfliteNif.build(:bogus_target, [])
      end
    end
  end
end
