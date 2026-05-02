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

  describe "narrow_platforms_for_device/2 and /3" do
    # Tests inject an empty discovery list so the format-only fallback
    # paths (ios_physical_udid?/1) are exercised without the LAN EPMD
    # scan in IOS.list_devices/0 — that scan can take 60s+ in busy
    # network environments and dominates the test runtime.

    test "returns platforms unchanged when device_id is nil" do
      assert NativeBuild.narrow_platforms_for_device([:android, :ios], nil, no_devices()) ==
               [:android, :ios]
    end

    test "drops Android when device id is a 40-char physical iOS UDID" do
      # Old-style iPhone UDID (pre-Apple Silicon). Format-check fallback
      # picks this up even when not in the discovery list.
      udid = "abcdef0123456789abcdef0123456789abcdef01"

      assert NativeBuild.narrow_platforms_for_device([:android, :ios], udid, no_devices()) ==
               [:ios]
    end

    test "drops Android when device id is a 8-16 short physical iOS UDID" do
      # Modern Apple Silicon iPhone UDID format.
      udid = "00008110-001E1C3A34F8401E"

      assert NativeBuild.narrow_platforms_for_device([:android, :ios], udid, no_devices()) ==
               [:ios]
    end

    test "drops iOS when device id is an Android serial" do
      # Real Moto E serial form — letters + digits, no UUID structure.
      assert NativeBuild.narrow_platforms_for_device(
               [:android, :ios],
               "ZY22CRLMWK",
               no_devices()
             ) == [:android]

      assert NativeBuild.narrow_platforms_for_device(
               [:android, :ios],
               "emulator-5554",
               no_devices()
             ) == [:android]
    end

    test "drops iOS when device id is an Android adb-over-WiFi address" do
      assert NativeBuild.narrow_platforms_for_device(
               [:android, :ios],
               "10.0.0.17:5555",
               no_devices()
             ) == [:android]
    end

    test "returns empty list when device id contradicts explicit platform" do
      # User passed `--android` + an iOS device id. The narrowing strips
      # Android (because the id is iOS), and there's no iOS in the list to
      # build/deploy — so the result is empty. That's the correct safety
      # behaviour: don't silently flip to iOS when the user explicitly
      # asked for Android only.
      udid = "00008110-001E1C3A34F8401E"
      assert NativeBuild.narrow_platforms_for_device([:android], udid, no_devices()) == []

      # Mirror case: --ios + Android serial → iOS gets stripped, empty.
      assert NativeBuild.narrow_platforms_for_device([:ios], "ZY22CRLMWK", no_devices()) == []
    end

    test "preserves order of remaining platforms when narrowing" do
      # The list-subtraction implementation preserves the order of the
      # remaining elements. Pin that so future refactors that reach for
      # MapSet/Enum-based dedup don't accidentally re-order the outputs.
      assert NativeBuild.narrow_platforms_for_device(
               [:ios, :android],
               "ZY22CRLMWK",
               no_devices()
             ) == [:android]

      assert NativeBuild.narrow_platforms_for_device(
               [:android, :ios],
               "ZY22CRLMWK",
               no_devices()
             ) == [:android]
    end

    test "discovery hit on a sim UDID drops Android (even when format is ambiguous)" do
      # Simulator UDIDs use the same 36-char UUID format as physical
      # devices, so we *must* consult discovery to disambiguate. With
      # the device present in discovery as type :simulator, the iOS
      # branch is taken via Device.match_id?/2 — not the physical-UDID
      # format fallback (which would also return true here, but for the
      # wrong reason).
      sim_udid = "12345678-ABCD-1234-ABCD-1234567890AB"

      sim = %MobDev.Device{
        platform: :ios,
        type: :simulator,
        serial: sim_udid,
        name: "iPhone 17",
        status: :discovered
      }

      assert NativeBuild.narrow_platforms_for_device(
               [:android, :ios],
               sim_udid,
               fn -> [sim] end
             ) == [:ios]
    end

    test "discovery hit by display_id (8-char prefix) still drops Android" do
      # `mix mob.devices` prints a short display id (first 8 chars of
      # the sim UDID). Users sometimes paste that to --device. Device.match_id?/2
      # accepts it, so the discovery branch fires.
      sim_udid = "12345678-ABCD-1234-ABCD-1234567890AB"

      sim = %MobDev.Device{
        platform: :ios,
        type: :simulator,
        serial: sim_udid,
        name: "iPhone 17",
        status: :discovered
      }

      assert NativeBuild.narrow_platforms_for_device(
               [:android, :ios],
               "12345678",
               fn -> [sim] end
             ) == [:ios]
    end

    test "/2 form delegates to /3 with the real iOS discovery (smoke check)" do
      # Don't exercise the network — just confirm the no-op nil branch
      # still works through the public 2-arity entry that real callers
      # use (mix mob.deploy, native_build.build_all).
      assert NativeBuild.narrow_platforms_for_device([:android, :ios], nil) ==
               [:android, :ios]
    end
  end

  # Stub iOS lister: returns no devices so tests exercise the
  # format-only fallback without hitting `MobDev.Discovery.IOS.list_devices/0`.
  defp no_devices, do: fn -> [] end
end
