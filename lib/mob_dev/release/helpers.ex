defmodule MobDev.Release.Helpers do
  @moduledoc """
  Replaces the two `scripts/release/_lib.sh` files. Pure functions where
  possible; side-effectful ones are narrow + testable via tmpdir fixtures.

  ## Why this lives in Elixir rather than shell

  The single big reason is **bugs surface in CI rather than in user
  inboxes**. The shell version's failure path is "user runs release →
  obscure error → reports issue → maintainer can't reproduce locally →
  long discovery cycle." This module's failure path is "CI test fails
  → fix → ship." See `MobDev.Release.Errors` for the typed error tags
  that make distinguishing "our bug" from "user env" from "infra down"
  cheap at the call site.

  ## Single source of truth conventions

  The shell `_lib.sh` mirrored constants from Elixir modules
  (`MobDev.NdkVersion`, etc.). This module *is* the source — no
  mirroring. When something downstream needs the recommended NDK
  version, it calls `MobDev.NdkVersion.effective/0` directly.
  """

  alias MobDev.Release.Errors

  @typedoc "Absolute path to an OTP source checkout (e.g. ~/code/otp)."
  @type otp_src :: Path.t()

  @hash_length 8

  # ── HASH detection ───────────────────────────────────────────────────────

  @doc """
  Detect the short git hash of the OTP source tree at `otp_src`. Used as
  the release-asset tag suffix (e.g. `otp-android-<hash>.tar.gz`).

  Pinned to 8 characters so tarball filenames, GitHub release tags, and
  the `@otp_hash` constant in `MobDev.OtpDownloader` all stay in
  lockstep. Git's default `--short` length grows over time (collision
  avoidance) so without pinning the names would silently drift.

  Returns `{:ok, "8hexchars"}` on success or a tagged error.
  """
  @spec git_hash(otp_src()) :: {:ok, String.t()} | Errors.t()
  def git_hash(otp_src) do
    git_dir = Path.join(otp_src, ".git")

    if File.dir?(git_dir) or File.regular?(git_dir) do
      run_git_hash(otp_src)
    else
      Errors.precondition("OTP_SRC (#{otp_src}) is not a git checkout — pass `hash:` explicitly")
    end
  end

  defp run_git_hash(otp_src) do
    case System.cmd("git", ["-C", otp_src, "rev-parse", "--short=#{@hash_length}", "HEAD"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        parse_git_hash(output)

      {output, exit_code} ->
        Errors.cmd_failed(
          ["git", "-C", otp_src, "rev-parse", "--short=#{@hash_length}", "HEAD"],
          exit_code,
          output
        )
    end
  end

  @doc """
  Parse a git short-hash from `git rev-parse` output. Trims whitespace
  and validates that the result is exactly `@hash_length` hex chars.

  Public for testing — the regex/length contract is the surface we want
  to lock down with examples, and a pure function is the cleanest way.
  """
  @spec parse_git_hash(binary()) :: {:ok, String.t()} | Errors.t()
  def parse_git_hash(output) when is_binary(output) do
    trimmed = String.trim(output)

    if hex_chars?(trimmed) and String.length(trimmed) == @hash_length do
      {:ok, trimmed}
    else
      Errors.parse_failed(output, "#{@hash_length}-char hex string from `git rev-parse --short`")
    end
  end

  defp hex_chars?(s), do: Regex.match?(~r/^[0-9a-f]+$/, s)

  # ── ERTS version detection ───────────────────────────────────────────────

  @doc """
  Read the ERTS version (e.g. `"17.0"`) from `<otp_src>/erts/vsn.mk`.
  The file format is one line `VSN = 17.0` plus comments.

  Returns `{:ok, "17.0"}` on success or a tagged error.
  """
  @spec erts_version(otp_src()) :: {:ok, String.t()} | Errors.t()
  def erts_version(otp_src) do
    path = Path.join([otp_src, "erts", "vsn.mk"])

    case File.read(path) do
      {:ok, content} -> parse_erts_version(content)
      {:error, reason} -> Errors.fs_failed(path, reason)
    end
  end

  @doc """
  Parse the `VSN = <version>` line out of an erts/vsn.mk-shaped file.

  Public for testing — version-string drift between OTP releases is
  exactly the kind of regression that should fail loudly with a clear
  message rather than silently producing tarballs named with a missing
  version suffix.
  """
  @spec parse_erts_version(binary()) :: {:ok, String.t()} | Errors.t()
  def parse_erts_version(content) when is_binary(content) do
    case Regex.run(~r/^\s*VSN\s*=\s*(\S+)\s*$/m, content, capture: :all_but_first) do
      [vsn] -> {:ok, vsn}
      _ -> Errors.parse_failed(content, "a line of the form `VSN = <version>`")
    end
  end

  # ── Elixir lib dir ───────────────────────────────────────────────────────

  @doc """
  Return the host Elixir's lib dir — the parent directory containing
  `elixir/`, `logger/`, `eex/` as sibling app dirs. Used to bundle the
  Elixir stdlib into the release tarball.

  Shell equivalent:

      ELIXIR_LIB=$(elixir -e "IO.puts(:code.lib_dir(:elixir))" | xargs dirname)

  Here we just call `:code.lib_dir/1` directly — no subprocess hop.
  """
  @spec elixir_lib_dir() :: {:ok, Path.t()} | Errors.t()
  def elixir_lib_dir do
    case :code.lib_dir(:elixir) do
      {:error, :bad_name} ->
        Errors.precondition("Elixir lib dir not found via :code.lib_dir(:elixir)")

      path when is_list(path) ->
        {:ok, path |> List.to_string() |> Path.dirname()}
    end
  end

  # ── Elixir stdlib bundler ────────────────────────────────────────────────

  @stdlib_apps ~w(elixir logger eex)

  @doc """
  Copy the Elixir stdlib apps (`elixir`, `logger`, `eex`) from the host's
  Elixir installation into the release stage directory. Mirrors
  `_lib.sh`'s `bundle_elixir_stdlib()` function.

  Bytecode is arch-independent, so the same source works for all
  platform tarballs. Caller is responsible for creating the stage
  directory.

  Returns `{:ok, [bundled_app_dirs]}` or a tagged error.
  """
  @spec bundle_elixir_stdlib(Path.t(), Path.t()) :: {:ok, [Path.t()]} | Errors.t()
  def bundle_elixir_stdlib(stage_dir, elixir_lib_dir) do
    if not File.dir?(elixir_lib_dir) do
      Errors.fs_failed(elixir_lib_dir, :enoent)
    else
      do_bundle_elixir_stdlib(stage_dir, elixir_lib_dir)
    end
  end

  defp do_bundle_elixir_stdlib(stage_dir, elixir_lib_dir) do
    Enum.reduce_while(@stdlib_apps, {:ok, []}, fn app, {:ok, acc} ->
      src = Path.join([elixir_lib_dir, app, "ebin"])
      dst = Path.join([stage_dir, "lib", app, "ebin"])

      with true <- File.dir?(src) || {:fs, src, :enoent},
           :ok <- File.mkdir_p(dst),
           {:ok, _} <- File.cp_r(src, dst) do
        {:cont, {:ok, [dst | acc]}}
      else
        {:fs, path, reason} -> {:halt, Errors.fs_failed(path, reason)}
        {:error, reason} when is_atom(reason) -> {:halt, Errors.fs_failed(dst, reason)}
        {:error, {:enoent, posix}} -> {:halt, Errors.fs_failed(dst, posix)}
        other -> {:halt, Errors.precondition("unexpected: #{inspect(other)}")}
      end
    end)
    |> case do
      {:ok, dirs} -> {:ok, Enum.reverse(dirs)}
      err -> err
    end
  end

  # ── Output directory + defaults ──────────────────────────────────────────

  @doc """
  Default OTP source path (mirrors `_lib.sh`'s `${OTP_SRC:=$HOME/code/otp}`).
  Resolved per-call rather than at module load so test setups can swap
  `$HOME` via `System.put_env/2`.
  """
  @spec default_otp_src() :: Path.t()
  def default_otp_src do
    case System.fetch_env("OTP_SRC") do
      {:ok, path} -> path
      :error -> Path.join(System.user_home!(), "code/otp")
    end
  end

  @doc """
  Default tarball output directory (mirrors `_lib.sh`'s `${OUT_DIR:=/tmp}`).
  """
  @spec default_out_dir() :: Path.t()
  def default_out_dir do
    System.get_env("OUT_DIR", "/tmp")
  end

  # ── One-shot resolver for the common case ────────────────────────────────

  @doc """
  Collapse the per-piece resolvers into one struct-shaped return.
  Convenience for callers that want all of `{otp_src, hash, erts_vsn,
  elixir_lib, out_dir}` resolved in one go.

  Honours these env vars (in the same order `_lib.sh` did):

    * `OTP_SRC` — overrides default otp source path
    * `OUT_DIR` — overrides default tarball output dir
    * `HASH`    — pre-set hash, skips git detection
    * `ERTS_VSN` — pre-set erts version, skips vsn.mk parsing

  Returns `{:ok, %{otp_src: ..., hash: ..., erts_vsn: ..., elixir_lib:
  ..., out_dir: ...}}` or the first error encountered.
  """
  @spec resolve_release_env(keyword()) :: {:ok, map()} | Errors.t()
  def resolve_release_env(opts \\ []) do
    otp_src = Keyword.get(opts, :otp_src) || default_otp_src()
    out_dir = Keyword.get(opts, :out_dir) || default_out_dir()

    with {:ok, hash} <- resolve_hash(opts, otp_src),
         {:ok, erts_vsn} <- resolve_erts_vsn(opts, otp_src),
         {:ok, elixir_lib} <- elixir_lib_dir() do
      {:ok,
       %{
         otp_src: otp_src,
         out_dir: out_dir,
         hash: hash,
         erts_vsn: erts_vsn,
         elixir_lib: elixir_lib
       }}
    end
  end

  defp resolve_hash(opts, otp_src) do
    case Keyword.get(opts, :hash) || System.get_env("HASH") do
      nil -> git_hash(otp_src)
      hash -> {:ok, hash}
    end
  end

  defp resolve_erts_vsn(opts, otp_src) do
    case Keyword.get(opts, :erts_vsn) || System.get_env("ERTS_VSN") do
      nil -> erts_version(otp_src)
      vsn -> {:ok, vsn}
    end
  end
end
