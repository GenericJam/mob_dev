defmodule Mix.Tasks.Mob.PluginsTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Mob.Plugins

  describe "normalize_activated/1 (config :mob, :plugins coercion)" do
    test "keeps a clean list of atom plugin names" do
      assert Plugins.normalize_activated([:a, :b]) == [:a, :b]
    end

    test "filters out non-atom entries (e.g. a stray string typo)" do
      assert Plugins.normalize_activated([:a, "mob_haptic", :b]) == [:a, :b]
    end

    test "a non-list (misconfigured) value coerces to [] instead of crashing" do
      # The defect: `name in activated` raises Protocol.UndefinedError when
      # :plugins is a non-list (e.g. a bare map or atom).
      assert Plugins.normalize_activated(%{a: 1}) == []
      assert Plugins.normalize_activated(:not_a_list) == []
      assert Plugins.normalize_activated(nil) == []
    end
  end

  # Release review of MOB-170: the CLI loaded manifests without the build's
  # acknowledgement, so two acknowledged unsigned plugins that collide were
  # dropped as nil and `mix mob.plugins` exited 0 where the build failed.
  describe "load_manifests/2 feeds the collision check like the build" do
    @moduletag :tmp_dir

    defp unsigned_plugin(root, name, composable) do
      dir = Path.join(root, Atom.to_string(name))
      File.mkdir_p!(Path.join(dir, "priv"))

      manifest = %{
        name: name,
        mob_version: "~> 0.6",
        plugin_spec_version: 1,
        ui_components: [%{atom: name, android: %{composable: composable}}]
      }

      File.write!(Path.join(dir, "priv/mob_plugin.exs"), inspect(manifest))
      dir
    end

    test "acknowledged unsigned plugins that collide fail the check", %{tmp_dir: tmp} do
      deps = %{
        plug_a: unsigned_plugin(tmp, :plug_a, "Shared_View"),
        plug_b: unsigned_plugin(tmp, :plug_b, "Shared_View")
      }

      loaded = Plugins.load_manifests(deps, [:plug_a, :plug_b])
      assert Enum.all?(loaded, fn {_app, manifest} -> is_map(manifest) end)

      activated = for {app, manifest} <- loaded, do: {deps[app], manifest}

      assert_raise Mix.Error, ~r/Shared_View|native view key/, fn ->
        MobDev.Plugin.Validator.raise_on_cross_plugin_conflicts!(activated)
      end
    end

    test "unacknowledged unsigned plugins are still skipped", %{tmp_dir: tmp} do
      deps = %{plug_a: unsigned_plugin(tmp, :plug_a, "A_View")}

      ExUnit.CaptureIO.capture_io(fn ->
        assert [{:plug_a, nil}] = Plugins.load_manifests(deps, [])
      end)
    end
  end
end
