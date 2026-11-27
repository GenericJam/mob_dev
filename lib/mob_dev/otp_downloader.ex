defmodule MobDev.OtpDownloader do
  @moduledoc """
  Downloads and caches pre-built OTP releases from GitHub for Android and iOS simulator.

  Artifacts are cached at `~/.mob/cache/` and reused across projects. Each
  tarball is checked against its SHA-256 pin in `MobDev.Download.Pins` before
  it is extracted, and a cached runtime is reused only if it was extracted
  from the pinned tarball.
  """

  @otp_hash "d199a49a"
  @release_tag "otp-#{@otp_hash}"
  @base_url "https://github.com/GenericJam/mob/releases/download/#{@release_tag}"

  @android_name "otp-android-#{@otp_hash}"
  @android_arm32_name "otp-android-arm32-#{@otp_hash}"
  @android_x86_64_name "otp-android-x86_64-#{@otp_hash}"
  @ios_sim_name "otp-ios-sim-#{@otp_hash}"
  @ios_device_name "otp-ios-device-#{@otp_hash}"

  @names [
    @android_name,
    @android_arm32_name,
    @android_x86_64_name,
    @ios_sim_name,
    @ios_device_name
  ]

  @doc "Ensures the Android OTP release is cached. Returns {:ok, path} or {:error, reason}."
  @spec ensure_android(String.t()) :: {:ok, String.t()} | {:error, term()}
  def ensure_android(abi \\ "arm64-v8a") do
    case abi do
      "armeabi-v7a" -> ensure(@android_arm32_name)
      "x86_64" -> ensure(@android_x86_64_name)
      _ -> ensure(@android_name)
    end
  end

  @doc "Ensures the iOS simulator OTP release is cached. Returns {:ok, path} or {:error, reason}."
  @spec ensure_ios_sim() :: {:ok, String.t()} | {:error, term()}
  def ensure_ios_sim do
    ensure(@ios_sim_name)
  end

  @doc "Ensures the iOS device OTP release is cached. Returns {:ok, path} or {:error, reason}."
  @spec ensure_ios_device() :: {:ok, String.t()} | {:error, term()}
  def ensure_ios_device do
    ensure(@ios_device_name)
  end

  @doc "Every tarball URL this downloader can request."
  @spec download_urls() :: [String.t()]
  def download_urls, do: Enum.map(@names, &download_url/1)

  @doc "Download URL of the tarball for a runtime name (e.g. `otp-android-<hash>`)."
  @spec download_url(String.t()) :: String.t()
  def download_url(name), do: "#{@base_url}/#{name}.tar.gz"

  @doc "Returns the cached Android OTP directory path (may not exist yet)."
  @spec android_otp_dir(String.t()) :: String.t()
  def android_otp_dir(abi \\ "arm64-v8a") do
    case abi do
      "armeabi-v7a" -> cache_dir(@android_arm32_name)
      "x86_64" -> cache_dir(@android_x86_64_name)
      _ -> cache_dir(@android_name)
    end
  end

  @doc "Returns the cached iOS simulator OTP directory path (may not exist yet)."
  @spec ios_sim_otp_dir() :: String.t()
  def ios_sim_otp_dir, do: cache_dir(@ios_sim_name)

  @doc "Returns the cached iOS device OTP directory path (may not exist yet)."
  @spec ios_device_otp_dir() :: String.t()
  def ios_device_otp_dir, do: cache_dir(@ios_device_name)

  @doc """
  Warns (does not fail) when the build's Elixir minor version differs from the
  Elixir bundled in the device OTP runtime at `otp_dir`.

  This is the `Enum.__in__/2` class of breakage: the `in` operator and other
  macros expand differently per Elixir minor, so beams compiled by 1.20 call
  functions a 1.19.5 runtime lacks → `:undef` at boot → black screen with no
  obvious cause. Warning (not failing) is deliberate: rc/patch transitions are
  common and usually fine, and a hard fail would block legitimate builds — but
  a loud warning would have turned that debugging saga into one line.
  """
  @spec warn_on_elixir_skew(String.t()) :: :ok
  def warn_on_elixir_skew(otp_dir) do
    case elixir_skew(System.version(), bundled_elixir_version(otp_dir)) do
      :ok ->
        :ok

      {:skew, build, bundled} ->
        IO.puts(:stderr, [
          IO.ANSI.yellow(),
          """
          ⚠  Elixir version skew: building with #{build}, but the device OTP runtime ships #{bundled}.
             Beams compiled here may not load on device (e.g. `x in list` compiles to
             Enum.__in__/2 under 1.20, which #{bundled} lacks → :undef at boot).
             Fix: align .tool-versions to #{bundled}, or rebuild the OTP tarball with #{build}.\
          """,
          IO.ANSI.reset()
        ])

        :ok
    end
  end

  @doc false
  @spec elixir_skew(String.t(), String.t() | nil) :: :ok | {:skew, String.t(), String.t()}
  def elixir_skew(_build, nil), do: :ok

  def elixir_skew(build, bundled) do
    if major_minor(build) == major_minor(bundled),
      do: :ok,
      else: {:skew, build, bundled}
  end

  @doc "Reads the Elixir vsn from `otp_dir/lib/elixir/ebin/elixir.app`, or nil."
  @spec bundled_elixir_version(String.t()) :: String.t() | nil
  def bundled_elixir_version(otp_dir) do
    app = Path.join([otp_dir, "lib", "elixir", "ebin", "elixir.app"])

    with {:ok, content} <- File.read(app),
         [_, vsn] <- Regex.run(~r/\{vsn,\s*"([^"]+)"\}/, content) do
      vsn
    else
      _ -> nil
    end
  end

  # ── Private ──────────────────────────────────────────────────────────────────

  # major.minor as a 2-element list, dropping any -pre/+build on the patch.
  # "1.20.0-rc.5" -> ["1", "20"]; "1.19.5" -> ["1", "19"].
  defp major_minor(vsn), do: vsn |> String.split(".") |> Enum.take(2)

  defp ensure(name) do
    dir = cache_dir(name)

    result =
      if cached?(dir, name) do
        {:ok, dir}
      else
        # Remove a stale, incomplete or unverified directory before
        # re-downloading: a failed extraction, or a cache from a mob_dev that
        # did not record which tarball it came from.
        if File.dir?(dir), do: File.rm_rf!(dir)
        download_and_extract(name, dir)
      end

    with {:ok, otp_dir} <- result, do: warn_on_elixir_skew(otp_dir)
    result
  end

  @doc false
  # A cached runtime is reused only when it has the expected layout AND was
  # extracted from the tarball whose SHA-256 is pinned for `name`.
  @spec cached?(String.t(), String.t()) :: boolean()
  def cached?(dir, name) do
    valid_otp_dir?(dir, name) and
      MobDev.Download.verified?(dir, MobDev.Download.Pins.sha256(download_url(name)))
  end

  # A valid extracted OTP dir must contain at least one erts-* subdirectory.
  # The iOS device tarball additionally must ship EPMD source files at
  # `erts/epmd/src/`, because `build_device.sh` static-links EPMD into the app
  # and there's no other place to source those .c files from. Tarballs without
  # the source extract cleanly but fail at iOS device build time with
  # `clang: no such file or directory: epmd.c`, so they are rejected here.
  @doc false
  @spec valid_otp_dir?(String.t(), String.t()) :: boolean()
  def valid_otp_dir?(dir, name) do
    base_valid? = File.dir?(dir) and Path.wildcard(Path.join(dir, "erts-*")) != []

    cond do
      not base_valid? -> false
      not crypto_present?(dir) -> false
      String.starts_with?(name, "otp-ios-device-") -> ios_device_extras_present?(dir)
      true -> true
    end
  end

  @doc false
  @spec crypto_present?(String.t()) :: boolean()
  def crypto_present?(dir) do
    # Schema bump (2026-05-06): tarballs ship erts-VSN/lib/crypto.a +
    # erts-VSN/lib/libcrypto.a so apps can statically link real OpenSSL.
    Path.wildcard(Path.join([dir, "erts-*", "lib", "crypto.a"])) != [] and
      Path.wildcard(Path.join([dir, "erts-*", "lib", "libcrypto.a"])) != []
  end

  @doc false
  @spec ios_device_extras_present?(String.t()) :: boolean()
  def ios_device_extras_present?(dir) do
    # `build_device.sh` static-links EPMD into the iOS app — it needs both the
    # .c sources AND the headers they #include (`epmd.h`, `epmd_int.h` — also
    # in erts/epmd/src/). A tarball missing the headers extracts cleanly but
    # fails at clang time with `'epmd.h' file not found`, so we treat it as
    # invalid and force re-download.
    Enum.all?(
      ~w[
        erts/epmd/src/epmd.c
        erts/epmd/src/epmd_srv.c
        erts/epmd/src/epmd_cli.c
        erts/epmd/src/epmd.h
        erts/epmd/src/epmd_int.h
      ],
      fn rel -> File.exists?(Path.join(dir, rel)) end
    )
  end

  defp cache_dir(name) do
    base =
      System.get_env("MOB_CACHE_DIR") ||
        Path.join([System.get_env("HOME"), ".mob", "cache"])

    Path.join(base, name)
  end

  defp download_and_extract(name, dest_dir) do
    url = download_url(name)
    tmp_file = MobDev.Download.staging_path(dest_dir, url)

    IO.puts("  Downloading #{name} OTP release...")
    IO.puts("  URL: #{url}")

    File.mkdir_p!(Path.dirname(dest_dir))

    with {:ok, sha} <- MobDev.Download.pin(url),
         :ok <- MobDev.Download.fetch_verified(url, tmp_file, sha),
         :ok <- extract(tmp_file, dest_dir),
         :ok <- verify_erts(dest_dir),
         :ok <- MobDev.Download.mark_verified(dest_dir, sha) do
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

  defp extract(tarball, dest_dir) do
    File.mkdir_p!(dest_dir)
    # The tarball extracts into a single top-level directory; strip it.
    MobDev.Download.untar(tarball, dest_dir, strip_components: 1)
  end

  defp verify_erts(dir) do
    case Path.wildcard(Path.join(dir, "erts-*")) do
      [_ | _] ->
        :ok

      [] ->
        {:error,
         "OTP extraction produced no erts-* directory in #{dir}.\n" <>
           "       The tarball may have an unexpected layout.\n" <>
           "       Run `mix mob.doctor` for diagnosis, or report at https://github.com/GenericJam/mob/issues"}
    end
  end
end
