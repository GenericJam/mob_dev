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
end
