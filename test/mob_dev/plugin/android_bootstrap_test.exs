defmodule MobDev.Plugin.AndroidBootstrapTest do
  use ExUnit.Case, async: true

  alias MobDev.Plugin.AndroidBootstrap

  defp base(extra),
    do: Map.merge(%{name: :p, mob_version: "~> 0.6", plugin_spec_version: 1}, extra)

  defp auto_registered_manifest do
    base(%{
      name: :mob_scene3d,
      ui_components: [
        %{
          tag: "Scene3d",
          atom: :scene3d,
          ios: %{view_module: "Mob_Scene3d_Viewport", swift_struct: "MobScene3dViewport"},
          android: %{
            composable: "Mob_Scene3d_Viewport",
            factory: "MobScene3dViewport"
          }
        }
      ],
      android: %{bridge_class: "io.mob.scene3d.MobScene3dBridge"}
    })
  end

  describe "classify/1" do
    test "preserves legacy composable registry keys without auto-registering them" do
      manifest =
        base(%{
          ui_components: [
            %{
              atom: :button,
              android: %{composable: "ClarityUI_Components_Button_Native"}
            }
          ],
          android: %{bridge_class: "io.example.ui.Plugin"}
        })

      assert AndroidBootstrap.classify([{"/a", manifest}]) ==
               %{registrations: [], errors: []}
    end

    test "qualifies an opted-in bare factory with the bridge_class package" do
      %{registrations: [reg], errors: []} =
        AndroidBootstrap.classify([{"/a", auto_registered_manifest()}])

      assert reg == %{
               key: "Mob_Scene3d_Viewport",
               factory: "io.mob.scene3d.MobScene3dViewport",
               plugin: :mob_scene3d
             }
    end

    test "uses a fully-qualified factory as-is without a bridge_class" do
      manifest =
        base(%{
          ui_components: [
            %{
              atom: :chart,
              android: %{
                composable: "Mob_Chart",
                factory: "io.mob.chart.MobChart"
              }
            }
          ]
        })

      %{registrations: [reg], errors: []} =
        AndroidBootstrap.classify([{"/a", manifest}])

      assert reg.factory == "io.mob.chart.MobChart"
    end

    test "composable remains authoritative when view_module is also present" do
      manifest =
        base(%{
          ui_components: [
            %{
              atom: :chart,
              android: %{
                view_module: "Android_Key",
                composable: "Legacy_Key",
                factory: "io.mob.chart.MobChart"
              }
            }
          ]
        })

      %{registrations: [reg]} = AndroidBootstrap.classify([{"/a", manifest}])
      assert reg.key == "Legacy_Key"
    end

    test "falls back to ios.view_module when composable is absent" do
      manifest =
        base(%{
          ui_components: [
            %{
              atom: :chart,
              ios: %{view_module: "Shared_Key"},
              android: %{factory: "io.mob.chart.MobChart"}
            }
          ]
        })

      %{registrations: [reg]} = AndroidBootstrap.classify([{"/a", manifest}])
      assert reg.key == "Shared_Key"
    end

    test "opted-in factory without a registry key is a build error" do
      manifest =
        base(%{ui_components: [%{atom: :pad, android: %{factory: "io.mob.MobPad"}}]})

      %{registrations: [], errors: [err]} = AndroidBootstrap.classify([{"/a", manifest}])

      assert err =~ ":pad"
      assert err =~ "no registry key"
    end

    test "bare opted-in factory without a bridge_class is a build error" do
      manifest =
        base(%{
          ui_components: [
            %{atom: :pad, android: %{composable: "MobPad_View", factory: "MobPad"}}
          ]
        })

      %{registrations: [], errors: [err]} = AndroidBootstrap.classify([{"/a", manifest}])

      assert err =~ "MobPad"
      assert err =~ "fully qualified"
    end

    test "present but invalid factory values are build errors" do
      for factory <- [:Bad, nil, 42] do
        manifest =
          base(%{
            ui_components: [
              %{atom: :pad, android: %{composable: "MobPad_View", factory: factory}}
            ]
          })

        %{registrations: [], errors: [err]} =
          AndroidBootstrap.classify([{"/a", manifest}])

        assert err =~ "android.factory"
        assert err =~ inspect(factory)
      end
    end

    test "iOS-only components and tier-0 plugins contribute nothing" do
      plugins = [
        {"/zero", nil},
        {"/ios_only",
         base(%{ui_components: [%{atom: :x, ios: %{view_module: "X", swift_struct: "XV"}}]})}
      ]

      assert AndroidBootstrap.classify(plugins) == %{registrations: [], errors: []}
    end

    test "preserves activation and declaration order" do
      plugins = [
        {"/a",
         base(%{
           name: :a,
           ui_components: [
             %{atom: :a1, android: %{composable: "A1", factory: "x.A1"}},
             %{atom: :a2, android: %{composable: "A2", factory: "x.A2"}}
           ]
         })},
        {"/b",
         base(%{
           name: :b,
           ui_components: [%{atom: :b1, android: %{composable: "B1", factory: "x.B1"}}]
         })}
      ]

      %{registrations: regs} = AndroidBootstrap.classify(plugins)
      assert Enum.map(regs, & &1.key) == ["A1", "A2", "B1"]
    end
  end

  describe "ui_source/2" do
    test "nothing to register yields nil" do
      assert AndroidBootstrap.ui_source(%{registrations: [], errors: []}, "com.example.app") ==
               nil
    end

    test "forwards props and the native event sender to an opted-in factory" do
      classified = AndroidBootstrap.classify([{"/a", auto_registered_manifest()}])
      %{call: call, body: body} = AndroidBootstrap.ui_source(classified, "com.example.app")

      assert call == "registerUiComponents()"

      assert body =~
               ~s|com.example.app.MobNativeViewRegistry.register("Mob_Scene3d_Viewport") { props, send ->|

      assert body =~ "io.mob.scene3d.MobScene3dViewport(props, send)"
    end
  end
end
