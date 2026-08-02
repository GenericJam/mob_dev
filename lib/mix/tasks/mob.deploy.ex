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

  **Full deploy** — build native binary + update APK/app + push BEAMs.
  Use this after changes to native C/Java/Swift code. Android native updates
  resolve a non-empty connected-device set, use only serial-scoped
  `adb install -r`, and never uninstall the existing app, so a signing mismatch
  or downgrade fails while preserving app data.

      mix mob.deploy --native

  ## Options

    * `--native`              — build native binaries before pushing BEAMs
    * `--no-restart`          — push BEAMs but don't restart the app
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
          slim: slim
        )
      end

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

    {deployed, failed, skipped} =
      deploy_after_native_build!(native, native_ok, deploy_opts)

    Enum.each(format_summary(deployed, failed, skipped, restart: restart), &IO.puts/1)
  end

  @doc false
  @spec deploy_after_native_build!(boolean(), boolean() | nil, keyword()) ::
          {[Device.t()], [Device.t()], [Device.t()]}
  def deploy_after_native_build!(native, native_ok, deploy_opts) do
    deploy_after_native_build!(native, native_ok, deploy_opts, &MobDev.Deployer.deploy_all/1)
  end

  @doc false
  @spec deploy_after_native_build!(
          boolean(),
          boolean() | nil,
          keyword(),
          (keyword() -> {[Device.t()], [Device.t()], [Device.t()]})
        ) :: {[Device.t()], [Device.t()], [Device.t()]}
  def deploy_after_native_build!(true, native_ok, _deploy_opts, _deployer)
      when native_ok != true do
    IO.puts("\n#{IO.ANSI.red()}Native build had failures — see errors above.#{IO.ANSI.reset()}")

    IO.puts(
      "#{IO.ANSI.yellow()}Run `mix mob.doctor` to check your environment, or `mix mob.deploy` (without --native) once the issue is fixed.#{IO.ANSI.reset()}"
    )

    Mix.raise("Native build failed")
  end

  def deploy_after_native_build!(_native, _native_ok, deploy_opts, deployer) do
    deployer.(deploy_opts)
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
