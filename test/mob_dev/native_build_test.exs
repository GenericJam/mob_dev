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
end
