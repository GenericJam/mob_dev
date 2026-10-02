defmodule MobDev.MobNifTableTest do
  use ExUnit.Case, async: true

  alias MobDev.MobNifTable

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

  defp write(root, rel, content) do
    path = Path.join(root, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  defp project(root, deps_nif) do
    app = Path.join(root, "app")
    File.mkdir_p!(app)
    if deps_nif, do: write(app, "deps/mob/src/mob_nif.erl", deps_nif)
    app
  end

  defp checkout(root, nif) do
    dir = Path.join(root, "mob_checkout")
    write(dir, "src/mob_nif.erl", nif)
    dir
  end

  test "flags a checkout whose NIF table differs from deps/mob, both ways", %{tmp_dir: tmp} do
    app = project(tmp, @hex_nif)
    mob_dir = checkout(tmp, @master_nif)

    assert {:mismatch, m} = MobNifTable.check(app, mob_dir)
    assert m.only_in_mob_dir == ["capabilities/0", "native_stats/1"]
    assert m.only_in_deps == []

    msg = MobNifTable.message(m)
    assert msg =~ Path.join(mob_dir, "src/mob_nif.erl")
    assert msg =~ Path.join(app, "deps/mob/src/mob_nif.erl")
    assert msg =~ "undef mob_nif:log/1"
    assert msg =~ ~s|Path.join(File.cwd!(), "deps/mob")|
  end

  test "agrees when the tables match despite formatting and comments", %{tmp_dir: tmp} do
    app = project(tmp, @hex_nif)
    mob_dir = checkout(tmp, "-nifs([log/2, platform/0,\n log/1]).\n")

    assert MobNifTable.check(app, mob_dir) == :ok
  end

  test "mob_dir pointing at deps/mob (relative or absolute) is the safe pairing", %{tmp_dir: tmp} do
    app = project(tmp, @hex_nif)

    assert MobNifTable.check(app, "deps/mob") == :ok
    assert MobNifTable.check(app, Path.join(app, "deps/mob")) == :ok
  end

  test "a path dep (no deps/mob) or unset mob_dir has nothing to compare", %{tmp_dir: tmp} do
    app = project(tmp, nil)

    assert MobNifTable.check(app, checkout(tmp, @master_nif)) == :ok
    assert MobNifTable.check(app, nil) == :ok
  end
end
