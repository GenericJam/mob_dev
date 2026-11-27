defmodule Mix.Tasks.Mob.Plugin.TrustTest do
  use ExUnit.Case, async: false

  alias MobDev.Plugin.{Crypto, Sign, TrustStore}

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

    {priv, pub} = Crypto.generate_keypair()
    File.write!(Path.join(plugin_dir, "priv/mob_plugin.pub"), Base.encode64(pub) <> "\n")
    :ok = Sign.sign_plugin(plugin_dir, priv)

    deps_paths = %{plugin_name => plugin_dir}

    on_exit(fn -> File.rm_rf!(workdir) end)

    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    {:ok,
     workdir: workdir,
     pub: pub,
     priv: priv,
     manifest: manifest,
     plugin_name: plugin_name,
     deps_paths: deps_paths}
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

  test "the review shows the fingerprint and the manifest's declared capabilities", %{
    workdir: workdir,
    pub: pub,
    plugin_name: name,
    deps_paths: deps
  } do
    send(self(), {:mix_shell_input, :yes?, false})
    Mix.Tasks.Mob.Plugin.Trust.run_with_deps([Atom.to_string(name)], deps, workdir)
    assert_received {:mix_shell, :info, [review]}

    assert review =~ "fingerprint:  #{Crypto.fingerprint(pub)}"
    assert review =~ ~s(ios frameworks: ["UIKit"])
    assert review =~ ~s(android permissions: ["android.permission.INTERNET"])
  end

  # MOB-550: trust is refused, and the manifest is never evaluated, unless the
  # plugin's v2 signature verifies first. Each manifest below writes a marker
  # file when evaluated.
  describe "a plugin without a valid signature" do
    setup %{workdir: workdir, manifest: manifest, deps_paths: deps, plugin_name: name} do
      marker = Path.join(workdir, "manifest_evaluated")

      side_effect_manifest = """
      File.write!(#{inspect(marker)}, "evaluated")
      #{inspect(manifest, limit: :infinity)}
      """

      {:ok, marker: marker, side_effect_manifest: side_effect_manifest, plugin_dir: deps[name]}
    end

    defp assert_refused_unevaluated(name, deps, workdir, marker, message) do
      mob_exs = File.read!(Path.join(workdir, "mob.exs"))

      assert_raise Mix.Error, message, fn ->
        Mix.Tasks.Mob.Plugin.Trust.run_with_deps([Atom.to_string(name)], deps, workdir)
      end

      refute File.exists?(marker), "the manifest was evaluated before verification"
      refute_received {:mix_shell, :yes?, _}
      assert File.read!(Path.join(workdir, "mob.exs")) == mob_exs

      # The probe's precondition: evaluating this manifest does write the
      # marker, so its absence above means the manifest never ran.
      Code.eval_file(Path.join(deps[name], "priv/mob_plugin.exs"))
      assert File.exists?(marker)
    end

    defp write_manifest!(plugin_dir, source),
      do: File.write!(Path.join(plugin_dir, "priv/mob_plugin.exs"), source)

    test "unsigned: refused, pointing at acknowledge_unsafe_plugins", ctx do
      File.rm!(Sign.signature_path(ctx.plugin_dir))
      write_manifest!(ctx.plugin_dir, ctx.side_effect_manifest)

      assert_refused_unevaluated(
        ctx.plugin_name,
        ctx.deps_paths,
        ctx.workdir,
        ctx.marker,
        ~r/is not signed.*acknowledge_unsafe_plugins, \[:mob_trust_demo\]/s
      )
    end

    test "manifest changed after signing: refused", ctx do
      write_manifest!(ctx.plugin_dir, ctx.side_effect_manifest)

      assert_refused_unevaluated(
        ctx.plugin_name,
        ctx.deps_paths,
        ctx.workdir,
        ctx.marker,
        ~r/signature for plugin :mob_trust_demo does not verify/
      )
    end

    test "signed by a key other than the shipped priv/mob_plugin.pub: refused", ctx do
      write_manifest!(ctx.plugin_dir, ctx.side_effect_manifest)
      {other_priv, _other_pub} = Crypto.generate_keypair()
      :ok = Sign.sign_plugin(ctx.plugin_dir, other_priv)
      File.rm!(ctx.marker)

      assert_refused_unevaluated(
        ctx.plugin_name,
        ctx.deps_paths,
        ctx.workdir,
        ctx.marker,
        ~r/does not verify/
      )
    end

    test "legacy v1 signature: refused", ctx do
      write_manifest!(ctx.plugin_dir, ctx.side_effect_manifest)

      v1 = Crypto.canonical_encode(%{signature: :binary.copy(<<0>>, 64), envelope_version: 1})
      File.write!(Sign.signature_path(ctx.plugin_dir), v1)

      assert_refused_unevaluated(
        ctx.plugin_name,
        ctx.deps_paths,
        ctx.workdir,
        ctx.marker,
        ~r/legacy v1 signature.*mix deps.update mob_trust_demo/s
      )
    end

    test "no priv/mob_plugin.pub: refused", ctx do
      File.rm!(Path.join(ctx.plugin_dir, "priv/mob_plugin.pub"))
      write_manifest!(ctx.plugin_dir, ctx.side_effect_manifest)

      assert_refused_unevaluated(
        ctx.plugin_name,
        ctx.deps_paths,
        ctx.workdir,
        ctx.marker,
        ~r/ships no priv\/mob_plugin.pub/
      )
    end

    test "a path dependency changed after signing: refused, told to re-sign in place", ctx do
      outside = Path.join(ctx.workdir, "checkouts/plugin")
      File.mkdir_p!(Path.dirname(outside))
      File.rename!(ctx.plugin_dir, outside)
      write_manifest!(outside, ctx.side_effect_manifest)

      assert_refused_unevaluated(
        ctx.plugin_name,
        %{ctx.plugin_name => outside},
        ctx.workdir,
        ctx.marker,
        ~r/does not verify.*path dependency.*re-sign it in its directory/s
      )
    end
  end

  describe "refusal_message/3" do
    test "a verified manifest that fails to evaluate" do
      assert Mix.Tasks.Mob.Plugin.Trust.refusal_message(:mob_x, "boom", false) ==
               "could not load manifest for :mob_x: boom"
    end

    test "a dependency under deps/ is told to reinstall or update" do
      assert Mix.Tasks.Mob.Plugin.Trust.refusal_message(:mob_x, :invalid_signature, false) =~
               "mix deps.clean mob_x && mix deps.get"

      message =
        Mix.Tasks.Mob.Plugin.Trust.refusal_message(:mob_x, :envelope_v1_unsupported, false)

      assert message =~ "mix deps.update mob_x"
    end

    test "a path dependency is told to re-sign in place, not to use deps.get/deps.update" do
      for reason <- [:invalid_signature, :envelope_v1_unsupported] do
        message = Mix.Tasks.Mob.Plugin.Trust.refusal_message(:mob_x, reason, true)
        assert message =~ "re-sign it in its directory with `mix mob.plugin.sign`"
        assert message =~ "~/.mob/keys/mob_x.priv"
        refute message =~ "mix deps."
      end
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

    defp move_to_path_dep(plugin_dir, root, priv, mix_exs) do
      outside = Path.join(root, "checkouts/plugin")
      File.mkdir_p!(Path.dirname(outside))
      File.rename!(plugin_dir, outside)
      manifest_path = Path.join(outside, "priv/mob_plugin.exs")
      {manifest, _} = manifest_path |> File.read!() |> Code.eval_string()
      File.write!(manifest_path, inspect(Map.delete(manifest, :version)))
      File.write!(Path.join(outside, "mix.exs"), mix_exs)
      :ok = Sign.sign_plugin(outside, priv)
      outside
    end

    test "a path dependency shows its mix.exs version and its location", %{
      workdir: workdir,
      priv: priv,
      plugin_name: name,
      deps_paths: deps
    } do
      dir =
        move_to_path_dep(deps[name], workdir, priv, """
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
      priv: priv,
      plugin_name: name,
      deps_paths: deps
    } do
      dir = move_to_path_dep(deps[name], workdir, priv, "this is not elixir (")

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
