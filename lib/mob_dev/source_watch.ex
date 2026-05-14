defmodule MobDev.SourceWatch do
  @moduledoc false

  # Helpers shared by `mix mob.watch` and `MobDev.Server.WatchWorker` —
  # both need a snapshot of `lib/**/*.ex` mtimes plus a diff against a
  # previous snapshot. Each had its own copy until ex_dna flagged them.

  @doc """
  Take a snapshot of every `lib/**/*.ex` file's mtime (posix seconds).
  Files that fail to stat get an mtime of 0.
  """
  @spec snapshot() :: %{Path.t() => integer()}
  def snapshot do
    Map.new(Path.wildcard("lib/**/*.ex"), fn path ->
      mtime =
        case File.stat(path, time: :posix) do
          {:ok, %{mtime: t}} -> t
          _ -> 0
        end

      {path, mtime}
    end)
  end

  @doc """
  Return the file paths whose mtime in `current` differs from `old`.
  """
  @spec diff(map(), map()) :: [Path.t()]
  def diff(old, current) do
    current
    |> Enum.filter(fn {path, mtime} -> Map.get(old, path) != mtime end)
    |> Enum.map(&elem(&1, 0))
  end
end
