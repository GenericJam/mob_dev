defmodule MobDev.NativeBuild do
  alias MobDev.{AndroidDeployLock, Release}

  @max_android_update_targets 32
  @max_adb_serial_bytes 128
  @max_adb_discovery_bytes 8_192
  @max_adb_install_result_bytes 4_096
  @max_android_apk_bytes 1_073_741_824
  @max_android_apk_entries 100_000
  @max_android_apk_entry_bytes 1_024
  @max_android_apk_required_entry_bytes 268_435_456
  @android_attempt_id_pattern "\\A[A-Za-z0-9_-]{16}\\z"
  @android_erts_sentinel_pattern "\\Aerts-[A-Za-z0-9._-]+/bin/erl_child_setup\\z"
  @android_erts_helpers [
    {"erl_child_setup", "liberl_child_setup.so"},
    {"inet_gethost", "libinet_gethost.so"},
    {"epmd", "libepmd.so"}
  ]

  @type android_update_failure_reason ::
          :insufficient_storage
          | :signature_mismatch
          | :version_downgrade
          | :offline
          | :unauthorized
          | :unavailable
          | :install_rejected
          | :suspicious_success
          | :unknown_failure
          | :invalid_target

  @type android_update_failure :: %{
          required(:serial) => String.t(),
          required(:reason) => android_update_failure_reason()
        }

  @type android_update_outcome :: %{
          required(:succeeded) => [String.t()],
          required(:failed) => [android_update_failure()]
        }

  @type build_outcome :: %{
          required(:ok?) => boolean(),
          required(:android_device_disposition) =>
            :not_attempted | :artifact_only | :held | :failed | :retained,
          required(:android_serials) => [String.t()],
          required(:android_deploy_lock) => map() | nil,
          required(:android_payload_plan) => map() | nil
        }

  @type command_runner :: (String.t(), [String.t()] -> {String.t(), integer()})
  @type command_runner_with_opts ::
          (String.t(), [String.t()], keyword() -> {String.t(), integer()})

  @moduledoc """
  Builds native binaries (APK for Android, .app bundle for iOS simulator)
  for the current Mob project.

  Reads paths from `mob.exs` in the project root. If `mob.exs` is missing
  or paths haven't been configured, prints instructions and exits.

  OTP runtimes for Android and iOS are downloaded automatically from GitHub
  and cached at `~/.mob/cache/` by `MobDev.OtpDownloader`.

  ## mob.exs keys

    * `:mob_dir`           — mob library repo (native C/ObjC/Swift source)
    * `:elixir_lib`        — Elixir stdlib lib dir
    * `:project_swift_sources` — optional extra Swift sources compiled into
                             the iOS app module
  """

  @doc """
  Builds native binaries for all platforms present in the project.
  Runs Android Gradle build if `android/` dir exists.
  Runs the Mix-driven iOS pipeline (delegating native compile + link
  to `ios/build.zig` for sim, `ios/build_device.zig` for device) when
  `ios/build.zig` exists. Selection between sim and device is driven
  by the `device:` opt.
  """
  @spec build_all(keyword()) :: boolean()
  def build_all(opts \\ []) do
    opts
    |> Keyword.put(:android_device_phase, false)
    |> build_all_with_outcome()
    |> Map.fetch!(:ok?)
  end

  @doc false
  @spec build_all_with_outcome(keyword()) :: build_outcome()
  def build_all_with_outcome(opts \\ []) do
    cfg = load_config()
    platforms = Keyword.get(opts, :platforms, [:android, :ios])
    device_id = Keyword.get(opts, :device, nil)
    slim = Keyword.get(opts, :slim, true)
    platforms = narrow_platforms_for_device(platforms, device_id)
    Process.put(:mob_slim, slim)

    # Always regenerate the runtime plugin manifest from the CURRENT activated
    # plugins before bundling priv — like the driver_tab, it's derived state, not
    # a hand-maintained file. Regenerating on every build (not just when the
    # `:plugins` list changes) means adding/changing a plugin's tier-3/4 sections
    # can't silently ship a stale manifest (the lifecycle/settings/notification
    # handlers just wouldn't activate on device, with no error).
    regen_runtime_manifest!()

    # Same treatment for the static-NIF driver table: it's derived state
    # (mob.exs :static_nifs + the activated plugins' NIFs), but it used to be a
    # checked-in artifact only `mix mob.regen_driver_tab` refreshed. Activating
    # a NIF plugin against a stale table links the <module>_nif_init symbol but
    # never registers it — every call then raises :nif_not_loaded at runtime
    # with nothing pointing at the cause. Regenerate on every native build.
    regen_driver_tab!()

    # Tier-3 build-time file merges (platform-agnostic; run once before the
    # per-platform builds): copy plugin migrations into the host migrations dir
    # and plugin images into the host bundle assets. Fonts are merged per-platform
    # (iOS Info.plist + bundle, Android assets) inside the build chains.
    apply_plugin_migrations!()
    apply_plugin_images!()

    # Manual host-app obligations a plugin declared (e.g. an AndroidManifest
    # <service> fragment the plugin system can't contribute) — print every
    # build, because forgetting one builds + boots clean and only fails at
    # first feature use (a SecurityException with nothing pointing here).
    warn_host_requirements!()

    results = []

    # Skip Android when its toolchain isn't installed instead of failing the
    # build half an hour into a partial-setup user's first deploy. Default
    # `mix mob.deploy` (no platform flag) targets every platform with a
    # `<dir>/` scaffold, but users who only set up iOS hit a Gradle error
    # half a build later — annoying, and fixable by checking up front.
    results =
      cond do
        :android not in platforms ->
          results

        not File.dir?("android") ->
          results

        not android_toolchain_available?() ->
          warn_skipped_android()
          results

        true ->
          [build_android(cfg, device_id, opts) | results]
      end

    try do
      finish_native_builds(results, cfg, platforms, device_id, opts)
    catch
      _kind, _reason ->
        IO.puts(
          "  #{IO.ANSI.red()}✗ native build failed unexpectedly; retained Android deploy state remains authoritative#{IO.ANSI.reset()}"
        )

        build_outcome([{:error, "Native", "unexpected native build failure"} | results], opts)
    end
  end

  defp finish_native_builds(results, cfg, platforms, device_id, opts) do
    results =
      case ios_phase_decision(
             results,
             platforms,
             Keyword.get(opts, :android_device_phase, false)
           ) do
        :run -> finish_ios_native_build(results, cfg, device_id)
        :defer -> results
        :suppress -> results
        :skip -> results
      end

    if results == [] do
      IO.puts(
        "  #{IO.ANSI.yellow()}No native build targets found (missing android/ or ios/build.zig, or toolchains)#{IO.ANSI.reset()}"
      )
    end

    Enum.each(results, fn
      {:ok, platform} ->
        IO.puts("  #{IO.ANSI.green()}✓ #{platform} native build complete#{IO.ANSI.reset()}")

      {:ok, platform, _metadata} ->
        IO.puts("  #{IO.ANSI.green()}✓ #{platform} native build complete#{IO.ANSI.reset()}")

      {:error, platform, reason} ->
        IO.puts(
          "  #{IO.ANSI.red()}✗ #{platform} native build failed: #{reason}#{IO.ANSI.reset()}"
        )

      {:error, platform, reason, _retained_lock} ->
        IO.puts(
          "  #{IO.ANSI.red()}✗ #{platform} native build failed: #{reason} (deploy lock retained)#{IO.ANSI.reset()}"
        )
    end)

    build_outcome(results, opts)
  end

  @doc false
  @spec ios_phase_decision([tuple()], [atom()], term()) :: :run | :defer | :suppress | :skip
  def ios_phase_decision(results, platforms, android_device_phase)
      when is_list(results) and is_list(platforms) do
    cond do
      :ios not in platforms ->
        :skip

      android_device_phase != true ->
        :run

      true ->
        case Enum.filter(results, &android_build_result?/1) do
          [] -> :run
          [result] -> if held_android_device_phase?(result), do: :defer, else: :suppress
          _multiple -> :suppress
        end
    end
  end

  def ios_phase_decision(_results, _platforms, _android_device_phase), do: :suppress

  defp android_build_result?(result) when is_tuple(result) and tuple_size(result) >= 2,
    do: elem(result, 1) == "Android"

  defp android_build_result?(_result), do: false

  defp held_android_device_phase?({:ok, "Android", %{serials: serials, deploy_lock: lock}})
       when is_list(serials) and serials != [] and is_map(lock) do
    serials == Enum.sort(serials) and Enum.uniq(serials) == serials and
      MobDev.AndroidDeployLock.valid?(lock, :native_ready) and lock.serials == serials
  end

  defp held_android_device_phase?(_result), do: false

  defp finish_ios_native_build(results, cfg, device_id) do
    physical_udid =
      cond do
        is_binary(device_id) and ios_physical_udid?(device_id) -> device_id
        is_nil(device_id) -> auto_detect_physical_ios()
        true -> nil
      end

    cond do
      not ios_toolchain_available?() ->
        warn_skipped_ios()
        results

      physical_udid ->
        [build_ios_physical(cfg, physical_udid) | results]

      File.exists?("ios/build.zig") ->
        [build_ios(cfg, device_id) | results]

      true ->
        results
    end
  end

  @doc false
  @spec build_outcome([tuple()]) :: build_outcome()
  def build_outcome(results) when is_list(results) do
    ok? = not Enum.empty?(results) and Enum.all?(results, &successful_native_build?/1)

    %{
      ok?: ok?,
      android_device_disposition: android_device_disposition(results),
      android_serials: android_serials_from_results(results),
      android_deploy_lock: android_deploy_lock_from_results(results),
      android_payload_plan: if(ok?, do: android_payload_plan_from_results(results), else: nil)
    }
  end

  @doc false
  @spec build_outcome([tuple()], keyword()) :: build_outcome()
  def build_outcome(results, opts) when is_list(results) and is_list(opts) do
    outcome = build_outcome(results)

    if outcome.ok? do
      outcome
    else
      case cleanup_successful_android_payloads(results, opts) do
        :ok ->
          outcome

        {:error, _cleanup_reason} ->
          IO.puts(
            "  #{IO.ANSI.yellow()}⚠ Android payload cleanup failed; deploy lease identity retained#{IO.ANSI.reset()}"
          )

          outcome
      end
    end
  end

  # ── Android ──────────────────────────────────────────────────────────────────

  defp build_android(cfg, device_id, opts) do
    bundle_id = cfg[:bundle_id] || MobDev.Config.bundle_id()
    apk = "android/app/build/outputs/apk/debug/app-debug.apk"
    mob_dir = Path.expand(cfg[:mob_dir])

    with {:ok, update_targets} <- android_update_targets_for_phase(device_id, opts),
         :ok <- print_android_build_start(),
         {:ok, otp_arm64} <- MobDev.OtpDownloader.ensure_android("arm64-v8a"),
         {:ok, otp_arm32} <- MobDev.OtpDownloader.ensure_android("armeabi-v7a"),
         {:ok, otp_x86_64} <- MobDev.OtpDownloader.ensure_android("x86_64"),
         {:ok, python_android_bundle} <- maybe_ensure_python_android_bundle(),
         :ok <- ensure_jni_libs(otp_arm64, "arm64-v8a"),
         :ok <- ensure_jni_libs(otp_arm32, "armeabi-v7a"),
         :ok <- ensure_jni_libs(otp_x86_64, "x86_64"),
         :ok <- ensure_python_android_libs(python_android_bundle),
         :ok <- install_nx_eigen_otp_lib(otp_arm64),
         :ok <- install_nx_eigen_otp_lib(otp_arm32),
         :ok <- zig_build_android_objects(mob_dir, otp_arm64, otp_arm32, otp_x86_64),
         :ok <- apply_plugin_android_manifest!(),
         :ok <- apply_plugin_gradle_deps!(),
         :ok <- apply_plugin_android_kotlin!(),
         :ok <- apply_plugin_android_res!(),
         :ok <- apply_fonts_to_android!(),
         :ok <- gradle_assemble(),
         {:ok, metadata} <-
           maybe_install_android_runtime(
             apk,
             update_targets,
             bundle_id,
             cfg[:elixir_lib],
             otp_arm64,
             otp_arm32,
             otp_x86_64,
             opts
           ) do
      {:ok, "Android", Map.put(metadata, :serials, update_targets)}
    else
      {:error, reason, deploy_lock} -> {:error, "Android", reason, deploy_lock}
      {:error, reason} -> {:error, "Android", reason}
    end
  end

  defp android_update_targets_for_phase(device_id, opts) do
    case Keyword.get(opts, :android_device_phase, false) do
      false -> {:ok, []}
      true -> android_update_targets(device_id)
      _invalid -> {:error, "Invalid Android device-phase option"}
    end
  end

  defp maybe_install_android_runtime(
         _apk,
         [],
         _bundle_id,
         _elixir_lib,
         _otp_arm64,
         _otp_arm32,
         _otp_x86_64,
         opts
       ) do
    case Keyword.get(opts, :android_device_phase, false) do
      false -> {:ok, %{deploy_lock: nil, payload_plan: nil}}
      _device_phase -> {:error, "Android device phase requires explicit canonical targets"}
    end
  end

  defp maybe_install_android_runtime(
         apk,
         update_targets,
         bundle_id,
         elixir_lib,
         otp_arm64,
         otp_arm32,
         otp_x86_64,
         opts
       ) do
    install_and_deliver_android_runtime(
      apk,
      update_targets,
      bundle_id,
      elixir_lib,
      otp_arm64,
      otp_arm32,
      otp_x86_64,
      opts
    )
  end

  defp print_android_build_start do
    IO.puts("  Building Android APK...")
    :ok
  end

  defp successful_native_build?({:ok, _platform}), do: true
  defp successful_native_build?({:ok, _platform, _metadata}), do: true
  defp successful_native_build?(_result), do: false

  defp android_device_disposition(results) do
    case Enum.filter(results, &android_build_result?/1) do
      [] ->
        :not_attempted

      [result] ->
        classify_android_device_result(result)

      multiple ->
        if Enum.any?(multiple, &android_authority_present?/1), do: :retained, else: :failed
    end
  end

  defp classify_android_device_result({:error, "Android", _reason, lock}) when is_map(lock),
    do: :retained

  defp classify_android_device_result(result) do
    cond do
      held_android_device_phase?(result) -> :held
      artifact_only_android_result?(result) -> :artifact_only
      true -> :failed
    end
  end

  defp artifact_only_android_result?({:ok, "Android"}), do: true

  defp artifact_only_android_result?(
         {:ok, "Android", %{serials: [], deploy_lock: nil, payload_plan: nil}}
       ),
       do: true

  defp artifact_only_android_result?(_result), do: false

  defp android_authority_present?({:error, "Android", _reason, lock}) when is_map(lock),
    do: true

  defp android_authority_present?({:ok, "Android", %{deploy_lock: lock}}) when is_map(lock),
    do: true

  defp android_authority_present?(_result), do: false

  defp android_serials_from_results(results) do
    case Enum.find(results, &match?({:ok, "Android", _serials}, &1)) do
      {:ok, "Android", %{serials: serials, deploy_lock: %{}}} -> serials
      _build_only_or_absent -> []
    end
  end

  defp android_deploy_lock_from_results(results) do
    Enum.find_value(results, fn
      {:ok, "Android", %{deploy_lock: lock}} -> lock
      {:error, "Android", _reason, lock} -> lock
      _result -> nil
    end)
  end

  defp android_payload_plan_from_results(results) do
    Enum.find_value(results, fn
      {:ok, "Android", %{payload_plan: plan}} -> plan
      _result -> nil
    end)
  end

  defp cleanup_successful_android_payloads(results, opts) do
    case Keyword.get(opts, :android_preinstall_cleanup) do
      cleanup when is_function(cleanup, 1) ->
        results
        |> Enum.flat_map(fn
          {:ok, "Android", %{payload_plan: plan}} when is_map(plan) -> [plan]
          _result -> []
        end)
        |> Enum.uniq()
        |> Enum.reduce_while(:ok, fn plan, :ok ->
          case cleanup_android_payload(cleanup, plan) do
            :ok -> {:cont, :ok}
            {:error, _reason} = error -> {:halt, error}
          end
        end)

      _missing ->
        :ok
    end
  end

  # Phase 2 iter 8: invoke build.zig per-ABI before Gradle. Produces
  # android/app/build/zig-out/<abi>/driver_tab_android.o which CMakeLists.txt
  # picks up via its `if(EXISTS ${ZIG_DRIVER_TAB_O})` check; the per-ABI
  # path is what CMake's ${ANDROID_ABI} variable resolves to.
  #
  # Skips silently if the project has no jni/build.zig (older projects from
  # before this iter still work via CMake compiling driver_tab_android.c
  # directly through the Phase 0 fallback).
  defp zig_build_android_objects(mob_dir, otp_arm64, otp_arm32, otp_x86_64) do
    build_zig = "android/app/src/main/jni/build.zig"
    # The CMake fallback (used when zig can't run) tries to compile this C
    # source straight out of the mob dep. mob 0.7+ ships it as .zig instead,
    # so on a current mob the fallback is a dead end; see zig_build_plan/3.
    legacy_c = Path.join(mob_dir, "android/jni/mob_nif.c")

    case zig_build_plan(File.exists?(build_zig), zig_available?(), File.exists?(legacy_c)) do
      :skip_no_build_zig ->
        :ok

      :legacy_cmake ->
        IO.puts(
          "  #{IO.ANSI.yellow()}zig not on PATH — skipping build.zig step (CMake will compile sources directly)#{IO.ANSI.reset()}"
        )

        :ok

      :zig_required ->
        {:error, zig_required_message()}

      :run_zig ->
        driver_tab = resolve_driver_tab_android(mob_dir)
        erts_vsn = detect_erts_vsn(otp_arm64) || "erts-17.0"

        IO.puts("  Compiling Android C objects via zig build (per-ABI)...")

        # Cross-compile project Rust/Zig NIFs once per ABI. Each
        # invocation targets `aarch64-linux-android` or
        # `armv7-linux-androideabi` (Rust) / `arm-linux-androideabi`
        # (Zig) and produces its own per-target `.a` paths. NIFs whose
        # `mob.exs` `:archs` entry lists `[:android_arm64]` only
        # appear in the arm64 build; same for arm32; `[:all]` and
        # `[:android]` land in both. The per-ABI build.zig invocation
        # in `run_zig_android_objects` then receives the right archive
        # set and links them into its `lib<app>.so`.
        with {:ok, arm64_nif_args} <- project_nif_zig_args(:android_arm64),
             {:ok, arm32_nif_args} <- project_nif_zig_args(:android_arm32),
             {:ok, x86_64_nif_args} <- project_nif_zig_args(:android_x86_64),
             {:ok, arm64_nxeigen} <- maybe_build_nxeigen(:android_arm64),
             {:ok, arm32_nxeigen} <- maybe_build_nxeigen(:android_arm32),
             {:ok, arm64_tflite} <- maybe_build_tflite(:android_arm64),
             {:ok, arm32_tflite} <- maybe_build_tflite(:android_arm32) do
          build_zig_src =
            case inject_page_size_flag(File.read!(build_zig)) do
              {:already, src} ->
                src

              {:patched, src} ->
                File.write!(build_zig, src)

                IO.puts(
                  "  Added 16 KB page-size alignment to #{build_zig} " <>
                    "(Android 15+ / Play requirement; build.zig predated the flag)."
                )

                src

              {:no_match, src} ->
                IO.puts(
                  "  #{IO.ANSI.yellow()}Could not auto-add the 16 KB page-size flag to " <>
                    "#{build_zig} — add -Wl,-z,max-page-size=16384 to the -shared link " <>
                    "manually, or regenerate build.zig from mob_new.#{IO.ANSI.reset()}"
                )

                src
            end

          [
            {otp_arm64, "arm64-v8a", arm64_nif_args, arm64_nxeigen, arm64_tflite},
            {otp_arm32, "armeabi-v7a", arm32_nif_args, arm32_nxeigen, arm32_tflite},
            {otp_x86_64, "x86_64", x86_64_nif_args, nil, nil}
          ]
          |> Enum.filter(fn {_otp, abi, _nif, _nx, _tf} ->
            build_zig_supports_abi?(build_zig_src, abi) ||
              warn_skip_abi(build_zig, abi)
          end)
          |> Enum.reduce_while(:ok, fn {otp_dir, abi, abi_nif_args, abi_nxeigen, abi_tflite},
                                       _acc ->
            # Drop the TFLite runtime .so into jniLibs/<abi>/ alongside
            # the static-NIF archive that gets linked into native-lib.
            # No-op when TFLite isn't enabled.
            :ok = copy_tflite_runtime_lib_android(abi_tflite, abi)

            case run_zig_android_objects(
                   build_zig,
                   abi,
                   otp_dir,
                   erts_vsn,
                   mob_dir,
                   driver_tab,
                   abi_nif_args,
                   abi_nxeigen,
                   abi_tflite
                 ) do
              :ok -> {:cont, :ok}
              {:error, reason} -> {:halt, {:error, reason}}
            end
          end)
        end
    end
  end

  # Pure kernel behind zig_build_android_objects/4, extracted so the
  # "obvious failure" case is testable without a toolchain or a device.
  # Decides the JNI build step from the three facts that determine whether
  # a native build can succeed at all:
  #
  #   build_zig?  does the project ship jni/build.zig?
  #   zig?        is `zig` on PATH (so build.zig can actually run)?
  #   legacy_c?   does the mob dep still ship the C JNI source the CMake
  #               fallback would compile (android/jni/mob_nif.c)?
  #
  # Outcomes:
  #   :skip_no_build_zig  no build.zig, nothing for this step to do.
  #   :run_zig            zig present, drive the real build.zig path.
  #   :legacy_cmake       no zig, but the mob dep still has the C sources,
  #                       so CMake can compile them directly (old mob).
  #   :zig_required       no zig AND no C sources (mob 0.7+): the build
  #                       cannot succeed, so fail fast with a clear cause
  #                       instead of limping into a cryptic CMake error.
  @doc false
  @spec zig_build_plan(boolean(), boolean(), boolean()) ::
          :skip_no_build_zig | :run_zig | :legacy_cmake | :zig_required
  def zig_build_plan(build_zig?, zig?, legacy_c?)
  def zig_build_plan(false, _zig?, _legacy_c?), do: :skip_no_build_zig
  def zig_build_plan(true, true, _legacy_c?), do: :run_zig
  def zig_build_plan(true, false, true), do: :legacy_cmake
  def zig_build_plan(true, false, false), do: :zig_required

  # The actionable error shown when an Android native build needs `zig` but
  # it is not on PATH and the mob dep no longer ships the C fallback sources.
  # Public so the test suite can pin the guidance without driving a build.
  @doc false
  @spec zig_required_message() :: String.t()
  def zig_required_message do
    """
    zig is not on your PATH, and this project's Android native build needs it.

    mob 0.7+ compiles the Android JNI layer with build.zig. The legacy CMake
    fallback would reference C sources (deps/mob/android/jni/mob_nif.c) that no
    longer ship with mob, so the build cannot succeed without zig.

    Install zig 0.15.x, then re-run `mix mob.deploy --native --android`:
      asdf:    asdf plugin add zig && asdf install zig 0.15.2 && asdf global zig 0.15.2
      manual:  https://ziglang.org/download/  (then put `zig` on your PATH)

    Verify your toolchain any time with `mix mob.doctor`.\
    """
  end

  # True if the app's build.zig handles `abi`. mob_dev builds all of
  # arm64-v8a/armeabi-v7a/x86_64 by default, but an app's app-owned build.zig
  # (copied at `mix mob.new` time) may predate x86_64 support (mob_new < 0.4.5)
  # and reject it, which used to fail the whole native build — aborting before
  # the plugin-bootstrap regen. Each handled ABI appears as a quoted string
  # literal in the build.zig's abi_to_target/ndk_arch_triple switches, so check
  # for that. Safe to skip: gradle abiFilters won't ship an ABI the build.zig
  # can't compile. Real failures of a SUPPORTED ABI still halt the build.
  @doc false
  @spec build_zig_supports_abi?(String.t(), String.t()) :: boolean()
  def build_zig_supports_abi?(build_zig_src, abi) do
    String.contains?(build_zig_src, ~s("#{abi}"))
  end

  defp warn_skip_abi(build_zig, abi) do
    IO.puts(
      "  #{IO.ANSI.yellow()}Skipping ABI #{abi}: not handled by #{build_zig} " <>
        "(regenerate from mob_new >= 0.4.5 to add x86_64).#{IO.ANSI.reset()}"
    )

    false
  end

  # The app's `-shared` link command, and that command with the 16 KB page-size
  # flag added. Android 15+ devices use 16 KB memory pages; Google Play requires
  # every bundled .so to have 16 KB-aligned LOAD segments. New apps get this from
  # the mob_new template, but an app-owned build.zig copied at `mix mob.new` time
  # predates the flag and links 4 KB-aligned .so. The link line is identical
  # across template versions, so we patch the command-array form (independent of
  # the `run`/var name and any later addArg lines).
  @shared_link ", \"-shared\" })"
  @shared_link_aligned ", \"-shared\", \"-Wl,-z,max-page-size=16384\" })"

  # Ensure the app's build.zig links 16 KB-aligned .so. Returns the (possibly
  # patched) source plus a status: `:already` (flag present), `:patched` (flag
  # injected into the -shared link), or `:no_match` (link line not recognized —
  # can't auto-fix). Pure; the caller writes the file + logs.
  @doc false
  @spec inject_page_size_flag(String.t()) :: {:already | :patched | :no_match, String.t()}
  def inject_page_size_flag(build_zig_src) do
    cond do
      String.contains?(build_zig_src, "max-page-size") ->
        {:already, build_zig_src}

      String.contains?(build_zig_src, @shared_link) ->
        {:patched, String.replace(build_zig_src, @shared_link, @shared_link_aligned)}

      true ->
        {:no_match, build_zig_src}
    end
  end

  defp run_zig_android_objects(
         build_zig,
         abi,
         otp_dir,
         erts_vsn,
         mob_dir,
         driver_tab,
         nif_args,
         nxeigen_archive,
         tflite_build
       ) do
    app_name = Mix.Project.config() |> Keyword.fetch!(:app) |> Atom.to_string()
    project_root = Path.expand(".")
    project_jni_dir = Path.join(project_root, "android/app/src/main/jni")
    jni_libs_abi = Path.join([project_root, "android/app/src/main/jniLibs", abi])
    File.mkdir_p!(jni_libs_abi)

    # Activated plugins' C NIF sources (one .c per nif, named after the NIF
    # module). Empty when no NIF-bearing plugin is activated; the build.zig
    # template orelse's "" so the flag is always safe to emit.
    plugin_c_nifs =
      MobDev.Plugin.Merge.nif_sources(MobDev.Plugin.activated(), :android) |> Enum.join(",")

    # Activated plugins' zig NIF sources (one .zig per nif, lang: :zig). Same
    # shape as plugin_c_nifs but compiled via addZigObject with named-module
    # imports for mob-core bindings. Empty when no zig-NIF plugin is activated.
    plugin_zig_nifs =
      MobDev.Plugin.Merge.zig_nif_sources(MobDev.Plugin.activated(), :android) |> Enum.join(",")

    # Activated plugins' JNI-thunk C sources (android.jni_source). Plain C
    # objects (no NIF-init libname) compiled + linked into the app .so so a
    # plugin's Java_<pkg>_<Class>_* thunks resolve. Empty when none.
    plugin_jni_sources =
      MobDev.Plugin.Merge.jni_sources(MobDev.Plugin.activated()) |> Enum.join(",")

    base_args = [
      "build",
      "native-lib",
      "--build-file",
      build_zig,
      "--prefix",
      "android/app/build/zig-out",
      "-Dabi=#{abi}",
      "-Dotp_dir=#{otp_dir}",
      "-Derts_vsn=#{erts_vsn}",
      "-Dmob_dir=#{mob_dir}",
      "-Ddriver_tab=#{driver_tab}",
      "-Dproject_jni_dir=#{project_jni_dir}",
      "-Dndk_sysroot=#{ndk_sysroot()}",
      "-Dapp_name=#{app_name}",
      "-Dproject_root=#{project_root}",
      "-Dexqlite_src=#{Path.join(project_root, "deps/exqlite/c_src")}"
    ]

    # Only emit -Dplugin_* when non-empty. A plugin-aware build.zig defaults
    # these to "" (so omitting them is equivalent there), but an app scaffolded
    # before the plugin system has no such option and Zig rejects the unknown
    # -D flag. Gating keeps non-plugin apps on older mob scaffolding building.
    plugin_args =
      for {name, val} <- [
            {"plugin_c_nifs", plugin_c_nifs},
            {"plugin_zig_nifs", plugin_zig_nifs},
            {"plugin_jni_sources", plugin_jni_sources}
          ],
          val != "",
          do: "-D#{name}=#{val}"

    # `project_nif_zig_args/1` also emits `-Dproject_root=` (since the
    # iOS templates need it and don't have a baseline equivalent). The
    # Android base_args above already supply it for the existing
    # jniLibs install path, so drop the duplicate from `nif_args`
    # before concatenating — Zig 0.16's option parser rejects
    # `-Dproject_root=...` appearing twice with "expected a string,
    # but received a list".
    nif_args_no_root = Enum.reject(nif_args, &String.starts_with?(&1, "-Dproject_root="))

    # Activated plugins' cpp_archive NIFs (e.g. an Nx CPU backend): each
    # cross-compiled to lib<mod>.a for this ABI and static-linked via
    # -Dplugin_static_libs. {:ok, []} when no such plugin is active; raises a
    # hard build error when one IS active on an ABI CppArchive can't target
    # (x86_64 emulator) rather than shipping an unresolved-symbol link failure.
    plugin_archive_result =
      case android_abi_to_cpp_target(abi) do
        nil -> {:ok, []}
        target_id -> build_plugin_static_archives(target_id, :android, otp_dir)
      end

    with {:ok, plugin_archives} <- plugin_archive_result do
      args =
        base_args ++
          plugin_args ++
          nif_args_no_root ++
          nxeigen_zig_args_android(nxeigen_archive) ++
          tflite_zig_args_android(tflite_build) ++
          plugin_static_lib_args(plugin_archives)

      case System.cmd("zig", args, stderr_to_stdout: true, into: IO.stream()) do
        {_, 0} -> :ok
        {_, code} -> {:error, "zig build for #{abi} exited #{code}"}
      end
    end
  end

  # Single source of truth in MobDev.NdkVersion (honors ANDROID_HOME /
  # ANDROID_SDK_ROOT + host detection) — shared with cpp_archive / nx_eigen_nif
  # so the NDK path can't diverge again (MOB-89).
  defp ndk_sysroot, do: MobDev.NdkVersion.sysroot()

  defp resolve_driver_tab_android(mob_dir) do
    resolve_driver_tab(mob_dir, "android", ["android", "jni"])
  end

  defp resolve_driver_tab_ios(mob_dir) do
    resolve_driver_tab(mob_dir, "ios", ["ios"])
  end

  defp resolve_driver_tab(mob_dir, platform, mob_subdir) do
    # Prefer .zig (Phase 6a) > generated .c > mob's reference .zig > .c.
    # The build.zig auto-detects extension via `addZigObject` vs
    # `addCObject`, so either extension flows through correctly.
    generated_zig = "priv/generated/driver_tab_#{platform}.zig"
    generated_c = "priv/generated/driver_tab_#{platform}.c"

    mob_zig =
      Path.join(mob_subdir ++ ["driver_tab_#{platform}.zig"]) |> then(&Path.join([mob_dir, &1]))

    mob_c =
      Path.join(mob_subdir ++ ["driver_tab_#{platform}.c"]) |> then(&Path.join([mob_dir, &1]))

    cond do
      File.exists?(generated_zig) -> Path.expand(generated_zig)
      File.exists?(generated_c) -> Path.expand(generated_c)
      File.exists?(mob_zig) -> mob_zig
      true -> mob_c
    end
  end

  defp detect_erts_vsn(otp_dir) do
    case File.ls(otp_dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.starts_with?(&1, "erts-"))
        |> Enum.sort(:desc)
        |> List.first()

      _ ->
        nil
    end
  end

  defp zig_available?, do: not is_nil(System.find_executable("zig"))

  # Downloads Chaquopy's CPython distribution iff Pythonx is a dep.
  # Returns `{:ok, nil}` for projects without Pythonx so the rest of the
  # Android pipeline runs unchanged.
  defp maybe_ensure_python_android_bundle do
    if pythonx_in_project?() do
      MobDev.PythonAndroidSupport.ensure()
    else
      {:ok, nil}
    end
  end

  # Copies Chaquopy's libpython*.so + bundled OpenSSL/SQLite into the
  # user's android/app/src/main/jniLibs/<abi>/ tree so the APK packager
  # picks them up. lib-dynload + stdlib go into assets/python/ for
  # runtime extraction by the user's app on first launch.
  #
  # No-op when bundle is nil (project without Pythonx).
  #
  # NOTE: this places the Python distribution but does NOT yet
  # cross-compile libpythonx.so (the Pythonx NIF) for Android NDK.
  # Without that, Pythonx.NIF.__on_load__/0 raises at runtime. The NDK
  # cross-compile is the next piece — see python_embedding guide.
  @android_python_abis ~w(arm64-v8a x86_64)
  defp ensure_python_android_libs(nil), do: :ok

  defp ensure_python_android_libs(bundle_dir) do
    Enum.each(@android_python_abis, fn abi ->
      copy_python_jni_libs(bundle_dir, abi)
      cross_compile_libpythonx_android(abi, bundle_dir)
    end)

    generate_android_enif_keepalive()
    install_pythonx_otp_lib_android()
    copy_python_assets(bundle_dir)
    :ok
  end

  # Mirrors the iOS enif_* keep-alive table. Without it, --gc-sections
  # in the user's CMakeLists strips enif_* symbols from
  # libpython_android_test.so, and dlopen of libpythonx.so fails at
  # runtime with "cannot locate symbol enif_keep_resource".
  #
  # Generates `android/app/src/main/jni/enif_keepalive.c` with one
  # __attribute__((used)) reference per `T _enif_*` exported by
  # erl_nif.o inside the Android OTP cache's libbeam.a. The CMakeLists
  # template (in mob_new) picks it up if present.
  defp generate_android_enif_keepalive do
    otp_dir = MobDev.OtpDownloader.android_otp_dir("arm64-v8a")

    libbeam =
      Path.wildcard("#{otp_dir}/erts-*/lib/libbeam.a")
      |> List.first()

    cond do
      is_nil(libbeam) or not File.exists?(libbeam) ->
        :ok

      true ->
        # macOS BSD `ar` chokes on the Linux-format archive Mob ships
        # (entries listed as "erl_nif.o/" with trailing slash). Use the
        # NDK's llvm-ar / llvm-nm, which handle either format cleanly.
        sdk_root = MobDev.NdkVersion.sdk_root()
        ndk_version = MobDev.NdkVersion.effective()

        bin =
          Path.join([
            sdk_root || "",
            "ndk",
            ndk_version,
            "toolchains",
            "llvm",
            "prebuilt",
            android_ndk_host(),
            "bin"
          ])

        ar = Path.join(bin, "llvm-ar")
        nm = Path.join(bin, "llvm-nm")

        if File.regular?(ar) and File.regular?(nm) do
          generate_android_enif_keepalive_with(ar, nm, libbeam)
        else
          IO.puts("  ⚠  NDK llvm-ar / llvm-nm not found — skipping enif_* keep-alive table")
          :ok
        end
    end
  end

  defp generate_android_enif_keepalive_with(ar, nm, libbeam) do
    tmp = System.tmp_dir!() |> Path.join("mob_enif_extract_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    System.cmd(ar, ["x", libbeam, "erl_nif.o"], cd: tmp, stderr_to_stdout: true)
    erl_nif_o = Path.join(tmp, "erl_nif.o")

    if File.exists?(erl_nif_o) do
      {nm_out, _} = System.cmd(nm, [erl_nif_o], stderr_to_stdout: true)

      symbols =
        nm_out
        |> String.split("\n")
        |> Enum.filter(&Regex.match?(Regex.compile!(~S{\sT\senif_}), &1))
        |> Enum.map(fn line -> line |> String.split() |> List.last() end)
        |> Enum.uniq()

      out = "android/app/src/main/jni/enif_keepalive.c"
      File.mkdir_p!(Path.dirname(out))
      File.write!(out, generate_android_enif_keepalive_source(symbols))
      IO.puts("  ✓ generated #{out} (#{length(symbols)} enif_* symbols pinned)")
    end

    File.rm_rf(tmp)
    :ok
  end

  defp generate_android_enif_keepalive_source(symbols) do
    refs =
      symbols
      |> Enum.map_join("\n", fn sym ->
        "extern void #{sym}(void); __attribute__((used)) static void *_keep_#{sym} = (void *)&#{sym};"
      end)

    """
    /* Auto-generated by mob_dev/native_build.ex.
     * References every enif_* symbol exported by libbeam.a's erl_nif.o
     * so the user's CMakeLists --gc-sections doesn't strip them. Without
     * these references, dlopen of dynamic NIFs (libpythonx.so) fails at
     * runtime with "cannot locate symbol enif_*".
     *
     * Regenerated on every `mix mob.deploy --native --device <android>`.
     */
    #{refs}
    """
  end

  # Mirrors the "Installing pythonx as OTP library" step in iOS's
  # build_device.sh: places the pythonx beams + .app into
  # <otp_arm64>/lib/pythonx-VSN/ebin and copies libpythonx.so to
  # priv/, so `:code.priv_dir(:pythonx)` resolves on device once the
  # OTP runtime is pushed.
  #
  # Only the arm64-v8a NIF goes into priv/ — Mob's Android OTP cache
  # is per-cache, not per-device. x86_64 emulator support would require
  # a per-device push (TODO). Apple Silicon Macs run arm64 Android
  # emulators natively, so the arm64-only restriction is rarely felt.
  defp install_pythonx_otp_lib_android do
    pythonx_vsn = read_pythonx_version()

    if pythonx_vsn do
      otp_dir = MobDev.OtpDownloader.android_otp_dir("arm64-v8a")
      pythonx_lib_dir = Path.join([otp_dir, "lib", "pythonx-#{pythonx_vsn}"])

      File.rm_rf!(pythonx_lib_dir)
      File.mkdir_p!(Path.join(pythonx_lib_dir, "ebin"))
      File.mkdir_p!(Path.join(pythonx_lib_dir, "priv"))

      Path.wildcard("_build/dev/lib/pythonx/ebin/*.beam")
      |> Enum.each(fn src ->
        cp(src, Path.join([pythonx_lib_dir, "ebin", Path.basename(src)]))
      end)

      if File.exists?("_build/dev/lib/pythonx/ebin/pythonx.app") do
        cp(
          "_build/dev/lib/pythonx/ebin/pythonx.app",
          Path.join([pythonx_lib_dir, "ebin", "pythonx.app"])
        )
      end

      src = "android/app/src/main/jniLibs/arm64-v8a/libpythonx.so"

      if File.exists?(src) do
        cp(src, Path.join([pythonx_lib_dir, "priv", "libpythonx.so"]))
      end
    end

    :ok
  end

  defp read_pythonx_version do
    cond do
      File.exists?("_build/dev/lib/pythonx/ebin/pythonx.app") ->
        case File.read("_build/dev/lib/pythonx/ebin/pythonx.app") do
          {:ok, content} ->
            case Regex.run(Regex.compile!(~S<{vsn,\s*"([^"]+)"}>), content) do
              [_, vsn] -> vsn
              _ -> nil
            end

          _ ->
            nil
        end

      true ->
        nil
    end
  end

  # Cross-compiles Pythonx's NIF (deps/pythonx/c_src/{pythonx,python}.cpp)
  # for Android against the NDK and the Chaquopy headers. Output drops
  # into android/app/src/main/jniLibs/<abi>/libpythonx.so so the APK
  # packager picks it up alongside the OTP runtime helper libs.
  #
  # Pythonx's design — runtime dlopen+dlsym for libpython AND enif_*
  # symbols resolved by the loaded BEAM — means libpythonx.so has many
  # undefined symbols at link time. `--unresolved-symbols=ignore-all`
  # tells lld this is intentional. Apps that load the NIF via
  # `:erlang.load_nif/2` resolve enif_* against the host BEAM, and
  # Pythonx.init/4 resolves Py* against the dlopen'd libpython.so.
  defp cross_compile_libpythonx_android(abi, bundle_dir) do
    pythonx_src = "deps/pythonx/c_src"

    if File.dir?(pythonx_src) do
      ndk_version = MobDev.NdkVersion.effective()
      sdk_root = MobDev.NdkVersion.sdk_root()

      cond do
        is_nil(sdk_root) ->
          IO.puts("  ⚠  Android SDK not found — skipping libpythonx.so cross-compile")
          :ok

        not MobDev.NdkVersion.installed?(ndk_version) ->
          IO.puts("  ⚠  Android NDK #{ndk_version} not installed — skipping libpythonx.so")
          IO.puts("     Install with: #{MobDev.NdkVersion.install_command()}")
          :ok

        true ->
          do_cross_compile_libpythonx_android(abi, bundle_dir, sdk_root, ndk_version)
      end
    else
      :ok
    end
  end

  defp do_cross_compile_libpythonx_android(abi, bundle_dir, sdk_root, ndk_version) do
    triple = android_triple(abi)
    api = android_api_level()
    host = android_ndk_host()

    bin_dir =
      Path.join([sdk_root, "ndk", ndk_version, "toolchains", "llvm", "prebuilt", host, "bin"])

    clang = Path.join(bin_dir, "#{triple}#{api}-clang++")

    unless File.regular?(clang) do
      IO.puts("  ⚠  NDK clang++ not found at #{clang} — skipping libpythonx.so")
      :ok
    end

    pythonx_src = "deps/pythonx/c_src"
    fine_inc = "deps/fine/c_include"
    python_inc = MobDev.PythonAndroidSupport.headers_dir(bundle_dir, abi)

    erts_inc =
      Path.wildcard("#{MobDev.OtpDownloader.android_otp_dir()}/erts-*/include")
      |> List.first()

    out = "android/app/src/main/jniLibs/#{abi}/libpythonx.so"
    File.mkdir_p!(Path.dirname(out))

    # libpythonx.so references enif_* symbols defined by the user's
    # libpython_android_test.so (via libbeam.a, statically linked into
    # it by Gradle). For Android's loader to resolve those at dlopen
    # time, libpythonx.so needs a `NEEDED libpython_android_test.so`
    # entry — otherwise the lookup happens in the wrong namespace and
    # fails with "cannot locate symbol enif_*".
    #
    # The real lib is built by Gradle AFTER this step. We work around
    # the chicken-and-egg with a tiny stub library that exports the
    # enif_* symbols and carries SONAME=libpython_android_test.so. At
    # runtime Android resolves the NEEDED entry by SONAME match, so
    # the real lib (already loaded via System.loadLibrary) provides
    # the implementations.
    stub_so = build_libpython_android_test_stub_so(bin_dir, triple, api, abi)

    # `-l<name>` looks for `lib<name>.so` — derive `<name>` from the
    # actual stub SONAME we just built so projects whose main lib
    # isn't `libpython_android_test.so` (every real project) still
    # link. Strip the `lib` prefix and `.so` suffix.
    stub_lib_name =
      if stub_so do
        stub_so
        |> Path.basename()
        |> String.replace_prefix("lib", "")
        |> String.replace_suffix(".so", "")
      end

    # Static-link libc++ so the resulting .so doesn't depend on
    # libc++_shared.so being in the app's jniLibs/.
    # Link against the stub: gives libpythonx.so a NEEDED
    # lib<app>.so entry plus link-time symbol resolution for enif_*.
    # The stub itself is discarded after link.
    args =
      ["-shared", "-fPIC", "-fvisibility=hidden", "-std=c++17", "-Os"] ++
        ["-ffunction-sections", "-fdata-sections"] ++
        ["-static-libstdc++"] ++
        ["-I", erts_inc, "-I", "#{erts_inc}/internal"] ++
        ["-I", fine_inc, "-I", python_inc] ++
        ["-Wno-unused-parameter", "-Wno-comment"] ++
        if(stub_so, do: ["-L", Path.dirname(stub_so), "-l#{stub_lib_name}"], else: []) ++
        ["#{pythonx_src}/pythonx.cpp", "#{pythonx_src}/python.cpp"] ++
        ["-o", out]

    case System.cmd(clang, args, stderr_to_stdout: true) do
      {_, 0} ->
        IO.puts("  ✓ cross-compiled #{out}")
        if stub_so, do: File.rm_rf!(Path.dirname(stub_so))
        :ok

      {output, code} ->
        if stub_so, do: File.rm_rf!(Path.dirname(stub_so))
        IO.puts(:stderr, "  ✗ libpythonx.so cross-compile failed (exit #{code})")
        IO.puts(:stderr, output)
        {:error, "libpythonx.so cross-compile failed for #{abi}"}
    end
  end

  # Builds a tiny stub `libpython_android_test.so` (or whatever the user's
  # main lib is called, which we read from the keepalive .c we generated)
  # that exports the enif_* symbols libpythonx.so references. Link-time only;
  # the real lib provides symbols at runtime via SONAME match.
  defp build_libpython_android_test_stub_so(bin_dir, triple, api, abi) do
    cc = Path.join(bin_dir, "#{triple}#{api}-clang")
    keepalive = "android/app/src/main/jni/enif_keepalive.c"

    if File.regular?(cc) and File.exists?(keepalive) do
      build_stub_with_symbols(cc, keepalive, abi)
    end
  end

  defp build_stub_with_symbols(cc, keepalive, abi) do
    symbols =
      keepalive
      |> File.read!()
      |> String.split("\n")
      |> Enum.map(&Regex.run(Regex.compile!(~S{extern void (enif_\w+)}), &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(fn [_, name] -> name end)
      |> Enum.uniq()

    if symbols != [] do
      # Mob's main lib SONAME is `lib<app_name>.so`. Detect from the
      # generated CMakeLists' `add_library` directive.
      soname = detect_main_lib_soname() || "libpython_android_test.so"

      tmp =
        System.tmp_dir!()
        |> Path.join("mob_pythonx_stub_#{abi}_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)
      stub_c = Path.join(tmp, "stub.c")
      stub_so = Path.join(tmp, soname)

      body = Enum.map_join(symbols, "\n", fn sym -> "void #{sym}(void) {}" end)
      File.write!(stub_c, body <> "\n")

      case System.cmd(
             cc,
             ["-shared", "-fPIC", "-Wl,-soname,#{soname}", stub_c, "-o", stub_so],
             stderr_to_stdout: true
           ) do
        {_, 0} ->
          stub_so

        _ ->
          File.rm_rf!(tmp)
          nil
      end
    end
  end

  defp detect_main_lib_soname do
    case File.read("android/app/src/main/jni/CMakeLists.txt") do
      {:ok, content} ->
        case Regex.run(Regex.compile!(~S{add_library\(\s*(\S+)\s+SHARED}), content) do
          [_, name] -> "lib#{name}.so"
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp android_triple("arm64-v8a"), do: "aarch64-linux-android"
  defp android_triple("x86_64"), do: "x86_64-linux-android"

  # Match mob_new's android template `minSdk 28`. Using API 28 keeps
  # the NIF compatible with the same device floor as the rest of the
  # Mob-generated app code.
  defp android_api_level, do: "28"

  # Pre-built NDK toolchains are named for the host that runs them.
  # Mob is a macOS-first dev environment; Linux hosts use the same
  # `darwin-x86_64` directory name on Apple Silicon thanks to Rosetta.
  defp android_ndk_host do
    case :os.type() do
      {:unix, :darwin} -> "darwin-x86_64"
      {:unix, _} -> "linux-x86_64"
      _ -> "darwin-x86_64"
    end
  end

  defp copy_python_jni_libs(bundle_dir, abi) do
    src_dir = MobDev.PythonAndroidSupport.jni_libs_dir(bundle_dir, abi)
    dst_dir = "android/app/src/main/jniLibs/#{abi}"
    File.mkdir_p!(dst_dir)

    if File.dir?(src_dir) do
      Path.wildcard(Path.join(src_dir, "*.so"))
      |> Enum.each(fn src ->
        dst = Path.join(dst_dir, Path.basename(src))
        cp(src, dst)
      end)
    end

    copy_project_python_jni_libs(abi, dst_dir)

    :ok
  end

  # Project-supplied native libs that need to land in jniLibs/<abi>/
  # rather than site-packages. Wheels for cffi-using packages
  # (cryptography, etc.) reference `libffi.so` via a NEEDED entry,
  # which the Android dynamic loader resolves out of the app's
  # `nativeLibraryDir` — i.e. the jniLibs/<abi>/ contents. Putting
  # the .so under filesDir/python/ doesn't help because the loader
  # has already given up by the time Python imports happen.
  #
  # Convention: project drops <name>.so files into
  # `priv/python_jni_libs/<abi>/`. Each one is copied into
  # `android/app/src/main/jniLibs/<abi>/` verbatim. Mob doesn't try
  # to know what's inside — that's the project's call.
  defp copy_project_python_jni_libs(abi, dst_dir) do
    src_dir = Path.join(["priv", "python_jni_libs", abi])

    if File.dir?(src_dir) do
      Path.wildcard(Path.join(src_dir, "*.so"))
      |> Enum.each(fn src ->
        dst = Path.join(dst_dir, Path.basename(src))
        cp(src, dst)
      end)
    end

    :ok
  end

  # Place the (slice-independent) stdlib and per-abi lib-dynload into
  # android/app/src/main/assets/python/. The APK packager will ship
  # them as packaged assets; the user's app extracts them to internal
  # storage on first launch (see <App>.PythonPaths).
  defp copy_python_assets(bundle_dir) do
    # Extract layout follows the PYTHONHOME contract:
    #   <filesDir>/python/lib/python3.13/        ← shared pure-Python stdlib
    #   <filesDir>/python/lib/python3.13/lib-dynload/<abi>/  ← arch-specific .so
    # Mirrors iOS's <App>.app/otp/python/ layout — Python's own bootstrap
    # walks `<home>/lib/pythonX.Y` to find encodings/ etc. before sys.path
    # is even initialized.
    assets_root = "android/app/src/main/assets/python"
    File.mkdir_p!(assets_root)

    stdlib_src = MobDev.PythonAndroidSupport.stdlib_dir(bundle_dir)
    stdlib_dst = Path.join([assets_root, "lib", "python3.13"])

    if File.dir?(stdlib_src) and not File.dir?(stdlib_dst) do
      File.mkdir_p!(stdlib_dst)
      System.cmd("cp", ["-R", stdlib_src <> "/.", stdlib_dst])
    end

    Enum.each(@android_python_abis, fn abi ->
      ld_src = MobDev.PythonAndroidSupport.lib_dynload_dir(bundle_dir, abi)
      # lib-dynload nests under stdlib for Python's own discovery, but
      # we keep per-abi subdirs since we ship multiple architectures.
      ld_dst = Path.join([assets_root, "lib", "python3.13", "lib-dynload", abi])

      if File.dir?(ld_src) and not File.dir?(ld_dst) do
        File.mkdir_p!(ld_dst)
        System.cmd("cp", ["-R", ld_src <> "/.", ld_dst])
      end
    end)

    copy_project_python_wheels(assets_root)

    :ok
  end

  # Drops project-supplied Python packages from `priv/python_wheels/`
  # into the per-platform site-packages directory under `python_root`.
  #
  # `python_root` is the platform's Python install root:
  #   * Android: `android/app/src/main/assets/python` (APK assets dir)
  #   * iOS:     `<otp_root>/python` (under the .app bundle)
  #
  # Both layouts share the `lib/python3.13/site-packages` suffix, so a
  # single helper works for all three callers (`copy_python_assets/1` for
  # Android, `maybe_setup_pythonx_sim/5` + `maybe_setup_pythonx_device/5`
  # for iOS).
  #
  # Each subdirectory of `priv/python_wheels/` is treated as an
  # already-extracted wheel — copy the directory contents directly into
  # site-packages. Wheel-extraction is the project's job (the wheel
  # format is package-specific and per-platform), but landing the
  # extracted layout into the per-platform bundle is a generic step
  # worth owning here so every Mob+Pythonx project doesn't reimplement
  # asset placement.
  #
  # Layout convention: `priv/python_wheels/<wheel-name>/` contains the
  # wheel's unzipped contents. A typical `cryptography-X.Y/` directory
  # holds `cryptography/`, `cryptography-X.Y.dist-info/`, and any
  # platform-specific `.so` / `.dylib` files. Everything inside gets
  # copied verbatim — site-packages discovery handles the rest.
  defp copy_project_python_wheels(python_root) do
    wheels_dir = Path.join("priv", "python_wheels")

    if File.dir?(wheels_dir) do
      site_packages = Path.join([python_root, "lib", "python3.13", "site-packages"])
      File.mkdir_p!(site_packages)

      wheels_dir
      |> File.ls!()
      |> Enum.each(fn entry ->
        src = Path.join(wheels_dir, entry)

        if File.dir?(src) do
          System.cmd("cp", ["-R", src <> "/.", site_packages])
        end
      end)
    end

    :ok
  end

  @doc """
  iOS-flavoured counterpart to `copy_project_python_wheels/1`. Same
  `priv/python_wheels/` convention, same site-packages destination,
  but skips any wheel directory containing a `.so` file at any depth.

  Today's wheel set ships Android-built binaries (Chaquopy-compatible)
  under names like `_cffi_backend.so` and `_rust.so` — no `"android"`
  in the filename — so a name-based heuristic misses them. Until the
  wheels directory holds platform-tagged subdirs (or an iOS-specific
  source), treating "has any `.so`" as "Android-only, skip on iOS"
  matches the current reality: pure-Python wheels (rns, lxmf,
  pyserial, pycparser) are the only iOS-safe ones. RNS falls back to
  its internal crypto provider when `cryptography` isn't importable,
  so this is enough to bring the Reticulum stack up on iOS device
  builds.

  Public so the iOS-specific filter can be tested independently of
  the rest of the bundle pipeline.
  """
  @spec copy_ios_safe_project_python_wheels(String.t(), String.t()) :: :ok
  def copy_ios_safe_project_python_wheels(python_root, wheels_dir) do
    if File.dir?(wheels_dir) do
      site_packages = Path.join([python_root, "lib", "python3.13", "site-packages"])
      File.mkdir_p!(site_packages)

      wheels_dir
      |> File.ls!()
      |> Enum.each(fn entry ->
        src = Path.join(wheels_dir, entry)

        cond do
          not File.dir?(src) ->
            :skip

          wheel_has_native_extension?(src) ->
            IO.puts(
              "  [ios-wheels] skipped wheel with native extensions (assumed non-iOS): #{entry}"
            )

          true ->
            IO.puts("  [ios-wheels] copied #{entry}")
            System.cmd("cp", ["-R", src <> "/.", site_packages])
        end
      end)
    end

    :ok
  end

  @doc """
  True if `wheel_dir` contains at least one `.so` file at any depth.
  Used by `copy_ios_safe_project_python_wheels/2` to detect
  Android-only wheels.
  """
  @spec wheel_has_native_extension?(String.t()) :: boolean()
  def wheel_has_native_extension?(wheel_dir) do
    case Path.wildcard(Path.join([wheel_dir, "**", "*.so"])) do
      [] -> false
      _ -> true
    end
  end

  # Copies ERTS helper executables into jniLibs as lib*.so so Android grants
  # them the apk_data_file SELinux label (required for execve).
  defp ensure_jni_libs(otp_dir, abi) do
    jni_libs = "android/app/src/main/jniLibs/#{abi}"

    with [erts_bins] <- Path.wildcard("#{otp_dir}/erts-*/bin"),
         :ok <- validate_android_erts_helpers(erts_bins),
         :ok <- mkdir_android_jni_libs(jni_libs) do
      Enum.reduce_while(@android_erts_helpers, :ok, fn {exe, lib}, :ok ->
        case replace_android_jni_helper(
               Path.join(erts_bins, exe),
               Path.join(jni_libs, lib)
             ) do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    else
      {:error, _reason} = error -> error
      _missing_or_ambiguous -> {:error, "Android ERTS helper source is missing or ambiguous"}
    end
  end

  defp validate_android_erts_helpers(erts_bins) do
    if Enum.all?(@android_erts_helpers, fn {exe, _lib} ->
         File.regular?(Path.join(erts_bins, exe))
       end) do
      :ok
    else
      {:error, "Android ERTS helper source is incomplete"}
    end
  end

  defp mkdir_android_jni_libs(jni_libs) do
    case File.mkdir_p(jni_libs) do
      :ok -> :ok
      {:error, _reason} -> {:error, "Could not prepare Android JNI library directory"}
    end
  end

  defp replace_android_jni_helper(source, destination) do
    staged =
      destination <>
        ".mob-stage-#{System.unique_integer([:positive, :monotonic])}"

    try do
      with :ok <- File.cp(source, staged),
           :ok <- File.rename(staged, destination),
           {:ok, source_bytes} <- File.read(source),
           {:ok, destination_bytes} <- File.read(destination),
           true <-
             :crypto.hash(:sha256, source_bytes) ==
               :crypto.hash(:sha256, destination_bytes) do
        :ok
      else
        _failure -> {:error, "Could not stage Android ERTS helpers"}
      end
    after
      File.rm(staged)
    end
  end

  defp gradle_assemble do
    IO.puts("  Running Gradle assembleDebug...")
    IO.puts("  (first build may take a few minutes while CMake compiles native code)")
    android_dir = Path.join(File.cwd!(), "android")
    gradlew = Path.join(android_dir, "gradlew")

    # Stale Gradle daemon registry locks accumulate when builds are killed (Ctrl+C,
    # force-stop, etc.) and cause subsequent runs to hang silently while the wrapper
    # waits to acquire the lock. Clear them before every build.
    clear_stale_gradle_locks()
    remove_stale_release_otp_zip(android_dir)

    if File.exists?(gradlew) do
      # Run gradlew as `bash scriptpath args` rather than exec-ing it directly
      # or using `bash -c "cmd"`.
      #
      # When System.cmd exec's gradlew directly, Gradle's worker subprocesses
      # may inherit the Erlang port's I/O pipes. If they outlive the main JVM,
      # the pipe stays open and System.cmd never receives EOF — hanging forever.
      #
      # `bash scriptpath args` keeps bash as the parent process. bash exits when
      # the script finishes (even if exec'd children remain), cleanly closing the
      # pipe to Erlang.
      #
      # NOTE: Kotlin errors appear before "* What went wrong:" in the output.
      # If the build fails, scroll up or run `cd android && ./gradlew assembleDebug`.
      case System.cmd("bash", [gradlew, "assembleDebug", "--no-daemon"],
             cd: android_dir,
             stderr_to_stdout: true,
             into: IO.stream()
           ) do
        {_, 0} ->
          :ok

        {_, _} ->
          {:error,
           "Gradle failed — scroll up for errors\n  (or run: cd android && ./gradlew assembleDebug)"}
      end
    else
      {:error, "gradlew not found at #{gradlew}"}
    end
  end

  # `mix mob.release --android` used to write the release OTP bundle to the
  # shared `src/main/assets/otp.zip`, which Gradle merges into every build
  # variant including debug. A prior release build then poisons every
  # subsequent debug deploy: MobBridge.kt's extractOtpIfNeeded() re-extracts
  # that stale zip on the next app launch (keyed off PackageInfo.lastUpdateTime,
  # which changes on every reinstall), silently overwriting freshly pushed dev
  # BEAMs with the release snapshot. Release builds now write to the
  # variant-scoped `src/release/assets/` instead (never merged into debug), but
  # existing checkouts may still carry a leftover `src/main/assets/otp.zip`
  # from before that fix — remove it so debug builds can't be poisoned by it.
  @doc false
  @spec remove_stale_release_otp_zip(String.t()) :: :ok
  def remove_stale_release_otp_zip(android_dir) do
    stale = Path.join([android_dir, "app", "src", "main", "assets", "otp.zip"])
    if File.exists?(stale), do: File.rm!(stale)
    :ok
  end

  # Remove stale Gradle lock files left behind when a build is interrupted
  # (Ctrl+C, kill, etc.). These cause the next run to hang indefinitely while
  # the wrapper waits to acquire the lock.
  defp clear_stale_gradle_locks do
    gradle_home =
      System.get_env("GRADLE_USER_HOME") ||
        Path.join(System.user_home!(), ".gradle")

    patterns = [
      "#{gradle_home}/daemon/*/registry.bin.lock",
      "#{gradle_home}/wrapper/dists/**/*.lck",
      "#{gradle_home}/native/**/*.lock",
      "#{gradle_home}/caches/**/*.lock",
      "#{gradle_home}/caches/**/*.lck"
    ]

    Enum.each(patterns, fn pattern ->
      Path.wildcard(pattern, match_dot: true) |> Enum.each(&File.rm/1)
    end)
  end

  @doc false
  @spec resolve_android_update_targets(String.t() | nil) ::
          {:ok, [String.t()]} | {:error, atom()}
  def resolve_android_update_targets(device_id) do
    resolve_android_update_targets(device_id, &run_system_command/2)
  end

  @doc false
  @spec resolve_android_update_targets(String.t() | nil, command_runner()) ::
          {:ok, [String.t()]} | {:error, atom()}
  def resolve_android_update_targets(nil, runner) do
    case invoke_command(runner, "adb", ["devices"]) do
      {:ok, output, 0} -> resolve_adb_targets(output, nil)
      _ -> {:error, :device_discovery_failed}
    end
  end

  def resolve_android_update_targets(device_id, runner) when is_binary(device_id) do
    if valid_adb_serial?(device_id) do
      case invoke_command(runner, "adb", ["devices"]) do
        {:ok, output, 0} -> resolve_adb_targets(output, device_id)
        _ -> {:error, :device_discovery_failed}
      end
    else
      {:error, :invalid_target}
    end
  end

  def resolve_android_update_targets(_device_id, _runner), do: {:error, :invalid_target}

  @doc false
  @deprecated "use install_and_deliver_android_runtime/8 with an authoritative payload plan"
  @spec install_android_updates(String.t(), [String.t()]) ::
          {:ok, android_update_outcome()}
          | {:error, android_update_outcome() | atom()}
  def install_android_updates(apk, serials) do
    install_android_updates(apk, serials, &run_system_command/2)
  end

  @doc false
  @deprecated "use install_and_deliver_android_runtime/8 with an authoritative payload plan"
  @spec install_android_updates(String.t(), [String.t()], command_runner()) ::
          {:ok, android_update_outcome()}
          | {:error, android_update_outcome() | atom()}
  def install_android_updates(apk, serials, runner)

  def install_android_updates(apk, serials, _runner)
      when not is_binary(apk) or apk == "" or not is_list(serials),
      do: {:error, :invalid_update_request}

  def install_android_updates(_apk, [], _runner), do: {:error, :no_explicit_targets}

  def install_android_updates(_apk, serials, _runner)
      when length(serials) > @max_android_update_targets,
      do: {:error, :too_many_targets}

  def install_android_updates(_apk, serials, _runner) do
    with :ok <- validate_android_update_serials(serials) do
      {:error, :authoritative_transaction_required}
    end
  end

  @doc false
  @deprecated "use install_and_deliver_android_runtime/8 with an authoritative payload plan"
  @spec install_and_deliver_android(
          String.t(),
          [String.t()],
          command_runner(),
          (String.t() -> :ok | {:error, term()})
        ) :: :ok | {:error, String.t()}
  def install_and_deliver_android(apk, serials, runner, _deliver) do
    case install_android_updates(apk, serials, runner) do
      {:error, reason} ->
        {:error, android_update_request_error(reason)}
    end
  end

  @doc false
  @spec install_and_deliver_android_runtime(
          String.t(),
          [String.t()],
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          keyword()
        ) :: {:ok, map()} | {:error, String.t()} | {:error, String.t(), map()}
  def install_and_deliver_android_runtime(
        apk,
        serials,
        bundle_id,
        elixir_lib,
        otp_arm64,
        otp_arm32,
        otp_x86_64,
        opts \\ []
      ) do
    runner = Keyword.get(opts, :probe_runner, &run_system_command/2)
    manifest_runner = Keyword.get(opts, :manifest_runner, &run_system_command/2)
    otp_runner = Keyword.get(opts, :otp_runner, &run_system_command/3)
    app_data = "/data/data/#{bundle_id}/files"

    with :ok <- validate_android_bundle_id(bundle_id),
         :ok <- validate_android_app_data(app_data, bundle_id),
         :ok <- preflight_android_otp_candidates(otp_arm64, otp_arm32, otp_x86_64, elixir_lib),
         :ok <- validate_android_update_serials(serials),
         {:ok, preinstall, cleanup} <- android_preinstall_callbacks(opts),
         {:ok, apk_snapshot} <- snapshot_android_apk(apk, opts) do
      try do
        with :ok <- validate_android_apk_identity(apk_snapshot.path, bundle_id, manifest_runner),
             :ok <- preflight_installed_android_targets(serials, bundle_id, runner),
             {:ok, selections} <-
               select_android_otp_sources(
                 serials,
                 otp_arm64,
                 otp_arm32,
                 otp_x86_64,
                 runner
               ),
             {:ok, payload_plan} <-
               invoke_android_preinstall(
                 preinstall,
                 cleanup,
                 bundle_id,
                 serials,
                 selections,
                 apk_snapshot
               ) do
          run_android_runtime_transaction(
            apk_snapshot,
            serials,
            bundle_id,
            app_data,
            elixir_lib,
            selections,
            payload_plan,
            cleanup,
            runner,
            otp_runner,
            opts
          )
        end
      after
        File.rm(apk_snapshot.path)
      end
    end
  end

  defp snapshot_android_apk(apk, opts) when is_binary(apk) do
    tmp_root = Keyword.get(opts, :tmp_root, System.tmp_dir!())
    snapshot_id = :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
    snapshot = Path.join(tmp_root, "mob_apk_#{snapshot_id}.apk")

    with {:ok, %{size: source_size}}
         when source_size > 0 and
                source_size <= @max_android_apk_bytes <-
           File.stat(apk),
         :ok <- File.cp(apk, snapshot),
         :ok <- File.chmod(snapshot, 0o400),
         {:ok, %{size: ^source_size}} <- File.stat(snapshot),
         {:ok, sha256} <- file_sha256(snapshot) do
      {:ok, %{path: snapshot, size: source_size, sha256: sha256}}
    else
      _failure ->
        File.rm(snapshot)
        {:error, "Could not snapshot exact Android APK; refusing update"}
    end
  end

  defp snapshot_android_apk(_apk, _opts),
    do: {:error, "Android APK path is invalid; refusing update"}

  defp file_sha256(path) do
    case File.open(path, [:read, :binary], fn io ->
           hash_file_chunks(io, :crypto.hash_init(:sha256))
         end) do
      {:ok, digest} when is_binary(digest) -> {:ok, digest}
      _failure -> {:error, :hash_failed}
    end
  end

  defp hash_file_chunks(io, context) do
    case IO.binread(io, 1_048_576) do
      :eof -> :crypto.hash_final(context)
      {:error, _reason} -> {:error, :read_failed}
      bytes when is_binary(bytes) -> hash_file_chunks(io, :crypto.hash_update(context, bytes))
    end
  end

  defp android_preinstall_callbacks(opts) do
    preinstall = Keyword.get(opts, :android_preinstall)
    cleanup = Keyword.get(opts, :android_preinstall_cleanup)

    if is_function(preinstall, 1) and is_function(cleanup, 1) do
      {:ok, preinstall, cleanup}
    else
      {:error, "Android device phase requires an authoritative payload plan"}
    end
  end

  defp invoke_android_preinstall(
         preinstall,
         cleanup,
         bundle_id,
         serials,
         selections,
         apk_snapshot
       ) do
    selected_abis_by_serial =
      Map.new(selections, fn {serial, %{abi: abi}} -> {serial, abi} end)

    input = %{
      apk: apk_snapshot.path,
      apk_sha256: Base.encode16(apk_snapshot.sha256, case: :lower),
      apk_size: apk_snapshot.size,
      bundle_id: bundle_id,
      serials: Enum.sort(serials),
      selected_abis: selected_android_abis(selections),
      selected_abis_by_serial: selected_abis_by_serial
    }

    try do
      case preinstall.(input) do
        {:ok, payload_plan} ->
          case validate_android_payload_plan(payload_plan, input) do
            {:ok, _payload_plan} = ok ->
              ok

            {:error, _reason} = error ->
              cleanup_android_payload_after_failure(cleanup, payload_plan, error)
          end

        {:error, _bounded_reason} ->
          {:error, "Could not prepare authoritative Android payload"}

        _invalid ->
          {:error, "Authoritative Android payload plan is invalid"}
      end
    catch
      _kind, _reason -> {:error, "Could not prepare authoritative Android payload"}
    end
  end

  defp validate_android_payload_plan(payload_plan, input)
       when is_map(payload_plan) and is_map(input) do
    with true <-
           exact_map_keys?(payload_plan, [
             :version,
             :package,
             :attempt_id,
             :serials,
             :selected_abis,
             :selected_abis_by_serial,
             :apk,
             :beam,
             :exqlite,
             :restart_by_serial
           ]),
         1 <- payload_plan.version,
         true <- payload_plan.package == input.bundle_id,
         true <- payload_plan.serials == input.serials,
         true <- payload_plan.selected_abis == input.selected_abis,
         true <- payload_plan.selected_abis_by_serial == input.selected_abis_by_serial,
         true <- valid_android_attempt_id?(payload_plan.attempt_id),
         :ok <- validate_android_plan_apk(payload_plan.apk, input),
         :ok <-
           validate_android_beam_plan(
             payload_plan.beam,
             payload_plan.package,
             payload_plan.attempt_id
           ),
         :ok <-
           validate_android_exqlite_plan(
             payload_plan.exqlite,
             payload_plan.package,
             payload_plan.attempt_id,
             payload_plan.selected_abis
           ),
         :ok <-
           validate_android_restart_plan(
             payload_plan.restart_by_serial,
             payload_plan.package,
             payload_plan.serials
           ),
         true <- android_plan_local_paths_distinct?(payload_plan) do
      {:ok, payload_plan}
    else
      _invalid -> {:error, "Authoritative Android payload plan identity is invalid"}
    end
  end

  defp validate_android_payload_plan(_payload_plan, _input),
    do: {:error, "Authoritative Android payload plan identity is invalid"}

  defp exact_map_keys?(map, keys) do
    MapSet.new(Map.keys(map)) == MapSet.new(keys)
  end

  defp valid_android_attempt_id?(attempt_id) when is_binary(attempt_id) do
    String.valid?(attempt_id) and
      Regex.match?(Regex.compile!(@android_attempt_id_pattern), attempt_id)
  end

  defp valid_android_attempt_id?(_attempt_id), do: false

  defp validate_android_plan_apk(apk, input) do
    with :ok <- validate_android_local_file_identity(apk, @max_android_apk_bytes),
         true <- apk.path != input.apk,
         true <- apk.size == input.apk_size,
         true <- apk.sha256 == input.apk_sha256 do
      :ok
    else
      _invalid -> {:error, :invalid_plan_apk}
    end
  end

  defp validate_android_local_file_identity(identity, max_bytes) when is_map(identity) do
    with true <- exact_map_keys?(identity, [:path, :size, :sha256]),
         true <- safe_android_local_plan_path?(identity.path),
         true <- is_integer(identity.size) and identity.size > 0 and identity.size <= max_bytes,
         true <- valid_sha256_hex?(identity.sha256),
         {:ok, %{type: :regular, size: size, mode: mode}} <- File.stat(identity.path),
         true <- size == identity.size,
         true <- Bitwise.band(mode, 0o222) == 0,
         {:ok, digest} <- file_sha256(identity.path),
         true <- Base.encode16(digest, case: :lower) == identity.sha256 do
      :ok
    else
      _invalid -> {:error, :invalid_local_plan_file}
    end
  end

  defp validate_android_local_file_identity(_identity, _max_bytes),
    do: {:error, :invalid_local_plan_file}

  defp safe_android_local_plan_path?(path) do
    is_binary(path) and byte_size(path) in 1..2_048 and String.valid?(path) and
      Path.type(path) == :absolute and not Enum.member?(Path.split(path), "..")
  end

  defp valid_sha256_hex?(sha256) when is_binary(sha256) do
    Regex.match?(Regex.compile!("\\A[0-9a-f]{64}\\z"), sha256)
  end

  defp valid_sha256_hex?(_sha256), do: false

  defp validate_android_beam_plan(beam, package, attempt_id) when is_map(beam) do
    with true <-
           exact_map_keys?(beam, [
             :archive,
             :stage_device,
             :app_stage,
             :app_backup,
             :activation_lock,
             :dist_snapshot,
             :runtime_version,
             :beam_flags
           ]),
         :ok <- validate_android_local_file_identity(beam.archive, @max_android_apk_bytes),
         :ok <-
           validate_android_beam_remote_paths(beam, package, attempt_id),
         :ok <- validate_android_dist_snapshot(beam.dist_snapshot),
         true <- beam.runtime_version == System.version(),
         true <- valid_android_beam_flags?(beam.beam_flags) do
      :ok
    else
      _invalid -> {:error, :invalid_beam_plan}
    end
  end

  defp validate_android_beam_plan(_beam, _package, _attempt_id),
    do: {:error, :invalid_beam_plan}

  defp validate_android_beam_remote_paths(plan, package, attempt_id) do
    app_data = "/data/data/#{package}/files"

    if plan.stage_device == "/data/local/tmp/mob_beams_#{attempt_id}.tar" and
         plan.app_stage == "#{app_data}/.mob_beams_stage_#{attempt_id}" and
         plan.app_backup == "#{app_data}/.mob_beams_backup_#{attempt_id}" and
         plan.activation_lock == "#{app_data}/.mob_beams_activation_lock" do
      :ok
    else
      {:error, :invalid_remote_plan_paths}
    end
  end

  defp validate_android_dist_snapshot(snapshot) do
    case MobDev.HotPush.validate_prepared_snapshot(snapshot) do
      :ok -> :ok
      {:error, _reason} -> {:error, :invalid_dist_snapshot}
    end
  end

  defp valid_android_beam_flags?(nil), do: true

  defp valid_android_beam_flags?(flags) when is_binary(flags),
    do: byte_size(flags) <= 4_096 and String.valid?(flags)

  defp valid_android_beam_flags?(_flags), do: false

  defp validate_android_exqlite_plan(nil, _package, _attempt_id, _selected_abis), do: :ok

  defp validate_android_exqlite_plan(exqlite, package, attempt_id, selected_abis)
       when is_map(exqlite) do
    with true <-
           exact_map_keys?(exqlite, [
             :archive,
             :stage_device,
             :app_stage,
             :app_backup,
             :activation_lock,
             :app_version,
             :beam_sentinel,
             :nif
           ]),
         :ok <- validate_android_local_file_identity(exqlite.archive, @max_android_apk_bytes),
         :ok <-
           validate_android_exqlite_remote_paths(exqlite, package, attempt_id),
         true <- valid_android_plan_component?(exqlite.app_version, 128),
         true <- valid_android_beam_sentinel?(exqlite.beam_sentinel),
         :ok <- validate_android_exqlite_nif(exqlite.nif, selected_abis) do
      :ok
    else
      _invalid -> {:error, :invalid_exqlite_plan}
    end
  end

  defp validate_android_exqlite_plan(_exqlite, _package, _attempt_id, _selected_abis),
    do: {:error, :invalid_exqlite_plan}

  defp validate_android_exqlite_remote_paths(plan, package, attempt_id) do
    lib_parent = "/data/data/#{package}/files/otp/lib"

    if plan.stage_device == "/data/local/tmp/mob_exqlite_#{attempt_id}.tar" and
         plan.app_stage == "#{lib_parent}/.mob_exqlite_stage_#{attempt_id}" and
         plan.app_backup == "#{lib_parent}/.mob_exqlite_backup_#{attempt_id}" and
         plan.activation_lock == "#{lib_parent}/.mob_exqlite_activation_lock" do
      :ok
    else
      {:error, :invalid_remote_plan_paths}
    end
  end

  defp validate_android_exqlite_nif(nif, selected_abis) when is_map(nif) do
    expected_entries = Map.new(selected_abis, &{&1, "lib/#{&1}/libsqlite3_nif.so"})

    if exact_map_keys?(nif, [
         :source,
         :filename,
         :selected_abis,
         :required_apk_entries
       ]) and nif.source == :installed_apk and nif.filename == "libsqlite3_nif.so" and
         nif.selected_abis == selected_abis and nif.required_apk_entries == expected_entries do
      :ok
    else
      {:error, :invalid_exqlite_nif}
    end
  end

  defp validate_android_exqlite_nif(_nif, _selected_abis),
    do: {:error, :invalid_exqlite_nif}

  defp valid_android_plan_component?(value, max_bytes) when is_binary(value) do
    byte_size(value) in 1..max_bytes and String.valid?(value) and
      Regex.match?(Regex.compile!("\\A[A-Za-z0-9._-]+\\z"), value)
  end

  defp valid_android_plan_component?(_value, _max_bytes), do: false

  defp valid_android_beam_sentinel?(sentinel) when is_binary(sentinel) do
    byte_size(sentinel) in 1..255 and String.valid?(sentinel) and
      Path.basename(sentinel) == sentinel and
      Regex.match?(Regex.compile!("\\A[A-Za-z0-9_.-]+\\.beam\\z"), sentinel)
  end

  defp valid_android_beam_sentinel?(_sentinel), do: false

  defp validate_android_restart_plan(restarts, package, serials) when is_map(restarts) do
    if Enum.sort(Map.keys(restarts)) == serials and
         Enum.all?(restarts, fn {serial, restart} ->
           valid_android_restart_entry?(serial, restart, package)
         end) do
      :ok
    else
      {:error, :invalid_restart_plan}
    end
  end

  defp validate_android_restart_plan(_restarts, _package, _serials),
    do: {:error, :invalid_restart_plan}

  defp valid_android_restart_entry?(serial, restart, package) when is_map(restart) do
    exact_map_keys?(restart, [
      :package,
      :activity,
      :restart?,
      :mode,
      :dist_port,
      :node_suffix
    ]) and restart.package == package and valid_adb_serial?(serial) and
      valid_android_activity?(restart.activity) and
      valid_android_node_suffix?(restart.node_suffix) and
      is_integer(restart.dist_port) and restart.dist_port in 1_024..65_535 and
      restart.restart? == true and restart.mode == :checked_restart
  end

  defp valid_android_restart_entry?(_serial, _restart, _package), do: false

  defp valid_android_activity?(activity) when is_binary(activity) do
    byte_size(activity) in 1..255 and String.valid?(activity) and
      Regex.match?(Regex.compile!("\\A\\.?[A-Za-z][A-Za-z0-9_.]*\\z"), activity)
  end

  defp valid_android_activity?(_activity), do: false

  defp valid_android_node_suffix?(suffix) when is_binary(suffix) do
    byte_size(suffix) in 1..128 and String.valid?(suffix) and
      Regex.match?(Regex.compile!("\\A[A-Za-z0-9_]+\\z"), suffix)
  end

  defp valid_android_node_suffix?(_suffix), do: false

  defp android_plan_local_paths_distinct?(payload_plan) do
    paths =
      [payload_plan.apk.path, payload_plan.beam.archive.path] ++
        case payload_plan.exqlite do
          nil -> []
          exqlite -> [exqlite.archive.path]
        end

    Enum.uniq(paths) == paths
  end

  defp run_android_runtime_transaction(
         apk_snapshot,
         serials,
         bundle_id,
         app_data,
         elixir_lib,
         selections,
         payload_plan,
         cleanup,
         runner,
         otp_runner,
         opts
       ) do
    try do
      result =
        with :ok <- verify_android_apk_snapshot(apk_snapshot),
             :ok <- validate_android_local_file_identity(payload_plan.apk, @max_android_apk_bytes),
             :ok <- validate_android_apk_runtime(payload_plan.apk.path, selections, payload_plan),
             :ok <- verify_android_apk_snapshot(apk_snapshot),
             {:ok, prepared} <-
               prepare_selected_otp_archives(selections, app_data, elixir_lib, opts),
             :ok <- validate_android_native_otp_plan(prepared, selections, app_data) do
          try do
            with {:ok, lock} <- acquire_android_deploy_lock(serials, bundle_id, runner, opts) do
              run_locked_android_transaction(lock, fn ->
                with :ok <- validate_android_native_otp_plan(prepared, selections, app_data) do
                  case deploy_locked_android_otp(
                         payload_plan.apk,
                         serials,
                         bundle_id,
                         app_data,
                         selections,
                         prepared,
                         lock,
                         runner,
                         otp_runner
                       ) do
                    :ok ->
                      transition_android_deploy_lock(lock, :acquired, :native_ready, runner)

                    {:error, {:android_deploy_lease_ambiguous, reason}} ->
                      {:error, reason, %{lock | state: :retained_ambiguous}}

                    {:error, reason} ->
                      {:error, reason, %{lock | state: :retained_failure}}
                  end
                else
                  {:error, reason} -> {:error, reason, %{lock | state: :retained_failure}}
                end
              end)
            end
          after
            cleanup_prepared_otp_archives(prepared)
          end
        end

      case result do
        {:ok, lock} ->
          {:ok, %{deploy_lock: lock, payload_plan: payload_plan}}

        {:error, _reason, _lock} = error ->
          cleanup_android_payload_after_failure(cleanup, payload_plan, error)

        {:error, _reason} = error ->
          cleanup_android_payload_after_failure(cleanup, payload_plan, error)

        _invalid ->
          cleanup_android_payload_after_failure(
            cleanup,
            payload_plan,
            {:error, "Authoritative Android runtime transaction returned an invalid result"}
          )
      end
    catch
      kind, reason ->
        case cleanup_android_payload(cleanup, payload_plan) do
          :ok -> :erlang.raise(kind, reason, __STACKTRACE__)
          {:error, cleanup_reason} -> {:error, cleanup_reason}
        end
    end
  end

  defp run_locked_android_transaction(lock, transaction) do
    try do
      transaction.()
    catch
      _kind, _reason ->
        {:error, "Android device transaction became ambiguous; deploy lease retained",
         %{lock | state: :retained_ambiguous}}
    end
  end

  defp verify_android_apk_snapshot(%{path: path, size: size, sha256: expected_sha256}) do
    with {:ok, %{size: ^size}} <- File.stat(path),
         {:ok, ^expected_sha256} <- file_sha256(path) do
      :ok
    else
      _changed -> {:error, "Exact Android APK snapshot changed; refusing update"}
    end
  end

  defp cleanup_android_payload(cleanup, payload_plan) do
    try do
      case cleanup.(payload_plan) do
        :ok -> :ok
        _invalid -> {:error, "Could not clean authoritative Android payload"}
      end
    catch
      _kind, _reason -> {:error, "Could not clean authoritative Android payload"}
    end
  end

  defp cleanup_android_payload_after_failure(cleanup, payload_plan, failure) do
    case cleanup_android_payload(cleanup, payload_plan) do
      :ok ->
        failure

      {:error, cleanup_reason} ->
        case failure do
          {:error, _reason, lock} -> {:error, cleanup_reason, lock}
          _failure -> {:error, cleanup_reason}
        end
    end
  end

  defp deploy_locked_android_otp(
         apk,
         serials,
         bundle_id,
         app_data,
         selections,
         prepared,
         lock,
         runner,
         otp_runner
       ) do
    Enum.reduce_while(serials, :ok, fn serial, :ok ->
      %{abi: expected_abi, otp_dir: otp_dir} = Map.fetch!(selections, serial)
      plan = Map.fetch!(prepared, otp_dir)

      result =
        with :ok <- verify_android_prepared_otp_archive(plan, otp_dir, expected_abi),
             :ok <- validate_android_local_file_identity(apk, @max_android_apk_bytes),
             :ok <- verify_android_deploy_lock_set(lock, runner),
             {:ok, ^serial} <- install_android_update(apk.path, serial, runner),
             :ok <- verify_android_deploy_lock_set(lock, runner),
             :ok <-
               repair_erts_helper_labels(
                 serial,
                 bundle_id,
                 expected_abi,
                 lock,
                 runner
               ),
             :ok <- verify_android_deploy_lock_set(lock, runner),
             :ok <- verify_android_prepared_otp_archive(plan, otp_dir, expected_abi) do
          deploy_prepared_otp(
            otp_runner,
            runner,
            lock,
            serial,
            bundle_id,
            app_data,
            plan
          )
        else
          {:error, %{reason: reason}} ->
            if definite_android_install_rejection?(reason) do
              {:error, "APK update failed: #{android_update_reason(reason)}"}
            else
              {:error,
               {:android_deploy_lease_ambiguous,
                "Android APK update result was not authoritative; deploy lease retained"}}
            end

          {:error, _reason} = error ->
            error
        end

      case result do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp verify_android_deploy_lock_owner(
         lock,
         serial,
         runner
       ) do
    case AndroidDeployLock.verify_owner(lock, serial, android_lock_runner(runner)) do
      :ok -> :ok
      {:error, _failure} -> {:error, "Android deploy lease owner could not be verified"}
    end
  end

  defp verify_android_deploy_lock_set(lock, runner) do
    Enum.reduce_while(lock.serials, :ok, fn serial, :ok ->
      case verify_android_deploy_lock_owner(lock, serial, runner) do
        :ok ->
          {:cont, :ok}

        {:error, _reason} ->
          {:halt,
           {:error,
            {:android_deploy_lease_ambiguous,
             "Android deploy lease set could not be verified; refusing mutation"}}}
      end
    end)
  end

  defp repair_erts_helper_labels(serial, bundle_id, expected_abi, lock, runner) do
    case invoke_command(runner, "adb", ["-s", serial, "root"]) do
      {:ok, output, status}
      when is_binary(output) and is_integer(status) and
             byte_size(output) <= @max_adb_install_result_bytes ->
        if String.valid?(output) do
          classify_android_root_response(String.trim(output), status)
          |> case do
            :not_rootable ->
              :ok

            {:rooted, restarted?} ->
              with :ok <- maybe_wait_for_rooted_adb(serial, restarted?, runner),
                   :ok <- verify_android_deploy_lock_set(lock, runner),
                   {:ok, ^expected_abi} <- probe_android_abi(serial, runner),
                   {:ok, apk_dir} <- probe_android_apk_dir(serial, bundle_id, runner),
                   :ok <- relabel_erts_helpers(serial, apk_dir, expected_abi, lock, runner) do
                :ok
              else
                {:error, _reason} = error -> error
                _abi_drift -> {:error, "Android ABI changed during deploy; refusing OTP delivery"}
              end

            :invalid ->
              {:error, "Could not classify adb root response; refusing OTP delivery"}
          end
        else
          {:error, "Invalid adb root response; refusing OTP delivery"}
        end

      _invalid ->
        {:error, "adb root probe failed; refusing OTP delivery"}
    end
  end

  defp classify_android_root_response(output, 0) do
    cond do
      output in ["adbd is already running as root", "adbd already running as root"] ->
        {:rooted, false}

      output in ["restarting adbd as root", "restarting adbd as root\n"] ->
        {:rooted, true}

      output == "adbd cannot run as root in production builds" ->
        :not_rootable

      true ->
        :invalid
    end
  end

  defp classify_android_root_response(output, _status) do
    if output == "adbd cannot run as root in production builds",
      do: :not_rootable,
      else: :invalid
  end

  defp maybe_wait_for_rooted_adb(_serial, false, _runner), do: :ok

  defp maybe_wait_for_rooted_adb(serial, true, runner) do
    checked_empty_android_command(runner, serial, ["wait-for-device"], "wait for rooted adb")
  end

  defp probe_android_abi(serial, runner) do
    runner
    |> invoke_command("adb", ["-s", serial, "shell", "getprop", "ro.product.cpu.abi"])
    |> android_abi_from_probe()
  end

  defp probe_android_apk_dir(serial, bundle_id, runner) do
    with {:ok, output, 0} <-
           invoke_command(runner, "adb", ["-s", serial, "shell", "pm", "path", bundle_id]),
         true <- byte_size(output) <= @max_adb_discovery_bytes,
         true <- String.valid?(output) do
      dirs =
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reduce_while([], fn
          "package:" <> path, dirs ->
            if safe_android_apk_path?(path),
              do: {:cont, [Path.dirname(path) | dirs]},
              else: {:halt, :invalid}

          _unexpected, _dirs ->
            {:halt, :invalid}
        end)

      case dirs do
        dirs when is_list(dirs) ->
          case Enum.uniq(dirs) do
            [dir] -> {:ok, dir}
            _ -> {:error, "Android APK path is missing or ambiguous"}
          end

        :invalid ->
          {:error, "Android APK path is invalid"}
      end
    else
      _ -> {:error, "Could not locate Android APK path"}
    end
  end

  defp relabel_erts_helpers(serial, apk_dir, abi, lock, runner) do
    abi_dir = if abi == "armeabi-v7a", do: "arm", else: abi |> String.replace("-v8a", "")
    lib_dir = Path.join([apk_dir, "lib", abi_dir])

    if safe_android_absolute_path?(lib_dir) do
      ["liberl_child_setup.so", "libinet_gethost.so", "libepmd.so"]
      |> Enum.reduce_while(:ok, fn lib, :ok ->
        case checked_empty_locked_android_command(
               lock,
               runner,
               serial,
               ["shell", "chcon", "u:object_r:apk_data_file:s0", Path.join(lib_dir, lib)],
               "repair ERTS helper label"
             ) do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    else
      {:error, "Android native library path is invalid"}
    end
  end

  defp checked_empty_android_command(runner, serial, args, operation) do
    case invoke_command(runner, "adb", ["-s", serial | args]) do
      {:ok, "", 0} -> :ok
      _failure_or_ambiguity -> {:error, "#{operation} failed"}
    end
  end

  defp checked_empty_locked_android_command(lock, runner, serial, args, operation) do
    with :ok <- verify_android_deploy_lock_set(lock, runner) do
      checked_empty_android_command(runner, serial, args, operation)
    end
  end

  defp safe_android_absolute_path?(path) do
    is_binary(path) and byte_size(path) <= 1_024 and String.valid?(path) and
      Regex.match?(Regex.compile!("\\A/[A-Za-z0-9._/+=~:-]+\\z"), path) and
      not Enum.member?(Path.split(path), "..")
  end

  defp safe_android_apk_path?(path) do
    parent = if is_binary(path), do: Path.dirname(path), else: ""

    safe_android_absolute_path?(path) and String.starts_with?(parent, "/data/app/") and
      parent != "/data/app" and String.ends_with?(path, ".apk") and
      Path.basename(path) not in ["", ".", ".."]
  end

  defp validate_android_apk_identity(apk, bundle_id, runner)
       when is_binary(apk) and is_function(runner, 2) do
    if File.regular?(apk) do
      case invoke_command(runner, "apkanalyzer", ["manifest", "application-id", apk]) do
        {:ok, output, 0}
        when byte_size(output) <= @max_adb_install_result_bytes ->
          lines =
            if String.valid?(output) do
              output
              |> String.split("\n", trim: true)
              |> Enum.map(&String.trim/1)
              |> Enum.reject(&(&1 == ""))
            else
              []
            end

          if lines == [bundle_id] do
            :ok
          else
            {:error, "Android APK application id does not match configured bundle id"}
          end

        _failure_or_malformed ->
          {:error, "Could not verify Android APK application id; refusing update"}
      end
    else
      {:error, "Android APK is missing; refusing update"}
    end
  end

  defp validate_android_apk_identity(_apk, _bundle_id, _runner),
    do: {:error, "Android APK path is invalid; refusing update"}

  defp validate_android_apk_runtime(apk, selections, payload_plan) do
    with {:ok, helper_sources} <- android_apk_helper_sources(selections),
         {:ok, payload_entries} <- android_payload_apk_entries(payload_plan, selections),
         {:ok, entries} <- android_apk_entries(apk),
         :ok <-
           validate_required_android_apk_entries(
             entries,
             Map.keys(helper_sources) ++ payload_entries
           ),
         :ok <- validate_android_apk_helper_content(apk, entries, helper_sources) do
      :ok
    end
  end

  defp android_apk_helper_sources(selections) when is_map(selections) do
    selections
    |> Map.values()
    |> Enum.uniq_by(& &1.abi)
    |> Enum.reduce_while({:ok, %{}}, fn %{abi: abi, otp_dir: otp_dir}, {:ok, sources} ->
      case Path.wildcard(Path.join(otp_dir, "erts-*/bin")) do
        [erts_bin] ->
          case validate_android_erts_helpers(erts_bin) do
            :ok ->
              next =
                Enum.reduce(@android_erts_helpers, sources, fn {source, packaged}, acc ->
                  Map.put(
                    acc,
                    "lib/#{abi}/#{packaged}",
                    Path.join(erts_bin, source)
                  )
                end)

              {:cont, {:ok, next}}

            {:error, _reason} = error ->
              {:halt, error}
          end

        _missing_or_ambiguous ->
          {:halt, {:error, "Android ERTS helper source is missing or ambiguous"}}
      end
    end)
  end

  defp android_payload_apk_entries(nil, _selections), do: {:ok, []}

  defp android_payload_apk_entries(%{exqlite: nil}, _selections), do: {:ok, []}

  defp android_payload_apk_entries(
         %{
           exqlite: %{
             nif: %{
               filename: "libsqlite3_nif.so",
               selected_abis: plan_abis,
               required_apk_entries: entries
             }
           }
         },
         selections
       ) do
    selected_abis = selected_android_abis(selections)
    expected = Map.new(selected_abis, &{&1, "lib/#{&1}/libsqlite3_nif.so"})

    if plan_abis == selected_abis and entries == expected do
      {:ok, expected |> Map.values() |> Enum.sort()}
    else
      {:error, "Android payload APK requirements do not match selected ABIs"}
    end
  end

  defp android_payload_apk_entries(_invalid, _selections),
    do: {:error, "Android payload APK requirements are invalid"}

  defp android_apk_entries(apk) do
    with {:ok, %{size: size}} when size > 0 and size <= @max_android_apk_bytes <-
           File.stat(apk),
         {:ok, zip_entries} <- :zip.list_dir(String.to_charlist(apk)),
         true <- length(zip_entries) <= @max_android_apk_entries do
      Enum.reduce_while(zip_entries, {:ok, []}, fn
        {:zip_comment, _comment}, {:ok, entries} ->
          {:cont, {:ok, entries}}

        {:zip_file, name, file_info, _comment, _offset, _compressed_size}, {:ok, entries} ->
          with {:ok, normalized} <- normalize_android_apk_entry_name(name),
               {:ok, uncompressed_size} <- android_zip_entry_size(file_info) do
            {:cont, {:ok, [{normalized, uncompressed_size} | entries]}}
          else
            {:error, _reason} = error -> {:halt, error}
          end

        _invalid, _acc ->
          {:halt, {:error, "Android APK ZIP directory is malformed"}}
      end)
    else
      false -> {:error, "Android APK ZIP directory exceeds the safety limit"}
      {:ok, %{size: _invalid}} -> {:error, "Android APK size is invalid"}
      _failure -> {:error, "Could not inspect Android APK ZIP directory"}
    end
  end

  defp normalize_android_apk_entry_name(name) when is_list(name) do
    try do
      normalized = List.to_string(name)

      if byte_size(normalized) > 0 and byte_size(normalized) <= @max_android_apk_entry_bytes and
           String.valid?(normalized) do
        {:ok, normalized}
      else
        {:error, "Android APK ZIP entry name is invalid"}
      end
    rescue
      _error -> {:error, "Android APK ZIP entry name is invalid"}
    end
  end

  defp normalize_android_apk_entry_name(_invalid),
    do: {:error, "Android APK ZIP entry name is invalid"}

  defp android_zip_entry_size(file_info)
       when is_tuple(file_info) and tuple_size(file_info) > 1 and
              elem(file_info, 0) == :file_info and is_integer(elem(file_info, 1)) and
              elem(file_info, 1) >= 0 and
              elem(file_info, 1) <= @max_android_apk_required_entry_bytes,
       do: {:ok, elem(file_info, 1)}

  defp android_zip_entry_size(_invalid),
    do: {:error, "Android APK ZIP entry size is invalid"}

  defp validate_required_android_apk_entries(entries, required) do
    frequencies = Enum.frequencies_by(entries, &elem(&1, 0))

    if Enum.all?(required, &(Map.get(frequencies, &1) == 1)) do
      :ok
    else
      {:error, "Android APK is missing an exact selected-ABI runtime entry"}
    end
  end

  defp validate_android_apk_helper_content(apk, entries, helper_sources) do
    required_names = Map.keys(helper_sources) |> Enum.sort()
    sizes = Map.new(entries)

    with true <- Enum.all?(required_names, &(Map.fetch!(sizes, &1) > 0)),
         {:ok, extracted} <-
           :zip.extract(
             String.to_charlist(apk),
             [:memory, {:file_list, Enum.map(required_names, &String.to_charlist/1)}]
           ),
         true <- length(extracted) == length(required_names) do
      extracted
      |> Enum.reduce_while(:ok, fn {entry_name, bytes}, :ok ->
        with {:ok, normalized} <- normalize_android_apk_entry_name(entry_name),
             source when is_binary(source) <- Map.fetch!(helper_sources, normalized),
             {:ok, source_bytes} <- File.read(source),
             true <-
               byte_size(bytes) == byte_size(source_bytes) and
                 :crypto.hash(:sha256, bytes) == :crypto.hash(:sha256, source_bytes) do
          {:cont, :ok}
        else
          _mismatch -> {:halt, {:error, "Android APK ERTS helper provenance mismatch"}}
        end
      end)
    else
      _missing_or_invalid -> {:error, "Android APK ERTS helper provenance mismatch"}
    end
  end

  defp selected_android_abis(selections) do
    selections
    |> Map.values()
    |> Enum.map(& &1.abi)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp select_android_otp_sources(serials, otp_arm64, otp_arm32, otp_x86_64, runner) do
    Enum.reduce_while(serials, {:ok, %{}}, fn serial, {:ok, selections} ->
      case device_otp_selection(serial, otp_arm64, otp_arm32, otp_x86_64, runner) do
        {:ok, selection} -> {:cont, {:ok, Map.put(selections, serial, selection)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp prepare_selected_otp_archives(selections, app_data, elixir_lib, opts) do
    otp_dirs =
      selections
      |> Map.values()
      |> Enum.map(& &1.otp_dir)
      |> Enum.uniq()
      |> Enum.sort()

    multiple? = length(otp_dirs) > 1

    Enum.reduce_while(otp_dirs, {:ok, %{}}, fn otp_dir, {:ok, prepared} ->
      archive_opts =
        opts
        |> Keyword.take([:attempt_id, :tmp_root, :otp_runner])
        |> then(fn archive_opts ->
          if multiple?, do: Keyword.delete(archive_opts, :attempt_id), else: archive_opts
        end)
        |> Keyword.put(:runner, Keyword.get(opts, :otp_runner, &run_system_command/3))

      case prepare_otp_archive(app_data, otp_dir, elixir_lib, archive_opts) do
        {:ok, plan} ->
          selected_abis =
            selections
            |> Map.values()
            |> Enum.filter(&(&1.otp_dir == otp_dir))
            |> Enum.map(& &1.abi)
            |> Enum.uniq()
            |> Enum.sort()

          plan =
            plan
            |> Map.put(:otp_dir, otp_dir)
            |> Map.put(:selected_abis, selected_abis)

          {:cont, {:ok, Map.put(prepared, otp_dir, plan)}}

        {:error, _reason} = error ->
          cleanup_prepared_otp_archives(prepared)
          {:halt, error}
      end
    end)
  end

  defp cleanup_prepared_otp_archives(prepared) do
    Enum.each(prepared, fn
      {_otp_dir, %{archive: %{path: path}}} when is_binary(path) -> File.rm(path)
      _invalid -> :ok
    end)
  end

  defp validate_android_native_otp_plan(prepared, selections, app_data)
       when is_map(prepared) and is_map(selections) do
    expected_dirs =
      selections
      |> Map.values()
      |> Enum.map(& &1.otp_dir)
      |> Enum.uniq()
      |> Enum.sort()

    paths =
      Enum.flat_map(prepared, fn {_otp_dir, plan} ->
        [plan.archive.path, plan.stage_device, plan.app_stage, plan.app_backup]
      end)

    with true <- Enum.sort(Map.keys(prepared)) == expected_dirs,
         true <- Enum.uniq(paths) == paths,
         true <-
           Enum.all?(prepared, fn {otp_dir, plan} ->
             expected_abis =
               selections
               |> Map.values()
               |> Enum.filter(&(&1.otp_dir == otp_dir))
               |> Enum.map(& &1.abi)
               |> Enum.uniq()
               |> Enum.sort()

             validate_android_native_otp_entry(plan, otp_dir, expected_abis, app_data) == :ok
           end) do
      :ok
    else
      _invalid -> {:error, "Authoritative Android OTP archive plan is invalid"}
    end
  end

  defp validate_android_native_otp_plan(_prepared, _selections, _app_data),
    do: {:error, "Authoritative Android OTP archive plan is invalid"}

  defp validate_android_native_otp_entry(plan, otp_dir, expected_abis, app_data)
       when is_map(plan) do
    with true <-
           exact_map_keys?(plan, [
             :activation_lock,
             :app_backup,
             :app_stage,
             :archive,
             :attempt_id,
             :otp_dir,
             :selected_abis,
             :sentinels,
             :stage_device
           ]),
         true <- plan.otp_dir == otp_dir,
         true <- plan.selected_abis == expected_abis and expected_abis != [],
         true <- valid_android_attempt_id?(plan.attempt_id),
         :ok <- validate_android_local_file_identity(plan.archive, @max_android_apk_bytes),
         true <- plan.stage_device == "/data/local/tmp/mob_otp_#{plan.attempt_id}.tar",
         true <- plan.app_stage == "#{app_data}/.mob_otp_stage_#{plan.attempt_id}",
         true <- plan.app_backup == "#{app_data}/.mob_otp_backup_#{plan.attempt_id}",
         true <- plan.activation_lock == "#{app_data}/.mob_otp_activation_lock",
         true <- valid_android_runtime_sentinels?(plan.sentinels) do
      :ok
    else
      _invalid -> {:error, :invalid_native_otp_entry}
    end
  end

  defp validate_android_native_otp_entry(_plan, _otp_dir, _expected_abis, _app_data),
    do: {:error, :invalid_native_otp_entry}

  defp verify_android_prepared_otp_archive(plan, otp_dir, expected_abi) do
    with true <- plan.otp_dir == otp_dir,
         true <- expected_abi in plan.selected_abis,
         :ok <- validate_android_local_file_identity(plan.archive, @max_android_apk_bytes) do
      :ok
    else
      _invalid -> {:error, "Exact Android OTP archive changed; refusing update"}
    end
  end

  defp valid_android_runtime_sentinels?(sentinels)
       when is_list(sentinels) and sentinels != [] and length(sentinels) <= 32 do
    Enum.uniq(sentinels) == sentinels and
      Enum.all?(sentinels, fn sentinel ->
        is_binary(sentinel) and byte_size(sentinel) in 1..1_024 and String.valid?(sentinel) and
          Path.type(sentinel) == :relative and String.starts_with?(sentinel, "otp/") and
          not Enum.member?(Path.split(sentinel), "..") and
          Regex.match?(Regex.compile!("\\A[A-Za-z0-9_./-]+\\z"), sentinel)
      end)
  end

  defp valid_android_runtime_sentinels?(_sentinels), do: false

  defp acquire_android_deploy_lock(serials, bundle_id, runner, opts) do
    lock_opts =
      case Keyword.fetch(opts, :lock_owner) do
        {:ok, owner} -> [owner: owner]
        :error -> []
      end

    case AndroidDeployLock.acquire(
           bundle_id,
           serials,
           android_lock_runner(runner),
           lock_opts
         ) do
      {:ok, lease} ->
        {:ok, lease}

      {:error, %{lease: %{state: :not_acquired}} = failure} ->
        {:error, AndroidDeployLock.message(failure)}

      {:error, %{lease: lease} = failure} ->
        {:error, AndroidDeployLock.message(failure), lease}
    end
  end

  defp transition_android_deploy_lock(lock, expected_phase, next_phase, runner) do
    case AndroidDeployLock.transition(
           lock,
           expected_phase,
           next_phase,
           android_lock_runner(runner)
         ) do
      {:ok, transitioned} ->
        {:ok, transitioned}

      {:error, %{lease: lease} = failure} ->
        {:error, AndroidDeployLock.message(failure), lease}
    end
  end

  defp android_lock_runner(runner) do
    fn args ->
      case invoke_command(runner, "adb", args) do
        {:ok, output, status} -> {output, status}
        {:error, _reason} -> {"", 255}
      end
    end
  end

  @doc false
  @spec release_android_deploy_lock(map(), keyword()) :: :ok | {:error, String.t()}
  def release_android_deploy_lock(lock_info, opts \\ []) do
    runner = Keyword.get(opts, :probe_runner, &run_system_command/2)

    case AndroidDeployLock.release(lock_info, android_lock_runner(runner)) do
      :ok -> :ok
      {:error, failure} -> {:error, AndroidDeployLock.message(failure)}
    end
  end

  defp preflight_installed_android_targets(serials, bundle_id, runner) do
    Enum.reduce_while(serials, :ok, fn serial, :ok ->
      case ensure_android_package_for_otp(runner, serial, bundle_id) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @doc false
  @spec interpret_adb_update(String.t(), integer()) ::
          :updated | {:failed, android_update_failure_reason()}
  def interpret_adb_update(output, exit_code)
      when is_binary(output) and is_integer(exit_code) and
             byte_size(output) <= @max_adb_install_result_bytes do
    if String.valid?(output) do
      case known_adb_failure(output) do
        nil -> interpret_adb_update_status(output, exit_code)
        reason -> {:failed, reason}
      end
    else
      {:failed, :unknown_failure}
    end
  end

  def interpret_adb_update(_output, _exit_code), do: {:failed, :unknown_failure}

  defp android_update_targets(device_id) do
    case resolve_android_update_targets(device_id) do
      {:ok, serials} -> {:ok, serials}
      {:error, reason} -> {:error, android_target_error(device_id, reason)}
    end
  end

  defp resolve_adb_targets(output, nil) do
    with {:ok, states} <- parse_adb_device_states(output) do
      case Enum.find(states, fn {_serial, state} -> state != "device" end) do
        {_serial, "offline"} -> {:error, :offline}
        {_serial, "unauthorized"} -> {:error, :unauthorized}
        {_serial, _state} -> {:error, :unknown_state}
        nil -> ready_android_targets(states)
      end
    end
  end

  defp resolve_adb_targets(output, device_id) do
    with {:ok, states} <- parse_adb_device_states(output) do
      matches =
        Enum.filter(states, fn {serial, _state} -> matching_adb_serial?(serial, device_id) end)

      case matches do
        [{serial, "device"}] -> {:ok, [serial]}
        [{_serial, "offline"}] -> {:error, :offline}
        [{_serial, "unauthorized"}] -> {:error, :unauthorized}
        [{_serial, _state}] -> {:error, :unknown_state}
        [] -> {:error, :target_not_connected}
        _ -> {:error, :ambiguous_target}
      end
    end
  end

  defp ready_android_targets([]), do: {:error, :no_targets}

  defp ready_android_targets(states) do
    {:ok, Enum.map(states, fn {serial, "device"} -> serial end)}
  end

  defp parse_adb_device_states(output)
       when is_binary(output) and byte_size(output) > @max_adb_discovery_bytes,
       do: {:error, :discovery_output_too_large}

  defp parse_adb_device_states(output) when is_binary(output) do
    if String.valid?(output) do
      lines =
        output
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      with {:ok, rows} <- adb_device_rows(lines),
           {:ok, states} <- parse_adb_device_rows(rows),
           :ok <- validate_adb_device_states(states) do
        {:ok, states}
      end
    else
      {:error, :malformed_discovery}
    end
  end

  defp parse_adb_device_states(_output), do: {:error, :malformed_discovery}

  defp adb_device_rows(lines) do
    {_notices, after_notices} = Enum.split_while(lines, &adb_daemon_notice?/1)

    case after_notices do
      ["List of devices attached" | rows] -> {:ok, rows}
      _ -> {:error, :malformed_discovery}
    end
  end

  defp adb_daemon_notice?(line), do: String.starts_with?(line, "* daemon ")

  defp parse_adb_device_rows(rows) do
    result =
      Enum.reduce_while(rows, [], fn row, states ->
        case String.split(row) do
          [serial, state] ->
            if valid_adb_serial?(serial) do
              {:cont, [{serial, state} | states]}
            else
              {:halt, :error}
            end

          _ ->
            {:halt, :error}
        end
      end)

    case result do
      :error -> {:error, :malformed_discovery}
      states -> {:ok, Enum.reverse(states)}
    end
  end

  defp validate_adb_device_states(states) do
    serials = Enum.map(states, &elem(&1, 0))

    cond do
      Enum.uniq(serials) != serials -> {:error, :duplicate_target}
      casefold_duplicates?(serials) -> {:error, :ambiguous_target}
      length(states) > @max_android_update_targets -> {:error, :too_many_targets}
      true -> :ok
    end
  end

  defp validate_android_update_serials(serials) do
    cond do
      Enum.any?(serials, &(not valid_adb_serial?(&1))) -> {:error, :invalid_target}
      Enum.uniq(serials) != serials -> {:error, :duplicate_target}
      casefold_duplicates?(serials) -> {:error, :ambiguous_target}
      true -> :ok
    end
  end

  defp casefold_duplicates?(serials) do
    normalized = Enum.map(serials, &String.downcase/1)
    Enum.uniq(normalized) != normalized
  end

  defp matching_adb_serial?(serial, device_id) do
    serial == device_id or serial == "#{device_id}:5555" or strip_port(serial) == device_id
  end

  defp install_android_update(apk, serial, runner) do
    if valid_adb_serial?(serial) do
      IO.puts("  Updating APK on #{serial} (preserving app data)...")

      result =
        case invoke_command(runner, "adb", ["-s", serial, "install", "-r", apk]) do
          {:ok, output, exit_code} -> interpret_adb_update(output, exit_code)
          {:error, _reason} -> {:failed, :unknown_failure}
        end

      case result do
        :updated ->
          {:ok, serial}

        {:failed, reason} ->
          IO.puts(
            "  #{IO.ANSI.yellow()}⚠  #{serial}: APK update failed " <>
              "(#{android_update_reason(reason)}); app data preserved#{IO.ANSI.reset()}"
          )

          {:error, %{serial: serial, reason: reason}}
      end
    else
      {:error, %{serial: bounded_serial_label(serial), reason: :invalid_target}}
    end
  end

  defp interpret_adb_update_status(output, 0) do
    lines =
      output
      |> String.split("\n", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    allowed = ["Performing Streamed Install", "Performing Incremental Install"]

    case Enum.reverse(lines) do
      ["Success" | preceding] ->
        if Enum.all?(preceding, &(&1 in allowed)),
          do: :updated,
          else: {:failed, :suspicious_success}

      _ ->
        {:failed, :suspicious_success}
    end
  end

  defp interpret_adb_update_status(_output, _exit_code), do: {:failed, :unknown_failure}

  defp known_adb_failure(output) do
    lower = String.downcase(output)

    cond do
      String.contains?(output, "INSTALL_FAILED_INSUFFICIENT_STORAGE") ->
        :insufficient_storage

      String.contains?(output, "INSTALL_FAILED_UPDATE_INCOMPATIBLE") or
        String.contains?(output, "INSTALL_PARSE_FAILED_INCONSISTENT_CERTIFICATES") or
          String.contains?(output, "INSTALL_FAILED_SHARED_USER_INCOMPATIBLE") ->
        :signature_mismatch

      String.contains?(output, "INSTALL_FAILED_VERSION_DOWNGRADE") ->
        :version_downgrade

      String.contains?(lower, "unauthorized") ->
        :unauthorized

      String.contains?(lower, "device offline") or String.contains?(lower, "offline") ->
        :offline

      String.contains?(lower, "no devices/emulators found") or
          String.contains?(lower, "device not found") ->
        :unavailable

      String.contains?(output, "INSTALL_FAILED_") or
          String.contains?(output, "INSTALL_PARSE_FAILED_") ->
        :install_rejected

      true ->
        nil
    end
  end

  defp definite_android_install_rejection?(reason),
    do:
      reason in [
        :insufficient_storage,
        :signature_mismatch,
        :version_downgrade,
        :install_rejected
      ]

  defp android_target_error(nil, :no_targets), do: "No connected Android update targets found"

  defp android_target_error(nil, reason) do
    "Connected Android update targets are #{android_update_reason(reason)}"
  end

  defp android_target_error(device_id, reason) do
    "Android update target #{bounded_serial_label(device_id)} is " <>
      android_update_reason(reason)
  end

  defp android_update_request_error(:no_explicit_targets),
    do: "Android APK update requires at least one explicit target"

  defp android_update_request_error(:too_many_targets),
    do: "Android APK update target count exceeds the safety limit"

  defp android_update_request_error(:authoritative_transaction_required),
    do: "Android APK updates require the authoritative payload transaction"

  defp android_update_request_error(_reason), do: "Android APK update request is invalid"

  defp android_update_reason(:device_discovery_failed), do: "not discoverable"
  defp android_update_reason(:discovery_output_too_large), do: "too large to validate safely"
  defp android_update_reason(:malformed_discovery), do: "malformed"
  defp android_update_reason(:duplicate_target), do: "duplicated"
  defp android_update_reason(:too_many_targets), do: "over the target safety limit"
  defp android_update_reason(:target_not_connected), do: "not connected"
  defp android_update_reason(:ambiguous_target), do: "ambiguous"
  defp android_update_reason(:unknown_state), do: "in an unknown adb state"
  defp android_update_reason(:insufficient_storage), do: "out of storage"
  defp android_update_reason(:signature_mismatch), do: "signed by a different key"
  defp android_update_reason(:version_downgrade), do: "a version downgrade"
  defp android_update_reason(:offline), do: "offline"
  defp android_update_reason(:unauthorized), do: "unauthorized"
  defp android_update_reason(:unavailable), do: "unavailable"
  defp android_update_reason(:install_rejected), do: "rejected by Android"
  defp android_update_reason(:suspicious_success), do: "an unverified adb success"
  defp android_update_reason(:unknown_failure), do: "an unknown adb failure"
  defp android_update_reason(:invalid_target), do: "an invalid target"

  defp bounded_serial_label(serial) when is_binary(serial) do
    if valid_adb_serial?(serial), do: serial, else: "<invalid>"
  end

  defp bounded_serial_label(_serial), do: "<invalid>"

  defp valid_adb_serial?(serial) when is_binary(serial) do
    byte_size(serial) in 1..@max_adb_serial_bytes and not String.starts_with?(serial, "-") and
      serial
      |> :binary.bin_to_list()
      |> Enum.all?(fn byte ->
        byte in ?0..?9 or byte in ?A..?Z or byte in ?a..?z or byte in ~c".:-_"
      end)
  end

  defp valid_adb_serial?(_serial), do: false

  defp invoke_command(runner, executable, args) do
    case runner.(executable, args) do
      {output, exit_code} when is_binary(output) and is_integer(exit_code) ->
        {:ok, output, exit_code}

      _ ->
        {:error, :invalid_command_result}
    end
  end

  defp run_system_command(executable, args) do
    case System.find_executable(executable) do
      nil -> {"", 127}
      path -> System.cmd(path, args, stderr_to_stdout: true)
    end
  end

  defp run_system_command(executable, args, opts) do
    case System.find_executable(executable) do
      nil -> {"", 127}
      path -> System.cmd(path, args, Keyword.put_new(opts, :stderr_to_stdout, true))
    end
  end

  @doc false
  @deprecated "OTP mutation is only supported by install_and_deliver_android_runtime/8"
  @spec deliver_android_otp_release(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          keyword()
        ) :: :ok | {:error, String.t()}
  def deliver_android_otp_release(
        _serial,
        _bundle_id,
        _elixir_lib,
        _otp_arm64,
        _otp_arm32,
        _otp_x86_64,
        _opts \\ []
      ),
      do: {:error, "Android OTP delivery requires the authoritative payload transaction"}

  defp preflight_android_otp_candidates(otp_arm64, otp_arm32, otp_x86_64, elixir_lib) do
    [otp_arm64, otp_arm32, otp_x86_64]
    |> Enum.reduce_while(:ok, fn otp_dir, :ok ->
      case android_runtime_sentinels(otp_dir, elixir_lib) do
        {:ok, _sentinels} -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp device_otp_selection(serial, otp_arm64, otp_arm32, otp_x86_64, runner) do
    probe =
      invoke_command(runner, "adb", [
        "-s",
        serial,
        "shell",
        "getprop",
        "ro.product.cpu.abi"
      ])

    with {:ok, abi} <- android_abi_from_probe(probe),
         {:ok, otp_dir} <-
           android_otp_dir_from_abi_probe(probe, otp_arm64, otp_arm32, otp_x86_64) do
      {:ok, %{abi: abi, otp_dir: otp_dir}}
    end
  end

  @doc false
  @spec android_otp_dir_from_abi_probe(
          term(),
          String.t(),
          String.t(),
          String.t()
        ) :: {:ok, String.t()} | {:error, String.t()}
  def android_otp_dir_from_abi_probe({:ok, output, 0}, otp_arm64, otp_arm32, otp_x86_64)
      when is_binary(output) and byte_size(output) <= 128 do
    with {:ok, abi} <- android_abi_from_probe({:ok, output, 0}) do
      case abi do
        "arm64-v8a" -> {:ok, otp_arm64}
        "armeabi-v7a" -> {:ok, otp_arm32}
        "x86_64" -> {:ok, otp_x86_64}
      end
    end
  end

  def android_otp_dir_from_abi_probe({:ok, _output, status}, _arm64, _arm32, _x86_64)
      when is_integer(status),
      do: {:error, "Android ABI probe failed; refusing OTP delivery"}

  def android_otp_dir_from_abi_probe(_probe, _arm64, _arm32, _x86_64),
    do: {:error, "Invalid Android ABI probe result; refusing OTP delivery"}

  defp android_abi_from_probe({:ok, output, 0})
       when is_binary(output) and byte_size(output) <= 128 do
    if String.valid?(output) do
      case String.trim(output) do
        abi when abi in ["arm64-v8a", "armeabi-v7a", "x86_64"] -> {:ok, abi}
        _unsupported -> {:error, "Unsupported or missing Android ABI; refusing OTP delivery"}
      end
    else
      {:error, "Invalid Android ABI probe output; refusing OTP delivery"}
    end
  end

  defp android_abi_from_probe({:ok, _output, status}) when is_integer(status),
    do: {:error, "Android ABI probe failed; refusing OTP delivery"}

  defp android_abi_from_probe(_probe),
    do: {:error, "Invalid Android ABI probe result; refusing OTP delivery"}

  @doc "Returns the OTP directory for the given Android ABI string."
  @spec otp_dir_for_abi(String.t(), String.t(), String.t()) :: String.t()
  def otp_dir_for_abi("armeabi-v7a", _arm64, arm32), do: arm32
  def otp_dir_for_abi(_abi, arm64, _arm32), do: arm64

  @doc "Returns the OTP directory for the given Android ABI string."
  @spec otp_dir_for_abi(String.t(), String.t(), String.t(), String.t()) :: String.t()
  def otp_dir_for_abi("armeabi-v7a", _arm64, arm32, _x86_64), do: arm32
  def otp_dir_for_abi("x86_64", _arm64, _arm32, x86_64), do: x86_64
  def otp_dir_for_abi(_abi, arm64, _arm32, _x86_64), do: arm64

  defp ensure_android_package_for_otp(runner, serial, bundle_id) do
    case invoke_command(runner, "adb", [
           "-s",
           serial,
           "shell",
           "pm",
           "list",
           "packages",
           bundle_id
         ]) do
      {:ok, pm_out, 0} ->
        if android_package_listed?(pm_out, bundle_id) do
          :ok
        else
          {:error, "Updated Android app is not installed; refusing OTP delivery"}
        end

      {:ok, output, _status} ->
        {:error, android_command_error("verify installed Android app", output)}

      {:error, _reason} ->
        {:error, "verify installed Android app failed: invalid command result"}
    end
  end

  @doc false
  @spec android_package_listed?(term(), String.t()) :: boolean()
  def android_package_listed?(pm_out, bundle_id)
      when is_binary(pm_out) and is_binary(bundle_id) do
    valid_output? =
      byte_size(pm_out) <= @max_adb_discovery_bytes and String.valid?(pm_out)

    valid_output? and
      Enum.any?(String.split(pm_out, "\n"), &(String.trim(&1) == "package:#{bundle_id}"))
  end

  def android_package_listed?(_pm_out, _bundle_id), do: false

  @doc false
  @deprecated "OTP mutation is only supported by install_and_deliver_android_runtime/8"
  @spec push_otp_runas(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          keyword()
        ) :: :ok | {:error, String.t()}
  def push_otp_runas(
        _serial,
        _bundle_id,
        _app_data,
        _otp_dir,
        _elixir_lib,
        _opts \\ []
      ),
      do: {:error, "Android OTP delivery requires the authoritative payload transaction"}

  defp prepare_otp_archive(app_data, otp_dir, elixir_lib, opts) do
    runner = Keyword.get(opts, :runner, &run_system_command/3)
    tmp_root = Keyword.get(opts, :tmp_root, System.tmp_dir!())

    with {:ok, attempt_id} <- android_attempt_id(opts),
         {:ok, sentinels} <- android_runtime_sentinels(otp_dir, elixir_lib) do
      stage_local = Path.join(tmp_root, "mob_otp_#{attempt_id}.tar")
      tmp = Path.join(tmp_root, "mob_otp_stage_#{attempt_id}")
      otp_tmp = Path.join(tmp, "otp")

      local_result =
        try do
          File.rm(stage_local)
          File.rm_rf!(tmp)
          File.mkdir_p!(otp_tmp)

          with :ok <-
                 checked_command(runner, "stage OTP runtime", "cp", [
                   "-r",
                   "#{otp_dir}/.",
                   otp_tmp
                 ]),
               :ok <- prepare_elixir_stage(otp_tmp),
               :ok <-
                 checked_command(runner, "stage Elixir runtime", "cp", [
                   "-r",
                   "#{elixir_lib}/elixir/ebin/.",
                   Path.join(otp_tmp, "lib/elixir/ebin")
                 ]),
               :ok <-
                 checked_command(runner, "stage Logger runtime", "cp", [
                   "-r",
                   "#{elixir_lib}/logger/ebin/.",
                   Path.join(otp_tmp, "lib/logger/ebin")
                 ]),
               :ok <-
                 checked_command(runner, "stage EEx runtime", "cp", [
                   "-r",
                   "#{elixir_lib}/eex/ebin/.",
                   Path.join(otp_tmp, "lib/eex/ebin")
                 ]),
               :ok <-
                 checked_command(
                   runner,
                   "create OTP archive",
                   "tar",
                   ["cf", stage_local, "-C", tmp, "otp"],
                   env: [{"COPYFILE_DISABLE", "1"}]
                 ),
               {:ok, archive} <- freeze_android_otp_archive(stage_local) do
            {:ok,
             %{
               archive: archive,
               attempt_id: attempt_id,
               stage_device: "/data/local/tmp/mob_otp_#{attempt_id}.tar",
               app_stage: "#{app_data}/.mob_otp_stage_#{attempt_id}",
               app_backup: "#{app_data}/.mob_otp_backup_#{attempt_id}",
               activation_lock: "#{app_data}/.mob_otp_activation_lock",
               sentinels: sentinels
             }}
          end
        after
          File.rm_rf(tmp)
        end

      case local_result do
        {:ok, _prepared} = ok ->
          ok

        {:error, _reason} = error ->
          File.rm(stage_local)
          error
      end
    end
  end

  defp freeze_android_otp_archive(path) do
    with :ok <- File.chmod(path, 0o400),
         {:ok, %{type: :regular, size: size, mode: mode}}
         when size > 0 and size <= @max_android_apk_bytes and Bitwise.band(mode, 0o222) == 0 <-
           File.stat(path),
         {:ok, sha256} <- file_sha256(path) do
      {:ok,
       %{
         path: path,
         size: size,
         sha256: Base.encode16(sha256, case: :lower)
       }}
    else
      _failure -> {:error, "Could not freeze exact Android OTP archive"}
    end
  end

  defp deploy_prepared_otp(
         runner,
         owner_runner,
         lock,
         serial,
         bundle_id,
         app_data,
         prepared
       ) do
    push_staged_otp(
      runner,
      owner_runner,
      lock,
      serial,
      bundle_id,
      app_data,
      prepared.archive.path,
      prepared.stage_device,
      prepared.app_stage,
      prepared.app_backup,
      prepared.activation_lock,
      prepared.sentinels
    )
  end

  defp push_staged_otp(
         runner,
         owner_runner,
         lock,
         serial,
         bundle_id,
         app_data,
         stage_local,
         stage_device,
         app_stage,
         app_backup,
         activation_lock,
         sentinels
       ) do
    push_result =
      checked_locked_android_command(
        lock,
        owner_runner,
        runner,
        serial,
        "push OTP archive",
        ["push", stage_local, stage_device]
      )

    case push_result do
      :ok ->
        deploy_result =
          with :ok <-
                 checked_locked_android_command(
                   lock,
                   owner_runner,
                   runner,
                   serial,
                   "prepare app-private OTP staging directory",
                   [
                     "shell",
                     "run-as #{bundle_id} sh -c 'test ! -e #{app_backup} && rm -rf #{app_stage} && mkdir -p #{app_stage}'"
                   ]
                 ),
               :ok <-
                 checked_locked_android_command(
                   lock,
                   owner_runner,
                   runner,
                   serial,
                   "extract OTP archive",
                   [
                     "shell",
                     "run-as #{bundle_id} tar xof #{stage_device} -C #{app_stage}"
                   ]
                 ),
               :ok <-
                 checked_command(runner, "verify staged OTP runtime", "adb", [
                   "-s",
                   serial,
                   "shell",
                   runtime_verification_command(bundle_id, app_stage, sentinels)
                 ]),
               :ok <-
                 checked_locked_android_command(
                   lock,
                   owner_runner,
                   runner,
                   serial,
                   "activate OTP runtime",
                   [
                     "shell",
                     otp_activation_command(
                       bundle_id,
                       app_data,
                       app_stage,
                       app_backup,
                       activation_lock,
                       sentinels
                     )
                   ]
                 ),
               :ok <-
                 checked_command(runner, "verify active OTP runtime", "adb", [
                   "-s",
                   serial,
                   "shell",
                   runtime_verification_command(bundle_id, app_data, sentinels)
                 ]),
               :ok <-
                 checked_locked_android_command(
                   lock,
                   owner_runner,
                   runner,
                   serial,
                   "release OTP activation lock",
                   ["shell", activation_lock_release_command(bundle_id, activation_lock)]
                 ),
               :ok <-
                 checked_locked_android_command(
                   lock,
                   owner_runner,
                   runner,
                   serial,
                   "clean OTP activation backup",
                   ["shell", activation_backup_cleanup_command(bundle_id, app_backup)]
                 ) do
            :ok
          end

        case deploy_result do
          :ok ->
            merge_deploy_and_cleanup_results(
              :ok,
              cleanup_android_otp_stage(
                runner,
                owner_runner,
                lock,
                serial,
                bundle_id,
                stage_device,
                app_stage
              )
            )

          {:error, _reason} = error ->
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp prepare_elixir_stage(otp_tmp) do
    for app <- ["elixir", "logger", "eex"] do
      File.mkdir_p!(Path.join(otp_tmp, "lib/#{app}/ebin"))
    end

    :ok
  end

  defp android_runtime_sentinels(otp_dir, elixir_lib)
       when is_binary(otp_dir) and is_binary(elixir_lib) do
    erts_bin_dirs = Path.wildcard(Path.join(otp_dir, "erts-*/bin"))

    kernel_sentinel = Path.join(elixir_lib, "elixir/ebin/Elixir.Kernel.beam")

    with [erts_bin] <- erts_bin_dirs,
         :ok <- validate_android_erts_helpers(erts_bin),
         true <- File.regular?(kernel_sentinel),
         {:ok, logger_sentinel} <- runtime_app_beam_sentinel(elixir_lib, "logger"),
         {:ok, eex_sentinel} <- runtime_app_beam_sentinel(elixir_lib, "eex") do
      relative_erts = Path.relative_to(Path.join(erts_bin, "erl_child_setup"), otp_dir)

      if Regex.match?(Regex.compile!(@android_erts_sentinel_pattern), relative_erts) do
        relative_erts_bin = Path.dirname(relative_erts)

        {:ok,
         [
           Path.join("otp", relative_erts),
           Path.join(["otp", relative_erts_bin, "inet_gethost"]),
           Path.join(["otp", relative_erts_bin, "epmd"]),
           "otp/lib/elixir/ebin/Elixir.Kernel.beam",
           Path.join("otp/lib/logger/ebin", logger_sentinel),
           Path.join("otp/lib/eex/ebin", eex_sentinel)
         ]}
      else
        {:error, "Unsafe Android runtime sentinel; refusing OTP delivery"}
      end
    else
      _ ->
        {:error, "Android runtime sentinel missing or ambiguous; refusing OTP delivery"}
    end
  end

  defp android_runtime_sentinels(_otp_dir, _elixir_lib),
    do: {:error, "Android runtime source is invalid; refusing OTP delivery"}

  defp runtime_app_beam_sentinel(elixir_lib, app) do
    sentinels =
      elixir_lib
      |> Path.join("#{app}/ebin/*.beam")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(&Path.basename/1)
      |> Enum.filter(fn basename ->
        byte_size(basename) <= 255 and String.valid?(basename) and
          Regex.match?(Regex.compile!("\\A[A-Za-z0-9_.-]+\\.beam\\z"), basename)
      end)
      |> Enum.sort()

    case sentinels do
      [sentinel | _] -> {:ok, sentinel}
      [] -> {:error, :missing_runtime_app_beam}
    end
  end

  defp runtime_verification_command(bundle_id, app_data, sentinels) do
    checks = Enum.map_join(sentinels, " && ", &"test -r #{Path.join(app_data, &1)}")
    "run-as #{bundle_id} sh -c '#{checks}'"
  end

  defp otp_activation_command(
         bundle_id,
         app_data,
         app_stage,
         app_backup,
         activation_lock,
         sentinels
       ) do
    live_otp = Path.join(app_data, "otp")
    staged_otp = Path.join(app_stage, "otp")
    checks = Enum.map_join(sentinels, " && ", &"test -r #{Path.join(app_data, &1)}")

    "run-as #{bundle_id} sh -c 'set -e; mkdir #{activation_lock}; had_live=0; " <>
      "if [ -e #{live_otp} ]; then mv #{live_otp} #{app_backup}; had_live=1; fi; " <>
      "if mv #{staged_otp} #{live_otp} && #{checks}; then " <>
      ":; else rm -rf #{live_otp}; " <>
      "if [ \"$had_live\" -eq 1 ]; then mv #{app_backup} #{live_otp}; fi; exit 1; fi'"
  end

  defp activation_lock_release_command(bundle_id, activation_lock),
    do: "run-as #{bundle_id} rmdir #{activation_lock}"

  defp activation_backup_cleanup_command(bundle_id, app_backup),
    do: "run-as #{bundle_id} rm -rf #{app_backup}"

  defp cleanup_android_otp_stage(
         runner,
         owner_runner,
         lock,
         serial,
         bundle_id,
         stage_device,
         app_stage
       ) do
    cleanup_results = [
      checked_locked_android_command(
        lock,
        owner_runner,
        runner,
        serial,
        "clean app-private OTP staging directory",
        ["shell", "run-as #{bundle_id} rm -rf #{app_stage}"]
      ),
      cleanup_remote_otp_archive(runner, owner_runner, lock, serial, stage_device)
    ]

    Enum.find(cleanup_results, :ok, &match?({:error, _reason}, &1))
  end

  defp cleanup_remote_otp_archive(runner, owner_runner, lock, serial, stage_device) do
    checked_locked_android_command(
      lock,
      owner_runner,
      runner,
      serial,
      "clean remote OTP archive",
      ["shell", "rm -f #{stage_device}"]
    )
  end

  defp checked_locked_android_command(
         lock,
         owner_runner,
         runner,
         serial,
         operation,
         args
       ) do
    with :ok <- verify_android_deploy_lock_set(lock, owner_runner) do
      checked_command(runner, operation, "adb", ["-s", serial | args])
    end
  end

  defp merge_deploy_and_cleanup_results(:ok, :ok), do: :ok

  defp merge_deploy_and_cleanup_results(:ok, {:error, _reason} = cleanup_error),
    do: cleanup_error

  defp android_attempt_id(opts) do
    attempt_id =
      case Keyword.get(opts, :attempt_id) do
        nil -> :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
        attempt_id -> attempt_id
      end

    if is_binary(attempt_id) and String.valid?(attempt_id) and
         Regex.match?(Regex.compile!(@android_attempt_id_pattern), attempt_id) do
      {:ok, attempt_id}
    else
      {:error, "Invalid Android deploy attempt id; refusing OTP delivery"}
    end
  end

  defp validate_android_bundle_id(bundle_id) when is_binary(bundle_id) do
    if byte_size(bundle_id) <= 255 and String.valid?(bundle_id) and
         Regex.match?(
           Regex.compile!("\\A[A-Za-z][A-Za-z0-9_]*(?:\\.[A-Za-z0-9_]+)+\\z"),
           bundle_id
         ) do
      :ok
    else
      {:error, "Invalid Android bundle id; refusing OTP delivery"}
    end
  end

  defp validate_android_bundle_id(_bundle_id),
    do: {:error, "Invalid Android bundle id; refusing OTP delivery"}

  defp validate_android_app_data(app_data, bundle_id) do
    if app_data == "/data/data/#{bundle_id}/files" do
      :ok
    else
      {:error, "Invalid Android app-data path; refusing OTP delivery"}
    end
  end

  defp checked_command(runner, operation, executable, args, opts \\ []) do
    case runner.(executable, args, Keyword.put_new(opts, :stderr_to_stdout, true)) do
      {output, 0}
      when is_binary(output) and byte_size(output) <= @max_adb_discovery_bytes ->
        if String.valid?(output),
          do: :ok,
          else: {:error, "#{operation} failed: invalid command output"}

      {_output, 0} ->
        {:error, "#{operation} failed: invalid command output"}

      {output, _status} ->
        {:error, android_command_error(operation, output)}

      _other ->
        {:error, "#{operation} failed: invalid command result"}
    end
  end

  defp android_command_error(operation, _output), do: "#{operation} failed"

  # Filters a list of adb serials by `--device <id>`. The id is matched against
  # the serial directly, against an `IP:port` form (auto-strip `:5555`), and
  # against a bare IP for WiFi-adb devices. Returns all serials when device_id
  # is nil. Returns empty + warning if device_id matches no connected serial.
  @doc false
  @spec filter_serials([String.t()], String.t() | nil) :: [String.t()]
  def filter_serials(serials, nil), do: serials

  def filter_serials(serials, id) when is_binary(id) do
    matches =
      Enum.filter(serials, fn s ->
        s == id or s == "#{id}:5555" or strip_port(s) == id
      end)

    if matches == [] do
      IO.puts(
        "  #{IO.ANSI.yellow()}⚠  --device #{id} matched no connected adb device — skipping#{IO.ANSI.reset()}"
      )
    end

    matches
  end

  defp strip_port(s) do
    case String.split(s, ":", parts: 2) do
      [host, _port] -> host
      _ -> s
    end
  end

  # ── iOS ──────────────────────────────────────────────────────────────────────

  defp build_ios(cfg, device_id) do
    with :ok <- check_path(cfg[:mob_dir], "mob_dir"),
         :ok <- check_path(cfg[:elixir_lib], "elixir_lib"),
         {:ok, otp_root} <- MobDev.OtpDownloader.ensure_ios_sim(),
         {:ok, python_bundle} <- maybe_ensure_python_bundle(),
         {:ok, mlx_dir} <- maybe_ensure_mlx_dir(:ios_sim),
         {:ok, nxeigen_archive} <- maybe_build_nxeigen(:ios_sim),
         {:ok, tflite_build} <- maybe_build_tflite(:ios_sim) do
      IO.puts("  Building iOS simulator app...")

      mob_dir = Path.expand(cfg[:mob_dir])
      elixir_lib = Path.expand(cfg[:elixir_lib])
      app_module = Mix.Project.config() |> Keyword.fetch!(:app) |> Atom.to_string()
      display_name = ios_display_name()
      erts_vsn = detect_erts_vsn(otp_root)
      project_swift_sources = project_swift_sources_arg(cfg)

      with {:ok, sdkroot} <- xcrun_sdk_path("iphonesimulator"),
           :ok <- compile_elixir_for_ios(),
           :ok <- copy_app_beams(otp_root, app_module),
           :ok <- install_exqlite_otp_lib(otp_root),
           :ok <- cross_compile_exqlite_nif_sim(otp_root, erts_vsn, sdkroot),
           :ok <- install_emlx_otp_lib(otp_root),
           :ok <- install_nx_eigen_otp_lib(otp_root),
           :ok <- maybe_setup_pythonx_sim(otp_root, erts_vsn, sdkroot, python_bundle, app_module),
           :ok <- maybe_install_crypto_shim(otp_root, app_module),
           :ok <- maybe_copy_ssl_beams(otp_root, app_module),
           :ok <- maybe_build_phoenix_assets(otp_root, app_module),
           :ok <- copy_priv_repo_assets(otp_root, app_module),
           :ok <- copy_elixir_stdlib_to_otp(elixir_lib, otp_root),
           :ok <- copy_eex_stdlib_to_app(elixir_lib, otp_root, app_module),
           :ok <- sync_otp_runtime_sim(otp_root),
           :ok <- copy_mob_logos_sim(mob_dir, otp_root),
           :ok <- spot_check_app_beams(otp_root, app_module, display_name),
           {:ok, build_dir} <- create_native_build_dir("ios_sim"),
           :ok <- generate_enif_keepalive(otp_root, erts_vsn, build_dir),
           :ok <-
             zig_build_binary_ios_sim(
               mob_dir,
               otp_root,
               erts_vsn,
               sdkroot,
               build_dir,
               display_name,
               project_swift_sources,
               mlx_dir,
               nxeigen_archive,
               tflite_build
             ),
           {:ok, sim_id} <- pick_ios_sim(device_id),
           binary_path = "ios/zig-out/#{display_name}",
           :ok <- check_path(binary_path, "iOS binary"),
           {:ok, app_path} <- bundle_ios_app(binary_path, display_name),
           :ok <-
             copy_tflite_frameworks_ios(
               tflite_build,
               "ios-arm64_x86_64-simulator",
               Path.join(app_path, "Frameworks")
             ),
           :ok <- install_ios_sim(sim_id, app_path) do
        {:ok, "iOS"}
      else
        {:error, reason} -> {:error, "iOS", reason}
      end
    else
      {:error, reason} -> {:error, "iOS", reason}
    end
  end

  # Phase 2 iter 13b: iOS sim build pipeline ported out of build.sh.
  # Each helper mirrors a section of the prior shell script.

  defp xcrun_sdk_path(sdk) do
    case System.cmd("xcrun", ["-sdk", sdk, "--show-sdk-path"], stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      {_, _} -> {:error, "xcrun -sdk #{sdk} --show-sdk-path failed — Xcode CLT installed?"}
    end
  end

  defp compile_elixir_for_ios do
    # Tells `mix compile` we're building for iOS so any `unless
    # System.get_env("MOB_TARGET") == "ios" do …` compile-time gates short-circuit.
    System.put_env("MOB_TARGET", "ios")
    Mix.Task.run("compile")
    :ok
  end

  defp copy_app_beams(otp_root, app_module) do
    beams_dir = Path.join(otp_root, app_module)
    File.mkdir_p!(beams_dir)
    chmod_writable(beams_dir)

    # Glob every compiled dep's ebin dir — covers vanilla (mob + ecto +
    # ecto_sqlite3 + decimal + telemetry + jason + nimble_parsec) AND
    # LiveView (Phoenix + Plug + Bandit + thousand_island + websock + etc.)
    # without having to maintain a hardcoded dep list.
    Path.wildcard("_build/dev/lib/*/ebin/*")
    |> Enum.each(fn src ->
      File.cp!(src, Path.join(beams_dir, Path.basename(src)))
    end)

    :ok
  end

  defp liveview_project? do
    # Treat as LV iff the project has its own Phoenix asset pipeline
    # (`assets/` at project root with package.json or tailwind config).
    # Just having phoenix_live_view as a transitive dep (via mob) doesn't
    # qualify — vanilla mob apps pull it in but have no `assets/` dir and
    # no `mix assets.build` task. Without this guard, `Mix.Task.run("assets.build")`
    # raises on vanilla projects.
    File.exists?("assets/tailwind.config.js") or
      File.exists?("assets/package.json") or
      File.exists?("assets/css/app.css")
  end

  defp chmod_writable(dir) do
    _ = System.cmd("chmod", ["-R", "u+w", dir], stderr_to_stdout: true)
    :ok
  end

  # Stages nx_eigen + fine into the on-device OTP lib structure for the
  # same reason as install_emlx_otp_lib/1 — without an emlx-VSN/-style
  # dir, `:code.priv_dir(:nx_eigen)` returns `{:error, :bad_name}` and
  # NxEigen.NIF.load_nif/0 crashes on Path.join. Staging an empty priv/
  # gives it a valid path; the static-NIF table then resolves the
  # `libnx_eigen` lookup by basename. Also stages `:fine` (NxEigen's
  # binding helper dep) so any code that consults `:code.priv_dir(:fine)`
  # doesn't blow up.
  @doc false
  @spec install_nx_eigen_otp_lib(String.t(), Path.t()) :: :ok
  def install_nx_eigen_otp_lib(otp_root, project_root \\ File.cwd!()) do
    Enum.each([:nx_eigen, :fine], fn app ->
      stage_empty_priv_otp_lib(otp_root, Atom.to_string(app), project_root)
    end)

    :ok
  end

  @doc false
  @spec stage_empty_priv_otp_lib(String.t(), String.t(), Path.t()) :: :ok
  def stage_empty_priv_otp_lib(otp_root, app, project_root \\ File.cwd!()) do
    # `project_root` defaults to the current working directory, which is what
    # the production caller (mix mob.deploy --native) wants. Tests can pass
    # an explicit path so they don't have to wrap calls in File.cd!/2 — that
    # changes process-wide cwd and races other async tests during parallel
    # compilation (Kernel.ParallelCompiler.require_file picks up wrong paths).
    ebin = Path.join([project_root, "_build", "dev", "lib", app, "ebin"])

    if File.dir?(ebin) do
      vsn = detect_dep_version(app) || read_app_vsn(Path.join(ebin, "#{app}.app")) || "0.0.0"
      IO.puts("  === Installing #{app} as OTP library (priv/ empty — NIF static-linked)")
      lib_dir = Path.join([otp_root, "lib", "#{app}-#{vsn}"])
      File.rm_rf!(Path.join(otp_root, "lib/#{app}-"))
      File.mkdir_p!(Path.join(lib_dir, "ebin"))
      File.mkdir_p!(Path.join(lib_dir, "priv"))

      Path.wildcard("#{ebin}/*.beam")
      |> Enum.each(&File.cp!(&1, Path.join([lib_dir, "ebin", Path.basename(&1)])))

      if File.exists?(Path.join(ebin, "#{app}.app")) do
        File.cp!(Path.join(ebin, "#{app}.app"), Path.join([lib_dir, "ebin", "#{app}.app"]))
      end
    end

    :ok
  end

  # Stages emlx into the on-device OTP lib structure (emlx-VSN/ebin + priv/)
  # when :emlx is a project dep. Without this, `:code.priv_dir(:emlx)` returns
  # `{:error, :bad_name}` and EMLX.NIF.load_nifs/0 can't compute its path arg
  # — so the static-NIF table lookup never gets a chance to fire.
  #
  # The priv/ dir is intentionally empty: libemlx.a is statically linked into
  # the main binary (not shipped as a .so), so EMLX.NIF.load_nifs's call to
  # `:erlang.load_nif("priv/libemlx", 0)` resolves via the static table even
  # though no .so exists at that path.
  defp install_emlx_otp_lib(otp_root) do
    ebin = Path.join(["_build", "dev", "lib", "emlx", "ebin"])

    if not File.dir?(ebin) do
      :ok
    else
      vsn = detect_dep_version("emlx") || read_app_vsn(Path.join(ebin, "emlx.app")) || "0.0.0"
      IO.puts("  === Installing emlx as OTP library (priv/ empty — NIF is statically linked)")
      lib_dir = Path.join([otp_root, "lib", "emlx-#{vsn}"])
      File.rm_rf!(Path.join(otp_root, "lib/emlx-"))
      File.mkdir_p!(Path.join(lib_dir, "ebin"))
      File.mkdir_p!(Path.join(lib_dir, "priv"))

      Path.wildcard("#{ebin}/*.beam")
      |> Enum.each(&File.cp!(&1, Path.join([lib_dir, "ebin", Path.basename(&1)])))

      if File.exists?(Path.join(ebin, "emlx.app")) do
        File.cp!(Path.join(ebin, "emlx.app"), Path.join([lib_dir, "ebin", "emlx.app"]))
      end

      :ok
    end
  end

  # Reads the `vsn` from an `<app>.app` Erlang term file. Used as a fallback
  # when `detect_dep_version/1` (which reads mix.lock) misses.
  defp read_app_vsn(app_file) do
    with true <- File.exists?(app_file),
         {:ok, content} <- File.read(app_file),
         [match] <- Regex.run(~r/\{vsn,\s*"([^"]+)"\}/, content, capture: :all_but_first) do
      match
    else
      _ -> nil
    end
  end

  defp install_exqlite_otp_lib(otp_root) do
    ebin = Path.join(["_build", "dev", "lib", "exqlite", "ebin"])
    vsn = detect_dep_version("exqlite")

    case install_exqlite_decision(vsn, ebin) do
      :noop ->
        :ok

      :stale ->
        IO.puts(
          "  [exqlite] stale mix.lock entry — not compiled in _build/dev/lib/exqlite, skipping"
        )

        :ok

      {:install, vsn} ->
        IO.puts("  === Installing exqlite as OTP library")
        lib_dir = Path.join([otp_root, "lib", "exqlite-#{vsn}"])
        # Remove any previous broken empty-version dir from older builds.
        File.rm_rf!(Path.join(otp_root, "lib/exqlite-"))
        File.mkdir_p!(Path.join(lib_dir, "ebin"))
        File.mkdir_p!(Path.join(lib_dir, "priv"))

        Path.wildcard("#{ebin}/*.beam")
        |> Enum.each(&File.cp!(&1, Path.join([lib_dir, "ebin", Path.basename(&1)])))

        File.cp!(Path.join(ebin, "exqlite.app"), Path.join([lib_dir, "ebin", "exqlite.app"]))
        :ok
    end
  end

  @doc """
  Decides what to do for the exqlite install step.

    * `:noop` — no exqlite lock entry; project doesn't use it.
    * `:stale` — lock entry exists but the dep isn't compiled in
      `_build/dev/lib/exqlite/`. Common cause: `ecto_sqlite3` was once
      a dep, was removed, and the transitive `exqlite` lock entry
      stayed behind (mix.lock isn't auto-pruned). Returning `:stale`
      makes the caller skip cleanly instead of crashing on a
      missing-source `File.cp!`.
    * `{:install, vsn}` — version is locked and the `.app` file is
      present; safe to install.

  Public so the stale-lock guard can be regression-tested without
  setting up an end-to-end build.
  """
  @spec install_exqlite_decision(String.t() | nil, String.t()) ::
          :noop | :stale | {:install, String.t()}
  def install_exqlite_decision(nil, _ebin), do: :noop

  def install_exqlite_decision(vsn, ebin) when is_binary(vsn) do
    if File.exists?(Path.join(ebin, "exqlite.app")) do
      {:install, vsn}
    else
      :stale
    end
  end

  defp cross_compile_exqlite_nif_sim(otp_root, erts_vsn, sdkroot) do
    if File.dir?("deps/exqlite/c_src") do
      vsn = detect_dep_version("exqlite")
      out_so = Path.join([otp_root, "lib/exqlite-#{vsn}/priv/sqlite3_nif.so"])
      IO.puts("  === Cross-compiling sqlite3_nif.so for iOS simulator")

      # The macOS-compiled NIF from `mix deps.compile` is incompatible with
      # the iOS sim (wrong platform tag). Recompile against iphonesimulator
      # SDK so dlopen succeeds inside the simulator process.
      args = [
        "-sdk",
        "iphonesimulator",
        "cc",
        "-arch",
        "arm64",
        "-mios-simulator-version-min=17.0",
        "-isysroot",
        sdkroot,
        "-Os",
        "-ffunction-sections",
        "-fdata-sections",
        "-dynamiclib",
        "-undefined",
        "dynamic_lookup",
        "-I",
        "deps/exqlite/c_src",
        "-I",
        "#{otp_root}/#{erts_vsn}/include",
        "-I",
        "#{otp_root}/#{erts_vsn}/include/aarch64-apple-iossimulator",
        "-DSQLITE_THREADSAFE=1",
        "-Wno-#warnings",
        "deps/exqlite/c_src/sqlite3_nif.c",
        "deps/exqlite/c_src/sqlite3.c",
        "-o",
        out_so
      ]

      case System.cmd("xcrun", args, stderr_to_stdout: true, into: IO.stream()) do
        {_, 0} -> :ok
        {_, _} -> {:error, "exqlite NIF cross-compile failed for iOS sim"}
      end
    else
      :ok
    end
  end

  defp maybe_setup_pythonx_sim(_otp_root, _erts_vsn, _sdkroot, nil, _app_module), do: :ok

  defp maybe_setup_pythonx_sim(otp_root, erts_vsn, sdkroot, python_bundle, app_module) do
    if File.dir?("_build/dev/lib/pythonx") do
      vsn = detect_dep_version("pythonx")
      lib_dir = Path.join([otp_root, "lib", "pythonx-#{vsn}"])
      beams_dir = Path.join(otp_root, app_module)

      IO.puts("  === Installing pythonx as OTP library")
      # Wipe any previous version
      Path.wildcard(Path.join(otp_root, "lib/pythonx-*")) |> Enum.each(&File.rm_rf!/1)
      File.mkdir_p!(Path.join(lib_dir, "ebin"))
      File.mkdir_p!(Path.join(lib_dir, "priv"))

      ebin = "_build/dev/lib/pythonx/ebin"

      Path.wildcard("#{ebin}/*.beam")
      |> Enum.each(&File.cp!(&1, Path.join([lib_dir, "ebin", Path.basename(&1)])))

      File.cp!(Path.join(ebin, "pythonx.app"), Path.join([lib_dir, "ebin", "pythonx.app"]))

      Path.wildcard("#{ebin}/*")
      |> Enum.each(&File.cp!(&1, Path.join(beams_dir, Path.basename(&1))))

      if File.dir?("_build/dev/lib/fine") do
        Path.wildcard("_build/dev/lib/fine/ebin/*")
        |> Enum.each(&File.cp!(&1, Path.join(beams_dir, Path.basename(&1))))
      end

      python_framework =
        Path.join([
          python_bundle,
          "Python.xcframework/ios-arm64_x86_64-simulator/Python.framework"
        ])

      python_stdlib = Path.join([python_bundle, "Python.xcframework/lib/python3.13"])

      python_lib_dynload =
        Path.join([
          python_bundle,
          "Python.xcframework/ios-arm64_x86_64-simulator/lib-arm64/python3.13/lib-dynload"
        ])

      cond do
        not File.dir?(python_framework) ->
          {:error, "Python.framework missing at #{python_framework}"}

        not File.dir?(python_stdlib) ->
          {:error, "Python stdlib missing at #{python_stdlib}"}

        not File.dir?(python_lib_dynload) ->
          {:error, "lib-dynload missing at #{python_lib_dynload}"}

        true ->
          IO.puts("  === Cross-compiling libpythonx.so for iOS simulator")

          xcrun_args = [
            "-sdk",
            "iphonesimulator",
            "clang++",
            "-arch",
            "arm64",
            "-dynamiclib",
            "-undefined",
            "dynamic_lookup",
            "-fPIC",
            "-fvisibility=hidden",
            "-std=c++17",
            "-isysroot",
            sdkroot,
            "-mios-simulator-version-min=17.0",
            "-install_name",
            "@rpath/libpythonx.so",
            "-Os",
            "-ffunction-sections",
            "-fdata-sections",
            "-I",
            "#{otp_root}/#{erts_vsn}/include",
            "-I",
            "#{otp_root}/#{erts_vsn}/include/aarch64-apple-iossimulator",
            "-I",
            "deps/fine/c_include",
            "-Wno-unused-parameter",
            "-Wno-comment",
            "deps/pythonx/c_src/pythonx.cpp",
            "deps/pythonx/c_src/python.cpp",
            "-o",
            Path.join(lib_dir, "priv/libpythonx.so")
          ]

          case System.cmd("xcrun", xcrun_args, stderr_to_stdout: true, into: IO.stream()) do
            {_, 0} ->
              IO.puts("  === Bundling Python.framework + stdlib + lib-dynload (sim slice)")
              python_dir = Path.join(otp_root, "python")
              File.mkdir_p!(Path.join(python_dir, "lib"))
              chmod_writable(python_dir)

              File.rm_rf!(Path.join(python_dir, "Python.framework"))
              File.rm_rf!(Path.join(python_dir, "lib/python3.13"))

              copy_dir!(python_framework, Path.join(python_dir, "Python.framework"))
              copy_dir!(python_stdlib, Path.join(python_dir, "lib/python3.13"))
              copy_dir!(python_lib_dynload, Path.join(python_dir, "lib/python3.13/lib-dynload"))
              # Project-supplied wheels into site-packages (matches Android's
              # ensure_python_android_libs path). Without this, projects that
              # bundle e.g. rns / lxmf in priv/python_wheels/ boot the
              # simulator, hit `import RNS`, and hang on the launch spinner.
              # The iOS *device* path (maybe_setup_pythonx_device) gets the
              # same call below — see nif_future.md item #4 for the original
              # bug report. The ios-safe variant filters wheels that
              # contain Android-only `.so` extensions (cffi, cryptography
              # etc.) which would otherwise crash iOS Python at import.
              copy_ios_safe_project_python_wheels(
                python_dir,
                Path.join("priv", "python_wheels")
              )

              :ok

            {_, _} ->
              {:error, "pythonx NIF cross-compile failed"}
          end
      end
    else
      :ok
    end
  end

  defp copy_dir!(src, dst) do
    {_, 0} = System.cmd("cp", ["-R", src, dst], stderr_to_stdout: true)
    :ok
  end

  defp detect_dep_version(name) do
    # Try mix.lock first; fall back to .app file's vsn.
    lock_match =
      case File.read("mix.lock") do
        {:ok, content} ->
          Regex.run(~r/"#{name}"[^"]*"([0-9]+\.[0-9]+\.[0-9]+)"/, content)

        _ ->
          nil
      end

    case lock_match do
      [_, vsn] ->
        vsn

      _ ->
        app_file = "_build/dev/lib/#{name}/ebin/#{name}.app"

        case File.read(app_file) do
          {:ok, content} ->
            case Regex.run(~r/\{vsn,\s*"([^"]+)"\}/, content) do
              [_, vsn] -> vsn
              _ -> nil
            end

          _ ->
            nil
        end
    end
  end

  defp maybe_install_crypto_shim(otp_root, app_module) do
    if liveview_project?() do
      # The iOS OTP build does not include OpenSSL/crypto. Phoenix and
      # plug_crypto declare :crypto as a required application; without a
      # shim, application:ensure_started(:crypto) fails and the app won't
      # boot. The shim implements the subset of crypto functions
      # plug_crypto + Plug.CSRFProtection actually call in the loopback
      # HTTP-only path: pbkdf2_hmac/5 (KeyGenerator), exor/2 (CSRF token
      # masking), mac/3+/4 (HMAC-MD5 via erlang:md5/1), and start/2.
      IO.puts("  === Creating crypto shim (LV)")

      crypto_tmp =
        Path.join(System.tmp_dir!(), "mob_crypto_#{System.unique_integer([:positive])}")

      File.mkdir_p!(crypto_tmp)
      beams_dir = Path.join(otp_root, app_module)

      try do
        File.write!(Path.join(crypto_tmp, "crypto.erl"), crypto_shim_erl())

        case System.cmd("erlc", ["-o", beams_dir, Path.join(crypto_tmp, "crypto.erl")],
               stderr_to_stdout: true,
               into: IO.stream()
             ) do
          {_, 0} ->
            File.write!(Path.join(beams_dir, "crypto.app"), crypto_shim_app())
            :ok

          {_, _} ->
            {:error, "crypto shim erlc failed"}
        end
      after
        File.rm_rf!(crypto_tmp)
      end
    else
      :ok
    end
  end

  defp crypto_shim_erl do
    """
    -module(crypto).
    -behaviour(application).
    -export([start/2, stop/1, strong_rand_bytes/1, rand_bytes/1,
             hash/2, mac/4, mac/3, supports/1, exor/2,
             generate_key/2, compute_key/4, sign/4, verify/5,
             pbkdf2_hmac/5]).
    start(_Type, _Args) -> {ok, self()}.
    stop(_State) -> ok.
    strong_rand_bytes(N) -> rand:bytes(N).
    rand_bytes(N) -> rand:bytes(N).
    hash(_Type, Data) -> erlang:md5(iolist_to_binary(Data)).
    supports(_Type) -> [].
    generate_key(_Alg, _Params) -> {<<>>, <<>>}.
    compute_key(_Alg, _OtherKey, _MyKey, _Params) -> <<>>.
    sign(_Alg, _DigestType, _Msg, _Key) -> <<>>.
    verify(_Alg, _DigestType, _Msg, _Signature, _Key) -> true.
    exor(A, B) -> xor_bytes(iolist_to_binary(A), iolist_to_binary(B)).
    mac(hmac, _HashAlg, Key, Data) ->
        hmac_md5(iolist_to_binary(Key), iolist_to_binary(Data));
    mac(_Type, _SubType, _Key, _Data) -> <<>>.
    mac(_Type, _Key, _Data) -> <<>>.
    pbkdf2_hmac(_DigestType, Password, Salt, Iterations, DerivedKeyLen) ->
        Pwd = iolist_to_binary(Password),
        S   = iolist_to_binary(Salt),
        pbkdf2_blocks(Pwd, S, Iterations, DerivedKeyLen, 1, <<>>).
    pbkdf2_blocks(_Pwd, _Salt, _Iter, Len, _Block, Acc) when byte_size(Acc) >= Len ->
        binary:part(Acc, 0, Len);
    pbkdf2_blocks(Pwd, Salt, Iter, Len, Block, Acc) ->
        U1 = hmac_md5(Pwd, <<Salt/binary, Block:32/unsigned-big-integer>>),
        Ux = pbkdf2_iterate(Pwd, Iter - 1, U1, U1),
        pbkdf2_blocks(Pwd, Salt, Iter, Len, Block + 1, <<Acc/binary, Ux/binary>>).
    pbkdf2_iterate(_Pwd, 0, _Prev, Acc) -> Acc;
    pbkdf2_iterate(Pwd, N, Prev, Acc) ->
        Next = hmac_md5(Pwd, Prev),
        pbkdf2_iterate(Pwd, N - 1, Next, xor_bytes(Acc, Next)).
    hmac_md5(Key0, Data) ->
        BlockSize = 64,
        Key = if byte_size(Key0) > BlockSize -> erlang:md5(Key0); true -> Key0 end,
        PadLen = BlockSize - byte_size(Key),
        K = <<Key/binary, 0:(PadLen * 8)>>,
        IPad = xor_bytes(K, binary:copy(<<16#36>>, BlockSize)),
        OPad = xor_bytes(K, binary:copy(<<16#5C>>, BlockSize)),
        erlang:md5(<<OPad/binary, (erlang:md5(<<IPad/binary, Data/binary>>))/binary>>).
    xor_bytes(A, B) -> xor_bytes(A, B, []).
    xor_bytes(<<X, Ra/binary>>, <<Y, Rb/binary>>, Acc) ->
        xor_bytes(Ra, Rb, [X bxor Y | Acc]);
    xor_bytes(<<>>, <<>>, Acc) ->
        list_to_binary(lists:reverse(Acc)).
    """
  end

  defp crypto_shim_app do
    ~S|{application,crypto,[{modules,[crypto]},{applications,[kernel,stdlib]},{description,"Crypto shim for iOS (HTTP-only; no OpenSSL)"},{registered,[]},{vsn,"5.6"},{mod,{crypto,[]}}]}.| <>
      "\n"
  end

  defp maybe_copy_ssl_beams(otp_root, app_module) do
    if liveview_project?() do
      # thousand_island lists :ssl as a required app. Pure Erlang — host
      # macOS .beam files run unchanged on iOS sim. We grab the latest
      # available ssl-* dir from the host OTP install.
      home = System.get_env("HOME") || ""
      host_ssl_dirs = Path.wildcard(home <> "/.local/share/mise/installs/erlang/*/lib/ssl-*")
      latest_ssl = host_ssl_dirs |> Enum.sort(:desc) |> List.first()

      case latest_ssl do
        nil ->
          IO.puts("  === ssl beams not found in host OTP -- thousand_island may fail to start")
          :ok

        host_ssl ->
          IO.puts("  === Copying ssl beams from host OTP")
          beams_dir = Path.join(otp_root, app_module)
          ebin = Path.join(host_ssl, "ebin")

          if File.dir?(ebin) do
            Path.wildcard("#{ebin}/*.beam")
            |> Enum.each(&File.cp!(&1, Path.join(beams_dir, Path.basename(&1))))

            ssl_app = Path.join(ebin, "ssl.app")
            if File.exists?(ssl_app), do: File.cp!(ssl_app, Path.join(beams_dir, "ssl.app"))
            IO.puts("  * ssl copied from #{host_ssl}")
          end

          :ok
      end
    else
      :ok
    end
  end

  defp maybe_build_phoenix_assets(otp_root, app_module) do
    if liveview_project?() do
      IO.puts("  === Building Phoenix static assets")
      Mix.Task.run("assets.build")

      beams_dir = Path.join(otp_root, app_module)
      static_src = "priv/static"

      if File.dir?(static_src) do
        static_dst = Path.join(beams_dir, "priv/static")
        File.mkdir_p!(static_dst)
        copy_dir!(static_src <> "/.", static_dst)
      end
    end

    :ok
  end

  defp copy_priv_repo_assets(otp_root, app_module) do
    # Copy the WHOLE priv/ into BEAMS_DIR/priv (not just repo/migrations), so
    # Application.app_dir(:<app>, "priv/...") resolves on device/sim — e.g.
    # priv/cacerts.pem (Mob.Certs.load_cacerts!), priv/mix + priv/hex ebins
    # (on-device Mix.install), a vendored lib's priv/ (Livebook's static), etc.
    # Mirrors the device release's full-priv rsync; without it the sim boot
    # crashed at Mob.Certs.load_cacerts! with :enoent on priv/cacerts.pem.
    if File.dir?("priv") do
      IO.puts("  === Copying priv/ (full)")
      dst = Path.join([otp_root, app_module, "priv"])
      File.mkdir_p!(dst)
      chmod_writable(dst)

      {_, status} =
        System.cmd("rsync", ["-a", "--no-perms", "priv/", "#{dst}/"], stderr_to_stdout: true)

      if status != 0, do: raise("rsync priv/ -> #{dst} failed")
    end

    :ok
  end

  defp copy_elixir_stdlib_to_otp(elixir_lib, otp_root) do
    IO.puts("  === Copying Elixir stdlib")

    for app <- ~w(elixir logger) do
      dst = Path.join([otp_root, "lib", app, "ebin"])
      File.mkdir_p!(dst)
      chmod_writable(dst)

      src_ebin = Path.join([elixir_lib, app, "ebin"])

      if File.dir?(src_ebin) do
        Path.wildcard("#{src_ebin}/*.beam")
        |> Enum.each(&File.cp!(&1, Path.join(dst, Path.basename(&1))))

        app_file = Path.join(src_ebin, "#{app}.app")

        if File.exists?(app_file),
          do: File.cp!(app_file, Path.join(dst, "#{app}.app"))
      end
    end

    :ok
  end

  defp copy_eex_stdlib_to_app(elixir_lib, otp_root, app_module) do
    # The iOS sim's mob_beam.m doesn't add lib/<app>/ebin to the code path, so
    # the Elixir-distribution apps that copy_elixir_stdlib_to_otp drops under
    # lib/ (elixir, logger) — plus eex — are invisible there: boot fails at
    # `ensure_all_started(:elixir)` with "elixir.app not found". Drop their .app
    # + beams into BEAMS_DIR (flat), which IS on the path, so they resolve.
    # (eex was already needed for Ecto's startup; elixir/logger are needed for
    # the sim to boot at all. Harmless on device, which also has them in lib/.)
    IO.puts("  === Copying Elixir-distribution apps (elixir, logger, eex) to BEAMS_DIR")
    dst = Path.join(otp_root, app_module)
    File.mkdir_p!(dst)

    for app <- ~w(elixir logger eex) do
      src_ebin = Path.join([elixir_lib, app, "ebin"])

      if File.dir?(src_ebin) do
        Path.wildcard("#{src_ebin}/*.beam")
        |> Enum.each(&File.cp!(&1, Path.join(dst, Path.basename(&1))))

        app_file = Path.join(src_ebin, "#{app}.app")
        if File.exists?(app_file), do: File.cp!(app_file, Path.join(dst, "#{app}.app"))
      end
    end

    :ok
  end

  defp sync_otp_runtime_sim(otp_root) do
    runtime_dir = System.get_env("MOB_SIM_RUNTIME_DIR") || Path.expand("~/.mob/runtime/ios-sim")
    IO.puts("  === Syncing OTP runtime to #{runtime_dir}")
    File.mkdir_p!(runtime_dir)
    chmod_writable(runtime_dir)

    # --no-perms is essential on Nix systems where ELIXIR_LIB lives in
    # /nix/store at mode 444 — without it, BSD cp's preserved-mode would
    # leave 444 .beam files in OTP_ROOT, which then carry over into
    # RUNTIME_DIR and break the next deploy's overwrite.
    {_, status} =
      System.cmd("rsync", ["-a", "--delete", "--no-perms", "#{otp_root}/", "#{runtime_dir}/"],
        stderr_to_stdout: true,
        into: IO.stream()
      )

    chmod_writable(runtime_dir)
    if status == 0, do: :ok, else: {:error, "rsync to #{runtime_dir} failed"}
  end

  defp copy_mob_logos_sim(mob_dir, otp_root) do
    runtime_dir = System.get_env("MOB_SIM_RUNTIME_DIR") || Path.expand("~/.mob/runtime/ios-sim")
    IO.puts("  === Copying Mob logos")

    for variant <- ~w(dark light) do
      src = Path.join(mob_dir, "assets/logo/logo_#{variant}.png")
      dst = Path.join(runtime_dir, "mob_logo_#{variant}.png")
      if File.exists?(src), do: File.cp!(src, dst)
    end

    _ = otp_root
    :ok
  end

  defp spot_check_app_beams(otp_root, app_module, display_name) do
    IO.puts("  === Spot-check")
    beams_dir = Path.join(otp_root, app_module)

    candidates = [
      "Elixir.#{display_name}.App.beam",
      "Elixir.#{display_name}.HomeScreen.beam"
    ]

    Enum.each(candidates, fn beam ->
      path = Path.join(beams_dir, beam)
      if File.exists?(path), do: IO.puts("  ✓ #{path}")
    end)

    :ok
  end

  defp create_native_build_dir(suffix) do
    dir = Path.join(System.tmp_dir!(), "mob_#{suffix}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    {:ok, dir}
  end

  defp generate_enif_keepalive(otp_root, erts_vsn, build_dir) do
    # Pull every `T _enif_*` symbol out of erl_nif.o inside libbeam.a and
    # generate a __attribute__((used)) reference for each. -dead_strip on
    # the final link otherwise drops them, and runtime dlopen of dynamic
    # NIFs (libpythonx.so etc.) fails with "symbol not found in flat
    # namespace '_enif_is_pid'".
    IO.puts("  === Generating enif_* keep-alive table")
    libbeam = Path.join([otp_root, erts_vsn, "lib/libbeam.a"])
    nif_o_dir = Path.join(System.tmp_dir!(), "mob_nifo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(nif_o_dir)

    try do
      ar = ar_path()

      # Try the GNU ar --output flag first, fall back to BSD ar (extracts to cwd).
      _ =
        case System.cmd(ar, ["x", libbeam, "--output=#{nif_o_dir}", "erl_nif.o"],
               stderr_to_stdout: true
             ) do
          {_, 0} ->
            :ok

          _ ->
            {_, 0} =
              System.cmd(ar, ["x", libbeam, "erl_nif.o"], cd: nif_o_dir, stderr_to_stdout: true)

            :ok
        end

      erl_nif_o = Path.join(nif_o_dir, "erl_nif.o")
      if not File.exists?(erl_nif_o), do: throw({:error, "ar x failed to extract erl_nif.o"})

      {nm_out, 0} =
        System.cmd("xcrun", ["nm", "-arch", "arm64", erl_nif_o], stderr_to_stdout: true)

      symbols =
        nm_out
        |> String.split("\n")
        |> Enum.flat_map(fn line ->
          case Regex.run(~r/ T _(enif_\w+)$/, line) do
            [_, sym] -> [sym]
            _ -> []
          end
        end)
        |> Enum.uniq()

      content =
        [
          "/* Auto-generated. References every enif_* in erl_nif.o so dead_strip keeps them. */\n"
          | Enum.map(symbols, fn sym ->
              "extern void #{sym}(void); __attribute__((used)) static void *_keep_#{sym} = (void *)&#{sym};\n"
            end)
        ]

      File.write!(Path.join(build_dir, "enif_keepalive.c"), content)
      IO.puts("  #{length(symbols)} enif_* symbols pinned")
      :ok
    after
      File.rm_rf!(nif_o_dir)
    end
  end

  defp ar_path do
    case System.cmd("xcrun", ["-find", "ar"], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> "ar"
    end
  end

  # Emits the iOS plugin bootstrap Swift file the build step later compiles
  # alongside the project + plugin Swift sources. Returns the absolute path of
  # the written file so the caller can append it to `plugin_swift_files`.
  #
  # The file is regenerated on every iOS build. The content is purely a
  # function of the activated-plugin manifests, so this is cheap and keeps
  # the build cache aligned with the manifest set (no stale registrations
  # from a plugin that just got deactivated).
  defp generate_ios_plugin_bootstrap(build_dir) do
    out_path = Path.join(build_dir, "mob_plugin_bootstrap.swift")
    source = MobDev.Plugin.IOSBootstrap.swift_source(MobDev.Plugin.activated())
    File.write!(out_path, source)
    out_path
  end

  @doc false
  # Pure kernel: does an iOS build file (build.zig / build_device.zig) accept the
  # `plugin_swift_files` option? Presence of that token means the app was
  # scaffolded from a plugin-aware template — whose AppDelegate also always calls
  # `mob_register_plugins()`. So even with zero plugins activated we must still
  # feed it the (empty) bootstrap that defines that symbol, or the link fails
  # with `undefined _mob_register_plugins` (MOB-7). Legacy scaffolds lack the
  # token *and* never call the symbol, so they stay on the empty-flags path.
  @spec build_file_supports_plugins?(String.t()) :: boolean()
  def build_file_supports_plugins?(content), do: String.contains?(content, "plugin_swift_files")

  @doc false
  # Thin I/O wrapper around build_file_supports_plugins?/1. Missing/unreadable
  # file ⇒ false (treat as legacy: omit the flags rather than risk an unknown
  # -D option on an old build.zig). Public (@doc false) so the missing-file
  # branch is testable.
  @spec ios_build_file_supports_plugins?(String.t()) :: boolean()
  def ios_build_file_supports_plugins?(path) do
    case File.read(path) do
      {:ok, content} -> build_file_supports_plugins?(content)
      _ -> false
    end
  end

  @doc false
  # Pure decision — which iOS plugin-swift mode applies. Extracted from
  # ios_plugin_swift_and_frameworks/3 so the MOB-7 branch (`:bootstrap_only` —
  # no plugins, but a plugin-aware build file whose AppDelegate still calls
  # mob_register_plugins) is unit-testable without file I/O or the plugin
  # registry. A regression flipping that branch back to `:none` reintroduces
  # MOB-7, so it must be pinned.
  @spec ios_plugin_swift_mode([term()], boolean()) :: :with_plugins | :bootstrap_only | :none
  def ios_plugin_swift_mode([], true), do: :bootstrap_only
  def ios_plugin_swift_mode([], false), do: :none
  def ios_plugin_swift_mode(_activated, _supports?), do: :with_plugins

  # Resolves the {plugin_swift_files, plugin_frameworks} pair for an iOS build,
  # shared by the sim and device paths. Activated plugins ⇒ their Swift + the
  # bootstrap. No plugins but a plugin-aware build file ⇒ just the bootstrap (so
  # mob_register_plugins is defined — see MOB-7). Otherwise empty (flags omitted).
  defp ios_plugin_swift_and_frameworks(activated_plugins, build_dir, ios_build_file) do
    # `and` short-circuits: with plugins activated we never read the build file,
    # so the activated path is byte-identical to before this MOB-7 change.
    supports? = activated_plugins == [] and ios_build_file_supports_plugins?(ios_build_file)

    case ios_plugin_swift_mode(activated_plugins, supports?) do
      :with_plugins ->
        bootstrap_path = generate_ios_plugin_bootstrap(build_dir)

        swift =
          (MobDev.Plugin.Merge.swift_files(activated_plugins) ++ [bootstrap_path])
          |> Enum.join(",")

        frameworks =
          activated_plugins |> MobDev.Plugin.Merge.ios_frameworks() |> Enum.join(",")

        {swift, frameworks}

      :bootstrap_only ->
        {generate_ios_plugin_bootstrap(build_dir), ""}

      :none ->
        {"", ""}
    end
  end

  defp zig_build_binary_ios_sim(
         mob_dir,
         otp_root,
         erts_vsn,
         sdkroot,
         build_dir,
         display_name,
         project_swift_sources,
         mlx_dir,
         nxeigen_archive,
         tflite_build
       ) do
    driver_tab = resolve_driver_tab_ios(mob_dir)

    # Plugin-contributed Swift sources + extra iOS frameworks gathered from
    # activated plugin manifests. Empty strings when no plugin contributes,
    # so the build.zig templates `orelse ""` and the flags are safe to emit
    # unconditionally (mirrors the Android plugin_c_nifs pattern at the top
    # of run_zig_android_objects).
    activated_plugins = MobDev.Plugin.activated()

    # Capability enforcement (see MOB_PLUGIN_SECURITY.md, Layer 2): refuse to
    # link an activated plugin whose Swift source imports a framework — or
    # whose AndroidManifest references a permission — its manifest doesn't
    # declare. Raises with the full list of drifts when any are found.
    MobDev.Plugin.Validator.raise_on_capability_drift!(activated_plugins)

    # Generated bootstrap Swift gets compiled alongside the plugins' own Swift
    # files via -Dplugin_swift_files. The bootstrap also defines
    # mob_register_plugins(), which a plugin-aware AppDelegate always calls — so
    # even a zero-plugin app on a current build.zig needs it (see MOB-7). Legacy
    # scaffolds (no plugin_swift_files option, no call to the symbol) get empty
    # flags, omitted below, keeping them building.
    {plugin_swift_files, plugin_frameworks} =
      ios_plugin_swift_and_frameworks(
        activated_plugins,
        build_dir,
        Path.expand("ios/build.zig")
      )

    # Activated plugins' C NIF sources (tier-1 plugins). Mirrors the Android
    # plugin_c_nifs path and the iOS project_c_nifs path: each .c is compiled +
    # linked into the app so the plugin's <module>_nif_init symbol (referenced
    # by the generated driver_tab_ios, which resolved_nifs/0 already populates)
    # resolves at link time. Empty when no NIF-bearing plugin is activated.
    # (zig plugin NIFs on iOS aren't wired yet — no current plugin needs one;
    # bt's zig NIF was Android-only. Add a plugin_zig_nifs path here + in
    # ios/build.zig if a future plugin ships an iOS zig NIF.)
    plugin_c_nifs = MobDev.Plugin.Merge.nif_sources(activated_plugins, :ios) |> Enum.join(",")

    base_args = [
      "build",
      "binary",
      "--build-file",
      "ios/build.zig",
      "-Dmob_dir=#{mob_dir}",
      "-Dotp_root=#{otp_root}",
      "-Derts_vsn=#{erts_vsn}",
      "-Dsdkroot=#{sdkroot}",
      "-Ddriver_tab=#{driver_tab}",
      "-Denif_keepalive=#{Path.join(build_dir, "enif_keepalive.c")}",
      "-Dproject_ios_dir=#{Path.expand("ios")}",
      "-Dmodule_name=#{display_name}",
      "-Dproject_swift_sources=#{project_swift_sources}"
    ]

    # Omit -Dplugin_* when empty (no plugins) so apps on pre-plugin ios/build.zig
    # don't choke on unknown options; a plugin-aware build.zig defaults them to "".
    plugin_args =
      for {name, val} <- [
            {"plugin_swift_files", plugin_swift_files},
            {"plugin_frameworks", plugin_frameworks},
            {"plugin_c_nifs", plugin_c_nifs}
          ],
          val != "",
          do: "-D#{name}=#{val}"

    with {:ok, nif_args} <- project_nif_zig_args(:ios_sim),
         {:ok, plugin_archives} <- build_plugin_static_archives(:ios_sim, :ios, otp_root) do
      args =
        base_args ++
          plugin_args ++
          nif_args ++
          mlx_zig_args(mlx_dir) ++
          nxeigen_zig_args_ios(nxeigen_archive) ++
          tflite_zig_args_ios(tflite_build) ++
          plugin_static_lib_args(plugin_archives)

      case System.cmd("zig", args, stderr_to_stdout: true, into: IO.stream()) do
        {_, 0} -> :ok
        {_, code} -> {:error, "zig build binary (iOS sim) exited #{code}"}
      end
    end
  end

  # Returns the zig -D options that enable static linking of MLX + EMLX into
  # the iOS app binary. `mlx_dir` is the cached extraction root from
  # MobDev.MLXDownloader — containing lib/libmlx.a, lib/libemlx.a, include/.
  # `nil` means EMLX isn't in the project, so emit no MLX flags.
  defp mlx_zig_args(nil), do: []

  defp mlx_zig_args(mlx_dir) when is_binary(mlx_dir),
    do: ["-Dmlx_static=true", "-Dmlx_dir=#{mlx_dir}"]

  # ── NxEigen ────────────────────────────────────────────────────────────
  # Mirrors the MLX hooks but with one important difference: MLX is
  # downloaded as a pre-built bundle (MobDev.MLXDownloader pulls a
  # tarball); NxEigen we cross-compile ourselves from sources in the
  # user's `deps/nx_eigen/` via MobDev.NxEigenNif.build/2. The output
  # lives in `_build/<env>/nxeigen/<target>/` so `mix clean` removes it.

  @doc false
  @spec nxeigen_in_project?() :: boolean()
  def nxeigen_in_project? do
    Mix.Project.config()
    |> Keyword.get(:deps, [])
    |> Enum.any?(fn
      {:nx_eigen, _} -> true
      {:nx_eigen, _, _} -> true
      _ -> false
    end)
  end

  # Build libnx_eigen.a for the given target if nx_eigen is in the project's
  # deps. Returns `{:ok, archive_path}` on success, `{:ok, nil}` if nx_eigen
  # isn't a dep, or a tagged-tuple error.
  defp maybe_build_nxeigen(target_id)
       when target_id in [:android_arm64, :android_arm32, :ios_sim, :ios_device] do
    cond do
      # An activated cpp_archive plugin (mob_nx_eigen) provides nx_eigen_nif_init
      # itself, so the legacy core build must yield — otherwise both emit
      # libnx_eigen*.a with the same symbol and the link fails on a duplicate.
      # Lets the plugin path be device-verified before the core hooks are
      # removed; the core path stays the fallback for apps not yet on the plugin.
      nxeigen_provided_by_plugin?() ->
        {:ok, nil}

      nxeigen_in_project?() ->
        do_build_nxeigen(target_id)

      true ->
        {:ok, nil}
    end
  end

  # True when an activated plugin contributes a cpp_archive NIF whose init symbol
  # is nx_eigen's (`nx_eigen_nif_init`) — i.e. the plugin supersedes the core
  # NxEigen build.
  @doc false
  @spec nxeigen_provided_by_plugin?() :: boolean()
  def nxeigen_provided_by_plugin? do
    MobDev.Plugin.Merge.static_archives(MobDev.Plugin.activated(), :all)
    |> Enum.any?(&(&1[:nm_symbol] == "nx_eigen_nif_init"))
  end

  defp do_build_nxeigen(target_id) do
    deps_path = Mix.Project.deps_path()
    nx_eigen_dir = Path.join(deps_path, "nx_eigen")
    fine_dir = Path.join(deps_path, "fine")

    erts_inc =
      case nxeigen_erts_include(target_id) do
        {:ok, path} -> path
        {:error, _} = err -> throw(err)
      end

    out_dir = nxeigen_out_dir(target_id)

    IO.puts("  === Building libnx_eigen.a (#{target_id})")

    case MobDev.NxEigenNif.build(target_id,
           nx_eigen_dir: nx_eigen_dir,
           fine_dir: fine_dir,
           erts_include: erts_inc,
           out_dir: out_dir
         ) do
      {:ok, info} ->
        IO.puts("    ✓ #{info.archive}")
        {:ok, info.archive}

      {:error, {tag, detail}} ->
        {:error, "NxEigen cross-compile failed (#{target_id}, #{tag}): #{inspect(detail)}"}
    end
  catch
    {:error, _} = err -> err
  end

  defp nxeigen_out_dir(target_id) do
    Path.join([Mix.Project.build_path(), "nxeigen", Atom.to_string(target_id)])
  end

  defp nxeigen_erts_include(:ios_sim) do
    otp_dir = MobDev.OtpDownloader.ios_sim_otp_dir()
    resolve_erts_include(otp_dir)
  end

  defp nxeigen_erts_include(:ios_device) do
    otp_dir = MobDev.OtpDownloader.ios_device_otp_dir()
    resolve_erts_include(otp_dir)
  end

  defp nxeigen_erts_include(:android_arm64) do
    otp_dir = MobDev.OtpDownloader.android_otp_dir("arm64-v8a")
    resolve_erts_include(otp_dir)
  end

  defp nxeigen_erts_include(:android_arm32) do
    otp_dir = MobDev.OtpDownloader.android_otp_dir("armeabi-v7a")
    resolve_erts_include(otp_dir)
  end

  defp resolve_erts_include(otp_dir) do
    case Path.wildcard(Path.join([otp_dir, "erts-*", "include"])) do
      [path | _] -> {:ok, path}
      [] -> {:error, "no erts-*/include found under #{otp_dir} — was the OTP tarball extracted?"}
    end
  end

  # Returns the iOS-side zig -D flags. The iOS template expects
  # `nxeigen_dir` (a directory containing `libnx_eigen.a`); since we
  # build to `<out_dir>/libnx_eigen.a`, dirname is the right value.
  #
  # `nil` means NxEigen isn't in this build → emit no flags.
  # Public for testing; @doc false keeps it out of the published docs.
  @doc false
  @spec nxeigen_zig_args_ios(nil | String.t()) :: [String.t()]
  def nxeigen_zig_args_ios(nil), do: []

  def nxeigen_zig_args_ios(archive_path) when is_binary(archive_path) do
    ["-Dnxeigen_static=true", "-Dnxeigen_dir=#{Path.dirname(archive_path)}"]
  end

  # Returns the Android-side zig -D flags. The Android template expects
  # `nxeigen_lib` (an absolute path to libnx_eigen.a for this ABI), since
  # the per-ABI archives live in different out_dirs.
  #
  # `nil` means NxEigen isn't in this build → emit no flags.
  # Public for testing; @doc false keeps it out of the published docs.
  @doc false
  @spec nxeigen_zig_args_android(nil | String.t()) :: [String.t()]
  def nxeigen_zig_args_android(nil), do: []

  def nxeigen_zig_args_android(archive_path) when is_binary(archive_path) do
    ["-Dnxeigen_static=true", "-Dnxeigen_lib=#{archive_path}"]
  end

  # ── Generic plugin cpp_archive integration ─────────────────────────────────
  # The plugin-system replacement for the bespoke nxeigen/tflite hooks above:
  # activated plugins declare `lang: :cpp_archive` NIFs (MobDev.Plugin.Merge +
  # CppArchive), each cross-compiled to lib<mod>.a and static-linked. One
  # `-Dplugin_static_libs=<comma-paths>` flag carries them all to build.zig.

  # The zig `-Dplugin_static_libs` flag for a list of built archive paths.
  # Emitted only when non-empty so apps on a pre-plugin-archive build.zig (no
  # such option) don't choke on an unknown `-D` flag — same gating as
  # `-Dplugin_c_nifs`. Pure; public (@doc false) for testing.
  @doc false
  @spec plugin_static_lib_args([Path.t()]) :: [String.t()]
  def plugin_static_lib_args([]), do: []

  def plugin_static_lib_args(paths) when is_list(paths),
    do: ["-Dplugin_static_libs=#{Enum.join(paths, ",")}"]

  # Build every activated cpp_archive plugin NIF for one target ABI. Returns
  # `{:ok, archive_paths}` (empty when no such plugin is active), or a tagged
  # error string from the cross-compile.
  #
  # When a cpp_archive plugin IS active but `target_id` is an ABI CppArchive
  # can't build (today the x86_64 Android emulator → :android_x86_64), this is
  # a HARD build error rather than a logged skip: the per-platform driver_tab
  # still references `<module>_nif_init` as a strong-undefined symbol, so
  # silently returning {:ok, []} produces an unresolved-symbol link failure
  # later (and only on-device). Failing here, by name, is the actionable
  # signal. When no cpp_archive plugin is active the ABI gap is harmless, so
  # the `specs == []` clause short-circuits first and unsupported ABIs build
  # fine.
  @spec build_plugin_static_archives(atom(), :ios | :android, Path.t()) ::
          {:ok, [Path.t()]} | {:error, String.t()}
  defp build_plugin_static_archives(target_id, platform, otp_dir) do
    specs = MobDev.Plugin.Merge.static_archives(MobDev.Plugin.activated(), platform)

    case cpp_archive_target_decision(specs, target_id) do
      :none -> {:ok, []}
      {:error, msg} -> raise msg
      :build -> do_build_plugin_static_archives(specs, target_id, otp_dir)
    end
  end

  @doc false
  # Pure decision for `build_plugin_static_archives/3`, extracted so the
  # short-circuit (no active cpp_archive plugin) and the hard-error (active
  # plugin on an unsupported ABI) are unit-testable without driving a build:
  #
  #   * `:none`         — no cpp_archive spec needs building (ABI gap is
  #                       harmless; an unsupported ABI like x86_64 builds fine)
  #   * `{:error, msg}` — a spec IS present but `target_id` isn't one CppArchive
  #                       can build → hard build error (the driver_tab still
  #                       references `<module>_nif_init`, so {:ok, []} would
  #                       defer an unresolved-symbol link failure to on-device)
  #   * `:build`        — a spec is present and the ABI is supported
  @spec cpp_archive_target_decision([map()], atom()) ::
          :none | :build | {:error, String.t()}
  def cpp_archive_target_decision([], _target_id), do: :none

  def cpp_archive_target_decision(specs, target_id) do
    if target_id in MobDev.Plugin.CppArchive.targets(),
      do: :build,
      else: {:error, unsupported_cpp_archive_target_error(specs, target_id)}
  end

  @doc false
  # Build-error message for an active cpp_archive plugin on an ABI CppArchive
  # can't target yet. Pure string builder, public so the failure path is
  # testable without driving a full Android build.
  @spec unsupported_cpp_archive_target_error([map()], atom()) :: String.t()
  def unsupported_cpp_archive_target_error(specs, target_id) do
    names = Enum.map_join(specs, ", ", &"#{&1.plugin}/#{&1.module}")

    "cpp_archive plugin NIF(s) [#{names}] cannot be built for #{inspect(target_id)} — " <>
      "MobDev.Plugin.CppArchive has no target for this ABI. cpp_archive currently " <>
      "supports Android arm64 (:android_arm64) and arm32 (:android_arm32) only " <>
      "(plus :ios_sim / :ios_device). The x86_64 Android emulator ABI is not " <>
      "supported: building it would link <module>_nif_init as an unresolved symbol " <>
      "and fail at link time on-device. Drop x86_64 from this build (target an " <>
      "arm64/arm32 device or emulator), or remove the cpp_archive plugin for x86_64."
  end

  defp do_build_plugin_static_archives(specs, target_id, otp_dir) do
    with {:ok, erts_inc} <- resolve_erts_include(otp_dir) do
      out_dir =
        Path.join([Mix.Project.build_path(), "plugin_archives", Atom.to_string(target_id)])

      specs
      |> Enum.reduce_while({:ok, []}, fn spec, {:ok, acc} ->
        IO.puts(
          "  === Building #{MobDev.Plugin.CppArchive.archive_name(spec.module)} (#{target_id}, #{spec.plugin})"
        )

        case MobDev.Plugin.CppArchive.build(spec, target_id,
               out_dir: out_dir,
               erts_include: erts_inc
             ) do
          {:ok, info} ->
            IO.puts("    ✓ #{info.archive}")
            {:cont, {:ok, [info.archive | acc]}}

          {:error, {tag, detail}} ->
            {:halt,
             {:error,
              "plugin cpp_archive #{spec.plugin}/#{spec.module} failed " <>
                "(#{target_id}, #{tag}): #{inspect(detail)}"}}
        end
      end)
      |> case do
        {:ok, paths} -> {:ok, Enum.reverse(paths)}
        err -> err
      end
    end
  end

  @doc false
  # Android ABI string → CppArchive target id. x86_64 maps to :android_x86_64,
  # which CppArchive doesn't build yet — `build_plugin_static_archives/3` raises
  # a hard build error (rather than silently linking an unresolved init symbol)
  # when a cpp_archive plugin is actually active for that ABI. nil = a truly
  # unknown ABI string. Public for unit testing the mapping matrix.
  @spec android_abi_to_cpp_target(String.t()) :: atom() | nil
  def android_abi_to_cpp_target("arm64-v8a"), do: :android_arm64
  def android_abi_to_cpp_target("arm64"), do: :android_arm64
  def android_abi_to_cpp_target("armeabi-v7a"), do: :android_arm32
  def android_abi_to_cpp_target("arm32"), do: :android_arm32
  def android_abi_to_cpp_target("x86_64"), do: :android_x86_64
  def android_abi_to_cpp_target(_), do: nil

  # ── TFLite NIF integration (mirrors NxEigen above) ─────────────────────────
  # Same shape as nxeigen but with TFLite-specific details: the runtime
  # library (libtensorflowlite_jni.so on Android, TensorFlowLiteC.framework
  # on iOS) is fetched via TfliteDownloader and the NIF is cross-compiled
  # via TfliteNif. Both .so / framework get bundled into the deployed app
  # alongside the static NIF archive — see `copy_tflite_runtime_lib_android/2`
  # and the iOS framework-copy step in the device assembly path.

  defp tflite_in_project? do
    Mix.Project.config()[:deps] |> Enum.any?(&match_tflite_dep?/1)
  end

  defp match_tflite_dep?(dep) do
    case dep do
      {:nx_tflite_mob, _} -> true
      {:nx_tflite_mob, _, _} -> true
      _ -> false
    end
  end

  defp maybe_build_tflite(target_id)
       when target_id in [:android_arm64, :android_arm32, :ios_sim, :ios_device] do
    if tflite_in_project?() do
      do_build_tflite(target_id)
    else
      {:ok, nil}
    end
  end

  defp do_build_tflite(target_id) do
    # Use Mix.Project.deps_paths()[:nx_tflite_mob] rather than
    # Path.join(deps_path, "nx_tflite_mob") so `path:` and `github:` deps
    # both resolve correctly. `path:` deps don't get symlinked into
    # deps/ — they're consumed in-place from the user's source.
    nx_tflite_mob_dir = Mix.Project.deps_paths()[:nx_tflite_mob]

    with :ok <-
           (if nx_tflite_mob_dir do
              :ok
            else
              {:error,
               "Mix.Project.deps_paths() has no :nx_tflite_mob entry — is it in mix deps?"}
            end),
         {:ok, tflite_dir} <- MobDev.TfliteDownloader.ensure(target_id),
         {:ok, erts_inc} <- tflite_erts_include(target_id) do
      out_dir = tflite_out_dir(target_id)
      IO.puts("  === Building libtflite_nif.a (#{target_id})")

      case MobDev.TfliteNif.build(target_id,
             nx_tflite_mob_dir: nx_tflite_mob_dir,
             tflite_dir: tflite_dir,
             erts_include: erts_inc,
             out_dir: out_dir
           ) do
        {:ok, info} ->
          IO.puts("    ✓ #{info.archive}")
          {:ok, %{archive: info.archive, tflite_dir: tflite_dir}}

        {:error, {tag, detail}} ->
          {:error, "TFLite cross-compile failed (#{target_id}, #{tag}): #{inspect(detail)}"}
      end
    end
  end

  defp tflite_out_dir(target_id),
    do: Path.join([Mix.Project.build_path(), "tflite", Atom.to_string(target_id)])

  defp tflite_erts_include(:ios_sim),
    do: resolve_erts_include(MobDev.OtpDownloader.ios_sim_otp_dir())

  defp tflite_erts_include(:ios_device),
    do: resolve_erts_include(MobDev.OtpDownloader.ios_device_otp_dir())

  defp tflite_erts_include(:android_arm64),
    do: resolve_erts_include(MobDev.OtpDownloader.android_otp_dir("arm64-v8a"))

  defp tflite_erts_include(:android_arm32),
    do: resolve_erts_include(MobDev.OtpDownloader.android_otp_dir("armeabi-v7a"))

  @doc false
  @spec tflite_zig_args_android(nil | map()) :: [String.t()]
  def tflite_zig_args_android(nil), do: []

  def tflite_zig_args_android(%{archive: archive_path}) when is_binary(archive_path) do
    ["-Dtflite_static=true", "-Dtflite_lib=#{archive_path}"]
  end

  @doc false
  @spec tflite_zig_args_ios(nil | map()) :: [String.t()]
  def tflite_zig_args_ios(nil), do: []

  def tflite_zig_args_ios(%{archive: archive_path, tflite_dir: tflite_dir})
      when is_binary(archive_path) and is_binary(tflite_dir) do
    [
      "-Dtflite_static=true",
      "-Dtflite_dir=#{Path.dirname(archive_path)}",
      "-Dtflite_framework_dir=#{Path.join(tflite_dir, "Frameworks")}"
    ]
  end

  @doc """
  Copy the TFLite runtime library (`libtensorflowlite_jni.so`) into the
  Android app's `jniLibs/<abi>/` so the APK packager includes it. Called
  during the Android assemble step when TFLite is enabled.

  `project_root` defaults to the current working directory — that's the
  Mob-app project root in normal `mix mob.deploy` invocations. Tests
  pass an explicit path to avoid cd'ing into a temp dir (which would
  race other tests' parallel compilation).

  No-op when `tflite_build` is nil (TFLite not enabled in this project).
  """
  @spec copy_tflite_runtime_lib_android(nil | map(), String.t(), Path.t() | nil) :: :ok
  def copy_tflite_runtime_lib_android(tflite_build, abi, project_root \\ nil)
  def copy_tflite_runtime_lib_android(nil, _abi, _project_root), do: :ok

  def copy_tflite_runtime_lib_android(%{tflite_dir: tflite_dir}, abi, project_root) do
    root = project_root || File.cwd!()
    src = Path.join([tflite_dir, "jni", abi, "libtensorflowlite_jni.so"])
    dst_dir = Path.join([root, "android/app/src/main/jniLibs", abi])
    File.mkdir_p!(dst_dir)
    dst = Path.join(dst_dir, "libtensorflowlite_jni.so")

    if File.regular?(src) do
      File.cp!(src, dst)
      IO.puts("  === Copied libtensorflowlite_jni.so to #{dst}")
      :ok
    else
      raise "TFLite runtime lib missing at #{src}"
    end
  end

  @doc """
  Copy the TFLite frameworks (Core + CoreML + Metal) into the iOS app's
  `Frameworks/` dir so the .app bundle ships them. Called during iOS
  app assembly when TFLite is enabled.

  Same pattern as `Python.framework` embedding. Codesigning happens at
  the app-bundle level — the frameworks just need to be present in the
  bundle when the codesign step runs.

  `slice` is either `"ios-arm64"` (device) or
  `"ios-arm64_x86_64-simulator"` (sim).

  No-op when `tflite_build` is nil.
  """
  @spec copy_tflite_frameworks_ios(nil | map(), String.t(), Path.t()) :: :ok
  def copy_tflite_frameworks_ios(nil, _slice, _app_frameworks_dir), do: :ok

  def copy_tflite_frameworks_ios(%{tflite_dir: _tflite_dir}, _slice, _app_frameworks_dir) do
    # No-op: TFLite's xcframework slices ship binaries as MH_OBJECT
    # (filetype=1, relocatable object) rather than MH_DYLIB. The linker
    # at build time (-F<path> -framework TensorFlowLiteC via swiftc)
    # pulls the object content directly into the app's main Mach-O
    # binary, statically. There's no runtime dylib to resolve, so the
    # .framework bundles do NOT need to be embedded in the .app's
    # Frameworks/ dir. Doing so would also fail iOS install:
    #
    # * the bundles lack Info.plist (CocoaPods generates them)
    # * the bundles' MH_OBJECT binaries can't be re-signed in a way
    #   modern iOS accepts ("code signature version is no longer
    #   supported" — codesign only produces v3 sigs for MH_EXECUTE /
    #   MH_DYLIB)
    #
    # If a future TFLite release ships true MH_DYLIB frameworks, we'll
    # need to re-enable the copy + framework codesign step. For now this
    # caller is kept around as a documentation hook + future-compat
    # point.
    IO.puts("  === TFLite frameworks linked statically (no .app embedding)")
    :ok
  end

  # ── iOS device-specific build helpers (Phase 2 iter 13c) ─────────────────────
  # Mirror the iOS-sim helpers above, with iphoneos SDK + arm64 single-arch +
  # static-NIF (.a) packaging. Only the divergent steps live here; the rest
  # (compile_elixir_for_ios, copy_app_beams, install_exqlite_otp_lib,
  # maybe_install_crypto_shim, maybe_build_phoenix_assets, copy_priv_repo_assets,
  # copy_elixir_stdlib_to_otp, copy_eex_stdlib_to_app, generate_enif_keepalive,
  # spot_check_app_beams) are shared.

  defp cross_compile_exqlite_nif_device(otp_root, erts_vsn, sdkroot) do
    if File.dir?("deps/exqlite/c_src") do
      vsn = detect_dep_version("exqlite")
      out_a = Path.join([otp_root, "lib/exqlite-#{vsn}/priv/sqlite3_nif.a"])
      IO.puts("  === Building sqlite3_nif.a (static NIF for iOS device)")

      build_dir_tmp =
        Path.join(System.tmp_dir!(), "mob_exqlite_#{System.unique_integer([:positive])}")

      File.mkdir_p!(build_dir_tmp)
      nif_o = Path.join(build_dir_tmp, "sqlite3_nif.o")
      sqlite_o = Path.join(build_dir_tmp, "sqlite3.o")

      common_cc = [
        "-arch",
        "arm64",
        "-miphoneos-version-min=17.0",
        "-isysroot",
        sdkroot,
        "-Os",
        "-ffunction-sections",
        "-fdata-sections"
      ]

      with :ok <-
             run_cc(
               common_cc ++
                 [
                   "-I",
                   "deps/exqlite/c_src",
                   "-I",
                   "#{otp_root}/#{erts_vsn}/include",
                   "-I",
                   "#{otp_root}/#{erts_vsn}/include/internal",
                   "-DSQLITE_THREADSAFE=1",
                   "-DSTATIC_ERLANG_NIF_LIBNAME=sqlite3_nif",
                   "-Wno-#warnings",
                   "-c",
                   "deps/exqlite/c_src/sqlite3_nif.c",
                   "-o",
                   nif_o
                 ]
             ),
           :ok <-
             run_cc(
               common_cc ++
                 [
                   "-I",
                   "deps/exqlite/c_src",
                   "-DSQLITE_THREADSAFE=1",
                   "-Wno-#warnings",
                   "-c",
                   "deps/exqlite/c_src/sqlite3.c",
                   "-o",
                   sqlite_o
                 ]
             ),
           :ok <- run_ar(["rcs", out_a, nif_o, sqlite_o]) do
        File.rm_rf!(build_dir_tmp)
        :ok
      end
    else
      :ok
    end
  end

  defp run_cc(args) do
    case System.cmd("xcrun", ["cc" | args], stderr_to_stdout: true, into: IO.stream()) do
      {_, 0} -> :ok
      {_, _} -> {:error, "iOS device cc failed"}
    end
  end

  defp run_ar(args) do
    case System.cmd("xcrun", ["ar" | args], stderr_to_stdout: true, into: IO.stream()) do
      {_, 0} -> :ok
      {_, _} -> {:error, "iOS device ar failed"}
    end
  end

  defp maybe_setup_pythonx_device(_otp_root, _erts_vsn, _sdkroot, nil, _app_module), do: :ok

  defp maybe_setup_pythonx_device(otp_root, erts_vsn, sdkroot, python_bundle, app_module) do
    if File.dir?("_build/dev/lib/pythonx") do
      pythonx_vsn = detect_dep_version("pythonx")
      pythonx_lib_dir = Path.join([otp_root, "lib", "pythonx-#{pythonx_vsn}"])
      beams_dir = Path.join(otp_root, app_module)

      IO.puts("  === Installing pythonx as OTP library")
      File.rm_rf!(Path.join(otp_root, "lib/pythonx-"))
      File.mkdir_p!(Path.join(pythonx_lib_dir, "ebin"))
      File.mkdir_p!(Path.join(pythonx_lib_dir, "priv"))

      pythonx_ebin = Path.join(["_build", "dev", "lib", "pythonx", "ebin"])

      Path.wildcard("#{pythonx_ebin}/*.beam")
      |> Enum.each(&File.cp!(&1, Path.join([pythonx_lib_dir, "ebin", Path.basename(&1)])))

      pythonx_app = Path.join(pythonx_ebin, "pythonx.app")

      if File.exists?(pythonx_app),
        do: File.cp!(pythonx_app, Path.join([pythonx_lib_dir, "ebin", "pythonx.app"]))

      # Mirror beams into the app's flat -pa dir so module load works
      # without -boot-time path negotiation.
      Path.wildcard("#{pythonx_ebin}/*")
      |> Enum.each(fn src ->
        if not File.dir?(src),
          do: File.cp!(src, Path.join(beams_dir, Path.basename(src)))
      end)

      fine_ebin = "_build/dev/lib/fine/ebin"

      if File.dir?(fine_ebin) do
        Path.wildcard("#{fine_ebin}/*")
        |> Enum.each(fn src ->
          if not File.dir?(src),
            do: File.cp!(src, Path.join(beams_dir, Path.basename(src)))
        end)
      end

      framework = Path.join(python_bundle, "Python.xcframework/ios-arm64/Python.framework")
      stdlib = Path.join(python_bundle, "Python.xcframework/lib/python3.13")

      lib_dynload =
        Path.join(python_bundle, "Python.xcframework/ios-arm64/lib-arm64/python3.13/lib-dynload")

      cond do
        not File.dir?(framework) ->
          {:error, "Python.framework missing at #{framework}"}

        not File.dir?(stdlib) ->
          {:error, "Python stdlib missing at #{stdlib}"}

        not File.dir?(lib_dynload) ->
          {:error, "lib-dynload missing at #{lib_dynload}"}

        true ->
          IO.puts("  === Cross-compiling libpythonx.so for iOS device (iphoneos arm64)")

          out_so = Path.join([pythonx_lib_dir, "priv", "libpythonx.so"])

          xcrun_args = [
            "-sdk",
            "iphoneos",
            "clang++",
            "-arch",
            "arm64",
            "-dynamiclib",
            "-undefined",
            "dynamic_lookup",
            "-fPIC",
            "-fvisibility=hidden",
            "-std=c++17",
            "-isysroot",
            sdkroot,
            "-miphoneos-version-min=17.0",
            "-install_name",
            "@rpath/libpythonx.so",
            "-Os",
            "-ffunction-sections",
            "-fdata-sections",
            "-I",
            "#{otp_root}/#{erts_vsn}/include",
            "-I",
            "#{otp_root}/#{erts_vsn}/include/internal",
            "-I",
            "deps/fine/c_include",
            "-Wno-unused-parameter",
            "-Wno-comment",
            "deps/pythonx/c_src/pythonx.cpp",
            "deps/pythonx/c_src/python.cpp",
            "-o",
            out_so
          ]

          with {_, 0} <-
                 System.cmd("xcrun", xcrun_args, stderr_to_stdout: true, into: IO.stream()) do
            IO.puts("  === Bundling Python.framework + stdlib + lib-dynload (device arch)")
            python_dst = Path.join(otp_root, "python")
            File.mkdir_p!(Path.join(python_dst, "lib"))
            chmod_writable(python_dst)

            File.rm_rf!(Path.join(python_dst, "Python.framework"))
            File.rm_rf!(Path.join(python_dst, "lib/python3.13"))

            cp_r!(framework, Path.join(python_dst, "Python.framework"))
            cp_r!(stdlib, Path.join(python_dst, "lib/python3.13"))
            cp_r!(lib_dynload, Path.join(python_dst, "lib/python3.13/lib-dynload"))
            # Project-supplied wheels into site-packages — mirrors Android's
            # ensure_python_android_libs path and the sim path above. Without
            # this, real-device Python apps boot and hang on `import RNS`
            # because `priv/python_wheels/` never landed in the .app bundle.
            # See nif_future.md item #4. The ios-safe variant filters
            # wheels with Android-only `.so` extensions.
            copy_ios_safe_project_python_wheels(
              python_dst,
              Path.join("priv", "python_wheels")
            )

            :ok
          else
            _ -> {:error, "pythonx NIF cross-compile failed"}
          end
      end
    else
      IO.puts("  === pythonx not in project — skipping CPython bundle")
      :ok
    end
  end

  defp cp_r!(src, dst) do
    {_, 0} =
      System.cmd("cp", ["-R", src, dst], stderr_to_stdout: true, into: IO.stream())

    :ok
  end

  defp maybe_install_ssl_shim(otp_root, app_module) do
    if liveview_project?() do
      IO.puts("  === Creating ssl shim (LV)")
      ssl_tmp = Path.join(System.tmp_dir!(), "mob_ssl_#{System.unique_integer([:positive])}")
      File.mkdir_p!(ssl_tmp)
      beams_dir = Path.join(otp_root, app_module)

      try do
        File.write!(Path.join(ssl_tmp, "ssl.erl"), ssl_shim_erl())

        case System.cmd("erlc", ["-o", beams_dir, Path.join(ssl_tmp, "ssl.erl")],
               stderr_to_stdout: true,
               into: IO.stream()
             ) do
          {_, 0} ->
            File.write!(Path.join(beams_dir, "ssl.app"), ssl_shim_app())
            :ok

          {_, _} ->
            {:error, "ssl shim erlc failed"}
        end
      after
        File.rm_rf!(ssl_tmp)
      end
    else
      :ok
    end
  end

  defp ssl_shim_erl do
    """
    -module(ssl).
    -behaviour(application).
    -export([start/2, stop/1, start/0, stop/0,
             connect/3, connect/4, connect/5,
             listen/2, accept/2, accept/3,
             close/1, send/2, recv/2, recv/3,
             controlling_process/2, getopts/2, setopts/2,
             peername/1, sockname/1, peercert/1,
             negotiated_protocol/1, cipher_suites/0,
             cipher_suites/2, cipher_suites/3,
             versions/0, format_error/1,
             clear_pem_cache/0, handshake/1, handshake/2, handshake/3,
             handshake_continue/2, handshake_continue/3,
             handshake_cancel/1, shutdown/2,
             transport_info/1, connection_information/1,
             connection_information/2]).
    start(_Type, _Args) ->
        Pid = spawn(fun() -> receive stop -> ok end end),
        {ok, Pid}.
    stop(_State) -> ok.
    start() -> ok.
    stop() -> ok.
    connect(_, _, _) -> {error, ssl_not_supported}.
    connect(_, _, _, _) -> {error, ssl_not_supported}.
    connect(_, _, _, _, _) -> {error, ssl_not_supported}.
    listen(_, _) -> {error, ssl_not_supported}.
    accept(_, _) -> {error, ssl_not_supported}.
    accept(_, _, _) -> {error, ssl_not_supported}.
    close(_) -> ok.
    send(_, _) -> {error, closed}.
    recv(_, _) -> {error, closed}.
    recv(_, _, _) -> {error, closed}.
    controlling_process(_, _) -> ok.
    getopts(_, _) -> {ok, []}.
    setopts(_, _) -> ok.
    peername(_) -> {error, ssl_not_supported}.
    sockname(_) -> {error, ssl_not_supported}.
    peercert(_) -> {error, ssl_not_supported}.
    negotiated_protocol(_) -> {error, ssl_not_supported}.
    cipher_suites() -> [].
    cipher_suites(_, _) -> [].
    cipher_suites(_, _, _) -> [].
    versions() -> [].
    format_error(_) -> "ssl not available on iOS (HTTP-only)".
    clear_pem_cache() -> ok.
    handshake(_) -> {error, ssl_not_supported}.
    handshake(_, _) -> {error, ssl_not_supported}.
    handshake(_, _, _) -> {error, ssl_not_supported}.
    handshake_continue(_, _) -> {error, ssl_not_supported}.
    handshake_continue(_, _, _) -> {error, ssl_not_supported}.
    handshake_cancel(_) -> ok.
    shutdown(_, _) -> ok.
    transport_info(_) -> {error, ssl_not_supported}.
    connection_information(_) -> {error, ssl_not_supported}.
    connection_information(_, _) -> {error, ssl_not_supported}.
    """
  end

  defp ssl_shim_app do
    ~S|{application,ssl,[{modules,[ssl]},{applications,[kernel,stdlib,crypto,public_key]},{description,"SSL shim for iOS (HTTP-only)"},{registered,[]},{vsn,"11.2"},{mod,{ssl,[]}}]}.| <>
      "\n"
  end

  defp copy_otp_libs_for_phoenix(otp_root) do
    IO.puts("  === Copying OTP standard libraries (Phoenix deps)")
    # Phoenix and its deps require runtime_tools (extra_applications),
    # asn1 (public_key dep), and public_key (cookie/cert infra). The Mob
    # iOS-device tarball does not bundle these; copy from the host.
    for app <- ~w(runtime_tools asn1 public_key) do
      case :code.lib_dir(String.to_atom(app)) do
        src when is_list(src) ->
          src_dir = to_string(src)
          ebin = Path.join(src_dir, "ebin")

          if File.dir?(ebin) do
            vsn_dir = Path.basename(src_dir)
            dst_ebin = Path.join([otp_root, "lib", vsn_dir, "ebin"])
            File.mkdir_p!(dst_ebin)

            Path.wildcard("#{ebin}/*.beam")
            |> Enum.each(&File.cp!(&1, Path.join(dst_ebin, Path.basename(&1))))

            app_file = Path.join(ebin, "#{app}.app")
            if File.exists?(app_file), do: File.cp!(app_file, Path.join(dst_ebin, "#{app}.app"))
            IO.puts("  + #{vsn_dir}")
          else
            IO.puts("  ! #{app} not found on host — skipping")
          end

        _ ->
          IO.puts("  ! #{app} not found on host — skipping")
      end
    end

    :ok
  end

  defp install_app_in_otp_lib(otp_root, app_module) do
    # Plug.Static (from: :app_name) resolves the priv dir via code:lib_dir/1,
    # which requires a code-path entry named "app_name-vsn" (not just
    # "app_name"). Install the app into $OTP_ROOT/lib/<app>-<vsn>/ alongside
    # runtime_tools, asn1, etc.
    beams_dir = Path.join(otp_root, app_module)
    app_file = Path.join(beams_dir, "#{app_module}.app")

    case File.read(app_file) do
      {:ok, content} ->
        case Regex.run(~r/\{vsn,\s*"([^"]+)"\}/, content) do
          [_, vsn] ->
            IO.puts("  === Installing app into OTP lib/ (required for code:priv_dir)")
            app_lib_dir = Path.join([otp_root, "lib", "#{app_module}-#{vsn}"])
            File.rm_rf!(app_lib_dir)
            File.mkdir_p!(Path.join(app_lib_dir, "ebin"))
            File.cp!(app_file, Path.join([app_lib_dir, "ebin", "#{app_module}.app"]))

            priv_src = Path.join(beams_dir, "priv")

            if File.dir?(priv_src) do
              File.mkdir_p!(Path.join(app_lib_dir, "priv"))
              copy_dir!(priv_src <> "/.", Path.join(app_lib_dir, "priv"))
            end

            IO.puts("  + #{app_module}-#{vsn}")
            :ok

          _ ->
            IO.puts("  ! Could not read version — code:priv_dir(:#{app_module}) may not work")
            :ok
        end

      _ ->
        :ok
    end
  end

  defp copy_mob_logos_to_otp_root(mob_dir, otp_root) do
    IO.puts("  === Copying logos")

    for variant <- ~w(dark light) do
      src = Path.join(mob_dir, "assets/logo/logo_#{variant}.png")
      dst = Path.join(otp_root, "mob_logo_#{variant}.png")
      if File.exists?(src), do: File.cp!(src, dst)
    end

    :ok
  end

  defp patch_epmd_source(epmd_build_src) do
    # Stock OTP epmd.c calls `run_daemon(g)` unconditionally inside
    # `if (g->is_daemon)`. With -DNO_DAEMON the function body is stripped
    # but the call site still references the symbol, so the link fails
    # with "Undefined symbols: _run_daemon". Idempotent inline patch wraps
    # the call in `#ifndef NO_DAEMON` so both halves go away together.
    epmd_c = Path.join([epmd_build_src, "erts/epmd/src/epmd.c"])

    cond do
      not File.exists?(epmd_c) ->
        :ok

      File.read!(epmd_c) =~ "ifndef NO_DAEMON" ->
        :ok

      true ->
        IO.puts("  patching #{epmd_c} (NO_DAEMON guard around run_daemon call)")
        original = File.read!(epmd_c)

        # Match the exact signature from the OTP source.
        pattern = ~r/(    if \(g->is_daemon\)  \{\n)(\trun_daemon\(g\);\n)(    \} else \{\n)/

        case Regex.replace(pattern, original, "\\1#ifndef NO_DAEMON\n\\2#endif\n\\3",
               global: false
             ) do
          ^original ->
            {:error, "epmd.c patch pattern did not match — manual fix required"}

          patched ->
            File.write!(epmd_c, patched)
            :ok
        end
    end
  end

  @doc false
  # `def` (not `defp`) so the test suite can pin the contract. This shim
  # has been mistakenly removed before — the test exists to flag the
  # next attempt as a test failure rather than an iOS device link
  # failure.
  #
  # erl_errno_id_unknown is missing from libbeam.a in the iOS-device OTP
  # tarball — it's referenced only by erl_posix_str.o (the legacy
  # implementation), which the linker pulls in because it comes before
  # the newer erl_errno_str.o in the archive's `ar` index AND because
  # the iOS BEAM startup path (mob_beam.m) doesn't reference
  # erts_errno_init, so erl_errno_str.o is never pulled in to provide
  # the symbol the modern way. Net: legacy file wins, needs the
  # `_unknown` helper, we provide it weakly here. A weak definition
  # loses to the real symbol if a future tarball includes it.
  #
  # The iOS-sim and Android tarballs don't have erl_posix_str.o at all
  # (only erl_errno_str.o) and don't need this shim. If the iOS-device
  # OTP tarball is ever rebuilt without erl_posix_str.c (matching the
  # sim/Android configs), this shim becomes obsolete — but verify with
  # `nm libbeam.a | grep erl_errno_id_unknown` first; the iOS-device
  # link surfaces the regression as
  # `Undefined symbols: _erl_errno_id_unknown`.
  # Visible to tests; private callers can pretend `defp`.
  @spec project_nif_user_entries() :: [MobDev.StaticNifs.nif_entry()]
  def project_nif_user_entries do
    default_modules =
      MobDev.StaticNifs.default_nifs() |> MapSet.new(& &1.module)

    Mix.Tasks.Mob.RegenDriverTab.resolved_nifs()
    |> Enum.reject(fn entry -> MapSet.member?(default_modules, entry.module) end)
  end

  @spec classify_project_nif(MobDev.StaticNifs.nif_entry()) ::
          {:c, Path.t()} | {:rust, Path.t()} | {:zig, atom()} | :elixir_only
  def classify_project_nif(entry), do: classify_project_nif(entry, File.cwd!())

  @doc false
  @spec classify_project_nif(MobDev.StaticNifs.nif_entry(), Path.t()) ::
          {:c, Path.t()} | {:rust, Path.t()} | {:zig, atom()} | :elixir_only
  def classify_project_nif(entry, project_root) do
    name = to_string(entry.module)
    c_src = Path.join(project_root, "c_src/#{name}.c")
    rust_manifest = Path.join(project_root, "native/#{name}/Cargo.toml")

    cond do
      # C wins if both exist — the user has explicitly written C.
      File.exists?(c_src) -> {:c, c_src}
      File.exists?(rust_manifest) -> {:rust, rust_manifest}
      true -> classify_via_zig_stub(name, project_root)
    end
  end

  # Detect Zigler-backed NIFs by `use Zig` in the generated stub.
  # `mob.add_nif --type zigler` puts the stub at `lib/<app>/nifs/<name>.ex`.
  # If it contains `use Zig,`, treat the NIF as Zigler-backed and record
  # the BEAM module atom (needed for `Zig.Builder.staging_directory/1`).
  defp classify_via_zig_stub(name, project_root) do
    app =
      case Application.fetch_env(:mob_dev, :__app_name__) do
        {:ok, app} -> app
        :error -> Mix.Project.config() |> Keyword.get(:app)
      end

    if is_nil(app) do
      :elixir_only
    else
      stub = Path.join(project_root, "lib/#{app}/nifs/#{name}.ex")

      if File.exists?(stub) and File.read!(stub) =~ ~r/use\s+Zig\b/ do
        # Module follows the resolve_module/3 convention in mob.add_nif:
        # <AppCamel>.Nifs.<NameCamel>
        camel = app |> to_string() |> Macro.camelize()
        nif_camel = name |> Macro.camelize()
        {:zig, Module.concat([camel, "Nifs", nif_camel])}
      else
        :elixir_only
      end
    end
  end

  # Build args to pass to `zig build`. Returns
  # `{:ok, ["-Dproject_c_nifs=…", "-Dproject_rust_libs=…", "-Dproject_root=…"]}`
  # or `{:error, reason}` if a Rust cross-compile fails.
  @spec project_nif_zig_args(
          :ios_device
          | :ios_sim
          | :android_arm64
          | :android_arm32
          | :android_x86_64
        ) ::
          {:ok, [String.t()]} | {:error, String.t()}
  @doc false
  def project_nif_zig_args(platform) do
    project_root = File.cwd!()
    # Respect each entry's `:archs` field — a NIF with
    # `archs: [:ios]` (in mob.exs `:static_nifs`) should be skipped on
    # the Android build path entirely (and vice versa), and a NIF with
    # `archs: [:android_arm64]` should only land in the arm64 build,
    # not the armv7 one. The driver_tab generator already honours this
    # via `on_platform?/2`; the cross-compile path now does too. Maps
    # the mob_dev build atom → the StaticNifs arch atom that
    # `on_platform?/2` understands.
    target_arch =
      case platform do
        p when p in [:ios_device, :ios_sim] -> p
        :android_arm64 -> :android_arm64
        :android_arm32 -> :android_arm32
        :android_x86_64 -> :android
      end

    entries =
      project_nif_user_entries()
      |> Enum.filter(&MobDev.StaticNifs.on_platform?(&1, target_arch))

    {c_names, rust_manifests, zig_modules} =
      Enum.reduce(entries, {[], [], []}, fn entry, {c_acc, rust_acc, zig_acc} ->
        case classify_project_nif(entry, project_root) do
          {:c, _path} ->
            {[to_string(entry.module) | c_acc], rust_acc, zig_acc}

          {:rust, manifest} ->
            {c_acc, [{to_string(entry.module), manifest} | rust_acc], zig_acc}

          {:zig, module} ->
            {c_acc, rust_acc, [{to_string(entry.module), module} | zig_acc]}

          :elixir_only ->
            {c_acc, rust_acc, zig_acc}
        end
      end)

    # Per-ABI external static archives declared via `:extra_static_libs` on the
    # already platform-filtered entries. These resolve a project NIF's `extern`
    # symbols at the app link without making the host-rendered NIF link against
    # an archive for the wrong architecture.
    extra_static_libs =
      Enum.flat_map(entries, fn entry ->
        case entry |> Map.get(:extra_static_libs, %{}) |> Map.get(platform) do
          nil -> []
          path -> [Path.expand(path, project_root)]
        end
      end)

    nif_static_flags =
      for entry <- entries, Map.has_key?(entry, :guard), do: "-D#{entry.module}_static=true"

    with {:ok, rust_libs} <- cross_compile_rust_nifs(rust_manifests, platform),
         {:ok, zig_libs} <- cross_compile_zig_nifs(zig_modules, platform) do
      # Pass both Rust and Zig static archives via the same flag
      # (they go to the same linker step). Name kept legacy-flavored
      # for the build template's existing consumer; sweep up later.
      static_libs = Enum.reverse(rust_libs) ++ Enum.reverse(zig_libs) ++ extra_static_libs

      {:ok,
       [
         "-Dproject_root=#{project_root}",
         "-Dproject_c_nifs=#{Enum.join(Enum.reverse(c_names), ",")}",
         "-Dproject_rust_libs=#{Enum.join(static_libs, ",")}"
       ] ++ nif_static_flags}
    end
  end

  @spec cross_compile_rust_nifs([{String.t(), Path.t()}], atom()) ::
          {:ok, [Path.t()]} | {:error, String.t()}
  defp cross_compile_rust_nifs([], _platform), do: {:ok, []}

  defp cross_compile_rust_nifs(manifests, platform) do
    target = rust_target_for(platform)

    Enum.reduce_while(manifests, {:ok, []}, fn {name, manifest}, {:ok, acc} ->
      case cross_compile_rust_nif(name, manifest, target) do
        {:ok, a_path} -> {:cont, {:ok, [a_path | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp cross_compile_rust_nif(name, manifest, target) do
    Mix.shell().info("  === Cross-compiling Rust NIF #{name} for #{target}")

    args = [
      "rustc",
      "--release",
      "--target",
      target,
      "--crate-type",
      "staticlib",
      "--manifest-path",
      manifest
    ]

    case System.cmd("cargo", args, stderr_to_stdout: true, into: IO.stream()) do
      {_, 0} ->
        a = Path.expand("native/#{name}/target/#{target}/release/lib#{name}.a")

        if File.exists?(a) do
          {:ok, a}
        else
          {:error,
           "cargo rustc for '#{name}' succeeded but #{a} not found — " <>
             "check that the crate-type includes staticlib"}
        end

      {_, code} ->
        {:error,
         "cargo rustc for Rust NIF '#{name}' (target=#{target}) exited #{code}.\n" <>
           "  Common causes:\n" <>
           "    1. `rustup target add #{target}` not run — check `rustup target list --installed`.\n" <>
           "    2. Cargo.toml's [lib] crate-type doesn't include \"staticlib\".\n" <>
           "    3. The Rust source has a compile error — see the cargo output above."}
    end
  end

  # Apple toolchains differ between simulator and device targets. Both
  # are arm64 on Apple Silicon Macs; sim has the `-sim` suffix because
  # the SDK headers differ. Android splits per-ABI: arm64-v8a uses
  # `aarch64-linux-android`; armeabi-v7a uses `armv7-linux-androideabi`.
  defp rust_target_for(:ios_device), do: "aarch64-apple-ios"
  defp rust_target_for(:ios_sim), do: "aarch64-apple-ios-sim"
  defp rust_target_for(:android_arm64), do: "aarch64-linux-android"
  defp rust_target_for(:android_arm32), do: "armv7-linux-androideabi"
  defp rust_target_for(:android_x86_64), do: "x86_64-linux-android"

  # ── Zigler cross-compile (issue #15 final piece) ─────────────────────────

  @spec cross_compile_zig_nifs([{String.t(), module()}], atom()) ::
          {:ok, [Path.t()]} | {:error, String.t()}
  defp cross_compile_zig_nifs([], _platform), do: {:ok, []}

  defp cross_compile_zig_nifs(zig_modules, platform) do
    target = zig_build_target_for(platform)

    with {:ok, sdkroot_args} <- sdkroot_args_for(platform) do
      Enum.reduce_while(zig_modules, {:ok, []}, fn {name, module}, {:ok, acc} ->
        case cross_compile_zig_nif(name, module, target, sdkroot_args) do
          {:ok, a_path} -> {:cont, {:ok, [a_path | acc]}}
          {:error, _} = err -> {:halt, err}
        end
      end)
    end
  end

  # Resolve the SDK / NDK sysroot that Zigler's cImport-bearing
  # modules need when cross-compiling. Returns the list of `-D...=`
  # args to append to `zig build` (empty list for desktop builds
  # where Zig's host libc headers cover everything).
  #
  # * iOS device/sim — need Apple SDK for `<sys/types.h>` etc.
  # * Android — need NDK sysroot; Zig 0.16's bundled libc for the
  #   `aarch64-linux-android` target doesn't ship `<sys/types.h>`,
  #   so erl_nif.h's transitive cImport fails without this.
  defp sdkroot_args_for(:ios_device) do
    with {:ok, path} <- xcrun_sdk_path("iphoneos") do
      {:ok, ["-Dapple_sdkroot=#{path}"]}
    end
  end

  defp sdkroot_args_for(:ios_sim) do
    with {:ok, path} <- xcrun_sdk_path("iphonesimulator") do
      {:ok, ["-Dapple_sdkroot=#{path}"]}
    end
  end

  defp sdkroot_args_for(:android_arm64), do: {:ok, ["-Dandroid_sdkroot=#{ndk_sysroot()}"]}
  defp sdkroot_args_for(:android_arm32), do: {:ok, ["-Dandroid_sdkroot=#{ndk_sysroot()}"]}
  defp sdkroot_args_for(:android_x86_64), do: {:ok, ["-Dandroid_sdkroot=#{ndk_sysroot()}"]}

  # Drives Zigler's build pipeline a SECOND time against the staging
  # directory (which Zigler set up during the normal `mix compile` host
  # build), with the static-link + alias options the GenericJam/zigler
  # fork added. Produces `libElixir.<Module>.a` in `zig-out/lib/` of
  # the staging dir, suitable for linking into the iOS device binary.
  defp cross_compile_zig_nif(name, module, target, sdkroot_args) do
    # Resolve `Zig.Builder` dynamically — it only exists when the
    # consuming project has `:zigler` as a dep. mob_dev itself doesn't
    # depend on Zigler, so a static `Zig.Builder.staging_directory/1`
    # reference would emit an "undefined module" warning at compile
    # time and refuse `--warnings-as-errors`.
    builder = Module.concat([:Zig, :Builder])

    staging_dir =
      if Code.ensure_loaded?(builder) and
           function_exported?(builder, :staging_directory, 1) do
        builder.staging_directory(module)
      end

    cond do
      is_nil(staging_dir) ->
        {:error,
         "Zigler not loaded — can't cross-compile NIF '#{name}'. " <>
           "Is `:zigler` in the project's deps?"}

      not File.dir?(staging_dir) ->
        {:error,
         "Zigler staging dir missing for '#{name}': #{staging_dir}\n" <>
           "  Has `mix compile` run yet? The host build sets up the staging dir."}

      true ->
        Mix.shell().info("  === Cross-compiling Zig NIF #{name} for #{target}")

        # Resolve Zig via Zigler's own lookup (cache → ZIG_ARCHIVE_PATH
        # → PATH) instead of `System.find_executable("zig")`. mob_dev
        # users typically have a different Zig on PATH (mob's own
        # pin) than the one Zigler 0.15.x expects (0.16 from
        # the user cache). Hard-coding to PATH would pick the wrong
        # version and break the build.
        zig_cmd = Module.concat([:Zig, :Command])

        zig_exe =
          if Code.ensure_loaded?(zig_cmd) and
               function_exported?(zig_cmd, :executable_path, 0) do
            zig_cmd.executable_path()
          else
            "zig"
          end

        # `-Dtarget=...` is consumed by zig's `standardTargetOptions`
        # at build time — overrides whatever the rendered build.zig
        # had as its default. We can't use Zigler's TARGET_ARCH/OS/ABI
        # env vars here because the staging build.zig was already
        # rendered during the host `mix compile` (with default target).
        #
        # `--prefix zig-out-<target>` keeps per-target outputs in
        # separate directories so running this twice (Android arm64
        # + armv7) doesn't overwrite the first build's archive — the
        # default `zig-out/` would clobber on the second invocation.
        prefix = "zig-out-#{target}"
        path_args = zigler_build_path_args(module, staging_dir)

        args =
          [
            "build",
            "-Dtarget=#{target}",
            "-Dnif_linkage=static",
            "-Dnif_init_alias=#{name}_nif_init",
            "--prefix",
            prefix
          ] ++ path_args ++ sdkroot_args

        case System.cmd(zig_exe, args,
               cd: staging_dir,
               stderr_to_stdout: true,
               into: IO.stream()
             ) do
          {_, 0} ->
            # Zigler names the output `libElixir.<Module>.a`.
            a = Path.join([staging_dir, "#{prefix}/lib/libElixir.#{module_basename(module)}.a"])

            cond do
              not File.exists?(a) ->
                {:error,
                 "zig build for '#{name}' succeeded but #{a} not found — " <>
                   "did Zigler change its output naming?"}

              # Apple ld64 requires .a archive members to be 8-byte
              # aligned. Zig 0.16's archive output isn't aligned and
              # ld64 rejects it with "not 8-byte aligned". Re-archive
              # with xcrun ar to produce a Mach-O-compatible static
              # library. macOS's `ar` doesn't understand ELF archives
              # (Zig's Android output) — running it against an ELF .a
              # extracts zero members and the rearchive errors with
              # "ar: no archive members specified". The NDK linker
              # accepts Zig's archive directly, so skip the rearchive
              # for non-Apple targets.
              String.contains?(target, "-ios") ->
                case rearchive_for_apple_ld(a) do
                  :ok -> {:ok, a}
                  {:error, _} = err -> err
                end

              :else ->
                {:ok, a}
            end

          {_, code} ->
            {:error, "zig build for Zig NIF '#{name}' exited #{code}"}
        end
    end
  end

  defp zigler_build_path_args(module, staging_dir) do
    erts_include =
      Path.join([:code.root_dir(), "erts-#{:erlang.system_info(:version)}", "include"])

    zigler_priv = :zigler |> :code.priv_dir() |> to_string()
    erl_nif_win_path = Path.join(zigler_priv, "erl_nif_win")

    erl_nif_header =
      if :os.type() == {:win32, :nt},
        do: Path.join(erl_nif_win_path, "erl_nif_win.h"),
        else: Path.join(erts_include, "erl_nif.h")

    module_root = zigler_module_root(module, staging_dir)

    [
      "-Derts_include=#{erts_include}",
      "-Derl_nif_header=#{erl_nif_header}",
      "-Derl_nif_win_path=#{erl_nif_win_path}",
      "-Dzigler_priv=#{zigler_priv}",
      "-Dmodule_root=#{module_root}"
    ]
  end

  defp zigler_module_root(module, staging_dir) do
    build_zig = Path.join(staging_dir, "build.zig")

    with {:ok, source} <- File.read(build_zig),
         [_match, basename] <- Regex.run(~r/&\.\{\s*module_root,\s*"([^"]+)"\s*\}/, source),
         [path | _] <- Path.wildcard(Path.join(File.cwd!(), "**/#{basename}"), match_dot: true) do
      Path.dirname(path)
    else
      _ -> module_source_root(module)
    end
  end

  defp module_source_root(module) do
    module.module_info(:compile)
    |> Keyword.fetch!(:source)
    |> to_string()
    |> Path.dirname()
  end

  # Re-archives a Zig-built `.a` using `xcrun ar` so its members are
  # 8-byte aligned (required by Apple's ld64). Extracts the .o members
  # from the existing archive into a temp dir, then re-archives them
  # in-place. Idempotent — calling on an already-aligned archive is fine.
  defp rearchive_for_apple_ld(archive_path) do
    tmp = Path.join(System.tmp_dir!(), "mob_zig_ar_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    try do
      case System.cmd("xcrun", ["ar", "-x", archive_path], cd: tmp, stderr_to_stdout: true) do
        {_, 0} ->
          members =
            tmp
            |> File.ls!()
            |> Enum.reject(&String.starts_with?(&1, "__."))

          # File perms on extracted members can be 000; chmod to readable.
          Enum.each(members, fn m -> File.chmod!(Path.join(tmp, m), 0o644) end)

          case System.cmd("xcrun", ["ar", "rcs", archive_path | members],
                 cd: tmp,
                 stderr_to_stdout: true
               ) do
            {_, 0} -> :ok
            {out, code} -> {:error, "xcrun ar rcs failed (#{code}): #{out}"}
          end

        {out, code} ->
          {:error, "xcrun ar -x failed (#{code}): #{out}"}
      end
    after
      File.rm_rf!(tmp)
    end
  end

  defp module_basename(module) do
    module |> Module.split() |> Enum.join(".")
  end

  # Zig target triples passed to `-Dtarget=...`. iOS device + sim
  # differ via the `.simulator` ABI suffix.
  defp zig_build_target_for(:ios_device), do: "aarch64-ios-none"
  defp zig_build_target_for(:ios_sim), do: "aarch64-ios-simulator"
  defp zig_build_target_for(:android_arm64), do: "aarch64-linux-android"
  # Zig's armv7-android triple uses `arm-linux-androideabi`; the
  # `androideabi` ABI marker matches Rust's `armv7-linux-androideabi`
  # for ELF-level compatibility when both libs land in the same .so.
  defp zig_build_target_for(:android_arm32), do: "arm-linux-androideabi"
  defp zig_build_target_for(:android_x86_64), do: "x86_64-linux-android"

  @spec generate_erl_errno_compat_stub(Path.t()) :: :ok
  def generate_erl_errno_compat_stub(build_dir) do
    File.write!(
      Path.join(build_dir, "erl_errno_id_compat.c"),
      """
      __attribute__((weak)) const char *erl_errno_id_unknown(int error) {
          (void)error;
          return "unknown";
      }
      """
    )

    :ok
  end

  defp zig_build_binary_ios_device(
         mob_dir,
         otp_root,
         erts_vsn,
         otp_release,
         sdkroot,
         epmd_build_src,
         build_dir,
         display_name,
         project_swift_sources,
         sqlite_static_lib,
         mlx_dir,
         nxeigen_archive,
         tflite_build
       ) do
    driver_tab = resolve_driver_tab_ios(mob_dir)

    # Plugin contributions, same as the sim path above.
    activated_plugins = MobDev.Plugin.activated()

    # Capability enforcement — same one-liner the sim path uses. See
    # MOB_PLUGIN_SECURITY.md, Layer 2.
    MobDev.Plugin.Validator.raise_on_capability_drift!(activated_plugins)

    # See sim build for the rationale (MOB-7). A plugin-aware build_device.zig
    # implies an AppDelegate that always calls mob_register_plugins(), so a
    # zero-plugin app still needs the bootstrap; legacy scaffolds get empty flags.
    {plugin_swift_files, plugin_frameworks} =
      ios_plugin_swift_and_frameworks(
        activated_plugins,
        build_dir,
        Path.expand("ios/build_device.zig")
      )

    # Activated plugins' C NIF sources — see the sim build for the full
    # rationale. Same path on device; the iPhone uses build_device.zig.
    plugin_c_nifs = MobDev.Plugin.Merge.nif_sources(activated_plugins, :ios) |> Enum.join(",")

    base_args = [
      "build",
      "binary",
      "--build-file",
      "ios/build_device.zig",
      "-Dmob_dir=#{mob_dir}",
      "-Dotp_root=#{otp_root}",
      "-Derts_vsn=#{erts_vsn}",
      "-Dotp_release=#{otp_release}",
      "-Dsdkroot=#{sdkroot}",
      "-Ddriver_tab=#{driver_tab}",
      "-Denif_keepalive=#{Path.join(build_dir, "enif_keepalive.c")}",
      "-Dproject_ios_dir=#{Path.expand("ios")}",
      "-Dmodule_name=#{display_name}",
      "-Depmd_build_src=#{epmd_build_src}",
      "-Derrno_compat=#{Path.join(build_dir, "erl_errno_id_compat.c")}",
      "-Dproject_swift_sources=#{project_swift_sources}"
    ]

    plugin_args =
      for {name, val} <- [
            {"plugin_swift_files", plugin_swift_files},
            {"plugin_frameworks", plugin_frameworks},
            {"plugin_c_nifs", plugin_c_nifs}
          ],
          val != "",
          do: "-D#{name}=#{val}"

    with {:ok, nif_args} <- project_nif_zig_args(:ios_device),
         {:ok, plugin_archives} <- build_plugin_static_archives(:ios_device, :ios, otp_root) do
      sqlite_args =
        case sqlite_static_lib do
          nil -> []
          path -> ["-Dsqlite_static=true", "-Dsqlite_static_lib=#{path}"]
        end

      args =
        base_args ++
          plugin_args ++
          nif_args ++
          sqlite_args ++
          mlx_zig_args(mlx_dir) ++
          nxeigen_zig_args_ios(nxeigen_archive) ++
          tflite_zig_args_ios(tflite_build) ++
          plugin_static_lib_args(plugin_archives)

      case System.cmd("zig", args, stderr_to_stdout: true, into: IO.stream()) do
        {_, 0} ->
          File.cp!("ios/zig-out/#{display_name}", Path.join(build_dir, display_name))
          :ok

        {_, code} ->
          {:error, "zig build binary (iOS device) exited #{code}"}
      end
    end
  end

  defp xcrun_sdk_path_device do
    case System.cmd("xcrun", ["-sdk", "iphoneos", "--show-sdk-path"], stderr_to_stdout: true) do
      {path, 0} -> {:ok, String.trim(path)}
      {_, _} -> {:error, "xcrun -sdk iphoneos failed — Xcode missing?"}
    end
  end

  defp detect_otp_release(otp_root) do
    releases = Path.join(otp_root, "releases")

    case File.ls(releases) do
      {:ok, entries} ->
        # Plain integer-string filter — avoids a literal `~r` regex
        # because OTP 28.0 trips on `:re.import/1` for module-level
        # compiled regexes. Switch back to `~r/.../` once the
        # project's OTP pin is 28.1+ or ≤ 27.
        entries
        |> Enum.filter(&match?({_, ""}, Integer.parse(&1)))
        |> Enum.sort_by(&String.to_integer/1, :desc)
        |> List.first()

      _ ->
        nil
    end
  end

  # Phase 2 iter 6: Bundle assembly + simctl install moved out of build.sh.
  # The shell script now ends after `zig build binary`; everything below
  # used to live as the `# ── Bundle + install ──` block in ios/build.sh.eex.

  defp ios_display_name do
    Mix.Project.config()
    |> Keyword.fetch!(:app)
    |> Atom.to_string()
    |> Macro.camelize()
  end

  # The user-facing `--device` accepts any case-insensitive prefix of
  # a booted simulator's UDID (e.g. `defd4bdc` for
  # `DEFD4BDC-CA42-4CD2-93A1-62BE425E7A78`). Previously the prefix got
  # passed straight to `xcrun simctl install` which only accepts full
  # UDIDs and refused with `Invalid device: <prefix>`. Resolve to a
  # full UDID via `simctl list devices booted` first.
  defp pick_ios_sim(device_id) do
    case System.cmd("xcrun", ~w(simctl list devices booted -j), stderr_to_stdout: true) do
      {json, 0} ->
        with {:ok, %{"devices" => by_runtime}} <- Jason.decode(json),
             udid when is_binary(udid) <- resolve_booted_udid(by_runtime, device_id) do
          {:ok, udid}
        else
          _ ->
            {:error, sim_lookup_error_message(device_id)}
        end

      _ ->
        {:error, "xcrun simctl list failed — is Xcode installed?"}
    end
  end

  @doc """
  Given the JSON-decoded `xcrun simctl list devices booted -j` result
  and an optional `device_id` (full UDID or any case-insensitive
  prefix of one), return the matching booted simulator's full UDID
  or nil.

  When `device_id` is nil → first booted sim wins.
  When `device_id` is a string → case-insensitive prefix match
  against booted UDIDs. A full UDID matches itself; an 8-char
  prefix matches the corresponding device. Public for testing —
  JSON shape is the contract.
  """
  @spec resolve_booted_udid(map(), String.t() | nil) :: String.t() | nil
  def resolve_booted_udid(by_runtime, device_id) do
    booted_udids =
      by_runtime
      |> Map.values()
      |> List.flatten()
      |> Enum.filter(&match?(%{"state" => "Booted"}, &1))
      |> Enum.map(& &1["udid"])

    case device_id do
      nil ->
        List.first(booted_udids)

      id when is_binary(id) ->
        needle = String.downcase(id)
        Enum.find(booted_udids, fn udid -> String.starts_with?(String.downcase(udid), needle) end)
    end
  end

  defp sim_lookup_error_message(nil),
    do: "No booted simulator. Boot one in Simulator.app or pass `--device <UDID>`."

  defp sim_lookup_error_message(id),
    do:
      "No booted simulator matched `--device #{id}`. " <>
        "Pass a full UDID or a case-insensitive prefix that matches " <>
        "exactly one booted sim. Run `mix mob.devices` to see what's available."

  defp bundle_ios_app(binary_path, display_name) do
    build_dir =
      Path.join(System.tmp_dir!(), "mob_ios_bundle_#{System.unique_integer([:positive])}")

    File.mkdir_p!(build_dir)
    app_path = Path.join(build_dir, "#{display_name}.app")
    File.rm_rf!(app_path)
    File.mkdir_p!(app_path)

    IO.puts("  Building .app bundle at #{app_path}...")
    File.cp!(binary_path, Path.join(app_path, display_name))

    cond do
      not File.exists?("ios/Info.plist") ->
        {:error, "ios/Info.plist not found — required for the .app bundle"}

      true ->
        info_plist = Path.join(app_path, "Info.plist")
        File.cp!("ios/Info.plist", info_plist)
        apply_plugin_plist_keys!(info_plist)
        apply_fonts_to_ios_bundle!(info_plist, app_path)
        if File.dir?("ios/Assets.xcassets/AppIcon.appiconset"), do: compile_ios_icons(app_path)
        {:ok, app_path}
    end
  end

  defp compile_ios_icons(app_path) do
    actool_plist =
      Path.join(System.tmp_dir!(), "mob_actool_#{System.unique_integer([:positive])}.plist")

    # actool can be flaky and is non-critical (the binary still runs without
    # icons compiled — just shows the system default). Mirror the build.sh
    # `2>/dev/null || true` posture so a broken Assets.xcassets doesn't kill
    # an otherwise-successful native build.
    case System.cmd(
           "xcrun",
           [
             "actool",
             "ios/Assets.xcassets",
             "--compile",
             app_path,
             "--platform",
             "iphonesimulator",
             "--minimum-deployment-target",
             "17.0",
             "--app-icon",
             "AppIcon",
             "--output-partial-info-plist",
             actool_plist
           ],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        _ =
          System.cmd(
            "/usr/libexec/PlistBuddy",
            [
              "-c",
              "Merge #{actool_plist}",
              Path.join(app_path, "Info.plist")
            ],
            stderr_to_stdout: true
          )

      _ ->
        :ok
    end

    File.rm(actool_plist)
  end

  defp install_ios_sim(sim_id, app_path) do
    IO.puts("  Installing on simulator #{sim_id}...")

    case System.cmd("xcrun", ["simctl", "install", sim_id, app_path],
           stderr_to_stdout: true,
           into: IO.stream()
         ) do
      {_, 0} -> :ok
      {_, _} -> {:error, "xcrun simctl install failed — check output above"}
    end
  end

  # Physical iOS: compile for device SDK, bundle OTP, sign, install via devicectl.
  # Mirrors the mob_qa build_device.sh approach but driven from mob.exs config.
  #
  # Required mob.exs keys:
  #   ios_team_id        — Apple Developer Team ID (10-char alphanumeric)
  #   ios_sign_identity  — codesign identity string (from `security find-identity -v -p codesigning`)
  #   ios_profile_uuid   — provisioning profile UUID (filename without .mobileprovision)
  #
  # Optional mob.exs key:
  #   ios_epmd_build_src — path to an OTP tree that exposes EPMD source under
  #                        erts/epmd/src/ and iOS headers under erts/include/.
  #                        Defaults to the iOS-device OTP cache, which ships
  #                        these files starting with the post-(c) tarball.
  defp build_ios_physical(cfg, udid) do
    IO.puts("  Building iOS app for physical device #{udid}...")

    with {:ok, cfg} <- check_device_signing_config(cfg),
         {:ok, otp_root} <- MobDev.OtpDownloader.ensure_ios_device(),
         {:ok, python_bundle} <- maybe_ensure_python_bundle(),
         {:ok, mlx_dir} <- maybe_ensure_mlx_dir(:ios_device),
         {:ok, nxeigen_archive} <- maybe_build_nxeigen(:ios_device),
         {:ok, tflite_build} <- maybe_build_tflite(:ios_device),
         {:ok, sdkroot} <- xcrun_sdk_path_device(),
         erts_vsn = detect_erts_vsn(otp_root) || "erts-17.0",
         otp_release = detect_otp_release(otp_root) || "27",
         mob_dir = Path.expand(cfg[:mob_dir]),
         elixir_lib = Path.expand(resolve_elixir_lib(cfg[:elixir_lib])),
         epmd_build_src = cfg[:ios_epmd_build_src] || otp_root,
         app_module = Mix.Project.config() |> Keyword.fetch!(:app) |> Atom.to_string(),
         display_name = ios_display_name(),
         project_swift_sources = project_swift_sources_arg(cfg),
         build_dir =
           Path.join(System.tmp_dir!(), "mob_ios_device_#{System.unique_integer([:positive])}"),
         _ = File.mkdir_p!(build_dir),
         :ok <- compile_elixir_for_ios(),
         :ok <- copy_app_beams(otp_root, app_module),
         :ok <- install_exqlite_otp_lib(otp_root),
         :ok <- cross_compile_exqlite_nif_device(otp_root, erts_vsn, sdkroot),
         :ok <- install_emlx_otp_lib(otp_root),
         :ok <- install_nx_eigen_otp_lib(otp_root),
         {:ok, sqlite_static_lib} = {:ok, sqlite_device_static_path(otp_root)},
         :ok <-
           maybe_setup_pythonx_device(otp_root, erts_vsn, sdkroot, python_bundle, app_module),
         :ok <- maybe_install_crypto_shim(otp_root, app_module),
         :ok <- maybe_install_ssl_shim(otp_root, app_module),
         :ok <- copy_elixir_stdlib_to_otp(elixir_lib, otp_root),
         :ok <- copy_eex_stdlib_to_app(elixir_lib, otp_root, app_module),
         :ok <- copy_otp_libs_for_phoenix(otp_root),
         :ok <- copy_priv_repo_assets(otp_root, app_module),
         :ok <- maybe_build_phoenix_assets(otp_root, app_module),
         :ok <- install_app_in_otp_lib(otp_root, app_module),
         :ok <- copy_mob_logos_to_otp_root(mob_dir, otp_root),
         :ok <- patch_epmd_source(epmd_build_src),
         :ok <- generate_erl_errno_compat_stub(build_dir),
         :ok <- generate_enif_keepalive(otp_root, erts_vsn, build_dir),
         :ok <-
           zig_build_binary_ios_device(
             mob_dir,
             otp_root,
             erts_vsn,
             otp_release,
             sdkroot,
             epmd_build_src,
             build_dir,
             display_name,
             project_swift_sources,
             sqlite_static_lib,
             mlx_dir,
             nxeigen_archive,
             tflite_build
           ),
         binary_path = Path.join(build_dir, display_name),
         :ok <- check_path(binary_path, "iOS device binary"),
         {:ok, app_path} <- bundle_ios_device_app(binary_path, otp_root, cfg, build_dir),
         :ok <-
           copy_tflite_frameworks_ios(
             tflite_build,
             "ios-arm64",
             Path.join(app_path, "Frameworks")
           ),
         :ok <- maybe_slim_otp_bundle(app_path, cfg),
         :ok <- embed_provisioning_profile(app_path, cfg[:ios_profile_uuid]),
         :ok <- codesign_ios_device_app(app_path, cfg, build_dir),
         :ok <- devicectl_install(udid, app_path) do
      {:ok, "iOS (device)"}
    else
      {:error, reason} -> {:error, "iOS", reason}
    end
  end

  defp sqlite_device_static_path(otp_root) do
    case detect_dep_version("exqlite") do
      nil ->
        nil

      vsn ->
        path = Path.join([otp_root, "lib/exqlite-#{vsn}/priv/sqlite3_nif.a"])
        if File.exists?(path), do: path, else: nil
    end
  end

  # Phase 2 iter 12d: bundle + codesign + devicectl install moved out of
  # build_device.sh. The shell script now ends after `zig build binary`
  # produces the Mach-O at MOB_BUILD_DIR/<app_name>; everything below used
  # to live as the `# ── Bundle / Code signing / Installing ──` blocks.

  defp bundle_ios_device_app(binary_path, otp_root, cfg, build_dir) do
    app_name = ios_display_name()
    app_module = Mix.Project.config() |> Keyword.fetch!(:app) |> Atom.to_string()
    bundle_id = cfg[:ios_bundle_id] || cfg[:bundle_id]

    if is_nil(bundle_id), do: throw_bundle_id_error()

    erts_vsn = detect_erts_vsn(otp_root) || "erts-17.0"
    app_path = Path.join(build_dir, "#{app_name}.app")

    IO.puts("  === Building .app bundle at #{app_path}")
    File.rm_rf!(app_path)
    File.mkdir_p!(app_path)
    File.cp!(binary_path, Path.join(app_path, app_name))

    cond do
      not File.exists?("ios/Info.plist") ->
        {:error, "ios/Info.plist not found"}

      true ->
        info_plist = Path.join(app_path, "Info.plist")
        File.cp!("ios/Info.plist", info_plist)
        apply_plugin_plist_keys!(info_plist)
        apply_fonts_to_ios_bundle!(info_plist, app_path)
        plist_set!(info_plist, ":CFBundleIdentifier", bundle_id)
        plist_set!(info_plist, ":CFBundleExecutable", app_name)
        plist_set!(info_plist, ":CFBundleName", app_name)

        if File.dir?("ios/Assets.xcassets/AppIcon.appiconset"),
          do: compile_ios_device_icons(app_path)

        bundle_otp_runtime(app_path, otp_root, app_module, erts_vsn)
        maybe_bundle_mlx_metallib(app_path)
        {:ok, app_path}
    end
  end

  # MLX's Metal backend looks for a colocated `mlx.metallib` next to the
  # running binary (`get_binary_directory()/mlx.metallib`). When mob ships
  # a Metal-enabled MLX bundle the cached MLX_DIR contains a
  # `lib/mlx.metallib` next to the static archives — copy it into the
  # .app bundle alongside the main binary so MLX can find it at runtime.
  # No-op when the bundle is CPU-only (`device: :gpu` then returns the
  # "Cannot get gpu stream" error from EMLX).
  @doc false
  @spec maybe_bundle_mlx_metallib(String.t()) :: :ok
  def maybe_bundle_mlx_metallib(app_path) do
    with {:ok, mlx_dir} <- MobDev.MLXDownloader.ensure_ios_device(),
         src when is_binary(src) <- MobDev.MLXDownloader.metallib_path(mlx_dir) do
      File.cp!(src, Path.join(app_path, "mlx.metallib"))
      IO.puts("  === Copied mlx.metallib (Metal GPU kernels) into .app")
      :ok
    else
      _ -> :ok
    end
  end

  defp plist_set!(plist, key, value) do
    {_, 0} =
      System.cmd("/usr/libexec/PlistBuddy", ["-c", "Set #{key} #{value}", plist],
        stderr_to_stdout: true
      )

    :ok
  end

  # Adds plugin-declared Info.plist keys via PlistBuddy `Add`. Add fails (and is
  # ignored) when the key is already present, giving us "project Info.plist wins
  # on conflict; plugins fill gaps" semantics — so a plugin can ship a default
  # NSCameraUsageDescription that the app author can override in their own
  # Info.plist without changing the plugin. See ADR
  # decisions/2026-05-28-plugin-plist-keys-merge.md.
  defp apply_plugin_plist_keys!(info_plist) do
    activated_plugins = MobDev.Plugin.activated()

    for {key, value} <- MobDev.Plugin.Merge.plist_keys(activated_plugins) do
      cond do
        # Array-valued keys (e.g. UIBackgroundModes) MERGE into any existing
        # array — append the missing string entries, deduped — rather than
        # clobber. Lets a plugin contribute `bluetooth-central` without wiping a
        # host's `audio` entry (mob_background) and vice versa.
        is_list(value) ->
          plist_merge_array!(info_plist, key, value)

        true ->
          case plist_add_type(value) do
            {:ok, type, str_value} ->
              plist_add(info_plist, ":#{key}", type, str_value)

            :unsupported ->
              Mix.shell().info(
                "  [plugin plist] skipping :#{key} — unsupported value type #{inspect(value)}"
              )
          end
      end
    end

    :ok
  end

  # Ensure `key` is an `<array>` in the plist and append every string item in
  # `items` that isn't already present (order-preserving, deduped against what's
  # on disk). PlistBuddy `Add :key array` is a no-op when the array already
  # exists (the duplicate-key swallow in plist_add/4), so this composes with a
  # host plist that already declares the key.
  defp plist_merge_array!(plist, key, items) do
    plist_add(plist, ":#{key}", "array", "")

    existing = plist_array_entries(plist, ":#{key}")

    for item <- plist_array_additions(existing, items) do
      plist_add(plist, ":#{key}:", "string", item)
    end

    :ok
  end

  @doc false
  # Pure: given the array entries already on disk and a plugin's desired items,
  # return the string items to append — binaries only, not already present,
  # de-duplicated, input order preserved. Extracted so the merge decision is
  # unit-testable without PlistBuddy.
  @spec plist_array_additions([String.t()], [term()]) :: [String.t()]
  def plist_array_additions(existing, items) do
    items
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.reject(&(&1 in existing))
  end

  # Read the current string entries of an `<array>` plist key via PlistBuddy
  # `Print`. Returns [] when the key is absent or not an array.
  defp plist_array_entries(plist, key) do
    case System.cmd("/usr/libexec/PlistBuddy", ["-c", "Print #{key}", plist],
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        out
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 in ["Array {", "}", ""]))

      _ ->
        []
    end
  end

  defp plist_add_type(value) when is_binary(value), do: {:ok, "string", value}
  defp plist_add_type(true), do: {:ok, "bool", "true"}
  defp plist_add_type(false), do: {:ok, "bool", "false"}

  defp plist_add_type(value) when is_integer(value),
    do: {:ok, "integer", Integer.to_string(value)}

  defp plist_add_type(_other), do: :unsupported

  # PlistBuddy `Add` is non-zero on duplicate-key (and on a few other failure
  # modes we'd want to know about). We swallow the duplicate-key case
  # deliberately — that's our project-wins mechanism — and accept that other
  # PlistBuddy errors will pass silently. The first plugin that hits a real
  # problem here can extend this to inspect stderr and surface non-duplicate
  # failures.
  defp plist_add(plist, key, type, value) do
    System.cmd(
      "/usr/libexec/PlistBuddy",
      ["-c", "Add #{key} #{type} #{value}", plist],
      stderr_to_stdout: true
    )

    :ok
  end

  # ── Android plugin contributions: manifest + gradle ──────────────────────────

  @android_manifest_path "android/app/src/main/AndroidManifest.xml"
  @android_app_gradle_path "android/app/build.gradle"
  @android_java_root "android/app/src/main/java"
  # Generated startup hook (package io.mob.plugin). MainActivity.onCreate calls
  # io.mob.plugin.MobPluginBootstrap.registerAll(this).
  @plugin_bootstrap_path "android/app/src/main/java/io/mob/plugin/MobPluginBootstrap.kt"
  # Generated stable contract: a bridge class implements MobActivityAware to be
  # handed the host Activity by registerAll. Always written next to the bootstrap.
  @plugin_activity_aware_path "android/app/src/main/java/io/mob/plugin/MobActivityAware.kt"
  # Generated stable contract: a bridge class implements MobPermissionProvider to
  # supply the cap->Android-permission-string mapping for a capability core no
  # longer knows about (the permission-registry extension). Always written.
  @plugin_permission_provider_path "android/app/src/main/java/io/mob/plugin/MobPermissionProvider.kt"
  # Generated stable seam: notification-delivery state shared between HOST
  # delivery code (MobFirebaseService / MainActivity / NotificationReceiver,
  # app package) and the mob_notify plugin bridge (io.mob.notify) — neither
  # can reference the other's package directly. Always written.
  @plugin_notify_hub_path "android/app/src/main/java/io/mob/plugin/MobNotifyHub.kt"

  # Inserts `<uses-permission android:name="..."/>` lines for each permission
  # declared by activated plugins into `AndroidManifest.xml`. Idempotent: skips
  # any permission name already present in the manifest (covers both the
  # project's hand-rolled declarations and a previous run's plugin merge).
  #
  # No-op (with a notice) when the manifest is missing — mirrors how
  # `MobDev.Enable.Igniter.add_android_permission/2` handles the absence at
  # `mix mob.enable` time.
  defp apply_plugin_android_manifest! do
    activated = MobDev.Plugin.activated()

    # Capability enforcement — same call the iOS sim/device paths use; runs
    # the AndroidManifest-fragment + Swift-import scans across every
    # activated plugin and raises on drift. See MOB_PLUGIN_SECURITY.md,
    # Layer 2.
    MobDev.Plugin.Validator.raise_on_capability_drift!(activated)

    permissions = MobDev.Plugin.Merge.android_permissions(activated)
    snippets = for s <- MobDev.Plugin.Merge.android_manifest_snippets(activated), do: s.snippet

    case File.read(@android_manifest_path) do
      {:error, :enoent} ->
        if permissions != [] or snippets != [] do
          IO.puts(
            "  [plugin android] #{@android_manifest_path} not found — skipping plugin " <>
              "permissions + manifest components."
          )
        end

        :ok

      {:ok, content} ->
        patched =
          content
          |> merge_android_permissions(permissions)
          |> merge_android_manifest_components(snippets)

        if patched != content, do: File.write!(@android_manifest_path, patched)

        :ok
    end
  end

  # Inserts `implementation "<dep>"` lines for each gradle dependency declared
  # by activated plugins into the app-level `build.gradle`'s `dependencies { }`
  # block. Idempotent: skips any dep string already mentioned anywhere in the
  # file (the substring check is intentionally broad — Gradle allows several
  # syntaxes for the same dep, and we'd rather under-add than duplicate).
  #
  # No-op (with a notice) when the gradle file is missing.
  defp apply_plugin_gradle_deps! do
    case File.read(@android_app_gradle_path) do
      {:error, :enoent} ->
        if MobDev.Plugin.Merge.gradle_deps(MobDev.Plugin.activated()) != [] do
          IO.puts(
            "  [plugin android] #{@android_app_gradle_path} not found — skipping plugin gradle_deps."
          )
        end

        :ok

      {:ok, content} ->
        deps = MobDev.Plugin.Merge.gradle_deps(MobDev.Plugin.activated())
        patched = merge_gradle_deps(content, deps)

        if patched != content, do: File.write!(@android_app_gradle_path, patched)

        :ok
    end
  end

  @host_migrations_dir "priv/repo/migrations"
  @plugin_assets_root "priv/generated/plugin_assets"
  @plugin_artifact_ledger_dir "priv/generated/.mob_plugin_artifacts"

  @doc false
  # The removal half of the add/remove plugin lifecycle. A plugin's tier-3
  # merges COPY files into the host tree (bridge Kotlin into the Kotlin
  # sourceSet, migrations into priv/repo/migrations, images into the asset
  # bundle); the runtime manifest + driver_tab are recomputed from scratch each
  # build, but these copies linger after a plugin is removed — an orphaned
  # bridge .kt can even break the Gradle compile. This deletes the files a
  # prior build wrote for one merge concern (`scope`) that the current build no
  # longer produces: it reads the scope's ledger of relative paths, removes
  # (previous − current), then persists `current`. Per-scope and only called
  # when that concern's merge runs, so an iOS-only build never prunes Android
  # artifacts. Returns the pruned paths (for tests).
  # The relative paths a prior build recorded for a plugin-artifact `scope`
  # (empty when none). Shared by the prune and the res host-clobber guard.
  defp read_plugin_artifact_ledger(scope) do
    case File.read(Path.join(@plugin_artifact_ledger_dir, to_string(scope))) do
      {:ok, body} -> String.split(body, "\n", trim: true)
      _ -> []
    end
  end

  @spec __prune_plugin_artifacts__(atom(), [Path.t()]) :: [Path.t()]
  def __prune_plugin_artifacts__(scope, current) do
    ledger = Path.join(@plugin_artifact_ledger_dir, to_string(scope))
    current = current |> Enum.map(&Path.relative_to_cwd/1) |> Enum.uniq()

    previous = read_plugin_artifact_ledger(scope)

    pruned =
      for stale <- previous -- current, File.exists?(stale) do
        File.rm!(stale)
        IO.puts("  ✓ pruned orphaned plugin artifact (plugin removed): #{stale}")
        stale
      end

    File.mkdir_p!(@plugin_artifact_ledger_dir)
    File.write!(ledger, Enum.join(current, "\n"))
    pruned
  end

  # Tier 3: copies each activated plugin's migration files into the host's
  # migrations dir, namespaced by `repo_namespace` (version-preserving) so the
  # host's existing `Ecto.Migrator` picks them up. Idempotent. No-op when no
  # plugin declares `:migrations`.
  # Rebuilds priv/generated/mob_plugins.exs (the host's runtime plugin manifest)
  # from the activated plugins' current manifests, so the on-device tier-3/4
  # wiring always matches what the plugins declare at build time.
  @doc false
  # Regenerates the on-disk static-NIF driver tables for every format the
  # project already uses (zig and/or c). A project with no generated driver_tab
  # files is normally left untouched — a plain app relies on mob's core table at
  # link time. BUT activating a NIF-bearing plugin adds entries the core table
  # lacks: without an app-level table the plugin's `<module>_nif_init` links yet
  # never registers, so `load_nif/2` falls back to dlopen and the NIF is
  # `:nif_not_loaded` on device. So when plugins contribute NIFs and the app has
  # no table yet, create one (zig — the default format). Public for tests (and
  # exercised on every `build_all`).
  @spec regen_driver_tab!() :: :ok
  def regen_driver_tab! do
    formats =
      __regen_formats__(__driver_tab_formats__(&File.exists?/1), __plugin_nifs_present__())

    for fmt <- formats do
      paths = Mix.Tasks.Mob.RegenDriverTab.target_paths(fmt)

      expected = %{
        paths.ios =>
          MobDev.StaticNifs.generate(:ios, Mix.Tasks.Mob.RegenDriverTab.resolved_nifs(:ios),
            format: fmt
          )
          |> IO.iodata_to_binary(),
        paths.android =>
          MobDev.StaticNifs.generate(
            :android,
            Mix.Tasks.Mob.RegenDriverTab.resolved_nifs(:android),
            format: fmt
          )
          |> IO.iodata_to_binary()
      }

      for {path, src} <- expected,
          File.read(path) != {:ok, src} do
        existed? = File.exists?(path)
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, src)
        verb = if existed?, do: "regenerated (was stale)", else: "created (plugin NIFs)"
        IO.puts("  ✓ driver_tab #{verb}: #{path}")
      end
    end

    :ok
  end

  @doc false
  # True when any activated plugin contributes a NIF — the trigger for creating
  # an app-level driver_tab where none exists (see regen_driver_tab!/0).
  @spec __plugin_nifs_present__() :: boolean()
  def __plugin_nifs_present__ do
    MobDev.Plugin.Merge.nifs(MobDev.Plugin.activated()) != []
  end

  @doc false
  # Pure kernel: which driver_tab formats to (re)generate. An app with existing
  # tables keeps its format(s). An app with NONE normally generates nothing (it
  # links against mob's core table) — UNLESS a NIF-bearing plugin is active, in
  # which case it needs its own table (core + plugin entries), defaulting to
  # zig. Public for tests.
  @spec __regen_formats__([:zig | :c], boolean()) :: [:zig | :c]
  def __regen_formats__([], true), do: [:zig]
  def __regen_formats__([], false), do: []
  def __regen_formats__(existing, _plugin_nifs?), do: existing

  defp warn_host_requirements! do
    case __host_requirements_warning__(
           MobDev.Plugin.Merge.host_requirements(MobDev.Plugin.activated())
         ) do
      nil -> :ok
      msg -> IO.puts(msg)
    end

    :ok
  end

  @doc false
  # Pure kernel: render the host-obligation warning block (nil when no plugin
  # declares any). Public for tests.
  @spec __host_requirements_warning__([%{plugin: atom(), requirement: String.t()}]) ::
          String.t() | nil
  def __host_requirements_warning__([]), do: nil

  def __host_requirements_warning__(reqs) do
    lines = for %{plugin: p, requirement: r} <- reqs, do: "      [#{p}] #{r}"

    IO.ANSI.yellow() <>
      "  ⚠  plugin host requirements — manual steps the build can NOT do for you:\n" <>
      Enum.join(lines, "\n") <> IO.ANSI.reset()
  end

  @doc false
  # Pure kernel: which driver_tab formats the project uses, decided from file
  # existence alone (`exists?` is injected so tests don't touch the disk).
  @spec __driver_tab_formats__((String.t() -> boolean())) :: [:zig | :c]
  def __driver_tab_formats__(exists?) when is_function(exists?, 1) do
    for fmt <- [:zig, :c],
        paths = Mix.Tasks.Mob.RegenDriverTab.target_paths(fmt),
        exists?.(paths.ios) or exists?.(paths.android),
        do: fmt
  end

  defp regen_runtime_manifest! do
    manifest = MobDev.Plugin.RuntimeManifest.build(MobDev.Plugin.activated())
    MobDev.Plugin.RuntimeManifest.write(File.cwd!(), manifest)
    %{screens: s, lifecycle: l, settings: st, notification_handlers: n} = manifest

    IO.puts(
      "  ✓ runtime plugin manifest (#{length(s)} screens, #{length(l)} lifecycle, " <>
        "#{length(st)} settings, #{length(n)} handlers)"
    )

    :ok
  end

  defp apply_plugin_migrations! do
    migrations = MobDev.Plugin.Merge.migrations(MobDev.Plugin.activated())

    written =
      if migrations != [] do
        File.mkdir_p!(@host_migrations_dir)

        plugin_migs =
          for m <- migrations do
            %{
              repo_namespace: m.repo_namespace,
              files: Path.wildcard(Path.join(m.migrations_dir, "*.exs"))
            }
          end

        for {src, dest} <-
              MobDev.Plugin.Assets.migration_copies(plugin_migs, @host_migrations_dir) do
          File.cp!(src, dest)
          IO.puts("  ✓ plugin migration → #{Path.relative_to_cwd(dest)}")
          dest
        end
      else
        []
      end

    # Prune migrations a removed plugin left in the host dir. Deleting the file
    # does not roll back an already-applied migration (schema_migrations keeps
    # the record); it just stops Ecto re-running it and keeps the dir honest.
    __prune_plugin_artifacts__(:migrations, written)

    :ok
  end

  # Tier 3: copies each activated plugin's images into the host bundle under
  # `priv/generated/plugin_assets/assets/plugin/<plugin>/<file>` — the path the
  # core `Mob.Plugins.resolve_image/1` (`plugin://<plugin>/<file>`) resolves to.
  # No-op when no plugin declares image assets.
  defp apply_plugin_images! do
    written =
      for %{plugin: plugin, images: images} <-
            MobDev.Plugin.Merge.assets(MobDev.Plugin.activated()),
          src <- images do
        rel = MobDev.Plugin.Assets.image_bundle_path(plugin, Path.basename(src))
        dest = Path.join(@plugin_assets_root, rel)
        File.mkdir_p!(Path.dirname(dest))
        File.cp!(src, dest)
        IO.puts("  ✓ plugin image → #{Path.relative_to_cwd(dest)}")
        dest
      end

    # Prune images a removed plugin left in the bundle.
    __prune_plugin_artifacts__(:images, written)

    :ok
  end

  @android_res_font "android/app/src/main/res/font"

  # App-level (`priv/fonts/*.ttf|otf`) + plugin (`assets.fonts`) custom fonts.
  defp collect_all_fonts do
    app_fonts = Path.wildcard("priv/fonts/*.{ttf,otf,TTF,OTF}")

    plugin_fonts =
      for %{fonts: fonts} <- MobDev.Plugin.Merge.assets(MobDev.Plugin.activated()),
          f <- fonts,
          do: f

    Enum.uniq(app_fonts ++ plugin_fonts)
  end

  # Copies the app's + plugins' fonts into the iOS `.app` bundle root and lists
  # them in `Info.plist` UIAppFonts so iOS registers them at launch (the SwiftUI
  # `Font.custom(name, …)` path in MobRootView then resolves them by name). No-op
  # when there are no fonts.
  defp apply_fonts_to_ios_bundle!(info_plist, app_path) do
    fonts = collect_all_fonts()

    if fonts != [] do
      copies =
        case MobDev.Plugin.Assets.plan_ios_font_bundle(fonts) do
          {:ok, copies} ->
            copies

          {:error, {:font_basename_collision, name, srcs}} ->
            Mix.raise(
              "Font bundle collision: multiple fonts share the iOS bundle name #{name}:\n  " <>
                Enum.join(srcs, "\n  ") <>
                "\nRename one so the .app bundle + UIAppFonts stay unambiguous."
            )
        end

      for {src, dest} <- copies, do: File.cp!(src, Path.join(app_path, dest))
      basenames = Enum.map(copies, fn {_src, dest} -> dest end)
      plist = File.read!(info_plist)
      File.write!(info_plist, MobDev.Plugin.Assets.merge_ui_app_fonts(plist, basenames))
      IO.puts("  ✓ bundled #{length(copies)} font(s) + UIAppFonts")
    end

    :ok
  end

  # Copies the app's + plugins' fonts into the Android `res/font/` dir under a
  # normalised resource name (lowercase + underscores; the renderer normalises
  # the `font:` prop the same way to look them up via `getIdentifier`). Unlike
  # `assets/`, `res/font/` entries are stored uncompressed, which Android's font
  # loader requires. No-op when there are no fonts.
  defp apply_fonts_to_android! do
    fonts = collect_all_fonts()

    if fonts != [] do
      copies =
        case MobDev.Plugin.Assets.plan_android_font_copies(fonts) do
          {:ok, copies} ->
            copies

          {:error, {:font_resource_collision, res_name, srcs}} ->
            Mix.raise(
              "Font resource collision: multiple fonts normalise to the Android resource #{res_name}:\n  " <>
                Enum.join(srcs, "\n  ") <>
                "\nRename one (Android collapses '-', '_', ' ' etc. to '_')."
            )
        end

      File.mkdir_p!(@android_res_font)

      for {src, res_filename} <- copies do
        dest = Path.join(@android_res_font, res_filename)
        File.cp!(src, dest)
        IO.puts("  ✓ android font → #{Path.relative_to_cwd(dest)}")
      end
    end

    :ok
  end

  @android_res_root "android/app/src/main"

  # Copies each activated plugin's `android.res_files` into the app's `res/`
  # tree (at its declared `res/<type>/<file>` destination), so a manifest
  # component's `@xml/…` reference resolves at build time. Ledger-pruned like
  # bridge_kt (a res file left by a since-removed plugin is deleted). Raises on
  # two plugins targeting the same destination with different sources — the
  # cross-plugin validator catches this at activation, this is the build-time
  # backstop. No-op (with a notice) when the res root is missing.
  #
  # Two safety guards (the manifest validator enforces the first at activation
  # too; these are the build-time backstop, since `activated/0` can feed
  # unvalidated manifests):
  #   * containment — the resolved destination must stay under the app `res/`
  #     dir, so a `..`-bearing path can't make `File.cp!` write plugin bytes
  #     anywhere on the build host (path traversal).
  #   * no host clobber — refuse to overwrite a file this build didn't write on
  #     a previous run (tracked in the ledger); otherwise a plugin could replace
  #     a host-owned resource (e.g. res/values/styles.xml) and, worse, the
  #     ledger prune would later delete the host's file on plugin removal.
  defp apply_plugin_android_res! do
    res_files = MobDev.Plugin.Merge.android_res_files(MobDev.Plugin.activated())

    cond do
      res_files == [] ->
        :ok

      not File.dir?(@android_res_root) ->
        IO.puts("  [plugin android] #{@android_res_root} not found — skipping plugin res files.")
        :ok

      true ->
        raise_on_res_dest_collision!(res_files)
        prior = read_plugin_artifact_ledger(:android_res)

        written =
          for %{src: src, dest: dest} <- res_files do
            target = safe_res_target!(dest)
            rel = Path.relative_to_cwd(target)

            if File.exists?(target) and rel not in prior do
              Mix.raise(
                "plugin res file #{dest} would overwrite host-owned #{rel} — rename it in the plugin"
              )
            end

            File.mkdir_p!(Path.dirname(target))
            File.cp!(src, target)
            IO.puts("  ✓ android res → #{rel}")
            target
          end

        __prune_plugin_artifacts__(:android_res, written)
        :ok
    end
  end

  # Resolve a plugin res destination to a copy target, raising if it escapes the
  # app `res/` dir. The hard security boundary behind the manifest validator's
  # `..` rejection.
  defp safe_res_target!(dest) do
    case __res_target__(@android_res_root, dest) do
      {:ok, target} ->
        target

      {:error, :escapes_res_dir} ->
        Mix.raise(
          "plugin res file destination escapes the app res/ dir: #{dest} " <>
            "(path traversal — declared res_files must not contain \"..\")"
        )
    end
  end

  @doc false
  # Pure: {:ok, copy_target} when `dest` (joined onto `root`) stays inside
  # `root/res`, else {:error, :escapes_res_dir}. `..` and absolute escapes are
  # normalised by Path.expand before the containment check.
  @spec __res_target__(String.t(), String.t()) :: {:ok, String.t()} | {:error, :escapes_res_dir}
  def __res_target__(root, dest) do
    res_dir = Path.expand(Path.join(root, "res"))
    target_abs = Path.expand(Path.join(root, dest))

    if target_abs == res_dir or String.starts_with?(target_abs, res_dir <> "/"),
      do: {:ok, Path.join(root, dest)},
      else: {:error, :escapes_res_dir}
  end

  defp raise_on_res_dest_collision!(res_files) do
    res_files
    |> Enum.group_by(& &1.dest, & &1.src)
    |> Enum.each(fn {dest, srcs} ->
      case Enum.uniq(srcs) do
        [_single] ->
          :ok

        many ->
          Mix.raise(
            "Android res collision: multiple plugins target #{dest}:\n  " <>
              Enum.join(many, "\n  ") <> "\nRename one so plugin res files don't clash."
          )
      end
    end)
  end

  # Copies each activated plugin's `bridge_kt` into the app's Kotlin sourceSet
  # (at its own package path, read from the file's `package` line) so Gradle
  # compiles it, and (re)generates `io.mob.plugin.MobPluginBootstrap` whose
  # `registerAll(activity)` calls each `bridge_class`'s `register()` and then
  # hands the Activity to any bridge implementing `MobActivityAware`.
  # MainActivity calls `MobPluginBootstrap.registerAll(this)` in `onCreate`.
  # The `MobActivityAware` contract is written alongside the bootstrap, and
  # both are always written (empty registerAll body when no plugin declares a
  # bridge_class) so the MainActivity call always resolves. No-op (with a
  # notice) when the java root is missing.
  defp apply_plugin_android_kotlin! do
    if File.dir?(@android_java_root) do
      activated = MobDev.Plugin.activated()

      written =
        Enum.flat_map(MobDev.Plugin.Merge.bridge_kt_sources(activated), fn src ->
          case File.read(src) do
            {:ok, content} ->
              case __parse_kotlin_package__(content) do
                nil ->
                  IO.puts("  [plugin android] #{src} has no `package` line — skipping copy.")
                  []

                package ->
                  dest = __bridge_kt_dest__(@android_java_root, package, Path.basename(src))
                  File.mkdir_p!(Path.dirname(dest))
                  File.write!(dest, content)
                  [dest]
              end

            {:error, reason} ->
              IO.puts("  [plugin android] cannot read #{src}: #{inspect(reason)} — skipping.")
              []
          end
        end)

      # Delete bridge .kt left in the sourceSet by plugins since removed — an
      # orphaned bridge can break the Gradle compile. The generated glue below
      # is overwritten at fixed paths each build, so only the per-plugin bridge
      # copies (scattered by package) need ledger-tracked pruning.
      __prune_plugin_artifacts__(:android_kotlin, written)

      write_generated_kotlin!(@plugin_activity_aware_path, __activity_aware_kotlin__())
      write_generated_kotlin!(@plugin_permission_provider_path, __permission_provider_kotlin__())
      write_generated_kotlin!(@plugin_notify_hub_path, __notify_hub_kotlin__())

      write_generated_kotlin!(
        @plugin_bootstrap_path,
        __bootstrap_kotlin__(MobDev.Plugin.Merge.bridge_classes(activated))
      )

      :ok
    else
      if MobDev.Plugin.Merge.bridge_kt_sources(MobDev.Plugin.activated()) != [] do
        IO.puts("  [plugin android] #{@android_java_root} not found — skipping plugin Kotlin.")
      end

      :ok
    end
  end

  # Extracts the FQ package from a Kotlin source, or nil if none.
  @doc false
  @spec __parse_kotlin_package__(String.t()) :: String.t() | nil
  def __parse_kotlin_package__(content) do
    case Regex.run(~r/^\s*package\s+([\w.]+)/m, content) do
      [_, package] -> package
      _ -> nil
    end
  end

  @doc false
  @spec __bridge_kt_dest__(String.t(), String.t(), String.t()) :: String.t()
  def __bridge_kt_dest__(java_root, package, basename) do
    Path.join([java_root, String.replace(package, ".", "/"), basename])
  end

  # Writes a generated Kotlin file, creating its dir and skipping the write
  # when the content is byte-identical (keeps Gradle's up-to-date checks happy).
  defp write_generated_kotlin!(path, content) do
    File.mkdir_p!(Path.dirname(path))
    if File.read(path) != {:ok, content}, do: File.write!(path, content)
    :ok
  end

  # Source for io.mob.plugin.MobNotifyHub — see @plugin_notify_hub_path.
  @doc false
  @spec __notify_hub_kotlin__() :: String.t()
  def __notify_hub_kotlin__ do
    """
    // GENERATED by mob_dev — do not edit. Stable cross-package seam for
    // notification-delivery state: host delivery code (MobFirebaseService /
    // MainActivity / NotificationReceiver, app package) and the mob_notify
    // plugin bridge (io.mob.notify) both use it; neither can reference the
    // other's generated package directly.
    package io.mob.plugin

    object MobNotifyHub {
        // Local-notification channel id — the host NotificationReceiver posts
        // to it; the plugin's notify_schedule creates it.
        const val CHANNEL_ID = "mob_notifications"

        // The screen process registered via MobNotify.register_push/1. Host
        // delivery paths (FCM foreground push, notification tap) send to it
        // via core's nativeDeliver* thunks; 0 = no screen registered.
        @Volatile @JvmStatic var notifyPid: Long = 0

        // FCM token that refreshed while no screen was registered; the
        // plugin's notify_register_push drains it.
        @Volatile @JvmStatic var pendingToken: String? = null
    }
    """
  end

  # Source for io.mob.plugin.MobPluginBootstrap. registerAll(activity) calls each
  # bridge class's register(), then hands the Activity to any bridge implementing
  # MobActivityAware via the handOff helper. The body is uniform per bridge, so
  # the generator needs no per-plugin knowledge. handOff takes `Any` so the
  # `as?` runtime check is valid for every bridge type — a direct
  # `(SomeFinalObject as? MobActivityAware)` would draw a "cast can never
  # succeed" warning for bridges that don't opt in.
  @doc false
  @spec __bootstrap_kotlin__([String.t()]) :: String.t()
  def __bootstrap_kotlin__(bridge_classes) do
    calls =
      bridge_classes
      |> Enum.map(fn cls ->
        "        #{cls}.register()\n        handOff(#{cls}, activity)\n        collectPermissionProvider(#{cls})"
      end)
      |> Enum.join("\n")

    {body, helpers} =
      if calls == "" do
        {"", ""}
      else
        {"\n" <> calls <> "\n    ",
         "\n\n    // Hands the Activity to a bridge that opts in via" <>
           " MobActivityAware.\n" <>
           "    private fun handOff(bridge: Any, activity: Activity) {\n" <>
           "        (bridge as? MobActivityAware)?.setActivity(activity)\n" <>
           "    }\n\n" <>
           "    // Records a bridge that opts in via MobPermissionProvider so" <>
           " core\n" <>
           "    // MobBridge.request_permission can fall through to it for a" <>
           " capability\n" <>
           "    // core no longer knows about.\n" <>
           "    private fun collectPermissionProvider(bridge: Any) {\n" <>
           "        (bridge as? MobPermissionProvider)?.let {\n" <>
           "            if (!permissionProviders.contains(it)) permissionProviders.add(it)\n" <>
           "        }\n" <>
           "    }"}
      end

    """
    // Generated by mob_dev (MobDev.NativeBuild) — do not edit.
    // Calls each activated plugin's bridge-class register() at startup, then
    // hands the Activity to any bridge implementing MobActivityAware and records
    // any bridge implementing MobPermissionProvider; invoked from
    // MainActivity.onCreate as registerAll(this).
    package io.mob.plugin

    import android.app.Activity

    object MobPluginBootstrap {
        private val permissionProviders = mutableListOf<MobPermissionProvider>()

        @JvmStatic
        fun registerAll(activity: Activity) {#{body}}

        // Returns the first plugin-supplied Android permission mapping for `cap`,
        // or null if no activated plugin provides this capability. Core
        // MobBridge.request_permission consults this in its `else` branch.
        @JvmStatic
        fun permissionsFor(cap: String): Array<String>? {
            for (provider in permissionProviders) {
                val perms = provider.permissionsFor(cap)
                if (perms != null) return perms
            }
            return null
        }#{helpers}
    }
    """
  end

  # Source for io.mob.plugin.MobPermissionProvider — the stable opt-in contract a
  # plugin bridge class implements to supply the cap->Android-permission-string
  # mapping for a capability core no longer hardcodes. Generated (never changes)
  # so existing apps and mob_new projects get it without a template edit.
  @doc false
  @spec __permission_provider_kotlin__() :: String.t()
  def __permission_provider_kotlin__ do
    """
    // Generated by mob_dev (MobDev.NativeBuild) — do not edit.
    // A plugin bridge class implements this to supply the Android permission
    // strings for a capability; MobPluginBootstrap collects providers at
    // registerAll and core MobBridge.request_permission consults them.
    package io.mob.plugin

    interface MobPermissionProvider {
        // Return the Android permission strings for `cap`, or null if this
        // provider does not handle the capability.
        fun permissionsFor(cap: String): Array<String>?
    }
    """
  end

  # Source for io.mob.plugin.MobActivityAware — the stable opt-in contract a
  # plugin bridge class implements to be handed the host Activity. Generated
  # (never changes) so existing apps and mob_new projects get it without a
  # template edit.
  @doc false
  @spec __activity_aware_kotlin__() :: String.t()
  def __activity_aware_kotlin__ do
    """
    // Generated by mob_dev (MobDev.NativeBuild) — do not edit.
    // A plugin bridge class implements this to receive the host Activity from
    // MobPluginBootstrap.registerAll, right after register().
    package io.mob.plugin

    import android.app.Activity

    interface MobActivityAware {
        fun setActivity(activity: Activity)
    }
    """
  end

  @doc false
  @spec __merge_android_permissions__(String.t(), [String.t()]) :: String.t()
  def __merge_android_permissions__(manifest, permissions),
    do: merge_android_permissions(manifest, permissions)

  @doc false
  @spec __merge_gradle_deps__(String.t(), [String.t()]) :: String.t()
  def __merge_gradle_deps__(content, deps), do: merge_gradle_deps(content, deps)

  @doc false
  @spec __merge_android_manifest_components__(String.t(), [String.t()]) :: String.t()
  def __merge_android_manifest_components__(manifest, snippets),
    do: merge_android_manifest_components(manifest, snippets)

  # Pure transform: splice each plugin `<application>` snippet (a <service>,
  # <receiver>, …) in just before `</application>`. Idempotent per component:
  # skips any snippet whose `android:name` (or, lacking one, whose trimmed body)
  # is already present, so re-runs and hand-added copies don't duplicate. Each
  # snippet's own indentation is preserved and shifted 8 spaces to sit inside
  # <application>. No `</application>` → returns the manifest untouched rather
  # than risk corrupting it.
  # Managed-block markers (MobDev.Plugin.ManagedBlock) fence each plugin
  # contribution so the region is regenerated every build and vanishes when the
  # plugin is removed — the app manifest / build.gradle are host-owned and
  # hand-edited, so there's no ledger to prune (unlike bridge_kt / res_files).
  # Comment syntax matches the host file (XML for the manifest, `//` for Gradle).
  @perm_markers {
    "    <!-- mob:plugin-permissions BEGIN (managed — regenerated each build; do not edit) -->",
    "    <!-- mob:plugin-permissions END -->"
  }
  @component_markers {
    "        <!-- mob:plugin-components BEGIN (managed — regenerated each build; do not edit) -->",
    "        <!-- mob:plugin-components END -->"
  }
  @gradle_dep_markers {
    "    // mob:plugin-deps BEGIN (managed — regenerated each build; do not edit)",
    "    // mob:plugin-deps END"
  }

  # Splice plugin `<application>` components (a `<service>`, `<receiver>`, …)
  # into a managed region just before `</application>`. De-duped against
  # host-authored content (post-strip) so a hand-declared component isn't
  # doubled; removed automatically when no plugin contributes one (empty region
  # → stripped).
  defp merge_android_manifest_components(manifest, snippets) when is_binary(manifest) do
    stripped = MobDev.Plugin.ManagedBlock.strip(manifest, @component_markers)
    missing = Enum.reject(snippets, &manifest_component_present?(stripped, &1))
    body = Enum.map_join(missing, "\n\n", &indent_manifest_snippet/1)

    MobDev.Plugin.ManagedBlock.upsert(
      manifest,
      @component_markers,
      body,
      &place_before_application_close/2
    )
  end

  defp place_before_application_close(stripped, region) do
    if String.contains?(stripped, "</application>") do
      MobDev.Plugin.ManagedBlock.insert_before(stripped, "</application>", region)
    else
      stripped
    end
  end

  defp manifest_component_present?(manifest, snippet) do
    case Regex.run(~r/android:name="([^"]+)"/, snippet) do
      [_, name] -> String.contains?(manifest, ~s(android:name="#{name}"))
      _ -> String.contains?(manifest, String.trim(snippet))
    end
  end

  defp indent_manifest_snippet(snippet) do
    snippet
    |> String.trim("\n")
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "" -> ""
      line -> "        " <> line
    end)
  end

  # Splice plugin `<uses-permission>` tags into a managed region before
  # `<application` (or `</manifest>`). De-duped against host-authored content so
  # a hand-declared permission isn't doubled; removed on plugin removal.
  defp merge_android_permissions(manifest, permissions) when is_binary(manifest) do
    stripped = MobDev.Plugin.ManagedBlock.strip(manifest, @perm_markers)
    missing = Enum.reject(permissions, &permission_present?(stripped, &1))
    body = Enum.map_join(missing, "\n", &~s(    <uses-permission android:name="#{&1}" />))
    MobDev.Plugin.ManagedBlock.upsert(manifest, @perm_markers, body, &place_before_application/2)
  end

  defp permission_present?(manifest, permission) do
    String.contains?(manifest, ~s(android:name="#{permission}")) and
      String.contains?(manifest, "uses-permission")
  end

  defp place_before_application(stripped, region) do
    cond do
      String.contains?(stripped, "<application") ->
        MobDev.Plugin.ManagedBlock.insert_before(stripped, "<application", region)

      String.contains?(stripped, "</manifest>") ->
        MobDev.Plugin.ManagedBlock.insert_before(stripped, "</manifest>", region)

      true ->
        # Pathological manifest (no <application and no </manifest>): append the
        # region as whole lines at EOF so strip/2 still reverses it.
        sep = if stripped == "" or String.ends_with?(stripped, "\n"), do: "", else: "\n"
        stripped <> sep <> region <> "\n"
    end
  end

  # Splice plugin `implementation "<dep>"` lines into a managed region inside the
  # top-level `dependencies { }` block. Broad substring de-dupe against
  # host-authored content (Gradle allows several syntaxes for one dep, so we'd
  # rather under-add than duplicate); removed on plugin removal.
  defp merge_gradle_deps(content, deps) when is_binary(content) do
    stripped = MobDev.Plugin.ManagedBlock.strip(content, @gradle_dep_markers)
    missing = Enum.reject(deps, &String.contains?(stripped, &1))
    body = Enum.map_join(missing, "\n", &~s(    implementation "#{&1}"))

    MobDev.Plugin.ManagedBlock.upsert(
      content,
      @gradle_dep_markers,
      body,
      &place_in_dependencies/2
    )
  end

  # Insert the region just before the matching close-brace of the top-level
  # `dependencies { ... }` block; fall back to a fresh appended block (Gradle
  # merges multiple `dependencies {}` blocks) when it can't be located.
  defp place_in_dependencies(stripped, region) do
    case Regex.run(~r/^dependencies\s*\{/m, stripped, return: :index) do
      [{start_idx, len}] ->
        open_brace_idx = start_idx + len - 1

        case find_matching_close_brace(stripped, open_brace_idx) do
          {:ok, close_idx} ->
            MobDev.Plugin.ManagedBlock.insert_before_index(stripped, close_idx, region)

          :not_found ->
            stripped <> "\ndependencies {\n#{region}\n}\n"
        end

      nil ->
        stripped <> "\ndependencies {\n#{region}\n}\n"
    end
  end

  # Given an index pointing at an opening `{` byte, return the index of the
  # matching `}`. Operates on bytes — fine for Gradle files which are ASCII
  # in practice; if a project sneaks in a UTF-8 brace-lookalike, we'd just
  # miss it and fall back to the append path.
  defp find_matching_close_brace(content, open_idx) do
    scan_brace(content, open_idx + 1, 1)
  end

  defp scan_brace(content, idx, depth) when idx < byte_size(content) do
    case binary_part(content, idx, 1) do
      "{" -> scan_brace(content, idx + 1, depth + 1)
      "}" when depth == 1 -> {:ok, idx}
      "}" -> scan_brace(content, idx + 1, depth - 1)
      _ -> scan_brace(content, idx + 1, depth)
    end
  end

  defp scan_brace(_content, _idx, _depth), do: :not_found

  defp compile_ios_device_icons(app_path) do
    actool_plist =
      Path.join(System.tmp_dir!(), "mob_actool_#{System.unique_integer([:positive])}.plist")

    case System.cmd(
           "xcrun",
           [
             "actool",
             "ios/Assets.xcassets",
             "--compile",
             app_path,
             "--platform",
             "iphoneos",
             "--minimum-deployment-target",
             "17.0",
             "--app-icon",
             "AppIcon",
             "--output-partial-info-plist",
             actool_plist
           ],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        _ =
          System.cmd(
            "/usr/libexec/PlistBuddy",
            [
              "-c",
              "Merge #{actool_plist}",
              Path.join(app_path, "Info.plist")
            ],
            stderr_to_stdout: true
          )

      _ ->
        :ok
    end

    File.rm(actool_plist)
  end

  defp bundle_otp_runtime(app_path, otp_root, app_module, erts_vsn) do
    IO.puts("  === Bundling OTP runtime inside .app")
    otp_bundle = Path.join(app_path, "otp")
    File.mkdir_p!(otp_bundle)

    rsync_dir!(Path.join(otp_root, "lib") <> "/", Path.join(otp_bundle, "lib") <> "/")
    rsync_dir!(Path.join(otp_root, "releases") <> "/", Path.join(otp_bundle, "releases") <> "/")
    rsync_dir!(Path.join(otp_root, app_module) <> "/", Path.join(otp_bundle, app_module) <> "/")

    python_src = Path.join(otp_root, "python")

    if File.dir?(python_src) do
      rsync_dir!(python_src <> "/", Path.join(otp_bundle, "python") <> "/")
      # Mirrors the Android `copy_project_python_wheels/1` call in
      # `copy_python_assets/1`. iOS device builds nuke and rebuild
      # `<otp_root>/python/lib/python3.13/` on every run (see
      # `ios/build_device.sh` PYTHON_STDLIB block), so staging wheels
      # into the OTP cache wouldn't survive. Doing the copy here, after
      # the rsync into the .app bundle, lands them where Python's
      # site-packages discovery will find them at runtime.
      copy_ios_safe_project_python_wheels(
        Path.join(otp_bundle, "python"),
        Path.join("priv", "python_wheels")
      )
    end

    for ext <- ["png", "jpg"] do
      Path.wildcard("#{otp_root}/*.#{ext}")
      |> Enum.each(&File.cp!(&1, Path.join(otp_bundle, Path.basename(&1))))
    end

    File.mkdir_p!(Path.join([otp_bundle, erts_vsn, "bin"]))

    {size, _} = System.cmd("du", ["-sh", otp_bundle])
    IO.puts("  OTP bundle: #{size |> String.split() |> List.first()}")
    :ok
  end

  defp rsync_dir!(src, dst) do
    {_, 0} =
      System.cmd("rsync", ["-a", "--delete", src, dst], stderr_to_stdout: true, into: IO.stream())

    :ok
  end

  defp maybe_slim_otp_bundle(app_path, cfg) do
    if System.get_env("MOB_SLIM") == "1" do
      otp_bundle = Path.join(app_path, "otp")
      slim_opts = Keyword.get(cfg, :slim, [])

      IO.puts("  === Slim strip pass")

      audit_input = maybe_run_audit(otp_bundle, slim_opts)

      {:ok, result} =
        MobDev.OtpAudit.Slim.slim_bundle(otp_bundle,
          keep_libs: Keyword.get(slim_opts, :keep_libs, []),
          drop_libs: Keyword.get(slim_opts, :drop_libs, []),
          audit_input: audit_input,
          on_step: fn %{label: label, before_kb: before, after_kb: after_size} ->
            delta = before - after_size
            IO.puts("  [SLIM:#{label}] #{before} KB → #{after_size} KB  (-#{delta} KB)")
          end
        )

      mb = Float.round(result.final_kb / 1024, 1)
      IO.puts("  Slim OTP bundle: #{mb}M")
    else
      IO.puts("  [SLIM:skipped] MOB_SLIM=0 — keeping full OTP runtime")
    end

    :ok
  end

  # Returns a MobDev.OtpAudit.report when slim_opts says to run the audit,
  # nil otherwise. The Slim module's audit_expansion gracefully treats nil
  # as "no expansion."
  #
  # The mob.exs surface is conservative — default off — because the audit
  # walks every `.beam` in the bundle (seconds added per build). Users
  # opt in once they've captured trace(s) and want to expand the strip set:
  #
  #     config :mob_dev,
  #       slim: [audit: true, trace_json: "priv/mob_trace.json"]
  #
  # For production stripping, multi-trace union is strongly recommended —
  # a single 60s capture only sees one slice of the app:
  #
  #     config :mob_dev,
  #       slim: [
  #         audit: true,
  #         trace_jsons: ["priv/boot.json", "priv/ui.json", "priv/auth.json"]
  #       ]
  #
  # The union picks "ever called" across all captures: a lib is
  # trace-strippable only if NONE of the traces saw any of its modules.
  defp maybe_run_audit(otp_bundle, slim_opts) do
    if Keyword.get(slim_opts, :audit, false) do
      trace_paths = trace_paths_from_opts(slim_opts)
      trace_input = union_trace_jsons(trace_paths)
      project_deps = infer_project_deps()

      app_name =
        case Mix.Project.get() do
          nil -> nil
          _ -> Mix.Project.config()[:app]
        end

      trace_desc =
        case {trace_input, length(trace_paths)} do
          {nil, _} -> "none"
          {ms, 1} -> "#{MapSet.size(ms)} modules from 1 capture"
          {ms, n} -> "#{MapSet.size(ms)} unique modules across #{n} captures"
        end

      IO.puts(
        "  [SLIM:audit] running OtpAudit " <>
          "(project_deps=#{length(project_deps || [])}, trace=#{trace_desc})"
      )

      MobDev.OtpAudit.audit(otp_bundle,
        app_name: app_name,
        project_deps: project_deps,
        trace_input: trace_input
      )
    end
  end

  # mob.exs accepts both shapes for back-compat:
  #   slim: [trace_json: "single.json"]
  #   slim: [trace_jsons: ["one.json", "two.json"]]
  # If both are given, the singular is appended to the plural list.
  defp trace_paths_from_opts(slim_opts) do
    paths = Keyword.get(slim_opts, :trace_jsons, [])

    case Keyword.get(slim_opts, :trace_json) do
      nil -> paths
      single -> paths ++ [single]
    end
  end

  # In the slim build path a failed read should warn but not raise:
  # the build keeps going (no trace expansion) so the user still gets
  # a slim build, just with fewer libs stripped than they configured.
  defp union_trace_jsons(paths) do
    MobDev.OtpAudit.union_trace_jsons(paths, fn path, reason ->
      IO.warn(
        "[SLIM:audit] could not read trace_json #{path}: " <>
          "#{inspect(reason)} — skipping that trace"
      )
    end)
  end

  defp infer_project_deps do
    case File.ls("_build/dev/lib") do
      {:ok, libs} -> Enum.map(libs, &String.to_atom/1)
      _ -> nil
    end
  end

  defp embed_provisioning_profile(app_path, profile_uuid) do
    candidates = [
      Path.expand(
        "~/Library/Developer/Xcode/UserData/Provisioning Profiles/#{profile_uuid}.mobileprovision"
      ),
      Path.expand("~/Library/MobileDevice/Provisioning Profiles/#{profile_uuid}.mobileprovision")
    ]

    case Enum.find(candidates, &File.exists?/1) do
      nil ->
        {:error,
         "Provisioning profile #{profile_uuid} not found in either Xcode UserData or MobileDevice paths.\n" <>
           "Open Xcode → Settings → Accounts → Download Profiles."}

      profile_path ->
        IO.puts("  === Embedding provisioning profile")
        File.cp!(profile_path, Path.join(app_path, "embedded.mobileprovision"))
        :ok
    end
  end

  defp codesign_ios_device_app(app_path, cfg, build_dir) do
    sign_identity = cfg[:ios_sign_identity]
    team_id = cfg[:ios_team_id]
    bundle_id = cfg[:ios_bundle_id] || cfg[:bundle_id]

    IO.puts("  === Code signing")
    entitlements = resolve_or_generate_entitlements(app_path, build_dir, team_id, bundle_id)

    otp_bundle = Path.join(app_path, "otp")

    if File.dir?(Path.join(otp_bundle, "python")),
      do: codesign_python_dylibs(otp_bundle, sign_identity)

    # Sign embedded TFLite frameworks before signing the app bundle.
    # iOS requires every nested .framework to carry its own signature;
    # the app-level sign then includes the framework hashes in its
    # sealed-resources list.
    codesign_tflite_frameworks(app_path, sign_identity)

    {_, 0} =
      System.cmd(
        "codesign",
        [
          "--force",
          "--sign",
          sign_identity,
          "--entitlements",
          entitlements,
          "--timestamp=none",
          app_path
        ],
        stderr_to_stdout: true,
        into: IO.stream()
      )

    :ok
  end

  defp codesign_tflite_frameworks(app_path, sign_identity) do
    frameworks_dir = Path.join(app_path, "Frameworks")

    for fw_name <- ~w(TensorFlowLiteC TensorFlowLiteCCoreML TensorFlowLiteCMetal) do
      fw_path = Path.join(frameworks_dir, "#{fw_name}.framework")

      if File.dir?(fw_path) do
        IO.puts("  === Signing #{fw_name}.framework")

        # Sign the binary inside the framework first (deepest), then
        # sign the framework dir itself. iOS 17+ rejects pre-existing
        # CocoaPods-style signatures so --force overwrites any leftover.
        # --generate-entitlement-der writes the modern entitlement
        # encoding required by iOS 26.
        binary = Path.join(fw_path, fw_name)

        if File.exists?(binary) do
          {_, 0} =
            System.cmd(
              "codesign",
              [
                "--force",
                "--sign",
                sign_identity,
                "--timestamp=none",
                "--generate-entitlement-der",
                binary
              ],
              stderr_to_stdout: true,
              into: IO.stream()
            )
        end

        {_, 0} =
          System.cmd(
            "codesign",
            [
              "--force",
              "--sign",
              sign_identity,
              "--timestamp=none",
              "--generate-entitlement-der",
              fw_path
            ],
            stderr_to_stdout: true,
            into: IO.stream()
          )
      end
    end

    :ok
  end

  defp resolve_or_generate_entitlements(app_path, build_dir, team_id, bundle_id) do
    case Path.wildcard("ios/*.entitlements") do
      [entitlements | _] ->
        entitlements

      [] ->
        path = Path.join(build_dir, "mob_device.entitlements")

        # Mirror aps-environment from the profile so the binary entitlement
        # matches what the profile grants — without this APNs registration
        # silently fails and the push token is never delivered.
        aps_env = read_aps_environment(Path.join(app_path, "embedded.mobileprovision"))

        File.write!(path, """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>application-identifier</key>
            <string>#{team_id}.#{bundle_id}</string>
            <key>com.apple.developer.team-identifier</key>
            <string>#{team_id}</string>
            <key>get-task-allow</key>
            <true/>
        #{if aps_env, do: "    <key>aps-environment</key>\n    <string>#{aps_env}</string>\n", else: ""}\
        </dict>
        </plist>
        """)

        path
    end
  end

  defp read_aps_environment(profile_path) do
    # `security cms -D -i <profile>` decodes the CMS-wrapped XML plist;
    # we route it through a temp file because PlistBuddy doesn't read
    # stdin reliably and System.cmd doesn't pipe.
    tmp_plist =
      Path.join(System.tmp_dir!(), "mob_aps_#{System.unique_integer([:positive])}.plist")

    try do
      case System.cmd("security", ["cms", "-D", "-i", profile_path, "-o", tmp_plist],
             stderr_to_stdout: true
           ) do
        {_, 0} ->
          case System.cmd(
                 "/usr/libexec/PlistBuddy",
                 ["-c", "Print :Entitlements:aps-environment", tmp_plist],
                 stderr_to_stdout: true
               ) do
            {value, 0} -> String.trim(value)
            _ -> nil
          end

        _ ->
          nil
      end
    after
      File.rm(tmp_plist)
    end
  end

  defp codesign_python_dylibs(otp_bundle, sign_identity) do
    IO.puts("  === Codesigning bundled Python dylibs")
    lib_dynload = Path.join([otp_bundle, "python", "lib", "python3.13", "lib-dynload"])

    so_files = Path.wildcard("#{lib_dynload}/**/*.so")

    Enum.each(so_files, fn so ->
      {_, 0} =
        System.cmd(
          "codesign",
          ["--force", "--sign", sign_identity, "--timestamp=none", so],
          stderr_to_stdout: true
        )
    end)

    IO.puts("  signed #{length(so_files)} lib-dynload extensions")

    framework = Path.join([otp_bundle, "python", "Python.framework", "Python"])

    if File.exists?(framework) do
      {_, 0} =
        System.cmd(
          "codesign",
          ["--force", "--sign", sign_identity, "--timestamp=none", framework],
          stderr_to_stdout: true
        )

      IO.puts("  signed Python.framework/Python")
    end

    Path.wildcard("#{otp_bundle}/lib/**/libpythonx.so")
    |> Enum.each(fn pythonx ->
      {_, 0} =
        System.cmd(
          "codesign",
          ["--force", "--sign", sign_identity, "--timestamp=none", pythonx],
          stderr_to_stdout: true
        )

      IO.puts("  signed #{Path.relative_to(pythonx, otp_bundle)}")
    end)
  end

  defp devicectl_install(udid, app_path) do
    IO.puts("  === Installing on device #{udid}")

    case System.cmd(
           "xcrun",
           ["devicectl", "device", "install", "app", "--device", udid, app_path],
           stderr_to_stdout: true,
           into: IO.stream()
         ) do
      {_, 0} -> :ok
      {_, code} -> {:error, "devicectl install failed (exit #{code}) — check output above"}
    end
  end

  defp throw_bundle_id_error,
    do: throw({:error, "bundle_id not set in mob.exs"})

  # Returns {:ok, cfg_with_signing} or {:error, reason}.
  # Values already in mob.exs are kept; missing ones are auto-detected from the
  # keychain and provisioning profile directories. Fails with a clear message only
  # when auto-detection itself finds multiple candidates and can't pick one.
  defp check_device_signing_config(cfg) do
    bundle_id = cfg[:bundle_id]

    with {:ok, identity} <- resolve_sign_identity(cfg[:ios_sign_identity], cfg[:ios_team_id]),
         {:ok, {profile_uuid, team_id}} <-
           resolve_profile_uuid(cfg[:ios_profile_uuid], bundle_id, cfg[:ios_team_id]) do
      {:ok,
       cfg
       |> Keyword.put(:ios_sign_identity, identity)
       |> Keyword.put(:ios_team_id, team_id)
       |> Keyword.put(:ios_profile_uuid, profile_uuid)}
    end
  end

  # Resolves signing identity. Returns {:ok, identity} or {:error, reason}.
  defp resolve_sign_identity(identity, _team_id) when is_binary(identity), do: {:ok, identity}

  defp resolve_sign_identity(_identity, _team_id) do
    case System.cmd("security", ["find-identity", "-v", "-p", "codesigning"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        identities =
          Regex.scan(Regex.compile!("\\d+\\) [0-9A-F]+ \"([^\"]+)\""), output)
          |> Enum.map(fn [_, full] -> full end)
          |> Enum.filter(&String.contains?(&1, "Apple Development"))
          |> Enum.uniq()

        case identities do
          [] ->
            {:error,
             """
             No Apple Development signing identity found in the keychain.

             One-time setup:
             1. Open Xcode → Settings → Accounts → add your Apple ID
             2. Select your team → click "Download Manual Profiles"
             3. Close Xcode

             This installs a development certificate into your Keychain so mob
             can sign device builds without Xcode.
             """}

          [identity] ->
            IO.puts(
              "  #{IO.ANSI.cyan()}Auto-detected signing identity: #{identity}#{IO.ANSI.reset()}"
            )

            {:ok, identity}

          many ->
            choices = Enum.map_join(many, "\n", &"    #{&1}")

            {:error,
             """
             Multiple signing identities found — add ios_sign_identity to mob.exs:

                 config :mob_dev,
                   ios_sign_identity: "Apple Development: you@example.com (XXXXXXXXXX)"

             Available identities:
             #{choices}
             """}
        end

      {out, _} ->
        {:error, "security find-identity failed: #{out}"}
    end
  end

  # Resolves provisioning profile UUID + team ID from profiles on disk.
  # Returns {:ok, {uuid, team_id}} or {:error, reason}.
  # Team ID is read from the profile itself (more reliable than parsing the cert string).
  defp resolve_profile_uuid(uuid, _bundle_id, team_id)
       when is_binary(uuid) and is_binary(team_id),
       do: {:ok, {uuid, team_id}}

  defp resolve_profile_uuid(uuid, bundle_id, _team_id) do
    profile_dirs = [
      Path.expand("~/Library/Developer/Xcode/UserData/Provisioning Profiles"),
      Path.expand("~/Library/MobileDevice/Provisioning Profiles")
    ]

    all_profiles =
      Enum.flat_map(profile_dirs, &Path.wildcard(Path.join(&1, "*.mobileprovision")))
      |> Enum.flat_map(&Release.parse_mobileprovision/1)

    # `mix mob.deploy --native` is for installing dev builds on registered
    # test devices (via xcrun devicectl). devicectl rejects App Store / Beta
    # profiles with "Attempted to install a Beta profile without the proper
    # entitlement" — so filter to Development profiles only:
    #   - Development:  provisioned_devices? = true,  provisions_all_devices? = false
    #   - Ad Hoc:       provisioned_devices? = true,  provisions_all_devices? = false (signed
    #                   with Distribution cert; rare for our flow)
    #   - App Store:    provisioned_devices? = false, provisions_all_devices? = false
    #   - Enterprise:   provisioned_devices? = false, provisions_all_devices? = true
    # We require provisioned_devices? = true. App Store profiles fall through to release.ex.
    dev_profiles = Enum.filter(all_profiles, & &1.provisioned_devices?)

    # Prefer exact bundle ID match; fall back to wildcard profiles (app_id "TEAMID.*")
    exact_profiles =
      Enum.filter(dev_profiles, fn %{app_id: app_id} ->
        String.ends_with?(app_id, ".#{bundle_id}")
      end)

    profiles =
      if exact_profiles != [] do
        exact_profiles
      else
        Enum.filter(dev_profiles, fn %{app_id: app_id} ->
          String.ends_with?(app_id, ".*")
        end)
      end

    candidates =
      if is_binary(uuid) do
        Enum.filter(profiles, &(&1.uuid == uuid))
      else
        profiles
      end

    case candidates do
      [] ->
        {:error, no_dev_profile_message(bundle_id, all_profiles)}

      [%{uuid: found_uuid, app_id: app_id, team_id: team}] ->
        unless is_binary(uuid) do
          IO.puts(
            "  #{IO.ANSI.cyan()}Auto-detected Development profile: #{found_uuid} (team #{team})#{IO.ANSI.reset()}"
          )
        end

        if String.ends_with?(app_id, ".*") do
          IO.puts(
            "  #{IO.ANSI.cyan()}  (using wildcard profile — run `mix mob.provision` to create a dedicated profile for #{bundle_id})#{IO.ANSI.reset()}"
          )
        end

        {:ok, {found_uuid, team}}

      many ->
        choices = Enum.map_join(many, "\n", fn %{uuid: u, app_id: a} -> "    #{u}  (#{a})" end)

        {:error,
         """
         Multiple Development profiles match '#{bundle_id}' — add ios_profile_uuid to mob.exs:

             config :mob_dev, ios_profile_uuid: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

         Matching Development profiles:
         #{choices}
         """}
    end
  end

  # Distinguish "no profiles at all" from "have App Store profile but no Development one".
  # The latter is the conflict case we hit after setting up TestFlight publishing —
  # the user has a working App Store profile but `mob.deploy` needs a Development one.
  defp no_dev_profile_message(bundle_id, all_profiles) do
    has_app_store_profile? =
      Enum.any?(all_profiles, fn %{app_id: app_id} = p ->
        not p.provisioned_devices? and not p.provisions_all_devices? and
          String.ends_with?(app_id, ".#{bundle_id}")
      end)

    if has_app_store_profile? do
      """
      No Development profile found for bundle ID '#{bundle_id}', but an App Store
      profile exists. `mix mob.deploy --native` needs a Development profile —
      App Store profiles can only be installed via TestFlight / App Store, not via
      xcrun devicectl.

      To get one (one-time):
        1. Open https://developer.apple.com/account/resources/profiles/list
        2. Click + → iOS App Development → choose '#{bundle_id}' → select your dev cert
           and the device(s) you want to install on → Generate
        3. Open Xcode → Settings → Accounts → select your team → "Download Manual Profiles"
        4. Re-run `mix mob.deploy --native`

      Now your machine has both profiles. mob_dev picks Development for `mob.deploy`
      and App Store for `mob.release` automatically.
      """
    else
      """
      No provisioning profile found for bundle ID '#{bundle_id}'.

      One-time setup (only needed once per machine):
      1. Open Xcode
      2. Xcode → Settings → Accounts → add your Apple ID if not already listed
      3. Select your team → click "Download Manual Profiles"
      4. Close Xcode — you won't need to open it again

      After that, `mix mob.deploy --native` will find the profile automatically.

      If the bundle ID is not yet registered in your developer account:
          open https://developer.apple.com/account/resources/identifiers/list
      """
    end
  end

  @doc """
  Returns true when the user's project has a built `:pythonx` dependency.

  Detection is via `_build/dev/lib/pythonx/` rather than scanning `mix.exs`
  so users get the same behavior whether they `mix mob.enable python` and
  rely on the dep being added, or vendor pythonx some other way.
  """
  @spec pythonx_in_project?(String.t()) :: boolean()
  def pythonx_in_project?(_project_dir \\ File.cwd!()) do
    dep_in_project?(:pythonx)
  end

  @doc """
  Returns the PYTHON_APPLE_SUPPORT env entry list when Pythonx is in the
  project, otherwise `[]`. Kept public — `mob.release` and other release
  paths still call into this when constructing distribution-mode envs.
  """
  @spec python_apple_support_env(boolean(), String.t() | nil) :: [{String.t(), String.t()}]
  def python_apple_support_env(false, _bundle), do: []
  def python_apple_support_env(true, nil), do: []

  def python_apple_support_env(true, bundle) when is_binary(bundle),
    do: [{"PYTHON_APPLE_SUPPORT", bundle}]

  # Downloads the BeeWare Python-Apple-support bundle iff Pythonx is a dep.
  # Skipped silently for projects without Pythonx.
  defp maybe_ensure_python_bundle do
    if pythonx_in_project?() do
      MobDev.PythonAppleSupport.ensure()
    else
      {:ok, nil}
    end
  end

  @doc """
  True when the current project has `:emlx` in its dependency tree.
  Mirrors `pythonx_in_project?/1` — the trigger for downloading the MLX
  bundle and adding `-Dmlx_static=true` to the iOS Zig build.
  """
  @spec emlx_in_project?(String.t()) :: boolean()
  def emlx_in_project?(_project_dir \\ File.cwd!()) do
    dep_in_project?(:emlx)
  end

  # The old detector checked `_build/dev/lib/<dep>` exists — a STALE build
  # artifact (dep since removed) false-positived, e.g. triggering MLX bundle
  # downloads (and their 404 noise) for apps that don't dep emlx at all.
  # Mix.Project.deps_paths/0 is the dependency truth: hex + path + transitive,
  # immune to leftover _build dirs.
  defp dep_in_project?(name) do
    __dep_in_project__(Mix.Project.deps_paths(), name)
  rescue
    # Outside a Mix project context, fall back to "not present".
    _ -> false
  end

  @doc false
  # Pure kernel, public for tests.
  @spec __dep_in_project__(%{atom() => Path.t()}, atom()) :: boolean()
  def __dep_in_project__(deps_paths, name), do: Map.has_key?(deps_paths, name)

  # Downloads the cross-compiled MLX bundle iff EMLX is a dep, for the given
  # target slice. Returns `{:ok, nil}` for projects without EMLX so the
  # iOS-sim and iOS-device build paths can pattern-match the same shape.
  defp maybe_ensure_mlx_dir(:ios_device) do
    if emlx_in_project?() do
      MobDev.MLXDownloader.ensure_ios_device()
    else
      {:ok, nil}
    end
  end

  defp maybe_ensure_mlx_dir(:ios_sim) do
    if emlx_in_project?() do
      MobDev.MLXDownloader.ensure_ios_sim()
    else
      {:ok, nil}
    end
  end

  @doc """
  Returns the UDID of the sole connected physical iOS device, or nil.
  When exactly one physical device is connected, it can be used automatically.
  With zero or 2+ physical devices, returns nil.
  """
  @spec detect_physical_ios() :: String.t() | nil
  def detect_physical_ios do
    auto_detect_physical_ios()
  end

  defp auto_detect_physical_ios do
    if System.find_executable("xcrun") do
      all = MobDev.Discovery.IOS.list_devices()

      physical =
        Enum.filter(all, &(&1.type == :physical and &1.status in [:connected, :discovered]))

      case physical do
        [device] ->
          IO.puts(
            "  #{IO.ANSI.cyan()}Auto-detected physical device: #{device.name || device.serial}#{IO.ANSI.reset()}"
          )

          # If a sim is also booted, surface it so the user knows the
          # alternative without having to memorize `mix mob.devices`.
          # iter 13d note: this was the discoverability gap from
          # issues.md #5 — the iPhone-vs-sim choice was silent.
          booted_sims =
            Enum.filter(all, &(&1.type == :simulator and &1.status == :booted))

          case booted_sims do
            [sim | _] ->
              IO.puts(
                "  #{IO.ANSI.cyan()}  (booted simulator also available — pass `--device #{MobDev.Device.short_id(sim.serial)}` to target #{sim.name} instead)#{IO.ANSI.reset()}"
              )

            [] ->
              :ok
          end

          device.serial

        [_ | _] ->
          IO.puts(
            "  #{IO.ANSI.yellow()}Multiple physical devices connected — use --device <id> to pick one. Building for simulator.#{IO.ANSI.reset()}"
          )

          nil

        [] ->
          nil
      end
    end
  end

  # Physical iOS UDIDs come in several formats:
  #   Old (pre-2021):  40 hex chars, no dashes (e.g. a1b2c3d4e5f6...)
  #   Standard UUID:   8-4-4-4-12 hex (e.g. 12345678-ABCD-1234-ABCD-1234567890AB)
  #   New Apple format: 8-16 hex   (e.g. 00008110-001E1C3A34F8401E)
  # Simulator display_ids are exactly 8 hex chars. Android serials never match.
  @doc """
  When `--device <id>` is given, narrow `platforms` to just the platform
  the device lives on. Drops Android when the id resolves to an iOS
  device (sim or physical), drops iOS otherwise.

  Public so `mix mob.deploy` can apply the same narrowing before calling
  `MobDev.Deployer.deploy_all/1` — otherwise the deployer's per-platform
  `filter_by_device_id` complains "No device matched" against the
  irrelevant platform even though the build itself was correctly
  targeted.

  Returns `platforms` unchanged when `device_id` is nil.
  """
  @spec narrow_platforms_for_device([atom()], String.t() | nil) :: [atom()]
  def narrow_platforms_for_device(platforms, nil), do: platforms

  def narrow_platforms_for_device(platforms, device_id) when is_binary(device_id) do
    narrow_platforms_for_device(platforms, device_id, &MobDev.Discovery.IOS.list_devices/0)
  end

  @doc """
  Variant that takes an iOS-discovery function so tests (and other
  callers that already have the device list in hand) can avoid the
  network-bound `IOS.list_devices/0` LAN scan.

  The lister is called at most once per invocation; both `ios_device?`
  and the physical-UDID format fallback consume the same result.
  """
  @spec narrow_platforms_for_device([atom()], String.t() | nil, (-> [MobDev.Device.t()])) ::
          [atom()]
  def narrow_platforms_for_device(platforms, nil, _lister), do: platforms

  def narrow_platforms_for_device(platforms, device_id, lister)
      when is_binary(device_id) and is_function(lister, 0) do
    devices = lister.()

    if ios_device?(device_id, devices) do
      platforms -- [:android]
    else
      platforms -- [:ios]
    end
  end

  # iOS device UDID matchers — string-based instead of regex so the check
  # works across BEAM/OTP versions (OTP 28 won't reuse precompiled regexes
  # stored in module attributes — `:re.import/1` is undefined or private).
  defp matches_ios_udid_long?(id) when is_binary(id),
    do: byte_size(id) == 40 and all_hex?(id)

  defp matches_ios_udid_long?(_), do: false

  defp matches_ios_udid_short?(id) when is_binary(id) and byte_size(id) == 25 do
    case String.split(id, "-", parts: 2) do
      [a, b] -> byte_size(a) == 8 and all_hex?(a) and byte_size(b) == 16 and all_hex?(b)
      _ -> false
    end
  end

  defp matches_ios_udid_short?(_), do: false

  defp all_hex?(s) when is_binary(s), do: s |> String.to_charlist() |> Enum.all?(&hex?/1)

  defp hex?(c)
       when (c >= ?0 and c <= ?9) or
              (c >= ?a and c <= ?f) or
              (c >= ?A and c <= ?F),
       do: true

  defp hex?(_), do: false

  # True when `id` matches *any* iOS device (sim or physical) in the
  # given `devices` list, OR matches an offline physical-UDID format.
  # Used to decide whether `--device <id>` narrows `platforms` to iOS or
  # Android. Accepts the full serial, the human-friendly `display_id`
  # (e.g. the first 8 chars of a sim UUID which `mix mob.devices`
  # prints), or — for offline devices that discovery doesn't return —
  # the format-based fallback below.
  defp ios_device?(id, devices) do
    Enum.any?(devices, fn d -> MobDev.Device.match_id?(d, id) end) or
      ios_physical_udid?(id, devices)
  end

  # Single-arg form used by build_all/1 — fetches iOS discovery itself
  # since the caller doesn't already have the list. Tests should use the
  # 2-arg form below (or call narrow_platforms_for_device/3) to avoid
  # the network-bound LAN scan.
  defp ios_physical_udid?(id) do
    ios_physical_udid?(id, MobDev.Discovery.IOS.list_devices())
  end

  # True when `id` is recognised as a connected physical iOS device.
  # Both simulator and physical UDIDs are UUIDs in modern Xcode (the
  # 36-char form), so format-only matching is ambiguous. We resolve by
  # consulting `devices` for the device type. Falls back to a format
  # check only when discovery returns nothing for that id — covers the
  # case where a UDID was passed but the device is offline / not yet
  # enumerable, in which case we err on the side of "physical" so the
  # device build is attempted (40-char and short forms are
  # physical-only).
  defp ios_physical_udid?(id, devices) do
    case Enum.find(devices, &(&1.serial == id)) do
      %MobDev.Device{type: :physical} ->
        true

      %MobDev.Device{type: :simulator} ->
        false

      nil ->
        matches_ios_udid_long?(id) or matches_ios_udid_short?(id)
    end
  end

  # ── Toolchain availability ──────────────────────────────────────────────────

  @doc """
  Returns true when the Android build toolchain looks usable from the given
  project directory. Three signals must all be present:

    1. `adb` is on PATH (build needs it to install the APK after Gradle)
    2. `<project_dir>/android/local.properties` exists and sets `sdk.dir`
    3. The directory `sdk.dir` points at exists on disk

  Returns false otherwise so the deploy can skip Android cleanly instead of
  failing late inside Gradle. Pure of side effects.
  """
  @spec android_toolchain_available?(String.t()) :: boolean()
  def android_toolchain_available?(project_dir \\ File.cwd!()) do
    with true <- adb_available?(),
         {:ok, sdk_dir} <- read_sdk_dir(project_dir) do
      File.dir?(sdk_dir)
    else
      _ -> false
    end
  end

  @doc """
  Returns true when an iOS build is feasible: macOS host with `xcrun`
  installed. Linux/Windows always returns false. Pure of side effects.
  """
  @spec ios_toolchain_available?() :: boolean()
  def ios_toolchain_available? do
    macos?() and System.find_executable("xcrun") != nil
  end

  @doc false
  @spec read_sdk_dir(String.t()) :: {:ok, String.t()} | :error
  def read_sdk_dir(project_dir) do
    path = Path.join([project_dir, "android", "local.properties"])

    with {:ok, content} <- File.read(path),
         [_, raw] <- Regex.run(Regex.compile!("^\\s*sdk\\.dir\\s*=\\s*(.+?)\\s*$", "m"), content) do
      {:ok, expand_sdk_dir(raw)}
    else
      _ -> :error
    end
  end

  # Java's `Properties.store()` writes "/Users/me/Android/sdk" but with
  # backslash-colons on Windows; on Unix it round-trips fine. Just trim.
  defp expand_sdk_dir(raw), do: String.trim(raw) |> Path.expand()

  @doc """
  Generates the fallback entitlements plist that `build_device.sh` writes when
  no `ios/*.entitlements` file is found in the project.

  `aps_env` should be `"development"`, `"production"`, or `nil`.  When non-nil
  the `aps-environment` key is included, allowing APNs push token registration
  to succeed.  When nil the key is omitted (the historic default, suitable for
  apps that do not use push notifications).

  This function is public so it can be unit-tested independently of the shell
  script that actually writes the file on device builds.
  """
  @spec fallback_entitlements_plist(String.t(), String.t(), String.t() | nil) :: String.t()
  def fallback_entitlements_plist(team_id, bundle_id, aps_env \\ nil) do
    aps_entry =
      if aps_env do
        "    <key>aps-environment</key>\n    <string>#{aps_env}</string>\n"
      else
        ""
      end

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>application-identifier</key>
        <string>#{team_id}.#{bundle_id}</string>
        <key>com.apple.developer.team-identifier</key>
        <string>#{team_id}</string>
        <key>get-task-allow</key>
        <true/>
    #{aps_entry}</dict>
    </plist>
    """
  end

  defp adb_available?, do: System.find_executable("adb") != nil

  defp macos?, do: match?({:unix, :darwin}, :os.type())

  defp warn_skipped_android do
    IO.puts(
      "  #{IO.ANSI.yellow()}⚠  Skipping Android build — toolchain not detected#{IO.ANSI.reset()}"
    )

    cond do
      not adb_available?() ->
        IO.puts("     `adb` not found on PATH. Install Android Studio (it bundles")
        IO.puts("     adb) or platform-tools, then re-run.")

      not File.exists?(Path.join(["android", "local.properties"])) ->
        IO.puts("     android/local.properties is missing. Run `mix mob.install`")
        IO.puts("     to generate it (auto-detects ANDROID_HOME / Android Studio).")

      true ->
        IO.puts("     android/local.properties has no `sdk.dir` set. Either:")
        IO.puts("       export ANDROID_HOME=/path/to/android/sdk && mix mob.install")
        IO.puts("     or edit android/local.properties and add a sdk.dir= line.")
    end
  end

  defp warn_skipped_ios do
    IO.puts(
      "  #{IO.ANSI.yellow()}⚠  Skipping iOS build — Xcode command-line tools not detected#{IO.ANSI.reset()}"
    )

    if macos?() do
      IO.puts("     Install Xcode and run `xcode-select --install`, then re-run.")
    else
      IO.puts("     iOS builds require macOS.")
    end
  end

  # ── Config ───────────────────────────────────────────────────────────────────

  @doc false
  @spec __load_config__() :: keyword()
  def __load_config__, do: load_config()

  @doc false
  @spec __resolve_elixir_lib__(String.t() | nil) :: String.t()
  def __resolve_elixir_lib__(configured), do: resolve_elixir_lib(configured)

  @doc false
  @spec __project_swift_sources_arg__(keyword()) :: String.t()
  def __project_swift_sources_arg__(cfg), do: project_swift_sources_arg(cfg)

  defp load_config do
    config_file = Path.join(File.cwd!(), "mob.exs")

    unless File.exists?(config_file) do
      Mix.raise("""
      mob.exs not found in #{File.cwd!()}.

      Run `mix mob.install` to configure your project, or
      `mix mob.doctor` to diagnose your environment.
      """)
    end

    cfg = Config.Reader.read!(config_file) |> Keyword.get(:mob_dev, [])

    elixir_lib = resolve_elixir_lib(cfg[:elixir_lib])
    bundle_id = cfg[:bundle_id] || MobDev.Config.bundle_id()

    cfg
    |> Keyword.put(:elixir_lib, elixir_lib)
    |> Keyword.put_new(:bundle_id, bundle_id)
  end

  # Use the mob.exs value if it exists on disk AND its Elixir version matches the
  # running toolchain; otherwise detect from the running BEAM.
  #
  # WHY the version check: the app's .beam files are compiled by the toolchain
  # that runs `mix` (System.version()). The bundled Elixir stdlib must be the
  # SAME version, because macros baked into those BEAMs (Ecto.Migration, regex
  # literals, …) emit calls into compiler internals that move between versions —
  # e.g. `:elixir_quote.validate_quote/1` exists in 1.20.0 final but not in
  # 1.20.0-rc.5. A stale mob.exs `elixir_lib` (rc.5) that still exists on disk
  # would silently ship a mismatched stdlib; the skew is invisible until the app
  # compiles an .exs at runtime on-device (a migration) and dies with `undef`.
  # Android dodged this because its runtime sync auto-detects from the running
  # BEAM; the iOS bundle path trusted the config. Prefer a correct build over an
  # honored-but-stale config, and warn so the user fixes mob.exs.
  defp resolve_elixir_lib(configured) when is_binary(configured) do
    expanded = Path.expand(configured)
    exists? = File.exists?(expanded)

    configured_vsn =
      if exists? do
        MobDev.AppFile.vsn_from_path(Path.join(expanded, "elixir/ebin/elixir.app"))
      end

    toolchain_vsn = System.version()

    case __elixir_lib_decision__(exists?, configured_vsn, toolchain_vsn) do
      {:use_configured} ->
        configured

      {:use_detected, reason} ->
        detected = detect_elixir_lib()

        if reason == :version_skew do
          Mix.shell().info([
            :yellow,
            __elixir_lib_skew_warning__(configured, configured_vsn, toolchain_vsn, detected),
            :reset
          ])
        end

        detected
    end
  end

  defp resolve_elixir_lib(_), do: detect_elixir_lib()

  defp detect_elixir_lib do
    :code.lib_dir(:elixir) |> to_string() |> Path.dirname()
  end

  @doc false
  # Pure decision kernel for resolve_elixir_lib/1 — which lib dir to bundle.
  #   exists?        — configured path present on disk
  #   configured_vsn — Elixir version read from <lib>/elixir/ebin/elixir.app (nil if unreadable)
  #   toolchain_vsn  — System.version(), the compiler that built the app's BEAMs
  # Falls back to the auto-detected (running-BEAM) lib on a missing path or a
  # version skew; honors an unreadable-but-present config (can't prove it wrong).
  @spec __elixir_lib_decision__(boolean(), String.t() | nil, String.t()) ::
          {:use_configured} | {:use_detected, :missing | :version_skew}
  def __elixir_lib_decision__(false, _configured_vsn, _toolchain_vsn),
    do: {:use_detected, :missing}

  def __elixir_lib_decision__(true, nil, _toolchain_vsn), do: {:use_configured}
  def __elixir_lib_decision__(true, vsn, vsn), do: {:use_configured}

  def __elixir_lib_decision__(true, _configured_vsn, _toolchain_vsn),
    do: {:use_detected, :version_skew}

  @doc false
  @spec __elixir_lib_skew_warning__(String.t(), String.t() | nil, String.t(), String.t()) ::
          String.t()
  def __elixir_lib_skew_warning__(configured, configured_vsn, toolchain_vsn, detected) do
    """
    * mob.exs elixir_lib is Elixir #{configured_vsn} but the active toolchain is \
    #{toolchain_vsn}.
        configured: #{configured}
        A mismatched bundled stdlib causes on-device `undef` crashes when the app \
    compiles .exs at runtime (e.g. Ecto migrations: :elixir_quote.validate_quote/1).
        Bundling the toolchain's stdlib instead: #{detected}
        Update mob.exs `elixir_lib` to silence this warning.
    """
  end

  defp project_swift_sources_arg(cfg) do
    cfg
    |> Keyword.get(:project_swift_sources, [])
    |> normalize_project_swift_sources!()
    |> Enum.join(",")
  end

  defp normalize_project_swift_sources!(nil), do: []

  defp normalize_project_swift_sources!(source) when is_binary(source) do
    normalize_project_swift_sources!([source])
  end

  defp normalize_project_swift_sources!(sources) when is_list(sources) do
    sources
    |> Enum.map(&normalize_ios_swift_source!/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_project_swift_sources!(other) do
    Mix.raise(
      ":project_swift_sources must be a string or list of strings, got: #{inspect(other)}"
    )
  end

  defp normalize_ios_swift_source!(source) when is_binary(source) do
    source = String.trim(source)

    if String.contains?(source, ",") do
      Mix.raise(":project_swift_sources entries must not contain commas: #{inspect(source)}")
    end

    if source == "", do: "", else: Path.expand(source)
  end

  defp normalize_ios_swift_source!(other) do
    Mix.raise(":project_swift_sources entries must be strings, got: #{inspect(other)}")
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp check_path(path, key) do
    expanded = if is_binary(path), do: Path.expand(path), else: path

    cond do
      is_nil(path) or path =~ "/path/to/" ->
        {:error, "#{key} not configured in mob.exs — run `mix mob.doctor` for setup help"}

      not File.exists?(expanded) ->
        {:error, "#{key} path not found: #{path} — run `mix mob.doctor` to diagnose"}

      true ->
        :ok
    end
  end

  defp cp(src, dest) do
    System.cmd("cp", [src, dest], stderr_to_stdout: true)
  end
end
