defmodule Mix.Tasks.Mob.PluginsTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Mob.Plugins
  alias MobDev.Plugin.{Crypto, Report, Sign}

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

    test "unacknowledged unsigned plugins are not loaded, and say why", %{tmp_dir: tmp} do
      deps = %{plug_a: unsigned_plugin(tmp, :plug_a, "A_View")}

      assert [{:plug_a, {:unverified, :missing_signature}}] = Plugins.load_manifests(deps, [])
    end
  end

  # MOB-332: a plugin whose signature failed was listed as
  # "tier 0 … no manifest (regular dep)", hiding both the failure and its fix.
  describe "a plugin whose signature doesn't verify" do
    @describetag :tmp_dir

    defp signed_plugin(root, name) do
      dir = Path.join(root, Atom.to_string(name))
      File.mkdir_p!(Path.join(dir, "priv"))

      manifest = %{name: name, mob_version: "~> 0.6", plugin_spec_version: 1, nifs: []}
      File.write!(Path.join(dir, "priv/mob_plugin.exs"), inspect(manifest))

      {priv, pub} = Crypto.generate_keypair()
      File.write!(Path.join(dir, "priv/mob_plugin.pub"), Base.encode64(pub) <> "\n")
      :ok = Sign.sign_plugin(dir, priv)
      dir
    end

    defp listing(deps_paths, activated) do
      deps_paths |> Plugins.load_manifests([]) |> Report.rows(activated) |> Report.render()
    end

    test "an activated plugin tampered after signing is reported invalid, with the fix", %{
      tmp_dir: tmp
    } do
      dir = signed_plugin(tmp, :plug_t)
      File.write!(Path.join(dir, "priv/mob_plugin.exs"), "%{name: :plug_t, nifs: [:evil]}")

      out = listing(%{plug_t: dir}, [:plug_t])

      assert out =~ "signature is invalid"
      assert out =~ "mix mob.plugin.sign"
      assert out =~ "mix deps.clean plug_t && mix deps.get"
      assert out =~ "tier ?"
      refute out =~ "no manifest"
      refute out =~ ~r/plug_t\s+tier 0/
    end

    test "an unsigned plugin is listed even before activation, naming how to sign or allow it",
         %{tmp_dir: tmp} do
      out = listing(%{plug_a: unsigned_plugin(tmp, :plug_a, "A_View")}, [])

      assert out =~ "plug_a"
      assert out =~ "manifest is not signed"
      assert out =~ "config :mob, :acknowledge_unsafe_plugins, [:plug_a]"
    end

    test "a correctly signed plugin carries no signature note", %{tmp_dir: tmp} do
      out = listing(%{plug_ok: signed_plugin(tmp, :plug_ok)}, [:plug_ok])

      assert out =~ "tier 1"
      refute out =~ "fix:"
    end
  end
end
