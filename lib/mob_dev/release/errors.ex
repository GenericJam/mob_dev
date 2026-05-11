defmodule MobDev.Release.Errors do
  @moduledoc """
  Typed error tags used across the `MobDev.Release.*` modules.

  These exist for one specific reason: when the release pipeline fails in
  production, the caller needs to instantly distinguish "it's our bug"
  from "it's an external infra issue" from "the user's environment isn't
  set up right." Shell scripts blob all three together as `exit 1`; this
  module gives every release function a tagged-tuple shape so the
  top-level Mix task can format an actionable message.

  ## Categories

  Each error is `{:error, {category, detail}}`. The category is one of:

    * `:precondition_failed` — a checked precondition didn't hold
      *before* we did real work. Example: `OTP_SRC` not a git repo,
      `OPENSSL_PREFIX` not yet built, `$ANDROID_NDK_ROOT` missing.
      **Caller action:** fix the environment, retry.

    * `:cmd_failed` — an external command exited nonzero. Detail
      includes the command, exit code, and captured output.
      **Caller action:** read the output. If it looks like our code's
      fault, file a bug; if it looks like the tool's fault, escalate.

    * `:parse_failed` — output we expected to parse didn't match. This
      is almost always our bug — a tool's output format drifted or our
      regex was wrong.
      **Caller action:** file a bug.

    * `:fs_failed` — a filesystem operation failed. Detail carries the
      `:file.posix` reason.
      **Caller action:** check the path; if `eacces`/`enospc` etc.,
      it's environmental.

    * `:infra_unreachable` — a network/GH/etc. operation failed. Carries
      the HTTP status or transport error.
      **Caller action:** check status.github.com / status.hex.pm. Not
      our bug.

    * `:auth_required` — credentials missing or expired. Carries a hint
      about which credential needs renewal.
      **Caller action:** run the auth refresh command we suggest.

  ## Convenience helpers

  Each category has a constructor and a guard. Use the constructors in
  return values; pattern-match on the tag in the formatter.

      def foo do
        with {:ok, hash} <- read_hash(),
             {:ok, _} <- validate(hash) do
          {:ok, hash}
        end
      end

      # In the Mix task:
      case Release.full() do
        {:ok, _} -> :ok
        {:error, {:precondition_failed, msg}} -> Mix.raise(msg)
        {:error, {:auth_required, hint}} -> Mix.raise("auth: " <> hint)
        {:error, other} -> Mix.raise("release failed: " <> inspect(other))
      end
  """

  @type category ::
          :precondition_failed
          | :cmd_failed
          | :parse_failed
          | :fs_failed
          | :infra_unreachable
          | :auth_required

  @type detail :: term()

  @type t :: {:error, {category(), detail()}}

  # ── Constructors ─────────────────────────────────────────────────────────

  @doc "Build a precondition_failed error. `msg` should be human-readable."
  @spec precondition(String.t()) :: t()
  def precondition(msg) when is_binary(msg), do: {:error, {:precondition_failed, msg}}

  @doc """
  Build a cmd_failed error. Captures the command's argv, exit code, and
  the head of its captured output (truncated to avoid pinning huge build
  logs to memory).
  """
  @spec cmd_failed([String.t()], non_neg_integer(), String.t()) :: t()
  def cmd_failed(argv, exit_code, output) when is_list(argv) and is_integer(exit_code) do
    {:error, {:cmd_failed, %{cmd: argv, exit: exit_code, output: truncate(output)}}}
  end

  @doc "Build a parse_failed error. `expected` describes what we tried to parse."
  @spec parse_failed(term(), String.t()) :: t()
  def parse_failed(input, expected) when is_binary(expected) do
    {:error, {:parse_failed, %{input: input, expected: expected}}}
  end

  @doc "Build an fs_failed error. `reason` is the `:file` posix atom."
  @spec fs_failed(Path.t(), atom()) :: t()
  def fs_failed(path, reason) when is_atom(reason) do
    {:error, {:fs_failed, %{path: path, reason: reason}}}
  end

  @doc "Build an infra_unreachable error. Detail is opaque (HTTP status, transport error, etc.)."
  @spec infra_unreachable(term()) :: t()
  def infra_unreachable(detail), do: {:error, {:infra_unreachable, detail}}

  @doc "Build an auth_required error. `hint` should suggest the renewal command."
  @spec auth_required(String.t()) :: t()
  def auth_required(hint) when is_binary(hint), do: {:error, {:auth_required, hint}}

  # ── Formatter ────────────────────────────────────────────────────────────

  @doc """
  Format a tagged error for end-user display. Returns a string suitable
  for passing to `Mix.raise/1` or `IO.puts/1`. Uses the category to
  produce an actionable message.

      iex> MobDev.Release.Errors.format({:error, {:precondition_failed, "OTP_SRC missing"}})
      "precondition failed — OTP_SRC missing"
  """
  @spec format(t()) :: String.t()
  def format({:error, {:precondition_failed, msg}}) do
    "precondition failed — #{msg}"
  end

  def format({:error, {:cmd_failed, %{cmd: cmd, exit: exit, output: out}}}) do
    """
    command failed (exit #{exit}):
      #{Enum.join(cmd, " ")}
    output:
    #{indent(out, "      ")}\
    """
  end

  def format({:error, {:parse_failed, %{input: input, expected: expected}}}) do
    "parse failed — expected #{expected}, got: #{inspect(input, limit: 50)}"
  end

  def format({:error, {:fs_failed, %{path: path, reason: reason}}}) do
    "filesystem error at #{path}: #{reason}"
  end

  def format({:error, {:infra_unreachable, detail}}) do
    "external infrastructure unreachable: #{inspect(detail)}"
  end

  def format({:error, {:auth_required, hint}}) do
    "authentication required — #{hint}"
  end

  # ── Internals ────────────────────────────────────────────────────────────

  @max_output_bytes 4_000

  defp truncate(output) when is_binary(output) do
    if byte_size(output) > @max_output_bytes do
      head = binary_part(output, 0, @max_output_bytes)
      head <> "\n... (truncated, full output was #{byte_size(output)} bytes)"
    else
      output
    end
  end

  defp truncate(other), do: inspect(other)

  defp indent(text, prefix) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", &(prefix <> &1))
  end
end
