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

  describe "build_outcome/1" do
    test "an empty native target set fails closed" do
      assert NativeBuild.build_outcome([]) == %{
               ok?: false,
               android_device_disposition: :not_attempted,
               android_serials: [],
               android_deploy_lock: nil,
               android_payload_plan: nil
             }
    end

    test "one successful platform remains a valid partial multi-platform outcome" do
      assert NativeBuild.build_outcome([{:ok, "iOS"}]) == %{
               ok?: true,
               android_device_disposition: :not_attempted,
               android_serials: [],
               android_deploy_lock: nil,
               android_payload_plan: nil
             }
    end

    test "any attempted native platform failure fails the aggregate outcome" do
      assert NativeBuild.build_outcome([
               {:ok, "iOS"},
               {:error, "Android", "target unavailable"}
             ]) == %{
               ok?: false,
               android_device_disposition: :failed,
               android_serials: [],
               android_deploy_lock: nil,
               android_payload_plan: nil
             }
    end

    test "an artifact-only Android success exposes no targets, lease, or payload plan" do
      assert NativeBuild.build_outcome([
               {:ok, "Android", %{serials: [], deploy_lock: nil, payload_plan: nil}}
             ]) == %{
               ok?: true,
               android_device_disposition: :artifact_only,
               android_serials: [],
               android_deploy_lock: nil,
               android_payload_plan: nil
             }
    end

    test "an aggregate failure hides the Android payload plan but retains the lease" do
      lease = %{state: :native_ready}
      plan = %{version: 1}

      assert NativeBuild.build_outcome([
               {:ok, "Android", %{serials: ["serial-a"], deploy_lock: lease, payload_plan: plan}},
               {:error, "iOS", "build failed"}
             ]) == %{
               ok?: false,
               android_device_disposition: :failed,
               android_serials: ["serial-a"],
               android_deploy_lock: lease,
               android_payload_plan: nil
             }
    end

    test "a later-platform failure and cleanup failure still return the exact Android lease" do
      lease = %{
        bundle_id: "com.example.casein",
        owner: "ownerproof000001",
        serials: ["serial-a"],
        target_digest: String.duplicate("a", 64),
        phase: :native_ready,
        state: :held_success
      }

      plan = %{attempt_id: "planbeam00000001"}

      results = [
        {:ok, "Android", %{serials: ["serial-a"], deploy_lock: lease, payload_plan: plan}},
        {:error, "iOS", "injected later-platform failure"}
      ]

      cleanup = fn ^plan ->
        send(self(), :aggregate_cleanup_attempted)
        {:error, :injected_cleanup_failure}
      end

      assert NativeBuild.build_outcome(results, android_preinstall_cleanup: cleanup) == %{
               ok?: false,
               android_device_disposition: :failed,
               android_serials: ["serial-a"],
               android_deploy_lock: lease,
               android_payload_plan: nil
             }

      assert_received :aggregate_cleanup_attempted
    end

    test "reports retained and ambiguous Android authority with a bounded disposition" do
      held = native_ready_lease(["serial-a"])
      retained = %{held | state: :retained_ambiguous}

      assert %{
               android_device_disposition: :held,
               android_deploy_lock: ^held
             } =
               NativeBuild.build_outcome([
                 {:ok, "Android",
                  %{
                    serials: ["serial-a"],
                    deploy_lock: held,
                    payload_plan: %{version: 1}
                  }}
               ])

      assert %{
               android_device_disposition: :retained,
               android_deploy_lock: ^retained
             } =
               NativeBuild.build_outcome([
                 {:error, "Android", "typed failure", retained}
               ])

      assert %{
               android_device_disposition: :retained,
               android_deploy_lock: ^held
             } =
               NativeBuild.build_outcome([
                 {:ok, "Android", %{serials: ["serial-a"], deploy_lock: held}},
                 {:error, "Android", "duplicate result"}
               ])
    end
  end

  describe "ios_phase_decision/3" do
    test "defers iOS for one exact held Android device phase" do
      serials = ["serial-a", "serial-b"]
      lock = native_ready_lease(serials)

      results = [
        {:ok, "Android", %{serials: serials, deploy_lock: lock, payload_plan: %{version: 1}}}
      ]

      assert NativeBuild.ios_phase_decision(results, [:android, :ios], true) == :defer
    end

    test "suppresses iOS after an Android device-phase error or invalid held result" do
      lock = native_ready_lease(["serial-a"])

      for results <- [
            [{:error, "Android", "update failed"}],
            [{:error, "Android", "update ambiguous", %{lock | state: :retained_ambiguous}}],
            [{:ok, "Android", %{serials: ["serial-b"], deploy_lock: lock}}],
            [
              {:ok, "Android", %{serials: ["serial-a"], deploy_lock: lock}},
              {:error, "Android", "duplicate result"}
            ]
          ] do
        assert NativeBuild.ios_phase_decision(results, [:android, :ios], true) == :suppress
      end
    end

    test "preserves iOS for artifact-only work and when Android had no device-phase result" do
      android_error = [{:error, "Android", "artifact build failed"}]

      assert NativeBuild.ios_phase_decision(android_error, [:android, :ios], false) == :run
      assert NativeBuild.ios_phase_decision([], [:android, :ios], true) == :run
      assert NativeBuild.ios_phase_decision([{:ok, "iOS"}], [:android, :ios], true) == :run
      assert NativeBuild.ios_phase_decision([], [:android], true) == :skip
    end
  end

  describe "build_zig_supports_abi?/2" do
    test "true when the build.zig declares the ABI as a quoted string literal" do
      src = ~s|
        if (std.mem.eql(u8, abi, "arm64-v8a")) return "aarch64-linux-android";
        if (std.mem.eql(u8, abi, "x86_64")) return "x86_64-linux-android";
      |

      assert NativeBuild.build_zig_supports_abi?(src, "arm64-v8a")
      assert NativeBuild.build_zig_supports_abi?(src, "x86_64")
    end

    test "false when the ABI is absent (e.g. a pre-x86_64 mob_new < 0.4.5 build.zig)" do
      src = ~s|
        if (std.mem.eql(u8, abi, "arm64-v8a")) return "aarch64-linux-android";
        if (std.mem.eql(u8, abi, "armeabi-v7a")) return "arm-linux-androideabi";
        // ERROR: unsupported -Dabi (expected arm64-v8a or armeabi-v7a)
      |

      assert NativeBuild.build_zig_supports_abi?(src, "armeabi-v7a")
      refute NativeBuild.build_zig_supports_abi?(src, "x86_64")
    end
  end

  describe "inject_page_size_flag/1" do
    test "injects the 16 KB flag into a stale build.zig's -shared link" do
      src = ~s|    const run = b.addSystemCommand(&.{ ndk_clang, target_arg, "-shared" });|
      assert {:patched, out} = NativeBuild.inject_page_size_flag(src)
      assert out =~ ~s|"-shared", "-Wl,-z,max-page-size=16384" })|
      assert out =~ "max-page-size=16384"
    end

    test "patches every -shared link (app .so + sqlite .so)" do
      src = ~s|
        const run = b.addSystemCommand(&.{ ndk_clang, target_arg, "-shared" });
        const run = b.addSystemCommand(&.{ ndk_clang, target_arg, "-shared" });
      |

      assert {:patched, out} = NativeBuild.inject_page_size_flag(src)
      assert length(String.split(out, "max-page-size=16384")) == 3
    end

    test "idempotent — already-aligned build.zig is left unchanged" do
      # mirrors how the mob_new template / a hand-fixed app (e.g. Io) carries it
      src = ~s|
        const run = b.addSystemCommand(&.{ ndk_clang, target_arg, "-shared" });
        run.addArg("-Wl,-z,max-page-size=16384");
      |

      assert {:already, ^src} = NativeBuild.inject_page_size_flag(src)
    end

    test "no_match when the -shared link line is unrecognized" do
      src = ~s|    // a build.zig that does its linking some other way|
      assert {:no_match, ^src} = NativeBuild.inject_page_size_flag(src)
    end
  end

  describe "__driver_tab_formats__/1 + regen_driver_tab!/0" do
    test "detects the formats whose generated files exist" do
      zig_paths = Mix.Tasks.Mob.RegenDriverTab.target_paths(:zig)
      c_paths = Mix.Tasks.Mob.RegenDriverTab.target_paths(:c)

      assert NativeBuild.__driver_tab_formats__(fn _ -> false end) == []
      assert NativeBuild.__driver_tab_formats__(&(&1 == zig_paths.android)) == [:zig]
      assert NativeBuild.__driver_tab_formats__(&(&1 == c_paths.ios)) == [:c]
      assert NativeBuild.__driver_tab_formats__(fn _ -> true end) == [:zig, :c]
    end

    test "rewrites a stale on-disk driver_tab (the :nif_not_loaded footgun)" do
      dir =
        Path.join(System.tmp_dir!(), "mob_driver_tab_regen_#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(dir, "priv/generated"))
      stale_path = Path.join(dir, "priv/generated/driver_tab_android.zig")
      File.write!(stale_path, "// stale — generated before a plugin was added\n")

      cwd = File.cwd!()
      File.cd!(dir)

      try do
        assert :ok = NativeBuild.regen_driver_tab!()
        regenerated = File.read!(stale_path)
        refute regenerated =~ "stale"
        # The zig sibling is regenerated alongside; the c format stays absent.
        assert File.exists?(Path.join(dir, "priv/generated/driver_tab_ios.zig"))
        refute File.exists?(Path.join(dir, "priv/generated/driver_tab_ios.c"))
      after
        File.cd!(cwd)
        File.rm_rf!(dir)
      end
    end

    test "leaves a project with no generated driver_tab untouched" do
      dir =
        Path.join(System.tmp_dir!(), "mob_driver_tab_none_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      cwd = File.cwd!()
      File.cd!(dir)

      try do
        assert :ok = NativeBuild.regen_driver_tab!()
        assert File.ls!(dir) == []
      after
        File.cd!(cwd)
        File.rm_rf!(dir)
      end
    end
  end

  describe "__merge_android_manifest_components__/2" do
    @manifest """
    <manifest xmlns:android="http://schemas.android.com/apk/res/android">
        <application android:label="X">
            <activity android:name=".MainActivity"/>
        </application>
    </manifest>
    """

    test "splices a component in just before </application>" do
      out =
        NativeBuild.__merge_android_manifest_components__(@manifest, [
          ~s(<service android:name="io.mob.nfc.MobNfcApduService" android:exported="true"/>)
        ])

      assert out =~ ~s(<service android:name="io.mob.nfc.MobNfcApduService")
      # inserted inside <application> (before its close, after the activity)
      assert out =~ ~r/MainActivity.*MobNfcApduService.*<\/application>/s
    end

    test "is idempotent on the component's android:name" do
      snippet = ~s(<service android:name="io.mob.nfc.MobNfcApduService"/>)
      once = NativeBuild.__merge_android_manifest_components__(@manifest, [snippet])
      twice = NativeBuild.__merge_android_manifest_components__(once, [snippet])
      assert once == twice
      assert length(String.split(once, "MobNfcApduService")) == 2
    end

    test "removing the plugin (empty set) strips the previously-injected region" do
      snippet = ~s(<service android:name="io.mob.nfc.MobNfcApduService"/>)
      with_svc = NativeBuild.__merge_android_manifest_components__(@manifest, [snippet])
      assert with_svc =~ "MobNfcApduService"
      # plugin removed → next build contributes no components → region gone
      cleaned = NativeBuild.__merge_android_manifest_components__(with_svc, [])
      refute cleaned =~ "MobNfcApduService"
      refute cleaned =~ "mob:plugin-components"
      assert cleaned == @manifest
    end

    test "swapping which plugin is active replaces the component (old one gone)" do
      a =
        NativeBuild.__merge_android_manifest_components__(@manifest, [
          ~s(<service android:name="io.a.Svc"/>)
        ])

      b =
        NativeBuild.__merge_android_manifest_components__(a, [
          ~s(<service android:name="io.b.Svc"/>)
        ])

      assert b =~ "io.b.Svc"
      refute b =~ "io.a.Svc"
    end

    test "no snippets → manifest unchanged" do
      assert NativeBuild.__merge_android_manifest_components__(@manifest, []) == @manifest
    end

    test "no </application> → returns manifest untouched rather than corrupting it" do
      weird = "<manifest></manifest>"
      assert NativeBuild.__merge_android_manifest_components__(weird, ["<service/>"]) == weird
    end

    test "preserves nested indentation, shifted into <application>" do
      snippet = "<service android:name=\"io.x.S\">\n  <intent-filter/>\n</service>"
      out = NativeBuild.__merge_android_manifest_components__(@manifest, [snippet])
      assert out =~ "        <service android:name=\"io.x.S\">"
      assert out =~ "          <intent-filter/>"
    end
  end

  describe "__res_target__/2 (plugin res path containment)" do
    @root "android/app/src/main"

    test "a normal res destination resolves to a copy target under res/" do
      assert {:ok, "android/app/src/main/res/xml/svc.xml"} =
               NativeBuild.__res_target__(@root, "res/xml/svc.xml")
    end

    test "a .. traversal that escapes res/ is rejected" do
      assert {:error, :escapes_res_dir} =
               NativeBuild.__res_target__(@root, "res/../../../build.gradle")
    end

    test "a deeper traversal to an arbitrary host path is rejected" do
      assert {:error, :escapes_res_dir} =
               NativeBuild.__res_target__(@root, "res/../../../../../../etc/hosts")
    end

    test "the res dir itself is allowed but a sibling of res/ is not" do
      assert {:ok, _} = NativeBuild.__res_target__(@root, "res")
      assert {:error, :escapes_res_dir} = NativeBuild.__res_target__(@root, "res/../resx/x")
    end
  end

  describe "__notify_hub_kotlin__/0" do
    test "generated hub is the stable io.mob.plugin seam with the three members" do
      src = NativeBuild.__notify_hub_kotlin__()
      assert src =~ "package io.mob.plugin"
      assert src =~ "object MobNotifyHub"
      assert src =~ ~s(const val CHANNEL_ID = "mob_notifications")
      assert src =~ "var notifyPid: Long = 0"
      assert src =~ "var pendingToken: String? = null"
    end
  end

  describe "__host_requirements_warning__/1" do
    test "no obligations → no warning" do
      assert NativeBuild.__host_requirements_warning__([]) == nil
    end

    test "renders one line per obligation, tagged with the plugin" do
      msg =
        NativeBuild.__host_requirements_warning__([
          %{plugin: :mob_screencast, requirement: "add the mediaProjection <service>"},
          %{plugin: :mob_camera, requirement: "declare a FileProvider"}
        ])

      assert msg =~ "manual steps the build can NOT do for you"
      assert msg =~ "[mob_screencast] add the mediaProjection <service>"
      assert msg =~ "[mob_camera] declare a FileProvider"
    end
  end

  describe "__elixir_lib_decision__/3 (which Elixir stdlib to bundle)" do
    test "missing configured path → detect from running BEAM" do
      assert NativeBuild.__elixir_lib_decision__(false, nil, "1.20.0") ==
               {:use_detected, :missing}
    end

    test "matching version → honor the configured path" do
      assert NativeBuild.__elixir_lib_decision__(true, "1.20.0", "1.20.0") ==
               {:use_configured}
    end

    test "version skew → fall back to the toolchain's stdlib" do
      # The exact bug this guards: mob.exs pinned 1.20.0-rc.5 while the toolchain
      # is 1.20.0 final. rc.5's elixir_quote lacks validate_quote/1, so bundling
      # it crashes on-device Ecto-migration compilation.
      assert NativeBuild.__elixir_lib_decision__(true, "1.20.0-rc.5", "1.20.0") ==
               {:use_detected, :version_skew}
    end

    test "present but unreadable version → honor config (can't prove it wrong)" do
      assert NativeBuild.__elixir_lib_decision__(true, nil, "1.20.0") ==
               {:use_configured}
    end
  end

  describe "__elixir_lib_skew_warning__/4" do
    test "names both versions, the failure mode, and the fallback" do
      msg =
        NativeBuild.__elixir_lib_skew_warning__(
          "/x/1.20.0-rc.5-otp-29/lib",
          "1.20.0-rc.5",
          "1.20.0",
          "/y/1.20.0-otp-29/lib"
        )

      assert msg =~ "1.20.0-rc.5"
      assert msg =~ "1.20.0"
      assert msg =~ "validate_quote/1"
      assert msg =~ "/y/1.20.0-otp-29/lib"
      assert msg =~ "mob.exs"
    end
  end

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

    test "x86_64 returns the x86_64 path when provided" do
      assert NativeBuild.otp_dir_for_abi("x86_64", "/otp/arm64", "/otp/arm32", "/otp/x86_64") ==
               "/otp/x86_64"
    end

    test "unknown ABI still falls back to arm64 when x86_64 path is provided" do
      assert NativeBuild.otp_dir_for_abi("x86", "/otp/arm64", "/otp/arm32", "/otp/x86_64") ==
               "/otp/arm64"
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

  describe "plugin Kotlin bootstrap helpers" do
    test "__parse_kotlin_package__ extracts the FQ package" do
      assert NativeBuild.__parse_kotlin_package__(
               "package io.mob.bluetooth\n\nobject MobBluetoothBridge {}"
             ) == "io.mob.bluetooth"
    end

    test "__parse_kotlin_package__ tolerates leading whitespace / comments before it" do
      src = "// header\n  package io.mob.bluetooth\n"
      assert NativeBuild.__parse_kotlin_package__(src) == "io.mob.bluetooth"
    end

    test "__parse_kotlin_package__ returns nil when there's no package line" do
      assert NativeBuild.__parse_kotlin_package__("object Foo {}") == nil
    end

    test "__bridge_kt_dest__ maps package + basename under the java root" do
      assert NativeBuild.__bridge_kt_dest__(
               "android/app/src/main/java",
               "io.mob.bluetooth",
               "MobBluetoothBridge.kt"
             ) == "android/app/src/main/java/io/mob/bluetooth/MobBluetoothBridge.kt"
    end

    test "__bootstrap_kotlin__ emits register() + activity handoff per bridge class" do
      src = NativeBuild.__bootstrap_kotlin__(["io.mob.bluetooth.MobBluetoothBridge"])
      assert src =~ "package io.mob.plugin"
      assert src =~ "import android.app.Activity"
      assert src =~ "object MobPluginBootstrap"
      assert src =~ "fun registerAll(activity: Activity)"
      assert src =~ "io.mob.bluetooth.MobBluetoothBridge.register()"
      assert src =~ "handOff(io.mob.bluetooth.MobBluetoothBridge, activity)"
      assert src =~ "collectPermissionProvider(io.mob.bluetooth.MobBluetoothBridge)"
      # The cast lives in the Any-typed helper, never inline against a final object.
      assert src =~ "private fun handOff(bridge: Any, activity: Activity)"
      assert src =~ "(bridge as? MobActivityAware)?.setActivity(activity)"
      assert src =~ "private fun collectPermissionProvider(bridge: Any)"
      assert src =~ "(bridge as? MobPermissionProvider)?.let {"
      refute src =~ "MobBluetoothBridge as? MobActivityAware"
    end

    test "__bootstrap_kotlin__ always exposes permissionsFor for core to consult" do
      # Present with bridges...
      with_bridge = NativeBuild.__bootstrap_kotlin__(["io.mob.location.MobLocationBridge"])

      assert with_bridge =~
               "private val permissionProviders = mutableListOf<MobPermissionProvider>()"

      assert with_bridge =~ "fun permissionsFor(cap: String): Array<String>?"

      # ...and without (so MobBridge can reference it unconditionally).
      empty = NativeBuild.__bootstrap_kotlin__([])
      assert empty =~ "fun permissionsFor(cap: String): Array<String>?"
      assert empty =~ "private val permissionProviders = mutableListOf<MobPermissionProvider>()"
    end

    test "__bootstrap_kotlin__ hands the activity to every bridge uniformly" do
      src =
        NativeBuild.__bootstrap_kotlin__([
          "io.mob.bluetooth.MobBluetoothBridge",
          "io.mob.zigextras.MobZigExtrasBridge"
        ])

      # One register() + one handOff() per class, no per-plugin branching, and
      # exactly one shared helper holding the single cast.
      assert length(Regex.scan(~r/\.register\(\)/, src)) == 2
      assert length(Regex.scan(~r/handOff\([\w.]+, activity\)/, src)) == 2
      assert length(Regex.scan(~r/collectPermissionProvider\([\w.]+\)/, src)) == 2
      assert length(Regex.scan(~r/as\? MobActivityAware/, src)) == 1
      assert length(Regex.scan(~r/as\? MobPermissionProvider/, src)) == 1
    end

    test "__bootstrap_kotlin__ emits an empty registerAll body and no register helpers when no bridges" do
      src = NativeBuild.__bootstrap_kotlin__([])
      assert src =~ "fun registerAll(activity: Activity) {}"
      refute src =~ ".register()"
      refute src =~ "handOff"
      refute src =~ "collectPermissionProvider"
    end

    test "__activity_aware_kotlin__ emits the stable MobActivityAware contract" do
      src = NativeBuild.__activity_aware_kotlin__()
      assert src =~ "package io.mob.plugin"
      assert src =~ "import android.app.Activity"
      assert src =~ "interface MobActivityAware {"
      assert src =~ "fun setActivity(activity: Activity)"
    end

    test "__permission_provider_kotlin__ emits the stable MobPermissionProvider contract" do
      src = NativeBuild.__permission_provider_kotlin__()
      assert src =~ "package io.mob.plugin"
      assert src =~ "interface MobPermissionProvider {"
      assert src =~ "fun permissionsFor(cap: String): Array<String>?"
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

    test "removing the plugin strips its managed permission region, keeping host perms" do
      added =
        NativeBuild.__merge_android_permissions__(@manifest_with_perms, [
          "android.permission.BLUETOOTH_CONNECT"
        ])

      assert added =~ "BLUETOOTH_CONNECT"
      cleaned = NativeBuild.__merge_android_permissions__(added, [])
      refute cleaned =~ "BLUETOOTH_CONNECT"
      refute cleaned =~ "mob:plugin-permissions"
      # host-declared permissions are untouched
      assert cleaned =~ "android.permission.INTERNET"
      assert cleaned == @manifest_with_perms
    end

    test "a host-declared permission is not duplicated into the managed region" do
      out =
        NativeBuild.__merge_android_permissions__(@manifest_with_perms, [
          "android.permission.CAMERA"
        ])

      # CAMERA already declared by hand → not added again
      assert length(String.split(out, ~s(android:name="android.permission.CAMERA"))) == 2
    end

    test "forward-only: an existing UNFENCED entry is treated as host-authored" do
      # Simulates an app an older mob_dev already patched (CAMERA appended
      # unfenced). It's indistinguishable from a hand-added permission, so it is
      # neither re-added to the fence nor removed when the plugin goes away.
      with_plugin =
        NativeBuild.__merge_android_permissions__(@manifest_with_perms, [
          "android.permission.CAMERA"
        ])

      assert with_plugin == @manifest_with_perms
      refute with_plugin =~ "mob:plugin-permissions"

      # plugin removed → the pre-existing unfenced CAMERA line survives
      cleaned = NativeBuild.__merge_android_permissions__(with_plugin, [])
      assert cleaned =~ "android.permission.CAMERA"
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

    test "the managed region sits after host permissions (before <application)" do
      perms = ["android.permission.BLUETOOTH_CONNECT"]
      result = NativeBuild.__merge_android_permissions__(@manifest_with_perms, perms)

      # Host perms stay first; the fenced plugin perm follows, still before
      # <application: INTERNET, CAMERA, RECORD_AUDIO, then BLUETOOTH_CONNECT.
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

    test "removing the plugin strips its managed dep region, keeping host deps" do
      added = NativeBuild.__merge_gradle_deps__(@gradle, ["com.example:foo:1.0.0"])
      assert added =~ "com.example:foo:1.0.0"
      # region lives inside the dependencies block
      assert added =~ ~r/dependencies\s*\{.*mob:plugin-deps.*\}/s
      cleaned = NativeBuild.__merge_gradle_deps__(added, [])
      refute cleaned =~ "com.example:foo:1.0.0"
      refute cleaned =~ "mob:plugin-deps"
      assert cleaned =~ "androidx.appcompat:appcompat:1.6.1"
      assert cleaned == @gradle
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

  describe "dep detection (deps_paths, not stale _build dirs — the MLX-404 lesson)" do
    test "__dep_in_project__/2 keys on deps_paths" do
      assert NativeBuild.__dep_in_project__(%{pythonx: "/deps/pythonx"}, :pythonx)
      refute NativeBuild.__dep_in_project__(%{}, :pythonx)
    end

    @tag :tmp_dir
    test "a leftover _build/dev/lib/<dep> dir no longer counts", %{tmp_dir: tmp} do
      File.mkdir_p!(Path.join([tmp, "_build", "dev", "lib", "pythonx", "ebin"]))
      # mob_dev itself deps neither pythonx nor emlx; the stale dir is ignored.
      refute NativeBuild.pythonx_in_project?(tmp)
      refute NativeBuild.emlx_in_project?(tmp)
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

  describe "project_nif_zig_args/1" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "project_nif_args_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)

      old_static_nifs = Application.get_env(:mob_dev, :static_nifs)
      cwd = File.cwd!()

      on_exit(fn ->
        if is_nil(old_static_nifs) do
          Application.delete_env(:mob_dev, :static_nifs)
        else
          Application.put_env(:mob_dev, :static_nifs, old_static_nifs)
        end

        File.cd!(cwd)
        File.rm_rf!(tmp)
      end)

      File.cd!(tmp)
      :ok
    end

    test "adds per-ABI extra static archives to project_rust_libs and emits guard flag" do
      Application.put_env(:mob_dev, :static_nifs, [
        %{
          module: :ghostty_vt,
          archs: [:android_arm64],
          guard: "MOB_STATIC_GHOSTTY_VT_NIF",
          extra_static_libs: %{
            android_arm64: "native/ghostty_vt/lib-android-arm64/libghostty-vt.a"
          }
        }
      ])

      assert {:ok, args} = NativeBuild.project_nif_zig_args(:android_arm64)

      expected_lib = Path.expand("native/ghostty_vt/lib-android-arm64/libghostty-vt.a")
      assert "-Dproject_rust_libs=#{expected_lib}" in args
      assert "-Dghostty_vt_static=true" in args
    end

    test "does not add extra static archives or guard flags on non-matching ABIs" do
      Application.put_env(:mob_dev, :static_nifs, [
        %{
          module: :ghostty_vt,
          archs: [:android_arm64],
          guard: "MOB_STATIC_GHOSTTY_VT_NIF",
          extra_static_libs: %{
            android_arm64: "native/ghostty_vt/lib-android-arm64/libghostty-vt.a"
          }
        }
      ])

      assert {:ok, args} = NativeBuild.project_nif_zig_args(:android_arm32)

      assert "-Dproject_rust_libs=" in args
      refute "-Dghostty_vt_static=true" in args
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

  describe "plugin_static_lib_args/1" do
    test "empty list → no flag (so pre-plugin build.zig isn't passed an unknown -D)" do
      assert NativeBuild.plugin_static_lib_args([]) == []
    end

    test "one archive → -Dplugin_static_libs=<path>" do
      assert NativeBuild.plugin_static_lib_args(["/b/android_arm64/libnx_eigen_nif.a"]) ==
               ["-Dplugin_static_libs=/b/android_arm64/libnx_eigen_nif.a"]
    end

    test "multiple archives → one comma-joined flag" do
      args = NativeBuild.plugin_static_lib_args(["/b/liba.a", "/b/libb.a"])
      assert args == ["-Dplugin_static_libs=/b/liba.a,/b/libb.a"]
    end
  end

  describe "android_abi_to_cpp_target/1" do
    test "arm64 ABI strings → :android_arm64" do
      assert NativeBuild.android_abi_to_cpp_target("arm64-v8a") == :android_arm64
      assert NativeBuild.android_abi_to_cpp_target("arm64") == :android_arm64
    end

    test "arm32 ABI strings → :android_arm32" do
      assert NativeBuild.android_abi_to_cpp_target("armeabi-v7a") == :android_arm32
      assert NativeBuild.android_abi_to_cpp_target("arm32") == :android_arm32
    end

    test "x86_64 → :android_x86_64 (a real target id CppArchive can't build yet)" do
      assert NativeBuild.android_abi_to_cpp_target("x86_64") == :android_x86_64
    end

    test "unknown ABI strings → nil" do
      assert NativeBuild.android_abi_to_cpp_target("riscv64") == nil
      assert NativeBuild.android_abi_to_cpp_target("") == nil
      assert NativeBuild.android_abi_to_cpp_target("x86") == nil
    end
  end

  describe "cpp_archive_target_decision/2 + unsupported_cpp_archive_target_error/2" do
    @cpp_spec %{plugin: :nx_cpu, module: :nx_cpu_nif}

    test ":none when no cpp_archive spec is present (unsupported ABI is harmless then)" do
      # The x86_64 emulator ABI gap only matters when a plugin actually needs it.
      assert NativeBuild.cpp_archive_target_decision([], :android_x86_64) == :none
    end

    test "{:error, _} when a cpp_archive spec is present on an unsupported ABI (x86_64)" do
      assert {:error, msg} =
               NativeBuild.cpp_archive_target_decision([@cpp_spec], :android_x86_64)

      # Names the unsupported ABI and the plugin/module, explains arm-only support.
      assert msg =~ ":android_x86_64"
      assert msg =~ "nx_cpu/nx_cpu_nif"
      assert msg =~ ":android_arm64"
      assert msg =~ ":android_arm32"
    end

    test ":build when a cpp_archive spec is present on a supported ABI" do
      assert NativeBuild.cpp_archive_target_decision([@cpp_spec], :android_arm64) == :build
      assert NativeBuild.cpp_archive_target_decision([@cpp_spec], :android_arm32) == :build
      assert NativeBuild.cpp_archive_target_decision([@cpp_spec], :ios_sim) == :build
    end

    test "error message lists every active plugin/module" do
      specs = [@cpp_spec, %{plugin: :other, module: :other_nif}]
      msg = NativeBuild.unsupported_cpp_archive_target_error(specs, :android_x86_64)
      assert msg =~ "nx_cpu/nx_cpu_nif"
      assert msg =~ "other/other_nif"
    end
  end

  describe "nxeigen_provided_by_plugin?/0" do
    test "false when no cpp_archive plugin provides nx_eigen_nif_init (mob_dev's own env)" do
      # mob_dev activates no plugins, so the legacy core NxEigen build stays the
      # active path. (Guards the coexistence logic; the plugin-present case is
      # covered by Merge.static_archives tests.)
      refute NativeBuild.nxeigen_provided_by_plugin?()
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

  describe "__regen_formats__/2 (driver_tab format selection)" do
    test "an app with existing tables keeps its format(s)" do
      assert NativeBuild.__regen_formats__([:zig], false) == [:zig]
      assert NativeBuild.__regen_formats__([:c], true) == [:c]
      assert NativeBuild.__regen_formats__([:zig, :c], false) == [:zig, :c]
    end

    test "no existing table + no plugin NIFs → generate nothing (links against mob core)" do
      assert NativeBuild.__regen_formats__([], false) == []
    end

    test "no existing table + a plugin NIF → create a zig table (the device fix)" do
      # Without this, a plugin's <module>_nif_init links but never registers,
      # so the NIF is :nif_not_loaded on device (caught verifying the showcase).
      assert NativeBuild.__regen_formats__([], true) == [:zig]
    end
  end

  describe "__prune_plugin_artifacts__/2 (the plugin-removal prune)" do
    setup do
      dir = Path.join(System.tmp_dir!(), "mob_prune_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      cwd = File.cwd!()
      File.cd!(dir)
      on_exit(fn -> File.cd!(cwd) end)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    defp touch!(rel) do
      File.mkdir_p!(Path.dirname(rel))
      File.write!(rel, "x")
      rel
    end

    test "first run prunes nothing and records the current set" do
      a = touch!("android/app/src/main/java/io/cam/CamBridge.kt")
      assert NativeBuild.__prune_plugin_artifacts__(:android_kotlin, [a]) == []
      assert File.exists?(a)
      assert File.exists?("priv/generated/.mob_plugin_artifacts/android_kotlin")
    end

    test "a file dropped from the current set is deleted on the next run" do
      cam = touch!("android/app/src/main/java/io/cam/CamBridge.kt")
      loc = touch!("android/app/src/main/java/io/loc/LocBridge.kt")
      NativeBuild.__prune_plugin_artifacts__(:android_kotlin, [cam, loc])

      # mob_camera removed: next build only writes the location bridge.
      pruned = NativeBuild.__prune_plugin_artifacts__(:android_kotlin, [loc])

      assert pruned == [cam]
      refute File.exists?(cam), "orphaned bridge should be pruned"
      assert File.exists?(loc), "still-activated bridge must survive"
    end

    test "an empty current set (all plugins removed) prunes everything prior" do
      a = touch!("priv/generated/plugin_assets/assets/plugin/cam/icon.png")
      NativeBuild.__prune_plugin_artifacts__(:images, [a])

      assert NativeBuild.__prune_plugin_artifacts__(:images, []) == [a]
      refute File.exists?(a)
    end

    test "scopes are independent — pruning one never touches another" do
      kt = touch!("android/app/src/main/java/io/cam/CamBridge.kt")
      mig = touch!("priv/repo/migrations/20260101_cam.exs")
      NativeBuild.__prune_plugin_artifacts__(:android_kotlin, [kt])
      NativeBuild.__prune_plugin_artifacts__(:migrations, [mig])

      # Re-run kotlin with nothing; the migration in another scope is untouched.
      NativeBuild.__prune_plugin_artifacts__(:android_kotlin, [])

      refute File.exists?(kt)
      assert File.exists?(mig)
    end

    test "a ledgered path already gone (manually deleted) does not crash" do
      a = touch!("android/app/src/main/java/io/cam/CamBridge.kt")
      NativeBuild.__prune_plugin_artifacts__(:android_kotlin, [a])
      File.rm!(a)

      assert NativeBuild.__prune_plugin_artifacts__(:android_kotlin, []) == []
    end
  end

  describe "zig_build_plan/3 (fail fast when the JNI build can't succeed)" do
    test "no build.zig: nothing to do, regardless of zig or C sources" do
      assert NativeBuild.zig_build_plan(false, false, false) == :skip_no_build_zig
      assert NativeBuild.zig_build_plan(false, true, true) == :skip_no_build_zig
      assert NativeBuild.zig_build_plan(false, false, true) == :skip_no_build_zig
    end

    test "zig present: drive the real build.zig path (C-source presence irrelevant)" do
      assert NativeBuild.zig_build_plan(true, true, false) == :run_zig
      assert NativeBuild.zig_build_plan(true, true, true) == :run_zig
    end

    test "no zig but the mob dep still ships C sources: CMake fallback can compile them" do
      assert NativeBuild.zig_build_plan(true, false, true) == :legacy_cmake
    end

    test "no zig AND no C sources (mob 0.7+): obvious failure, so signal :zig_required" do
      assert NativeBuild.zig_build_plan(true, false, false) == :zig_required
    end
  end

  describe "zig_required_message/0" do
    test "names the cause and the exact fix" do
      msg = NativeBuild.zig_required_message()

      # the cause: zig missing + the vanished C fallback source
      assert msg =~ "zig is not on your PATH"
      assert msg =~ "mob_nif.c"
      # the fix: the version mob.doctor pins, plus how to verify
      assert msg =~ "zig 0.15"
      assert msg =~ "mix mob.doctor"
    end

    test "stays in plain prose (no em dashes leaking into user-facing output)" do
      refute NativeBuild.zig_required_message() =~ "—"
    end
  end

  describe "Android update-only native install" do
    test "fails closed when discovery resolves no update targets" do
      parent = self()

      runner = fn command, args ->
        send(parent, {:command, command, args})
        {"List of devices attached\n", 0}
      end

      assert {:error, :no_targets} =
               NativeBuild.resolve_android_update_targets(nil, runner)

      assert_received {:command, "adb", ["devices"]}
      refute_received {:command, _, _}
    end

    test "default fanout resolves every ready serial when the full snapshot is ready" do
      runner = fn "adb", ["devices"] ->
        {"""
         * daemon not running; starting now at tcp:5037
         * daemon started successfully
         List of devices attached
         serial-a\tdevice
         serial-b\tdevice
         """, 0}
      end

      assert {:ok, ["serial-a", "serial-b"]} =
               NativeBuild.resolve_android_update_targets(nil, runner)
    end

    test "implicit fanout rejects mixed offline, unauthorized, and unknown states" do
      cases = [
        {"offline", :offline},
        {"unauthorized", :unauthorized},
        {"recovery", :unknown_state}
      ]

      Enum.each(cases, fn {state, reason} ->
        output = "List of devices attached\nready\tdevice\nblocked\t#{state}\n"
        runner = fn "adb", ["devices"] -> {output, 0} end

        assert {:error, ^reason} =
                 NativeBuild.resolve_android_update_targets(nil, runner)
      end)
    end

    test "rejects duplicate and malformed discovery snapshots" do
      duplicate = "List of devices attached\nserial-a\tdevice\nserial-a\tdevice\n"
      malformed = "List of devices attached\nserial-a\tdevice\textra\n"

      assert {:error, :duplicate_target} =
               NativeBuild.resolve_android_update_targets(
                 nil,
                 fn "adb", ["devices"] -> {duplicate, 0} end
               )

      for output <- [malformed, "serial-a\tdevice\n", <<255, 254>>] do
        assert {:error, :malformed_discovery} =
                 NativeBuild.resolve_android_update_targets(
                   nil,
                   fn "adb", ["devices"] -> {output, 0} end
                 )
      end
    end

    test "accepts exactly 32 maximum-length serials and rejects larger target sets" do
      serials =
        for index <- 1..33 do
          prefix = Integer.to_string(index)
          prefix <> String.duplicate("a", 128 - byte_size(prefix))
        end

      output = fn selected ->
        "List of devices attached\n" <>
          Enum.map_join(selected, "", &"#{&1}\tdevice\n")
      end

      accepted = Enum.take(serials, 32)

      assert {:ok, ^accepted} =
               NativeBuild.resolve_android_update_targets(
                 nil,
                 fn "adb", ["devices"] -> {output.(accepted), 0} end
               )

      assert {:error, :too_many_targets} =
               NativeBuild.resolve_android_update_targets(
                 nil,
                 fn "adb", ["devices"] -> {output.(serials), 0} end
               )
    end

    test "rejects oversized discovery output instead of parsing a truncated prefix" do
      output = "List of devices attached\n" <> String.duplicate("x", 8_193)

      assert {:error, :discovery_output_too_large} =
               NativeBuild.resolve_android_update_targets(
                 nil,
                 fn "adb", ["devices"] -> {output, 0} end
               )
    end

    test "resolves only the requested online serial, including a bare WiFi address" do
      output = """
      List of devices attached
      ZY22K6BSJM\tdevice
      10.0.0.17:5555\tdevice
      emulator-5554\tdevice
      """

      runner = fn "adb", ["devices"] -> {output, 0} end

      assert {:ok, ["10.0.0.17:5555"]} =
               NativeBuild.resolve_android_update_targets("10.0.0.17", runner)
    end

    test "fails closed for offline, unauthorized, missing, ambiguous, and invalid targets" do
      runner = fn "adb", ["devices"] ->
        {"""
         List of devices attached
         offline-one\toffline
         auth-one\tunauthorized
         10.0.0.17\tdevice
         10.0.0.17:5555\tdevice
         """, 0}
      end

      assert {:error, :offline} =
               NativeBuild.resolve_android_update_targets("offline-one", runner)

      assert {:error, :unauthorized} =
               NativeBuild.resolve_android_update_targets("auth-one", runner)

      assert {:error, :target_not_connected} =
               NativeBuild.resolve_android_update_targets("missing", runner)

      assert {:error, :ambiguous_target} =
               NativeBuild.resolve_android_update_targets("10.0.0.17", runner)

      assert {:error, :invalid_target} =
               NativeBuild.resolve_android_update_targets("--transport-any", runner)
    end

    test "explicit resolution rejects a case-variant discovery collision before mutation" do
      parent = self()

      runner = fn
        "adb", ["devices"] = args ->
          send(parent, {:command, "adb", args})

          {"List of devices attached\nCaseTarget\tdevice\ncasetarget\tdevice\n", 0}

        command, args ->
          send(parent, {:command, command, args})
          {"Success\n", 0}
      end

      assert {:error, :ambiguous_target} =
               NativeBuild.resolve_android_update_targets("CaseTarget", runner)

      assert_received {:command, "adb", ["devices"]}
      refute_received {:command, _, _}
    end

    test "legacy install and delivery seams require the authoritative transaction" do
      parent = self()
      apk = "/tmp/app-debug.apk"

      runner = fn
        "adb", ["devices"] = args ->
          send(parent, {:command, "adb", args})
          {"List of devices attached\nCaseTarget\tdevice\n", 0}

        command, args ->
          send(parent, {:command, command, args})
          {"Success\n", 0}
      end

      deliver = fn serial ->
        send(parent, {:delivered, serial})
        :ok
      end

      assert {:ok, ["CaseTarget"]} =
               NativeBuild.resolve_android_update_targets("CaseTarget", runner)

      assert {:error, :authoritative_transaction_required} =
               apply(NativeBuild, :install_android_updates, [apk, ["CaseTarget"], runner])

      assert {:error, message} =
               apply(NativeBuild, :install_and_deliver_android, [
                 apk,
                 ["CaseTarget"],
                 runner,
                 deliver
               ])

      assert message =~ "authoritative payload transaction"
      assert_received {:command, "adb", ["devices"]}
      refute_received {:command, _, _}
      refute_received {:delivered, _}
    end

    test "accepts only recognized adb success output" do
      assert :updated = NativeBuild.interpret_adb_update("Success\n", 0)

      assert :updated =
               NativeBuild.interpret_adb_update("Performing Streamed Install\nSuccess\n", 0)

      assert {:failed, :suspicious_success} =
               NativeBuild.interpret_adb_update("Success\nunexpected extra line\n", 0)

      assert {:failed, :suspicious_success} = NativeBuild.interpret_adb_update("", 0)
      assert {:failed, :unknown_failure} = NativeBuild.interpret_adb_update("Success\n", 1)
      assert {:failed, :unknown_failure} = NativeBuild.interpret_adb_update(<<255, 254>>, 0)
    end

    test "accepts exactly 4096 verified bytes and rejects every oversized install result" do
      exact = "Success" <> String.duplicate("\n", 4_096 - byte_size("Success"))
      assert byte_size(exact) == 4_096
      assert :updated = NativeBuild.interpret_adb_update(exact, 0)

      assert {:failed, :unknown_failure} =
               NativeBuild.interpret_adb_update(exact <> "\n", 0)

      assert {:failed, :unknown_failure} =
               NativeBuild.interpret_adb_update(
                 exact <> "Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE]\n",
                 0
               )
    end

    test "classifies destructive and recoverable adb failures without returning raw output" do
      cases = [
        {"Failure [INSTALL_FAILED_INSUFFICIENT_STORAGE] raw-private-detail",
         :insufficient_storage},
        {"Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE] raw-private-detail", :signature_mismatch},
        {"Failure [INSTALL_PARSE_FAILED_INCONSISTENT_CERTIFICATES]", :signature_mismatch},
        {"Failure [INSTALL_FAILED_VERSION_DOWNGRADE]", :version_downgrade},
        {"error: device offline", :offline},
        {"error: device unauthorized. Please check the confirmation dialog", :unauthorized},
        {"error: device not found", :unavailable},
        {"Failure [INSTALL_FAILED_DEXOPT]", :install_rejected},
        {"some unrecognized failure containing raw-private-detail", :unknown_failure}
      ]

      Enum.each(cases, fn {output, reason} ->
        result = NativeBuild.interpret_adb_update(output, 1)
        assert result == {:failed, reason}
        refute inspect(result) =~ "raw-private-detail"
      end)
    end

    test "legacy seams still reject invalid target sets without invoking callbacks" do
      parent = self()

      runner = fn command, args ->
        send(parent, {:command, command, args})
        {"unexpected", 0}
      end

      deliver = fn serial ->
        send(parent, {:delivered, serial})
        :ok
      end

      assert {:error, :invalid_target} =
               NativeBuild.resolve_android_update_targets("--all", runner)

      assert {:error, :no_explicit_targets} =
               apply(NativeBuild, :install_android_updates, ["/tmp/app.apk", [], runner])

      assert {:error, :invalid_target} =
               apply(NativeBuild, :install_android_updates, [
                 "/tmp/app.apk",
                 ["--all"],
                 runner
               ])

      assert {:error, _message} =
               apply(NativeBuild, :install_and_deliver_android, [
                 "/tmp/app.apk",
                 ["CaseTarget", "casetarget"],
                 runner,
                 deliver
               ])

      refute_received {:command, _, _}
      refute_received {:delivered, _}
    end
  end

  describe "plist_array_additions/2 (plugin array plist merge, e.g. UIBackgroundModes)" do
    test "returns items not already present, input order preserved" do
      assert NativeBuild.plist_array_additions(
               ["audio"],
               ["bluetooth-central", "bluetooth-peripheral"]
             ) == ["bluetooth-central", "bluetooth-peripheral"]
    end

    test "skips items already on disk (idempotent re-merge)" do
      assert NativeBuild.plist_array_additions(
               ["audio", "bluetooth-central"],
               ["bluetooth-central", "bluetooth-peripheral"]
             ) == ["bluetooth-peripheral"]
    end

    test "de-duplicates within the requested items" do
      assert NativeBuild.plist_array_additions([], ["x", "x", "y"]) == ["x", "y"]
    end

    test "drops non-binary entries" do
      assert NativeBuild.plist_array_additions([], ["ok", :atom, 1, nil]) == ["ok"]
    end

    test "empty when everything is already present" do
      assert NativeBuild.plist_array_additions(["a", "b"], ["a", "b"]) == []
    end
  end

  describe "build_file_supports_plugins?/1 (MOB-7: blank-iOS mob_register_plugins link)" do
    test "true when the iOS build file exposes the plugin_swift_files option" do
      src = ~s|
        const plugin_swift_files = b.option([]const u8, "plugin_swift_files", "…") orelse "";
        const plugin_frameworks = b.option([]const u8, "plugin_frameworks", "…") orelse "";
      |

      assert NativeBuild.build_file_supports_plugins?(src)
    end

    test "false for a pre-plugin build file (no plugin_swift_files option)" do
      src = ~s|
        const mob_dir = b.option([]const u8, "mob_dir", "…") orelse "";
        const sdkroot = b.option([]const u8, "sdkroot", "…") orelse "";
      |

      refute NativeBuild.build_file_supports_plugins?(src)
    end

    test "false for empty content" do
      refute NativeBuild.build_file_supports_plugins?("")
    end
  end

  describe "ios_plugin_swift_mode/2 (MOB-7: the actual bootstrap decision)" do
    # This is the fix. The :bootstrap_only case — no plugins activated, but the
    # build file supports plugins (so its AppDelegate calls mob_register_plugins)
    # — is what a --blank iOS app needs; flipping it back to :none reintroduces
    # the undefined-symbol link failure.
    test "no plugins + plugin-aware build file => :bootstrap_only (the MOB-7 fix)" do
      assert NativeBuild.ios_plugin_swift_mode([], true) == :bootstrap_only
    end

    test "no plugins + legacy build file => :none (omit flags, keep legacy building)" do
      assert NativeBuild.ios_plugin_swift_mode([], false) == :none
    end

    test "activated plugins => :with_plugins regardless of build-file support" do
      assert NativeBuild.ios_plugin_swift_mode([{"dir", %{}}], true) == :with_plugins
      assert NativeBuild.ios_plugin_swift_mode([{"dir", %{}}], false) == :with_plugins
    end
  end

  describe "ios_build_file_supports_plugins?/1 (file-read wrapper)" do
    @describetag :tmp_dir

    test "true when the file exists and declares the option", %{tmp_dir: dir} do
      path = Path.join(dir, "build.zig")
      File.write!(path, ~s|const plugin_swift_files = b.option(...);|)
      assert NativeBuild.ios_build_file_supports_plugins?(path)
    end

    test "false when the file exists without the option", %{tmp_dir: dir} do
      path = Path.join(dir, "build.zig")
      File.write!(path, ~s|const mob_dir = b.option(...);|)
      refute NativeBuild.ios_build_file_supports_plugins?(path)
    end

    test "false when the file is missing (legacy scaffold, no build.zig)", %{tmp_dir: dir} do
      refute NativeBuild.ios_build_file_supports_plugins?(Path.join(dir, "does_not_exist.zig"))
    end
  end

  describe "remove_stale_release_otp_zip/1" do
    @describetag :tmp_dir

    # Regression guard: `mix mob.release --android` used to write
    # `assets/otp.zip` into the shared `src/main/assets/` source set, which
    # Gradle merges into every build variant. A checkout that had ever run a
    # release build carried that file into every subsequent debug build too,
    # where MobBridge.kt's extractOtpIfNeeded() would re-extract it on the
    # next app launch and silently overwrite freshly pushed dev BEAMs with
    # the stale release snapshot. Release builds now write to the
    # variant-scoped `src/release/assets/` instead, but existing checkouts
    # may still carry the leftover file — the debug build path removes it
    # so it can't keep poisoning deploys.
    test "removes a leftover otp.zip from the shared main asset source set", %{tmp_dir: dir} do
      assets_dir = Path.join([dir, "app", "src", "main", "assets"])
      File.mkdir_p!(assets_dir)
      stale = Path.join(assets_dir, "otp.zip")
      File.write!(stale, "stale release bundle")

      assert NativeBuild.remove_stale_release_otp_zip(dir) == :ok
      refute File.exists?(stale)
    end

    test "is a no-op when no stale zip is present", %{tmp_dir: dir} do
      assert NativeBuild.remove_stale_release_otp_zip(dir) == :ok
    end

    test "leaves sibling assets (e.g. logos) untouched", %{tmp_dir: dir} do
      assets_dir = Path.join([dir, "app", "src", "main", "assets"])
      File.mkdir_p!(assets_dir)
      File.write!(Path.join(assets_dir, "otp.zip"), "stale")
      logo = Path.join(assets_dir, "mob_logo_dark.png")
      File.write!(logo, "logo bytes")

      NativeBuild.remove_stale_release_otp_zip(dir)

      assert File.exists?(logo)
    end
  end

  describe "install_and_deliver_android_runtime/8 authoritative transaction" do
    @describetag :tmp_dir

    test "requires authoritative callbacks before any device command", %{tmp_dir: dir} do
      fixture = authoritative_android_fixture!(dir, ["serial-a"])

      runner = fn executable, args ->
        send(self(), {:native_probe, executable, args})
        {"unexpected", 0}
      end

      assert {:error, reason} =
               NativeBuild.install_and_deliver_android_runtime(
                 fixture.apk,
                 fixture.serials,
                 fixture.package,
                 fixture.elixir_lib,
                 fixture.otp_arm64,
                 fixture.otp_arm32,
                 fixture.otp_x86_64,
                 probe_runner: runner,
                 tmp_root: dir
               )

      assert reason =~ "authoritative payload plan"
      refute_received {:native_probe, _, _}
    end

    test "installs the immutable plan APK and returns a native_ready set-wide lease", %{
      tmp_dir: dir
    } do
      fixture = authoritative_android_fixture!(dir, ["serial-a"])
      owner_state = start_supervised!({Agent, fn -> true end})
      probe_runner = authoritative_android_probe_runner(self(), fixture, owner_state)
      otp_runner = authoritative_android_otp_runner(self())

      preinstall = fn input -> {:ok, authoritative_android_payload_plan!(dir, input)} end
      cleanup = fn plan -> cleanup_authoritative_android_plan(plan) end

      assert {:ok,
              %{
                deploy_lock: %{phase: :native_ready, state: :held_success} = lease,
                payload_plan: plan
              }} =
               run_authoritative_android(
                 fixture,
                 dir,
                 probe_runner,
                 otp_runner,
                 preinstall,
                 cleanup
               )

      assert lease.owner == "ownerproof000001"
      assert lease.serials == ["serial-a"]

      commands = drain_native_commands(:native_probe)

      assert Enum.any?(commands, fn
               {"adb", ["-s", "serial-a", "install", "-r", installed_apk]} ->
                 installed_apk == plan.apk.path and installed_apk != fixture.apk

               _command ->
                 false
             end)

      assert File.regular?(plan.apk.path)
      assert cleanup_authoritative_android_plan(plan) == :ok
    end

    test "accepts only the bounded binary beam-flags payload contract", %{tmp_dir: dir} do
      fixture = authoritative_android_fixture!(dir, ["serial-a"])
      owner_state = start_supervised!({Agent, fn -> true end})
      probe_runner = authoritative_android_probe_runner(self(), fixture, owner_state)
      otp_runner = authoritative_android_otp_runner(self())

      preinstall = fn input ->
        plan = authoritative_android_payload_plan!(dir, input)
        {:ok, put_in(plan.beam.beam_flags, "+S 2:2 -A 4")}
      end

      cleanup = fn plan -> cleanup_authoritative_android_plan(plan) end

      assert {:ok, %{deploy_lock: %{phase: :native_ready}, payload_plan: plan}} =
               run_authoritative_android(
                 fixture,
                 dir,
                 probe_runner,
                 otp_runner,
                 preinstall,
                 cleanup
               )

      assert plan.beam.beam_flags == "+S 2:2 -A 4"
      assert cleanup_authoritative_android_plan(plan) == :ok

      for invalid_flags <- [["+S", "2:2"], String.duplicate("x", 4_097), <<0xFF>>] do
        invalid_preinstall = fn input ->
          invalid_plan = authoritative_android_payload_plan!(dir, input)
          {:ok, put_in(invalid_plan.beam.beam_flags, invalid_flags)}
        end

        assert {:error, "Could not clean authoritative Android payload"} =
                 run_authoritative_android(
                   fixture,
                   dir,
                   probe_runner,
                   otp_runner,
                   invalid_preinstall,
                   fn _plan -> {:error, :injected_cleanup_failure} end
                 )
      end

      commands = drain_native_commands(:native_probe)
      assert Enum.count(commands, &native_install_command?/1) == 1
      assert Enum.count(commands, &native_lock_mutation_command?/1) > 0

      Enum.each(Path.wildcard(Path.join(dir, "authoritative-plan-*.apk")), &File.rm!/1)
      Enum.each(Path.wildcard(Path.join(dir, "authoritative-beams-*.tar")), &File.rm!/1)
    end

    test "rejects no-restart plans, invokes cleanup once, and performs zero lease or install mutation",
         %{tmp_dir: dir} do
      fixture = authoritative_android_fixture!(dir, ["serial-a"])
      owner_state = start_supervised!({Agent, fn -> true end})
      probe_runner = authoritative_android_probe_runner(self(), fixture, owner_state)
      otp_runner = authoritative_android_otp_runner(self())

      preinstall = fn input ->
        plan = authoritative_android_payload_plan!(dir, input)

        restart = %{
          Map.fetch!(plan.restart_by_serial, "serial-a")
          | restart?: false,
            mode: :no_restart
        }

        {:ok, put_in(plan.restart_by_serial["serial-a"], restart)}
      end

      cleanup = fn plan ->
        send(self(), {:payload_cleanup, plan.attempt_id})
        {:error, :injected_cleanup_failure}
      end

      assert {:error, "Could not clean authoritative Android payload"} =
               run_authoritative_android(
                 fixture,
                 dir,
                 probe_runner,
                 otp_runner,
                 preinstall,
                 cleanup
               )

      assert_received {:payload_cleanup, "planbeam00000001"}

      commands = drain_native_commands(:native_probe)
      refute Enum.any?(commands, &native_install_command?/1)
      refute Enum.any?(commands, &native_lock_mutation_command?/1)

      [leaked_apk] = Path.wildcard(Path.join(dir, "authoritative-plan-*.apk"))
      File.rm!(leaked_apk)
      Enum.each(Path.wildcard(Path.join(dir, "authoritative-beams-*.tar")), &File.rm!/1)
    end

    test "freezes OTP archives and refuses every second-target mutation after archive drift", %{
      tmp_dir: dir
    } do
      fixture = authoritative_android_fixture!(dir, ["serial-a", "serial-b"])
      owner_state = start_supervised!({Agent, fn -> true end})
      archive_state = start_supervised!({Agent, fn -> nil end}, id: :otp_archive_state)
      probe_runner = authoritative_android_probe_runner(self(), fixture, owner_state)

      otp_runner =
        authoritative_android_otp_runner(self(), fn
          ["-s", "serial-a", "push", archive, _remote] ->
            Agent.update(archive_state, fn _old -> archive end)

          ["-s", "serial-a", "shell", "rm -f " <> _remote] ->
            archive = Agent.get(archive_state, & &1)
            File.chmod!(archive, 0o600)
            File.write!(archive, "mutated between canonical targets")

          _args ->
            :ok
        end)

      preinstall = fn input -> {:ok, authoritative_android_payload_plan!(dir, input)} end

      cleanup = fn plan ->
        send(self(), {:payload_cleanup, plan.attempt_id})
        cleanup_authoritative_android_plan(plan)
      end

      assert {:error, reason, %{state: :retained_failure, phase: :acquired}} =
               run_authoritative_android(
                 fixture,
                 dir,
                 probe_runner,
                 otp_runner,
                 preinstall,
                 cleanup
               )

      assert reason =~ "OTP archive changed"
      assert_received {:payload_cleanup, "planbeam00000001"}
      probe_commands = drain_native_commands(:native_probe)
      otp_commands = drain_native_commands(:native_otp)

      refute Enum.any?(probe_commands, fn
               {"adb", ["-s", "serial-b", "install" | _args]} -> true
               _command -> false
             end)

      refute Enum.any?(otp_commands, fn
               {"adb", ["-s", "serial-b" | _args]} -> true
               _command -> false
             end)
    end

    test "set-wide owner loss after target A prevents every target B mutation", %{tmp_dir: dir} do
      fixture = authoritative_android_fixture!(dir, ["serial-a", "serial-b"])
      owner_state = start_supervised!({Agent, fn -> true end})
      probe_runner = authoritative_android_probe_runner(self(), fixture, owner_state)

      otp_runner =
        authoritative_android_otp_runner(self(), fn
          ["-s", "serial-a", "shell", "rm -f " <> _remote] ->
            Agent.update(owner_state, fn _valid -> false end)

          _args ->
            :ok
        end)

      preinstall = fn input -> {:ok, authoritative_android_payload_plan!(dir, input)} end

      cleanup = fn plan ->
        cleanup_authoritative_android_plan(plan)
      end

      assert {:error, reason,
              %{state: :retained_ambiguous, phase: :acquired, serials: ["serial-a", "serial-b"]}} =
               run_authoritative_android(
                 fixture,
                 dir,
                 probe_runner,
                 otp_runner,
                 preinstall,
                 cleanup
               )

      assert reason =~ "lease set could not be verified"
      probe_commands = drain_native_commands(:native_probe)
      otp_commands = drain_native_commands(:native_otp)

      refute Enum.any?(probe_commands, fn
               {"adb", ["-s", "serial-b", "install" | _args]} -> true
               _command -> false
             end)

      refute Enum.any?(otp_commands, fn
               {"adb", ["-s", "serial-b" | _args]} -> true
               _command -> false
             end)
    end

    test "non-authoritative install success retains an ambiguous lease and stops later targets",
         %{tmp_dir: dir} do
      fixture = authoritative_android_fixture!(dir, ["serial-a", "serial-b"])
      owner_state = start_supervised!({Agent, fn -> true end})
      base_runner = authoritative_android_probe_runner(self(), fixture, owner_state)

      probe_runner = fn
        "adb", ["-s", "serial-a", "install", "-r", _apk] = args ->
          send(self(), {:native_probe, "adb", args})
          {"Success\nuntrusted trailing output\n", 0}

        executable, args ->
          base_runner.(executable, args)
      end

      otp_runner = authoritative_android_otp_runner(self())
      preinstall = fn input -> {:ok, authoritative_android_payload_plan!(dir, input)} end
      cleanup = fn plan -> cleanup_authoritative_android_plan(plan) end

      assert {:error, reason,
              %{state: :retained_ambiguous, phase: :acquired, serials: ["serial-a", "serial-b"]}} =
               run_authoritative_android(
                 fixture,
                 dir,
                 probe_runner,
                 otp_runner,
                 preinstall,
                 cleanup
               )

      assert reason =~ "not authoritative"
      probe_commands = drain_native_commands(:native_probe)
      assert Enum.count(probe_commands, &native_install_command?/1) == 1

      refute Enum.any?(probe_commands, fn
               {"adb", ["-s", "serial-b", "install" | _args]} -> true
               _command -> false
             end)

      refute Enum.any?(drain_native_commands(:native_otp), fn
               {"adb", _args} -> true
               _local_command -> false
             end)
    end

    test "runner exceptions after acquire preserve the exact ambiguous lease and stop later targets",
         %{tmp_dir: dir} do
      fixture = authoritative_android_fixture!(dir, ["serial-a", "serial-b"])
      owner_state = start_supervised!({Agent, fn -> true end})
      probe_runner = authoritative_android_probe_runner(self(), fixture, owner_state)

      otp_runner =
        authoritative_android_otp_runner(self(), fn
          ["-s", "serial-a", "push" | _args] -> throw(:transport_lost_after_write)
          _args -> :ok
        end)

      preinstall = fn input -> {:ok, authoritative_android_payload_plan!(dir, input)} end

      cleanup = fn plan ->
        send(self(), {:payload_cleanup, plan.attempt_id})
        {:error, :injected_cleanup_failure}
      end

      assert {:error, "Could not clean authoritative Android payload",
              %{
                owner: "ownerproof000001",
                state: :retained_ambiguous,
                phase: :acquired,
                serials: ["serial-a", "serial-b"]
              }} =
               run_authoritative_android(
                 fixture,
                 dir,
                 probe_runner,
                 otp_runner,
                 preinstall,
                 cleanup
               )

      assert_received {:payload_cleanup, "planbeam00000001"}
      probe_commands = drain_native_commands(:native_probe)

      refute Enum.any?(probe_commands, fn
               {"adb", ["-s", "serial-b", "install" | _args]} -> true
               _command -> false
             end)

      Enum.each(Path.wildcard(Path.join(dir, "authoritative-plan-*.apk")), &File.rm!/1)
      Enum.each(Path.wildcard(Path.join(dir, "authoritative-beams-*.tar")), &File.rm!/1)
    end
  end

  defp authoritative_android_fixture!(dir, serials) do
    package = "com.example.casein"
    elixir_lib = Path.join(dir, "authoritative-elixir")

    for app <- ["elixir", "logger", "eex"] do
      ebin = Path.join([elixir_lib, app, "ebin"])
      File.mkdir_p!(ebin)
      File.write!(Path.join(ebin, "#{app}.beam"), "#{app}-runtime")
    end

    File.write!(Path.join([elixir_lib, "elixir", "ebin", "Elixir.Kernel.beam"]), "kernel")

    otp_by_abi =
      Map.new(["arm64-v8a", "armeabi-v7a", "x86_64"], fn abi ->
        otp_dir = Path.join(dir, "authoritative-otp-#{abi}")
        erts_bin = Path.join(otp_dir, "erts-17.0/bin")
        File.mkdir_p!(erts_bin)

        for helper <- ["erl_child_setup", "inet_gethost", "epmd"] do
          File.write!(Path.join(erts_bin, helper), "#{abi}:#{helper}")
        end

        {abi, otp_dir}
      end)

    apk = Path.join(dir, "authoritative-input.apk")

    apk_entries =
      for {abi, otp_dir} <- otp_by_abi,
          {helper, packaged} <- [
            {"erl_child_setup", "liberl_child_setup.so"},
            {"inet_gethost", "libinet_gethost.so"},
            {"epmd", "libepmd.so"}
          ] do
        source = Path.join([otp_dir, "erts-17.0", "bin", helper])
        {String.to_charlist("lib/#{abi}/#{packaged}"), File.read!(source)}
      end

    {:ok, _apk} = :zip.create(String.to_charlist(apk), apk_entries)

    %{
      apk: apk,
      package: package,
      serials: serials,
      elixir_lib: elixir_lib,
      otp_arm64: Map.fetch!(otp_by_abi, "arm64-v8a"),
      otp_arm32: Map.fetch!(otp_by_abi, "armeabi-v7a"),
      otp_x86_64: Map.fetch!(otp_by_abi, "x86_64")
    }
  end

  defp authoritative_android_payload_plan!(dir, input) do
    unique = System.unique_integer([:positive, :monotonic])
    apk = Path.join(dir, "authoritative-plan-#{unique}.apk")
    beam_archive = Path.join(dir, "authoritative-beams-#{unique}.tar")
    File.cp!(input.apk, apk)
    File.write!(beam_archive, "exact prepared BEAM archive")
    File.chmod!(apk, 0o400)
    File.chmod!(beam_archive, 0o400)

    {MobDev.NativeBuild, beam_binary, _beam_path} = :code.get_object_code(MobDev.NativeBuild)

    beam_path = "Elixir.MobDev.NativeBuild.beam"
    attempt_id = "planbeam00000001"
    app_data = "/data/data/#{input.bundle_id}/files"

    restart_by_serial =
      input.serials
      |> Enum.with_index(9_100)
      |> Map.new(fn {serial, dist_port} ->
        suffix = String.replace(serial, ~r/[^A-Za-z0-9_]/, "_")

        {serial,
         %{
           package: input.bundle_id,
           activity: ".MainActivity",
           restart?: true,
           mode: :checked_restart,
           dist_port: dist_port,
           node_suffix: suffix
         }}
      end)

    %{
      version: 1,
      package: input.bundle_id,
      attempt_id: attempt_id,
      serials: input.serials,
      selected_abis: input.selected_abis,
      selected_abis_by_serial: input.selected_abis_by_serial,
      apk: authoritative_android_file_identity!(apk),
      beam: %{
        archive: authoritative_android_file_identity!(beam_archive),
        stage_device: "/data/local/tmp/mob_beams_#{attempt_id}.tar",
        app_stage: "#{app_data}/.mob_beams_stage_#{attempt_id}",
        app_backup: "#{app_data}/.mob_beams_backup_#{attempt_id}",
        activation_lock: "#{app_data}/.mob_beams_activation_lock",
        dist_snapshot: [
          %{
            module: MobDev.NativeBuild,
            path: beam_path,
            binary: beam_binary,
            sha256: :crypto.hash(:sha256, beam_binary)
          }
        ],
        runtime_version: System.version(),
        beam_flags: nil
      },
      exqlite: nil,
      restart_by_serial: restart_by_serial
    }
  end

  defp authoritative_android_file_identity!(path) do
    bytes = File.read!(path)

    %{
      path: path,
      size: byte_size(bytes),
      sha256: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
    }
  end

  defp cleanup_authoritative_android_plan(plan) do
    File.rm(plan.apk.path)
    File.rm(plan.beam.archive.path)

    if is_map(plan.exqlite) do
      File.rm(plan.exqlite.archive.path)
    end

    :ok
  end

  defp run_authoritative_android(
         fixture,
         dir,
         probe_runner,
         otp_runner,
         preinstall,
         cleanup
       ) do
    NativeBuild.install_and_deliver_android_runtime(
      fixture.apk,
      fixture.serials,
      fixture.package,
      fixture.elixir_lib,
      fixture.otp_arm64,
      fixture.otp_arm32,
      fixture.otp_x86_64,
      probe_runner: probe_runner,
      manifest_runner: fn "apkanalyzer", ["manifest", "application-id", _apk] ->
        {fixture.package <> "\n", 0}
      end,
      otp_runner: otp_runner,
      android_preinstall: preinstall,
      android_preinstall_cleanup: cleanup,
      tmp_root: dir,
      attempt_id: "nativeotp0000001",
      lock_owner: "ownerproof000001"
    )
  end

  defp authoritative_android_probe_runner(owner, fixture, owner_state) do
    serials = Enum.sort(fixture.serials)
    digest = :crypto.hash(:sha256, Enum.join(serials, <<0>>)) |> Base.encode16(case: :lower)
    record = "1|ownerproof000001|#{digest}|acquired"

    fn "adb", args ->
      send(owner, {:native_probe, "adb", args})

      case args do
        ["-s", _serial, "shell", "pm", "list", "packages", package]
        when package == fixture.package ->
          {"package:#{fixture.package}\n", 0}

        ["-s", _serial, "shell", "getprop", "ro.product.cpu.abi"] ->
          {"arm64-v8a\n", 0}

        ["-s", _serial, "install", "-r", _apk] ->
          {"Success\n", 0}

        ["-s", _serial, "root"] ->
          {"adbd cannot run as root in production builds", 1}

        ["-s", _serial, "shell", command] ->
          if String.contains?(command, "size=$(wc -c") and
               not String.contains?(command, "value=$(cat") do
            if Agent.get(owner_state, & &1), do: {record, 0}, else: {"replaced", 0}
          else
            {"", 0}
          end
      end
    end
  end

  defp authoritative_android_otp_runner(owner, hook \\ fn _args -> :ok end) do
    fn executable, args, opts ->
      send(owner, {:native_otp, executable, args})

      cond do
        executable in ["cp", "tar"] ->
          System.cmd(executable, args, opts)

        executable == "adb" ->
          hook.(args)
          {"", 0}
      end
    end
  end

  defp drain_native_commands(tag, commands \\ []) do
    receive do
      {^tag, executable, args} -> drain_native_commands(tag, [{executable, args} | commands])
    after
      0 -> Enum.reverse(commands)
    end
  end

  defp native_install_command?({"adb", ["-s", _serial, "install", "-r", _apk]}), do: true
  defp native_install_command?(_command), do: false

  defp native_lock_mutation_command?({"adb", ["-s", _serial, "shell", command]}) do
    String.contains?(command, ".mob_native_deploy_lock") and
      (String.contains?(command, "mkdir ") or String.contains?(command, "printf %s"))
  end

  defp native_lock_mutation_command?(_command), do: false

  describe "deprecated push_otp_runas/6" do
    test "fails before invoking an injected command runner" do
      runner = fn executable, args, _opts ->
        send(self(), {:command, executable, args})
        {"unexpected", 0}
      end

      assert %{
               ok?: true,
               android_device_disposition: :artifact_only,
               android_deploy_lock: nil,
               android_payload_plan: nil
             } = NativeBuild.build_outcome([{:ok, "Android"}])

      assert {:error, reason} =
               apply(NativeBuild, :push_otp_runas, [
                 "serial-a",
                 "com.example.casein",
                 "/data/data/com.example.casein/files",
                 "/tmp/otp",
                 "/tmp/elixir",
                 [runner: runner]
               ])

      assert reason =~ "authoritative payload transaction"
      refute_received {:command, _, _}
    end
  end

  defp native_ready_lease(serials) do
    serials = Enum.sort(serials)

    %{
      bundle_id: "com.example.casein",
      owner: "ownerproof000001",
      serials: serials,
      target_digest:
        serials
        |> Enum.join(<<0>>)
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower),
      phase: :native_ready,
      state: :held_success
    }
  end
end
