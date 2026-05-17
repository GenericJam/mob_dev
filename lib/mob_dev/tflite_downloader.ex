defmodule MobDev.TfliteDownloader do
  @moduledoc """
  Downloads and caches pre-built TensorFlow Lite native libraries for
  Android and iOS so Mob apps can ship the TFLite Nx backend without
  building TFLite from source (Bazel).

  Two upstream sources:

  * **Android** — `tensorflow-lite-2.16.1.aar` from Maven Central
    (the last release with a packed `.aar`; 2.17.0 ships `.jar` only).
    Extracted to `jni/arm64-v8a/libtensorflowlite_jni.so` +
    `headers/tensorflow/lite/c/c_api.h` etc.
  * **iOS** — `TensorFlowLiteC-2.17.0.tar.gz` from `dl.google.com`
    (CocoaPods upstream). Contains three xcframeworks (Core, CoreML,
    Metal) each with `ios-arm64` device + `ios-arm64_x86_64-simulator`
    slices.

  The C API is binary-compatible between these versions — TFLite's
  `c_api.h` surface has been stable since 2.13. Different version pins
  per platform reflect upstream packaging differences, not API drift.

  Mirrors the `MobDev.MLXDownloader` pattern: hashed URL + cached
  extraction at `~/.mob/cache/tflite-<version>-<target>/`, validated
  against the expected layout. Reused across projects.

  Used by `MobDev.NativeBuild` when the project enables TFLite via
  `mix mob.enable tflite`. The build template sources `TFLITE_DIR` from
  `dir/1` and links the `tflite_nif.c` NIF against the headers and
  framework / .so it provides.

  ## Local-build override

  Set `MOB_TFLITE_LOCAL_TARBALL_DIR=/path/to/dir` to bypass the upstream
  download and use locally-fetched tarballs (named exactly as
  `tarball_name/1` returns). Useful when iterating offline or against
  a custom TFLite build.
  """

  @android_version "2.16.1"
  @ios_version "2.17.0"

  @android_aar_url "https://repo1.maven.org/maven2/org/tensorflow/tensorflow-lite/#{@android_version}/tensorflow-lite-#{@android_version}.aar"

  # iOS tarball URL is content-addressed by the CocoaPods publishing
  # pipeline — the `0c10b3543e01f547` segment is a build hash that
  # changes per upstream release. Captured here so the download is
  # deterministic without needing to scrape the podspec at build time.
  @ios_tarball_url "https://dl.google.com/tflite-release/ios/prod/tensorflow/lite/release/ios/release/32/20240729-115310/TensorFlowLiteC/#{@ios_version}/0c10b3543e01f547/TensorFlowLiteC-#{@ios_version}.tar.gz"

  @typedoc "Target slice this downloader supports."
  @type target :: :android_arm64 | :android_arm32 | :ios_device | :ios_sim

  @android_targets [:android_arm64, :android_arm32]
  @ios_targets [:ios_device, :ios_sim]

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Ensure the TFLite bundle for `target` is cached and extracted.

  Returns `{:ok, path}` where `path` is the unpacked root containing the
  expected layout (see `valid_dir?/2`).
  """
  @spec ensure(target()) :: {:ok, String.t()} | {:error, term()}
  def ensure(target) when target in @android_targets do
    dest = dir(target)

    if valid_dir?(target, dest) do
      {:ok, dest}
    else
      if File.dir?(dest), do: File.rm_rf!(dest)
      download_and_extract_android(target, dest)
    end
  end

  def ensure(target) when target in @ios_targets do
    dest = dir(target)

    if valid_dir?(target, dest) do
      {:ok, dest}
    else
      if File.dir?(dest), do: File.rm_rf!(dest)
      download_and_extract_ios(target, dest)
    end
  end

  @doc """
  Cached TFLite root directory for `target`. May not exist if `ensure/1`
  hasn't been called.
  """
  @spec dir(target()) :: String.t()
  def dir(target), do: Path.join(cache_dir(), name(target))

  @doc """
  Returns true if the cache directory has the expected layout for the
  given target. Public for tests and `NativeBuild` probing.
  """
  @spec valid_dir?(target(), String.t()) :: boolean()
  def valid_dir?(target, dir) when target == :android_arm64 do
    File.regular?(Path.join([dir, "jni", "arm64-v8a", "libtensorflowlite_jni.so"])) and
      File.regular?(Path.join([dir, "headers", "tensorflow", "lite", "c", "c_api.h"]))
  end

  def valid_dir?(target, dir) when target == :android_arm32 do
    File.regular?(Path.join([dir, "jni", "armeabi-v7a", "libtensorflowlite_jni.so"])) and
      File.regular?(Path.join([dir, "headers", "tensorflow", "lite", "c", "c_api.h"]))
  end

  def valid_dir?(:ios_device, dir) do
    fw = Path.join([dir, "Frameworks", "TensorFlowLiteC.xcframework", "ios-arm64"])

    File.regular?(Path.join([fw, "TensorFlowLiteC.framework", "TensorFlowLiteC"])) and
      File.regular?(Path.join([fw, "TensorFlowLiteC.framework", "Headers", "c_api.h"]))
  end

  def valid_dir?(:ios_sim, dir) do
    fw =
      Path.join([dir, "Frameworks", "TensorFlowLiteC.xcframework", "ios-arm64_x86_64-simulator"])

    File.regular?(Path.join([fw, "TensorFlowLiteC.framework", "TensorFlowLiteC"])) and
      File.regular?(Path.join([fw, "TensorFlowLiteC.framework", "Headers", "c_api.h"]))
  end

  @doc "Android TFLite version pin."
  @spec android_version() :: String.t()
  def android_version, do: @android_version

  @doc "iOS TFLite version pin."
  @spec ios_version() :: String.t()
  def ios_version, do: @ios_version

  # ── Internals ───────────────────────────────────────────────────────────────

  defp name(:android_arm64), do: "tflite-#{@android_version}-android_arm64"
  defp name(:android_arm32), do: "tflite-#{@android_version}-android_arm32"
  defp name(:ios_device), do: "tflite-#{@ios_version}-ios_device"
  defp name(:ios_sim), do: "tflite-#{@ios_version}-ios_sim"

  # Public for testability — tests redirect to /tmp via `MOB_CACHE_DIR`.
  @doc false
  @spec cache_dir() :: String.t()
  def cache_dir do
    case System.get_env("MOB_CACHE_DIR") do
      nil ->
        System.user_home!()
        |> Path.join(".mob")
        |> Path.join("cache")

      "" ->
        System.user_home!()
        |> Path.join(".mob")
        |> Path.join("cache")

      path ->
        path
    end
  end

  defp download_and_extract_android(target, dest) do
    aar_dir = Path.join(cache_dir(), "tflite-#{@android_version}-android-aar")

    with {:ok, aar_path} <- fetch_android_aar(aar_dir),
         :ok <- unpack_aar(aar_path, dest, target) do
      {:ok, dest}
    end
  end

  defp fetch_android_aar(aar_dir) do
    File.mkdir_p!(aar_dir)
    aar_path = Path.join(aar_dir, "tensorflow-lite-#{@android_version}.aar")

    cond do
      File.regular?(aar_path) ->
        {:ok, aar_path}

      local = local_tarball_dir() ->
        local_aar = Path.join(local, "tensorflow-lite-#{@android_version}.aar")

        if File.regular?(local_aar) do
          File.cp!(local_aar, aar_path)
          {:ok, aar_path}
        else
          {:error, {:local_missing, local_aar}}
        end

      true ->
        case http_get(@android_aar_url, aar_path) do
          :ok -> {:ok, aar_path}
          err -> err
        end
    end
  end

  # AAR is a zip; extract jni/<abi>/libtensorflowlite_jni.so + headers/.
  # The AAR ships headers/ as a peer of jni/ — both root entries.
  defp unpack_aar(aar_path, dest, target) do
    File.mkdir_p!(dest)

    case System.cmd("unzip", ["-q", "-o", aar_path, "-d", dest], stderr_to_stdout: true) do
      {_, 0} ->
        # Patch in two upstream-missing headers (AAR ships an incomplete
        # tensorflow/lite/core tree); they are needed by c_api_experimental.h
        # at build time. Same workaround the standalone bench Makefile uses.
        patch_missing_android_headers(dest)

        if valid_dir?(target, dest) do
          :ok
        else
          {:error, {:invalid_aar_layout, dest}}
        end

      {out, code} ->
        {:error, {:unzip_failed, code, out}}
    end
  end

  defp patch_missing_android_headers(dest) do
    headers_root = Path.join(dest, "headers")

    [
      "tensorflow/lite/core/c/registration_external.h",
      "tensorflow/lite/core/async/c/types.h"
    ]
    |> Enum.each(fn rel ->
      out = Path.join(headers_root, rel)

      unless File.regular?(out) do
        File.mkdir_p!(Path.dirname(out))

        url =
          "https://raw.githubusercontent.com/tensorflow/tensorflow/v#{@android_version}/#{rel}"

        _ = http_get(url, out)
      end
    end)
  end

  defp download_and_extract_ios(target, dest) do
    tar_dir = Path.join(cache_dir(), "tflite-#{@ios_version}-ios-tarball")

    with {:ok, tar_path} <- fetch_ios_tarball(tar_dir),
         :ok <- unpack_ios(tar_path, dest, target) do
      {:ok, dest}
    end
  end

  defp fetch_ios_tarball(tar_dir) do
    File.mkdir_p!(tar_dir)
    tar_path = Path.join(tar_dir, "TensorFlowLiteC-#{@ios_version}.tar.gz")

    cond do
      File.regular?(tar_path) ->
        {:ok, tar_path}

      local = local_tarball_dir() ->
        local_tar = Path.join(local, "TensorFlowLiteC-#{@ios_version}.tar.gz")

        if File.regular?(local_tar) do
          File.cp!(local_tar, tar_path)
          {:ok, tar_path}
        else
          {:error, {:local_missing, local_tar}}
        end

      true ->
        case http_get(@ios_tarball_url, tar_path) do
          :ok -> {:ok, tar_path}
          err -> err
        end
    end
  end

  defp unpack_ios(tar_path, dest, target) do
    File.mkdir_p!(dest)

    case System.cmd("tar", ["xzf", tar_path, "-C", dest, "--strip-components=1"],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        if valid_dir?(target, dest) do
          :ok
        else
          {:error, {:invalid_ios_layout, dest}}
        end

      {out, code} ->
        {:error, {:tar_failed, code, out}}
    end
  end

  defp http_get(url, dest) do
    # Use curl rather than :httpc to inherit system certs without
    # juggling ssl options; matches MLXDownloader's approach.
    case System.cmd("curl", ["-fsSL", "-o", dest, url], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, code} -> {:error, {:http_get_failed, code, out}}
    end
  end

  defp local_tarball_dir do
    case System.get_env("MOB_TFLITE_LOCAL_TARBALL_DIR") do
      nil -> nil
      "" -> nil
      path -> path
    end
  end
end
