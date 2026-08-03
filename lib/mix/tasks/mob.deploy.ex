defmodule Mix.Tasks.Mob.Deploy do
  use Mix.Task

  alias MobDev.Device

  @shortdoc "Build and deploy to all connected mob devices"

  @moduledoc """
  Compiles the project then pushes BEAM files to all connected
  Android devices and iOS simulators.

  ## Modes

  **Fast deploy** (default) — push BEAMs + restart. Use this for day-to-day
  Elixir code changes. Requires the native app already installed on device.

      mix mob.deploy

  **Full deploy** — build native binary + update APK/app + push BEAMs.
  Use this after changes to native C/Java/Swift code. Android native updates
  are update-only: every target must already have the exact configured package
  installed. The task resolves a non-empty connected-device set, uses only
  serial-scoped `adb install -r`, and never uninstalls or clears the existing
  app, so a signing mismatch or downgrade fails while preserving app data. The
  validated serial snapshot also scopes the final BEAM push, even if device
  discovery changes mid-deploy.

      mix mob.deploy --native

  ## Options

    * `--native`              — build native binaries before pushing BEAMs
    * `--no-restart`          — push BEAMs but don't restart the app (fast deploy
                                only; native Android requires a checked restart)
    * `--device <id>`         — target a specific device; use `mix mob.devices` to find IDs
    * `--dist-port <N>`       — pin the BEAM dist listen port (default: auto-allocated per
                              device, `9100 + index`). Use to resolve EPMD collisions when
                              multiple sims/emulators are running the same app concurrently
                              and the auto-allocated ports aren't what you want.
    * `--node-suffix <S>`     — append `_<S>` to the BEAM node name (default: auto-derived
                              from device serial on Android, SIMULATOR_UDID on iOS sim). Use
                              for scripted scenarios where you need a specific naming scheme.
    * `--schedulers <N>`      — set BEAM scheduler count (saved to mob.exs)
    * `--beam-flags "<flags>"` — arbitrary BEAM flags string (saved to mob.exs)
    * `--slim`                — strip OTP source/debug for size measurement on
                                a real device. OFF by default for dev iteration
                                (the strip pass adds ~5-10s per build); use this
                                to verify a slim build runs before
                                `mix mob.republish` round-trips through TestFlight.
                                The strip set is controlled by `MobDev.OtpAudit.Slim`;
                                per-app overrides live in `mob.exs`:

                                    config :mob_dev,
                                      slim: [
                                        drop_libs: ["my_unused_dep"],
                                        keep_libs: ["mnesia"],
                                        audit: true,                       # opt in
                                        # Single capture (a starting point):
                                        trace_json: "priv/mob_trace.json",
                                        # OR multiple captures unioned —
                                        # much safer for production
                                        # stripping. A lib is trace-
                                        # strippable only if NONE of the
                                        # captures observed any of its
                                        # modules.
                                        trace_jsons: [
                                          "priv/boot.json",
                                          "priv/ui.json",
                                          "priv/auth.json"
                                        ]
                                      ]

                                With `audit: true`, the slim pass runs
                                `MobDev.OtpAudit` against the bundle and
                                expands the strip set with foreign apps
                                + (when a trace is supplied) the
                                trace-augmented strip set. Trace JSON
                                comes from `mix mob.trace_otp --json`.

  ## BEAM scheduler tuning

  The default native build uses `1:1` (single scheduler) for battery efficiency.
  Override for the current deploy and all future deploys until changed:

      # Pin to 2 schedulers
      mix mob.deploy --schedulers 2

      # Let BEAM auto-detect — one scheduler per logical core
      mix mob.deploy --schedulers 0

      # Arbitrary flags (replaces --schedulers)
      mix mob.deploy --beam-flags "-S 4:4 -A 4"

  The chosen value is written to `mob.exs` under `beam_flags:` and reused on
  subsequent `mix mob.deploy` runs that don't pass either flag. The flags are
  written alongside the BEAMs as a `mob_beam_flags` file that the native launcher
  reads at startup — no APK/app rebuild required.

  ## Under the hood

  A fast deploy is equivalent to:

      mix deps.get                                     # only with --native
      mix compile

      # Android
      adb push _build/prod/lib/*/ebin/*.beam /data/data/<pkg>/files/lib/*/ebin/
      adb shell am force-stop <package>               # restart

      # iOS simulator
      xcrun simctl spawn <udid> cp <beam_files> <app_bundle>/

  When Erlang distribution is already reachable (app running, node connected),
  `mix mob.deploy` skips `adb push` and hot-pushes via RPC instead — equivalent
  to calling `nl(Module)` in IEx for every changed module:

      :rpc.call(node, :code, :load_binary, [Module, path, beam_binary])

  With `--native`, it also runs the platform build before pushing BEAMs:

      # Android
      ./gradlew assembleDebug
      adb install -r app/build/outputs/apk/debug/app-debug.apk

      # iOS simulator
      xcodebuild -scheme <app> -destination 'platform=iOS Simulator,...' build
      xcrun simctl install booted <app>.app
  """

  @switches [
    native: :boolean,
    restart: :boolean,
    android: :boolean,
    ios: :boolean,
    device: :string,
    schedulers: :integer,
    beam_flags: :string,
    # Manual overrides for the BEAM-distribution surface — useful when
    # the auto-allocated per-device dist port (`Tunnel.dist_port(idx)`)
    # or auto-derived node-name suffix (`Discovery.Android.device_node_suffix`
    # / SIMULATOR_UDID-derived) collides with another locally-running
    # device, or when scripting a specific naming scheme.
    #
    # When set, ALL targeted devices share the same value (so use with
    # `--device` to be explicit about which one you mean). Auto-allocation
    # only kicks in when neither flag is set.
    dist_port: :integer,
    node_suffix: :string,
    # Slim build (drops src/include + .beam debug chunks + Apple-policy strips).
    # On by default for both dev and release. Pass `--no-slim` to keep the
    # full OTP runtime in the bundle — useful if you need debug info on
    # device, or to isolate a strip-induced regression during diagnosis.
    slim: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: @switches)

    restart = Keyword.get(opts, :restart, true)
    native = Keyword.get(opts, :native, false)
    device_id = opts[:device]
    platforms = resolve_platforms(opts)
    # Narrow once at the task level so build_all and deploy_all both see the
    # same platform list. Without this, the deployer iterates over the
    # irrelevant platform and `filter_by_device_id` emits a misleading
    # "No device matched" warning even when the targeted platform succeeded.
    platforms = MobDev.NativeBuild.narrow_platforms_for_device(platforms, device_id)
    beam_flags = resolve_beam_flags(opts)

    if native and not restart and :android in platforms do
      Mix.raise("Native Android deploy requires an authoritative restart; remove --no-restart")
    end

    # When no --device is given and we're doing a native iOS build, auto-detect
    # a connected physical device now so both the native build and the BEAM push
    # target the same device (not all simulators + the phone).
    effective_device_id =
      device_id ||
        if native and :ios in platforms,
          do: MobDev.NativeBuild.detect_physical_ios()

    # Validate every targeted device against the project's enabled
    # features (Pythonx, etc.) BEFORE we waste time on a multi-minute
    # native build that the device couldn't have run anyway. See
    # `MobDev.SupportMatrix` for the per-feature requirements and why
    # silent failures here are particularly costly for users on older
    # / cheaper hardware.
    #
    # `MOB_FORCE_DEPLOY=1` bypasses for the trust-but-verify case
    # ("I know my device is below the floor; show me what actually
    # breaks"). The Moto e empirical run that uncovered the corrected
    # `:base` armv7 floor used this — the SupportMatrix message is
    # only as good as the data it's based on, and an escape hatch is
    # how we keep that data honest.
    if System.get_env("MOB_FORCE_DEPLOY") in [nil, ""] do
      validate_device_compatibility!(platforms, effective_device_id)
    else
      IO.puts(
        "  #{IO.ANSI.yellow()}MOB_FORCE_DEPLOY set — skipping device compatibility check#{IO.ANSI.reset()}"
      )
    end

    IO.puts("")

    if native do
      fetch_native_dependencies!()
    end

    Mix.Task.run("compile")
    IO.puts("\n#{IO.ANSI.cyan()}Deploying to devices...#{IO.ANSI.reset()}\n")

    # Default OFF for dev iteration: slim adds the strip pass + erl spawn
    # for beam_lib:strip_release + xcrun strip, which costs seconds. Dev
    # cycle wants those seconds back. Opt in with `--slim` when you want
    # to size-test before mix mob.republish round-trips through TestFlight
    # (and the inevitable extra TestFlight build that confuses testers).
    slim = Keyword.get(opts, :slim, false)

    deploy_opts =
      [
        restart: restart,
        platforms: platforms,
        force_fs: native,
        device: device_id,
        ios_device: effective_device_id,
        beam_flags: beam_flags,
        # nil → auto-allocation (per-device port + auto-derived suffix).
        # Set → all targeted devices use these values verbatim.
        dist_port: opts[:dist_port],
        node_suffix: opts[:node_suffix]
      ]

    deploy_result =
      if native do
        native_opts = [
          slim: slim,
          android_preinstall: fn native_context ->
            MobDev.Deployer.prepare_android_payload(native_context,
              restart: restart,
              beam_flags: beam_flags,
              dist_port: opts[:dist_port],
              node_suffix: opts[:node_suffix]
            )
          end,
          android_preinstall_cleanup: &MobDev.Deployer.cleanup_android_payload/1
        ]

        execute_native_deploy!(
          platforms,
          device_id,
          effective_device_id,
          native_opts,
          deploy_opts
        )
      else
        deploy_after_native_build!(false, nil, deploy_opts)
      end

    report_deploy_result!(deploy_result, restart: restart)
  end

  @doc false
  @spec execute_native_deploy!(
          [:android | :ios],
          String.t() | nil,
          String.t() | nil,
          keyword(),
          keyword(),
          keyword()
        ) :: {[Device.t()], [Device.t()], [Device.t()]}
  def execute_native_deploy!(
        platforms,
        android_device_id,
        ios_device_id,
        native_opts,
        deploy_opts,
        callbacks \\ []
      ) do
    builder = Keyword.get(callbacks, :builder, &MobDev.NativeBuild.build_all_with_outcome/1)
    deployer = Keyword.get(callbacks, :deployer, &MobDev.Deployer.deploy_all_with_lease/1)

    finalizer =
      Keyword.get(callbacks, :finalizer, &MobDev.NativeBuild.release_android_deploy_lock/1)

    cleanup = Keyword.get(callbacks, :cleanup, &MobDev.Deployer.cleanup_android_payload/1)

    valid? =
      valid_native_platforms?(platforms) and is_list(native_opts) and
        Keyword.keyword?(native_opts) and is_list(deploy_opts) and Keyword.keyword?(deploy_opts) and
        valid_optional_device_id?(android_device_id) and valid_optional_device_id?(ios_device_id) and
        is_function(builder, 1) and is_function(deployer, 1) and is_function(finalizer, 1) and
        is_function(cleanup, 1)

    if valid? do
      execute_native_platforms!(
        platforms,
        android_device_id,
        ios_device_id,
        native_opts,
        deploy_opts,
        builder,
        deployer,
        finalizer,
        cleanup
      )
    else
      raise_native_build_failed!()
    end
  end

  defp execute_native_platforms!(
         platforms,
         android_device_id,
         ios_device_id,
         native_opts,
         deploy_opts,
         builder,
         deployer,
         finalizer,
         cleanup
       ) do
    cond do
      :android in platforms and :ios in platforms ->
        execute_mixed_native_platforms!(
          android_device_id,
          ios_device_id,
          native_opts,
          deploy_opts,
          builder,
          deployer,
          finalizer,
          cleanup
        )

      :android in platforms ->
        run_native_platform!(
          :android,
          android_device_id,
          native_opts,
          deploy_opts,
          builder,
          deployer,
          finalizer,
          cleanup
        )

      true ->
        run_native_platform!(
          :ios,
          ios_device_id,
          native_opts,
          deploy_opts,
          builder,
          deployer,
          finalizer,
          cleanup
        )
    end
  end

  defp execute_mixed_native_platforms!(
         android_device_id,
         ios_device_id,
         native_opts,
         deploy_opts,
         builder,
         deployer,
         finalizer,
         cleanup
       ) do
    android_build_opts = native_platform_build_opts(native_opts, :android, android_device_id)
    android_outcome = builder.(android_build_opts)

    case android_outcome do
      %{
        ok?: false,
        android_device_disposition: :not_attempted,
        android_serials: [],
        android_deploy_lock: nil,
        android_payload_plan: nil
      } = not_attempted
      when map_size(not_attempted) == 5 ->
        run_native_platform!(
          :ios,
          ios_device_id,
          native_opts,
          deploy_opts,
          builder,
          deployer,
          finalizer,
          cleanup
        )

      _attempted_or_malformed ->
        android_result =
          deploy_native_platform_outcome!(
            :android,
            android_device_id,
            android_outcome,
            deploy_opts,
            deployer,
            finalizer,
            cleanup
          )

        case android_result do
          {_deployed, [], _skipped} ->
            ios_result =
              run_native_platform!(
                :ios,
                ios_device_id,
                native_opts,
                deploy_opts,
                builder,
                deployer,
                finalizer,
                cleanup
              )

            merge_deploy_results([android_result, ios_result])

          _android_failed ->
            android_result
        end
    end
  end

  defp run_native_platform!(
         platform,
         device_id,
         native_opts,
         deploy_opts,
         builder,
         deployer,
         finalizer,
         cleanup
       ) do
    outcome = builder.(native_platform_build_opts(native_opts, platform, device_id))

    deploy_native_platform_outcome!(
      platform,
      device_id,
      outcome,
      deploy_opts,
      deployer,
      finalizer,
      cleanup
    )
  end

  defp native_platform_build_opts(native_opts, platform, device_id) do
    native_opts
    |> Keyword.put(:platforms, [platform])
    |> Keyword.put(:device, device_id)
    |> Keyword.put(:android_device_phase, platform == :android)
    |> maybe_drop_android_callbacks(platform)
  end

  defp deploy_native_platform_outcome!(
         platform,
         device_id,
         outcome,
         deploy_opts,
         deployer,
         finalizer,
         cleanup
       ) do
    platform_deploy_opts =
      deploy_opts
      |> Keyword.put(:platforms, [platform])
      |> Keyword.delete(:canonical_android_serials)
      |> Keyword.delete(:android_deploy_lock)
      |> Keyword.delete(:android_payload_plan)
      |> platform_device_opts(platform, device_id)

    deploy_after_native_build!(
      true,
      outcome,
      platform_deploy_opts,
      deployer,
      finalizer,
      cleanup
    )
  end

  defp maybe_drop_android_callbacks(opts, :android), do: opts

  defp maybe_drop_android_callbacks(opts, :ios) do
    opts
    |> Keyword.delete(:android_preinstall)
    |> Keyword.delete(:android_preinstall_cleanup)
  end

  defp platform_device_opts(opts, :android, device_id) do
    opts
    |> Keyword.put(:device, device_id)
    |> Keyword.delete(:ios_device)
  end

  defp platform_device_opts(opts, :ios, device_id) do
    opts
    |> Keyword.put(:device, nil)
    |> Keyword.put(:ios_device, device_id)
  end

  defp valid_optional_device_id?(nil), do: true

  defp valid_optional_device_id?(device_id) when is_binary(device_id),
    do: byte_size(device_id) in 1..256 and String.valid?(device_id)

  defp valid_optional_device_id?(_device_id), do: false

  @doc false
  @spec deploy_after_native_build!(
          boolean(),
          MobDev.NativeBuild.build_outcome() | nil,
          keyword()
        ) ::
          {[Device.t()], [Device.t()], [Device.t()]}
  def deploy_after_native_build!(true, native_outcome, deploy_opts) do
    deploy_after_native_build!(
      true,
      native_outcome,
      deploy_opts,
      &MobDev.Deployer.deploy_all_with_lease/1,
      &MobDev.NativeBuild.release_android_deploy_lock/1,
      &MobDev.Deployer.cleanup_android_payload/1
    )
  end

  def deploy_after_native_build!(false, native_outcome, deploy_opts) do
    deploy_after_native_build!(
      false,
      native_outcome,
      deploy_opts,
      &MobDev.Deployer.deploy_all/1,
      &MobDev.NativeBuild.release_android_deploy_lock/1,
      &MobDev.Deployer.cleanup_android_payload/1
    )
  end

  @doc false
  @spec deploy_after_native_build!(
          boolean(),
          MobDev.NativeBuild.build_outcome() | nil,
          keyword(),
          (keyword() -> {[Device.t()], [Device.t()], [Device.t()]})
        ) :: {[Device.t()], [Device.t()], [Device.t()]}
  def deploy_after_native_build!(native, native_outcome, deploy_opts, deployer) do
    deploy_after_native_build!(
      native,
      native_outcome,
      deploy_opts,
      deployer,
      &MobDev.NativeBuild.release_android_deploy_lock/1,
      &MobDev.Deployer.cleanup_android_payload/1
    )
  end

  @doc false
  @spec deploy_after_native_build!(
          boolean(),
          MobDev.NativeBuild.build_outcome() | nil,
          keyword(),
          (keyword() -> {[Device.t()], [Device.t()], [Device.t()]}),
          (map() -> :ok | {:error, String.t()} | {:error, String.t(), map()})
        ) :: {[Device.t()], [Device.t()], [Device.t()]}
  def deploy_after_native_build!(
        native,
        native_outcome,
        deploy_opts,
        deployer,
        lock_finalizer
      ) do
    deploy_after_native_build!(
      native,
      native_outcome,
      deploy_opts,
      deployer,
      lock_finalizer,
      &MobDev.Deployer.cleanup_android_payload/1
    )
  end

  @doc false
  @spec deploy_after_native_build!(
          boolean(),
          MobDev.NativeBuild.build_outcome() | nil,
          keyword(),
          (keyword() -> term()),
          (map() -> :ok | {:error, term()}),
          (map() -> term())
        ) :: {[Device.t()], [Device.t()], [Device.t()]}
  def deploy_after_native_build!(
        true,
        %{
          ok?: true,
          android_device_disposition: android_device_disposition,
          android_serials: android_serials,
          android_deploy_lock: android_deploy_lock,
          android_payload_plan: android_payload_plan
        },
        deploy_opts,
        deployer,
        lock_finalizer,
        payload_cleanup
      )
      when is_list(android_serials) and is_function(deployer, 1) and
             is_function(lock_finalizer, 1) and is_function(payload_cleanup, 1) do
    try do
      valid_opts? = is_list(deploy_opts) and Keyword.keyword?(deploy_opts)
      platforms = if valid_opts?, do: Keyword.get(deploy_opts, :platforms, [:android, :ios])
      restart = if valid_opts?, do: Keyword.get(deploy_opts, :restart, true)

      consistent_platform? =
        is_list(platforms) and
          ((android_device_disposition == :not_attempted and android_serials == [] and
              is_nil(android_deploy_lock) and
              is_nil(android_payload_plan)) or
             (android_device_disposition == :held and android_serials != [] and
                :android in platforms and is_map(android_deploy_lock) and
                is_map(android_payload_plan)))

      with true <- valid_opts?,
           true <- valid_native_platforms?(platforms),
           true <- consistent_platform?,
           :ok <- validate_native_android_lock(android_deploy_lock, android_serials),
           true <- valid_native_restart?(restart, android_serials) do
        deploy_native_targets(
          deploy_opts,
          android_serials,
          android_deploy_lock,
          android_payload_plan,
          deployer,
          lock_finalizer
        )
      else
        _invalid_or_noncommittable -> raise_native_build_failed!()
      end
    after
      cleanup_native_android_payload(android_payload_plan, payload_cleanup)
    end
  end

  def deploy_after_native_build!(
        true,
        native_outcome,
        _deploy_opts,
        _deployer,
        _finalizer,
        payload_cleanup
      )
      when is_function(payload_cleanup, 1) do
    payload_plan = if is_map(native_outcome), do: Map.get(native_outcome, :android_payload_plan)

    try do
      raise_native_build_failed!()
    after
      cleanup_native_android_payload(payload_plan, payload_cleanup)
    end
  end

  def deploy_after_native_build!(
        false,
        _native_outcome,
        deploy_opts,
        deployer,
        _finalizer,
        _payload_cleanup
      ) do
    deployer.(deploy_opts)
  end

  defp raise_native_build_failed! do
    IO.puts("\n#{IO.ANSI.red()}Native build had failures — see errors above.#{IO.ANSI.reset()}")

    IO.puts(
      "#{IO.ANSI.yellow()}Run `mix mob.doctor` to check your environment, or `mix mob.deploy` (without --native) once the issue is fixed.#{IO.ANSI.reset()}"
    )

    Mix.raise("Native build failed")
  end

  defp fetch_native_dependencies! do
    IO.puts("Fetching dependencies...")

    with mix when is_binary(mix) <- System.find_executable("mix"),
         {_output, 0} <- System.cmd(mix, ["deps.get"], into: IO.stream()) do
      :ok
    else
      nil -> Mix.raise("Could not find mix while preparing the native deploy")
      {_output, _status} -> Mix.raise("Could not fetch dependencies for the native deploy")
    end
  end

  defp validate_native_android_lock(nil, []), do: :ok

  defp validate_native_android_lock(lock, canonical_serials)
       when is_map(lock) and is_list(canonical_serials) do
    if canonical_serials != [] and canonical_serials == Enum.sort(canonical_serials) and
         Enum.uniq(canonical_serials) == canonical_serials and
         MobDev.AndroidDeployLock.valid?(lock, :native_ready) and
         lock.bundle_id == MobDev.Config.bundle_id() and lock.serials == canonical_serials do
      :ok
    else
      {:error, :invalid_native_android_lock}
    end
  end

  defp validate_native_android_lock(_lock, _serials),
    do: {:error, :invalid_native_android_lock}

  defp valid_native_platforms?(platforms) when is_list(platforms) do
    platforms != [] and Enum.uniq(platforms) == platforms and
      Enum.all?(platforms, &(&1 in [:android, :ios]))
  end

  defp valid_native_platforms?(_platforms), do: false

  defp valid_native_restart?(restart, []), do: restart in [true, false]
  defp valid_native_restart?(true, [_serial | _]), do: true
  defp valid_native_restart?(_restart, _serials), do: false

  defp deploy_native_targets(
         deploy_opts,
         android_serials,
         android_deploy_lock,
         android_payload_plan,
         deployer,
         lock_finalizer
       ) do
    platforms = Keyword.get(deploy_opts, :platforms, [:android, :ios])
    remaining_platforms = platforms -- [:android]

    if android_serials == [] and remaining_platforms == [] do
      raise_native_build_failed!()
    end

    android_results =
      if :android in platforms and android_serials != [] do
        {raw_android_result, committed_lock} =
          deploy_opts
          |> Keyword.put(:platforms, [:android])
          |> Keyword.put(:canonical_android_serials, android_serials)
          |> Keyword.put(:android_deploy_lock, android_deploy_lock)
          |> Keyword.put(:android_payload_plan, android_payload_plan)
          |> Keyword.delete(:device)
          |> deployer.()
          |> normalize_native_deployer_result()

        android_result = enforce_native_android_targets(raw_android_result, android_serials)

        [
          finalize_native_android_lock(
            android_result,
            android_deploy_lock,
            committed_lock,
            lock_finalizer
          )
        ]
      else
        []
      end

    case android_results do
      [{_deployed, [_failure | _], _skipped}] ->
        merge_deploy_results(android_results)

      _android_committed_or_absent ->
        remaining_results =
          if remaining_platforms == [] do
            []
          else
            remaining_opts =
              deploy_opts
              |> Keyword.put(:platforms, remaining_platforms)
              |> Keyword.delete(:canonical_android_serials)
              |> Keyword.delete(:android_deploy_lock)
              |> Keyword.delete(:android_payload_plan)

            [remaining_opts |> deployer.() |> normalize_remaining_deployer_result()]
          end

        merge_deploy_results(android_results ++ remaining_results)
    end
  end

  defp finalize_native_android_lock(
         {deployed, [], []} = result,
         native_lock,
         committed_lock,
         finalizer
       )
       when is_map(native_lock) do
    with :ok <- validate_committed_android_lock(committed_lock, native_lock),
         :ok <- finalizer.(committed_lock) do
      result
    else
      _invalid_failure_or_ambiguity ->
        {[],
         Enum.map(deployed, fn device ->
           native_target_failure(device, "Native Android deploy-lock release failed")
         end), []}
    end
  end

  defp finalize_native_android_lock(
         {deployed, failed, skipped},
         native_lock,
         _committed_lock,
         _finalizer
       )
       when is_map(native_lock) do
    uncommitted =
      Enum.map(deployed ++ skipped, fn device ->
        native_target_failure(
          device,
          "Native Android target set did not reach an authoritative commit"
        )
      end)

    {[], uncommitted ++ failed, []}
  end

  defp finalize_native_android_lock(result, _native_lock, _committed_lock, _finalizer),
    do: result

  defp validate_committed_android_lock(
         %{phase: :final_committed, state: :held_success} = committed,
         %{phase: :native_ready, state: :held_success} = native
       ) do
    identity_fields = [:bundle_id, :owner, :serials, :target_digest]

    if MobDev.AndroidDeployLock.valid?(committed, :final_committed) and
         MobDev.AndroidDeployLock.valid?(native, :native_ready) and
         Map.take(committed, identity_fields) == Map.take(native, identity_fields),
       do: :ok,
       else: {:error, :committed_lock_identity_mismatch}
  end

  defp validate_committed_android_lock(_committed, _native),
    do: {:error, :invalid_committed_lock}

  defp normalize_native_deployer_result({{deployed, failed, skipped}, lease})
       when is_list(deployed) and is_list(failed) and is_list(skipped) do
    if valid_device_buckets?([deployed, failed, skipped]),
      do: {{deployed, failed, skipped}, lease},
      else: {{[], [], []}, nil}
  end

  defp normalize_native_deployer_result({deployed, failed, skipped})
       when is_list(deployed) and is_list(failed) and is_list(skipped) do
    if valid_device_buckets?([deployed, failed, skipped]),
      do: {{deployed, failed, skipped}, nil},
      else: {{[], [], []}, nil}
  end

  defp normalize_native_deployer_result(_invalid), do: {{[], [], []}, nil}

  defp normalize_remaining_deployer_result({{deployed, failed, skipped}, _lease})
       when is_list(deployed) and is_list(failed) and is_list(skipped) do
    if valid_device_buckets?([deployed, failed, skipped]),
      do: {deployed, failed, skipped},
      else: raise_native_build_failed!()
  end

  defp normalize_remaining_deployer_result({deployed, failed, skipped})
       when is_list(deployed) and is_list(failed) and is_list(skipped) do
    if valid_device_buckets?([deployed, failed, skipped]),
      do: {deployed, failed, skipped},
      else: raise_native_build_failed!()
  end

  defp normalize_remaining_deployer_result(_invalid), do: raise_native_build_failed!()

  defp valid_device_buckets?([deployed, failed, skipped]) do
    valid_device_bucket?(deployed, :deployed) and
      valid_device_bucket?(failed, :failed) and
      valid_device_bucket?(skipped, :skipped)
  end

  defp valid_device_buckets?(_invalid), do: false

  defp valid_device_bucket?(bucket, expected_bucket) do
    Enum.all?(bucket, fn
      %Device{platform: platform, serial: serial, status: status}
      when platform in [:android, :ios] and is_binary(serial) ->
        byte_size(serial) in 1..256 and String.valid?(serial) and
          valid_bucket_status?(expected_bucket, status)

      _invalid ->
        false
    end)
  end

  defp valid_bucket_status?(:deployed, status), do: status not in [:error, :skipped]
  defp valid_bucket_status?(:failed, :error), do: true
  defp valid_bucket_status?(:skipped, :skipped), do: true
  defp valid_bucket_status?(_bucket, _status), do: false

  defp cleanup_native_android_payload(nil, _cleanup), do: :ok

  defp cleanup_native_android_payload(payload_plan, cleanup) when is_map(payload_plan) do
    try do
      case cleanup.(payload_plan) do
        :ok -> :ok
        _failed_or_invalid -> warn_android_payload_cleanup_failed()
      end
    catch
      _kind, _reason -> warn_android_payload_cleanup_failed()
    end
  end

  defp cleanup_native_android_payload(_untrusted_payload_plan, _cleanup), do: :ok

  defp warn_android_payload_cleanup_failed do
    IO.puts(
      "#{IO.ANSI.yellow()}Could not clean local Android deploy staging; no device cleanup was attempted.#{IO.ANSI.reset()}"
    )

    :ok
  end

  defp enforce_native_android_targets({deployed, failed, skipped}, serials) do
    canonical = MapSet.new(serials)

    tagged =
      Enum.map(deployed, &{:deployed, &1}) ++
        Enum.map(failed, &{:failed, &1}) ++ Enum.map(skipped, &{:skipped, &1})

    grouped =
      Enum.group_by(tagged, fn {_bucket, device} -> {device.platform, device.serial} end)

    canonical_results =
      Enum.map(serials, fn serial ->
        case Map.get(grouped, {:android, serial}, []) do
          [{:deployed, device}] ->
            {:deployed, device}

          [{:failed, device}] ->
            {:failed, device}

          [{:skipped, device}] ->
            {:failed,
             native_target_failure(
               device,
               "Native Android target became unavailable after install"
             )}

          [] ->
            {:failed,
             %Device{
               platform: :android,
               serial: serial,
               status: :error,
               error: "Native Android target was not accounted for after install"
             }}

          _duplicate_or_conflicting ->
            {:failed,
             %Device{
               platform: :android,
               serial: serial,
               status: :error,
               error: "Native Android target produced duplicate or conflicting results"
             }}
        end
      end)

    invalid_results =
      tagged
      |> Enum.reject(fn {_bucket, device} ->
        device.platform == :android and MapSet.member?(canonical, device.serial)
      end)
      |> Enum.map(fn {_bucket, device} ->
        {:failed,
         native_target_failure(device, "Native Android pass reported a non-canonical target")}
      end)

    results = canonical_results ++ invalid_results

    {
      for({:deployed, device} <- results, do: device),
      for({:failed, device} <- results, do: device),
      []
    }
  end

  defp native_target_failure(%Device{} = device, reason) do
    %{device | status: :error, error: reason}
  end

  defp merge_deploy_results(results) do
    {
      Enum.flat_map(results, fn {deployed, _failed, _skipped} -> deployed end),
      Enum.flat_map(results, fn {_deployed, failed, _skipped} -> failed end),
      Enum.flat_map(results, fn {_deployed, _failed, skipped} -> skipped end)
    }
  end

  @doc false
  @spec ensure_deploy_succeeded!({[Device.t()], [Device.t()], [Device.t()]}) :: :ok
  def ensure_deploy_succeeded!({_deployed, [], _skipped}), do: :ok

  def ensure_deploy_succeeded!({_deployed, failed, _skipped}) when is_list(failed) do
    Mix.raise("Deploy failed on #{length(failed)} device(s)")
  end

  @doc false
  @spec report_deploy_result!(
          {[Device.t()], [Device.t()], [Device.t()]},
          keyword()
        ) :: :ok
  def report_deploy_result!({deployed, failed, skipped} = result, opts \\ []) do
    Enum.each(format_summary(deployed, failed, skipped, opts), &IO.puts/1)
    ensure_deploy_succeeded!(result)
  end

  @doc """
  Build the per-deploy summary lines from the three device buckets.

  Returns an iolist of strings (one per line) that the task prints
  verbatim. Public so the report shape can be pinned against fixture
  device lists — keeps "Failed on N" from regressing back into
  counting skipped-because-not-installed devices.

  Opts:
    * `:restart` — boolean; controls the post-deploy IEx hint line
  """
  @spec format_summary([Device.t()], [Device.t()], [Device.t()], keyword()) :: [String.t()]
  def format_summary(deployed, failed, skipped, opts \\ []) do
    restart? = Keyword.get(opts, :restart, true)

    cond do
      deployed == [] and failed == [] and skipped == [] ->
        [
          "#{IO.ANSI.yellow()}No devices found.#{IO.ANSI.reset()}",
          "Try: mix mob.devices   to diagnose connection issues"
        ]

      true ->
        []
        |> append_deployed_block(deployed, restart?)
        |> append_skipped_block(skipped)
        |> append_failed_block(failed)
    end
  end

  defp append_deployed_block(acc, [], _restart?), do: acc

  defp append_deployed_block(acc, deployed, restart?) do
    follow_up =
      if restart? do
        "Apps restarted. Run #{IO.ANSI.cyan()}mix mob.connect#{IO.ANSI.reset()} to open IEx."
      else
        "BEAMs pushed. In IEx: #{IO.ANSI.cyan()}nl(MyModule)#{IO.ANSI.reset()} to hot-load."
      end

    acc ++
      [
        "\n#{IO.ANSI.green()}Deployed to #{length(deployed)} device(s)#{IO.ANSI.reset()}",
        follow_up
      ]
  end

  defp append_skipped_block(acc, []), do: acc

  defp append_skipped_block(acc, skipped) do
    header =
      "\n#{IO.ANSI.yellow()}Skipped on #{length(skipped)} device(s) — app not installed " <>
        "(build for that platform with --android / --ios if intended)#{IO.ANSI.reset()}"

    rows =
      Enum.map(skipped, fn d ->
        "  #{IO.ANSI.faint()}— #{d.name || d.serial}: #{d.error}#{IO.ANSI.reset()}"
      end)

    acc ++ [header | rows]
  end

  defp append_failed_block(acc, []), do: acc

  defp append_failed_block(acc, failed) do
    header = "\n#{IO.ANSI.red()}Failed on #{length(failed)} device(s)#{IO.ANSI.reset()}"
    rows = Enum.map(failed, fn d -> "  ✗ #{d.name || d.serial}: #{d.error}" end)
    acc ++ [header | rows]
  end

  defp resolve_platforms(opts) do
    android = opts[:android]
    ios = opts[:ios]

    cond do
      android && ios ->
        [:android, :ios]

      android ->
        [:android]

      ios ->
        if macos?() do
          [:ios]
        else
          IO.puts(
            "#{IO.ANSI.yellow()}Warning: --ios is only supported on macOS. Skipping iOS.#{IO.ANSI.reset()}"
          )

          []
        end

      macos?() ->
        [:android, :ios]

      true ->
        [:android]
    end
  end

  defp macos?, do: match?({:unix, :darwin}, :os.type())

  # ── Pre-build device compatibility check ────────────────────────────────────
  #
  # The instinct in mobile build pipelines is "let it fail at install / runtime
  # and tell the user something went wrong." That instinct is hostile to users
  # with older or cheaper hardware — they buy a phone, deploy, get a cryptic
  # error, and walk away assuming the framework is broken.
  #
  # We instead query each candidate device's properties up front, cross-
  # reference them against the project's enabled features (Pythonx, etc.), and
  # refuse to proceed with a clear, named-feature, named-reason error when
  # there's a mismatch. The user finds out which device(s) won't work and why
  # before any build runs.
  #
  # We deliberately don't filter — if any one of the targeted devices fails,
  # we halt and surface every device that fails. Skipping unsupported devices
  # silently would just regrow the silent-failure problem at a different layer.
  defp validate_device_compatibility!(platforms, device_id) do
    project_dir = File.cwd!()
    features = MobDev.SupportMatrix.enabled_features(project_dir)

    if features == [] do
      :ok
    else
      devices = candidate_devices(platforms, device_id)

      issues =
        devices
        |> Enum.flat_map(fn device ->
          case MobDev.SupportMatrix.check_device(device, features) do
            :ok -> []
            {:error, items} -> items
          end
        end)

      case issues do
        [] ->
          :ok

        _ ->
          IO.puts("")
          IO.puts("#{IO.ANSI.red()}Device compatibility check failed.#{IO.ANSI.reset()}")
          IO.puts(MobDev.SupportMatrix.format_error(issues))
          IO.puts("")

          IO.puts(
            "  See guides/support_matrix.md for the per-feature device floor, " <>
              "or pick a different device with #{IO.ANSI.cyan()}--device <id>#{IO.ANSI.reset()}."
          )

          Mix.raise("Device compatibility check failed")
      end
    end
  end

  # Returns the connected devices that mob.deploy would actually target.
  # Mirrors what the deployer / build pipeline does internally — narrow by
  # platform and (if given) by --device id.
  defp candidate_devices(platforms, device_id) do
    devices =
      []
      |> maybe_concat(:android in platforms, fn ->
        try do
          MobDev.Discovery.Android.list_devices()
        rescue
          _ -> []
        end
      end)
      |> maybe_concat(:ios in platforms, fn ->
        try do
          MobDev.Discovery.IOS.list_simulators()
        rescue
          _ -> []
        end
      end)

    case device_id do
      nil -> devices
      id -> Enum.filter(devices, &MobDev.Device.match_id?(&1, id))
    end
  end

  defp maybe_concat(list, true, fun), do: list ++ fun.()
  defp maybe_concat(list, false, _fun), do: list

  # Resolve --schedulers / --beam-flags into a combined flags string, save to
  # mob.exs, and return it (or the previously saved value if no flags given).
  defp resolve_beam_flags(opts) do
    new_flags = combine_beam_flags(opts[:schedulers], opts[:beam_flags])

    if new_flags do
      save_beam_flags(new_flags)
      IO.puts("#{IO.ANSI.cyan()}* beam flags: #{new_flags} (saved to mob.exs)#{IO.ANSI.reset()}")
      new_flags
    else
      MobDev.Config.load_mob_config()[:beam_flags]
    end
  end

  @doc false
  @spec combine_beam_flags(pos_integer() | nil, String.t() | nil) :: String.t() | nil
  def combine_beam_flags(schedulers, flags_string) do
    case {schedulers, flags_string} do
      {nil, nil} -> nil
      {n, nil} -> "-S #{n}:#{n}"
      {nil, flags} -> String.trim(flags)
      {n, flags} -> "-S #{n}:#{n} #{String.trim(flags)}"
    end
  end

  # Write or update the beam_flags key in mob.exs.
  defp save_beam_flags(flags) do
    path = Path.join(File.cwd!(), "mob.exs")
    unless File.exists?(path), do: Mix.raise("mob.exs not found in current directory")

    content = File.read!(path)
    updated = update_beam_flags_in_config(content, flags)
    File.write!(path, updated)
  end

  @doc false
  @spec update_beam_flags_in_config(String.t(), String.t() | nil) :: String.t()
  def update_beam_flags_in_config(content, flags) do
    value = inspect(flags)

    if content =~ Regex.compile!("^\\s+beam_flags:", "m") do
      Regex.replace(
        Regex.compile!("^(\\s+beam_flags:).*$", "m"),
        content,
        "  beam_flags: #{value}"
      )
    else
      String.trim_trailing(content) <> "\nconfig :mob_dev, beam_flags: #{value}\n"
    end
  end
end
