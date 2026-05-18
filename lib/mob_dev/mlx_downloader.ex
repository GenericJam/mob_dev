defmodule MobDev.MLXDownloader do
  @moduledoc """
  Downloads and caches pre-built Apple MLX + EMLX NIF static archives so
  iOS Mob apps can ship `EMLX.Backend` as an Nx backend without
  cross-compiling MLX themselves.

  Mirrors the `MobDev.OtpDownloader` / `MobDev.PythonAppleSupport` pattern:
  hashed URL + cached download at `~/.mob/cache/mlx-<version>-<target>/`,
  validated against the expected layout. Reused across projects.

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
  scripts in `mob_dev/scripts/release/mlx/`.
  """

  # Pinned MLX upstream version. Bump in lock-step with EMLX (deps/emlx/mix.exs
  # @mlx_version) and the cross-compile scripts in
  # scripts/release/mlx/_lib.sh.
  @mlx_version "0.25.1"

  # Distinct release tag from the OTP tarballs so MLX can move independently.
  # Repo-hosted on the same `GenericJam/mob` release surface OtpDownloader uses.
  #
  # TODO(2026-05-17): switch `@base_url` to `cocoa-xu/mlx-build/releases/...`
  # once that repo publishes iOS assets. The iOS build workflow merged
  # upstream in cocoa-xu/mlx-build#2 (GenericJam:ios-metal-builds, merged
  # 2026-05-17), but the latest release (v0.31.2) predates the workflow
  # and has no iOS assets yet. Next upstream release that triggers
  # `ios.yml` should produce `mlx-arm64-apple-ios-*.tar.gz` +
  # `mlx-arm64-apple-iossimulator-*.tar.gz` assets we can consume
  # directly, retiring our own iOS cross-compile in
  # scripts/release/mlx/. Until then we keep self-hosting.
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

    if valid_dir?(dest) do
      {:ok, dest}
    else
      # Stale or partial — clean and re-download. Same rationale as
      # OtpDownloader: previous failed extraction or schema bump.
      if File.dir?(dest), do: File.rm_rf!(dest)
      download_and_extract(target, dest)
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

  @doc "Pinned MLX upstream version (e.g. `0.25.1`)."
  @spec mlx_version() :: String.t()
  def mlx_version, do: @mlx_version

  @doc "GitHub release tag this downloader targets."
  @spec release_tag() :: String.t()
  def release_tag, do: @release_tag

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

  defp download_and_extract(target, dest_dir) do
    File.mkdir_p!(Path.dirname(dest_dir))

    with {:ok, tarball_path} <- fetch_tarball(target),
         :ok <- extract(tarball_path, dest_dir),
         :ok <- verify_layout(dest_dir) do
      # Only clean up the tarball when we downloaded it ourselves.
      # Local-override tarballs are user-managed; don't surprise them.
      if String.starts_with?(tarball_path, System.tmp_dir!()) do
        File.rm(tarball_path)
      end

      IO.puts("  Cached MLX (#{target}) at #{dest_dir}")
      {:ok, dest_dir}
    else
      {:error, reason} ->
        File.rm_rf(dest_dir)
        {:error, reason}
    end
  end

  defp fetch_tarball(target) do
    case local_tarball_dir() do
      nil -> download(target)
      dir -> use_local(target, dir)
    end
  end

  defp use_local(target, dir) do
    path = Path.join(dir, tarball_name(target))

    if File.regular?(path) do
      IO.puts("  Using local MLX tarball: #{path}")
      {:ok, path}
    else
      {:error,
       "MOB_MLX_LOCAL_TARBALL_DIR is set to #{dir} but " <>
         "#{tarball_name(target)} is not there."}
    end
  end

  defp download(target) do
    url = download_url(target)
    tmp_file = Path.join(System.tmp_dir!(), tarball_name(target))

    IO.puts("  Downloading MLX #{@mlx_version} (#{target})...")
    IO.puts("  URL: #{url}")

    case System.cmd("curl", ["-L", "--fail", "--progress-bar", "-o", tmp_file, url],
           stderr_to_stdout: false
         ) do
      {_, 0} -> {:ok, tmp_file}
      {out, rc} -> {:error, "curl failed (exit #{rc}): #{String.trim(out)}"}
    end
  end

  defp extract(tarball, dest_dir) do
    parent = Path.dirname(dest_dir)
    File.mkdir_p!(parent)

    # The tarball's top-level dir matches `name/1`, so extracting into the
    # parent of `dest_dir` lands the right layout. Verify happens afterward.
    MobDev.Download.untar(tarball, parent)
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
