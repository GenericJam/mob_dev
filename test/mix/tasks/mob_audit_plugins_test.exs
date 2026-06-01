defmodule Mix.Tasks.Mob.AuditPluginsTest do
  use ExUnit.Case, async: true

  alias MobDev.Plugin.{Audit, Report}

  @demo_root "/Users/kevin/code/mob_plugin_demo/plugins"

  describe "Phase 1 prototypes — well-behaved plugins" do
    @describetag :phase1_prototypes

    test "mob_palette_demo (tier 0) produces zero findings" do
      dir = Path.join(@demo_root, "mob_palette_demo")

      if File.exists?(dir) do
        assert %{findings: []} = Audit.audit_plugin(dir, %{name: :mob_palette_demo})
      else
        :ok
      end
    end

    test "mob_demo_haptic_extras (tier 1 with C NIF) produces zero findings" do
      dir = Path.join(@demo_root, "mob_demo_haptic_extras")

      if File.exists?(dir) do
        report = Audit.audit_plugin(dir, %{name: :mob_demo_haptic_extras})

        assert report.findings == [],
               "expected zero findings for the well-behaved haptic_extras plugin, got: " <>
                 inspect(report.findings, pretty: true)
      else
        :ok
      end
    end

    test "mob_demo_signature_pad (tier 2 with Kotlin/Swift) produces zero Elixir/C findings" do
      dir = Path.join(@demo_root, "mob_demo_signature_pad")

      if File.exists?(dir) do
        report = Audit.audit_plugin(dir, %{name: :mob_demo_signature_pad})
        assert report.findings == []
        assert report.kotlin_or_swift_skipped == true
      else
        :ok
      end
    end

    test "audit + render_audit on all three prototypes prints a clean roll-up" do
      paths = [
        {"mob_palette_demo", :mob_palette_demo},
        {"mob_demo_haptic_extras", :mob_demo_haptic_extras},
        {"mob_demo_signature_pad", :mob_demo_signature_pad}
      ]

      reports =
        for {sub, name} <- paths,
            dir = Path.join(@demo_root, sub),
            File.exists?(dir) do
          Audit.audit_plugin(dir, %{name: name})
        end

      if reports == [] do
        :ok
      else
        output = Report.render_audit(reports)
        IO.puts("\n--- mix mob.audit_plugins (Phase 1 prototypes) ---\n" <> output)

        # Spot-check shape
        assert output =~ "Audit summary"
        assert output =~ "scanned"

        for {_sub, name} <- paths do
          if Enum.any?(reports, &(&1.plugin == name)) do
            assert output =~ to_string(name)
          end
        end

        # Every prototype should be clean.
        assert Audit.exit_code(reports) == 0
      end
    end
  end

  describe "audit_all/1 + activated_plugins/0" do
    test "audit_all/1 returns [] when no plugins are activated" do
      # No mob.exs in the mob_dev project itself, and no :mob :plugins env set
      # — activated_plugins/0 yields [], so audit_all/1 yields [].
      original = Application.get_env(:mob, :plugins, [])
      Application.put_env(:mob, :plugins, [])

      try do
        assert Mix.Tasks.Mob.AuditPlugins.audit_all() == []
      after
        Application.put_env(:mob, :plugins, original)
      end
    end
  end

  describe "render_audit/1 — visual style" do
    test "renders a finding line with rule, location, snippet, and hint" do
      report = %{
        plugin: :evil_plugin,
        findings: [
          %{
            severity: :high,
            rule: :code_eval,
            plugin: :evil_plugin,
            file: "lib/evil.ex",
            line: 7,
            snippet: "Code.eval_string(...)",
            hint: "Arbitrary code execution. Remove this call or justify it in the manifest."
          }
        ],
        summary: %{high: 1, medium: 0, low: 0},
        kotlin_or_swift_skipped: false
      }

      out = Report.render_audit([report])

      assert out =~ "evil_plugin"
      assert out =~ "HIGH"
      assert out =~ "code_eval"
      assert out =~ "lib/evil.ex:7"
      assert out =~ "Code.eval_string"
      assert out =~ "Arbitrary code execution"
      assert out =~ "1 high"
    end

    test "renders a 'no findings' line for clean plugins" do
      report = %{
        plugin: :clean,
        findings: [],
        summary: %{high: 0, medium: 0, low: 0},
        kotlin_or_swift_skipped: false
      }

      out = Report.render_audit([report])
      assert out =~ "clean — no findings"
    end

    test "mentions the Kotlin/Swift skip when applicable" do
      report = %{
        plugin: :tier2,
        findings: [],
        summary: %{high: 0, medium: 0, low: 0},
        kotlin_or_swift_skipped: true
      }

      out = Report.render_audit([report])
      assert out =~ "Kotlin/Swift sources present but not yet audited"
    end

    test "render_audit/1 with no reports prints a friendly empty message" do
      assert Report.render_audit([]) =~ "No plugins audited"
    end
  end
end
