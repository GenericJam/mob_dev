defmodule MobDev.ExqliteTest do
  use ExUnit.Case, async: true

  # MOB-487: device builds compiled sqlite3.c with only -DSQLITE_THREADSAFE=1,
  # so an FTS5 table that worked under host tests failed on the phone with
  # `no such module: fts5`. Every mob build of the amalgamation must use
  # exqlite's own defines, the ones its Makefile compiles the host NIF with.

  alias MobDev.Exqlite

  test "the define set enables FTS5" do
    assert "-DSQLITE_ENABLE_FTS5=1" in Exqlite.cflags()
  end

  test "the define set is exqlite's Makefile set, in order" do
    makefile = Path.join(Mix.Project.deps_paths().exqlite, "Makefile")
    line = Regex.compile!(~S{^CFLAGS \+= -D(\S+)$}, "m")
    makefile_defines = Regex.scan(line, File.read!(makefile), capture: :all_but_first)

    assert Exqlite.defines() == List.flatten(makefile_defines)
  end

  # mob_new is a self-contained archive and can't call MobDev.Exqlite, so its
  # Android templates carry the list themselves. Read them from the mob_new
  # checkout CI provides in MOB_NEW_DIR: an installed mob_new archive or a
  # stale ~/code/mob_new (MobDev.Adopt.Generator.templates_root/1's other
  # sources) can predate the list.
  if is_nil(System.get_env("MOB_NEW_DIR")),
    do: @tag(skip: "set MOB_NEW_DIR to a mob_new checkout")

  test "mob_new's Android build.zig and CMakeLists.txt compile SQLite with the same set" do
    jni =
      Path.join(
        System.fetch_env!("MOB_NEW_DIR"),
        "priv/templates/mob.new/android/app/src/main/jni"
      )

    zig_define = Regex.compile!(~S{^"-D(.+)",$})

    zig =
      jni
      |> Path.join("build.zig.eex")
      |> define_block()
      |> Enum.map(&(Regex.run(zig_define, &1, capture: :all_but_first) |> hd()))

    cmake = jni |> Path.join("CMakeLists.txt.eex") |> define_block()

    assert {zig, cmake} == {Exqlite.defines(), Exqlite.defines()}
  end

  # The lines between the `exqlite SQLite defines (begin)` and `(end)` marker
  # comments (`//` in build.zig, `#` in CMakeLists.txt), trimmed.
  defp define_block(path) do
    marker = Regex.compile!(~S{^\s*(?://|#) exqlite SQLite defines \((?:begin|end)\)$}, "m")
    [_, block, _] = Regex.split(marker, File.read!(path))
    block |> String.split("\n", trim: true) |> Enum.map(&String.trim/1)
  end
end
