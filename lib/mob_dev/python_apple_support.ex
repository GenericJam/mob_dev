defmodule MobDev.PythonAppleSupport do
  @moduledoc """
  Downloads and caches BeeWare's Python-Apple-support bundle so iOS
  builds can embed CPython.

  Mirrors the `MobDev.OtpDownloader` pattern: hashed URL + cached download
  at `~/.mob/cache/python-apple-support-<version>/`, validated against
  the expected `Python.xcframework` layout. Reused across projects.

  Used by `MobDev.NativeBuild` whenever the user's project depends on
  `:pythonx` — the build templates source `PYTHON_APPLE_SUPPORT` from
  `extracted_dir/0` and bundle the framework + stdlib + lib-dynload
  inside the `.app`.

  ## Scope

  Only the bare CPython runtime + standard library + standard arch-specific
  C extensions ship via this module. Third-party wheels (cryptography, RNS,
  numpy, …) are out of scope; users who need those should produce their
  own wheels with BeeWare's `mobile-forge` and drop them into their
  project. See `guides/python_embedding.md`.
  """

  # Pinned BeeWare release. Bump together with manual end-to-end validation
  # on iOS sim + device — Python releases occasionally shift the lib-dynload
  # layout or framework signing requirements.
  @python_version "3.13"
  @beeware_build "b13"
  @release_tag "#{@python_version}-#{@beeware_build}"
  @tarball_name "Python-#{@python_version}-iOS-support.#{@beeware_build}.tar.gz"
  @base_url "https://github.com/beeware/Python-Apple-support/releases/download"

  @doc """
  Ensures the BeeWare Python-Apple-support bundle is cached and extracted.
  Returns `{:ok, extracted_dir}` or `{:error, reason}`.
  """
  @spec ensure() :: {:ok, String.t()} | {:error, term()}
  def ensure do
    dir = extracted_dir()

    if valid_dir?(dir) do
      {:ok, dir}
    else
      # Stale or partial — clean and re-download. Same rationale as
      # OtpDownloader: previous failed extraction or schema bump.
      if File.dir?(dir), do: File.rm_rf!(dir)
      download_and_extract(dir)
    end
  end

  @doc """
  Returns the cached extraction directory path. May not exist if `ensure/0`
  hasn't been called.
  """
  @spec extracted_dir() :: String.t()
  def extracted_dir do
    Path.join(version_dir(), "extracted")
  end

  @doc """
  Validates that the extracted bundle has the `Python.xcframework` layout
  this module expects (both device and simulator slices, plus shared stdlib).

  Public to enable testing (per AGENTS.md convention) and to let
  `MobDev.NativeBuild` cheaply detect a partial cache.
  """
  @spec valid_dir?(String.t()) :: boolean()
  def valid_dir?(dir) do
    File.dir?(Path.join([dir, "Python.xcframework", "ios-arm64", "Python.framework"])) and
      File.dir?(
        Path.join([dir, "Python.xcframework", "ios-arm64_x86_64-simulator", "Python.framework"])
      ) and
      File.dir?(stdlib_path(dir))
  end

  @doc """
  Path to `Python.framework` inside the given extracted bundle for the
  named platform slice.

  `slice` is one of `:ios_device` (`ios-arm64/`) or `:ios_simulator`
  (`ios-arm64_x86_64-simulator/`).
  """
  @spec framework_path(String.t(), :ios_device | :ios_simulator) :: String.t()
  def framework_path(dir, :ios_device),
    do: Path.join([dir, "Python.xcframework", "ios-arm64", "Python.framework"])

  def framework_path(dir, :ios_simulator),
    do: Path.join([dir, "Python.xcframework", "ios-arm64_x86_64-simulator", "Python.framework"])

  @doc """
  Path to the shared (slice-independent) Python standard library directory.
  This is the pure-Python `os.py`, `urllib/`, etc. layout that goes under
  `PYTHONHOME/lib/python3.13/`.
  """
  @spec stdlib_path(String.t()) :: String.t()
  def stdlib_path(dir) do
    Path.join([dir, "Python.xcframework", "lib", "python#{@python_version}"])
  end

  @doc """
  Path to the arch-specific C-extension dir (`_ctypes.so`, `_ssl.so`, …).
  These live OUTSIDE the shared stdlib because they're per-slice.
  """
  @spec lib_dynload_path(String.t(), :ios_device | :ios_simulator) :: String.t()
  def lib_dynload_path(dir, :ios_device),
    do:
      Path.join([
        dir,
        "Python.xcframework",
        "ios-arm64",
        "lib-arm64",
        "python#{@python_version}",
        "lib-dynload"
      ])

  def lib_dynload_path(dir, :ios_simulator),
    do:
      Path.join([
        dir,
        "Python.xcframework",
        "ios-arm64_x86_64-simulator",
        "lib-arm64",
        "python#{@python_version}",
        "lib-dynload"
      ])

  @doc "URL the bundle is fetched from."
  @spec download_url() :: String.t()
  def download_url, do: "#{@base_url}/#{@release_tag}/#{@tarball_name}"

  @doc "Tarball file name (used for caching the downloaded artifact)."
  @spec tarball_name() :: String.t()
  def tarball_name, do: @tarball_name

  @doc "Pinned BeeWare release tag."
  @spec release_tag() :: String.t()
  def release_tag, do: @release_tag

  @doc "Pinned Python version (`3.13`, `3.14`, …)."
  @spec python_version() :: String.t()
  def python_version, do: @python_version

  # ── Private ─────────────────────────────────────────────────────────────────

  defp version_dir do
    Path.join(cache_dir(), "python-apple-support-#{@release_tag}")
  end

  defp cache_dir do
    System.get_env("MOB_CACHE_DIR") ||
      Path.join([System.get_env("HOME"), ".mob", "cache"])
  end

  defp download_and_extract(dest_dir) do
    tmp_file = Path.join(System.tmp_dir!(), @tarball_name)

    IO.puts("  Downloading BeeWare Python-Apple-support #{@release_tag}...")
    IO.puts("  URL: #{download_url()}")

    File.mkdir_p!(Path.dirname(dest_dir))

    with :ok <- download(download_url(), tmp_file),
         :ok <- extract(tmp_file, dest_dir),
         :ok <- verify_layout(dest_dir) do
      File.rm(tmp_file)
      IO.puts("  Cached at #{dest_dir}")
      {:ok, dest_dir}
    else
      {:error, reason} ->
        File.rm(tmp_file)
        File.rm_rf(dest_dir)
        {:error, reason}
    end
  end

  defp download(url, dest) do
    case System.cmd("curl", ["-L", "--fail", "--progress-bar", "-o", dest, url],
           stderr_to_stdout: false
         ) do
      {_, 0} -> :ok
      {out, rc} -> {:error, "curl failed (exit #{rc}): #{String.trim(out)}"}
    end
  end

  defp extract(tarball, dest_dir) do
    File.mkdir_p!(dest_dir)
    # BeeWare's tarball doesn't have a single top-level directory — extract
    # straight in. Verify happens afterward.
    case System.cmd("tar", ["xzf", tarball, "-C", dest_dir], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, rc} -> {:error, "tar failed (exit #{rc}): #{String.trim(out)}"}
    end
  end

  defp verify_layout(dir) do
    if valid_dir?(dir) do
      :ok
    else
      {:error,
       "Python-Apple-support extraction at #{dir} is missing expected paths.\n" <>
         "       Expected Python.xcframework with ios-arm64 + ios-arm64_x86_64-simulator\n" <>
         "       slices and shared stdlib at lib/python#{@python_version}/.\n" <>
         "       Tarball may have an unexpected layout — report at\n" <>
         "       https://github.com/GenericJam/mob_dev/issues"}
    end
  end
end
