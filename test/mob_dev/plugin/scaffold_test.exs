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
  end

  describe "validate_tier/1" do
    test "0, 1, 2 are valid" do
      for t <- [0, 1, 2], do: assert(Scaffold.validate_tier(t) == :ok)
    end

    test "other tiers are rejected" do
      assert {:error, _} = Scaffold.validate_tier(3)
      assert {:error, _} = Scaffold.validate_tier(-1)
      assert {:error, _} = Scaffold.validate_tier("0")
    end
  end

  describe "files_for/2 — tier 0" do
    setup do
      {:ok, files: Scaffold.files_for(0, "mob_demo_widget")}
    end

    test "emits mix.exs and lib/<name>.ex (2 files, no manifest)", %{files: files} do
      paths = paths(files)
      assert "mix.exs" in paths
      assert "lib/mob_demo_widget.ex" in paths
      assert length(files) == 2
    end

    test "mix.exs has the right module + app names", %{files: files} do
      content = content_for(files, "mix.exs")
      assert content =~ "defmodule MobDemoWidget.MixProject"
      assert content =~ "app: :mob_demo_widget"
      assert content =~ "{:mob, \"~> 0.6\"}"
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

    test "emits the 5 expected files for a NIF-bearing plugin", %{files: files} do
      paths = paths(files)
      assert "mix.exs" in paths
      assert "lib/mob_demo_widget.ex" in paths
      assert "src/mob_demo_widget_nif.erl" in paths
      assert "priv/mob_plugin.exs" in paths
      assert "priv/native/jni/mob_demo_widget_nif.c" in paths
      assert length(files) == 5
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

      assert {:ok, _} = Manifest.validate(manifest)
      assert Manifest.tier(manifest) == 1
      assert %{errors: [], warnings: []} = Validator.validate_plugin(manifest, dir, "0.6.20")
    end
  end

  describe "files_for/2 — tier 2" do
    setup do
      {:ok, files: Scaffold.files_for(2, "mob_demo_widget")}
    end

    test "emits the 6 expected files for a UI-component plugin", %{files: files} do
      paths = paths(files)
      assert "mix.exs" in paths
      assert "lib/mob_demo_widget.ex" in paths
      assert "lib/mob_demo_widget/view.ex" in paths
      assert "priv/mob_plugin.exs" in paths
      assert "priv/native/android/MobDemoWidget.kt" in paths
      assert "priv/native/ios/MobDemoWidgetView.swift" in paths
      assert length(files) == 6
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
      assert {:ok, _} = Manifest.validate(manifest)
      assert Manifest.tier(manifest) == 2
      assert %{errors: []} = Validator.validate_plugin(manifest, dir, "0.6.20")
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

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
