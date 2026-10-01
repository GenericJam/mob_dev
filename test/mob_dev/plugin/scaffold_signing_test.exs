defmodule MobDev.Plugin.ScaffoldSigningTest do
  # Points the author key store at a tmp dir through app env, so not async.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias MobDev.Plugin.{Crypto, PrivateKeyStore, Scaffold, Verify}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    previous = Application.get_env(:mob_dev, :plugin_key_home)
    Application.put_env(:mob_dev, :plugin_key_home, Path.join(tmp, "home"))

    on_exit(fn ->
      if previous,
        do: Application.put_env(:mob_dev, :plugin_key_home, previous),
        else: Application.delete_env(:mob_dev, :plugin_key_home)
    end)

    {:ok, _} = Application.ensure_all_started(:yamerl)
    :ok
  end

  defp scaffold!(tmp, tier) do
    name = "mob_sign_scaffold_t#{tier}"
    dir = Path.join(tmp, name)

    for {rel, content} <- Scaffold.files_for(tier, name) do
      path = Path.join(dir, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
    end

    {name, dir}
  end

  defp keygen_and_sign!(dir) do
    capture_io(fn ->
      Mix.Tasks.Mob.Plugin.Keygen.run(["--plugin", dir])
      Mix.Tasks.Mob.Plugin.Sign.run(["--plugin", dir])
    end)
  end

  # What `mix hex.publish` ships for `package files:`: each entry expanded,
  # directories recursively (dotfiles included), regular files only.
  defp shipped_files(dir) do
    {:ok, ast} = dir |> Path.join("mix.exs") |> File.read!() |> Code.string_to_quoted()

    {_, [patterns]} =
      Macro.prewalk(ast, [], fn
        {:files, {:sigil_w, _, [{:<<>>, _, [words]}, _]}} = node, acc ->
          {node, [String.split(words) | acc]}

        node, acc ->
          {node, acc}
      end)

    for pattern <- patterns,
        path <- Path.wildcard(Path.join(dir, pattern), match_dot: true),
        file <-
          if(File.dir?(path),
            do: Path.wildcard(Path.join(path, "**"), match_dot: true),
            else: [path]
          ),
        File.regular?(file),
        into: MapSet.new(),
        do: Path.relative_to(file, dir)
  end

  defp workflow_steps(dir) do
    {:ok, yml} = YamlElixir.read_from_file(Path.join(dir, ".github/workflows/release.yml"))
    yml["jobs"]["release"]["steps"]
  end

  defp step!(steps, name), do: Enum.find(steps, &(&1["name"] == name)) || flunk("no step #{name}")

  for tier <- 1..4 do
    @tier tier
    describe "tier #{tier}" do
      test "keygen + sign of the scaffold gives a v2 signature hosts accept", %{tmp_dir: tmp} do
        {_name, dir} = scaffold!(tmp, @tier)
        keygen_and_sign!(dir)

        assert Verify.verify_plugin(dir) == :ok
      end

      test "package files ship every file the signature lists, plus the key and signature",
           %{tmp_dir: tmp} do
        {_name, dir} = scaffold!(tmp, @tier)
        keygen_and_sign!(dir)
        {:ok, %{file_hashes: hashes}} = Verify.load_envelope(dir)
        shipped = shipped_files(dir)

        signed =
          for {path, _} <- hashes,
              not String.starts_with?(path, "priv/mob_plugin.coverage-"),
              do: path

        assert "priv/mob_plugin.exs" in signed

        for path <- signed ++ ["priv/mob_plugin.pub", "priv/mob_plugin.sig"] do
          assert path in shipped, "#{path} is signed/required but not in package files"
        end
      end

      test "the signature is gitignored and the public key is not", %{tmp_dir: tmp} do
        {_name, dir} = scaffold!(tmp, @tier)

        ignored =
          dir
          |> Path.join(".gitignore")
          |> File.read!()
          |> String.split("\n")
          |> Enum.reject(&String.starts_with?(&1, "#"))

        assert "priv/mob_plugin.sig" in ignored
        refute Enum.any?(ignored, &String.contains?(&1, "mob_plugin.pub"))
      end
    end
  end

  describe "release workflow" do
    test "the key check accepts the keygen key and rejects any other", %{tmp_dir: tmp} do
      {name, dir} = scaffold!(tmp, 1)
      capture_io(fn -> Mix.Tasks.Mob.Plugin.Keygen.run(["--plugin", dir]) end)

      run =
        step!(workflow_steps(dir), "Verify the signing key matches priv/mob_plugin.pub")["run"]

      [_, script] = Regex.run(Regex.compile!("elixir -e '(.*)'\\s*$", "s"), run)
      elixir = System.find_executable("elixir") || flunk("elixir not on PATH")

      check = fn secret ->
        System.cmd(elixir, ["-e", script],
          cd: dir,
          env: [{"MOB_PLUGIN_SIGN_KEY", secret}],
          stderr_to_stdout: true
        )
      end

      # The secret is the key file's exact contents (trailing newline and all).
      {_, ok} = check.(File.read!(PrivateKeyStore.key_path(name)))
      assert ok == 0

      {other, _pub} = Crypto.generate_keypair()
      {out, bad} = check.(Base.encode64(other))
      assert bad != 0
      assert out =~ "does not derive the committed priv/mob_plugin.pub"
    end

    test "it signs right before publishing, and refuses to publish without the key",
         %{tmp_dir: tmp} do
      {_name, dir} = scaffold!(tmp, 2)
      steps = workflow_steps(dir)
      names = Enum.map(steps, & &1["name"])

      order =
        Enum.map(
          [
            "Require the signing key",
            "Verify the signing key matches priv/mob_plugin.pub",
            "Validate, then sign what ships",
            "mix hex.publish"
          ],
          fn n -> Enum.find_index(names, &(&1 == n)) || flunk("no step #{n}") end
        )

      assert order == Enum.sort(order)

      require_key = step!(steps, "Require the signing key")
      assert require_key["if"] =~ "env.MOB_PLUGIN_SIGN_KEY == ''"
      assert require_key["run"] =~ "exit 1"

      sign = step!(steps, "Validate, then sign what ships")["run"]
      assert sign =~ "mix mob.plugin.sign"
      assert sign =~ "~/.mob/keys/\"$pkg\".priv"
      env = load_env(dir)
      assert env[Scaffold.sign_key_secret()] == "${{ secrets.#{Scaffold.sign_key_secret()} }}"
    end

    test "publishing stops until @source_url is set, then passes", %{tmp_dir: tmp} do
      {_name, dir} = scaffold!(tmp, 3)
      run = step!(workflow_steps(dir), "Require a real @source_url in mix.exs")["run"]
      # Actions substitutes ${{ … }} before the shell sees the script.
      script = String.replace(run, "${{ github.repository }}", "acme/plugin")
      guard = fn -> System.cmd("sh", ["-c", script], cd: dir, stderr_to_stdout: true) end

      assert {out, 1} = guard.()
      assert out =~ "https://github.com/acme/plugin"

      mix_exs = Path.join(dir, "mix.exs")

      File.write!(
        mix_exs,
        String.replace(File.read!(mix_exs), "github.com/OWNER/", "github.com/acme/")
      )

      assert {_, 0} = guard.()
    end
  end

  test "tier 0 has no manifest and gets none of the signing setup" do
    paths = for {p, _} <- Scaffold.files_for(0, "mob_plain"), do: p
    refute ".gitignore" in paths
    refute ".github/workflows/release.yml" in paths

    refute Scaffold.files_for(0, "mob_plain") |> List.keyfind("mix.exs", 0) |> elem(1) =~
             "mob_dev"
  end

  test "the next steps name the secret the workflow reads and the key file keygen writes" do
    steps = Mix.Tasks.Mob.NewPlugin.next_steps("mob_x", 1, "plugins/mob_x")
    assert steps =~ "gh secret set #{Scaffold.sign_key_secret()} < ~/.mob/keys/mob_x.priv"
    assert steps =~ "mix mob.plugin.trust mob_x"
    refute Mix.Tasks.Mob.NewPlugin.next_steps("mob_x", 0, "plugins/mob_x") =~ "gh secret"
  end

  defp load_env(dir) do
    {:ok, yml} = YamlElixir.read_from_file(Path.join(dir, ".github/workflows/release.yml"))
    yml["jobs"]["release"]["env"]
  end
end
