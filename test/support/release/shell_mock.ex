# Mox-defined mock for `MobDev.Release.Shell`. Loaded automatically as
# part of `test/support/` (see mix.exs elixirc_paths(:test)) so the
# module `MobDev.Release.ShellMock` is available to every test in the
# `MobDev.Release.*` suite without an explicit require.
#
# Usage in a test:
#
#     import Mox
#
#     setup :verify_on_exit!
#     setup do
#       Application.put_env(:mob_dev, :release_shell, MobDev.Release.ShellMock)
#       on_exit(fn -> Application.delete_env(:mob_dev, :release_shell) end)
#     end
#
#     test "..." do
#       Mox.expect(MobDev.Release.ShellMock, :cmd, fn argv, _opts ->
#         assert argv == ["clang", "-c", "x.c"]
#         {:ok, ""}
#       end)
#       ...
#     end

Mox.defmock(MobDev.Release.ShellMock, for: MobDev.Release.Shell)
