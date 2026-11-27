defmodule MobDev.MLXDownloader do
  @moduledoc """
  Downloads and caches pre-built Apple MLX + EMLX NIF static archives so
  iOS Mob apps can ship `EMLX.Backend` as an Nx backend without
  cross-compiling MLX themselves.

  Mirrors the `MobDev.OtpDownloader` / `MobDev.PythonAppleSupport` pattern:
  pinned URL + cached download at `~/.mob/cache/libmlx-<version>-<target>/`,
  validated against the expected layout. Reused across projects. The tarball
  is checked against its SHA-256 pin in `MobDev.Download.Pins` before it is
  extracted, and a cache is reused only if it came from that tarball.

  Used by `MobDev.NativeBuild` when the project's deps include `:emlx` or
  `mob.exs` declares `mlx_enabled: true`. The build template sources
  `MLX_DIR` from `dir/1` and links `libmlx.a` + `libemlx.a` from there.

  ## Scope (v1)

  CPU-only MLX. Metal-on-iOS is gated behind a separate tarball variant
  (`libmlx-<ver>-ios-device-metal.tar.gz`) that requires the iOS-Metal
  CMakeLists patch and the Xcode Metal Toolchain installed at build
  time. v1 ships CPU + Accelerate framework — already
  ~10-50x faster than `Nx.BinaryBackend` for typical Nx workloads.

  ## Local-build override

  Set `MOB_MLX_LOCAL_TARBALL_DIR=/path/to/dir` to bypass the GitHub
  download and use locally-built tarballs (named exactly as
  `tarball_name/1` returns). Useful when iterating on the cross-compile
  scripts in `mob_dev/scripts/release/mlx/`. A local tarball is your own
  build, so it is not held to the pin; its hash is recorded instead, and
  the cache it produced is replaced once the override is unset.
  """

  # Pinned MLX upstream version. Bump in lock-step with EMLX (deps/emlx/mix.exs
  # @mlx_version) and the cross-compile scripts in
  # scripts/release/mlx/_lib.sh.
  @mlx_version "0.25.1"

  # The EMLX line the bundle's libemlx.a is compiled from
  # (scripts/release/mlx/build_emlx_nif_ios_*.sh against emlx 0.2.0's
  # c_src). The project's EMLX BEAMs must come from the same line: EMLX
  # 0.3+ changed the NIF function table, so a newer EMLX.NIF can't load
  # this NIF. `mix mob.enable mlx` writes this requirement into mix.exs.
  @emlx_requirement "~> 0.2.0"

  # Distinct release tag from the OTP tarballs so MLX can move independently.
  # Repo-hosted on the same `GenericJam/mob` release surface OtpDownloader uses.
  #
  # TODO: switch the libmlx.a half to `cocoa-xu/mlx-build/releases/...`
  # once that repo publishes iOS assets. Its `ios.yml` workflow merged
  # in cocoa-xu/mlx-build#2 (2026-05-17), but as of 2026-09-30 no release
  # (latest v0.32.0) carries `mlx-arm64-apple-ios*` assets, and it never
  # built v0.25.1, the MLX EMLX 0.2.0 needs. Upstream can't replace the
  # whole bundle anyway: libemlx.a is EMLX's NIF compiled against Mob's
  # iOS OTP, so scripts/release/mlx/ keeps producing that part. Until
  # then we self-host both, built by scripts/release/mlx/all_ios.sh and
  # uploaded by publish.sh.
  @release_tag "mlx-#{@mlx_version}"
  @base_url "https://github.com/GenericJam/mob/releases/download/#{@release_tag}"

  @typedoc "Target slice this downloader supports."
  @type target :: :ios_device | :ios_sim

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Ensure the MLX bundle for `target` is cached and extracted.
  Returns `{:ok, path}` where `path` is the unpacked root containing
  `lib/libmlx.a`, `lib/libemlx.a`, `include/mlx/...`, `VERSION`.
  """
  @spec ensure(target()) :: {:ok, String.t()} | {:error, term()}
  def ensure(target) when target in [:ios_device, :ios_sim] do
    dest = dir(target)

    with {:ok, source, sha} <- source(target) do
      if valid_dir?(dest) and MobDev.Download.verified?(dest, sha) do
        {:ok, dest}
      else
        # Partial, unverified, or extracted from a different tarball (a local
        # override, or an older mob_dev): clean and re-fetch.
        if File.dir?(dest), do: File.rm_rf!(dest)
        fetch_and_extract(target, source, sha, dest)
      end
    end
  end

  @doc "Convenience for iOS device."
  @spec ensure_ios_device() :: {:ok, String.t()} | {:error, term()}
  def ensure_ios_device, do: ensure(:ios_device)

  @doc "Convenience for iOS simulator."
  @spec ensure_ios_sim() :: {:ok, String.t()} | {:error, term()}
  def ensure_ios_sim, do: ensure(:ios_sim)

  @doc """
  Cached MLX root directory for `target`. May not exist if `ensure/1`
  hasn't been called.
  """
  @spec dir(target()) :: String.t()
  def dir(target) do
    Path.join(cache_dir(), name(target))
  end

  @doc """
  Returns true if the cache directory has the expected layout
  (`lib/libmlx.a`, `lib/libemlx.a`, `include/mlx/`, `VERSION`).

  Public for testing and so `NativeBuild` can cheaply probe for a partial
  cache without parsing the VERSION file.
  """
  @spec valid_dir?(String.t()) :: boolean()
  def valid_dir?(dir) do
    File.regular?(Path.join([dir, "lib", "libmlx.a"])) and
      File.regular?(Path.join([dir, "lib", "libemlx.a"])) and
      File.dir?(Path.join([dir, "include", "mlx"])) and
      File.regular?(Path.join([dir, "VERSION"]))
  end

  @doc """
  Path to `mlx.metallib` if this bundle ships Metal GPU kernels, or
  `nil` if it's a CPU-only bundle.

  The CPU build (`scripts/release/mlx/ios_device.sh`) doesn't produce
  a metallib. The Metal build (`ios_device_metal.sh`) puts one at
  `lib/mlx.metallib` alongside the static archives. Callers use this
  to decide whether to copy the metallib into the iOS .app bundle so
  EMLX's runtime `device: :gpu` path can find it (via MLX's
  `load_colocated_library`).
  """
  @spec metallib_path(String.t()) :: nil | String.t()
  def metallib_path(dir) do
    path = Path.join([dir, "lib", "mlx.metallib"])
    if File.regular?(path), do: path, else: nil
  end

  @doc "Bundle name (no extension, no path) for `target` — `libmlx-0.25.1-ios-device` etc."
  @spec name(target()) :: String.t()
  def name(:ios_device), do: "libmlx-#{@mlx_version}-ios-device"
  def name(:ios_sim), do: "libmlx-#{@mlx_version}-ios-sim"

  @doc "Tarball file name for `target` (e.g. `libmlx-0.25.1-ios-device.tar.gz`)."
  @spec tarball_name(target()) :: String.t()
  def tarball_name(target), do: name(target) <> ".tar.gz"

  @doc "Download URL for the `target` tarball."
  @spec download_url(target()) :: String.t()
  def download_url(target), do: "#{@base_url}/#{tarball_name(target)}"

  @doc "Every tarball URL this downloader can request."
  @spec download_urls() :: [String.t()]
  def download_urls, do: Enum.map([:ios_device, :ios_sim], &download_url/1)

  @doc "Pinned MLX upstream version (e.g. `0.25.1`)."
  @spec mlx_version() :: String.t()
  def mlx_version, do: @mlx_version

  @doc "GitHub release tag this downloader targets."
  @spec release_tag() :: String.t()
  def release_tag, do: @release_tag

  @doc """
  The `:emlx` dependency requirement this bundle's `libemlx.a` matches
  (e.g. `"~> 0.2.0"`).
  """
  @spec emlx_requirement() :: String.t()
  def emlx_requirement, do: @emlx_requirement

  @doc """
  Checks a project's resolved EMLX version against the bundle's
  `libemlx.a`. Returns `{:error, message}` with the migration steps when
  they don't match, because the app would link but `EMLX.NIF` would fail
  to load at runtime. `nil` (version couldn't be determined) passes.
  """
  @spec check_emlx_version(String.t() | nil) :: :ok | {:error, String.t()}
  def check_emlx_version(nil), do: :ok

  def check_emlx_version(vsn) when is_binary(vsn) do
    case Version.parse(vsn) do
      {:ok, version} ->
        if Version.match?(version, @emlx_requirement),
          do: :ok,
          else: {:error, emlx_mismatch_message(vsn)}

      :error ->
        {:error, "Couldn't parse the project's EMLX version #{inspect(vsn)}."}
    end
  end

  defp emlx_mismatch_message(vsn) do
    """
    EMLX #{vsn} can't use Mob's prebuilt MLX #{@mlx_version} bundle, whose
           EMLX NIF (libemlx.a) is built from EMLX #{@emlx_requirement}. The app
           would link, but EMLX.NIF would fail to load on the device.

           Pin EMLX to the bundle's line:
             1. In mix.exs set {:emlx, "#{@emlx_requirement}"}
                (or re-run `mix mob.enable mlx --yes`).
             2. mix deps.update emlx
             3. mix mob.deploy --native\
    """
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  defp cache_dir do
    System.get_env("MOB_CACHE_DIR") ||
      Path.join([System.get_env("HOME") || ".", ".mob", "cache"])
  end

  defp local_tarball_dir do
    case System.get_env("MOB_MLX_LOCAL_TARBALL_DIR") do
      nil -> nil
      "" -> nil
      v -> v
    end
  end

  # The tarball to extract and the SHA-256 its cache is recorded under: the
  # pinned release asset, or the developer's own local build.
  defp source(target) do
    case local_tarball_dir() do
      nil ->
        url = download_url(target)
        with {:ok, sha} <- MobDev.Download.pin(url), do: {:ok, {:remote, url}, sha}

      dir ->
        local_source(target, dir)
    end
  end

  defp local_source(target, dir) do
    path = Path.join(dir, tarball_name(target))

    if File.regular?(path) do
      with {:ok, sha} <- MobDev.Download.sha256_file(path), do: {:ok, {:local, path}, sha}
    else
      {:error,
       "MOB_MLX_LOCAL_TARBALL_DIR is set to #{dir} but " <>
         "#{tarball_name(target)} is not there."}
    end
  end

  defp fetch_and_extract(target, {:local, path}, sha, dest_dir) do
    IO.puts("  Using local MLX tarball: #{path}")
    unpack(target, path, sha, dest_dir)
  end

  defp fetch_and_extract(target, {:remote, url}, sha, dest_dir) do
    File.mkdir_p!(Path.dirname(dest_dir))
    tmp_file = MobDev.Download.staging_path(dest_dir, url)

    IO.puts("  Downloading MLX #{@mlx_version} (#{target})...")
    IO.puts("  URL: #{url}")

    result =
      with :ok <- MobDev.Download.fetch_verified(url, tmp_file, sha),
           do: unpack(target, tmp_file, sha, dest_dir)

    File.rm(tmp_file)
    result
  end

  # The tarball's single top-level dir is `name/1`; strip it into `dest_dir`.
  defp unpack(target, tarball, sha, dest_dir) do
    File.mkdir_p!(dest_dir)

    with :ok <- MobDev.Download.untar(tarball, dest_dir, strip_components: 1),
         :ok <- verify_layout(dest_dir),
         :ok <- MobDev.Download.mark_verified(dest_dir, sha) do
      IO.puts("  Cached MLX (#{target}) at #{dest_dir}")
      {:ok, dest_dir}
    else
      {:error, reason} ->
        File.rm_rf(dest_dir)
        {:error, reason}
    end
  end

  defp verify_layout(dir) do
    if valid_dir?(dir) do
      :ok
    else
      {:error,
       "MLX bundle at #{dir} is missing expected paths.\n" <>
         "       Expected lib/libmlx.a, lib/libemlx.a, include/mlx/, VERSION.\n" <>
         "       Tarball may have an unexpected layout."}
    end
  end
end
