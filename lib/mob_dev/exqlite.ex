defmodule MobDev.Exqlite do
  @moduledoc """
  The compile-time defines mob builds exqlite's SQLite amalgamation with.

  On the host, exqlite compiles `sqlite3.c` with its own Makefile, which
  enables FTS3/4/5, R*Tree, Geopoly, math functions and more. On a phone,
  mob compiles the same amalgamation itself (the iOS simulator `.so`, the
  iOS device `.a`, `mix mob.release --ios`), and the generated Android
  `build.zig` / `CMakeLists.txt` do the same. Every one of those builds uses
  this set, so the device SQLite has the features host tests rely on: an
  FTS5 table that works under `mix test` also works on the phone (MOB-487).

  The list is exqlite's Makefile `CFLAGS += -D…` lines, verbatim and in
  order, including the unprefixed ones (`ENABLE_STAT4`, …) that SQLite
  ignores; `MobDev.ExqliteTest` pins it against the locked exqlite's
  Makefile. mob_new's Android templates carry the same lines (it is a
  self-contained archive and can't call this module); the same test keeps
  them in sync.
  """

  @defines [
    "SQLITE_THREADSAFE=1",
    "SQLITE_USE_URI=1",
    "SQLITE_LIKE_DOESNT_MATCH_BLOBS=1",
    "SQLITE_DQS=0",
    "HAVE_USLEEP=1",
    "ALLOW_COVERING_INDEX_SCAN=1",
    "ENABLE_FTS3_PARENTHESIS=1",
    "ENABLE_LOAD_EXTENSION=1",
    "ENABLE_SOUNDEX=1",
    "ENABLE_STAT4=1",
    "ENABLE_UPDATE_DELETE_LIMIT=1",
    "SQLITE_ENABLE_FTS3=1",
    "SQLITE_ENABLE_FTS4=1",
    "SQLITE_ENABLE_FTS5=1",
    "SQLITE_ENABLE_GEOPOLY=1",
    "SQLITE_ENABLE_MATH_FUNCTIONS=1",
    "SQLITE_ENABLE_RBU=1",
    "SQLITE_ENABLE_RTREE=1",
    "SQLITE_OMIT_DEPRECATED=1",
    "SQLITE_ENABLE_DBSTAT_VTAB=1"
  ]

  @doc "The defines, as `NAME=VALUE` strings."
  @spec defines() :: [String.t()]
  def defines, do: @defines

  @doc "The defines as compiler flags (`-DNAME=VALUE`)."
  @spec cflags() :: [String.t()]
  def cflags, do: Enum.map(@defines, &("-D" <> &1))
end
