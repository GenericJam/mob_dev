defmodule MobDev.Download do
  @moduledoc false

  # Tiny wrappers around `curl` and `tar` so the various downloaders
  # (OTP, Python apple/android, MLX) don't all reimplement the same
  # `System.cmd` + error pattern.

  @doc """
  Fetch `url` to `dest` via curl.
  """
  @spec curl(String.t(), Path.t()) :: :ok | {:error, String.t()}
  def curl(url, dest) do
    case System.cmd("curl", ["-L", "--fail", "--progress-bar", "-o", dest, url],
           stderr_to_stdout: false
         ) do
      {_, 0} -> :ok
      {out, rc} -> {:error, "curl failed (exit #{rc}): #{String.trim(out)}"}
    end
  end

  @doc """
  Extract `tarball` into `dest_dir` via `tar xzf`.
  """
  @spec untar(Path.t(), Path.t()) :: :ok | {:error, String.t()}
  def untar(tarball, dest_dir) do
    case System.cmd("tar", ["xzf", tarball, "-C", dest_dir], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, rc} -> {:error, "tar failed (exit #{rc}): #{String.trim(out)}"}
    end
  end
end
