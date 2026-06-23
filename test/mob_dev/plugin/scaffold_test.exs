defmodule MobDev.Plugin.ScaffoldTest do
  use ExUnit.Case, async: true

  alias MobDev.Plugin.{Scaffold, Manifest, Validator}

  describe "module_name/1" do
    test "converts snake_case to PascalCase" do
      assert Scaffold.module_name("mob_demo_widget") == "MobDemoWidget"
      assert Scaffold.module_name("widget") == "Widget"
      assert Scaffold.module_name("mob_x") == "MobX"
    end
  end

  describe "validate_name/1" do
    test "accepts snake_case identifiers" do
      assert Scaffold.validate_name("mob_demo_widget") == :ok
      assert Scaffold.validate_name("widget") == :ok
      assert Scaffold.validate_name("plugin_with_123") == :ok
    end

    test "rejects empty / non-string / wrong shape" do
      assert {:error, _} = Scaffold.validate_name("")
      assert {:error, _} = Scaffold.validate_name(:atom)
      assert {:error, _} = Scaffold.validate_name("BadName")
      assert {:error, _} = Scaffold.validate_name("1leading_digit")
      assert {:error, _} = Scaffold.validate_name("with-dash")
      assert {:error, _} = Scaffold.validate_name("with space")
    end

    test "rejects special atoms that build a no-app project (nil/true/false)" do
      # `app: :nil`/`:false` make `mix compile` die with "Cannot access build
      # without an application name"; `:true` builds a boolean-named app. These
      # pass the snake_case regex but produce a broken plugin.
      for name <- ["nil", "true", "false"] do
        assert {:error, msg} = Scaffold.validate_name(name)
        assert msg =~ "reserved word"
      end
    end

    test "rejects Elixir reserved words (mirrors mix new)" do
      for name <- ["when", "fn", "def", "import", "case", "receive"] do
        assert {:error, _} = Scaffold.validate_name(name)
      end
    end
  end

  describe "validate_tier/1" do
    test "0 through 4 are valid" do
      for t <- [0, 1, 2, 3, 4], do: assert(Scaffold.validate_tier(t) == :ok)
    end

    test "other tiers are rejected" do
      assert {:error, _} = Scaffold.validate_tier(5)
      assert {:error, _} = Scaffold.validate_tier(-1)
      assert {:error, _} = Scaffold.validate_tier("0")
    end
  end

  describe "mob version requirement (issue #21 — scaffolds must not pin a stale mob)" do
    test "mob_requirement/1 derives ~> MAJOR.MINOR from a concrete version" do
      assert Scaffold.mob_requirement("0.7.3") == "~> 0.7"
      assert Scaffold.mob_requirement("1.2.10") == "~> 1.2"
      assert Scaffold.mob_requirement(Version.parse!("0.8.0-rc.1")) == "~> 0.8"
    end

    test "mob_requirement/1 falls back to the compiled default on nil" do
      assert Scaffold.mob_requirement(nil) =~ ~r/^~> \d+\.\d+$/
    end

    test "the compiled default is a parseable version requirement" do
      assert {:ok, _} = Version.parse_requirement(Scaffold.mob_requirement(nil))
    end

    test "detect_mob_requirement/0 returns a parseable requirement" do
      assert {:ok, _} = Version.parse_requirement(Scaffold.detect_mob_requirement())
    end

    test "the default does NOT pin the abandoned ~> 0.6 (the bug this fixes)" do
      # mob is 0.7.x; a 0.6 pin can't activate against published mob. If mob's
      # major.minor moves again, bump @fallback_mob_requirement — this guards
      # against silently shipping the old floor.
      refute Scaffold.mob_requirement(nil) == "~> 0.6"
    end

    test "every tier's mix.exs + manifest pin the same default requirement" do
      req = Scaffold.mob_requirement(nil)

      for tier <- 0..4 do
        files = Scaffold.files_for(tier, "mob_demo_widget")
        assert content_for(files, "mix.exs") =~ "{:mob, \"#{req}\"}"

        # tier 0 has no manifest; tiers 1-4 must agree with mix.exs.
        if tier > 0 do
          {m, _} = Code.eval_string(content_for(files, "priv/mob_plugin.exs"))
          assert m.mob_version == req, "tier #{tier} manifest mob_version drifted from mix.exs"
        end
      end
    end

    test "files_for/3 threads an explicit requirement into mix.exs + manifest" do
      files = Scaffold.files_for(1, "mob_demo_widget", "~> 9.9")
      assert content_for(files, "mix.exs") =~ "{:mob, \"~> 9.9\"}"
      {m, _} = Code.eval_string(content_for(files, "priv/mob_plugin.exs"))
      assert m.mob_version == "~> 9.9"
    end

    test "a scaffolded plugin's manifest is satisfied by a matching mob version" do
      # The whole point: validate the generated manifest against a mob the
      # default actually targets (not the stale 0.6 the validator used to OK).
      for tier <- 1..4 do
        dir = write_to_tmpdir!(Scaffold.files_for(tier, "mob_demo_widget"))
        manifest = load_manifest!(dir)
        assert %{errors: []} = Validator.validate_plugin(manifest, dir, satisfying_mob_version())
      end
    end
  end

  describe "files_for/2 — tier 0" do
    setup do
      {:ok, files: Scaffold.files_for(0, "mob_demo_widget")}
    end

    test "emits mix.exs, lib/<name>.ex + test scaffolding (no manifest)", %{files: files} do
      paths = paths(files)
      assert "mix.exs" in paths
      assert "lib/mob_demo_widget.ex" in paths
      assert length(files) == 4
    end

    test "mix.exs has the right module + app names", %{files: files} do
      content = content_for(files, "mix.exs")
      assert content =~ "defmodule MobDemoWidget.MixProject"
      assert content =~ "app: :mob_demo_widget"
      assert content =~ "{:mob, \"#{Scaffold.mob_requirement(nil)}\"}"
    end

    test "lib module is the PascalCase name", %{files: files} do
      content = content_for(files, "lib/mob_demo_widget.ex")
      assert content =~ "defmodule MobDemoWidget do"
    end
  end

  describe "files_for/2 — tier 1" do
    setup do
      {:ok, files: Scaffold.files_for(1, "mob_demo_widget")}
    end

    test "emits the 7 expected files for a NIF-bearing plugin", %{files: files} do
      paths = paths(files)
      assert "mix.exs" in paths
      assert "lib/mob_demo_widget.ex" in paths
      assert "src/mob_demo_widget_nif.erl" in paths
      assert "priv/mob_plugin.exs" in paths
      assert "priv/native/jni/mob_demo_widget_nif.c" in paths
      assert length(files) == 7
    end

    test "manifest's nif :module is the C-token name (not the Elixir module)", %{files: files} do
      manifest_src = content_for(files, "priv/mob_plugin.exs")
      {map, _} = Code.eval_string(manifest_src)
      assert %{nifs: [%{module: :mob_demo_widget_nif, native_dir: "priv/native/jni"}]} = map
    end

    test "Erlang stub matches the NIF name + has tolerant on_load", %{files: files} do
      erl = content_for(files, "src/mob_demo_widget_nif.erl")
      assert erl =~ "-module(mob_demo_widget_nif)."
      assert erl =~ "load_nif(\"mob_demo_widget_nif\", 0)"
      assert erl =~ "{error, _} -> ok"
    end

    test "C source uses ERL_NIF_INIT with the matching NIF name", %{files: files} do
      c = content_for(files, "priv/native/jni/mob_demo_widget_nif.c")
      assert c =~ "ERL_NIF_INIT(mob_demo_widget_nif, nif_funcs"
      assert c =~ "#include <erl_nif.h>"
    end

    test "Elixir wrapper delegates to the Erlang NIF module", %{files: files} do
      lib = content_for(files, "lib/mob_demo_widget.ex")
      assert lib =~ "defmodule MobDemoWidget do"
      assert lib =~ "defdelegate ping, to: :mob_demo_widget_nif"
    end

    test "tier-1 manifest validates clean (structural + path existence in tmpdir)" do
      dir = write_to_tmpdir!(Scaffold.files_for(1, "mob_demo_widget"))
      manifest = load_manifest!(dir)

      assert {:ok, ^manifest} = Manifest.validate(manifest)
      assert Manifest.tier(manifest) == 1

      assert %{errors: [], warnings: []} =
               Validator.validate_plugin(manifest, dir, satisfying_mob_version())
    end
  end

  describe "files_for/2 — tier 2" do
    setup do
      {:ok, files: Scaffold.files_for(2, "mob_demo_widget")}
    end

    test "emits the 8 expected files for a UI-component plugin", %{files: files} do
      paths = paths(files)
      assert "mix.exs" in paths
      assert "lib/mob_demo_widget.ex" in paths
      assert "lib/mob_demo_widget/view.ex" in paths
      assert "priv/mob_plugin.exs" in paths
      assert "priv/native/android/MobDemoWidget.kt" in paths
      assert "priv/native/ios/MobDemoWidgetView.swift" in paths
      assert length(files) == 8
    end

    test "manifest's registry name matches Mob.Component's module-name encoding", %{files: files} do
      manifest_src = content_for(files, "priv/mob_plugin.exs")
      {map, _} = Code.eval_string(manifest_src)

      assert %{ui_components: [comp]} = map
      assert comp.ios.view_module == "MobDemoWidget_View"
      assert comp.android.composable == "MobDemoWidget_View"
    end

    test "Elixir wrapper goes through Mob.UI.native_view with the View module", %{files: files} do
      lib = content_for(files, "lib/mob_demo_widget.ex")
      assert lib =~ "Mob.UI.native_view(MobDemoWidget.View"
      assert lib =~ "requires an :id atom"
    end

    test "view module uses Mob.Component", %{files: files} do
      view = content_for(files, "lib/mob_demo_widget/view.ex")
      assert view =~ "defmodule MobDemoWidget.View do"
      assert view =~ "use Mob.Component"
      assert view =~ "@impl true"
      assert view =~ "def mount("
      assert view =~ "def render("
    end

    test "Kotlin registers under the encoded name", %{files: files} do
      kt = content_for(files, "priv/native/android/MobDemoWidget.kt")
      assert kt =~ "MobNativeViewRegistry.register(\"MobDemoWidget_View\")"
      assert kt =~ "object MobDemoWidgetPlugin"
    end

    test "tier-2 manifest validates clean" do
      dir = write_to_tmpdir!(Scaffold.files_for(2, "mob_demo_widget"))
      manifest = load_manifest!(dir)
      assert {:ok, ^manifest} = Manifest.validate(manifest)
      assert Manifest.tier(manifest) == 2
      assert %{errors: []} = Validator.validate_plugin(manifest, dir, satisfying_mob_version())
    end
  end

  describe "files_for/2 — tier 3" do
    setup do
      {:ok, files: Scaffold.files_for(3, "mob_demo_widget")}
    end

    test "emits two screens, a manifest, and a migration", %{files: files} do
      paths = paths(files)
      assert "mix.exs" in paths
      assert "lib/mob_demo_widget/list_screen.ex" in paths
      assert "lib/mob_demo_widget/detail_screen.ex" in paths
      assert "priv/mob_plugin.exs" in paths
      assert "priv/repo/migrations/20260101000000_create_mob_demo_widget_items.exs" in paths
      assert length(files) == 7
    end

    test "manifest declares two screen routes + a namespaced migration", %{files: files} do
      {map, _} = Code.eval_string(content_for(files, "priv/mob_plugin.exs"))
      assert %{screens: screens, migrations: %{repo_namespace: "mob_demo_widget_"}} = map
      routes = Enum.map(screens, & &1.default_route)
      assert "/mob_demo_widget/list" in routes
      assert "/mob_demo_widget/detail" in routes
    end

    test "tier-3 manifest validates clean + classifies as tier 3" do
      dir = write_to_tmpdir!(Scaffold.files_for(3, "mob_demo_widget"))
      manifest = load_manifest!(dir)
      assert {:ok, ^manifest} = Manifest.validate(manifest)
      assert Manifest.tier(manifest) == 3
      assert %{errors: []} = Validator.validate_plugin(manifest, dir, satisfying_mob_version())
    end
  end

  describe "files_for/2 — tier 4" do
    setup do
      {:ok, files: Scaffold.files_for(4, "mob_demo_widget")}
    end

    test "emits lifecycle lib, worker, notifications, settings screen, manifest", %{files: files} do
      paths = paths(files)
      assert "mix.exs" in paths
      assert "lib/mob_demo_widget.ex" in paths
      assert "lib/mob_demo_widget/worker.ex" in paths
      assert "lib/mob_demo_widget/notifications.ex" in paths
      assert "lib/mob_demo_widget/settings_screen.ex" in paths
      assert "priv/mob_plugin.exs" in paths
      assert length(files) == 8
    end

    test "manifest wires lifecycle + settings + notifications", %{files: files} do
      {map, _} = Code.eval_string(content_for(files, "priv/mob_plugin.exs"))
      assert %{lifecycle: lc, settings: settings, notifications: %{handlers: [h]}} = map
      assert lc.on_start == {MobDemoWidget, :start, []}
      assert lc.supervised == [MobDemoWidget.Worker]
      assert settings.editor_screen == MobDemoWidget.SettingsScreen
      assert h.match == %{type: "mob_demo_widget"}
    end

    test "tier-4 manifest validates clean + classifies as tier 4" do
      dir = write_to_tmpdir!(Scaffold.files_for(4, "mob_demo_widget"))
      manifest = load_manifest!(dir)
      assert {:ok, ^manifest} = Manifest.validate(manifest)
      assert Manifest.tier(manifest) == 4
      assert %{errors: []} = Validator.validate_plugin(manifest, dir, satisfying_mob_version())
    end
  end

  describe "files_for/2 — test scaffolding (all tiers)" do
    test "every tier ships test/test_helper.exs + test/<name>_test.exs" do
      for tier <- 0..4 do
        ps = Scaffold.files_for(tier, "mob_demo_widget") |> paths()
        assert "test/test_helper.exs" in ps, "tier #{tier} missing test_helper"
        assert "test/mob_demo_widget_test.exs" in ps, "tier #{tier} missing test file"
      end
    end

    test "generated test files are valid Elixir with the right module name" do
      for tier <- 0..4 do
        content =
          Scaffold.files_for(tier, "mob_demo_widget")
          |> content_for("test/mob_demo_widget_test.exs")

        assert content =~ "defmodule MobDemoWidgetTest do"
        Code.string_to_quoted!(content)
      end
    end

    test "manifest-bearing tiers (1-4) get the structural manifest tests, tier 0 doesn't" do
      for tier <- 1..4 do
        content =
          Scaffold.files_for(tier, "mob_demo_widget")
          |> content_for("test/mob_demo_widget_test.exs")

        assert content =~ "priv/mob_plugin.exs"
        assert content =~ "mix mob.validate_plugin"
      end

      tier0 =
        Scaffold.files_for(0, "mob_demo_widget")
        |> content_for("test/mob_demo_widget_test.exs")

      refute tier0 =~ "priv/mob_plugin.exs"
    end

    test "the generated structural expectations hold for the scaffolded tier-1 plugin itself" do
      files = Scaffold.files_for(1, "mob_demo_widget")
      manifest_src = content_for(files, "priv/mob_plugin.exs")
      {m, _} = Code.eval_string(manifest_src)

      # Mirror the generated assertions: required keys + per-NIF native_dir
      # present in the scaffolded file set (on-disk File checks are covered by
      # the validate-in-tmpdir tests above).
      assert m.name == :mob_demo_widget
      assert m.mob_version == Scaffold.mob_requirement(nil)
      assert m.plugin_spec_version == 1

      scaffolded_dirs = paths(files) |> Enum.map(&Path.dirname/1) |> MapSet.new()

      for %{native_dir: dir} <- m.nifs do
        assert dir in scaffolded_dirs, "manifest native_dir #{dir} not scaffolded"
      end
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  # A concrete version that satisfies the scaffolded mob requirement, so the
  # validate-in-tmpdir checks track the default and never lag a mob bump:
  # "~> 0.7" → "0.7.0".
  defp satisfying_mob_version do
    "~> " <> base = Scaffold.mob_requirement(nil)
    base <> ".0"
  end

  defp paths(files), do: Enum.map(files, fn {p, _} -> p end)

  defp content_for(files, path) do
    {^path, content} = Enum.find(files, fn {p, _} -> p == path end)
    content
  end

  defp write_to_tmpdir!(files) do
    dir = Path.join(System.tmp_dir!(), "mob_scaffold_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit_cleanup(dir)

    Enum.each(files, fn {rel, content} ->
      path = Path.join(dir, rel)
      path |> Path.dirname() |> File.mkdir_p!()
      File.write!(path, content)
    end)

    dir
  end

  defp on_exit_cleanup(dir) do
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(dir) end)
  end

  defp load_manifest!(dir) do
    {:ok, manifest} = Manifest.load(dir)
    manifest
  end
end
