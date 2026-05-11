defmodule MobDev.Release.OpenSSL.CryptoNif do
  @moduledoc """
  Replaces `scripts/release/openssl/build_crypto_static_*.sh` (×4).
  Compiles OTP's crypto NIF C sources with `-DSTATIC_ERLANG_NIF` for one
  target ABI and archives the result as `crypto.a`. Pairs with
  `MobDev.Release.OpenSSL` (the OpenSSL build itself) to produce the
  two `.a` files that get static-linked into the user app's main
  native binary:

      $OPENSSL_PREFIX/lib/libcrypto.a   ← from MobDev.Release.OpenSSL
      $OTP_SRC/lib/crypto/priv/lib/<arch>/crypto.a   ← from this module

  ## Why static-link the crypto NIF?

  Different reasons on each platform; the artifact is the same.

    * **Android.** dlopen'd children inherit `RTLD_LOCAL` by default,
      which hides the parent's `enif_*` symbols from `crypto.so`.
      `crypto.so`'s `on_load` then fails with "cannot locate symbol".
      Static linking sidesteps that — the BEAM finds
      `crypto_nif_init` via `dlsym(RTLD_DEFAULT)` instead of dlopen.
    * **iOS.** App Store forbids loading unsigned dylib/dlopen — every
      NIF must be present in the final signed binary. Same artifact.

  ## Per-target deltas (the spec)

  All four targets compile the same 30 source files (`@sources`) with a
  shared base CFLAGS list (`@base_cflags`). The deltas are:

  | Target        | Arch dir                        | Toolchain          | Extra CFLAGS                                  | nm symbol         |
  |---------------|---------------------------------|--------------------|-----------------------------------------------|-------------------|
  | android_arm64 | aarch64-unknown-linux-android   | NDK clang/llvm-ar  | Android hardening: branch-protect, stack-clash, _GNU_SOURCE | `crypto_nif_init`  |
  | android_arm32 | arm-unknown-linux-androideabi   | NDK clang/llvm-ar  | Android hardening + `-march=armv7-a -mfloat-abi=softfp -mthumb` | `crypto_nif_init`  |
  | ios_sim       | aarch64-apple-iossimulator      | xcrun (sim SDK)    | iOS minimal — no Android hardening            | `_crypto_nif_init` |
  | ios_device    | aarch64-apple-ios               | xcrun (device SDK) | iOS minimal — no Android hardening            | `_crypto_nif_init` |

  ## Phases

  Each `build/2` call:
    1. Precheck — OTP source + OpenSSL prefix exist; Android/iOS
       toolchain reachable.
    2. Compile — for each of @sources, run `<cc> <cflags> -c -o obj src`.
    3. Archive — `<ar> rcs crypto.a obj1 obj2 ...` then `<ranlib> crypto.a`.
    4. Verify — `<nm> crypto.a`, scan output for the expected symbol.
       Symbol missing is a `:precondition_failed` (means our compile
       didn't actually produce `crypto_nif_init` — usually because the
       OTP source moved out from under us).
  """

  alias MobDev.Release.{Errors, Shell}
  alias MobDev.NdkVersion

  @android_api 24
  @ios_min_version "17.0"

  # ── Source list — OTP's crypto NIF C files, minus otp_test_engine.c ─────

  @sources [
    "aead.c",
    "aes.c",
    "algorithms.c",
    "api_ng.c",
    "atoms.c",
    "bn.c",
    "cipher.c",
    "cmac.c",
    "common.c",
    "crypto.c",
    "crypto_callback.c",
    "dh.c",
    "digest.c",
    "dss.c",
    "ec.c",
    "ecdh.c",
    "eddsa.c",
    "engine.c",
    "evp.c",
    "fips.c",
    "hash.c",
    "hash_equals.c",
    "hmac.c",
    "info.c",
    "mac.c",
    "math.c",
    "pbkdf2_hmac.c",
    "pkey.c",
    "rand.c",
    "rsa.c",
    "srp.c"
  ]

  @doc "Source files compiled for every target. Public so tests can pin the surface."
  @spec sources() :: [String.t()]
  def sources, do: @sources

  # ── Base CFLAGS — shared across all targets ─────────────────────────────

  @base_cflags [
    "-fno-strict-aliasing",
    "-fno-delete-null-pointer-checks",
    "-fno-strict-overflow",
    "-fexceptions",
    "-fstack-protector-strong",
    "-U_FORTIFY_SOURCE",
    "-D_FORTIFY_SOURCE=3",
    "-fno-common",
    "-g",
    "-Os",
    "-ffunction-sections",
    "-fdata-sections",
    "-fPIC",
    "-DHAVE_OPENSSL_CRYPTO_MEMCMP",
    "-DSTATIC_ERLANG_NIF",
    "-DDISABLE_EVP_DH=0",
    "-DDISABLE_EVP_HMAC=0",
    "-Wno-deprecated-declarations"
  ]

  @doc "Base CFLAGS shared across all targets. Public for testing."
  @spec base_cflags() :: [String.t()]
  def base_cflags, do: @base_cflags

  # Android targets add hardening flags + _GNU_SOURCE. iOS doesn't ship
  # these — they're either non-applicable (no branch-protect on iOS
  # arm64 — Apple's PAC is enabled differently) or Apple's SDK already
  # defines its own equivalents.
  @android_extra_cflags [
    "-fstrict-flex-arrays=3",
    "-mbranch-protection=standard",
    "-fstack-clash-protection",
    "-D_GNU_SOURCE"
  ]

  # arm32 additionally needs ABI flags: armv7-a target arch, softfp ABI
  # (required for Android — Google's API contract pins this), and -mthumb
  # to match NDK's default code-gen.
  @arm32_extra_cflags ["-march=armv7-a", "-mfloat-abi=softfp", "-mthumb"]

  # ── Target spec ─────────────────────────────────────────────────────────

  defmodule Target do
    @moduledoc "Per-target description: arch path layout, toolchain factory, extra CFLAGS, expected nm symbol."

    @enforce_keys [:id, :arch_dir, :tools_fn, :extra_cflags, :nm_symbol, :default_prefix]
    defstruct [:id, :arch_dir, :tools_fn, :extra_cflags, :nm_symbol, :default_prefix]

    @type tools :: %{cc: [String.t()], ar: [String.t()], ranlib: [String.t()], nm: [String.t()]}

    @type t :: %__MODULE__{
            id: :android_arm64 | :android_arm32 | :ios_sim | :ios_device,
            arch_dir: String.t(),
            tools_fn: (keyword() -> tools()),
            extra_cflags: [String.t()],
            nm_symbol: String.t(),
            default_prefix: Path.t()
          }
  end

  @doc "All known crypto-NIF targets. Same set as `MobDev.Release.OpenSSL.targets/0`."
  @spec targets() :: [atom()]
  def targets, do: [:android_arm64, :android_arm32, :ios_sim, :ios_device]

  @doc """
  Per-target spec. Public so tests can lock down the surface
  (especially the `extra_cflags` lists — silent drops there would
  silently weaken released binaries).
  """
  @spec target_spec(atom()) :: Target.t()
  def target_spec(:android_arm64) do
    %Target{
      id: :android_arm64,
      arch_dir: "aarch64-unknown-linux-android",
      tools_fn: &android_tools(&1, :android_arm64),
      extra_cflags: @android_extra_cflags,
      nm_symbol: "crypto_nif_init",
      default_prefix: "/tmp/openssl-android-arm64"
    }
  end

  def target_spec(:android_arm32) do
    %Target{
      id: :android_arm32,
      arch_dir: "arm-unknown-linux-androideabi",
      tools_fn: &android_tools(&1, :android_arm32),
      extra_cflags: @arm32_extra_cflags ++ @android_extra_cflags,
      nm_symbol: "crypto_nif_init",
      default_prefix: "/tmp/openssl-android-arm32"
    }
  end

  def target_spec(:ios_sim) do
    %Target{
      id: :ios_sim,
      arch_dir: "aarch64-apple-iossimulator",
      tools_fn: &ios_tools(&1, :ios_sim),
      extra_cflags: [],
      # Mach-O symbols carry a leading underscore in the nm output.
      nm_symbol: "_crypto_nif_init",
      default_prefix: "/tmp/openssl-ios-sim"
    }
  end

  def target_spec(:ios_device) do
    %Target{
      id: :ios_device,
      arch_dir: "aarch64-apple-ios",
      tools_fn: &ios_tools(&1, :ios_device),
      extra_cflags: [],
      nm_symbol: "_crypto_nif_init",
      default_prefix: "/tmp/openssl-ios-device"
    }
  end

  # ── CFLAGS assembly (pure) ──────────────────────────────────────────────

  @doc """
  Assemble the full CFLAGS list for a target, given OpenSSL prefix +
  OTP source path. Pure function for testability — silent flag drops
  are the exact regression class this module exists to prevent.

  Order: base CFLAGS + per-target extras + include paths. Includes
  carry the arch_dir suffix on OTP-internal headers because OTP
  per-arch's `erl_int_sizes_config.h` lives there.
  """
  @spec cflags(Target.t(), Path.t(), Path.t()) :: [String.t()]
  def cflags(%Target{} = target, openssl_prefix, otp_src) do
    @base_cflags ++
      target.extra_cflags ++
      [
        "-I#{openssl_prefix}/include",
        "-I#{otp_src}/erts/emulator/beam",
        "-I#{otp_src}/erts/include",
        "-I#{otp_src}/erts/include/#{target.arch_dir}",
        "-I#{otp_src}/erts/include/internal",
        "-I#{otp_src}/erts/include/internal/#{target.arch_dir}",
        "-I#{otp_src}/erts/emulator/sys/unix",
        "-I#{otp_src}/erts/emulator/sys/common"
      ]
  end

  # ── Build entrypoint ────────────────────────────────────────────────────

  @doc """
  Compile + archive + verify the crypto NIF for one target. Returns
  `{:ok, info}` naming the produced archive, or a tagged error.

  Options:
    * `:otp_src` — OTP source checkout (default: `$OTP_SRC` env or
      `~/code/otp`)
    * `:openssl_prefix` — OpenSSL install dir (default: target's
      `default_prefix`)
    * `:ndk_root` — Android NDK root (Android targets only)
  """
  @spec build(atom(), keyword()) :: {:ok, map()} | Errors.t()
  def build(target_id, opts \\ []) when target_id in [:android_arm64, :android_arm32, :ios_sim, :ios_device] do
    target = target_spec(target_id)
    shell = Shell.impl()
    otp_src = opts[:otp_src] || default_otp_src(shell)
    openssl_prefix = opts[:openssl_prefix] || target.default_prefix

    paths = %{
      crypto_src: Path.join([otp_src, "lib/crypto/c_src"]),
      obj_dir: Path.join([otp_src, "lib/crypto/priv/obj/#{target.arch_dir}_static_nif"]),
      lib_dir: Path.join([otp_src, "lib/crypto/priv/lib/#{target.arch_dir}"])
    }

    with :ok <- precheck(target, shell, otp_src, openssl_prefix, opts),
         tools = target.tools_fn.(opts),
         flags = cflags(target, openssl_prefix, otp_src),
         :ok <- shell.mkdir_p(paths.obj_dir),
         :ok <- shell.mkdir_p(paths.lib_dir),
         {:ok, objects} <- compile_sources(shell, tools, flags, paths),
         archive = Path.join(paths.lib_dir, "crypto.a"),
         :ok <- shell.rm_f(archive),
         {:ok, _} <- shell.cmd(tools.ar ++ ["rcs", archive | objects], []),
         {:ok, _} <- shell.cmd(tools.ranlib ++ [archive], []),
         :ok <- verify_symbol(shell, tools.nm, archive, target.nm_symbol) do
      {:ok, %{target: target_id, archive: archive, objects: objects}}
    end
  end

  defp compile_sources(shell, tools, flags, paths) do
    Enum.reduce_while(@sources, {:ok, []}, fn src, {:ok, acc} ->
      src_path = Path.join(paths.crypto_src, src)
      obj_path = Path.join(paths.obj_dir, String.replace_suffix(src, ".c", ".o"))

      argv = tools.cc ++ flags ++ ["-c", "-o", obj_path, src_path]

      case shell.cmd(argv, []) do
        {:ok, _} -> {:cont, {:ok, [obj_path | acc]}}
        err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, objs} -> {:ok, Enum.reverse(objs)}
      err -> err
    end
  end

  defp verify_symbol(shell, nm_argv, archive, expected_symbol) do
    case shell.cmd(nm_argv ++ [archive], []) do
      {:ok, output} -> check_symbol_present(output, expected_symbol, archive)
      err -> err
    end
  end

  @doc """
  Parse `nm` output and confirm the expected `crypto_nif_init` symbol
  is exported (`T` flag in nm's output). Returns `:ok` or a tagged
  precondition_failed.

  Public for testing — the shell version did `nm <archive> | grep -E
  ' T crypto_nif_init$' | head -3` and silently let release ship if
  the grep returned 0 lines.  This module's behaviour: missing symbol
  is a hard failure with a clear message.
  """
  @spec check_symbol_present(binary(), String.t(), Path.t()) :: :ok | Errors.t()
  def check_symbol_present(nm_output, expected_symbol, archive) when is_binary(nm_output) do
    # nm output lines look like:
    #   0000000000000000 T crypto_nif_init
    #   0000000000000018 T _other_symbol
    # We want " T <symbol>" with nothing after — exact match on the
    # symbol name. Anchoring to end-of-line catches the case where some
    # related symbol shares a prefix.
    pattern = ~r/^\s*[0-9a-f]+ T #{Regex.escape(expected_symbol)}\s*$/m

    if Regex.match?(pattern, nm_output) do
      :ok
    else
      Errors.precondition(
        "expected `T #{expected_symbol}` not found in #{archive} — " <>
          "did OTP's crypto source layout change? Did -DSTATIC_ERLANG_NIF get dropped?"
      )
    end
  end

  # ── Preconditions ──────────────────────────────────────────────────────

  defp precheck(target, shell, otp_src, openssl_prefix, opts) do
    cond do
      not shell.dir?(otp_src) ->
        Errors.precondition(
          "OTP_SRC missing at #{otp_src} — clone github.com/erlang/otp"
        )

      not shell.dir?(openssl_prefix) ->
        Errors.precondition(
          "OPENSSL_PREFIX missing at #{openssl_prefix} — run MobDev.Release.OpenSSL.build(#{inspect(target.id)}) first"
        )

      target.id in [:android_arm64, :android_arm32] ->
        android_precheck(shell, opts)

      target.id in [:ios_sim, :ios_device] ->
        :ok
    end
  end

  defp android_precheck(shell, opts) do
    ndk_root = opts[:ndk_root] || default_ndk_root()

    if shell.dir?(ndk_root) do
      :ok
    else
      Errors.precondition(
        "Android NDK not at #{ndk_root} — install NDK #{NdkVersion.effective()}"
      )
    end
  end

  # ── Per-target toolchain factories ─────────────────────────────────────

  defp android_tools(opts, target_id) do
    toolchain_bin = android_toolchain_bin(opts)
    cc_name = android_cc_name(target_id)

    %{
      cc: [Path.join(toolchain_bin, cc_name)],
      ar: [Path.join(toolchain_bin, "llvm-ar")],
      ranlib: [Path.join(toolchain_bin, "llvm-ranlib")],
      nm: [Path.join(toolchain_bin, "llvm-nm")]
    }
  end

  defp android_cc_name(:android_arm64), do: "aarch64-linux-android#{@android_api}-clang"
  defp android_cc_name(:android_arm32), do: "armv7a-linux-androideabi#{@android_api}-clang"

  defp ios_tools(_opts, target_id) do
    sdk = ios_sdk_name(target_id)
    min_flag = ios_min_version_flag(target_id)

    %{
      cc: ["xcrun", "-sdk", sdk, "clang", "-arch", "arm64", min_flag],
      ar: ["xcrun", "-sdk", sdk, "ar"],
      ranlib: ["xcrun", "-sdk", sdk, "ranlib"],
      nm: ["xcrun", "-sdk", sdk, "nm"]
    }
  end

  defp ios_sdk_name(:ios_sim), do: "iphonesimulator"
  defp ios_sdk_name(:ios_device), do: "iphoneos"

  defp ios_min_version_flag(:ios_sim), do: "-mios-simulator-version-min=#{@ios_min_version}"
  defp ios_min_version_flag(:ios_device), do: "-miphoneos-version-min=#{@ios_min_version}"

  # ── Defaults ───────────────────────────────────────────────────────────

  defp default_otp_src(shell) do
    case shell.fetch_env("OTP_SRC") do
      {:ok, path} -> path
      :error -> Path.join(System.user_home!(), "code/otp")
    end
  end

  defp default_ndk_root do
    Path.join([System.user_home!(), "Library/Android/sdk/ndk", NdkVersion.effective()])
  end

  defp android_toolchain_bin(opts) do
    ndk_root = opts[:ndk_root] || default_ndk_root()
    Path.join([ndk_root, "toolchains/llvm/prebuilt/darwin-x86_64/bin"])
  end
end
