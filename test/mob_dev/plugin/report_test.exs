defmodule MobDev.Plugin.ReportTest do
  use ExUnit.Case, async: true

  alias MobDev.Plugin.Report

  @nif %{name: :mob_haptic, mob_version: "~> 0.6", plugin_spec_version: 1, nifs: []}
  @screens %{name: :mob_chat, mob_version: "~> 0.6", plugin_spec_version: 1, screens: []}

  describe "rows/2" do
    test "includes a tier-0 (no-manifest) dep only when activated" do
      deps = [{:mob_palette_demo, nil}, {:jason, nil}]

      # not activated → neither shows (both look like ordinary libs)
      assert Report.rows(deps, []) == []

      # activated → the tier-0 plugin appears, jason still doesn't
      assert [row] = Report.rows(deps, [:mob_palette_demo])
      assert row.name == :mob_palette_demo
      assert row.tier == 0
      assert row.hot_pushable == true
      assert row.status == :activated
      refute row.manifest?
    end

    test "includes a manifested dep even when not activated, marked :installed" do
      assert [row] = Report.rows([{:mob_haptic, @nif}], [])
      assert row.status == :installed
      assert row.tier == 1
      assert row.hot_pushable == false
      assert row.manifest?
    end

    test "marks a manifested dep :activated when in the list" do
      assert [row] = Report.rows([{:mob_haptic, @nif}], [:mob_haptic])
      assert row.status == :activated
    end

    test "carries tier + hot_pushable from the manifest" do
      assert [row] = Report.rows([{:mob_chat, @screens}], [:mob_chat])
      assert row.tier == 3
      assert row.hot_pushable == true
    end

    test "sorts rows by name" do
      deps = [{:mob_chat, @screens}, {:mob_haptic, @nif}]
      assert [%{name: :mob_chat}, %{name: :mob_haptic}] = Report.rows(deps, [])
    end

    test "surfaces the manifest description" do
      m = Map.put(@nif, :description, "Haptics")
      assert [%{description: "Haptics"}] = Report.rows([{:mob_haptic, m}], [])
    end
  end

  describe "render/1" do
    test "renders a friendly message when there are no plugins" do
      assert Report.render([]) =~ "No mob plugins found"
    end

    test "renders a table with the plugin, tier, and status" do
      out = Report.rows([{:mob_haptic, @nif}], [:mob_haptic]) |> Report.render()
      assert out =~ "mob_haptic"
      assert out =~ "tier 1"
      assert out =~ "activated"
    end

    test "flags a tier-0 activated plugin as a no-manifest regular dep" do
      out = Report.rows([{:mob_palette_demo, nil}], [:mob_palette_demo]) |> Report.render()
      assert out =~ "no manifest (regular dep)"
    end

    test "explains the installed-but-not-activated state when present" do
      out = Report.rows([{:mob_haptic, @nif}], []) |> Report.render()
      assert out =~ "not activated"
    end

    test "omits the VETTING column when no row carries vetting" do
      out = Report.rows([{:mob_haptic, @nif}], [:mob_haptic]) |> Report.render()
      refute out =~ "VETTING"
    end

    test "adds the VETTING column and renders 'clean' for a spotless row" do
      rows = [
        %{
          name: :mob_palette_demo,
          tier: 0,
          hot_pushable: true,
          status: :activated,
          manifest?: true,
          description: nil,
          vetting: %{
            audit: %{high: 0, medium: 0, low: 0},
            capability_errors: 0
          }
        }
      ]

      out = Report.render(rows)
      assert out =~ "VETTING"
      assert out =~ "clean"
    end

    test "renders capability error count when present" do
      rows = [
        %{
          name: :leaky_plugin,
          tier: 2,
          hot_pushable: false,
          status: :activated,
          manifest?: true,
          description: nil,
          vetting: %{
            audit: %{high: 0, medium: 0, low: 0},
            capability_errors: 2
          }
        }
      ]

      assert Report.render(rows) =~ "caps:2"
    end

    test "renders compact audit summary, omitting zero categories" do
      rows = [
        %{
          name: :risky_plugin,
          tier: 1,
          hot_pushable: false,
          status: :activated,
          manifest?: true,
          description: nil,
          vetting: %{
            audit: %{high: 1, medium: 2, low: 0},
            capability_errors: 0
          }
        }
      ]

      out = Report.render(rows)
      assert out =~ "1H"
      assert out =~ "2M"
      refute out =~ "0L"
    end
  end
end
