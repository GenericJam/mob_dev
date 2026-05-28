defmodule MobDev.NativeBuildTest do
  # async: false — a handful of tests in this module mutate process-global
  # env vars (`MOB_CACHE_DIR`, `MOB_MLX_LOCAL_TARBALL_DIR`) inside the
  # maybe_bundle_mlx_metallib/1 describe block. Running async with
  # MobDev.OtpDownloaderTest (which reads MOB_CACHE_DIR via OtpDownloader.
  # cache_dir/1) races and surfaces the polluted path as a real assertion
  # failure. Whole module is sync; 82 tests in ~200ms — the parallelism
  # gain isn't worth the env-var-shared-state hazard.
  use ExUnit.Case, async: false

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

  describe "__project_swift_sources_arg__/1" do
    test "joins extra iOS Swift sources as absolute comma-separated paths" do
      cwd = File.cwd!()

      assert NativeBuild.__project_swift_sources_arg__(
               project_swift_sources: ["ios/Bridge.swift", "../shared/Peer.swift"]
             ) ==
               Enum.join(
                 [
                   Path.expand("ios/Bridge.swift", cwd),
                   Path.expand("../shared/Peer.swift", cwd)
                 ],
                 ","
               )
    end

    test "defaults to an empty option value" do
      assert NativeBuild.__project_swift_sources_arg__([]) == ""
      assert NativeBuild.__project_swift_sources_arg__(project_swift_sources: nil) == ""
    end

    test "rejects comma-containing source entries" do
      assert_raise Mix.Error, ~r/must not contain commas/, fn ->
        NativeBuild.__project_swift_sources_arg__(project_swift_sources: ["a.swift,b.swift"])
      end
    end
  end

  describe "__merge_android_permissions__/2" do
    @manifest_with_perms """
    <?xml version="1.0" encoding="utf-8"?>
    <manifest xmlns:android="http://schemas.android.com/apk/res/android"
        package="com.example.app">
        <uses-permission android:name="android.permission.INTERNET" />
        <uses-permission android:name="android.permission.CAMERA" />
        <uses-permission android:name="android.permission.RECORD_AUDIO" />

        <application
            android:label="App">
        </application>
    </manifest>
    """

    @manifest_without_perms """
    <?xml version="1.0" encoding="utf-8"?>
    <manifest xmlns:android="http://schemas.android.com/apk/res/android"
        package="com.example.app">
        <application
            android:label="App">
        </application>
    </manifest>
    """

    test "is a no-op when permission list is empty" do
      assert NativeBuild.__merge_android_permissions__(@manifest_with_perms, []) ==
               @manifest_with_perms
    end

    test "is a no-op when every permission is already declared" do
      perms = ["android.permission.CAMERA", "android.permission.INTERNET"]

      assert NativeBuild.__merge_android_permissions__(@manifest_with_perms, perms) ==
               @manifest_with_perms
    end

    test "adds only missing permissions, dedup against existing" do
      # Project has INTERNET + CAMERA + RECORD_AUDIO (3 lines). Plugin set
      # contributes 4 of which 1 (CAMERA) is already there → expect 3 + 3 = 6
      # uses-permission tags in the result, no duplicates.
      perms = [
        "android.permission.CAMERA",
        "android.permission.BLUETOOTH_CONNECT",
        "android.permission.BLUETOOTH_SCAN",
        "android.permission.POST_NOTIFICATIONS"
      ]

      result = NativeBuild.__merge_android_permissions__(@manifest_with_perms, perms)

      tags = Regex.scan(~r/<uses-permission android:name="([^"]+)"/, result)
      names = Enum.map(tags, fn [_, name] -> name end)

      assert length(names) == 6
      assert Enum.uniq(names) == names

      assert "android.permission.BLUETOOTH_CONNECT" in names
      assert "android.permission.BLUETOOTH_SCAN" in names
      assert "android.permission.POST_NOTIFICATIONS" in names
    end

    test "inserts after the LAST existing uses-permission line" do
      perms = ["android.permission.BLUETOOTH_CONNECT"]
      result = NativeBuild.__merge_android_permissions__(@manifest_with_perms, perms)

      # Order: INTERNET, CAMERA, RECORD_AUDIO, BLUETOOTH_CONNECT
      offsets =
        for tag <- [
              "android.permission.INTERNET",
              "android.permission.CAMERA",
              "android.permission.RECORD_AUDIO",
              "android.permission.BLUETOOTH_CONNECT"
            ],
            do: :binary.match(result, tag) |> elem(0)

      assert offsets == Enum.sort(offsets)
    end

    test "inserts before <application when manifest has no existing permissions" do
      perms = ["android.permission.CAMERA"]
      result = NativeBuild.__merge_android_permissions__(@manifest_without_perms, perms)

      assert String.contains?(
               result,
               ~s(<uses-permission android:name="android.permission.CAMERA" />)
             )

      perm_idx = :binary.match(result, "android.permission.CAMERA") |> elem(0)
      app_idx = :binary.match(result, "<application") |> elem(0)
      assert perm_idx < app_idx
    end

    test "is idempotent — running twice gives the same result" do
      perms = ["android.permission.BLUETOOTH_CONNECT", "android.permission.BLUETOOTH_SCAN"]
      once = NativeBuild.__merge_android_permissions__(@manifest_with_perms, perms)
      twice = NativeBuild.__merge_android_permissions__(once, perms)
      assert once == twice
    end
  end

  describe "__merge_gradle_deps__/2" do
    @gradle """
    plugins {
        id 'com.android.application'
    }

    android {
        namespace 'com.example.app'
    }

    dependencies {
        implementation 'androidx.appcompat:appcompat:1.6.1'
        implementation 'androidx.camera:camera-camera2:1.3.4'
    }
    """

    test "is a no-op when dep list is empty" do
      assert NativeBuild.__merge_gradle_deps__(@gradle, []) == @gradle
    end

    test "is a no-op when every dep is already present" do
      deps = ["androidx.appcompat:appcompat:1.6.1", "androidx.camera:camera-camera2:1.3.4"]
      assert NativeBuild.__merge_gradle_deps__(@gradle, deps) == @gradle
    end

    test "adds only missing deps inside the dependencies block" do
      deps = [
        "com.github.PhilJay:MPAndroidChart:v3.1.0",
        "androidx.appcompat:appcompat:1.6.1",
        "com.example:foo:1.0.0"
      ]

      result = NativeBuild.__merge_gradle_deps__(@gradle, deps)

      assert String.contains?(
               result,
               ~s(implementation "com.github.PhilJay:MPAndroidChart:v3.1.0")
             )

      assert String.contains?(result, ~s(implementation "com.example:foo:1.0.0"))

      # Existing appcompat dep stays its original form — no duplicate.
      appcompat_count =
        Regex.scan(~r/androidx\.appcompat:appcompat:1\.6\.1/, result) |> length()

      assert appcompat_count == 1
    end

    test "inserts inside the dependencies block (before its closing brace)" do
      deps = ["com.example:foo:1.0.0"]
      result = NativeBuild.__merge_gradle_deps__(@gradle, deps)

      # The new implementation line lives between `dependencies {` and the next
      # closing `}` — not floating at end-of-file.
      [{deps_open, _}] = Regex.run(~r/dependencies\s*\{/, result, return: :index)
      foo_idx = :binary.match(result, "com.example:foo:1.0.0") |> elem(0)
      # Find the closing brace of the dependencies block (first `}` after deps_open).
      close_idx =
        (binary_part(result, deps_open, byte_size(result) - deps_open)
         |> :binary.match("}")
         |> elem(0)) + deps_open

      assert deps_open < foo_idx
      assert foo_idx < close_idx
    end

    test "is idempotent — running twice gives the same result" do
      deps = ["com.github.PhilJay:MPAndroidChart:v3.1.0"]
      once = NativeBuild.__merge_gradle_deps__(@gradle, deps)
      twice = NativeBuild.__merge_gradle_deps__(once, deps)
      assert once == twice
    end

    test "falls back to appending a fresh dependencies block when none exists" do
      content = """
      plugins {
          id 'com.android.application'
      }
      """

      result =
        NativeBuild.__merge_gradle_deps__(content, ["com.example:foo:1.0.0"])

      assert String.contains?(result, "dependencies {")
      assert String.contains?(result, ~s(implementation "com.example:foo:1.0.0"))
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

  describe "fallback_entitlements_plist/3" do
    test "contains application-identifier and team-identifier" do
      xml = NativeBuild.fallback_entitlements_plist("TEAM1", "com.example.app")
      assert xml =~ "<string>TEAM1.com.example.app</string>"
      assert xml =~ "<string>TEAM1</string>"
    end

    test "contains get-task-allow" do
      xml = NativeBuild.fallback_entitlements_plist("T", "com.x.y")
      assert xml =~ "<key>get-task-allow</key>"
      assert xml =~ "<true/>"
    end

    test "omits aps-environment when not given" do
      xml = NativeBuild.fallback_entitlements_plist("T", "com.x.y")
      refute xml =~ "aps-environment"
    end

    test "omits aps-environment when nil is explicit" do
      xml = NativeBuild.fallback_entitlements_plist("T", "com.x.y", nil)
      refute xml =~ "aps-environment"
    end

    test "includes aps-environment development when given" do
      xml =
        NativeBuild.fallback_entitlements_plist("Q89CW299G8", "com.mob.pushlab", "development")

      assert xml =~ "<key>aps-environment</key>"
      assert xml =~ "<string>development</string>"
    end

    test "includes aps-environment production when given" do
      xml = NativeBuild.fallback_entitlements_plist("Q89CW299G8", "com.mob.pushlab", "production")
      assert xml =~ "<key>aps-environment</key>"
      assert xml =~ "<string>production</string>"
    end

    test "output is well-formed XML with a plist root" do
      xml = NativeBuild.fallback_entitlements_plist("T", "com.x.y", "development")
      assert xml =~ ~s(<?xml version="1.0" encoding="UTF-8"?>)
      assert xml =~ "<plist version="
      assert xml =~ "</plist>"
      assert xml =~ "<dict>"
      assert xml =~ "</dict>"
    end

    test "application-identifier key precedes aps-environment key" do
      xml = NativeBuild.fallback_entitlements_plist("T", "com.x.y", "development")
      app_id_pos = :binary.match(xml, "application-identifier") |> elem(0)
      aps_pos = :binary.match(xml, "aps-environment") |> elem(0)
      assert app_id_pos < aps_pos
    end
  end

  # Stub iOS lister: returns no devices so tests exercise the
  # format-only fallback without hitting `MobDev.Discovery.IOS.list_devices/0`.
  defp no_devices, do: fn -> [] end

  # ── Pythonx integration ────────────────────────────────────────────────────

  describe "pythonx_in_project?/1" do
    @tag :tmp_dir
    test "false when no _build/dev/lib/pythonx", %{tmp_dir: tmp} do
      refute NativeBuild.pythonx_in_project?(tmp)
    end

    @tag :tmp_dir
    test "true when _build/dev/lib/pythonx exists", %{tmp_dir: tmp} do
      File.mkdir_p!(Path.join([tmp, "_build", "dev", "lib", "pythonx", "ebin"]))
      assert NativeBuild.pythonx_in_project?(tmp)
    end
  end

  describe "python_apple_support_env/2" do
    test "returns empty list when pythonx not in project" do
      assert NativeBuild.python_apple_support_env(false, "/some/path") == []
    end

    test "returns PYTHON_APPLE_SUPPORT env var when pythonx is in project" do
      assert NativeBuild.python_apple_support_env(true, "/path/to/extracted") == [
               {"PYTHON_APPLE_SUPPORT", "/path/to/extracted"}
             ]
    end
  end

  # build_device.sh script generation removed in Phase 2 iter 13c — iOS
  # device build glue (mix compile, BEAM copies, NIF cross-compile, Pythonx
  # framework, EPMD patch, enif_keepalive, build_device.zig invocation) all
  # flow through MobDev.NativeBuild helpers now. The Pythonx detection
  # (`pythonx_in_project?/1` + `python_apple_support_env/2`) is still public
  # and tested in the surrounding describe block.

  describe "install_exqlite_decision/2" do
    setup do
      tmp =
        Path.join(System.tmp_dir!(), "mob_exqlite_decision_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)
      {:ok, tmp: tmp}
    end

    test "no version → :noop (project doesn't depend on exqlite)", %{tmp: tmp} do
      assert NativeBuild.install_exqlite_decision(nil, tmp) == :noop
    end

    test "version locked + .app present → {:install, vsn}", %{tmp: tmp} do
      File.write!(Path.join(tmp, "exqlite.app"), "{application, exqlite, []}.")

      assert NativeBuild.install_exqlite_decision("0.36.0", tmp) == {:install, "0.36.0"}
    end

    test "version locked but .app missing → :stale (stale mix.lock guard)", %{tmp: tmp} do
      # Regression for pigeon's iOS-device deploy: mix.lock had exqlite
      # left over from a long-removed ecto_sqlite3 dep, but
      # _build/dev/lib/exqlite/ebin was never populated. The old code
      # crashed in File.cp!; the new code returns :stale and the
      # caller skips cleanly.
      refute File.exists?(Path.join(tmp, "exqlite.app"))

      assert NativeBuild.install_exqlite_decision("0.36.0", tmp) == :stale
    end
  end

  describe "wheel_has_native_extension?/1" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "mob_wheel_native_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)
      {:ok, tmp: tmp}
    end

    test "returns false for a pure-Python wheel directory", %{tmp: tmp} do
      wheel = Path.join(tmp, "purepy")
      File.mkdir_p!(Path.join(wheel, "pkg"))
      File.write!(Path.join([wheel, "pkg", "__init__.py"]), "")
      File.write!(Path.join([wheel, "pkg", "thing.py"]), "x = 1\n")

      refute NativeBuild.wheel_has_native_extension?(wheel)
    end

    test "returns true for a wheel containing a top-level .so", %{tmp: tmp} do
      wheel = Path.join(tmp, "cffi")
      File.mkdir_p!(wheel)
      File.write!(Path.join(wheel, "_cffi_backend.so"), <<0>>)

      assert NativeBuild.wheel_has_native_extension?(wheel)
    end

    test "returns true for a .so nested several directories deep", %{tmp: tmp} do
      wheel = Path.join(tmp, "cryptography")
      File.mkdir_p!(Path.join([wheel, "cryptography", "hazmat", "bindings"]))
      File.write!(Path.join([wheel, "cryptography", "hazmat", "bindings", "_rust.so"]), <<0>>)

      assert NativeBuild.wheel_has_native_extension?(wheel)
    end

    test "returns false for an empty wheel directory", %{tmp: tmp} do
      wheel = Path.join(tmp, "empty")
      File.mkdir_p!(wheel)

      refute NativeBuild.wheel_has_native_extension?(wheel)
    end
  end

  describe "copy_ios_safe_project_python_wheels/2" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "mob_wheel_copy_#{System.unique_integer([:positive])}")
      wheels_dir = Path.join(tmp, "wheels")
      python_root = Path.join(tmp, "python")
      File.mkdir_p!(wheels_dir)
      on_exit(fn -> File.rm_rf!(tmp) end)
      {:ok, tmp: tmp, wheels_dir: wheels_dir, python_root: python_root}
    end

    test "copies pure-Python wheels into site-packages", %{
      wheels_dir: wheels_dir,
      python_root: python_root
    } do
      seed_pure_wheel(wheels_dir, "rns")
      seed_pure_wheel(wheels_dir, "lxmf")

      assert :ok = NativeBuild.copy_ios_safe_project_python_wheels(python_root, wheels_dir)

      site_packages = Path.join([python_root, "lib", "python3.13", "site-packages"])
      assert File.dir?(Path.join(site_packages, "rns"))
      assert File.dir?(Path.join(site_packages, "lxmf"))
      assert File.read!(Path.join([site_packages, "rns", "marker.txt"])) == "from rns\n"
    end

    test "skips wheels containing native .so extensions", %{
      wheels_dir: wheels_dir,
      python_root: python_root
    } do
      seed_pure_wheel(wheels_dir, "rns")
      seed_native_wheel(wheels_dir, "cffi")
      seed_native_wheel(wheels_dir, "cryptography")

      ExUnit.CaptureIO.capture_io(fn ->
        NativeBuild.copy_ios_safe_project_python_wheels(python_root, wheels_dir)
      end)

      site_packages = Path.join([python_root, "lib", "python3.13", "site-packages"])
      assert File.dir?(Path.join(site_packages, "rns"))
      refute File.dir?(Path.join(site_packages, "cffi"))
      refute File.dir?(Path.join(site_packages, "cryptography"))
    end

    test "logs skip and copy decisions", %{
      wheels_dir: wheels_dir,
      python_root: python_root
    } do
      seed_pure_wheel(wheels_dir, "lxmf")
      seed_native_wheel(wheels_dir, "cryptography")

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          NativeBuild.copy_ios_safe_project_python_wheels(python_root, wheels_dir)
        end)

      assert output =~ "[ios-wheels] copied lxmf"
      assert output =~ "[ios-wheels] skipped wheel with native extensions"
      assert output =~ "cryptography"
    end

    test "ignores non-directory entries (stray files) in the wheels dir", %{
      wheels_dir: wheels_dir,
      python_root: python_root
    } do
      seed_pure_wheel(wheels_dir, "rns")
      File.write!(Path.join(wheels_dir, "README.md"), "not a wheel\n")

      assert :ok = NativeBuild.copy_ios_safe_project_python_wheels(python_root, wheels_dir)

      site_packages = Path.join([python_root, "lib", "python3.13", "site-packages"])
      assert File.dir?(Path.join(site_packages, "rns"))
      refute File.exists?(Path.join(site_packages, "README.md"))
    end

    test "is a no-op when wheels_dir does not exist", %{python_root: python_root, tmp: tmp} do
      missing = Path.join(tmp, "no_such_dir")

      assert :ok = NativeBuild.copy_ios_safe_project_python_wheels(python_root, missing)

      refute File.exists?(Path.join([python_root, "lib"]))
    end

    test "creates site-packages even when wheels_dir is empty", %{
      wheels_dir: wheels_dir,
      python_root: python_root
    } do
      assert :ok = NativeBuild.copy_ios_safe_project_python_wheels(python_root, wheels_dir)

      site_packages = Path.join([python_root, "lib", "python3.13", "site-packages"])
      assert File.dir?(site_packages)
    end
  end

  defp seed_pure_wheel(wheels_dir, name) do
    pkg = Path.join([wheels_dir, name, name])
    File.mkdir_p!(pkg)
    File.write!(Path.join(pkg, "__init__.py"), "")
    File.write!(Path.join(pkg, "marker.txt"), "from #{name}\n")
  end

  defp seed_native_wheel(wheels_dir, name) do
    pkg = Path.join([wheels_dir, name, name])
    File.mkdir_p!(pkg)
    File.write!(Path.join(pkg, "__init__.py"), "")
    File.write!(Path.join(pkg, "_ext.so"), <<0xCA, 0xFE, 0xBA, 0xBE>>)
  end

  # ── resolve_booted_udid/2 ───────────────────────────────────────────────
  #
  # Regression: `mix mob.deploy --native --device defd4bdc` failed at
  # `xcrun simctl install defd4bdc <app>` with `Invalid device:
  # defd4bdc` because the prefix was passed straight through to simctl,
  # which only accepts full UDIDs. The lookup now resolves any
  # case-insensitive prefix against the booted-sim list.

  describe "resolve_booted_udid/2" do
    # Shape matches `xcrun simctl list devices booted -j` output's
    # top-level "devices" map (string keys = runtime IDs, value =
    # list of sim dicts).
    defp by_runtime do
      %{
        "com.apple.CoreSimulator.SimRuntime.iOS-26-4" => [
          %{
            "udid" => "8A4250E9-B675-49CA-B143-A6C6D89B22AB",
            "name" => "iPhone 17 Pro",
            "state" => "Booted",
            "isAvailable" => true
          },
          %{
            "udid" => "DEFD4BDC-CA42-4CD2-93A1-62BE425E7A78",
            "name" => "iPhone 11 Pro Max",
            "state" => "Booted",
            "isAvailable" => true
          }
        ]
      }
    end

    test "nil device_id → first booted sim" do
      assert NativeBuild.resolve_booted_udid(by_runtime(), nil) ==
               "8A4250E9-B675-49CA-B143-A6C6D89B22AB"
    end

    test "8-char lowercase prefix matches the full UDID (user's repro)" do
      assert NativeBuild.resolve_booted_udid(by_runtime(), "defd4bdc") ==
               "DEFD4BDC-CA42-4CD2-93A1-62BE425E7A78"
    end

    test "8-char uppercase prefix also matches (case-insensitive)" do
      assert NativeBuild.resolve_booted_udid(by_runtime(), "DEFD4BDC") ==
               "DEFD4BDC-CA42-4CD2-93A1-62BE425E7A78"
    end

    test "full UDID passes through unchanged" do
      full = "DEFD4BDC-CA42-4CD2-93A1-62BE425E7A78"
      assert NativeBuild.resolve_booted_udid(by_runtime(), full) == full
    end

    test "no match → nil" do
      assert NativeBuild.resolve_booted_udid(by_runtime(), "12345678") == nil
    end

    test "empty booted list + nil device_id → nil" do
      assert NativeBuild.resolve_booted_udid(%{}, nil) == nil
    end

    test "empty booted list + given device_id → nil" do
      assert NativeBuild.resolve_booted_udid(%{}, "defd4bdc") == nil
    end

    test "shutdown sims are filtered out even if their UDID prefix matches" do
      # Defensive: simctl's `booted` filter already excludes shutdown
      # sims, but pin our own filter in case the caller passes a
      # broader listing.
      runtime = %{
        "iOS" => [
          %{
            "udid" => "DEFD4BDC-CA42-4CD2-93A1-62BE425E7A78",
            "name" => "iPhone 11 Pro Max",
            "state" => "Shutdown"
          }
        ]
      }

      assert NativeBuild.resolve_booted_udid(runtime, "defd4bdc") == nil
    end
  end

  describe "generate_erl_errno_compat_stub/1" do
    # This shim is load-bearing for iOS device builds — the link will
    # fail with `Undefined symbols: _erl_errno_id_unknown` without it.
    # See the function's docstring for the full diagnosis. The tests
    # below exist specifically so an agent (or human) who concludes
    # "this shim looks obsolete" hits a red test rather than a
    # broken iOS device build.

    setup do
      build_dir =
        Path.join(System.tmp_dir!(), "errno_compat_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(build_dir)
      on_exit(fn -> File.rm_rf!(build_dir) end)
      {:ok, build_dir: build_dir}
    end

    test "writes erl_errno_id_compat.c into the build dir", %{build_dir: build_dir} do
      assert :ok = NativeBuild.generate_erl_errno_compat_stub(build_dir)
      assert File.exists?(Path.join(build_dir, "erl_errno_id_compat.c"))
    end

    test "the shim defines erl_errno_id_unknown weakly", %{build_dir: build_dir} do
      :ok = NativeBuild.generate_erl_errno_compat_stub(build_dir)
      contents = File.read!(Path.join(build_dir, "erl_errno_id_compat.c"))

      # `weak` is what lets a future OTP tarball that ships the real
      # symbol take precedence without a duplicate-symbol error. If
      # this assertion is failing because someone changed it to a
      # strong definition, that breaks the forward-compatibility path.
      assert contents =~ "__attribute__((weak))"
      assert contents =~ "erl_errno_id_unknown"
    end

    test "the shim returns a non-empty string so callers see a valid C-string", %{
      build_dir: build_dir
    } do
      :ok = NativeBuild.generate_erl_errno_compat_stub(build_dir)
      contents = File.read!(Path.join(build_dir, "erl_errno_id_compat.c"))

      # The return value flows through BEAM error reporting (errno
      # → atom). Returning NULL would crash the formatter.
      assert contents =~ ~s|return "unknown"|
    end
  end

  describe "classify_project_nif/2" do
    # Pins the source-classification logic that decides whether a
    # project-side NIF gets the C wiring path, the Rust cross-compile +
    # link path, or no native wiring at all (Elixir-only stub). Issue #18.
    #
    # The 2-arg form takes the project root explicitly so tests don't
    # have to File.cd! (which mutates global OS-process state and races
    # with other async tests).

    setup do
      tmp = Path.join(System.tmp_dir!(), "classify_nif_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)
      {:ok, tmp: tmp}
    end

    test "finds C source at c_src/<name>.c", %{tmp: tmp} do
      c_path = Path.join(tmp, "c_src/foo.c")
      File.mkdir_p!(Path.dirname(c_path))
      File.write!(c_path, "")

      assert {:c, ^c_path} = NativeBuild.classify_project_nif(%{module: :foo}, tmp)
    end

    test "finds Rust manifest at native/<name>/Cargo.toml", %{tmp: tmp} do
      cargo_path = Path.join(tmp, "native/foo/Cargo.toml")
      File.mkdir_p!(Path.dirname(cargo_path))
      File.write!(cargo_path, "")

      assert {:rust, ^cargo_path} = NativeBuild.classify_project_nif(%{module: :foo}, tmp)
    end

    test "C wins if both exist (user has explicitly written C)", %{tmp: tmp} do
      File.mkdir_p!(Path.join(tmp, "c_src"))
      File.mkdir_p!(Path.join(tmp, "native/foo"))
      File.write!(Path.join(tmp, "c_src/foo.c"), "")
      File.write!(Path.join(tmp, "native/foo/Cargo.toml"), "")

      assert {:c, _} = NativeBuild.classify_project_nif(%{module: :foo}, tmp)
    end

    test "elixir_only when neither C nor Rust source exists", %{tmp: tmp} do
      # Stub-only NIF (the `--type elixir-only` from mob.add_nif).
      # No native wiring — the Elixir module just raises nif_error.
      assert :elixir_only = NativeBuild.classify_project_nif(%{module: :no_native}, tmp)
    end
  end

  # ── NxEigen integration helpers ──────────────────────────────────────────
  # Pure functions — no toolchain or filesystem touched.

  describe "nxeigen_zig_args_ios/1" do
    test "nil → no flags (NxEigen not in this build)" do
      assert NativeBuild.nxeigen_zig_args_ios(nil) == []
    end

    test "archive path → -Dnxeigen_static=true + -Dnxeigen_dir=<dirname>" do
      args = NativeBuild.nxeigen_zig_args_ios("/some/build/ios_sim/libnx_eigen.a")
      assert args == ["-Dnxeigen_static=true", "-Dnxeigen_dir=/some/build/ios_sim"]
    end

    test "uses dirname (not full path) so the template's `{nxeigen_dir}/libnx_eigen.a` resolves" do
      args = NativeBuild.nxeigen_zig_args_ios("/x/libnx_eigen.a")
      assert "-Dnxeigen_dir=/x" in args
      refute Enum.any?(args, &String.contains?(&1, "libnx_eigen.a"))
    end
  end

  describe "nxeigen_zig_args_android/1" do
    test "nil → no flags" do
      assert NativeBuild.nxeigen_zig_args_android(nil) == []
    end

    test "archive path → -Dnxeigen_static=true + -Dnxeigen_lib=<full path>" do
      # Android passes the full per-ABI archive path (not dirname) so a
      # single zig invocation can target one ABI's lib precisely. Two
      # ABI builds → two different `nxeigen_lib` values.
      args = NativeBuild.nxeigen_zig_args_android("/build/android_arm64/libnx_eigen.a")
      assert args == ["-Dnxeigen_static=true", "-Dnxeigen_lib=/build/android_arm64/libnx_eigen.a"]
    end

    test "iOS uses dir, Android uses lib — they differ for the same archive" do
      # Regression guard: the two flag shapes are intentionally
      # asymmetric. iOS templates expect a directory because the link
      # uses `{nxeigen_dir}/libnx_eigen.a`; Android templates expect
      # the per-ABI lib path directly.
      ios = NativeBuild.nxeigen_zig_args_ios("/x/libnx_eigen.a")
      android = NativeBuild.nxeigen_zig_args_android("/x/libnx_eigen.a")
      refute ios == android
    end
  end

  # ── install_nx_eigen_otp_lib — filesystem integration ────────────────────

  describe "install_nx_eigen_otp_lib/1 (and stage_empty_priv_otp_lib/2)" do
    setup do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "mobdev_install_nxeigen_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)
      {:ok, tmp: tmp}
    end

    test "no-op when neither dep ebin exists in _build/dev/lib/", %{tmp: otp_root} do
      # No _build dir at all — should silently no-op (the function isn't
      # required to fail when a project just doesn't have the deps).
      assert :ok = NativeBuild.install_nx_eigen_otp_lib(otp_root)
      refute File.dir?(Path.join([otp_root, "lib"]))
    end

    test "stages a single dep into <otp_root>/lib/<app>-<vsn>/{ebin,priv}", %{tmp: otp_root} do
      project = setup_project_with_dep("nx_eigen", "1.2.3")

      NativeBuild.stage_empty_priv_otp_lib(otp_root, "nx_eigen", project)

      lib_dir = Path.join([otp_root, "lib", "nx_eigen-1.2.3"])
      assert File.dir?(lib_dir)
      assert File.dir?(Path.join(lib_dir, "ebin"))
      # priv MUST exist (so :code.priv_dir/1 returns a path), and MUST
      # be empty (the .a is statically linked into the main binary).
      assert File.dir?(Path.join(lib_dir, "priv"))
      assert File.ls!(Path.join(lib_dir, "priv")) == []

      # .beam files copied through.
      assert File.exists?(Path.join([lib_dir, "ebin", "Elixir.NxEigen.NIF.beam"]))
      # .app file copied through too.
      assert File.exists?(Path.join([lib_dir, "ebin", "nx_eigen.app"]))
    end

    test "is idempotent — re-staging the same app overwrites without duplicating", %{
      tmp: otp_root
    } do
      project = setup_project_with_dep("nx_eigen", "1.2.3")

      NativeBuild.stage_empty_priv_otp_lib(otp_root, "nx_eigen", project)
      NativeBuild.stage_empty_priv_otp_lib(otp_root, "nx_eigen", project)

      # Still exactly one lib dir; ebin still has the same contents.
      lib_dirs = File.ls!(Path.join(otp_root, "lib"))
      assert lib_dirs == ["nx_eigen-1.2.3"]
    end

    test "install_nx_eigen_otp_lib stages BOTH nx_eigen + fine", %{tmp: otp_root} do
      # Both deps need staging because Fine is the C++ binding helper;
      # any code that consults `:code.priv_dir(:fine)` would crash on
      # the same `:bad_name` pattern without it.
      project = setup_project_with_dep("nx_eigen", "1.2.3")
      _ = setup_dep_in_project(project, "fine", "0.5.0")

      NativeBuild.install_nx_eigen_otp_lib(otp_root, project)

      lib_dirs = Enum.sort(File.ls!(Path.join(otp_root, "lib")))
      assert lib_dirs == ["fine-0.5.0", "nx_eigen-1.2.3"]
    end

    # Helper: build a fake project containing _build/dev/lib/<app>/ebin/
    # with one .beam + a .app file the staging code expects.
    defp setup_project_with_dep(app, vsn) do
      tmp = Path.join(System.tmp_dir!(), "mobdev_proj_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)
      setup_dep_in_project(tmp, app, vsn)
      tmp
    end

    defp setup_dep_in_project(project, app, vsn) do
      ebin = Path.join([project, "_build", "dev", "lib", app, "ebin"])
      File.mkdir_p!(ebin)

      File.write!(
        Path.join(ebin, "Elixir.#{Macro.camelize(app)}.NIF.beam"),
        "FAKE_BEAM_BYTES"
      )

      File.write!(
        Path.join(ebin, "#{app}.app"),
        ~s({application,#{app},[{vsn,"#{vsn}"},{description,"test"}]}.)
      )

      project
    end
  end

  # ── maybe_bundle_mlx_metallib/1 ──────────────────────────────────────────
  # Copies mlx.metallib (the precompiled Metal GPU kernels) out of mob's
  # MLX cache into the .app bundle so MLX's load_colocated_library can
  # find it next to the running binary. No-op when the cached bundle is
  # CPU-only (no metallib in the staged tarball).

  describe "maybe_bundle_mlx_metallib/1" do
    setup do
      tmp =
        Path.join(System.tmp_dir!(), "mob_metallib_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)

      original_cache = System.get_env("MOB_CACHE_DIR")
      original_local = System.get_env("MOB_MLX_LOCAL_TARBALL_DIR")

      on_exit(fn ->
        File.rm_rf!(tmp)
        restore_env("MOB_CACHE_DIR", original_cache)
        restore_env("MOB_MLX_LOCAL_TARBALL_DIR", original_local)
      end)

      {:ok, tmp: tmp}
    end

    test "copies mlx.metallib into the .app when the cached bundle ships one", %{tmp: tmp} do
      app_path = Path.join(tmp, "Test.app")
      File.mkdir_p!(app_path)

      stage_mlx_cache(tmp, with_metallib: true)

      assert :ok = NativeBuild.maybe_bundle_mlx_metallib(app_path)
      copied = Path.join(app_path, "mlx.metallib")
      assert File.regular?(copied)
      assert File.read!(copied) == "stub-metallib-bytes"
    end

    test "no-op when the cached bundle is CPU-only (no metallib)", %{tmp: tmp} do
      app_path = Path.join(tmp, "Test.app")
      File.mkdir_p!(app_path)

      stage_mlx_cache(tmp, with_metallib: false)

      assert :ok = NativeBuild.maybe_bundle_mlx_metallib(app_path)
      refute File.exists?(Path.join(app_path, "mlx.metallib"))
    end
  end

  # Stage a fake MLX cache + local tarball under tmp/. Uses the same
  # MOB_MLX_LOCAL_TARBALL_DIR override the MLXDownloader tests use so
  # ensure_ios_device/0 doesn't touch the network.
  defp stage_mlx_cache(tmp, opts) do
    bundle_name = MobDev.MLXDownloader.name(:ios_device)
    tarball_name = MobDev.MLXDownloader.tarball_name(:ios_device)

    # Build the staging dir (what the tarball will contain).
    stage_root = Path.join(tmp, "stage")
    bundle_dir = Path.join(stage_root, bundle_name)
    File.mkdir_p!(Path.join(bundle_dir, "lib"))
    File.mkdir_p!(Path.join([bundle_dir, "include", "mlx"]))
    File.write!(Path.join([bundle_dir, "lib", "libmlx.a"]), "stub-mlx")
    File.write!(Path.join([bundle_dir, "lib", "libemlx.a"]), "stub-emlx")
    File.write!(Path.join(bundle_dir, "VERSION"), "mlx_version=stub\nvariant=test\n")

    if opts[:with_metallib] do
      File.write!(Path.join([bundle_dir, "lib", "mlx.metallib"]), "stub-metallib-bytes")
    end

    # Pack into a tarball at the location the local-tarball override
    # expects.
    local_dir = Path.join(tmp, "local")
    File.mkdir_p!(local_dir)
    tar_out = Path.join(local_dir, tarball_name)

    {_, 0} = System.cmd("tar", ["-czf", tar_out, "-C", stage_root, bundle_name])
    File.rm_rf!(stage_root)

    # Point the downloader at a fresh tmp cache + the staged tarball.
    cache_dir = Path.join(tmp, "cache")
    System.put_env("MOB_CACHE_DIR", cache_dir)
    System.put_env("MOB_MLX_LOCAL_TARBALL_DIR", local_dir)
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  # ── Pin script + patch presence ──────────────────────────────────────────
  # The Metal build process depends on two files living at known paths.
  # If a refactor removes or renames either, fail loudly here instead of
  # silently producing a CPU-only bundle.

  describe "MLX Metal build artifacts present" do
    test "ios_device_metal.sh exists and is executable" do
      script =
        Path.join([
          File.cwd!(),
          "scripts/release/mlx/ios_device_metal.sh"
        ])

      assert File.regular?(script), "expected #{script} to exist"

      assert File.stat!(script).mode |> Bitwise.band(0o111) > 0,
             "expected #{script} to be executable"
    end

    # ExSlop flags this as "doesn't exercise application code" — strictly true
    # (it only touches File.regular?/1 + String.contains?/2) but the assertion
    # is on a build asset the deploy pipeline consumes. Losing the patch
    # silently would break iOS Metal builds in a way a regular test couldn't
    # catch, since the consumer is `mix mob.deploy --native --ios`, not BEAM.
    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "iOS-Metal CMake patch file exists" do
      patch =
        Path.join([
          File.cwd!(),
          "scripts/release/mlx/patches/0001-ios-metal-build.patch"
        ])

      assert File.regular?(patch), "expected #{patch} to exist"

      content = File.read!(patch)
      assert String.contains?(content, "iOS"), "patch should mention iOS"
      assert String.contains?(content, "iphoneos"), "patch should switch to iphoneos SDK"
    end
  end
end
