defmodule Mix.Tasks.Mob.Deploy do
  use Mix.Task

  @shortdoc "Build and deploy to all connected mob devices"

  @moduledoc """
  Compiles the project then pushes BEAM files to all connected
  Android devices and iOS simulators.

  ## Modes

  **Fast deploy** (default) — push BEAMs + restart. Use this for day-to-day
  Elixir code changes. Requires the native app already installed on device.

      mix mob.deploy

  **Full deploy** — build native binary + install APK/app + push BEAMs.
  Use this the first time, or after changes to native C/Java/Swift code.

      mix mob.deploy --native

  ## Options

    * `--native`              — build native binaries before pushing BEAMs
    * `--no-restart`          — push BEAMs but don't restart the app
    * `-d`, `--device <id>`   — target a specific device; use `mix mob.devices` to find IDs
    * `--dist-port <N>`       — pin the BEAM dist listen port (default: auto-allocated per
                              device, `9100 + index`). Use to resolve EPMD collisions when
                              multiple sims/emulators are running the same app concurrently
                              and the auto-allocated ports aren't what you want.
    * `--node-suffix <S>`     — append `_<S>` to the BEAM node name (default: auto-derived
                              from device serial on Android, SIMULATOR_UDID on iOS sim). Use
                              for scripted scenarios where you need a specific naming scheme.
    * `--schedulers <N>`      — set BEAM scheduler count (saved to mob.exs)
    * `--beam-flags "<flags>"` — arbitrary BEAM flags string (saved to mob.exs)
    * `--json`                — machine-readable result on stdout; progress goes to
                              stderr, so `mix mob.deploy --json | jq` gets one document
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

  ## Exit status

  Every targeted device is attempted and the full summary printed, then the
  task exits non-zero if **any** device landed in the `Failed on N device(s)`
  bucket — including a partial success where other devices deployed fine.

  Devices under `Skipped on N device(s)` (app not installed for that platform)
  do not fail the run — *unless you named that platform*. A skip means "this
  device is not a target for this app", which is ordinary when it is a phone
  that happens to be attached, and a failure when the run asked for it:

    * `mix mob.deploy` with an unrelated phone attached — exit 0.
    * `mix mob.deploy --ios` where every iOS device was skipped — exit 1.
    * `mix mob.deploy --ios` where one simulator deployed and a stale one was
      skipped — exit 0. A partial success is a success; the rule is per
      platform, not per device.
    * `mix mob.deploy --device X` that reached X and deployed nothing — exit 1.
    * `mix mob.deploy --device NOPE` matching no device — exit 1.
    * `mix mob.deploy --android --native` that built the APK with no device
      attached — exit 0. The artifact is what was asked for.

  `--native` fails the run when a platform you named built nothing at all, which
  is what a missing `sdk.dir` in `android/local.properties` produces.
  """

  alias MobDev.Device

  @switches [
    native: :boolean,
    # Machine-readable result on stdout, for a caller that needs to know which
    # targets got what without parsing coloured prose. Progress is redirected
    # to stderr for the run (see the group-leader swap in `run/1`) so stdout
    # carries exactly one document.
    json: :boolean,
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
    if MobDev.TaskHelp.help_requested?(args) do
      MobDev.TaskHelp.print_module_help(__MODULE__)
    else
      do_run(args)
    end
  end

  defp do_run(args) do
    {opts, argv, invalid} =
      args
      |> join_dashed_values()
      |> OptionParser.parse(strict: @switches, aliases: [d: :device])

    # `switches:` silently discards anything it does not recognise, so
    # `mix mob.deploy -d <udid>` — `-d` was never aliased here, though
    # `mob.connect` has aliased it all along — deployed to every device
    # instead of the one named, and said nothing. A typo'd `--devcie` did the
    # same. `strict:` collects them so the run can refuse rather than do
    # something other than what was asked.
    unless invalid == [] do
      Mix.raise(invalid_options_message(invalid))
    end

    # `mix mob.deploy --native ABC123` — a natural fumble of `--device` — parsed
    # cleanly, deployed to every device, and said nothing. This task takes no
    # positional arguments, so tolerating them is the same silent-ignore the
    # strict parsing above was added to end.
    unless argv == [] do
      Mix.raise(
        "mix mob.deploy takes no positional arguments, got: #{Enum.join(argv, ", ")}\n\n" <>
          "Did you mean `--device #{hd(argv)}`?"
      )
    end

    # Under --json, stdout must carry ONE document and nothing else. Every
    # progress line in this task, the deployer and the native build is a plain
    # `IO.puts/1`, which resolves `:stdio` through the group leader — so
    # repointing it sends all of them, and the `into: IO.stream()` subprocess
    # output too, to stderr. The JSON is then written to the real stdout
    # explicitly. Rewriting several hundred call sites to take a device would
    # be the alternative.
    if opts[:json] do
      # Capture the real stdout FIRST. `:standard_io` also resolves through the
      # group leader, so swapping it without saving this sends the document to
      # stderr along with the prose — the flag then emits nothing a pipe can
      # read, which is the whole failure it exists to prevent.
      Process.put(:mob_deploy_stdout, Process.group_leader())
      Process.group_leader(self(), Process.whereis(:standard_error))
    end

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
      IO.puts("Fetching dependencies...")
      mix = System.find_executable("mix")
      System.cmd(mix, ["deps.get"], into: IO.stream())
    end

    Mix.Task.run("compile")
    IO.puts("\n#{IO.ANSI.cyan()}Deploying to devices...#{IO.ANSI.reset()}\n")

    # Default OFF for dev iteration: slim adds the strip pass + erl spawn
    # for beam_lib:strip_release + xcrun strip, which costs seconds. Dev
    # cycle wants those seconds back. Opt in with `--slim` when you want
    # to size-test before mix mob.republish round-trips through TestFlight
    # (and the inevitable extra TestFlight build that confuses testers).
    slim = Keyword.get(opts, :slim, false)

    native_ok =
      if native do
        MobDev.NativeBuild.build_all(
          platforms: platforms,
          device: effective_device_id,
          slim: slim,
          requested: requested_platforms(opts)
        )
      end

    # Skip BEAM push if native build failed — the APK/app bundle isn't installed
    # so run-as / simctl push would fail with misleading errors.
    if native and native_ok == false do
      IO.puts("\n#{IO.ANSI.red()}Native build had failures — see errors above.#{IO.ANSI.reset()}")

      IO.puts(
        "#{IO.ANSI.yellow()}Run `mix mob.doctor` to check your environment, or `mix mob.deploy` (without --native) once the issue is fixed.#{IO.ANSI.reset()}"
      )

      emit_json(opts, [], [], [], "Native build failed")
      Mix.raise("Native build failed")
    end

    {deployed, failed, skipped} =
      MobDev.Deployer.deploy_all(
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
      )

    Enum.each(format_summary(deployed, failed, skipped, restart: restart), &IO.puts/1)

    # The full summary is printed first, then the status code is set — the
    # fan-out across devices is unchanged, only the exit code is.
    message =
      missing_device_message(device_id, deployed, failed, skipped) ||
        failure_message(
          deployed,
          failed,
          skipped,
          requested_platforms(opts),
          native and native_ok == true
        )

    emit_json(opts, deployed, failed, skipped, message)

    case message do
      nil -> :ok
      message -> Mix.raise(message)
    end
  end

  @doc """
  The `Mix.raise` message for a finished deploy, or `nil` when the run
  should exit 0.

  A deploy that printed "Failed on N device(s)" used to still exit 0, so
  CI and wrapper scripts read a failed deploy as a success.

  Only `failed` (a real error during push) is fatal. `skipped` is not:
  it means "app not installed for that platform", the expected outcome of
  e.g. building `--ios` with an Android phone also plugged in — the same
  distinction `format_summary/4` renders.

  Partial success is still a failure. Every targeted device is still
  attempted and reported before this runs, so the operator can see which
  ones got the BEAMs; a *script* has no way to notice one device missed
  out if the status code says everything is fine.
  """
  @spec failure_message([Device.t()], [Device.t()], [Device.t()]) :: String.t() | nil
  def failure_message(deployed, failed, skipped),
    do: failure_message(deployed, failed, skipped, [])

  @doc """
  As `failure_message/3`, but knowing which platforms were explicitly asked for.

  A skipped device is normally not a failure — it means "this device is not a
  target for this app", the expected outcome of an Android phone being attached
  during a default run. It IS a failure when the run named that platform: a
  `mix mob.deploy --android` that skips every Android device asked for
  something and got nothing, and must not report success.

  Pass `[]` for requested and every skip is incidental, which is the
  `failure_message/3` behaviour.
  """
  @spec failure_message([Device.t()], [Device.t()], [Device.t()], [atom()]) :: String.t() | nil
  def failure_message(_deployed, failed, _skipped, _requested) when failed != [],
    do: "Deploy failed on #{length(failed)} device(s) — see errors above"

  def failure_message(deployed, failed, skipped, requested),
    do: failure_message(deployed, failed, skipped, requested, false)

  @doc """
  As `failure_message/4`, but knowing whether a native build succeeded.

  A `--native` run that built the artifact and found no device to push it to
  did its main job. Failing it would break "build the APK now, attach the phone
  after", which used to exit 0.
  """
  @spec failure_message([Device.t()], [Device.t()], [Device.t()], [atom()], boolean()) ::
          String.t() | nil
  def failure_message(_deployed, failed, _skipped, _requested, _native) when failed != [],
    do: "Deploy failed on #{length(failed)} device(s) — see errors above"

  def failure_message(deployed, _failed, skipped, requested, native_built?) do
    # Per PLATFORM, not per device. `deploy_all/1` only enumerates devices for
    # platforms in the resolved list, and the resolved list is a subset of the
    # requested one, so "is this skip's platform requested?" is always true and
    # the rule would reduce to "any skip at all is fatal once you name a
    # platform". That fails a perfectly good run: two booted simulators with
    # the app on only the one you are working on, or a spare phone plugged in.
    # A platform is unserved only when it skipped AND nothing of it landed.
    unserved =
      Enum.filter(requested, fn platform ->
        Enum.any?(skipped, &(&1.platform == platform)) and
          not Enum.any?(deployed, &(&1.platform == platform))
      end)

    cond do
      unserved != [] ->
        "Deploy reached no #{names(unserved)} device — every one was skipped, " <>
          "and you asked for it"

      # Asked for a platform and reached nothing at all. Covers `--ios` on
      # Linux, where platform resolution yields an empty list, so no device is
      # even enumerated and every bucket is empty.
      #
      # Not when a native build succeeded: that run produced the artifact it
      # was asked for and merely had nowhere to push it.
      requested != [] and deployed == [] and skipped == [] and not native_built? ->
        "Deploy reached no device for #{names(requested)} — none was connected"

      true ->
        nil
    end
  end

  defp names(platforms), do: platforms |> Enum.map(&"--#{&1}") |> Enum.join(", ")

  # Written to the REAL stdout, not the group leader — which under --json now
  # points at stderr so the progress prose gets out of the document's way.
  defp emit_json(opts, deployed, failed, skipped, message) do
    if opts[:json] do
      json = Jason.encode!(json_result(deployed, failed, skipped, message), pretty: true)
      IO.puts(Process.get(:mob_deploy_stdout, :standard_io), json)
    end
  end

  @doc false
  @spec switches() :: keyword()
  def switches, do: @switches

  @doc """
  Rewrite `--flag value` to `--flag=value` when the value starts with a dash.

  `OptionParser` will not consume a dash-prefixed argument as a `:string`
  value, so `--beam-flags "-S 4:4 -A 4"` — the spelling this repo prints in
  seven places, including the README and both battery-bench workflows — parsed
  as two unknown options. Under the old lenient parsing the value was silently
  dropped and the deploy carried on with whatever `mob.exs` held; under strict
  parsing it became a hard failure that named a valid option as unknown.

  BEAM flags essentially all start with a dash, so this is not an edge case:
  it is the documented invocation.
  """
  @spec join_dashed_values([String.t()]) :: [String.t()]
  def join_dashed_values(args), do: join_dashed(args, [])

  defp join_dashed([], acc), do: Enum.reverse(acc)

  defp join_dashed(["--" | rest], acc), do: Enum.reverse(acc) ++ ["--" | rest]

  defp join_dashed([flag, value | rest], acc) do
    if string_switch?(flag) and String.starts_with?(value, "-") do
      join_dashed(rest, ["#{flag}=#{value}" | acc])
    else
      join_dashed([value | rest], [flag | acc])
    end
  end

  defp join_dashed([last], acc), do: Enum.reverse([last | acc])

  # Only the switches whose value is free text can legitimately begin with a
  # dash. Doing this for every switch would swallow `--android --ios`.
  defp string_switch?("--" <> name),
    do: Keyword.get(@switches, String.to_atom(String.replace(name, "-", "_"))) == :string

  defp string_switch?(_), do: false

  @doc """
  The error for options the task does not accept.

  Names them, because the failure this replaces was silent: the flag was
  dropped and the deploy proceeded as if it had never been passed.
  """
  @spec invalid_options_message([{String.t(), String.t() | nil}]) :: String.t()
  def invalid_options_message(invalid) do
    # `OptionParser`'s `invalid` list conflates "unrecognised flag" with
    # "recognised flag, unparseable value". Reporting both as "unknown" sends
    # someone who typed `--schedulers abc` to a help page that lists
    # `--schedulers`, with the offending value discarded and nothing to go on.
    # `mob.new_plugin` already got this right; this now matches it.
    names =
      Enum.map_join(invalid, ", ", fn
        {flag, nil} -> flag
        {flag, value} -> "#{flag} #{value}"
      end)

    "Unrecognized or invalid option(s): #{names}\n\n" <>
      "Run `mix help mob.deploy` for the accepted options."
  end

  @doc """
  The machine-readable result of a finished deploy.

  Exists because an agent driving `mix mob.deploy` otherwise has to infer the
  outcome from coloured prose, and the exit code alone does not say *which*
  target missed out. `outcome` mirrors the exit status: `"ok"` when the task
  returns 0, `"error"` when it raises.
  """
  @spec json_result([Device.t()], [Device.t()], [Device.t()], String.t() | nil) :: map()
  def json_result(deployed, failed, skipped, message) do
    %{
      "outcome" => if(message, do: "error", else: "ok"),
      "message" => message,
      "deployed" => Enum.map(deployed, &json_device/1),
      "failed" => Enum.map(failed, &json_device/1),
      "skipped" => Enum.map(skipped, &json_device/1)
    }
  end

  defp json_device(%MobDev.Device{} = device) do
    %{
      "name" => device.name,
      "serial" => device.serial,
      "platform" => to_string(device.platform),
      "reason" => device.error
    }
  end

  @doc """
  The message for a run that named a device and did not find it, or `nil`.

  `mix mob.deploy --device NOPE` printed "No devices found." and exited 0. The
  device filter matches nothing, every bucket comes back empty, and a run that
  shipped to a device you named by id is indistinguishable from one that
  shipped nowhere.

  Only fires when a device was named: with no `--device`, an empty run is the
  ordinary "nothing is plugged in" case and stays non-fatal.
  """
  @spec missing_device_message(String.t() | nil, [Device.t()], [Device.t()], [Device.t()]) ::
          String.t() | nil
  def missing_device_message(nil, _deployed, _failed, _skipped), do: nil

  def missing_device_message(device_id, [], [], []),
    do: "No device matched --device #{device_id} — nothing was deployed"

  # Found, but nothing landed on it. Naming a device by id is at least as
  # explicit as naming a platform, so a run that shipped nowhere must say so.
  # `failed` is left to `failure_message/5`, which reports the actual error.
  def missing_device_message(device_id, [], [], skipped) when skipped != [],
    do: "--device #{device_id} was skipped — nothing was deployed to it"

  def missing_device_message(_device_id, _deployed, _failed, _skipped), do: nil

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

  @doc """
  The platforms the user explicitly asked for, from the raw flags.

  Deliberately NOT `resolve_platforms/1`, which collapses "no flag given" into
  every platform with a scaffold. That distinction is the whole point: a device
  skipped during a default run is incidental (a phone that happens to be
  attached), while one skipped during `--android` is a request that went
  unserved. Returns `[]` when no platform flag was given.
  """
  @spec requested_platforms(keyword()) :: [:android | :ios]
  def requested_platforms(opts) do
    Enum.filter([:android, :ios], &(opts[&1] == true))
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
