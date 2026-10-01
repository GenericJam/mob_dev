defmodule MobDev.MobDirCheckTest do
  use ExUnit.Case, async: false

  alias MobDev.MobDirCheck

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    mob = Path.join(tmp, "mob")
    other = Path.join(tmp, "other_mob")
    File.mkdir_p!(mob)
    File.mkdir_p!(other)
    %{mob: mob, other: other}
  end

  describe "check/2" do
    test "the same directory matches", %{mob: mob} do
      assert MobDirCheck.check(mob, mob) == :ok
      assert MobDirCheck.check(mob <> "/", Path.join(mob, "../mob")) == :ok
    end

    test "a symlink to the dependency matches", %{tmp_dir: tmp, mob: mob} do
      link = Path.join(tmp, "mob_link")
      File.ln_s!(mob, link)

      assert MobDirCheck.check(link, mob) == :ok
      assert MobDirCheck.check(mob, link) == :ok
    end

    test "a different checkout is a mismatch naming both expanded paths", %{
      mob: mob,
      other: other
    } do
      assert MobDirCheck.check(other, mob) == {:mismatch, other, mob}
      assert MobDirCheck.check(Path.join(other, "../other_mob"), mob) == {:mismatch, other, mob}
    end

    test "a symlink to a different checkout is a mismatch", %{
      tmp_dir: tmp,
      mob: mob,
      other: other
    } do
      link = Path.join(tmp, "looks_like_mob")
      File.ln_s!(other, link)

      assert {:mismatch, ^link, ^mob} = MobDirCheck.check(link, mob)
    end

    test "unset mob_dir or no :mob dependency has nothing to compare", %{mob: mob} do
      assert MobDirCheck.check(nil, mob) == :ok
      assert MobDirCheck.check(mob, nil) == :ok
      assert MobDirCheck.check(nil, nil) == :ok
    end

    test "paths that don't exist yet compare with symlinked parents resolved", %{
      tmp_dir: tmp,
      mob: mob
    } do
      # A Hex :mob before `mix deps.get`: deps/mob doesn't exist yet, and the
      # project dir may be reached through a symlink (macOS /tmp -> /private/tmp).
      link = Path.join(tmp, "project_link")
      File.ln_s!(mob, link)
      unfetched = Path.join(mob, "deps/mob")

      assert MobDirCheck.check(Path.join(link, "deps/mob"), unfetched) == :ok
      assert {:mismatch, _, _} = MobDirCheck.check(Path.join(link, "deps/other"), unfetched)
    end
  end

  test "the message names both paths and both fixes", %{mob: mob, other: other} do
    msg = MobDirCheck.message(other, mob)

    assert msg =~ "mob_dir (native code is compiled from):   #{other}"
    assert msg =~ ":mob dependency (Elixir code comes from): #{mob}"
    assert msg =~ ~s(config :mob_dev, mob_dir: "#{mob}")
    assert msg =~ ~s({:mob, path: "#{other}", override: true})
  end

  describe "native builds refuse a mismatch before compiling" do
    setup %{tmp_dir: tmp, other: other} do
      project = Path.join(tmp, "app")
      File.mkdir_p!(project)

      File.write!(
        Path.join(project, "mob.exs"),
        "import Config\nconfig :mob_dev, mob_dir: #{inspect(other)}\n"
      )

      cwd = File.cwd!()
      File.cd!(project)
      on_exit(fn -> File.cd!(cwd) end)

      # The test runs inside mob_dev's own Mix project, whose :mob dependency
      # is a real path that is not `other`.
      dep = MobDirCheck.dep_path()
      assert is_binary(dep)
      %{project: project, dep: dep}
    end

    test "MobDev.NativeBuild.build_all/1", %{project: project, other: other, dep: dep} do
      error = assert_raise Mix.Error, fn -> MobDev.NativeBuild.build_all(platforms: []) end

      assert error.message =~ other
      assert error.message =~ Path.expand(dep)
      # Stopped before generating any native build input.
      assert File.ls!(project) == ["mob.exs"]
    end

    test "MobDev.Release.build_ipa/1", %{project: project, other: other} do
      error = assert_raise Mix.Error, fn -> MobDev.Release.build_ipa() end

      assert error.message =~ other
      assert File.ls!(project) == ["mob.exs"]
    end
  end

  describe "mix mob.doctor" do
    test "fails a mismatch, naming both paths", %{mob: mob, other: other} do
      assert {:fail, _label, detail, fix} = Mix.Tasks.Mob.Doctor.__mob_dir_dep_check__(other, mob)
      assert detail =~ other
      assert detail =~ mob
      assert fix =~ ~s(mob_dir: "#{mob}")
    end

    test "passes a match and stays quiet when either side is unknown", %{mob: mob} do
      assert {:ok, _, _, nil} = Mix.Tasks.Mob.Doctor.__mob_dir_dep_check__(mob, mob)
      assert Mix.Tasks.Mob.Doctor.__mob_dir_dep_check__(nil, mob) == []
      assert Mix.Tasks.Mob.Doctor.__mob_dir_dep_check__(mob, nil) == []
    end
  end
end
