defmodule MobDev.MobNifTableTest do
  use ExUnit.Case, async: true

  alias MobDev.{MobDirCheck, MobNifTable}

  @moduletag :tmp_dir

  # Shaped like mob's real mob_nif.erl: comments inside the list, a NIF
  # commented out, and a second -nifs attribute.
  @hex_nif """
  -module(mob_nif).
  -export([platform/0, log/1, log/2]).
  -nifs([
      platform/0,
      log/1,  % plain log
      log/2
      %% capabilities/0,  not in this release
  ]).
  -on_load(init/0).
  """

  @master_nif """
  -module(mob_nif).
  -nifs([
      platform/0,
      log/1,
      log/2,
      capabilities/0
  ]).
  -nifs([native_stats/1]).
  -on_load(init/0).
  """

  defp mob(root, name, nif) do
    dir = Path.join(root, name)
    File.mkdir_p!(Path.join(dir, "src"))
    File.write!(Path.join(dir, "src/mob_nif.erl"), nif)
    dir
  end

  test "names the NIFs only one checkout lists, both ways", %{tmp_dir: tmp} do
    master = mob(tmp, "master", @master_nif)
    hex = mob(tmp, "hex", @hex_nif)

    assert MobNifTable.diff(master, hex) ==
             %{only_in_mob_dir: ["capabilities/0", "native_stats/1"], only_in_dep: []}

    assert MobNifTable.diff(hex, master) ==
             %{only_in_mob_dir: [], only_in_dep: ["capabilities/0", "native_stats/1"]}
  end

  test "tables that agree despite formatting and comments are no difference", %{tmp_dir: tmp} do
    hex = mob(tmp, "hex", @hex_nif)
    other = mob(tmp, "other", "-nifs([log/2, platform/0,\n log/1]).\n")

    assert MobNifTable.diff(other, hex) == nil
  end

  test "a checkout without mob_nif.erl has nothing to compare", %{tmp_dir: tmp} do
    hex = mob(tmp, "hex", @hex_nif)
    assert MobNifTable.diff(Path.join(tmp, "missing"), hex) == nil
  end

  describe "the mob_dir / :mob dependency mismatch error" do
    test "names the boot crash and the differing NIFs when the tables differ", %{tmp_dir: tmp} do
      master = mob(tmp, "master", @master_nif)
      hex = mob(tmp, "hex", @hex_nif)

      msg = MobDirCheck.message(master, hex)
      assert msg =~ "undef mob_nif:log/1"
      assert msg =~ "only in mob_dir:         capabilities/0, native_stats/1"
      assert msg =~ "config :mob_dev, mob_dir: #{inspect(hex)}"

      assert {:fail, _, detail, _fix} = Mix.Tasks.Mob.Doctor.__mob_dir_dep_check__(master, hex)
      assert detail =~ "undef mob_nif:log/1"
    end

    test "doesn't claim a boot crash when the tables agree", %{tmp_dir: tmp} do
      a = mob(tmp, "a", @hex_nif)
      b = mob(tmp, "b", @hex_nif)

      refute MobDirCheck.message(a, b) =~ "undef"
    end

    test "a path dep matching mob_dir passes even with a stale Hex deps/mob on disk", %{
      tmp_dir: tmp
    } do
      checkout = mob(tmp, "checkout", @master_nif)
      app = Path.join(tmp, "app")
      mob(app, "deps/mob", @hex_nif)

      assert MobDirCheck.check(checkout, checkout) == :ok
      assert {:ok, _, _, nil} = Mix.Tasks.Mob.Doctor.__mob_dir_dep_check__(checkout, checkout)
    end
  end
end
