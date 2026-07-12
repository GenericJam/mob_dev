defmodule MobDev.NdkVersion do
  @moduledoc """
  Single source of truth for the Android NDK version Mob's bundled OTP
  runtime was cross-compiled against.

  The on-device `libbeam.a` (in the `otp-android-*` tarballs) embeds C++
  stdlib symbols using libc++'s versioned inline namespace. NDK 27.2
  uses `std::__ne180000::`; NDK 25 uses `std::__ne140000::`. These
  don't link cross-version: an app's `libpigeon.so` built with the
  wrong NDK fails with `undefined symbol: __cxa_allocate_exception`
  (or similar libc++ ABI symbols).

  This module is consulted by:

    * `mix mob.doctor` — checks the recommended NDK is installed and
      that the project's gradle pin (or override) doesn't drift.
    * `mix mob.install` — same check during onboarding.
    * `mix mob.new`'s gradle template (via `MobNew.NdkVersion`) — sets
      the `ndkVersion` literal so AGP picks deterministically.
    * `scripts/release/openssl/*.sh` — sources `NDK_VERSION` from
      `_lib.sh` so the host-side OpenSSL cross-compile uses the same
      NDK as the bundled tarballs.

  ## Recommended vs effective

  `recommended/0` is the version Mob's tarballs were built against. It
  changes only when we cross-compile new tarballs.

  `effective/0` returns the recommended version *unless* the user has
  overridden it. Two override mechanisms:

    1. **Environment variable** (`MOB_ANDROID_NDK_VERSION=...`) —
       machine-local. Use when one developer needs a specific NDK on
       their box and the team's project config should stay clean.

    2. **Per-project config** in `mob.exs`:

           config :mob_dev,
             android_ndk_version: "25.1.8937393"

       Travels with the project. Use when the whole team needs to
       build against a non-recommended NDK (legacy library
       dependency, hardware-specific toolchain, etc).

  Precedence: env var > mob.exs > recommended.

  ## Override caveat

  When an override is active the user opts out of the libc++ ABI
  guarantee against the bundled tarballs. They're navigating that
  alone — `mob.doctor` warns but does not fail. Cryptic link errors
  against `libbeam.a` are then their problem to debug. See
  `~/code/mob/common_fixes.md` "NDK 27 / clang 18 split libc++"
  for the symptom and the diagnostic.
  """

  @recommended "27.2.12479018"

  @doc "The NDK version the bundled OTP tarballs were cross-compiled with."
  @spec recommended() :: String.t()
  def recommended, do: @recommended

  @doc """
  The NDK version the user's build should target.

  Returns `recommended/0` unless overridden via `MOB_ANDROID_NDK_VERSION`
  env var or `:android_ndk_version` in `mob.exs`'s `:mob_dev` config.
  """
  @spec effective() :: String.t()
  def effective do
    case override() do
      {_source, version} -> version
      :none -> @recommended
    end
  end

  @doc """
  Returns `{:env, version}`, `{:mob_exs, version}`, or `:none`
  describing which override mechanism is active (if any).

  Used by `mob.doctor` to explain *why* the effective version differs
  from the recommendation.
  """
  @spec override() :: {:env | :mob_exs, String.t()} | :none
  def override do
    cond do
      env = System.get_env("MOB_ANDROID_NDK_VERSION") -> {:env, env}
      cfg = Application.get_env(:mob_dev, :android_ndk_version) -> {:mob_exs, cfg}
      true -> :none
    end
  end

  @doc """
  True if the given NDK version is installed under the local Android SDK.

  Looks for `<sdk>/ndk/<version>/source.properties` since the directory
  alone can be a half-extracted partial install.
  """
  @spec installed?(String.t()) :: boolean()
  def installed?(version) do
    case sdk_root() do
      nil -> false
      sdk -> File.regular?(Path.join([sdk, "ndk", version, "source.properties"]))
    end
  end

  @doc """
  Returns all NDK versions present under the local SDK, newest-first by
  string sort.
  """
  @spec installed_versions() :: [String.t()]
  def installed_versions do
    case sdk_root() do
      nil ->
        []

      sdk ->
        ndk_dir = Path.join(sdk, "ndk")

        case File.ls(ndk_dir) do
          {:ok, entries} ->
            entries
            |> Enum.filter(&File.regular?(Path.join([ndk_dir, &1, "source.properties"])))
            |> Enum.sort(:desc)

          _ ->
            []
        end
    end
  end

  @doc """
  Returns the absolute path to the recommended NDK install if present,
  or `nil`.
  """
  @spec recommended_install_path() :: String.t() | nil
  def recommended_install_path do
    case sdk_root() do
      nil ->
        nil

      sdk ->
        path = Path.join([sdk, "ndk", @recommended])
        if File.regular?(Path.join(path, "source.properties")), do: path, else: nil
    end
  end

  @doc """
  Reads the project's `android/app/build.gradle` (or `.kts`) for the
  `ndkVersion` literal. Returns the string or `nil` if not pinned.

  Accepts an optional project root; defaults to the current working
  directory.
  """
  @spec project_pinned(String.t()) :: String.t() | nil
  def project_pinned(project_root \\ File.cwd!()) do
    candidates = [
      Path.join(project_root, "android/app/build.gradle"),
      Path.join(project_root, "android/app/build.gradle.kts")
    ]

    # `ndkVersion '27.2.x'` (Groovy DSL) and `ndkVersion = "27.2.x"` (Kotlin DSL)
    # are both accepted — the regex tolerates the optional `=`.
    # Compiled at runtime to avoid OTP 28.0 `:re.import/1` undefined-function
    # crash on sigil-precompiled regexes loaded from beam files.
    pattern = Regex.compile!("ndkVersion\\s*=?\\s*[\"']([^\"']+)[\"']")

    Enum.find_value(candidates, fn path ->
      case File.read(path) do
        {:ok, contents} ->
          case Regex.run(pattern, contents, capture: :all_but_first) do
            [version] -> version
            _ -> nil
          end

        _ ->
          nil
      end
    end)
  end

  # ── Internals ────────────────────────────────────────────────────────────────

  @doc false
  @spec sdk_root() :: String.t() | nil
  def sdk_root do
    System.get_env("ANDROID_HOME") ||
      System.get_env("ANDROID_SDK_ROOT") ||
      default_sdk_root_for_os()
  end

  @doc false
  # The Android NDK toolchain host tag — the NDK ships a single prebuilt
  # (darwin-x86_64 even on Apple Silicon; Apple's Rosetta 2 covers it).
  @spec host() :: String.t()
  def host do
    case :os.type() do
      {:unix, :darwin} -> "darwin-x86_64"
      {:unix, :linux} -> "linux-x86_64"
      other -> raise "unsupported host for NDK: #{inspect(other)}"
    end
  end

  @doc false
  # NDK root for the effective version, honoring ANDROID_HOME / ANDROID_SDK_ROOT
  # (falls back to the OS-conventional SDK dir even when it doesn't exist, so a
  # "toolchain not found at <path>" error still names a sensible location). The
  # single source of truth for `native_build`, `cpp_archive`, and `nx_eigen_nif`
  # — none of them should re-derive this (see MOB-89).
  @spec root() :: String.t()
  def root, do: Path.join([sdk_root() || os_default_sdk_dir(), "ndk", effective()])

  @doc false
  @spec toolchain_bin() :: String.t()
  def toolchain_bin, do: Path.join([root(), "toolchains", "llvm", "prebuilt", host(), "bin"])

  @doc false
  @spec sysroot() :: String.t()
  def sysroot, do: Path.join([root(), "toolchains", "llvm", "prebuilt", host(), "sysroot"])

  # The OS-conventional SDK dir (path only, no existence check) — used by
  # `root/0` as the last-resort fallback so error messages name a real path.
  defp os_default_sdk_dir do
    case :os.type() do
      {:unix, :linux} -> Path.expand("~/Android/Sdk")
      _ -> Path.expand("~/Library/Android/sdk")
    end
  end

  defp default_sdk_root_for_os do
    path = os_default_sdk_dir()
    if File.dir?(path), do: path, else: nil
  end

  @doc """
  Build the suggested install command for the recommended NDK. Used by
  `mob.doctor` and `mix mob.install` to give the user a one-liner.
  """
  @spec install_command() :: String.t()
  def install_command do
    "sdkmanager --install \"ndk;#{@recommended}\""
  end
end
