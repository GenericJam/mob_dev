defmodule Mix.Tasks.Mob.Plugin.TrustTest do
  use ExUnit.Case, async: false

  alias MobDev.Plugin.{Crypto, TrustStore}

  setup do
    workdir =
      Path.join(System.tmp_dir!(), "mob_trust_task_#{System.unique_integer([:positive])}")

    File.mkdir_p!(workdir)
    File.write!(Path.join(workdir, "mob.exs"), "import Config\n")

    plugin_name = :mob_trust_demo
    plugin_dir = Path.join(workdir, "deps/#{plugin_name}")
    File.mkdir_p!(Path.join(plugin_dir, "priv"))

    manifest = %{
      name: plugin_name,
      mob_version: "~> 0.6",
      plugin_spec_version: 1,
      version: "0.1.0",
      ios: %{frameworks: ["UIKit"]},
      android: %{permissions: ["android.permission.INTERNET"]}
    }

    File.write!(Path.join(plugin_dir, "priv/mob_plugin.exs"), inspect(manifest, limit: :infinity))

    {_priv, pub} = Crypto.generate_keypair()
    File.write!(Path.join(plugin_dir, "priv/mob_plugin.pub"), Base.encode64(pub) <> "\n")

    deps_paths = %{plugin_name => plugin_dir}

    on_exit(fn -> File.rm_rf!(workdir) end)

    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    {:ok, workdir: workdir, pub: pub, plugin_name: plugin_name, deps_paths: deps_paths}
  end

  test "yes at prompt writes the trust entry", %{
    workdir: workdir,
    pub: pub,
    plugin_name: name,
    deps_paths: deps
  } do
    send(self(), {:mix_shell_input, :yes?, true})

    Mix.Tasks.Mob.Plugin.Trust.run_with_deps([Atom.to_string(name)], deps, workdir)

    expected = %{name => Crypto.fingerprint(pub)}
    assert TrustStore.load_trusted_plugins(workdir) == expected
  end

  test "is idempotent for the same key", %{
    workdir: workdir,
    pub: pub,
    plugin_name: name,
    deps_paths: deps
  } do
    send(self(), {:mix_shell_input, :yes?, true})
    Mix.Tasks.Mob.Plugin.Trust.run_with_deps([Atom.to_string(name)], deps, workdir)

    first = File.read!(Path.join(workdir, "mob.exs"))

    send(self(), {:mix_shell_input, :yes?, true})
    Mix.Tasks.Mob.Plugin.Trust.run_with_deps([Atom.to_string(name)], deps, workdir)

    assert File.read!(Path.join(workdir, "mob.exs")) == first
    assert TrustStore.load_trusted_plugins(workdir) == %{name => Crypto.fingerprint(pub)}
  end

  test "no at prompt leaves mob.exs unchanged", %{
    workdir: workdir,
    plugin_name: name,
    deps_paths: deps
  } do
    send(self(), {:mix_shell_input, :yes?, false})

    Mix.Tasks.Mob.Plugin.Trust.run_with_deps([Atom.to_string(name)], deps, workdir)

    assert TrustStore.load_trusted_plugins(workdir) == %{}
  end

  test "raises when the plugin isn't a known dep", %{workdir: workdir} do
    assert_raise Mix.Error, ~r/no dependency named/, fn ->
      Mix.Tasks.Mob.Plugin.Trust.run_with_deps(["mob_unknown"], %{}, workdir)
    end
  end

  # MOB-334: a path dependency's manifest rarely declares a version, and the
  # review showed `version: (unset)` for it.
  describe "the version shown for review" do
    defp review_output(name, deps, workdir) do
      send(self(), {:mix_shell_input, :yes?, false})
      Mix.Tasks.Mob.Plugin.Trust.run_with_deps([Atom.to_string(name)], deps, workdir)
      assert_received {:mix_shell, :info, [review]}
      review
    end

    defp move_to_path_dep(plugin_dir, root, mix_exs) do
      outside = Path.join(root, "checkouts/plugin")
      File.mkdir_p!(Path.dirname(outside))
      File.rename!(plugin_dir, outside)
      manifest_path = Path.join(outside, "priv/mob_plugin.exs")
      {manifest, _} = manifest_path |> File.read!() |> Code.eval_string()
      File.write!(manifest_path, inspect(Map.delete(manifest, :version)))
      File.write!(Path.join(outside, "mix.exs"), mix_exs)
      outside
    end

    test "a path dependency shows its mix.exs version and its location", %{
      workdir: workdir,
      plugin_name: name,
      deps_paths: deps
    } do
      dir =
        move_to_path_dep(deps[name], workdir, """
        defmodule MobTrustDemo.MixProject do
          use Mix.Project
          @version "0.4.2"
          def project, do: [app: :mob_trust_demo, version: @version]
        end
        """)

      review = review_output(name, %{name => dir}, workdir)

      assert review =~ "version:      0.4.2 (path dependency: #{dir})"
      refute review =~ "(unset)"
    end

    test "a path dependency with no readable version still names its location", %{
      workdir: workdir,
      plugin_name: name,
      deps_paths: deps
    } do
      dir = move_to_path_dep(deps[name], workdir, "this is not elixir (")

      assert review_output(name, %{name => dir}, workdir) =~
               "version:      (not declared) (path dependency: #{dir})"
    end

    test "a dependency under deps/ shows the manifest's version", %{
      workdir: workdir,
      plugin_name: name,
      deps_paths: deps
    } do
      assert review_output(name, deps, workdir) =~ "version:      0.1.0\n"
    end
  end

  test "untrust removes the entry", %{
    workdir: workdir,
    pub: pub,
    plugin_name: name,
    deps_paths: deps
  } do
    send(self(), {:mix_shell_input, :yes?, true})
    Mix.Tasks.Mob.Plugin.Trust.run_with_deps([Atom.to_string(name)], deps, workdir)
    assert TrustStore.load_trusted_plugins(workdir) == %{name => Crypto.fingerprint(pub)}

    Mix.Tasks.Mob.Plugin.Untrust.run_in([Atom.to_string(name)], workdir)
    assert TrustStore.load_trusted_plugins(workdir) == %{}
  end
end
