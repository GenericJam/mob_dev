defmodule Mix.Tasks.Mob.DoctorTest do
  use ExUnit.Case, async: true

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
end
