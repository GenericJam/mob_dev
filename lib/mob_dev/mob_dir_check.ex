defmodule MobDev.MobDirCheck do
  @moduledoc """
  Detects a `mob.exs` `mob_dir` that names a different mob than the `:mob`
  dependency.

  The native build compiles mob's C/ObjC/Swift sources (`-Dmob_dir=…`) from
  `mob_dir`, while Mix compiles mob's Elixir side from the resolved `:mob`
  dependency (`Mix.Project.deps_paths()[:mob]`). When those are two checkouts,
  the app ships native code from one commit and BEAMs from another, and
  nothing fails: a fix in one half silently doesn't reach the device (MOB-351).
  Native builds stop on a mismatch; see
  `decisions/2026-10-01-mob-dir-must-match-mob-dep.md`.
  """

  # Symlink hops followed by realpath/1 before giving up on a loop (Linux's
  # MAXSYMLINKS).
  @max_symlink_hops 40

  @doc """
  Whether `mob_dir` and `dep_path` are the same directory: `:ok`, or
  `{:mismatch, mob_dir, dep_path}` with both paths expanded.

  `:ok` when either is `nil`: an unset `mob_dir` or a project without a `:mob`
  dependency has nothing to compare. Two existing directories are compared by
  identity (device + inode), so a symlinked or differently-cased path to the
  same checkout matches; otherwise by resolved real path.
  """
  @spec check(Path.t() | nil, Path.t() | nil) :: :ok | {:mismatch, Path.t(), Path.t()}
  def check(nil, _dep_path), do: :ok
  def check(_mob_dir, nil), do: :ok

  def check(mob_dir, dep_path) do
    mob_dir = Path.expand(mob_dir)
    dep_path = Path.expand(dep_path)

    if same_dir?(mob_dir, dep_path), do: :ok, else: {:mismatch, mob_dir, dep_path}
  end

  @doc """
  Raises `Mix.Error` naming both paths when the configured `mob_dir` isn't the
  current project's `:mob` dependency. Call before compiling native code.
  """
  @spec check!(Path.t() | nil) :: :ok
  def check!(mob_dir) do
    case check(mob_dir, dep_path()) do
      :ok -> :ok
      {:mismatch, mob_dir, dep_path} -> Mix.raise(message(mob_dir, dep_path))
    end
  end

  @doc "The resolved `:mob` dependency path of the current Mix project, or `nil`."
  @spec dep_path() :: Path.t() | nil
  def dep_path do
    Mix.Project.deps_paths()[:mob]
  rescue
    # Outside a Mix project there is no dependency to compare against.
    _ -> nil
  end

  @doc "The full error for a mismatch, naming both paths and the fixes."
  @spec message(Path.t(), Path.t()) :: String.t()
  def message(mob_dir, dep_path) do
    """
    mob_dir and the :mob dependency are different mob checkouts:
        mob_dir (native code is compiled from):   #{mob_dir}
        :mob dependency (Elixir code comes from): #{dep_path}
    The app would run native code from one and BEAMs from the other. If they are
    different commits it misbehaves without any error, so the native build stops here.

    #{fix(mob_dir, dep_path)}
    """
  end

  @doc "How to make the two agree."
  @spec fix(Path.t(), Path.t()) :: String.t()
  def fix(mob_dir, dep_path) do
    """
    Make both name the same checkout, either way:
      - point mob_dir at the dependency (mob.local.exs overrides mob.exs):
            config :mob_dev, mob_dir: #{inspect(dep_path)}
      - or point the dependency at mob_dir in mix.exs, then run mix deps.get:
            {:mob, path: #{inspect(mob_dir)}, override: true}\
    """
  end

  defp same_dir?(a, b) do
    case {File.stat(a), File.stat(b)} do
      {{:ok, %File.Stat{major_device: dev, inode: ino}},
       {:ok, %File.Stat{major_device: dev, inode: ino}}} ->
        true

      {{:ok, _}, {:ok, _}} ->
        false

      # At least one doesn't exist yet (e.g. a Hex dep before `mix deps.get`):
      # fall back to comparing paths with every existing symlink resolved.
      _ ->
        realpath(a) == realpath(b)
    end
  end

  # Resolves every symlink in an absolute path, component by component. Parts
  # that don't exist are kept as written. Erlang has no realpath(3).
  defp realpath(path) do
    ["/" | parts] = Path.split(path)
    resolve(parts, "/", @max_symlink_hops) || path
  end

  defp resolve([], acc, _hops), do: acc
  defp resolve(_parts, _acc, 0), do: nil
  defp resolve(["." | rest], acc, hops), do: resolve(rest, acc, hops)
  defp resolve([".." | rest], acc, hops), do: resolve(rest, Path.dirname(acc), hops)

  defp resolve([part | rest], acc, hops) do
    candidate = Path.join(acc, part)

    case :file.read_link(candidate) do
      {:ok, target} ->
        case Path.split(to_string(target)) do
          ["/" | target_parts] -> resolve(target_parts ++ rest, "/", hops - 1)
          target_parts -> resolve(target_parts ++ rest, acc, hops - 1)
        end

      {:error, _} ->
        resolve(rest, candidate, hops)
    end
  end
end
