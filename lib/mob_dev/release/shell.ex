defmodule MobDev.Release.Shell do
  @moduledoc """
  The I/O surface for `MobDev.Release.*` modules — every external command,
  every env-var read, every filesystem inspection that crosses out of
  Elixir's BEAM happens through a function declared here.

  ## Why this exists

  Release-script logic is mostly orchestration: "for each source file,
  call clang with these flags; then call ar; then run xcrun nm to verify
  the symbol exists." The actual *correctness* of the orchestration —
  did we pass the right flags? did we name the output file correctly? —
  is independent of whether clang itself runs. By routing every external
  invocation through a behaviour, tests can substitute a `Mox` mock that
  asserts on the exact argv we'd have invoked, without paying the
  wall-clock cost of running the real tool or depending on the host
  environment.

  Production code uses `MobDev.Release.Shell.System` (the default impl).
  Tests use `MobDev.Release.ShellMock` (defined in `test/support/`).
  Modules under `MobDev.Release.*` get the impl via application env:

      impl = Application.get_env(:mob_dev, :release_shell, MobDev.Release.Shell.System)
      impl.cmd(["clang", "-c", "x.c"], cd: "/tmp")

  Tests flip the env via `setup` to install the Mox.

  ## Contract

  Every callback returns either `{:ok, value}` or a tagged-tuple error
  from `MobDev.Release.Errors`. No callback raises on user-facing error
  paths — they all return tagged tuples so the caller chains them with
  `with`.

  Exception: programmer errors (bad argument types, etc.) may raise.
  """

  alias MobDev.Release.Errors

  @doc """
  Run an external command. Returns `{:ok, output}` on exit-0,
  `{:error, {:cmd_failed, %{cmd, exit, output}}}` otherwise.

  `opts` accepts:
    * `:cd` — working directory (default: cwd)
    * `:env` — list of `{name, value}` env overrides (default: [])
    * `:into` — passthrough to `System.cmd/3` (default: nil, output is
      captured)
  """
  @callback cmd([String.t()], keyword()) :: {:ok, String.t()} | Errors.t()

  @doc "Returns `true` if the path exists and is a directory."
  @callback dir?(Path.t()) :: boolean()

  @doc "Returns `true` if the path exists and is a regular file."
  @callback file?(Path.t()) :: boolean()

  @doc """
  Read an environment variable. Returns `{:ok, value}` if set,
  `:error` if unset. Mirrors `System.fetch_env/1` but routed through
  the behaviour so tests don't have to poke the global env.
  """
  @callback fetch_env(String.t()) :: {:ok, String.t()} | :error

  @doc "Create a directory and any missing parents. Returns `:ok` or fs_failed."
  @callback mkdir_p(Path.t()) :: :ok | Errors.t()

  @doc """
  Remove a file (best-effort). Returns `:ok` whether it existed or not,
  errors only on permission issues. Mirrors `rm -f`.
  """
  @callback rm_f(Path.t()) :: :ok | Errors.t()

  # ── Default impl resolver ─────────────────────────────────────────────

  @doc """
  Return the configured implementation module. Production: the real
  `System` impl. Tests: whatever Mox/test setup installs.
  """
  @spec impl() :: module()
  def impl, do: Application.get_env(:mob_dev, :release_shell, MobDev.Release.Shell.System)
end

defmodule MobDev.Release.Shell.System do
  @moduledoc """
  Production implementation of `MobDev.Release.Shell` — uses the real
  `System`, `File`, and OS to do work. Pure passthrough; the
  intelligence is in the callers.
  """

  @behaviour MobDev.Release.Shell

  alias MobDev.Release.Errors

  @impl true
  def cmd(argv, opts \\ []) when is_list(argv) and length(argv) >= 1 do
    [exe | args] = argv
    cmd_opts = Keyword.merge([stderr_to_stdout: true], Keyword.take(opts, [:cd, :env, :into]))

    case System.cmd(exe, args, cmd_opts) do
      {output, 0} -> {:ok, output}
      {output, exit_code} -> Errors.cmd_failed(argv, exit_code, output)
    end
  rescue
    e in ErlangError ->
      # Most common cause: executable not on $PATH. Translate to
      # precondition_failed since it's almost always an env issue.
      Errors.precondition("could not execute #{hd(argv)}: #{Exception.message(e)}")
  end

  @impl true
  def dir?(path), do: File.dir?(path)

  @impl true
  def file?(path), do: File.regular?(path)

  @impl true
  def fetch_env(name), do: System.fetch_env(name)

  @impl true
  def mkdir_p(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> Errors.fs_failed(path, reason)
    end
  end

  @impl true
  def rm_f(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> Errors.fs_failed(path, reason)
    end
  end
end
