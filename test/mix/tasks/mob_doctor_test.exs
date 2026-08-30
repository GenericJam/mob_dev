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
end
