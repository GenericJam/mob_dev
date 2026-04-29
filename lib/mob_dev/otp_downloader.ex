defmodule MobDev.OtpDownloader do
  @moduledoc """
  Downloads and caches pre-built OTP releases from GitHub for Android and iOS simulator.

  Artifacts are cached at `~/.mob/cache/` and reused across projects.
  """

  @otp_hash "73ba6e0f"
  @release_tag "otp-#{@otp_hash}"
  @base_url "https://github.com/GenericJam/mob/releases/download/#{@release_tag}"

  @android_name "otp-android-#{@otp_hash}"
  @android_arm32_name "otp-android-arm32-#{@otp_hash}"
  @ios_sim_name "otp-ios-sim-#{@otp_hash}"
  @ios_device_name "otp-ios-device-#{@otp_hash}"

  @doc "Ensures the Android OTP release is cached. Returns {:ok, path} or {:error, reason}."
  @spec ensure_android(String.t()) :: {:ok, String.t()} | {:error, term()}
  def ensure_android(abi \\ "arm64-v8a") do
    case abi do
      "armeabi-v7a" -> ensure(@android_arm32_name, "#{@android_arm32_name}.tar.gz")
      _ -> ensure(@android_name, "#{@android_name}.tar.gz")
    end
  end

  @doc "Ensures the iOS simulator OTP release is cached. Returns {:ok, path} or {:error, reason}."
  @spec ensure_ios_sim() :: {:ok, String.t()} | {:error, term()}
  def ensure_ios_sim do
    ensure(@ios_sim_name, "#{@ios_sim_name}.tar.gz")
  end

  @doc "Ensures the iOS device OTP release is cached. Returns {:ok, path} or {:error, reason}."
  @spec ensure_ios_device() :: {:ok, String.t()} | {:error, term()}
  def ensure_ios_device do
    ensure(@ios_device_name, "#{@ios_device_name}.tar.gz")
  end

  @doc "Returns the cached Android OTP directory path (may not exist yet)."
  @spec android_otp_dir(String.t()) :: String.t()
  def android_otp_dir(abi \\ "arm64-v8a") do
    case abi do
      "armeabi-v7a" -> cache_dir(@android_arm32_name)
      _ -> cache_dir(@android_name)
    end
  end

  @doc "Returns the cached iOS simulator OTP directory path (may not exist yet)."
  @spec ios_sim_otp_dir() :: String.t()
  def ios_sim_otp_dir, do: cache_dir(@ios_sim_name)

  @doc "Returns the cached iOS device OTP directory path (may not exist yet)."
  @spec ios_device_otp_dir() :: String.t()
  def ios_device_otp_dir, do: cache_dir(@ios_device_name)

  # ── Private ──────────────────────────────────────────────────────────────────

  defp ensure(name, tarball) do
    dir = cache_dir(name)

    if valid_otp_dir?(dir, name) do
      {:ok, dir}
    else
      # Remove stale/incomplete directory before re-downloading.
      # Two cases here:
      #   1. previous download attempt failed mid-extraction (Nix curl, flaky net)
      #   2. cached tarball predates a schema change — e.g. iOS device tarball
      #      now ships EPMD source under `erts/epmd/src/`. Re-download picks up
      #      the new asset at the same URL (same OTP hash, new revision uploaded).
      if File.dir?(dir), do: File.rm_rf!(dir)
      download_and_extract(name, tarball, dir)
    end
  end

  # A valid extracted OTP dir must contain at least one erts-* subdirectory.
  # The iOS device tarball additionally must ship EPMD source files at
  # `erts/epmd/src/`, because `build_device.sh` static-links EPMD into the app
  # and there's no other place to source those .c files from. Older tarballs
  # (without source) extract cleanly but fail at iOS device build time with
  # `clang: no such file or directory: epmd.c` — so we treat them as invalid
  # and force a re-download to pick up the schema-bumped asset.
  @doc false
  @spec valid_otp_dir?(String.t(), String.t()) :: boolean()
  def valid_otp_dir?(dir, name) do
    base_valid? = File.dir?(dir) and Path.wildcard(Path.join(dir, "erts-*")) != []

    cond do
      not base_valid? -> false
      String.starts_with?(name, "otp-ios-device-") -> ios_device_extras_present?(dir)
      true -> true
    end
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

  defp download_and_extract(name, tarball, dest_dir) do
    url = "#{@base_url}/#{tarball}"
    tmp_file = Path.join(System.tmp_dir!(), tarball)

    IO.puts("  Downloading #{name} OTP release...")
    IO.puts("  URL: #{url}")

    File.mkdir_p!(Path.dirname(dest_dir))

    with :ok <- download(url, tmp_file),
         :ok <- extract(tmp_file, dest_dir),
         :ok <- verify_erts(dest_dir) do
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
    # The tarball extracts into a single top-level directory; strip it with --strip-components=1.
    case System.cmd("tar", ["xzf", tarball, "-C", dest_dir, "--strip-components=1"],
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      {out, rc} -> {:error, "tar failed (exit #{rc}): #{String.trim(out)}"}
    end
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
