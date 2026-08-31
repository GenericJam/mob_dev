defmodule MobDev.Plugin.AndroidBootstrapTest do
  use ExUnit.Case, async: true

  alias MobDev.Plugin.AndroidBootstrap

  defp base(extra),
    do: Map.merge(%{name: :p, mob_version: "~> 0.6", plugin_spec_version: 1}, extra)

  # mob_scene3d's real shape: bare composable + bridge_class in the same
  # package, registry key on the iOS side only (mob_scene3d-q03 repro).
  defp scene3d_manifest do
    base(%{
      name: :mob_scene3d,
      ui_components: [
        %{
          tag: "Scene3d",
          atom: :scene3d,
          ios: %{view_module: "Mob_Scene3d_Viewport", swift_struct: "MobScene3dViewport"},
          android: %{composable: "MobScene3dViewport"}
        }
      ],
      android: %{bridge_class: "io.mob.scene3d.MobScene3dBridge"}
    })
  end

  describe "classify/1" do
    test "qualifies a bare composable with the bridge_class package" do
      %{registrations: [reg], placeholders: [], errors: []} =
        AndroidBootstrap.classify([{"/a", scene3d_manifest()}])

      assert reg == %{
               key: "Mob_Scene3d_Viewport",
               composable: "io.mob.scene3d.MobScene3dViewport",
               plugin: :mob_scene3d
             }
    end

    test "uses a fully-qualified composable as-is (no bridge_class needed)" do
      manifest =
        base(%{
          ui_components: [
            %{
              atom: :chart,
              ios: %{view_module: "Mob_Chart"},
              android: %{composable: "io.mob.chart.MobChart"}
            }
          ]
        })

      %{registrations: [reg], placeholders: [], errors: []} =
        AndroidBootstrap.classify([{"/a", manifest}])

      assert reg.composable == "io.mob.chart.MobChart"
    end

    test "android.view_module wins over ios.view_module as the registry key" do
      manifest =
        base(%{
          ui_components: [
            %{
              atom: :chart,
              ios: %{view_module: "Ios_Key"},
              android: %{view_module: "Android_Key", composable: "io.mob.chart.MobChart"}
            }
          ]
        })

      %{registrations: [reg]} = AndroidBootstrap.classify([{"/a", manifest}])
      assert reg.key == "Android_Key"
    end

    test "bare composable without a bridge_class becomes a loud placeholder" do
      # The hand-copied tier-2 workflow: the manifest can't tell codegen where
      # the composable lives, so the host registers it by hand — and gets a
      # loud placeholder (not silence) if it forgets.
      manifest =
        base(%{
          ui_components: [
            %{
              atom: :pad,
              ios: %{view_module: "MobPad_View", swift_struct: "MobPadView"},
              android: %{composable: "MobPadComposable"}
            }
          ]
        })

      %{registrations: [], placeholders: [ph], errors: []} =
        AndroidBootstrap.classify([{"/a", manifest}])

      assert ph == %{key: "MobPad_View", plugin: :p}
    end

    test "android backing without any registry key is a build error" do
      manifest =
        base(%{ui_components: [%{atom: :pad, android: %{composable: "MobPad"}}]})

      %{registrations: [], placeholders: [], errors: [err]} =
        AndroidBootstrap.classify([{"/a", manifest}])

      assert err =~ ":pad"
      assert err =~ "no registry key"
      assert err =~ "android.view_module"
    end

    test "android backing without a composable is a build error" do
      manifest =
        base(%{ui_components: [%{atom: :pad, ios: %{view_module: "K"}, android: %{}}]})

      %{errors: [err]} = AndroidBootstrap.classify([{"/a", manifest}])
      assert err =~ "no :composable"
    end

    test "iOS-only components and tier-0 (nil-manifest) plugins contribute nothing" do
      plugins = [
        {"/zero", nil},
        {"/ios_only",
         base(%{ui_components: [%{atom: :x, ios: %{view_module: "X", swift_struct: "XV"}}]})}
      ]

      assert AndroidBootstrap.classify(plugins) ==
               %{registrations: [], placeholders: [], errors: []}
    end

    test "preserves order across plugins (activation order, then declaration order)" do
      plugins = [
        {"/a",
         base(%{
           name: :a,
           ui_components: [
             %{atom: :a1, android: %{view_module: "A1", composable: "x.A1"}},
             %{atom: :a2, android: %{view_module: "A2", composable: "x.A2"}}
           ]
         })},
        {"/b",
         base(%{
           name: :b,
           ui_components: [%{atom: :b1, android: %{view_module: "B1", composable: "x.B1"}}]
         })}
      ]

      %{registrations: regs} = AndroidBootstrap.classify(plugins)
      assert Enum.map(regs, & &1.key) == ["A1", "A2", "B1"]
    end
  end

  describe "ui_source/2" do
    test "nothing to register yields nil (bootstrap stays byte-identical)" do
      assert AndroidBootstrap.ui_source(
               %{registrations: [], placeholders: [], errors: []},
               "com.example.app"
             ) == nil
    end

    test "emits a fully-qualified register call per registration" do
      classified = AndroidBootstrap.classify([{"/a", scene3d_manifest()}])
      %{call: call, body: body} = AndroidBootstrap.ui_source(classified, "com.example.app")

      assert call == "registerUiComponents()"
      assert body =~ "private fun registerUiComponents()"

      assert body =~
               ~s|com.example.app.MobNativeViewRegistry.register("Mob_Scene3d_Viewport") { props, _ ->|

      assert body =~ "io.mob.scene3d.MobScene3dViewport(props)"
      # No placeholders declared — the loud-placeholder composable is not emitted.
      refute body =~ "MissingUiComponent"
    end

    test "emits the loud placeholder for unresolvable declared components" do
      classified = %{
        registrations: [],
        placeholders: [%{key: "MobPad_View", plugin: :pad_plugin}],
        errors: []
      }

      %{body: body} = AndroidBootstrap.ui_source(classified, "com.example.app")

      assert body =~
               ~s|com.example.app.MobNativeViewRegistry.register("MobPad_View") { _, _ ->|

      assert body =~ ~s|MissingUiComponent("MobPad_View", "pad_plugin")|
      assert body =~ "@androidx.compose.runtime.Composable"
      assert body =~ "private fun MissingUiComponent(key: String, plugin: String)"
      assert body =~ "android.util.Log.e"
      assert body =~ "androidx.compose.material3.Text"
      assert body =~ "androidx.compose.ui.graphics.Color.Red"
    end
  end
end
