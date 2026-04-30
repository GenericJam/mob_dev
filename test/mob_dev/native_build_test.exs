defmodule MobDev.NativeBuildTest do
  use ExUnit.Case, async: true

  alias MobDev.NativeBuild

  describe "otp_dir_for_abi/3" do
    test "armeabi-v7a returns the arm32 path" do
      assert NativeBuild.otp_dir_for_abi("armeabi-v7a", "/otp/arm64", "/otp/arm32") ==
               "/otp/arm32"
    end

    test "arm64-v8a returns the arm64 path" do
      assert NativeBuild.otp_dir_for_abi("arm64-v8a", "/otp/arm64", "/otp/arm32") ==
               "/otp/arm64"
    end

    test "unknown ABI falls back to arm64" do
      assert NativeBuild.otp_dir_for_abi("x86_64", "/otp/arm64", "/otp/arm32") ==
               "/otp/arm64"
    end

    test "empty ABI string falls back to arm64" do
      assert NativeBuild.otp_dir_for_abi("", "/otp/arm64", "/otp/arm32") == "/otp/arm64"
    end
  end

  describe "filter_serials/2" do
    @serials [
      "ZY22K6BSJM",
      "10.0.0.17:5555",
      "10.0.0.82:5555",
      "emulator-5554",
      "emulator-5556"
    ]

    test "nil returns all serials unchanged" do
      assert NativeBuild.filter_serials(@serials, nil) == @serials
    end

    test "exact serial match" do
      assert NativeBuild.filter_serials(@serials, "ZY22K6BSJM") == ["ZY22K6BSJM"]
    end

    test "matches wifi-adb serial when given bare IP" do
      assert NativeBuild.filter_serials(@serials, "10.0.0.17") == ["10.0.0.17:5555"]
    end

    test "matches wifi-adb serial when given full IP:port" do
      assert NativeBuild.filter_serials(@serials, "10.0.0.17:5555") == ["10.0.0.17:5555"]
    end

    test "matches emulator serial" do
      assert NativeBuild.filter_serials(@serials, "emulator-5554") == ["emulator-5554"]
    end

    test "non-matching id returns empty list" do
      assert NativeBuild.filter_serials(@serials, "NOPE") == []
    end
  end

  describe "read_sdk_dir/1" do
    setup do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "mob_native_build_test_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(Path.join(tmp, "android"))
      on_exit(fn -> File.rm_rf!(tmp) end)
      {:ok, project: tmp}
    end

    test "returns {:ok, dir} when sdk.dir is set", %{project: project} do
      File.write!(
        Path.join([project, "android", "local.properties"]),
        "sdk.dir=/opt/Android/sdk\n"
      )

      assert {:ok, "/opt/Android/sdk"} = NativeBuild.read_sdk_dir(project)
    end

    test "trims trailing whitespace and resolves ~", %{project: project} do
      home = System.user_home!()

      File.write!(
        Path.join([project, "android", "local.properties"]),
        "sdk.dir=~/Library/Android/sdk   \n"
      )

      assert {:ok, dir} = NativeBuild.read_sdk_dir(project)
      assert dir == Path.expand("~/Library/Android/sdk")
      assert String.starts_with?(dir, home)
    end

    test "returns :error when local.properties is missing", %{project: project} do
      assert :error = NativeBuild.read_sdk_dir(project)
    end

    test "returns :error when local.properties has no sdk.dir line", %{project: project} do
      File.write!(
        Path.join([project, "android", "local.properties"]),
        "# placeholder\nsome.other=value\n"
      )

      assert :error = NativeBuild.read_sdk_dir(project)
    end
  end

  describe "android_toolchain_available?/1" do
    setup do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "mob_native_build_test_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(Path.join(tmp, "android"))

      sdk_dir = Path.join(tmp, "fake_sdk")
      File.mkdir_p!(sdk_dir)

      on_exit(fn -> File.rm_rf!(tmp) end)
      {:ok, project: tmp, sdk_dir: sdk_dir}
    end

    test "false when local.properties is missing", %{project: project} do
      refute NativeBuild.android_toolchain_available?(project)
    end

    test "false when sdk.dir points at a missing directory", %{project: project} do
      File.write!(
        Path.join([project, "android", "local.properties"]),
        "sdk.dir=/nonexistent/path/to/sdk\n"
      )

      refute NativeBuild.android_toolchain_available?(project)
    end

    test "true requires adb on PATH plus an existing sdk.dir", %{
      project: project,
      sdk_dir: sdk_dir
    } do
      File.write!(
        Path.join([project, "android", "local.properties"]),
        "sdk.dir=#{sdk_dir}\n"
      )

      expected = System.find_executable("adb") != nil
      assert NativeBuild.android_toolchain_available?(project) == expected
    end
  end

  describe "ios_toolchain_available?/0" do
    test "matches the actual macOS + xcrun status of the host" do
      macos? = match?({:unix, :darwin}, :os.type())
      xcrun? = System.find_executable("xcrun") != nil
      assert NativeBuild.ios_toolchain_available?() == (macos? and xcrun?)
    end
  end

  # ── narrow_platforms_for_device/2 ─────────────────────────────────────────
  #
  # Regression-critical helper. The bug timeline this guards against:
  #
  # - 0.3.16/0.3.17: `ios_physical_udid?/1` matched by UDID format only, so
  #   sim UDIDs were classified physical → device build → installer crash.
  #
  # - 0.3.18: predicate fixed (uses Discovery.IOS.list_devices/0). But the
  #   narrowing in `build_all/1` was `not ios_physical_udid? -> drop iOS`.
  #   With the fix, sim UDIDs returned false → iOS got stripped → no
  #   sim build, silent "No native build targets found" message.
  #
  # - 0.3.19: replaced narrowing with `ios_device?/1` (matches sim or
  #   physical via discovery). Extracted to public `narrow_platforms_for_device/2`
  #   in 0.3.21 so the deployer can reuse the same call site.
  #
  # We test against values that don't appear in the local discovery so the
  # behaviour is reproducible regardless of which devices happen to be
  # connected when the tests run. The format-only fallback in
  # `ios_physical_udid?/1` covers the discovery-empty case for these.

  describe "narrow_platforms_for_device/2" do
    test "returns platforms unchanged when device_id is nil" do
      assert NativeBuild.narrow_platforms_for_device([:android, :ios], nil) ==
               [:android, :ios]
    end

    test "drops Android when device id is a 40-char physical iOS UDID" do
      # Old-style iPhone UDID (pre-Apple Silicon). Format-check fallback
      # in ios_physical_udid?/1 picks this up even when not connected.
      udid = "abcdef0123456789abcdef0123456789abcdef01"

      assert NativeBuild.narrow_platforms_for_device([:android, :ios], udid) ==
               [:ios]
    end

    test "drops Android when device id is a 8-16 short physical iOS UDID" do
      # Modern Apple Silicon iPhone UDID format.
      udid = "00008110-001E1C3A34F8401E"

      assert NativeBuild.narrow_platforms_for_device([:android, :ios], udid) ==
               [:ios]
    end

    test "drops iOS when device id is an Android serial" do
      # Real Moto E serial form — letters + digits, no UUID structure.
      assert NativeBuild.narrow_platforms_for_device([:android, :ios], "ZY22CRLMWK") ==
               [:android]

      assert NativeBuild.narrow_platforms_for_device([:android, :ios], "emulator-5554") ==
               [:android]
    end

    test "drops iOS when device id is an Android adb-over-WiFi address" do
      assert NativeBuild.narrow_platforms_for_device([:android, :ios], "10.0.0.17:5555") ==
               [:android]
    end

    test "returns empty list when device id contradicts explicit platform" do
      # User passed `--android` + an iOS device id. The narrowing strips
      # Android (because the id is iOS), and there's no iOS in the list to
      # build/deploy — so the result is empty. That's the correct safety
      # behaviour: don't silently flip to iOS when the user explicitly
      # asked for Android only.
      udid = "00008110-001E1C3A34F8401E"
      assert NativeBuild.narrow_platforms_for_device([:android], udid) == []

      # Mirror case: --ios + Android serial → iOS gets stripped, empty.
      assert NativeBuild.narrow_platforms_for_device([:ios], "ZY22CRLMWK") == []
    end

    test "preserves order of remaining platforms when narrowing" do
      # The list-subtraction implementation preserves the order of the
      # remaining elements. Pin that so future refactors that reach for
      # MapSet/Enum-based dedup don't accidentally re-order the outputs.
      assert NativeBuild.narrow_platforms_for_device([:ios, :android], "ZY22CRLMWK") ==
               [:android]

      assert NativeBuild.narrow_platforms_for_device([:android, :ios], "ZY22CRLMWK") ==
               [:android]
    end
  end
end
