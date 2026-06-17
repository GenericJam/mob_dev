defmodule MobDev.Release.OTP do
  @moduledoc """
  Replaces `scripts/release/xcompile_*.sh` × 3 + the misplaced
  `scripts/release/openssl/_build_otp_android_arm64.sh`. Cross-compiles
  the Erlang OTP runtime for one of four target ABIs and stages the
  install tree at a release root.

      iex> MobDev.Release.OTP.build(:android_arm64,
      ...>   openssl_prefix: "/tmp/openssl-android-arm64")
      {:ok, %{release_root: "/tmp/otp-android", erts_vsn: "17.0", ...}}

  ## Phase 6c iter 13d deferral preserved

  The C compiler stays `xcrun cc` / NDK clang — iter 13d's research
  established that swapping in `zig cc` here breaks on OTP's emulator
  Makefile.in dep-generation pass. **This module is orchestration
  only**: it wraps `./otp_build configure && make` with typed errors
  + testable invocations, but the OTP build itself runs with the
  toolchain it always has.

  ## Per-target deltas

  | Target        | xcomp-conf                              | SSL strategy                                 | Install                            |
  |---------------|-----------------------------------------|----------------------------------------------|------------------------------------|
  | android_arm64 | xcomp/erl-xcomp-arm64-android.conf      | `--with-ssl=<prefix> --disable-dynamic-ssl-lib` | `./otp_build release -a <root>`     |
  | android_arm32 | xcomp/erl-xcomp-arm-android.conf        | same                                         | same                                |
  | ios_sim       | xcomp/erl-xcomp-arm64-iossimulator.conf | `--without-ssl` (the xcomp conf sets `--enable-static-nifs`; OTP doesn't propagate `--with-ssl` to beam.emu's link in that mode) | `make release RELEASE_ROOT=<root>` |
  | ios_device    | xcomp/erl-xcomp-arm64-ios.conf          | same as ios_sim                              | same                                |

  ### Why the iOS targets diverge on install method + SSL flag

  Trial-and-error knowledge from the shell scripts, preserved here
  inline so it's available to anyone reading the spec:

    * iOS xcomp confs set `--enable-static-nifs`, which static-links
      crypto into beam.emu at OTP-build time. OTP's build system
      doesn't propagate `--with-ssl=<prefix>` into beam.emu's link
      line, so `--with-ssl` would break with undefined references to
      `RAND_seed` / `OSSL_PROVIDER_load` / etc. We side-step by
      building crypto separately via `MobDev.Release.OpenSSL.CryptoNif`,
      then the tarball stage (iter 4) ships `crypto.a` + `libcrypto.a`
      and the user's app links them at app-build time.
    * `make release RELEASE_ROOT=` is the install incantation that
      works for iOS xcomp; `./otp_build release -a` (used by Android)
      hits a layout mismatch.

  Don't try to "unify" these without re-running the experiments —
  the divergence is load-bearing.

  ## What "build" does end-to-end

    1. `make distclean` (tolerant of failure — first-time builds
       have nothing to clean)
    2. `./otp_build configure --xcomp-conf=<conf> <ssl-flags>`
    3. `./otp_build boot` (the long step, ~5-10 minutes)
    4. `rm -rf <release_root>` (idempotency — re-runs replace)
    5. Install: `./otp_build release -a` (Android) OR `make release
       RELEASE_ROOT=` (iOS)
    6. Verify: per-target sanity checks (release tree exists, expected
       arch-specific config.h / libs are produced, Android-only:
       crypto/public_key/ssl apps are present in the install tree
       — i.e. `--with-ssl` was wired correctly)
  """

  alias MobDev.Release.{Errors, Shell, Helpers}
  alias MobDev.NdkVersion

  # ── Target spec ────────────────────────────────────────────────────────

  defmodule Target do
    @moduledoc "Per-target OTP cross-compile description."

    @enforce_keys [
      :id,
      :arch_dir,
      :xcomp_conf,
      :default_release_root,
      :ssl_strategy,
      :install_method,
      :env_fn
    ]
    defstruct [
      :id,
      :arch_dir,
      :xcomp_conf,
      :default_release_root,
      :ssl_strategy,
      :install_method,
      :env_fn
    ]

    @type ssl_strategy :: :with_openssl | :without_ssl
    @type install_method :: :otp_build_release | :make_release

    @type t :: %__MODULE__{
            id: :android_arm64 | :android_arm32 | :ios_sim | :ios_device,
            arch_dir: String.t(),
            xcomp_conf: String.t(),
            default_release_root: Path.t(),
            ssl_strategy: ssl_strategy(),
            install_method: install_method(),
            env_fn: (keyword() -> [{String.t(), String.t()}])
          }
  end

  @doc "All cross-compile targets, in canonical order."
  @spec targets() :: [atom()]
  def targets, do: [:android_arm64, :android_arm32, :android_x86_64, :ios_sim, :ios_device]

  @doc "Per-target spec. Public for testing — surface lock-down."
  @spec target_spec(atom()) :: Target.t()
  def target_spec(:android_arm64) do
    %Target{
      id: :android_arm64,
      arch_dir: "aarch64-unknown-linux-android",
      xcomp_conf: "xcomp/erl-xcomp-arm64-android.conf",
      default_release_root: "/tmp/otp-android",
      ssl_strategy: :with_openssl,
      install_method: :otp_build_release,
      env_fn: &android_env(&1, "android24")
    }
  end

  def target_spec(:android_x86_64) do
    %Target{
      id: :android_x86_64,
      arch_dir: "x86_64-pc-linux-android",
      xcomp_conf: "xcomp/erl-xcomp-x86_64-android.conf",
      default_release_root: "/tmp/otp-android-x86_64",
      ssl_strategy: :with_openssl,
      install_method: :otp_build_release,
      env_fn: &android_env(&1, "android24")
    }
  end

  def target_spec(:android_arm32) do
    %Target{
      id: :android_arm32,
      arch_dir: "arm-unknown-linux-androideabi",
      xcomp_conf: "xcomp/erl-xcomp-arm-android.conf",
      default_release_root: "/tmp/otp-android-arm32",
      ssl_strategy: :with_openssl,
      install_method: :otp_build_release,
      env_fn: &android_env(&1, "androideabi24")
    }
  end

  def target_spec(:ios_sim) do
    %Target{
      id: :ios_sim,
      arch_dir: "aarch64-apple-iossimulator",
      xcomp_conf: "xcomp/erl-xcomp-arm64-iossimulator.conf",
      default_release_root: "/tmp/otp-ios-sim",
      ssl_strategy: :without_ssl,
      install_method: :make_release,
      env_fn: &ios_env/1
    }
  end

  def target_spec(:ios_device) do
    %Target{
      id: :ios_device,
      arch_dir: "aarch64-apple-ios",
      xcomp_conf: "xcomp/erl-xcomp-arm64-ios.conf",
      default_release_root: "/tmp/otp-ios-device",
      ssl_strategy: :without_ssl,
      install_method: :make_release,
      env_fn: &ios_env/1
    }
  end

  # ── Argument assembly (pure) ───────────────────────────────────────────

  @doc """
  Assemble the `./otp_build configure` argv (excluding the program) for
  a target + opts. Pure for testability — silent flag drops here would
  ship a runtime that can't load crypto / can't be cross-linked / etc.
  """
  @spec configure_args(Target.t(), Path.t() | nil) :: [String.t()]
  def configure_args(%Target{} = target, openssl_prefix) do
    base = ["--xcomp-conf=./#{target.xcomp_conf}"]

    base ++ ssl_args(target, openssl_prefix)
  end

  defp ssl_args(%Target{ssl_strategy: :with_openssl}, openssl_prefix)
       when is_binary(openssl_prefix) do
    ["--with-ssl=#{openssl_prefix}", "--disable-dynamic-ssl-lib"]
  end

  defp ssl_args(%Target{ssl_strategy: :with_openssl}, nil) do
    # Caller passed nil for openssl_prefix to a target that requires
    # it. This is a precondition that build/2's precheck catches first;
    # if we ever get here it's a programmer error, raise rather than
    # silently producing a broken configure invocation.
    raise ArgumentError,
          "openssl_prefix is required for Android targets (ssl_strategy: :with_openssl)"
  end

  defp ssl_args(%Target{ssl_strategy: :without_ssl}, _), do: ["--without-ssl"]

  @doc """
  Assemble the install-step argv. Returns one of:
    * `["./otp_build", "release", "-a", release_root]`
    * `["make", "release", "RELEASE_ROOT=" <> release_root]`
  """
  @spec install_args(Target.t(), Path.t()) :: [String.t()]
  def install_args(%Target{install_method: :otp_build_release}, release_root) do
    ["./otp_build", "release", "-a", release_root]
  end

  def install_args(%Target{install_method: :make_release}, release_root) do
    ["make", "release", "RELEASE_ROOT=#{release_root}"]
  end

  # ── Build entrypoint ───────────────────────────────────────────────────

  @doc """
  Cross-compile OTP for one target. Returns `{:ok, info}` where info
  names the produced release root + erts version, or a tagged error.

  Options:
    * `:otp_src` — OTP source checkout (default: `$OTP_SRC` env or `~/code/otp`)
    * `:openssl_prefix` — OpenSSL install (required for Android targets;
      ignored for iOS)
    * `:release_root` — where to install (default: target's `default_release_root`)
    * `:ndk_root` — Android NDK override (Android targets only)
  """
  @spec build(atom(), keyword()) :: {:ok, map()} | Errors.t()
  def build(target_id, opts \\ [])
      when target_id in [:android_arm64, :android_arm32, :android_x86_64, :ios_sim, :ios_device] do
    target = target_spec(target_id)
    shell = Shell.impl()
    otp_src = opts[:otp_src] || default_otp_src(shell)
    openssl_prefix = opts[:openssl_prefix]
    release_root = opts[:release_root] || target.default_release_root

    with :ok <- precheck(target, shell, otp_src, openssl_prefix, opts),
         {:ok, erts_vsn} <- Helpers.erts_version(otp_src),
         env = target.env_fn.(opts),
         _ = maybe_distclean(shell, otp_src, env),
         cfg_argv = ["./otp_build", "configure" | configure_args(target, openssl_prefix)],
         {:ok, _} <- shell.cmd(cfg_argv, cd: otp_src, env: env),
         {:ok, _} <- shell.cmd(["./otp_build", "boot"], cd: otp_src, env: env),
         :ok <- prepare_release_root(shell, release_root),
         install_argv = install_args(target, release_root),
         {:ok, _} <- shell.cmd(install_argv, cd: otp_src, env: env),
         :ok <- verify_outputs(target, shell, otp_src, release_root, erts_vsn) do
      {:ok,
       %{
         target: target_id,
         release_root: release_root,
         erts_vsn: erts_vsn,
         otp_src: otp_src
       }}
    end
  end

  @doc """
  Build all four targets in sequence. Returns `[{target_id, result}, ...]`
  in canonical order. Doesn't short-circuit on first failure — callers
  can decide what to do with partial results.

  Per-target `:openssl_prefix` defaults from `MobDev.Release.OpenSSL`:
    * `android_arm64` → `/tmp/openssl-android-arm64`
    * `android_arm32` → `/tmp/openssl-android-arm32`
    * iOS targets → not required (build uses `--without-ssl`)
  """
  @spec build_all(keyword()) :: [{atom(), {:ok, map()} | Errors.t()}]
  def build_all(opts \\ []) do
    for target_id <- targets() do
      target_opts =
        case target_id do
          :android_arm64 -> Keyword.put_new(opts, :openssl_prefix, "/tmp/openssl-android-arm64")
          :android_arm32 -> Keyword.put_new(opts, :openssl_prefix, "/tmp/openssl-android-arm32")
          :android_x86_64 -> Keyword.put_new(opts, :openssl_prefix, "/tmp/openssl-android-x86_64")
          _ -> opts
        end

      {target_id, build(target_id, target_opts)}
    end
  end

  # ── Preconditions ──────────────────────────────────────────────────────

  defp precheck(target, shell, otp_src, openssl_prefix, opts) do
    cond do
      not shell.dir?(otp_src) ->
        Errors.precondition("OTP_SRC missing at #{otp_src} — clone github.com/erlang/otp")

      not shell.file?(Path.join(otp_src, "otp_build")) ->
        Errors.precondition(
          "otp_build script not found at #{otp_src}/otp_build — is this an OTP source checkout?"
        )

      target.ssl_strategy == :with_openssl and is_nil(openssl_prefix) ->
        Errors.precondition(
          "openssl_prefix required for #{target.id} — run MobDev.Release.OpenSSL.build/2 first " <>
            "and pass `openssl_prefix: <path>`"
        )

      target.ssl_strategy == :with_openssl and not shell.dir?(openssl_prefix) ->
        Errors.precondition(
          "OPENSSL_PREFIX missing at #{openssl_prefix} — run MobDev.Release.OpenSSL.build(#{inspect(target.id)})"
        )

      target.id in [:android_arm64, :android_arm32, :android_x86_64] ->
        android_precheck(shell, opts)

      true ->
        :ok
    end
  end

  defp android_precheck(shell, opts), do: MobDev.Release.AndroidPrecheck.verify_ndk(shell, opts)

  # ── Distclean (tolerant) ───────────────────────────────────────────────

  defp maybe_distclean(shell, otp_src, env) do
    # Mirrors `make distclean >/dev/null 2>&1 || true` from the shell.
    # First-time builds have nothing to clean; subsequent runs need it
    # to drop the prior arch's config.
    _ = shell.cmd(["make", "distclean"], cd: otp_src, env: env)
    :ok
  end

  # ── Release-root prep ──────────────────────────────────────────────────

  defp prepare_release_root(shell, release_root) do
    # The shell scripts `rm -rf $RELEASE_ROOT` before installing. Mirror
    # that — fresh install every time, no stale-file confusion.
    case shell.cmd(["rm", "-rf", release_root], []) do
      {:ok, _} -> :ok
      err -> err
    end
  end

  # ── Output verification ────────────────────────────────────────────────

  defp verify_outputs(target, shell, otp_src, release_root, erts_vsn) do
    erts_dir = Path.join(release_root, "erts-#{erts_vsn}")

    cond do
      not shell.dir?(erts_dir) ->
        Errors.precondition(
          "missing #{erts_dir} after install — 'make release' / 'otp_build release' didn't produce the expected layout"
        )

      target.id in [:android_arm64, :android_arm32, :android_x86_64] ->
        verify_android_outputs(target, shell, release_root)

      target.id in [:ios_sim, :ios_device] ->
        verify_ios_outputs(target, shell, otp_src)
    end
  end

  defp verify_android_outputs(_target, shell, release_root) do
    # Android: --with-ssl wired correctly means crypto/public_key/ssl
    # apps end up in the install tree. If they're missing, the runtime
    # has no TLS — easy to miss until first SSL call.
    lib_dir = Path.join(release_root, "lib")

    case shell.cmd(["ls", lib_dir], []) do
      {:ok, output} ->
        if Regex.match?(~r/^(crypto|public_key|ssl)-/m, output) do
          :ok
        else
          Errors.precondition(
            "crypto / public_key / ssl apps missing from #{lib_dir} — was --with-ssl wired correctly?"
          )
        end

      err ->
        err
    end
  end

  defp verify_ios_outputs(target, shell, otp_src) do
    # iOS: arch-specific config.h is what downstream tarball steps copy.
    config_h = Path.join([otp_src, "erts", target.arch_dir, "config.h"])

    if shell.file?(config_h) do
      :ok
    else
      Errors.precondition(
        "missing #{config_h} after build — the arch-specific config didn't materialise"
      )
    end
  end

  # ── Per-target environment ─────────────────────────────────────────────

  defp android_env(opts, ndk_abi_plat) do
    ndk_version = opts[:ndk_version] || NdkVersion.effective()
    ndk_root = opts[:ndk_root] || default_ndk_root(ndk_version)
    toolchain_bin = Path.join([ndk_root, "toolchains/llvm/prebuilt/darwin-x86_64/bin"])
    current_path = System.get_env("PATH", "")

    [
      {"NDK_ROOT", ndk_root},
      {"PATH", "#{toolchain_bin}:#{current_path}"},
      {"NDK_ABI_PLAT", ndk_abi_plat},
      # RELEASE_LIBBEAM=yes triggers OTP's release script to ship
      # libbeam.a in the install tree — what our static-link path
      # needs.
      {"RELEASE_LIBBEAM", "yes"}
    ]
  end

  defp ios_env(_opts) do
    # iOS xcomp configs handle the toolchain via xcrun internally; we
    # just set RELEASE_LIBBEAM. No PATH manipulation needed.
    [{"RELEASE_LIBBEAM", "yes"}]
  end

  # ── Defaults ───────────────────────────────────────────────────────────

  defp default_otp_src(shell) do
    case shell.fetch_env("OTP_SRC") do
      {:ok, path} -> path
      :error -> Path.join(System.user_home!(), "code/otp")
    end
  end

  defp default_ndk_root(ndk_version) do
    version = ndk_version || NdkVersion.effective()
    Path.join([System.user_home!(), "Library/Android/sdk/ndk", version])
  end
end
