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

  Mirrors the `MobDev.MLXDownloader` pattern: pinned URL + cached
  extraction at `~/.mob/cache/tflite-<version>-<target>/`, validated
  against the expected layout. Reused across projects. The AAR, the iOS
  tarball and the two headers patched into the Android tree are checked
  against their SHA-256 pins in `MobDev.Download.Pins` (the downloaded
  AAR/tarball again on every reuse), and an extracted cache is reused
  only if it came from the pinned archive.

  Used by `MobDev.NativeBuild` when the project enables TFLite via
  `mix mob.enable tflite`. The build template sources `TFLITE_DIR` from
  `dir/1` and links the `tflite_nif.c` NIF against the headers and
  framework / .so it provides.

  ## Local-build override

  Set `MOB_TFLITE_LOCAL_TARBALL_DIR=/path/to/dir` to bypass the upstream
  download and use `tensorflow-lite-<android_version>.aar` /
  `TensorFlowLiteC-<ios_version>.tar.gz` from that directory. Useful when
  iterating offline or against a custom TFLite build. A local archive is
  your own choice, so it is not held to the pin; its hash is recorded
  instead, and the cache it produced is replaced once the override is unset.
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

  # Headers the AAR's tensorflow/lite/core tree lacks; c_api_experimental.h
  # needs them at build time.
  @android_patch_headers [
    "tensorflow/lite/core/c/registration_external.h",
    "tensorflow/lite/core/async/c/types.h"
  ]

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Ensure the TFLite bundle for `target` is cached and extracted.

  Returns `{:ok, path}` where `path` is the unpacked root containing the
  expected layout (see `valid_dir?/2`).
  """
  @spec ensure(target()) :: {:ok, String.t()} | {:error, term()}
  def ensure(target) when target in @android_targets or target in @ios_targets do
    dest = dir(target)
    source = source(target)

    with {:ok, sha} <- source_sha(source) do
      if valid_dir?(target, dest) and MobDev.Download.verified?(dest, sha) do
        {:ok, dest}
      else
        if File.dir?(dest), do: File.rm_rf!(dest)
        extract(target, source, sha, dest)
      end
    end
  end

  @doc "Every URL this downloader can request."
  @spec download_urls() :: [String.t()]
  def download_urls do
    [@android_aar_url, @ios_tarball_url] ++ Enum.map(@android_patch_headers, &header_url/1)
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

  # Where `target`'s archive comes from: the pinned upstream URL (downloaded
  # once into the cache), or the developer's MOB_TFLITE_LOCAL_TARBALL_DIR.
  defp source(target) when target in @android_targets do
    file = "tensorflow-lite-#{@android_version}.aar"
    archive_source(@android_aar_url, "tflite-#{@android_version}-android-aar", file)
  end

  defp source(target) when target in @ios_targets do
    file = "TensorFlowLiteC-#{@ios_version}.tar.gz"
    archive_source(@ios_tarball_url, "tflite-#{@ios_version}-ios-tarball", file)
  end

  defp archive_source(url, cache_slot, file) do
    case local_tarball_dir() do
      nil -> {:remote, url, Path.join([cache_dir(), cache_slot, file])}
      local -> {:local, Path.join(local, file)}
    end
  end

  # The SHA-256 an extracted cache is recorded under: the pin, or the hash
  # of the developer's local archive.
  defp source_sha({:remote, url, _cached}), do: MobDev.Download.pin(url)

  defp source_sha({:local, path}) do
    if File.regular?(path),
      do: MobDev.Download.sha256_file(path),
      else: {:error, {:local_missing, path}}
  end

  defp extract(target, source, sha, dest) do
    File.mkdir_p!(dest)

    with {:ok, archive} <- obtain(source, sha),
         :ok <- unpack(target, archive, dest),
         :ok <- MobDev.Download.mark_verified(dest, sha) do
      {:ok, dest}
    else
      {:error, _} = err ->
        File.rm_rf(dest)
        err
    end
  end

  defp obtain({:local, path}, _sha), do: {:ok, path}

  # The downloaded archive is kept for the other targets it serves and is
  # re-verified each time it is reused; a copy that no longer matches is
  # deleted and fetched again.
  defp obtain({:remote, url, cached}, sha) do
    File.mkdir_p!(Path.dirname(cached))

    reusable? =
      File.regular?(cached) and
        case MobDev.Download.verify_sha256(cached, sha) do
          :ok ->
            true

          {:error, reason} ->
            IO.puts(:stderr, "  #{reason} Downloading it again.")
            false
        end

    if reusable? do
      {:ok, cached}
    else
      with :ok <- MobDev.Download.fetch_verified(url, cached, sha), do: {:ok, cached}
    end
  end

  # AAR is a zip; extract jni/<abi>/libtensorflowlite_jni.so + headers/.
  # The AAR ships headers/ as a peer of jni/ — both root entries.
  defp unpack(target, aar, dest) when target in @android_targets do
    with :ok <- MobDev.Download.unzip(aar, dest),
         :ok <- patch_missing_android_headers(dest) do
      if valid_dir?(target, dest), do: :ok, else: {:error, {:invalid_aar_layout, dest}}
    end
  end

  defp unpack(target, tarball, dest) when target in @ios_targets do
    with :ok <- MobDev.Download.untar(tarball, dest, strip_components: 1) do
      if valid_dir?(target, dest), do: :ok, else: {:error, {:invalid_ios_layout, dest}}
    end
  end

  # Same workaround the standalone bench Makefile uses.
  defp patch_missing_android_headers(dest) do
    Enum.reduce_while(@android_patch_headers, :ok, fn rel, :ok ->
      case fetch_header(rel, Path.join([dest, "headers", rel])) do
        :ok -> {:cont, :ok}
        err -> {:halt, err}
      end
    end)
  end

  defp fetch_header(rel, out) do
    if File.regular?(out) do
      :ok
    else
      File.mkdir_p!(Path.dirname(out))
      url = header_url(rel)

      with {:ok, sha} <- MobDev.Download.pin(url),
           do: MobDev.Download.fetch_verified(url, out, sha)
    end
  end

  defp header_url(rel),
    do: "https://raw.githubusercontent.com/tensorflow/tensorflow/v#{@android_version}/#{rel}"

  defp local_tarball_dir do
    case System.get_env("MOB_TFLITE_LOCAL_TARBALL_DIR") do
      nil -> nil
      "" -> nil
      path -> path
    end
  end
end
