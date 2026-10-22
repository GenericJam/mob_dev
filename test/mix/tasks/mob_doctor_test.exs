defmodule Mix.Tasks.Mob.DoctorTest do
  use ExUnit.Case, async: true

  describe "__zig_install_fix__/0" do
    test "pins the exact application-build Zig version" do
      fix = Mix.Tasks.Mob.Doctor.__zig_install_fix__()

      assert fix =~ MobDev.Toolchain.required_zig_version()
      refute fix =~ "zig 0.15"
      refute fix =~ "ziglang.org/download"
    end
  end

  describe "__zig_check_result__/1" do
    test "accepts only the exact version" do
      version = MobDev.Toolchain.required_zig_version()

      assert {:ok, "zig", ^version, nil} =
               Mix.Tasks.Mob.Doctor.__zig_check_result__({:ok, version})
    end

    test "fails an installed 0.15.x version" do
      assert {:fail, "zig", detail, fix} =
               Mix.Tasks.Mob.Doctor.__zig_check_result__({:version_mismatch, "0.15.2"})

      assert detail =~ "0.15.2"
      assert fix =~ MobDev.Toolchain.required_zig_version()
    end

    test "fails another nightly" do
      assert {:fail, "zig", detail, _fix} =
               Mix.Tasks.Mob.Doctor.__zig_check_result__(
                 {:version_mismatch, "0.17.0-dev.270+different"}
               )

      assert detail =~ "0.17.0-dev.270+different"
    end

    test "fails when `zig version` fails" do
      assert {:fail, "zig", detail, _fix} =
               Mix.Tasks.Mob.Doctor.__zig_check_result__(
                 {:version_command_failed, "dyld failure", 127}
               )

      assert detail =~ "exited 127"
      assert detail =~ "dyld failure"
    end
  end

  describe "__inactive_nif_plugins_check__/2 (MOB-281)" do
    test "no row when every NIF plugin is activated" do
      assert Mix.Tasks.Mob.Doctor.__inactive_nif_plugins_check__([], [:mob_scanner]) == []
    end

    test "warns, naming the plugin and the config line to set" do
      assert [{:warn, "plugin activation", detail, fix}] =
               Mix.Tasks.Mob.Doctor.__inactive_nif_plugins_check__([:mob_scanner], [:mob_camera])

      assert detail =~ "not activated, though they ship NIFs: mob_scanner"
      assert fix =~ "config :mob, :plugins, [:mob_camera, :mob_scanner]"
    end
  end

  describe "__missing_plugin_options__/2 (pre-plugin build.zig detection)" do
    # The real declaration shape every template uses.
    @declared """
    const plugin_c_nifs = b.option([]const u8, "plugin_c_nifs", "...") orelse "";
    const plugin_zig_nifs = b.option([]const u8, "plugin_zig_nifs", "...") orelse "";
    const plugin_jni_sources = b.option([]const u8, "plugin_jni_sources", "...") orelse "";
    """

    test "a plugin-aware build file is missing nothing" do
      assert Mix.Tasks.Mob.Doctor.__missing_plugin_options__(
               @declared,
               ~w(plugin_c_nifs plugin_zig_nifs plugin_jni_sources)
             ) == []
    end

    test "a pre-plugin build file is missing every option" do
      pre_plugin = """
      const driver_tab = b.option([]const u8, "driver_tab", "...") orelse "";
      """

      assert Mix.Tasks.Mob.Doctor.__missing_plugin_options__(
               pre_plugin,
               ~w(plugin_c_nifs plugin_zig_nifs plugin_jni_sources)
             ) == ~w(plugin_c_nifs plugin_zig_nifs plugin_jni_sources)
    end

    test "a partially upgraded build file reports only the absent options" do
      partial = """
      const plugin_c_nifs = b.option([]const u8, "plugin_c_nifs", "...") orelse "";
      """

      assert Mix.Tasks.Mob.Doctor.__missing_plugin_options__(
               partial,
               ~w(plugin_c_nifs plugin_zig_nifs plugin_jni_sources)
             ) == ~w(plugin_zig_nifs plugin_jni_sources)
    end

    test "an unquoted mention (a comment) does not count as declared" do
      comment_only = "// TODO: add plugin_c_nifs support"

      assert Mix.Tasks.Mob.Doctor.__missing_plugin_options__(comment_only, ["plugin_c_nifs"]) ==
               ["plugin_c_nifs"]
    end
  end

  describe "__ios_build_root_stale__/1" do
    test "flags the 0.17-dev glob that calls b.build_root" do
      stale = """
      var mob_ios = b.build_root.handle.openDir(glob_io, b.fmt("{s}/ios", .{mob_dir}), .{ .iterate = true }) catch @panic("mob ios dir not found");
      """

      assert Mix.Tasks.Mob.Doctor.__ios_build_root_stale__(stale)
    end

    test "does not flag the 0.17.0 glob" do
      fixed = """
      var mob_ios = std.Io.Dir.openDirAbsolute(glob_io, b.fmt("{s}/ios", .{mob_dir}), .{ .iterate = true }) catch @panic("mob ios dir not found");
      """

      refute Mix.Tasks.Mob.Doctor.__ios_build_root_stale__(fixed)
    end

    test "does not flag a migration comment that names the old field" do
      migrated = """
      // Replaced b.build_root.handle.openDir with std.Io.Dir.openDirAbsolute.
      var mob_ios = std.Io.Dir.openDirAbsolute(glob_io, b.fmt("{s}/ios", .{mob_dir}), .{ .iterate = true }) catch @panic("mob ios dir not found");
      """

      refute Mix.Tasks.Mob.Doctor.__ios_build_root_stale__(migrated)
    end
  end

  describe "__component_event_jni_mismatched__/1 (MOB-98 JNI owner check)" do
    test "flags the pre-fix declaration (bare external fun, no @JvmStatic)" do
      pre_fix = """
      object MobNativeViewRegistry {
          external fun nativeDeliverComponentEvent(handle: Int, event: String, payloadJson: String)
      }
      """

      assert Mix.Tasks.Mob.Doctor.__component_event_jni_mismatched__(pre_fix)
    end

    test "does not flag the corrected declaration (@JvmStatic, owned by MobBridge)" do
      fixed = """
      object MobBridge {
          @JvmStatic external fun nativeDeliverComponentEvent(handle: Int, event: String, payloadJson: String)
      }
      """

      refute Mix.Tasks.Mob.Doctor.__component_event_jni_mismatched__(fixed)
    end

    test "does not flag a file that doesn't declare the callback at all" do
      refute Mix.Tasks.Mob.Doctor.__component_event_jni_mismatched__("object MobBridge {}")
    end

    test "does not flag @JvmStatic on its own line above external fun (idiomatic Kotlin)" do
      # mix mob.doctor only warns — it never re-checks a hand-applied fix, so
      # a false positive here would tell a dev "still broken" forever even
      # after they correctly ported it in the idiomatic two-line style.
      fixed = """
      object MobBridge {
          @JvmStatic
          external fun nativeDeliverComponentEvent(handle: Int, event: String, payloadJson: String)
      }
      """

      refute Mix.Tasks.Mob.Doctor.__component_event_jni_mismatched__(fixed)
    end
  end

  describe "__sheet_dismiss_wire_shape_stale__/1 (MOB-104 dismissal wire shape)" do
    test "flags a sheet renderer that still dismisses through nativeSendTap" do
      pre_fix = """
      object MobBridge {
          @JvmStatic external fun nativeSendTap(handle: Int)
      }

      @Composable
      private fun MobSheet(node: MobNode) {
          fun sendDismissOnce() {
              dismissHandle?.let { MobBridge.nativeSendTap(it) }
          }
      }
      """

      assert Mix.Tasks.Mob.Doctor.__sheet_dismiss_wire_shape_stale__(pre_fix)
    end

    test "does not flag once nativeSendDismiss has been ported in" do
      fixed = """
      object MobBridge {
          @JvmStatic external fun nativeSendTap(handle: Int)
          @JvmStatic external fun nativeSendDismiss(handle: Int)
      }

      @Composable
      private fun MobSheet(node: MobNode) {
          fun sendDismissOnce() {
              dismissHandle?.let { MobBridge.nativeSendDismiss(it) }
          }
      }
      """

      refute Mix.Tasks.Mob.Doctor.__sheet_dismiss_wire_shape_stale__(fixed)
    end

    test "does not flag @JvmStatic split across lines (idiomatic Kotlin)" do
      # Same trap the MOB-98 kernel fell into: doctor only warns and never
      # re-checks, so a false positive tells a dev "still broken" forever.
      fixed = """
      object MobBridge {
          @JvmStatic
          external fun nativeSendDismiss(handle: Int)
      }

      private fun MobSheet(node: MobNode) {}
      """

      refute Mix.Tasks.Mob.Doctor.__sheet_dismiss_wire_shape_stale__(fixed)
    end

    test "does not flag an app generated before Mob.UI.sheet/2 existed" do
      # No MobSheet means no sheet support to be wrong about — warning here
      # would be pure noise on every pre-0.4.24 project.
      no_sheets = """
      object MobBridge {
          @JvmStatic external fun nativeSendTap(handle: Int)
      }
      """

      refute Mix.Tasks.Mob.Doctor.__sheet_dismiss_wire_shape_stale__(no_sheets)
    end

    test "tolerates whitespace variation in the MobSheet signature" do
      pre_fix = """
      object MobBridge { @JvmStatic external fun nativeSendTap(handle: Int) }
      private fun MobSheet (node: MobNode) {}
      """

      assert Mix.Tasks.Mob.Doctor.__sheet_dismiss_wire_shape_stale__(pre_fix)
    end
  end

  describe "__startup_status_hooks_missing__/1 (Android boot status)" do
    test "reports both methods for a MobBridge that predates them" do
      pre_fix = """
      object MobBridge {
          @JvmStatic
          fun setTheme(json: String) {}
      }
      """

      assert Mix.Tasks.Mob.Doctor.__startup_status_hooks_missing__(pre_fix) ==
               ["setStartupPhase", "setStartupError"]
    end

    test "reports only the one still missing from a partial port" do
      partial = """
      object MobBridge {
          @JvmStatic fun setStartupPhase(phase: String) {}
      }
      """

      assert Mix.Tasks.Mob.Doctor.__startup_status_hooks_missing__(partial) == ["setStartupError"]
    end

    test "reports nothing once both are ported, @JvmStatic on its own line" do
      fixed = """
      object MobBridge {
          @JvmStatic
          fun setStartupPhase(phase: String) {}

          @JvmStatic
          public fun setStartupError(error: String) {}
      }
      """

      assert Mix.Tasks.Mob.Doctor.__startup_status_hooks_missing__(fixed) == []
    end

    test "reports a port missing @JvmStatic, which GetStaticMethodID can't find" do
      instance_only = """
      object MobBridge {
          fun setStartupPhase(phase: String) {}
          @JvmStatic fun  setStartupError (error: String) {}
      }
      """

      assert Mix.Tasks.Mob.Doctor.__startup_status_hooks_missing__(instance_only) ==
               ["setStartupPhase"]
    end
  end

  describe "__kotlin_gradle_plugin_rows__/1 (MOB-497 CVE-2026-53914)" do
    @tag :tmp_dir
    test "warns, naming the file and version, for a pre-migration mob_new app", %{
      tmp_dir: root
    } do
      write!(root, "android/build.gradle", """
      buildscript {
          dependencies {
              classpath 'com.android.tools.build:gradle:8.2.0'
              classpath 'org.jetbrains.kotlin:kotlin-gradle-plugin:1.9.22'
          }
      }
      """)

      assert [{:warn, "Kotlin Gradle plugin (android/build.gradle)", problem, _fix}] =
               Mix.Tasks.Mob.Doctor.__kotlin_gradle_plugin_rows__(root)

      assert problem =~ "1.9.22"
      assert problem =~ "CVE-2026-53914"
    end

    @tag :tmp_dir
    test "is silent for the migrated template", %{tmp_dir: root} do
      write!(root, "android/build.gradle", """
      buildscript {
          dependencies {
              classpath 'com.android.tools.build:gradle:9.3.3'
              classpath 'org.jetbrains.kotlin:kotlin-gradle-plugin:2.4.21'
              classpath 'org.jetbrains.kotlin:compose-compiler-gradle-plugin:2.4.21'
          }
      }
      """)

      assert Mix.Tasks.Mob.Doctor.__kotlin_gradle_plugin_rows__(root) == []
    end

    @tag :tmp_dir
    test "warns when AGP 9's built-in Kotlin is left on its own KGP", %{tmp_dir: root} do
      write!(root, "android/build.gradle", """
      buildscript { dependencies { classpath 'com.android.tools.build:gradle:9.3.3' } }
      """)

      assert [{:warn, "Kotlin Gradle plugin (android/build.gradle)", problem, _fix}] =
               Mix.Tasks.Mob.Doctor.__kotlin_gradle_plugin_rows__(root)

      assert problem =~ "2.2.10"
    end

    @tag :tmp_dir
    test "is silent when there is no Android project", %{tmp_dir: root} do
      assert Mix.Tasks.Mob.Doctor.__kotlin_gradle_plugin_rows__(root) == []
    end
  end

  defp write!(root, rel, content) do
    path = Path.join(root, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end
end
