defmodule MobDev.PythonAndroidSupport do
  @moduledoc """
  Downloads and caches a Chaquopy CPython distribution so Android builds
  can embed Python.

  ## Why Chaquopy

  Chaquopy is currently the only actively-maintained source of pre-built
  CPython binaries for Android. BeeWare's `Python-Android-support`
  (the iOS sibling we already use) hasn't shipped a Python 3.11+ release.
  Chaquopy is Apache 2.0 (since 2025), publishes to Maven Central, and
  ships exactly the .so files we need:

      target-VSN-arm64-v8a.zip:
        jniLibs/arm64-v8a/libpython3.13.so          ← interpreter
        jniLibs/arm64-v8a/libcrypto_python.so       ← OpenSSL crypto
        jniLibs/arm64-v8a/libssl_python.so          ← OpenSSL SSL
        jniLibs/arm64-v8a/libsqlite3_python.so      ← bundled SQLite
        lib-dynload/arm64-v8a/*.so                  ← C extensions
        include/python3.13/                         ← headers (NIF compile)

      target-VSN-stdlib.zip:
        os.py, urllib/, email/, …                   ← shared pure-Python

      target-VSN-x86_64.zip:
        Same as arm64-v8a but for x86_64 emulator slice.

  We only use these binaries — Chaquopy's Java<->Python bridge is bypassed.
  Pythonx's NIF dlopens libpython3.13.so directly via the same path
  contract as iOS, just with Android paths.

  ## Architectures

  * `arm64-v8a` — modern Android phones. Required.
  * `x86_64` — Android emulators on Intel/AMD development machines.
    Required for sim development.
  * `armeabi-v7a` (32-bit) — NOT supported. Chaquopy dropped 32-bit
    Android Python a few releases back. iOS-era 32-bit Android phones
    (~2017 and earlier) cannot run Pythonx-enabled Mob apps.

  ## Mirrors PythonAppleSupport

  Same caching pattern: `~/.mob/cache/python-android-support-<version>/`,
  `valid_dir?/1` for layout validation, downloads on-demand via
  `MobDev.NativeBuild` when Pythonx is in the user's project.
  """

  @python_version "3.13"
  # Chaquopy's target-VSN versioning is `<python>.<patch>-<chaquopy-rev>`.
  # Bump together with manual end-to-end validation on emulator + device.
  @chaquopy_target "3.13.9-0"
  @release_tag @chaquopy_target
  @base_url "https://repo1.maven.org/maven2/com/chaquo/python/target"

  @abis ~w(arm64-v8a x86_64)

  @doc """
  Ensures Chaquopy's Python distribution is cached and extracted.
  Returns `{:ok, extracted_dir}` or `{:error, reason}`.

  Three artifacts get downloaded: per-abi binary zips for `arm64-v8a`
  and `x86_64`, plus the shared stdlib zip.
  """
  @spec ensure() :: {:ok, String.t()} | {:error, term()}
  def ensure do
    dir = extracted_dir()

    if valid_dir?(dir) do
      {:ok, dir}
    else
      if File.dir?(dir), do: File.rm_rf!(dir)
      File.mkdir_p!(dir)
      download_and_extract(dir)
    end
  end

  @doc """
  Returns the cached extraction directory path.
  """
  @spec extracted_dir() :: String.t()
  def extracted_dir do
    Path.join(version_dir(), "extracted")
  end

  @doc """
  Validates the extracted bundle has the expected layout: per-abi
  jniLibs/<abi>/libpython3.13.so, lib-dynload/<abi>/, headers, and
  the shared stdlib.

  Public for testing (per AGENTS.md convention).
  """
  @spec valid_dir?(String.t()) :: boolean()
  def valid_dir?(dir) do
    File.dir?(stdlib_dir(dir)) and
      Enum.all?(@abis, fn abi ->
        File.regular?(libpython_path(dir, abi)) and
          File.dir?(lib_dynload_dir(dir, abi))
      end)
  end

  @doc """
  Path to libpython3.13.so for a given ABI.
  """
  @spec libpython_path(String.t(), String.t()) :: String.t()
  def libpython_path(dir, abi) do
    Path.join([jni_libs_dir(dir, abi), "libpython#{@python_version}.so"])
  end

  @doc """
  Per-abi `jniLibs/<abi>` subtree containing libpython.so + its
  bundled OpenSSL/SQLite dependencies.
  """
  @spec jni_libs_dir(String.t(), String.t()) :: String.t()
  def jni_libs_dir(dir, abi) do
    Path.join([dir, abi, "jniLibs", abi])
  end

  @doc """
  Per-abi `lib-dynload/<abi>` subtree with arch-specific Python C
  extensions (_ssl, _ctypes, _hashlib, …).
  """
  @spec lib_dynload_dir(String.t(), String.t()) :: String.t()
  def lib_dynload_dir(dir, abi) do
    Path.join([dir, abi, "lib-dynload", abi])
  end

  @doc """
  Shared (slice-independent) Python standard library directory.
  """
  @spec stdlib_dir(String.t()) :: String.t()
  def stdlib_dir(dir) do
    Path.join(dir, "stdlib")
  end

  @doc """
  Per-abi C headers for cross-compiling NIFs (pythonx, etc.) against
  the bundled libpython.
  """
  @spec headers_dir(String.t(), String.t()) :: String.t()
  def headers_dir(dir, abi) do
    Path.join([dir, abi, "include", "python#{@python_version}"])
  end

  @doc "URL the per-variant artifact is fetched from."
  @spec download_url(String.t()) :: String.t()
  def download_url(variant) do
    "#{@base_url}/#{@chaquopy_target}/#{tarball_name(variant)}"
  end

  @doc "Tarball file name for a given variant (`arm64-v8a` / `x86_64` / `stdlib`)."
  @spec tarball_name(String.t()) :: String.t()
  def tarball_name(variant), do: "target-#{@chaquopy_target}-#{variant}.zip"

  @doc "Pinned Chaquopy target version (`3.13.9-0`, …)."
  @spec release_tag() :: String.t()
  def release_tag, do: @release_tag

  @doc "Pinned Python version (`3.13`)."
  @spec python_version() :: String.t()
  def python_version, do: @python_version

  @doc "Supported ABIs (the per-arch artifacts we extract)."
  @spec abis() :: [String.t()]
  def abis, do: @abis

  # ── Private ─────────────────────────────────────────────────────────────────

  defp version_dir do
    Path.join(cache_dir(), "python-android-support-#{@release_tag}")
  end

  defp cache_dir do
    System.get_env("MOB_CACHE_DIR") ||
      Path.join([System.get_env("HOME"), ".mob", "cache"])
  end

  defp download_and_extract(dest_dir) do
    File.mkdir_p!(dest_dir)

    # Each abi extracts to <dest_dir>/<abi>/, stdlib to <dest_dir>/stdlib/.
    with :ok <- download_and_extract_abi("arm64-v8a", dest_dir),
         :ok <- download_and_extract_abi("x86_64", dest_dir),
         :ok <- download_and_extract_stdlib(dest_dir),
         :ok <- verify_layout(dest_dir) do
      IO.puts("  Cached at #{dest_dir}")
      {:ok, dest_dir}
    else
      {:error, reason} ->
        File.rm_rf(dest_dir)
        {:error, reason}
    end
  end

  defp download_and_extract_abi(abi, dest_dir) do
    url = download_url(abi)
    abi_dir = Path.join(dest_dir, abi)
    File.mkdir_p!(abi_dir)
    tmp_zip = Path.join(System.tmp_dir!(), tarball_name(abi))

    IO.puts("  Downloading Chaquopy Python #{abi} (#{@release_tag})...")
    IO.puts("  URL: #{url}")

    with :ok <- download(url, tmp_zip),
         :ok <- extract_zip(tmp_zip, abi_dir) do
      File.rm(tmp_zip)
      :ok
    else
      err ->
        File.rm(tmp_zip)
        err
    end
  end

  defp download_and_extract_stdlib(dest_dir) do
    url = download_url("stdlib")
    stdlib = stdlib_dir(dest_dir)
    File.mkdir_p!(stdlib)
    tmp_zip = Path.join(System.tmp_dir!(), tarball_name("stdlib"))

    IO.puts("  Downloading Chaquopy Python stdlib (#{@release_tag})...")

    with :ok <- download(url, tmp_zip),
         :ok <- extract_zip(tmp_zip, stdlib) do
      File.rm(tmp_zip)
      :ok
    else
      err ->
        File.rm(tmp_zip)
        err
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

  defp extract_zip(zip, dest_dir) do
    case System.cmd("unzip", ["-q", "-o", zip, "-d", dest_dir], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, rc} -> {:error, "unzip failed (exit #{rc}): #{String.trim(out)}"}
    end
  end

  defp verify_layout(dir) do
    if valid_dir?(dir) do
      :ok
    else
      {:error,
       "Chaquopy Python extraction at #{dir} is missing expected paths.\n" <>
         "       Expected jniLibs/<abi>/libpython#{@python_version}.so for arm64-v8a + x86_64,\n" <>
         "       lib-dynload/<abi>/, and shared stdlib/.\n" <>
         "       Maven artifact may have an unexpected layout — report at\n" <>
         "       https://github.com/GenericJam/mob_dev/issues"}
    end
  end
end
