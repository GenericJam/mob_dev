defmodule MobDev.Release.Tarball do
  @moduledoc """
  Replaces `scripts/release/tarball_*.sh` × 4 — the staging + `tar czf`
  step that produces the `otp-<target>-<hash>.tar.gz` archive
  `MobDev.OtpDownloader` later fetches.

      iex> MobDev.Release.Tarball.build(:android_arm64,
      ...>   exqlite_build: "/path/to/_build/dev/lib/exqlite")
      {:ok, %{tarball: "/tmp/otp-android-abc12345.tar.gz", target: :android_arm64}}

  ## Per-target variation (the richest of any iter so far)

  | Field                          | android_arm64       | android_arm32              | ios_sim         | ios_device                |
  |--------------------------------|---------------------|----------------------------|-----------------|---------------------------|
  | Tarball basename               | `otp-android`       | `otp-android-arm32`        | `otp-ios-sim`   | `otp-ios-device`          |
  | Borrow crypto/pk/ssl apps from | (built in-tree)     | (built in-tree)            | Android install | Android install           |
  | Bundle exqlite BEAMs           | yes                 | yes                        | no              | no                        |
  | Bundle EPMD source             | no                  | no                         | no              | yes (for static-link)     |
  | Verify crypto.so present       | yes                 | no                         | no              | no                        |
  | tar --exclude paths            | (none)              | (none)                     | test-app dirs   | (none)                    |

  Note the asymmetry in `tarball_basename`: the Android arm64 tarball is
  `otp-android-<hash>.tar.gz` (NOT `otp-android-arm64-...`), preserved
  for backward compat with `MobDev.OtpDownloader.@otp_hash` —
  changing this would break every existing cache entry.

  ## Why iOS targets "borrow" crypto/public_key/ssl apps from Android

  iOS OTP is cross-compiled `--without-ssl` (the iOS xcomp confs use
  `--enable-static-nifs` and OTP's build system doesn't propagate
  `--with-ssl` to beam.emu's link in that mode). The `crypto`,
  `public_key`, and `ssl` Erlang apps therefore aren't produced for
  iOS. BEAM bytecode is platform-neutral, so we copy these apps'
  ebins from the Android arm64 install tree — they're the same
  bytecode. The platform-specific NIF artifacts they ship in `priv/`
  are obsolete on iOS anyway because we replace `crypto.so` with the
  static `crypto.a` + `libcrypto.a` we just baked.

  ## What "build" does end-to-end

    1. Stage — mktemp + `cp -r <otp_release>/.` (the cross-compiled
       OTP install tree from `MobDev.Release.OTP`)
    2. Borrow apps — iOS targets only. cp from
       `<android_otp_release>/lib/{crypto,public_key,ssl}-*`.
    3. Static libs — cp the four arch-specific `.a` files
       (`libzstd.a`, `libepcre.a`, `libryu.a`, `asn1rt_nif.a`) into
       `<stage>/erts-<vsn>/lib/`.
    4. Crypto archives — cp `crypto.a` (from
       `MobDev.Release.OpenSSL.CryptoNif`) + `libcrypto.a` (from
       `MobDev.Release.OpenSSL`) into the same place.
    5. ERTS headers — cp the 5 headers (`erl_nif.h`,
       `erl_nif_api_funcs.h`, `erl_drv_nif.h`,
       `erl_fixed_size_int_types.h`, arch-specific
       `erl_int_sizes_config.h`) into `<stage>/erts-<vsn>/include/`.
    6. Elixir stdlib — `MobDev.Release.Helpers.bundle_elixir_stdlib/2`
       (elixir, logger, eex ebins).
    7. exqlite BEAMs — Android targets only. Detect version from
       mix.lock; cp ebins into `<stage>/lib/exqlite-<vsn>/`.
    8. EPMD source — iOS device only. cp the 3 `.c` files + headers
       + the arch-specific config dir.
    9. tar czf the stage into `<out_dir>/<basename>-<hash>.tar.gz`,
       honouring per-target `--exclude` flags.
    10. Verify — `tar tzf | grep <pattern>` for each per-target
        required entry. Missing entries fail loudly rather than
        ship a broken tarball.

  ## Why mix.lock parsing lives here

  Android tarballs ship exqlite BEAMs that the user app loads as a NIF
  on device. The version of those BEAMs has to match the user app's
  `_build/dev/lib/exqlite/` ebins so dialyzer behaviours and protocol
  consolidation line up. Detecting the exqlite version means parsing
  mix.lock — a small regex on a known shape. Pure function, tested.
  """

  alias MobDev.Release.{Errors, Shell, Helpers}

  # ── Target spec ────────────────────────────────────────────────────────

  defmodule Target do
    @moduledoc "Per-target tarball staging description."

    @enforce_keys [
      :id,
      :arch_dir,
      :tarball_basename,
      :default_otp_release,
      :openssl_prefix_default,
      :include_exqlite,
      :include_epmd_source,
      :borrow_crypto_apps,
      :additional_verifies,
      :tar_excludes
    ]
    defstruct [
      :id,
      :arch_dir,
      :tarball_basename,
      :default_otp_release,
      :openssl_prefix_default,
      :include_exqlite,
      :include_epmd_source,
      :borrow_crypto_apps,
      :additional_verifies,
      :tar_excludes
    ]

    @type t :: %__MODULE__{
            id: :android_arm64 | :android_arm32 | :ios_sim | :ios_device,
            arch_dir: String.t(),
            tarball_basename: String.t(),
            default_otp_release: Path.t(),
            openssl_prefix_default: Path.t(),
            include_exqlite: boolean(),
            include_epmd_source: boolean(),
            # Path of an Android install to copy crypto/public_key/ssl
            # apps from, or nil (Android targets — they're built in-tree).
            borrow_crypto_apps: Path.t() | nil,
            # Additional `tar tzf | grep <pattern>` entries to verify
            # beyond the universal ones.
            additional_verifies: [String.t()],
            # Paths (relative to the stage root) to exclude from the tarball.
            tar_excludes: [String.t()]
          }
  end

  @doc "All tarball targets, in canonical order."
  @spec targets() :: [atom()]
  def targets, do: [:android_arm64, :android_arm32, :ios_sim, :ios_device]

  @doc """
  Per-target spec. Public for testing — surface lock-down for tarball
  naming (changing the basename breaks the downloader's cache), the
  iOS borrow-from-Android decision, and the per-target verify list.
  """
  @spec target_spec(atom()) :: Target.t()
  def target_spec(:android_arm64) do
    %Target{
      id: :android_arm64,
      arch_dir: "aarch64-unknown-linux-android",
      # Asymmetric: this is `otp-android` not `otp-android-arm64`.
      # MobDev.OtpDownloader's @otp_hash cache convention depends on
      # this — DO NOT change without bumping every cached tarball.
      tarball_basename: "otp-android",
      default_otp_release: "/tmp/otp-android",
      openssl_prefix_default: "/tmp/openssl-android-arm64",
      include_exqlite: true,
      include_epmd_source: false,
      borrow_crypto_apps: nil,
      # arm64 verifies the runtime crypto NIF + ssl/public_key ebins
      # are present — proves --with-ssl was wired correctly in
      # MobDev.Release.OTP. arm32 doesn't (the shell version didn't
      # either; matches the historical asymmetry).
      additional_verifies: [
        "lib/crypto-.*/priv/lib/crypto.so",
        "lib/public_key-.*/ebin/public_key.beam",
        "lib/ssl-.*/ebin/ssl.beam"
      ],
      tar_excludes: []
    }
  end

  def target_spec(:android_arm32) do
    %Target{
      id: :android_arm32,
      arch_dir: "arm-unknown-linux-androideabi",
      tarball_basename: "otp-android-arm32",
      default_otp_release: "/tmp/otp-android-arm32",
      openssl_prefix_default: "/tmp/openssl-android-arm32",
      include_exqlite: true,
      include_epmd_source: false,
      borrow_crypto_apps: nil,
      additional_verifies: [],
      tar_excludes: []
    }
  end

  def target_spec(:ios_sim) do
    %Target{
      id: :ios_sim,
      arch_dir: "aarch64-apple-iossimulator",
      tarball_basename: "otp-ios-sim",
      default_otp_release: "/tmp/otp-ios-sim",
      openssl_prefix_default: "/tmp/openssl-ios-sim",
      include_exqlite: false,
      include_epmd_source: false,
      # iOS borrows from the Android arm64 install (BEAM bytecode is
      # arch-independent; iOS OTP was --without-ssl so doesn't produce
      # these apps).
      borrow_crypto_apps: "/tmp/otp-android",
      additional_verifies: [],
      # The iOS sim OTP_RELEASE often has stray test-app build dirs;
      # excluding them keeps the tarball small + reproducible.
      tar_excludes: ["beamhello", "test_app", "test_app0"]
    }
  end

  def target_spec(:ios_device) do
    %Target{
      id: :ios_device,
      arch_dir: "aarch64-apple-ios",
      tarball_basename: "otp-ios-device",
      default_otp_release: "/tmp/otp-ios-device",
      openssl_prefix_default: "/tmp/openssl-ios-device",
      include_exqlite: false,
      include_epmd_source: true,
      borrow_crypto_apps: "/tmp/otp-android",
      # iOS device tarball ships EPMD source for static-link — the
      # per-app build.zig compiles these into the .app's main native lib.
      additional_verifies: [
        "erts/epmd/src/epmd.c",
        "erts/epmd/src/epmd_srv.c",
        "erts/epmd/src/epmd_cli.c",
        "erts/epmd/src/epmd.h",
        "erts/epmd/src/epmd_int.h",
        "erts/aarch64-apple-ios/config.h"
      ],
      tar_excludes: []
    }
  end

  # ── Tarball-name + path assembly (pure) ────────────────────────────────

  @doc """
  Final tarball path: `<out_dir>/<basename>-<hash>.tar.gz`. Public for
  testing — basename drift breaks the downloader's cache.
  """
  @spec tarball_path(Target.t(), Path.t(), String.t()) :: Path.t()
  def tarball_path(%Target{} = target, out_dir, hash) when is_binary(hash) do
    Path.join(out_dir, "#{target.tarball_basename}-#{hash}.tar.gz")
  end

  # ── exqlite version detection (pure) ───────────────────────────────────

  @doc """
  Parse the `exqlite` package version out of a mix.lock string.
  Returns `{:ok, version}` or a tagged error.

  Public for testing — silent parse failures here would silently bundle
  no exqlite, then user apps die at runtime with `:undef`.
  """
  @spec parse_exqlite_version_from_lock(binary()) :: {:ok, String.t()} | Errors.t()
  def parse_exqlite_version_from_lock(content) when is_binary(content) do
    # mix.lock entries look like:
    #   "exqlite": {:hex, :exqlite, "0.39.0", "...", ...}
    # We want the version string. Match the package name explicitly to
    # avoid false-matching another dep whose version field shares a
    # prefix.
    case Regex.run(~r/"exqlite":\s*\{:hex,\s*:exqlite,\s*"([^"]+)"/, content,
           capture: :all_but_first
         ) do
      [vsn] -> {:ok, vsn}
      _ -> Errors.parse_failed(content, "exqlite version line in mix.lock")
    end
  end

  @doc """
  Parse the `vsn` field out of an `exqlite.app` file's content.
  Fallback for when mix.lock isn't available (rare, but the shell
  version handled it). Returns `{:ok, version}` or a tagged error.
  """
  @spec parse_exqlite_version_from_app_file(binary()) :: {:ok, String.t()} | Errors.t()
  def parse_exqlite_version_from_app_file(content) when is_binary(content) do
    # OTP .app files look like:
    #   {application, exqlite, [{vsn, "0.39.0"}, ...]}
    case Regex.run(~r/\{vsn,\s*"([^"]+)"\}/, content, capture: :all_but_first) do
      [vsn] -> {:ok, vsn}
      _ -> Errors.parse_failed(content, "{vsn, \"...\"} entry in exqlite.app")
    end
  end

  @doc """
  Detect the exqlite version by reading mix.lock (preferred) or
  `<exqlite_build>/ebin/exqlite.app` (fallback). Returns `{:ok, vsn}`.

  `exqlite_build` is the path to `_build/dev/lib/exqlite/` in any Mob
  project that has run `mix deps.get && mix compile`.

  Project root lookup: mix.lock lives 4 levels up from
  `_build/dev/lib/exqlite/` — that's the project root convention every
  Hex umbrella uses.
  """
  @spec detect_exqlite_version(Path.t()) :: {:ok, String.t()} | Errors.t()
  def detect_exqlite_version(exqlite_build) do
    # Prefer mix.lock — it's the authoritative source.
    project_root = exqlite_build |> Path.join(["..", "..", "..", ".."]) |> Path.expand()
    mix_lock = Path.join(project_root, "mix.lock")

    case File.read(mix_lock) do
      {:ok, content} ->
        case parse_exqlite_version_from_lock(content) do
          {:ok, vsn} -> {:ok, vsn}
          {:error, _} -> detect_from_app_file(exqlite_build)
        end

      {:error, _} ->
        detect_from_app_file(exqlite_build)
    end
  end

  defp detect_from_app_file(exqlite_build) do
    app_file = Path.join([exqlite_build, "ebin", "exqlite.app"])

    case File.read(app_file) do
      {:ok, content} -> parse_exqlite_version_from_app_file(content)
      {:error, reason} -> Errors.fs_failed(app_file, reason)
    end
  end

  # ── Build entrypoint ───────────────────────────────────────────────────

  @doc """
  Stage + tar the per-target OTP runtime tarball. Returns `{:ok, info}`
  naming the produced tarball + final size, or a tagged error.

  Options:
    * `:otp_src` — OTP source checkout (default: `$OTP_SRC` env or `~/code/otp`)
    * `:otp_release` — install tree from `MobDev.Release.OTP.build/2`
      (default: target's `default_otp_release`)
    * `:openssl_prefix` — OpenSSL install dir (default per-target)
    * `:exqlite_build` — `_build/dev/lib/exqlite` in any project (required
      for Android targets; ignored for iOS)
    * `:android_otp_release` — used by iOS targets to borrow crypto
      apps (default: `/tmp/otp-android`)
    * `:asn1rt_nif_arm32` — pre-built arm32 asn1rt_nif.a (Android arm32
      only; default: `/tmp/asn1rt_nif_arm32.a`)
    * `:out_dir` — tarball output (default: `/tmp`)
    * `:hash` — release hash (default: detected from OTP source git)
  """
  @spec build(atom(), keyword()) :: {:ok, map()} | Errors.t()
  def build(target_id, opts \\ [])
      when target_id in [:android_arm64, :android_arm32, :ios_sim, :ios_device] do
    target = target_spec(target_id)
    shell = Shell.impl()
    otp_src = opts[:otp_src] || Helpers.default_otp_src()

    # Explicit otp_src dir check FIRST. Without this, resolve_release_env's
    # implicit File.read on erts/vsn.mk fires first and returns fs_failed
    # with a confusing path-with-vsn.mk-suffix rather than the actionable
    # "OTP_SRC missing" precondition_failed.
    if not shell.dir?(otp_src) do
      Errors.precondition("OTP_SRC missing at #{otp_src} — clone github.com/erlang/otp")
    else
      with {:ok, env} <-
             Helpers.resolve_release_env(Keyword.take(opts, [:otp_src, :hash, :out_dir])),
           otp_release = opts[:otp_release] || target.default_otp_release,
           openssl_prefix = opts[:openssl_prefix] || target.openssl_prefix_default,
           :ok <- precheck(target, shell, env, otp_release, openssl_prefix, opts) do
        do_build(target, shell, env, otp_release, openssl_prefix, opts)
      end
    end
  end

  defp do_build(target, shell, env, otp_release, openssl_prefix, opts) do
    stage = mktemp_stage(shell)

    try do
      with :ok <- stage_otp_release(shell, otp_release, stage),
           :ok <- maybe_borrow_crypto_apps(target, shell, opts, stage),
           :ok <- stage_static_libs(target, shell, env, otp_release, opts, openssl_prefix, stage),
           :ok <- stage_erts_headers(target, shell, env, stage),
           {:ok, _} <- Helpers.bundle_elixir_stdlib(stage, env.elixir_lib),
           :ok <- maybe_stage_exqlite(target, shell, opts, stage),
           :ok <- maybe_stage_epmd(target, shell, env, stage),
           tarball = tarball_path(target, env.out_dir, env.hash),
           :ok <- tar_stage(target, shell, stage, tarball),
           :ok <- verify_tarball(target, shell, env, tarball) do
        {:ok, %{target: target.id, tarball: tarball, hash: env.hash, erts_vsn: env.erts_vsn}}
      end
    after
      _ = shell.cmd(["rm", "-rf", stage], [])
    end
  end

  # ── Phases ─────────────────────────────────────────────────────────────

  defp mktemp_stage(shell) do
    {:ok, output} = shell.cmd(["mktemp", "-d"], [])
    String.trim(output)
  end

  defp stage_otp_release(shell, otp_release, stage) do
    # The trailing `/.` copies the directory CONTENTS, not the dir itself
    # — same as the shell `cp -r $OTP_RELEASE/. $STAGE` idiom.
    case shell.cmd(["cp", "-r", otp_release <> "/.", stage], []) do
      {:ok, _} -> :ok
      err -> err
    end
  end

  defp maybe_borrow_crypto_apps(%Target{borrow_crypto_apps: nil}, _shell, _opts, _stage), do: :ok

  defp maybe_borrow_crypto_apps(%Target{borrow_crypto_apps: default}, shell, opts, stage) do
    src_root = opts[:android_otp_release] || default

    if not shell.dir?(src_root) do
      Errors.precondition(
        "android_otp_release missing at #{src_root} — needed to borrow crypto/public_key/ssl beams. " <>
          "Run MobDev.Release.OTP.build(:android_arm64) first or pass `android_otp_release:` explicitly."
      )
    else
      Enum.reduce_while(~w(crypto public_key ssl), :ok, fn app, :ok ->
        # The app directory is named like `<app>-<version>/`. Find the
        # first match via `ls -d`. Failure here is a hard precondition —
        # the Android install must have these apps.
        case shell.cmd(
               ["bash", "-c", "ls -d #{src_root}/lib/#{app}-*/ 2>/dev/null | head -1"],
               []
             ) do
          {:ok, output} ->
            src = String.trim(output)

            if src == "" do
              {:halt, Errors.precondition("no #{app}-*/ in #{src_root}/lib")}
            else
              case shell.cmd(["cp", "-r", src, Path.join(stage, "lib") <> "/"], []) do
                {:ok, _} -> {:cont, :ok}
                err -> {:halt, err}
              end
            end

          err ->
            {:halt, err}
        end
      end)
    end
  end

  defp stage_static_libs(target, shell, env, _otp_release, opts, openssl_prefix, stage) do
    erts_lib_dst = Path.join(stage, "erts-#{env.erts_vsn}/lib") <> "/"

    # Static libs from OTP source tree (arch-specific path).
    base_libs = [
      "erts/emulator/zstd/obj/#{target.arch_dir}/opt/libzstd.a",
      "erts/emulator/pcre/obj/#{target.arch_dir}/opt/libepcre.a",
      "erts/emulator/ryu/obj/#{target.arch_dir}/opt/libryu.a"
    ]

    # asn1rt_nif.a — arm32 has a special pre-built location; others come
    # from the OTP source tree.
    asn1_src =
      case target.id do
        :android_arm32 ->
          opts[:asn1rt_nif_arm32] || "/tmp/asn1rt_nif_arm32.a"

        _ ->
          Path.join(env.otp_src, "lib/asn1/priv/lib/#{target.arch_dir}/asn1rt_nif.a")
      end

    # crypto.a from CryptoNif's output.
    crypto_a =
      Path.join(env.otp_src, "lib/crypto/priv/lib/#{target.arch_dir}/crypto.a")

    # libcrypto.a from OpenSSL build.
    libcrypto_a = Path.join(openssl_prefix, "lib/libcrypto.a")

    sources =
      Enum.map(base_libs, &Path.join(env.otp_src, &1)) ++
        [asn1_src, crypto_a, libcrypto_a]

    Enum.reduce_while(sources, :ok, fn src, :ok ->
      case shell.cmd(["cp", src, erts_lib_dst], []) do
        {:ok, _} -> {:cont, :ok}
        err -> {:halt, err}
      end
    end)
  end

  defp stage_erts_headers(target, shell, env, stage) do
    erts_inc_dst = Path.join(stage, "erts-#{env.erts_vsn}/include") <> "/"

    with :ok <- shell.mkdir_p(erts_inc_dst) do
      headers = [
        "erts/emulator/beam/erl_nif.h",
        "erts/emulator/beam/erl_nif_api_funcs.h",
        "erts/emulator/beam/erl_drv_nif.h",
        "erts/include/erl_fixed_size_int_types.h",
        # Arch-specific — the per-target size config.
        "erts/include/#{target.arch_dir}/erl_int_sizes_config.h"
      ]

      Enum.reduce_while(headers, :ok, fn header, :ok ->
        src = Path.join(env.otp_src, header)

        case shell.cmd(["cp", src, erts_inc_dst], []) do
          {:ok, _} -> {:cont, :ok}
          err -> {:halt, err}
        end
      end)
    end
  end

  defp maybe_stage_exqlite(%Target{include_exqlite: false}, _shell, _opts, _stage), do: :ok

  defp maybe_stage_exqlite(_target, shell, opts, stage) do
    case opts[:exqlite_build] do
      nil ->
        Errors.precondition(
          "exqlite_build required for Android targets — pass `exqlite_build: <path>` pointing at " <>
            "any project's _build/dev/lib/exqlite (run `mix deps.get && mix compile` in one of your projects)"
        )

      exqlite_build ->
        with true <-
               shell.dir?(Path.join(exqlite_build, "ebin")) ||
                 {:fs, Path.join(exqlite_build, "ebin"), :enoent},
             {:ok, vsn} <- detect_exqlite_version(exqlite_build),
             dst = Path.join(stage, "lib/exqlite-#{vsn}"),
             :ok <- shell.mkdir_p(Path.join(dst, "ebin")),
             :ok <- shell.mkdir_p(Path.join(dst, "priv")),
             # Copy ebin/* — bytecode + .app file
             {:ok, _} <- shell.cmd(["bash", "-c", "cp #{exqlite_build}/ebin/* #{dst}/ebin/"], []) do
          :ok
        else
          {:fs, path, reason} -> Errors.fs_failed(path, reason)
          err -> err
        end
    end
  end

  defp maybe_stage_epmd(%Target{include_epmd_source: false}, _shell, _env, _stage), do: :ok

  defp maybe_stage_epmd(target, shell, env, stage) do
    epmd_dst = Path.join(stage, "erts/epmd/src")
    arch_dst = Path.join(stage, "erts/#{target.arch_dir}")
    include_dst = Path.join(stage, "erts/include")
    include_internal_dst = Path.join(stage, "erts/include/internal")

    with :ok <- shell.mkdir_p(epmd_dst),
         # epmd .c sources
         epmd_srcs = ~w(epmd.c epmd_srv.c epmd_cli.c),
         :ok <- copy_each(shell, env.otp_src, "erts/epmd/src", epmd_srcs, epmd_dst <> "/"),
         # all epmd .h files (cheap to include)
         {:ok, _} <-
           shell.cmd(
             [
               "bash",
               "-c",
               "cp #{env.otp_src}/erts/epmd/src/*.h #{epmd_dst}/"
             ],
             []
           ),
         # arch-specific configure output
         :ok <- shell.mkdir_p(arch_dst),
         {:ok, _} <-
           shell.cmd(
             [
               "bash",
               "-c",
               "cp -r #{env.otp_src}/erts/#{target.arch_dir}/* #{arch_dst}/"
             ],
             []
           ),
         # erts/include + erts/include/internal mirrors
         :ok <- shell.mkdir_p(include_dst),
         :ok <- shell.mkdir_p(include_internal_dst),
         {:ok, _} <-
           shell.cmd(
             [
               "bash",
               "-c",
               "cp -r #{env.otp_src}/erts/include/* #{include_dst}/"
             ],
             []
           ),
         {:ok, _} <-
           shell.cmd(
             [
               "bash",
               "-c",
               "cp -r #{env.otp_src}/erts/include/internal/* #{include_internal_dst}/"
             ],
             []
           ) do
      :ok
    end
  end

  defp copy_each(shell, otp_src, rel_dir, files, dst) do
    Enum.reduce_while(files, :ok, fn file, :ok ->
      src = Path.join([otp_src, rel_dir, file])

      case shell.cmd(["cp", src, dst], []) do
        {:ok, _} -> {:cont, :ok}
        err -> {:halt, err}
      end
    end)
  end

  defp tar_stage(target, shell, stage, tarball) do
    base = Path.basename(stage)
    parent = Path.dirname(stage)

    # Build the tar argv with per-target --exclude flags.
    exclude_args =
      Enum.flat_map(target.tar_excludes, fn exclude ->
        ["--exclude=#{base}/#{exclude}"]
      end)

    argv = ["tar", "czf", tarball] ++ exclude_args ++ ["-C", parent, base]

    case shell.cmd(argv, []) do
      {:ok, _} -> :ok
      err -> err
    end
  end

  # ── Verification ───────────────────────────────────────────────────────

  @doc """
  Verify the produced tarball contains every required entry. Returns
  `:ok` or a precondition_failed naming the missing entry.

  Universal entries (every target):
    * `erts-<vsn>/` directory entry
    * `lib/elixir/ebin/elixir.app`
    * `erts-<vsn>/lib/crypto.a`
    * `erts-<vsn>/lib/libcrypto.a`

  Per-target additions come from `target.additional_verifies`.
  """
  @spec verify_tarball(Target.t(), MobDev.Release.Shell.t() | module(), map(), Path.t()) ::
          :ok | Errors.t()
  def verify_tarball(target, shell, env, tarball) do
    with {:ok, listing} <- shell.cmd(["tar", "tzf", tarball], []) do
      expected = required_entries(target, env)
      check_entries(listing, expected, tarball)
    end
  end

  @doc """
  Per-target required entries. Public for testing — pinning the list
  is the surface lock that prevents silent drops.

  ERTS version interpolation happens against `env.erts_vsn`.
  """
  @spec required_entries(Target.t(), map()) :: [String.t()]
  def required_entries(target, %{erts_vsn: vsn}) do
    universal = [
      "erts-#{vsn}",
      "lib/elixir/ebin/elixir.app",
      "erts-#{vsn}/lib/crypto.a",
      "erts-#{vsn}/lib/libcrypto.a"
    ]

    universal ++ target.additional_verifies
  end

  @doc """
  Scan a `tar tzf` listing and confirm every expected pattern matches
  at least one entry. Patterns are treated as regex (matching the
  shell's `grep -q` semantics). Public for tests.
  """
  @spec check_entries(binary(), [String.t()], Path.t()) :: :ok | Errors.t()
  def check_entries(listing, expected, tarball_path)
      when is_binary(listing) and is_list(expected) do
    missing =
      Enum.reject(expected, fn pattern ->
        # Compile as a regex — the shell version used grep -E, so .*
        # etc. need to work. Anchor on neither end (grep doesn't either).
        regex = Regex.compile!(pattern)
        Regex.match?(regex, listing)
      end)

    case missing do
      [] ->
        :ok

      [first | _] ->
        Errors.precondition("verify failed — tarball #{tarball_path} missing #{inspect(first)}")
    end
  end

  # ── build_all/1 ────────────────────────────────────────────────────────

  @doc """
  Build all four tarballs in sequence. Each target picks up its own
  defaults. Returns `[{target_id, result}, ...]` in canonical order.
  Doesn't short-circuit.
  """
  @spec build_all(keyword()) :: [{atom(), {:ok, map()} | Errors.t()}]
  def build_all(opts \\ []) do
    for target_id <- targets() do
      {target_id, build(target_id, opts)}
    end
  end

  # ── Preconditions ──────────────────────────────────────────────────────

  defp precheck(target, shell, env, otp_release, openssl_prefix, opts) do
    cond do
      not shell.dir?(env.otp_src) ->
        Errors.precondition("OTP_SRC missing at #{env.otp_src}")

      not shell.dir?(otp_release) ->
        Errors.precondition(
          "otp_release missing at #{otp_release} — run MobDev.Release.OTP.build(#{inspect(target.id)}) first"
        )

      not shell.dir?(openssl_prefix) ->
        Errors.precondition(
          "openssl_prefix missing at #{openssl_prefix} — run MobDev.Release.OpenSSL.build(#{inspect(target.id)}) first"
        )

      target.include_exqlite and is_nil(opts[:exqlite_build]) ->
        Errors.precondition(
          "exqlite_build required for #{target.id} — pass `exqlite_build: <path>` " <>
            "pointing at any project's _build/dev/lib/exqlite"
        )

      target.include_exqlite and not shell.dir?(Path.join(opts[:exqlite_build], "ebin")) ->
        Errors.precondition(
          "exqlite_build/ebin not found — did you `mix deps.get && mix compile` in the project?"
        )

      true ->
        :ok
    end
  end
end
