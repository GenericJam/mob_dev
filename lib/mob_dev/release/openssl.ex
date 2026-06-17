defmodule MobDev.Release.OpenSSL do
  @moduledoc """
  Replaces `scripts/release/openssl/{android_arm64,android_arm32,ios_sim,
  ios_device}.sh`. Cross-compiles OpenSSL 3.x for the four target
  ABIs that Mob's bundled OTP tarballs link against, producing static
  `libcrypto.a` + `libssl.a` + headers under a per-target `--prefix`.

  ## API

      iex> MobDev.Release.OpenSSL.build(:android_arm64)
      {:ok, %{prefix: "/tmp/openssl-android-arm64", libcrypto: ".../libcrypto.a"}}

      iex> MobDev.Release.OpenSSL.build_all()
      [{:android_arm64, {:ok, _}}, {:android_arm32, {:ok, _}}, ...]

  ## Why this exists

  The shell version compiled fine but had four classes of failure mode
  that this module addresses:

    * **Drift between targets.** The arm64 script had `no-asm`
      removed; the arm32 script needed it but the comment explaining
      *why* lived only in arm32. New targets would copy from arm64 and
      get bitten. Here the `Target` spec is data — the disable-`asm`
      decision lives next to the target ID, visible to anyone reading.

    * **NDK version drift.** The shell mirrored
      `MobDev.NdkVersion.@recommended` as a separate constant in
      `openssl/_lib.sh`. This module calls `MobDev.NdkVersion.effective/0`
      directly — no mirror, no drift.

    * **Silent precondition failures.** The shell version checked
      `$ANDROID_NDK_ROOT` and `$OPENSSL_SRC` and bailed with `exit 1`
      and a single-line `echo`. This module returns a tagged
      `:precondition_failed` with an actionable hint, so the Mix task
      layer can format it with the same shape as every other release
      error.

    * **No tests.** Self-explanatory.

  ## Target spec — what's shared, what differs

  All four targets share:
    * The `no-X` algorithm disable list (legacy/niche crypto we don't
      ship)
    * Size flags: `-Os -ffunction-sections -fdata-sections -fPIC`
    * The `make distclean` / `Configure` / `make -j8` / `make install_sw`
      sequence
    * Output layout: `$PREFIX/lib/libcrypto.a`, `$PREFIX/include/openssl/*`

  Per-target differences are encoded in `Target` structs (see
  `target_spec/1`):
    * `configure_target` — `"android-arm64"`, `"android-arm"`,
      `"iossimulator-xcrun"`, `"ios64-xcrun"`
    * `default_prefix` — `/tmp/openssl-<target>`
    * `env_fn` — function that returns the `:env` list for `Shell.cmd`
      (Android targets set `ANDROID_NDK_ROOT` + prepend the NDK
      toolchain to `PATH`; iOS targets set `CC`/`CXX`/`AR`/`RANLIB`
      to xcrun-prefixed invocations)
    * `extra_configure_args` — Android adds `-D__ANDROID_API__=24`;
      arm32 adds `no-asm` (its hand-written ARM assembly emits non-PIC
      relocations against `OPENSSL_armcap_P` that ld.lld rejects).

  ## Verifying outputs

  `build/2` doesn't ship — it returns a map naming the produced files.
  Callers (or the integration test) can assert on the existence of
  those files. We don't run `file` or `xcrun nm` here; the shell did
  that as a final "did it produce something for the right arch" check.
  In Elixir, that's a separate `verify/2` step (TODO — likely lands in
  iter 4 alongside tarball verification).
  """

  alias MobDev.Release.{Errors, Shell}
  alias MobDev.NdkVersion

  @android_api 24
  @ios_min_version "17.0"
  @make_parallelism 8

  # ── Target spec ──────────────────────────────────────────────────────────

  defmodule Target do
    @moduledoc """
    One cross-compile target. `env_fn` is invoked at build time so it
    can read live `:code.lib_dir(:elixir)` / NDK version / etc.
    """

    @enforce_keys [:id, :configure_target, :default_prefix, :env_fn, :extra_configure_args]
    defstruct [:id, :configure_target, :default_prefix, :env_fn, :extra_configure_args]

    @type t :: %__MODULE__{
            id: :android_arm64 | :android_arm32 | :ios_sim | :ios_device,
            configure_target: String.t(),
            default_prefix: Path.t(),
            env_fn: (keyword() -> [{String.t(), String.t()}]),
            extra_configure_args: [String.t()]
          }
  end

  @doc "All known targets in canonical order."
  @spec targets() :: [atom()]
  def targets, do: [:android_arm64, :android_arm32, :android_x86_64, :ios_sim, :ios_device]

  @doc """
  Return the `Target` spec for an id. Public so tests can inspect specs
  without having to build them. Raises on unknown id (programmer error).
  """
  @spec target_spec(atom()) :: Target.t()
  def target_spec(:android_arm64) do
    %Target{
      id: :android_arm64,
      configure_target: "android-arm64",
      default_prefix: "/tmp/openssl-android-arm64",
      env_fn: &android_env/1,
      # arm64 hand-written assembly is PIC-safe — no `no-asm` needed.
      extra_configure_args: ["-D__ANDROID_API__=#{@android_api}"]
    }
  end

  def target_spec(:android_x86_64) do
    %Target{
      id: :android_x86_64,
      configure_target: "android-x86_64",
      default_prefix: "/tmp/openssl-android-x86_64",
      env_fn: &android_env/1,
      # x86_64 assembly is PIC-safe — no `no-asm` needed (like arm64).
      extra_configure_args: ["-D__ANDROID_API__=#{@android_api}"]
    }
  end

  def target_spec(:android_arm32) do
    %Target{
      id: :android_arm32,
      configure_target: "android-arm",
      default_prefix: "/tmp/openssl-android-arm32",
      env_fn: &android_env/1,
      # `no-asm` is required: arm32 hand-written ARM assembly emits
      # non-PIC absolute relocations against OPENSSL_armcap_P, which
      # ld.lld rejects when libcrypto.a is linked into the app's .so.
      # Removing this would re-introduce the build failure the shell
      # version's comment block documents.
      extra_configure_args: ["-D__ANDROID_API__=#{@android_api}", "no-asm"]
    }
  end

  def target_spec(:ios_sim) do
    %Target{
      id: :ios_sim,
      configure_target: "iossimulator-xcrun",
      default_prefix: "/tmp/openssl-ios-sim",
      env_fn: &ios_env(&1, :ios_sim),
      extra_configure_args: []
    }
  end

  def target_spec(:ios_device) do
    %Target{
      id: :ios_device,
      configure_target: "ios64-xcrun",
      default_prefix: "/tmp/openssl-ios-device",
      env_fn: &ios_env(&1, :ios_device),
      extra_configure_args: []
    }
  end

  # ── Configure-args assembly ──────────────────────────────────────────────

  @doc """
  Assemble the full `./Configure` argv (excluding the program name) for
  a given target + prefix. Public so tests can assert on the exact
  list without running a build.

  Returns the args in canonical order: configure_target, size flags,
  per-target extras, prefix flags, disable-algorithm flags. The order
  is observable (OpenSSL's Configure is sensitive to placement of some
  flags) — tests pin it.
  """
  @spec configure_args(Target.t(), Path.t()) :: [String.t()]
  def configure_args(%Target{} = target, prefix) do
    [target.configure_target] ++
      size_flags() ++
      target.extra_configure_args ++
      ["--prefix=#{prefix}", "--openssldir=#{prefix}/ssl"] ++
      disabled_algorithms()
  end

  @doc "Size + compile flags shared across all targets."
  @spec size_flags() :: [String.t()]
  def size_flags, do: ["-Os", "-ffunction-sections", "-fdata-sections", "-fPIC"]

  @doc """
  The full `no-X` list — legacy ciphers + protocols we don't ship.
  Public so tests can pin the surface and any addition surfaces in
  a code review rather than buried in a shell script.

  Every entry has a justification kept inline in `disabled_algorithms_doc/0`.
  """
  @spec disabled_algorithms() :: [String.t()]
  def disabled_algorithms do
    [
      "no-shared",
      "no-tests",
      "no-apps",
      "no-engine",
      # Superseded by SHA-2 / BLAKE2 — no modern code uses them.
      "no-md2",
      "no-md4",
      "no-mdc2",
      "no-whirlpool",
      "no-rmd160",
      # Legacy ciphers — AES-GCM + ChaCha20-Poly1305 cover real cryptography.
      "no-rc2",
      "no-rc4",
      "no-idea",
      "no-cast",
      "no-bf",
      "no-blake2",
      "no-seed",
      "no-aria",
      "no-camellia",
      # Russian-only standards.
      "no-gost",
      # RC4, single-DES, NULL, EXPORT.
      "no-weak-ssl-ciphers",
      # Pre-TLS-1.2. Refused by every modern server.
      "no-ssl3",
      "no-tls1",
      "no-tls1_1",
      # Pre-shared password/key TLS variants — niche.
      "no-srp",
      "no-psk",
      # Superseded by ALPN.
      "no-nextprotoneg"
    ]
  end

  # ── Build entrypoints ────────────────────────────────────────────────────

  @doc """
  Build OpenSSL for one target. Returns `{:ok, info}` where info names
  the produced artifacts, or a tagged error.

  Options:
    * `:openssl_src` — OpenSSL source checkout (default: `~/code/openssl`
      or `$OPENSSL_SRC` env)
    * `:prefix` — install dir (default: target's `default_prefix`)
    * `:ndk_root` — Android NDK root override (Android targets only)
  """
  @spec build(atom(), keyword()) :: {:ok, map()} | Errors.t()
  def build(target_id, opts \\ [])
      when target_id in [:android_arm64, :android_arm32, :android_x86_64, :ios_sim, :ios_device] do
    target = target_spec(target_id)
    shell = Shell.impl()
    openssl_src = opts[:openssl_src] || default_openssl_src(shell)
    prefix = opts[:prefix] || target.default_prefix
    env = target.env_fn.(opts)

    with :ok <- precheck(target, shell, openssl_src, opts),
         :ok <- maybe_distclean(shell, openssl_src, env),
         args = configure_args(target, prefix),
         {:ok, _} <- shell.cmd(["./Configure" | args], cd: openssl_src, env: env),
         {:ok, _} <- shell.cmd(["make", "-j#{@make_parallelism}"], cd: openssl_src, env: env),
         {:ok, _} <- shell.cmd(["make", "install_sw"], cd: openssl_src, env: env) do
      {:ok,
       %{
         target: target_id,
         prefix: prefix,
         libcrypto: Path.join([prefix, "lib", "libcrypto.a"]),
         libssl: Path.join([prefix, "lib", "libssl.a"]),
         include: Path.join(prefix, "include")
       }}
    end
  end

  @doc """
  Build all four targets in sequence. Returns a list of
  `{target_id, result}` pairs in canonical target order. Does NOT
  short-circuit on first failure — callers can decide what to do with
  partial results.
  """
  @spec build_all(keyword()) :: [{atom(), {:ok, map()} | Errors.t()}]
  def build_all(opts \\ []) do
    for target_id <- targets() do
      {target_id, build(target_id, opts)}
    end
  end

  # ── Preconditions ────────────────────────────────────────────────────────

  defp precheck(target, shell, openssl_src, opts) do
    cond do
      not shell.dir?(openssl_src) ->
        Errors.precondition(
          "OPENSSL_SRC missing at #{openssl_src} — clone github.com/openssl/openssl and pass `openssl_src:`"
        )

      target.id in [:android_arm64, :android_arm32, :android_x86_64] ->
        android_precheck(shell, opts)

      target.id in [:ios_sim, :ios_device] ->
        ios_precheck(shell, target.id)
    end
  end

  defp android_precheck(shell, opts) do
    ndk_root = opts[:ndk_root] || default_ndk_root()

    cond do
      not shell.dir?(ndk_root) ->
        Errors.precondition(
          "Android NDK not at #{ndk_root} — install NDK #{NdkVersion.effective()} " <>
            "via Android Studio SDK manager or set `ndk_root:` opt"
        )

      not shell.dir?(android_toolchain(ndk_root)) ->
        Errors.precondition(
          "NDK toolchain not at #{android_toolchain(ndk_root)} — verify install integrity"
        )

      true ->
        :ok
    end
  end

  defp ios_precheck(shell, target_id) do
    sdk = ios_sdk_name(target_id)

    case shell.cmd(["xcrun", "--sdk", sdk, "--show-sdk-path"], []) do
      {:ok, _} ->
        :ok

      {:error, _} ->
        Errors.precondition(
          "iOS #{sdk} SDK not available — install Xcode + run xcode-select --install"
        )
    end
  end

  defp ios_sdk_name(:ios_sim), do: "iphonesimulator"
  defp ios_sdk_name(:ios_device), do: "iphoneos"

  # ── distclean (best-effort) ─────────────────────────────────────────────

  defp maybe_distclean(shell, openssl_src, env) do
    # The shell script does `make distclean >/dev/null 2>&1 || true`.
    # First-time builds have nothing to clean; subsequent builds for
    # a different arch need the clean to drop the prior config. Either
    # way, we don't care about the result — just don't let it stop us.
    _ = shell.cmd(["make", "distclean"], cd: openssl_src, env: env)
    :ok
  end

  # ── Per-target env builders ──────────────────────────────────────────────

  defp android_env(opts) do
    ndk_version = opts[:ndk_version] || NdkVersion.effective()
    ndk_root = opts[:ndk_root] || default_ndk_root(ndk_version)
    toolchain = android_toolchain(ndk_root)
    current_path = System.get_env("PATH", "")

    [
      {"ANDROID_NDK_ROOT", ndk_root},
      {"PATH", "#{toolchain}/bin:#{current_path}"}
    ]
  end

  defp ios_env(_opts, target_id) do
    sdk = ios_sdk_name(target_id)
    min_flag = ios_min_version_flag(target_id)

    cc = "xcrun -sdk #{sdk} clang -arch arm64 #{min_flag}"
    cxx = "xcrun -sdk #{sdk} clang++ -arch arm64 #{min_flag}"
    ar = "xcrun -sdk #{sdk} ar"
    ranlib = "xcrun -sdk #{sdk} ranlib"

    [
      {"CC", cc},
      {"CXX", cxx},
      {"AR", ar},
      {"RANLIB", ranlib}
    ]
  end

  defp ios_min_version_flag(:ios_sim), do: "-mios-simulator-version-min=#{@ios_min_version}"
  defp ios_min_version_flag(:ios_device), do: "-miphoneos-version-min=#{@ios_min_version}"

  # ── Defaults ─────────────────────────────────────────────────────────────

  defp default_openssl_src(shell) do
    case shell.fetch_env("OPENSSL_SRC") do
      {:ok, path} -> path
      :error -> Path.join(System.user_home!(), "code/openssl")
    end
  end

  defp default_ndk_root(ndk_version \\ nil) do
    version = ndk_version || NdkVersion.effective()
    Path.join([System.user_home!(), "Library/Android/sdk/ndk", version])
  end

  defp android_toolchain(ndk_root) do
    # Host-OS detection: darwin-x86_64 covers Apple Silicon too (Apple
    # ships Rosetta x86_64 toolchain — NDK r27 doesn't have an arm64
    # variant yet). When NDK ships native arm64-darwin we'd add a
    # detection branch here.
    Path.join([ndk_root, "toolchains/llvm/prebuilt", "darwin-x86_64"])
  end
end
