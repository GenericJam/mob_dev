defmodule MobDev.Release.Publish do
  @moduledoc """
  Replaces `scripts/release/publish.sh` — uploads built tarballs to a
  GitHub release tagged `otp-<hash>`. The release is created if it
  doesn't exist; existing assets with matching names are deleted before
  upload (`gh release upload` won't replace by default).

  ## Why this module carries the most error categories

  Of the five `MobDev.Release.*` orchestrators this is the one most
  likely to fail through no fault of ours — GitHub goes down, `gh`
  auth expires, the local network drops. The shell version of this
  step blobs all of those together as `exit 1`; the user can't tell
  whether it's their problem or ours. This module classifies every
  `gh` failure into one of:

    * `:auth_required` — gh CLI isn't authenticated, or token lacks
      `repo` scope. Hint suggests
      `gh auth login --scopes "repo,write:packages"`.
    * `:infra_unreachable` — GitHub returned 5xx or the network's
      down. Detail carries the first line of `gh`'s stderr so it's
      obvious what to check on status.github.com.
    * `:precondition_failed` — no tarballs in `out_dir` matching
      `hash`. Hint points the user at `mix mob.release.tarball all`.
    * `:cmd_failed` — fallback for unexpected `gh` failures (e.g.
      malformed tag, write permission denied on a non-our repo).

  This is exactly the "is GitHub down or am I broken?" distinction the
  build-system migration plan called for. Test coverage exercises each
  category against a representative `gh` stderr snippet.

  ## Public API

      MobDev.Release.Publish.publish()                    # defaults
      MobDev.Release.Publish.publish(repo: "fork/mob")    # publish to fork
      MobDev.Release.Publish.publish(assets: ["otp-android"])  # subset

  Returns `{:ok, %{tag, repo, assets}}` on success or a tagged error.

  ## What it does end-to-end

    1. Resolve `repo`, `hash`, `out_dir` (env or opts).
    2. Discover which of the four canonical tarball basenames are
       present in `out_dir` for this hash. At least one must exist.
    3. `gh release view otp-<hash>` — exists?
       - If not (`release not found`), `gh release create`.
       - If 401/403, `:auth_required`.
       - If 5xx/network, `:infra_unreachable`.
    4. List the release's existing assets. For each one that overlaps
       with what we're about to upload, `gh release delete-asset`.
    5. Single `gh release upload otp-<hash> <paths…>`.
    6. Verify by re-listing assets — returned in `info.assets`.
  """

  alias MobDev.Release.{Errors, Helpers, Shell}

  @default_repo "GenericJam/mob"
  @candidate_basenames [
    "otp-android",
    "otp-android-arm32",
    "otp-ios-sim",
    "otp-ios-device"
  ]

  @typedoc "Successful publish result."
  @type info :: %{tag: String.t(), repo: String.t(), assets: [String.t()]}

  @doc "Canonical tarball basenames the publisher knows how to upload."
  @spec candidate_basenames() :: [String.t()]
  def candidate_basenames, do: @candidate_basenames

  @doc "Default GitHub repo (mirrors publish.sh's `${REPO:=GenericJam/mob}`)."
  @spec default_repo() :: String.t()
  def default_repo, do: @default_repo

  @doc """
  Run the publish pipeline. See module doc for options.

  Recognized opts:

    * `:repo` — `owner/name` (default: `GenericJam/mob`)
    * `:hash` — release hash. Default: detected from `OTP_SRC` git or `$HASH`.
    * `:otp_src` — OTP checkout for hash detection. Default per `Helpers`.
    * `:out_dir` — directory containing the built tarballs. Default per `Helpers`.
    * `:assets` — list of tarball basenames to upload. Each may be
      either the bare base (`"otp-android"`) — in which case
      `-<hash>.tar.gz` is appended — or the full filename. Default:
      auto-discover any of the four canonical names that exist.
  """
  @spec publish(keyword()) :: {:ok, info()} | Errors.t()
  def publish(opts \\ []) do
    shell = Shell.impl()
    repo = opts[:repo] || @default_repo
    out_dir = opts[:out_dir] || Helpers.default_out_dir()

    with {:ok, hash} <- resolve_hash(opts),
         tag = tag_for(hash),
         {:ok, assets} <- resolve_assets(shell, opts, out_dir, hash),
         :ok <- ensure_release(shell, repo, tag, hash),
         {:ok, existing} <- list_assets(shell, repo, tag),
         :ok <- delete_existing(shell, repo, tag, existing, assets),
         :ok <- upload_assets(shell, repo, tag, out_dir, assets),
         {:ok, uploaded} <- list_assets(shell, repo, tag) do
      {:ok, %{tag: tag, repo: repo, assets: uploaded}}
    end
  end

  @doc """
  Asset basenames that exist in `out_dir` for the given `hash`. Returns
  an ordered list (matching `candidate_basenames/0` order).
  """
  @spec discover_assets(module(), Path.t(), String.t()) :: [String.t()]
  def discover_assets(shell, out_dir, hash) when is_binary(hash) do
    @candidate_basenames
    |> Enum.map(&"#{&1}-#{hash}.tar.gz")
    |> Enum.filter(&shell.file?(Path.join(out_dir, &1)))
  end

  @doc """
  Classify a `gh` stderr/stdout line into one of `:not_found`, `:auth`,
  `:infra`, or `:other`. Public for testing — the regexes are the
  contract.
  """
  @spec classify(String.t()) :: :not_found | :auth | :infra | :other
  def classify(output) when is_binary(output) do
    lower = String.downcase(output)

    cond do
      not_found?(lower) -> :not_found
      auth?(lower) -> :auth
      infra?(lower) -> :infra
      true -> :other
    end
  end

  @doc "Build the release tag for a hash (`otp-<hash>`)."
  @spec tag_for(String.t()) :: String.t()
  def tag_for(hash) when is_binary(hash), do: "otp-#{hash}"

  # ── Hash + asset resolution ────────────────────────────────────────────

  defp resolve_hash(opts) do
    case opts[:hash] || System.get_env("HASH") do
      nil ->
        otp_src = opts[:otp_src] || Helpers.default_otp_src()
        Helpers.git_hash(otp_src)

      hash ->
        {:ok, hash}
    end
  end

  defp resolve_assets(shell, opts, out_dir, hash) do
    case opts[:assets] do
      [_ | _] = explicit ->
        explicit_assets(shell, explicit, out_dir, hash)

      _ ->
        discovered_assets(shell, out_dir, hash)
    end
  end

  defp explicit_assets(shell, bases, out_dir, hash) do
    filenames = Enum.map(bases, &normalize_basename(&1, hash))
    missing = Enum.reject(filenames, &shell.file?(Path.join(out_dir, &1)))

    if missing == [] do
      {:ok, filenames}
    else
      Errors.precondition(
        "missing tarballs in #{out_dir}: #{Enum.join(missing, ", ")} — " <>
          "run `mix mob.release.tarball <target>` first"
      )
    end
  end

  defp discovered_assets(shell, out_dir, hash) do
    case discover_assets(shell, out_dir, hash) do
      [] ->
        Errors.precondition(
          "no tarballs found in #{out_dir} matching hash #{hash} — " <>
            "run `mix mob.release.tarball all` first"
        )

      assets ->
        {:ok, assets}
    end
  end

  defp normalize_basename(name, hash) do
    if String.ends_with?(name, ".tar.gz"), do: name, else: "#{name}-#{hash}.tar.gz"
  end

  # ── Release lifecycle ──────────────────────────────────────────────────

  defp ensure_release(shell, repo, tag, hash) do
    case shell.cmd(["gh", "release", "view", tag, "--repo", repo], []) do
      {:ok, _} ->
        :ok

      {:error, {:cmd_failed, %{output: output}}} = err ->
        case classify(output) do
          :not_found -> create_release(shell, repo, tag, hash)
          :auth -> Errors.auth_required(auth_hint())
          :infra -> Errors.infra_unreachable(infra_detail(output))
          :other -> err
        end

      err ->
        err
    end
  end

  defp create_release(shell, repo, tag, hash) do
    title = "OTP pre-built runtime #{hash}"

    notes =
      "Pre-built OTP for Android (aarch64 + arm32), iOS simulator " <>
        "(aarch64-apple-iossimulator), and iOS device (aarch64-apple-ios). " <>
        "OTP source commit: #{hash}."

    argv = [
      "gh",
      "release",
      "create",
      tag,
      "--repo",
      repo,
      "--title",
      title,
      "--notes",
      notes
    ]

    case shell.cmd(argv, []) do
      {:ok, _} -> :ok
      err -> reclassify(err)
    end
  end

  defp list_assets(shell, repo, tag) do
    argv = [
      "gh",
      "release",
      "view",
      tag,
      "--repo",
      repo,
      "--json",
      "assets",
      "-q",
      ".assets[].name"
    ]

    case shell.cmd(argv, []) do
      {:ok, output} ->
        names =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        {:ok, names}

      err ->
        reclassify(err)
    end
  end

  defp delete_existing(shell, repo, tag, existing, planned) do
    to_delete = Enum.filter(planned, &(&1 in existing))

    Enum.reduce_while(to_delete, :ok, fn name, :ok ->
      argv = ["gh", "release", "delete-asset", tag, name, "--repo", repo, "--yes"]

      case shell.cmd(argv, []) do
        {:ok, _} -> {:cont, :ok}
        err -> {:halt, reclassify(err)}
      end
    end)
  end

  defp upload_assets(shell, repo, tag, out_dir, assets) do
    paths = Enum.map(assets, &Path.join(out_dir, &1))
    argv = ["gh", "release", "upload", tag, "--repo", repo] ++ paths

    case shell.cmd(argv, []) do
      {:ok, _} -> :ok
      err -> reclassify(err)
    end
  end

  # ── Error classification ───────────────────────────────────────────────

  defp not_found?(s) do
    String.contains?(s, "release not found") or
      String.contains?(s, "no release found") or
      String.contains?(s, "could not find release") or
      String.contains?(s, "http 404")
  end

  defp auth?(s) do
    String.contains?(s, "http 401") or
      String.contains?(s, "http 403") or
      String.contains?(s, "bad credentials") or
      String.contains?(s, "must authenticate") or
      String.contains?(s, "you are not logged into") or
      String.contains?(s, "to get started with github cli") or
      String.contains?(s, "gh auth login")
  end

  defp infra?(s) do
    String.contains?(s, "http 5") or
      String.contains?(s, "no such host") or
      String.contains?(s, "connection refused") or
      String.contains?(s, "i/o timeout") or
      String.contains?(s, "dial tcp") or
      String.contains?(s, "could not connect") or
      String.contains?(s, "network is unreachable")
  end

  defp reclassify({:error, {:cmd_failed, %{output: output}}} = err) do
    case classify(output) do
      :auth -> Errors.auth_required(auth_hint())
      :infra -> Errors.infra_unreachable(infra_detail(output))
      _ -> err
    end
  end

  defp reclassify(other), do: other

  defp auth_hint do
    ~s(run `gh auth login --scopes "repo,write:packages"` and retry)
  end

  defp infra_detail(output) do
    case output |> String.split("\n", trim: true) |> List.first() do
      nil -> "gh returned 5xx or network unreachable"
      line -> String.trim(line)
    end
  end
end
