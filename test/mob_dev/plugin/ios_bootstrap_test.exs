defmodule MobDev.Plugin.IOSBootstrapTest do
  use ExUnit.Case, async: true

  alias MobDev.Plugin.IOSBootstrap

  defp base(extra),
    do: Map.merge(%{name: :p, mob_version: "~> 0.6", plugin_spec_version: 1}, extra)

  defp signature_pad_component do
    %{
      tag: "SignaturePad",
      atom: :signature_pad,
      props: [:bg_color, :corner_radius],
      ios: %{view_module: "MobDemoSignaturePad_View", swift_struct: "MobSignaturePadView"},
      android: %{composable: "MobDemoSignaturePad_View"}
    }
  end

  describe "swift_source/1" do
    test "emits the cdecl entry point even with no plugins" do
      src = IOSBootstrap.swift_source([])

      assert src =~ "@_cdecl(\"mob_register_plugins\")"
      assert src =~ "public func mob_register_plugins()"
      assert src =~ "import SwiftUI"
      refute src =~ "MobNativeViewRegistry.shared.register"
    end

    test "emits the cdecl entry point with no plugins (function body is empty)" do
      src = IOSBootstrap.swift_source([{"/a", nil}])

      assert src =~ "public func mob_register_plugins() {"
      refute src =~ "register("
    end

    test "emits one register call per ui_components entry" do
      plugins = [{"/a", base(%{ui_components: [signature_pad_component()]})}]
      src = IOSBootstrap.swift_source(plugins)

      assert src =~ ~s|MobNativeViewRegistry.shared.register("MobDemoSignaturePad_View")|
      assert src =~ "AnyView(MobSignaturePadView(props: props))"
    end

    test "preserves order across plugins (activation order, then declaration order)" do
      plugins = [
        {"/a",
         base(%{
           ui_components: [
             %{ios: %{view_module: "A_View", swift_struct: "AView"}},
             %{ios: %{view_module: "B_View", swift_struct: "BView"}}
           ]
         })},
        {"/b", base(%{ui_components: [%{ios: %{view_module: "C_View", swift_struct: "CView"}}]})}
      ]

      src = IOSBootstrap.swift_source(plugins)

      a_pos = :binary.match(src, "A_View") |> elem(0)
      b_pos = :binary.match(src, "B_View") |> elem(0)
      c_pos = :binary.match(src, "C_View") |> elem(0)

      assert a_pos < b_pos
      assert b_pos < c_pos
    end

    test "drops components missing :swift_struct (validator is what nags)" do
      plugins = [
        {"/a",
         base(%{
           ui_components: [
             # Missing :swift_struct — should be silently skipped here.
             %{ios: %{view_module: "Old_View"}},
             %{ios: %{view_module: "New_View", swift_struct: "NewView"}}
           ]
         })}
      ]

      src = IOSBootstrap.swift_source(plugins)

      refute src =~ "Old_View"
      assert src =~ "New_View"
      assert src =~ "NewView(props: props)"
    end

    test "drops components missing :view_module (no registry key — nothing to register)" do
      plugins = [
        {"/a",
         base(%{
           ui_components: [%{ios: %{swift_struct: "DangleView"}}]
         })}
      ]

      assert IOSBootstrap.swift_source(plugins) |> String.match?(~r/DangleView/) == false
    end

    test "ignores tier-0 (nil-manifest) plugins" do
      plugins = [
        {"/a", nil},
        {"/b", base(%{ui_components: [signature_pad_component()]})}
      ]

      src = IOSBootstrap.swift_source(plugins)
      assert src =~ "MobDemoSignaturePad_View"
    end

    test "emits a single cdecl entry even when multiple components are registered" do
      plugins = [
        {"/a",
         base(%{
           ui_components: [
             %{ios: %{view_module: "X_View", swift_struct: "XView"}},
             %{ios: %{view_module: "Y_View", swift_struct: "YView"}}
           ]
         })}
      ]

      src = IOSBootstrap.swift_source(plugins)

      cdecl_count =
        src
        |> String.split("@_cdecl(\"mob_register_plugins\")")
        |> length()
        |> Kernel.-(1)

      assert cdecl_count == 1
    end

    test "header annotates the file as auto-generated" do
      src = IOSBootstrap.swift_source([])
      assert src =~ "Auto-generated"
      assert src =~ "MobDev.Plugin.IOSBootstrap"
    end
  end
end
