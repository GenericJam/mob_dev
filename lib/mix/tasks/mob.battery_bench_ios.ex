defmodule Mix.Tasks.Mob.BatteryBenchIos do
  use Mix.Task

  alias MobDev.Bench.{DeviceObserver, Logger, Preflight, Probe, Reconnector, Summary}

  @shortdoc "Run a battery benchmark on a physical iOS device"

  @moduledoc """
  Builds a benchmark app, deploys it to a physical iPhone/iPad, and measures
  battery drain over time.

  Run this from your Mob app project directory (the one containing `ios/`,
  `mob.exs`, and your Elixir source). It requires `bundle_id` to be set in
  `mob.exs`:

      config :mob_dev,
        mob_dir:   "/path/to/mob",
        bundle_id: "com.example.myapp"

  ## Prerequisites

  libimobiledevice is required for battery readings:

      brew install libimobiledevice

  The device must be trusted on this Mac (accept "Trust This Computer" when
  connecting via USB). Xcode 15 or later is required for `xcrun devicectl`.

  ## Battery measurement

  iOS exposes battery capacity via libimobiledevice's `ideviceinfo` tool.
  If the device reports `BatteryMaxCapacity` (mAh), drain is shown in mAh like
  the Android benchmark. Otherwise, it falls back to percentage points
  (1% ≈ 40–60 mAh on most iPhones).

  WiFi-only measurements are not possible on iOS — USB-connected readings are
  skewed because the cable can trickle-charge. To minimise this, use a USB-only
  data cable (no charging), or note the baseline with and without cable.

  ## Recommended workflow (Mob projects)

  Mob projects use `ios/build_device.sh` rather than a full Xcode project,
  which means the bench task's `xcodebuild` path doesn't apply. Use this
  two-step pattern instead:

      # 1. Push BEAM flags via mob.deploy (no native rebuild — ~5 sec).
      mix mob.deploy --beam-flags "" --ios               # tuned (Nerves)
      mix mob.deploy --beam-flags "-S 6:6 -A 8" --ios    # untuned variant

      # 2. Run the bench with --no-build, specifying the phone's WiFi IP.
      mix mob.battery_bench_ios --no-build --wifi-ip 10.0.0.120

  Find the phone's WiFi IP in Settings → Wi-Fi → (i) → IP Address.

  See `README.md` for the full rationale and recovery procedure if a flag
  combination crashes the BEAM (which can happen if you request more
  threads than iOS allows per process).

  ## Usage (with built-in Xcode build path)

      mix mob.battery_bench_ios
      mix mob.battery_bench_ios --no-beam
      mix mob.battery_bench_ios --preset nerves
      mix mob.battery_bench_ios --flags "-sbwt none -S 1:1"
      mix mob.battery_bench_ios --duration 3600 --device UDID
      mix mob.battery_bench_ios --no-build   # re-run without rebuilding

  ## Options

    * `--duration N`      — benchmark duration in **seconds** (default: 1800 = 30 min)
    * `--device UDID`     — device UDID (auto-detected if one device connected)
    * `--wifi-ip IP`      — phone's WiFi IPv4 (recommended; bypasses auto-discovery)
    * `--no-beam`         — baseline: build without starting the BEAM at all
    * `--no-keep-alive`   — skip the silent-audio background keep-alive call
    * `--preset NAME`     — named BEAM flag preset (Xcode-build path only)
    * `--flags "..."`     — arbitrary BEAM VM flags (Xcode-build path only)
    * `--no-build`        — skip Xcode build and install; benchmark current install
    * `--scheme NAME`     — Xcode scheme name (default: camelized app name)
    * `--log-path PATH`   — override CSV log location (default: `_build/bench/run_<ts>.csv`)
    * `--no-csv`          — skip CSV logging
    * `--skip-preflight`  — bypass the preflight checks (USB/app/BEAM/RPC/NIF/keep-alive)

  ## What the presets do

    * `untuned`   — raw BEAM with no tuning flags (highest power use baseline)
    * `sbwt`      — only busy-wait disabled (`-sbwt none`)
    * `nerves`    — full Nerves set: single scheduler + busy-wait off + multi_time_warp
    * (default)   — same as `nerves` (production default)

  ## Understanding the results

  iOS battery percentage resolution is coarse. A 30-minute run should produce
  2–5% drain, enough to see the difference between no-BEAM and tuned-BEAM.
  Run at a fixed screen brightness or with the screen locked for reproducible
  results across runs.

  ## Under the hood

  `mix mob.battery_bench_ios` orchestrates the following commands:

      # Build
      xcodebuild -workspace ios/*.xcworkspace -scheme SCHEME \\
        -configuration Debug -sdk iphoneos \\
        -derivedDataPath /tmp/mob_bench_ios_STAMP \\
        [OTHER_CFLAGS='$(inherited) -DFLAG']

      # Install and launch
      xcrun devicectl device install app --device UDID /path/to/App.app
      xcrun devicectl device process launch --terminate-existing --device UDID \\
        com.example.myapp                   # → captures PID

      # Lock screen
      idevicediagnostics -u UDID sleep

      # Poll battery every 10s
      ideviceinfo -u UDID -q com.apple.mobile.battery -k BatteryCurrentCapacity
      ideviceinfo -u UDID -q com.apple.mobile.battery -k BatteryMaxCapacity

      # Stop app
      xcrun devicectl device process terminate --device UDID --pid PID

  BEAM tuning flags are injected as `OTHER_CFLAGS` build settings passed to
  xcodebuild, matching the same C preprocessor defines used in the Android build.
  """

  @switches [
    duration: :integer,
    device: :string,
    wifi_ip: :string,
    no_beam: :boolean,
    no_keep_alive: :boolean,
    preset: :string,
    flags: :string,
    no_build: :boolean,
    scheme: :string,
    dry_run: :boolean,
    log_path: :string,
    no_csv: :boolean,
    skip_preflight: :boolean
  ]

  @battery_domain "com.apple.mobile.battery"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: @switches)

    unless match?({:unix, :darwin}, :os.type()) do
      Mix.raise("mob.battery_bench_ios requires macOS.")
    end

    if opts[:dry_run] do
      dry_run!(opts)
      exit(:normal)
    end

    check_prerequisites!()

    duration = opts[:duration] || 1800
    no_build = opts[:no_build] || false

    # hw_udid: hardware UDID for libimobiledevice tools (USB only, may be nil over WiFi).
    # device_id: identifier for xcrun devicectl (works over WiFi for paired devices).
    # --device accepts either; if given, use it for both.
    {hw_udid, device_id} =
      case opts[:device] do
        given when is_binary(given) ->
          # Hardware UDID has no hyphens in the first segment (e.g. 00008110-...)
          # CoreDevice UUID has the standard 8-4-4-4-12 UUID format.
          hw =
            if String.match?(given, ~r/^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}/),
              do: nil,
              else: given

          {hw, given}

        nil ->
          case {auto_detect_usb(), auto_detect_wifi()} do
            {nil, nil} ->
              Mix.raise("""
              No iOS device found. Options:
                Connect an iPhone/iPad via USB and accept "Trust This Computer"
                mix mob.battery_bench_ios --device UDID
              List connected devices with: idevice_id -l
              """)

            {usb, nil} ->
              {usb, usb}

            {nil, wifi} ->
              {nil, wifi}

            {usb, wifi} ->
              {usb, wifi}
          end
      end

    # device_id is what we pass to xcrun devicectl (install, launch, terminate).
    udid = device_id

    pkg = MobDev.Config.bundle_id()
    cfg = MobDev.Config.load_mob_config()

    # Workspace discovery is only needed when building. Skip it with --no-build.
    {workspace_kind, workspace_path, scheme} =
      if no_build do
        {:none, nil, opts[:scheme] || cfg[:ios_scheme] || Macro.camelize(app_name())}
      else
        {wk, wp} = find_workspace!()
        {wk, wp, opts[:scheme] || cfg[:ios_scheme] || detect_scheme!(wk, wp)}
      end

    IO.puts("")
    IO.puts("=== Mob Battery Benchmark (iOS) ===")
    IO.puts("")
    IO.puts("  Device:   #{udid}")
    IO.puts("  Bundle:   #{pkg}")
    IO.puts("  Scheme:   #{scheme}")
    IO.puts("  Duration: #{duration}s (#{div(duration, 60)} min)")
    IO.puts("  Mode:     #{describe_mode(opts)}")
    IO.puts("")

    unless device_ok?(udid) do
      Mix.raise("Cannot reach device #{udid} — check it is paired and on the same network.")
    end

    # ── Build ──────────────────────────────────────────────────────────────────

    derived_data = Path.join(System.tmp_dir!(), "mob_bench_ios_#{System.os_time(:second)}")

    unless no_build do
      {other_cflags, header_dir} = resolve_build_flags(opts)

      IO.puts("=== Building iOS app ===")
      app_path = build_app(workspace_kind, workspace_path, scheme, other_cflags, derived_data)

      IO.puts("=== Installing on device ===")
      install_app!(udid, app_path)

      if header_dir, do: File.rm_rf!(header_dir)
    end

    # ── Launch app first so the BEAM is reachable for all battery reads ──────────

    IO.puts("=== Launching app ===")
    pid = launch_app!(udid, pkg)
    :timer.sleep(3000)

    # ── Pre-run checks ─────────────────────────────────────────────────────────

    # Connect to the phone's BEAM — used as fallback when ideviceinfo is
    # unavailable (WiFi-only mode) and for battery reads when screen is locked.
    # Best-effort: nil means RPC won't be available.
    IO.puts("  Connecting to device BEAM...")
    node = connect_beam_node(device_id, opts[:wifi_ip])

    if node do
      IO.puts("  BEAM connected: #{node}")

      if opts[:no_keep_alive] do
        IO.puts("  (skipping background keep-alive — iOS will suspend the app when locked)")
      else
        IO.puts("  Starting background keep-alive (silent audio session)...")
        :rpc.call(node, :mob_nif, :background_keep_alive, [], 5000)
      end
    else
      IO.puts("  (BEAM not reachable — will use ideviceinfo only, screen must stay on)")
    end

    # ── Preflight ─────────────────────────────────────────────────────────────

    unless opts[:skip_preflight] do
      IO.puts("")
      IO.puts("=== Preflight checks ===")

      preflight_results =
        Preflight.run(
          node: node,
          cookie: :mob_secret,
          bundle_id: pkg,
          device_id: device_id,
          hw_udid: hw_udid,
          require_keep_alive: opts[:no_keep_alive] != true
        )

      IO.puts(Preflight.pretty(preflight_results))

      unless Preflight.all_ok?(preflight_results) do
        IO.puts("")
        IO.puts(">>> Preflight checks reported issues. Continue anyway? (y/N)")

        case IO.gets("") |> String.trim() do
          "y" -> :ok
          _ -> Mix.raise("Aborted at preflight.")
        end
      end
    end

    max_mah = read_max_capacity_mah(hw_udid)
    battery = read_battery_required(hw_udid, max_mah, node)
    unit = if max_mah, do: "mAh", else: "%"

    IO.puts("")
    IO.puts("Battery:    #{format_battery(battery, max_mah)}")

    if battery.pct < 80 do
      IO.puts("WARNING: Battery below 80%. Charge to >90% for comparable results.")
      IO.puts("Continue? (y/N)")

      case IO.gets("") |> String.trim() do
        "y" -> :ok
        _ -> Mix.raise("Aborted.")
      end
    end

    IO.puts("")

    total_min = div(duration, 60)
    start_b = read_battery_required(hw_udid, max_mah, node)
    start_val = battery_value(start_b, max_mah)
    start_time = System.monotonic_time(:second)

    IO.puts("Start:  #{format_battery(start_b, max_mah)}")
    IO.puts("")

    screen_locked =
      if node do
        IO.puts(">>> Step 1 of 2 — Unplug the USB cable (if connected), then press Enter.")
        IO.gets("")
        IO.puts("")
        IO.puts(">>> Step 2 of 2 — Locking the screen now...")
        result = lock_screen_auto(hw_udid)
        IO.puts("")
        result
      else
        IO.puts(">>> Unplug the USB cable (if connected), keep the screen ON, then press Enter.")
        IO.puts("    (BEAM not connected — battery reads require USB or an active screen.)")
        IO.gets("")
        false
      end

    IO.puts("Running for #{div(duration, 60)} min...")
    IO.puts("")
    IO.puts("")

    # ── Open CSV log unless --no-csv ───────────────────────────────────────
    log =
      if opts[:no_csv] do
        nil
      else
        log_path =
          opts[:log_path] ||
            Path.join([
              File.cwd!(),
              "_build",
              "bench",
              "run_#{System.os_time(:second)}.csv"
            ])

        IO.puts("  Logging samples to #{log_path}")
        Logger.open(log_path, start_ts_ms: System.monotonic_time(:millisecond))
      end

    reconnector = Reconnector.new(node || :unset@unset, :mob_secret)

    expected_screen = if screen_locked, do: :off, else: :on

    # Subscribe to Mob.Device events on the device. If the app supports it,
    # we'll get ground-truth screen + app-state events as they happen (via
    # `:rpc.call(node, Mob.Device, :subscribe, ...)`). If not, the observer
    # falls back to passing through `expected_screen`.
    observer = DeviceObserver.subscribe(node, categories: [:app, :display, :memory])

    if observer.subscribed? do
      IO.puts("  Subscribed to Mob.Device events on #{inspect(node)}")
    else
      IO.puts("  (Mob.Device events not available — using expected screen state)")
    end

    {final_log, final_reconnector, _final_observer} =
      Enum.reduce(1..duration, {log, reconnector, observer}, fn i,
                                                                {log_acc, recon_acc, obs_acc} ->
        :timer.sleep(1000)

        if rem(i, 10) == 0 do
          poll_tick(
            i,
            log_acc,
            recon_acc,
            obs_acc,
            node: node,
            wifi_ip: opts[:wifi_ip],
            hw_udid: hw_udid,
            device_id: device_id,
            app_pid: pid,
            expected_screen: expected_screen,
            start_time: start_time,
            start_val: start_val,
            unit: unit,
            total_min: total_min
          )
        else
          # Even on non-poll iterations, drain device events into the observer.
          {log_acc, recon_acc, DeviceObserver.consume_messages(obs_acc)}
        end
      end)

    log = final_log
    _ = final_reconnector

    # ── Results ────────────────────────────────────────────────────────────────

    IO.puts("")
    IO.puts("=== Collecting results ===")
    if node, do: :rpc.call(node, :mob_nif, :background_stop, [], 5000)
    if pid, do: terminate_app(udid, pid)
    :timer.sleep(1000)

    IO.puts("  Unlock the phone to read final battery level...")
    end_b = read_battery_required(hw_udid, max_mah, node, 1, 60)
    end_val = battery_value(end_b, max_mah)
    drain = start_val - end_val
    elapsed_actual = System.monotonic_time(:second) - start_time

    rate =
      if elapsed_actual > 0,
        do: Float.round(drain * 3600 / elapsed_actual, 1),
        else: 0.0

    IO.puts("")
    IO.puts("=== Summary: #{describe_mode(opts)} ===")
    IO.puts("")
    IO.puts("  Duration: #{div(elapsed_actual, 60)} min #{rem(elapsed_actual, 60)} sec")
    IO.puts("  Start:    #{format_battery(start_b, max_mah)}")
    IO.puts("  End:      #{format_battery(end_b, max_mah)}")
    IO.puts("  Drain:    #{Float.round(drain * 1.0, 1)} #{unit}")
    IO.puts("  Rate:     #{rate} #{unit}/hr")

    if is_nil(max_mah) do
      IO.puts("")
      IO.puts("Note: BatteryMaxCapacity unavailable; showing percentage. 1% ≈ 40–60 mAh.")
    end

    IO.puts("")

    # ── Optional: precise USB read for 1% resolution ─────────────────────
    # iOS UIDevice.batteryLevel is clamped to 5% increments at the OS level
    # (privacy measure). ideviceinfo over USB exposes the raw 1% reading
    # via the battery domain. After a screen-off bench where the phone was
    # unplugged, plug it back in here for a more precise final number.
    precise_final_read(hw_udid)

    # ── CSV-based summary (probes, reconnects, gap analysis) ─────────────
    if log do
      log_path = log.path
      Logger.close(log)

      IO.puts("=== Probe-based summary ===")
      IO.puts("")

      try do
        metrics = Summary.from_csv(log_path)
        IO.puts(Summary.pretty(metrics))
        IO.puts("")
        IO.puts("Full log: #{log_path}")
      rescue
        e ->
          IO.puts("  (could not parse #{log_path}: #{Exception.message(e)})")
      end

      IO.puts("")
    end

    File.rm_rf!(derived_data)
  end

  # ── Probe-driven poll tick ────────────────────────────────────────────────

  # One iteration of the polling loop (called every 10s). Takes a probe
  # snapshot, prints a one-line trace, logs it, and runs the reconnector.
  # Returns updated {log, reconnector, observer} for the next tick.
  defp poll_tick(_iter, log, reconnector, observer, opts) do
    elapsed_sec = System.monotonic_time(:second) - opts[:start_time]
    elapsed_min = Float.round(elapsed_sec / 60, 1)
    ts = time_string()

    # Drain any buffered Mob.Device events first so the probe reflects
    # ground-truth screen/app state.
    observer = DeviceObserver.consume_messages(observer)

    probe =
      Probe.snapshot(
        node: opts[:node],
        host: opts[:wifi_ip] || derive_host_from_node(opts[:node]),
        hw_udid: opts[:hw_udid],
        device_id: opts[:device_id],
        app_pid: opts[:app_pid],
        expected_screen: opts[:expected_screen]
      )

    # Apply observer's authoritative screen/app state on top of the probe.
    probe = DeviceObserver.apply_to_probe(observer, probe)

    log = if log, do: Logger.append(log, probe), else: log

    # Render the live line.
    fragment = Probe.format(probe)

    line =
      case probe.battery_pct do
        nil ->
          "  [#{ts}] #{elapsed_min}/#{opts[:total_min]} min — #{fragment}"

        pct ->
          drain = opts[:start_val] - pct

          rate_str =
            if elapsed_sec > 30 do
              rate = Float.round(drain * 3600 / elapsed_sec, 1)
              " @ #{rate} #{opts[:unit]}/hr"
            else
              ""
            end

          "  [#{ts}] #{elapsed_min}/#{opts[:total_min]} min — #{fragment} (−#{Float.round(drain * 1.0, 1)} #{opts[:unit]}#{rate_str})"
      end

    IO.puts(line)

    # Reconnect logic — attempt Node.connect when in a recoverable state.
    now_ms = System.monotonic_time(:millisecond)

    reconnector =
      case Reconnector.tick(reconnector, probe, now_ms) do
        {:no_action, r} ->
          r

        {:attempt, r} ->
          if opts[:node] && Node.connect(opts[:node]) do
            IO.puts(
              "    ↻ reconnected to #{opts[:node]} (attempt #{r.attempts}, total #{r.total_reconnects + 1})"
            )

            Reconnector.record_success(r)
          else
            r
          end
      end

    {log, reconnector, observer}
  end

  # Optional precise final-battery read via ideviceinfo over USB. iOS clamps
  # UIDevice.batteryLevel to 5% increments — `99` rounds to `100`, hiding
  # small drains that matter for benchmarking. ideviceinfo's battery domain
  # exposes 1% precision when the device is connected via USB.
  defp precise_final_read(nil), do: :ok

  defp precise_final_read(hw_udid) when is_binary(hw_udid) do
    IO.puts("iOS reports battery in 5% increments. For 1% precision: plug in USB now.")

    IO.puts("Press Enter to read precise battery, or Ctrl-C to skip...")

    case IO.gets("") do
      :eof ->
        :ok

      {:error, _} ->
        :ok

      _ ->
        if System.find_executable("ideviceinfo") do
          case System.cmd(
                 "ideviceinfo",
                 ["-u", hw_udid, "-q", "com.apple.mobile.battery"],
                 stderr_to_stdout: true
               ) do
            {out, 0} ->
              IO.puts("")
              IO.puts("=== Precise battery (via ideviceinfo) ===")

              fields =
                out
                |> String.split("\n", trim: true)
                |> Enum.filter(fn line ->
                  String.starts_with?(line, [
                    "BatteryCurrentCapacity:",
                    "BatteryMaxCapacity:",
                    "BatteryIsCharging:",
                    "ExternalConnected:",
                    "FullyCharged:"
                  ])
                end)

              Enum.each(fields, &IO.puts("  " <> &1))

            {out, _} ->
              IO.puts("  (ideviceinfo failed — is USB connected? trust this Mac?)")
              IO.puts("  " <> String.trim(out))
          end
        else
          IO.puts("  (ideviceinfo not installed — `brew install libimobiledevice`)")
        end

        IO.puts("")
    end
  end

  defp derive_host_from_node(nil), do: nil

  defp derive_host_from_node(node) when is_atom(node) do
    case Atom.to_string(node) |> String.split("@", parts: 2) do
      [_, host] -> host
      _ -> nil
    end
  end

  # ── Prerequisites ─────────────────────────────────────────────────────────────

  defp check_prerequisites! do
    unless System.find_executable("xcrun") do
      Mix.raise("xcrun not found. Install Xcode command-line tools: xcode-select --install")
    end

    # ideviceinfo is needed for USB battery reads but not strictly required —
    # WiFi mode falls back to Erlang distribution RPC. Warn but don't abort.
    unless System.find_executable("ideviceinfo") do
      IO.puts("""
      Note: ideviceinfo not found (brew install libimobiledevice).
      Battery readings will use Erlang distribution over WiFi instead.
      """)
    end
  end

  # ── Dry run ───────────────────────────────────────────────────────────────────

  defp dry_run!(opts) do
    cfg = MobDev.Config.load_mob_config()
    pkg = MobDev.Config.bundle_id()

    scheme =
      opts[:scheme] || cfg[:ios_scheme] ||
        case find_workspace() do
          {:ok, {kind, path}} -> detect_scheme!(kind, path)
          :error -> Macro.camelize(app_name())
        end

    duration = opts[:duration] || 1800

    # Validate preset / flags (raises on bad preset name)
    {cflags, header_dir} = resolve_build_flags(opts)
    if header_dir, do: File.rm_rf!(header_dir)

    IO.puts("")
    IO.puts("=== Mob Battery Benchmark (iOS) — Dry Run ===")
    IO.puts("")
    IO.puts("  Device:   #{opts[:device] || "(auto-detect at run time)"}")
    IO.puts("  Bundle:   #{pkg || "(NOT SET)"}")
    IO.puts("  Scheme:   #{scheme}")
    IO.puts("  Duration: #{duration}s (#{div(duration, 60)} min)")
    IO.puts("  Mode:     #{describe_mode(opts)}")
    IO.puts("  Flags:    #{if cflags == "", do: "(default Nerves tuning)", else: cflags}")
    IO.puts("  Build:    #{if opts[:no_build], do: "skip (--no-build)", else: "yes"}")
    IO.puts("")

    IO.puts("Dry run complete — no prerequisites checked, no device contacted.")
    IO.puts("")
  end

  # ── Build flags ──────────────────────────────────────────────────────────────

  @doc false
  @spec resolve_build_flags(keyword()) :: {String.t(), String.t() | nil}
  def resolve_build_flags(opts) do
    cond do
      opts[:no_beam] ->
        {"-DNO_BEAM", nil}

      opts[:flags] ->
        header_dir = Path.join(System.tmp_dir!(), "mob_bench_flags_#{System.os_time(:second)}")
        File.mkdir_p!(header_dir)
        flags_list = String.split(opts[:flags], ~r/\s+/, trim: true)
        c_literals = Enum.map_join(flags_list, ", ", &~s("#{&1}"))

        header =
          "/* generated by mix mob.battery_bench_ios -- do not edit */\n" <>
            "#define BEAM_EXTRA_FLAGS #{c_literals},\n"

        File.write!(Path.join(header_dir, "mob_beam_flags.h"), header)
        {"-DBEAM_USE_CUSTOM_FLAGS -I#{header_dir}", header_dir}

      opts[:preset] ->
        flag =
          case opts[:preset] do
            "untuned" -> "-DBEAM_UNTUNED"
            "sbwt" -> "-DBEAM_SBWT_ONLY"
            "nerves" -> "-DBEAM_FULL_NERVES"
            other -> Mix.raise("Unknown preset #{inspect(other)}. Choose: untuned, sbwt, nerves")
          end

        {flag, nil}

      true ->
        {"", nil}
    end
  end

  @doc false
  @spec describe_mode(keyword()) :: String.t()
  def describe_mode(opts) do
    cond do
      opts[:no_beam] -> "no-beam (baseline)"
      opts[:flags] -> "custom flags: #{opts[:flags]}"
      opts[:preset] -> "preset: #{opts[:preset]}"
      true -> "default (Nerves tuning)"
    end
  end

  # ── Xcode build ──────────────────────────────────────────────────────────────

  defp find_workspace! do
    ios_dir = Path.join(File.cwd!(), "ios")
    unless File.dir?(ios_dir), do: Mix.raise("ios/ directory not found in #{File.cwd!()}")

    # Prefer .xcworkspace (CocoaPods/SPM), fall back to .xcodeproj.
    # Exclude Provision.xcodeproj — that is a mob.provision stub with no BEAM.
    workspaces = Path.wildcard(Path.join(ios_dir, "*.xcworkspace"))

    projects =
      ios_dir
      |> Path.join("*.xcodeproj")
      |> Path.wildcard()
      |> Enum.reject(&(Path.basename(&1) == "Provision.xcodeproj"))

    case {workspaces, projects} do
      {[ws | _], _} ->
        {:workspace, ws}

      {[], [proj | _]} ->
        {:project, proj}

      _ ->
        # Mob projects use ios/build.sh (simulator only) rather than an Xcode project.
        # Physical device builds require xcodebuild, which needs a .xcodeproj or .xcworkspace.
        build_sh = Path.join(ios_dir, "build.sh")

        if File.exists?(build_sh) do
          Mix.raise("""
          This project uses ios/build.sh (mob's build system), which targets the \
          iOS simulator only. Physical device builds require an Xcode project file.

          To run the battery benchmark:
            1. Open the project in Xcode, select a physical device, and run once.
            2. Then use --no-build to skip the build step and measure the installed app:

               mix mob.battery_bench_ios --no-build

          Alternatively, add an Xcode project to ios/ and re-run without --no-build.
          """)
        else
          Mix.raise("No .xcworkspace or .xcodeproj found in ios/")
        end
    end
  end

  defp build_app(kind, path, scheme, other_cflags, derived_data) do
    type_flag =
      case kind do
        :workspace -> ["-workspace", path]
        :project -> ["-project", path]
      end

    # Build settings are passed as positional KEY=VALUE args to xcodebuild.
    # $(inherited) is processed by xcodebuild itself, not the shell.
    cflags_arg =
      if other_cflags != "",
        do: ["OTHER_CFLAGS=$(inherited) #{other_cflags}"],
        else: []

    args =
      type_flag ++
        [
          "-scheme",
          scheme,
          "-configuration",
          "Debug",
          "-sdk",
          "iphoneos",
          "-derivedDataPath",
          derived_data
        ] ++ cflags_arg ++ ["build"]

    IO.puts("  Running xcodebuild (this may take a while)...")

    case System.cmd("xcodebuild", args, stderr_to_stdout: true, into: IO.stream()) do
      {_, 0} -> :ok
      {_, _} -> Mix.raise("xcodebuild failed — check output above")
    end

    products_dir = Path.join(derived_data, "Build/Products/Debug-iphoneos")

    case Path.wildcard(Path.join(products_dir, "*.app")) do
      [app | _] ->
        IO.puts("  Built: #{Path.basename(app)}")
        app

      [] ->
        Mix.raise("Built app not found in #{products_dir}. xcodebuild may have failed silently.")
    end
  end

  defp install_app!(udid, app_path) do
    IO.puts("  Installing #{Path.basename(app_path)}...")

    case System.cmd(
           "xcrun",
           ["devicectl", "device", "install", "app", "--device", udid, app_path],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        :ok

      {out, _} ->
        Mix.raise("App install failed: #{String.trim(out)}")
    end
  end

  # ── App lifecycle ─────────────────────────────────────────────────────────────

  # Returns the process PID (integer) or nil if it couldn't be parsed.
  defp launch_app!(udid, bundle_id) do
    case System.cmd(
           "xcrun",
           [
             "devicectl",
             "device",
             "process",
             "launch",
             "--terminate-existing",
             "--device",
             udid,
             bundle_id
           ],
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        case Regex.run(~r/\bprocess identifier\s+(\d+)/i, out) ||
               Regex.run(~r/\bpid[:\s]+(\d+)/i, out) ||
               Regex.run(~r/\b(\d{4,6})\b/, out) do
          [_, pid_str] ->
            String.to_integer(pid_str)

          nil ->
            IO.puts("  App launched (could not parse PID from: #{String.trim(out)})")
            nil
        end

      {out, _} ->
        Mix.raise("Failed to launch #{bundle_id}: #{String.trim(out)}")
    end
  end

  defp terminate_app(udid, pid) when is_integer(pid) do
    case System.cmd(
           "xcrun",
           [
             "devicectl",
             "device",
             "process",
             "terminate",
             "--device",
             udid,
             "--pid",
             to_string(pid)
           ],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        :ok

      {out, _} ->
        # Non-fatal — app may have already exited
        IO.puts("  terminate warning: #{String.trim(out)}")
    end
  end

  # ── Screen lock ──────────────────────────────────────────────────────────────

  # Returns true when the screen is locked (either automatically or by user).
  defp lock_screen_auto(nil) do
    IO.puts("  No hardware UDID — please lock the phone now.")
    IO.puts("  Press Enter once the screen is locked.")
    IO.gets("")
    true
  end

  defp lock_screen_auto(udid) do
    case System.cmd("idevicediagnostics", ["-u", udid, "sleep"], stderr_to_stdout: true) do
      {_, 0} ->
        IO.puts("  Screen locked.")
        :timer.sleep(1000)
        true

      _ ->
        IO.puts("  Auto-lock failed — please lock the phone manually.")
        IO.puts("  Press Enter once the screen is locked.")
        IO.gets("")
        true
    end
  end

  # ── Battery readings ─────────────────────────────────────────────────────────

  # Establish Erlang distribution to the running app on the device.
  # Returns the node atom if connected, nil otherwise.
  #
  # Retries up to 5 times, sleeping ~2 s between attempts so the device-side
  # BEAM has time to start, register in EPMD, and accept connections after
  # the app launch. Each attempt logs its outcome (no device / connect false /
  # connect ignored) so failures are diagnosable without re-running the bench.
  #
  # Once a device is discovered, subsequent attempts skip the discovery
  # cascade and just retry `Node.connect` against the same node — the
  # discovery itself can take 3–5 s on iOS (devicectl + ARP + EPMD scan)
  # which would chew through the retry budget if repeated each iteration.
  #
  # device_id: CoreDevice UUID — used to resolve the phone's IP via
  # `xcrun devicectl` so we can query EPMD directly without relying on
  # the ARP cache (which may not have the WiFi IP when all prior
  # communication was over USB).
  @max_connect_attempts 5
  @connect_retry_sleep_ms 2_000

  defp connect_beam_node(device_id, explicit_wifi_ip) do
    case Node.start(:"mob_bench@127.0.0.1", :longnames) do
      {:ok, _} -> Node.set_cookie(:mob_secret)
      {:error, {:already_started, _}} -> :ok
      _ -> :ok
    end

    # If the user passed --wifi-ip, warm the ARP cache with a quick ping so
    # the subsequent EPMD probe doesn't fail on a cold ARP lookup.
    if is_binary(explicit_wifi_ip) do
      System.cmd("ping", ["-c", "1", "-W", "1000", explicit_wifi_ip], stderr_to_stdout: true)
    end

    expected_node_prefix = "#{app_name()}_ios"

    do_connect_attempts(device_id, explicit_wifi_ip, expected_node_prefix, _cache = nil, 1)
  end

  defp do_connect_attempts(_device_id, _wifi_ip, _expected_prefix, _cache, attempt)
       when attempt > @max_connect_attempts,
       do: nil

  defp do_connect_attempts(device_id, wifi_ip, expected_prefix, cache, attempt) do
    device = cache || discover_ios_device(device_id, wifi_ip, expected_prefix)

    cond do
      is_nil(device) ->
        IO.puts(
          "  attempt #{attempt}/#{@max_connect_attempts}: no device discovered " <>
            "(devicectl + ARP + EPMD scan all empty)"
        )

        sleep_unless_last(attempt)
        do_connect_attempts(device_id, wifi_ip, expected_prefix, nil, attempt + 1)

      true ->
        Node.set_cookie(device.node, :mob_secret)

        case Node.connect(device.node) do
          true ->
            device.node

          false ->
            IO.puts(
              "  attempt #{attempt}/#{@max_connect_attempts}: found #{device.serial} at " <>
                "#{device.host_ip || "?"} (#{device.node}) but Node.connect returned false " <>
                "(BEAM not yet ready or cookie mismatch)"
            )

            sleep_unless_last(attempt)
            # Keep the device cached — likely the BEAM just isn't up yet.
            do_connect_attempts(device_id, wifi_ip, expected_prefix, device, attempt + 1)

          :ignored ->
            # Local node isn't alive (couldn't start it) — retrying won't help.
            IO.puts(
              "  attempt #{attempt}/#{@max_connect_attempts}: Node.connect returned :ignored — " <>
                "local node never started, aborting retries"
            )

            nil
        end
    end
  end

  defp sleep_unless_last(attempt) do
    if attempt < @max_connect_attempts, do: :timer.sleep(@connect_retry_sleep_ms)
  end

  # Three-stage discovery cascade. Returns the first %Device{} matching the
  # current project's expected node-name prefix (`<app>_ios`) or nil. Stages
  # run only as far as needed; ARP/EPMD scan is the slowest so it's last.
  #
  # The prefix filter matters because `MobDev.Discovery.IOS.list_physical/0`
  # scans EPMD and ARP and can return false positives — e.g. an Android phone
  # at 10.0.0.17 happens to have a stale `mob_qa_ios_*` EPMD entry tunneled
  # via adb-reverse, which the iOS-name regex matches. Without filtering, the
  # bench would happily try to connect to that and fail every retry. With the
  # filter, we'll only accept nodes whose name actually corresponds to the
  # app being benched.
  defp discover_ios_device(device_id, explicit_wifi_ip, expected_prefix) do
    explicit_match =
      if is_binary(explicit_wifi_ip),
        do: MobDev.Discovery.IOS.find_physical_at(explicit_wifi_ip)

    devicectl_match =
      explicit_match ||
        with ip when is_binary(ip) <- device_ip_from_devicectl(device_id) do
          MobDev.Discovery.IOS.find_physical_at(ip)
        end

    devicectl_match ||
      MobDev.Discovery.IOS.list_physical()
      |> Enum.find(fn d ->
        d.host_ip && node_matches_prefix?(d.node, expected_prefix)
      end)
  end

  # Match `<expected_prefix>@<host>` (with optional `_<udid>` segment for
  # simulators that disambiguate by booted UDID, e.g. `mob_qa_ios_78354490`).
  # Lets `test_nif_ios` accept `test_nif_ios@10.0.0.120` *and*
  # `test_nif_ios_<udid>@127.0.0.1` (sim) but reject `mob_qa_ios_*@anything`.
  @doc false
  @spec node_matches_prefix?(node() | nil, String.t()) :: boolean()
  def node_matches_prefix?(nil, _prefix), do: false

  def node_matches_prefix?(node, prefix) when is_atom(node) and is_binary(prefix) do
    name = Atom.to_string(node) |> String.split("@", parts: 2) |> hd()
    name == prefix or String.starts_with?(name, prefix <> "_")
  end

  # Returns the device's IP by extracting its mDNS hostname from xcrun devicectl
  # output and resolving it. Falls back to nil if devicectl is unavailable or
  # the device isn't found.
  defp device_ip_from_devicectl(nil), do: nil

  defp device_ip_from_devicectl(device_id) do
    tmp = Path.join(System.tmp_dir!(), "mob_bench_devlist_#{System.os_time(:millisecond)}.json")

    try do
      case System.cmd("xcrun", ["devicectl", "list", "devices", "--json-output", tmp],
             stderr_to_stdout: true
           ) do
        {_, 0} ->
          conn =
            tmp
            |> File.read!()
            |> Jason.decode!()
            |> get_in(["result", "devices"])
            |> List.wrap()
            |> Enum.find_value(fn dev ->
              if dev["identifier"] == device_id, do: dev["connectionProperties"]
            end)

          tunnel_ip = conn && conn["tunnelIPAddress"]
          # CoreDevice sometimes reports an IPv6 tunnel address (fd7f::/16 range).
          # Erlang EPMD doesn't listen on IPv6, so skip those and fall through to
          # hostname resolution which gives us the IPv4 WiFi address.
          ipv4_tunnel =
            if is_binary(tunnel_ip) && not String.contains?(tunnel_ip, ":"),
              do: tunnel_ip,
              else: nil

          cond do
            is_nil(conn) ->
              nil

            is_binary(ipv4_tunnel) ->
              ipv4_tunnel

            true ->
              hostname =
                conn["localHostnames"]
                |> List.wrap()
                |> List.first()

              case hostname && :inet.gethostbyname(String.to_charlist(hostname)) do
                {:ok, {:hostent, _, _, :inet, 4, [addr | _]}} ->
                  addr |> Tuple.to_list() |> Enum.join(".")

                _ ->
                  nil
              end
          end

        _ ->
          nil
      end
    rescue
      _ -> nil
    after
      File.rm(tmp)
    end
  end

  # Returns the max design capacity in mAh, or nil if unavailable.
  # Only readable via USB (ideviceinfo); WiFi RPC returns percentage only.
  defp read_max_capacity_mah(udid) do
    case ideviceinfo(udid, "BatteryMaxCapacity") do
      {:ok, val} ->
        case Integer.parse(val) do
          {mah, _} when mah > 0 -> mah
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # Returns integer % or nil.
  # Tries USB (ideviceinfo) first; falls back to Erlang RPC (mob_nif:battery_level/0)
  # when USB is unavailable — e.g. screen locked with iOS USB restriction, or
  # cable unplugged entirely.
  defp read_battery_pct(udid, node) do
    usb_result =
      if System.find_executable("ideviceinfo") do
        case ideviceinfo(udid, "BatteryCurrentCapacity") do
          {:ok, val} ->
            case Integer.parse(val) do
              {n, _} when n >= 0 -> n
              _ -> nil
            end

          {:error, _} ->
            nil
        end
      end

    usb_result || rpc_battery_level(node)
  end

  defp rpc_battery_level(nil), do: nil

  defp rpc_battery_level(node) do
    # Reconnect if the dist connection dropped (WiFi flap while screen locked).
    unless node in Node.list(), do: Node.connect(node)

    case :rpc.call(node, :mob_nif, :battery_level, [], 5000) do
      n when is_integer(n) and n >= 0 -> n
      _ -> nil
    end
  end

  # Like read_battery but retries up to max_attempts times (2s apart) before raising.
  defp read_battery_required(udid, max_mah, node),
    do: read_battery_required(udid, max_mah, node, 1, 5)

  defp read_battery_required(udid, max_mah, node, attempt, max_attempts) do
    case read_battery_pct(udid, node) do
      nil when attempt < max_attempts ->
        :timer.sleep(2000)
        read_battery_required(udid, max_mah, node, attempt + 1, max_attempts)

      nil ->
        device_str = if udid, do: "device #{udid}", else: "device"

        Mix.raise(
          "Could not read battery from #{device_str} after #{attempt} attempts.\n" <>
            "  USB:  no hardware UDID available (idevice_id -l returned nothing).\n" <>
            "  WiFi: BEAM not reachable — ensure the app is running and on the same network.\n" <>
            "        Run `mix mob.connect --no-iex` to verify the node is visible."
        )

      pct ->
        mah = if max_mah, do: round(max_mah * pct / 100), else: nil
        %{pct: pct, mah: mah}
    end
  end

  defp ideviceinfo(nil, _key), do: {:error, :no_hardware_udid}

  defp ideviceinfo(udid, key) do
    case System.find_executable("ideviceinfo") &&
           System.cmd("ideviceinfo", ["-u", udid, "-q", @battery_domain, "-k", key],
             stderr_to_stdout: true
           ) do
      {out, 0} ->
        val = String.trim(out)
        if val == "", do: {:error, "empty"}, else: {:ok, val}

      {out, _} when is_binary(out) ->
        {:error, String.trim(out)}

      _ ->
        {:error, "ideviceinfo not available"}
    end
  end

  # Returns the value we actually track: mAh if available, pct otherwise.
  defp battery_value(%{mah: mah}, _max_mah) when is_integer(mah), do: mah
  defp battery_value(%{pct: pct}, _max_mah), do: pct

  defp format_battery(%{mah: mah, pct: pct}, _max_mah) when is_integer(mah),
    do: "#{mah} mAh  (#{pct}%)"

  defp format_battery(%{pct: pct}, _max_mah),
    do: "#{pct}%"

  # ── Device detection ─────────────────────────────────────────────────────────

  defp auto_detect_usb do
    case System.find_executable("idevice_id") &&
           System.cmd("idevice_id", ["-l"], stderr_to_stdout: true) do
      {out, 0} ->
        out
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> List.first()

      _ ->
        nil
    end
  end

  # Finds the CoreDevice UUID of a connected (including WiFi-paired) iOS device
  # via `xcrun devicectl list devices --json-output`.
  defp auto_detect_wifi do
    tmp = Path.join(System.tmp_dir!(), "mob_devicectl_list_#{System.os_time(:millisecond)}.json")

    try do
      case System.cmd("xcrun", ["devicectl", "list", "devices", "--json-output", tmp],
             stderr_to_stdout: true
           ) do
        {_, 0} ->
          tmp
          |> File.read!()
          |> Jason.decode!()
          |> get_in(["result", "devices"])
          |> List.wrap()
          |> Enum.find_value(fn dev ->
            state =
              get_in(dev, ["connectionProperties", "tunnelState"]) ||
                get_in(dev, ["connectionProperties", "transportType"])

            if state not in [nil, "unavailable"] do
              dev["identifier"]
            end
          end)

        _ ->
          nil
      end
    rescue
      _ -> nil
    after
      File.rm(tmp)
    end
  end

  defp device_ok?(udid) do
    # Try USB (ideviceinfo), then devicectl (works over WiFi for paired devices)
    usb_ok =
      System.find_executable("ideviceinfo") &&
        match?(
          {_, 0},
          System.cmd("ideviceinfo", ["-u", udid, "-k", "DeviceName"], stderr_to_stdout: true)
        )

    usb_ok || devicectl_ok?(udid)
  end

  defp devicectl_ok?(identifier) do
    tmp = Path.join(System.tmp_dir!(), "mob_devicectl_check_#{System.os_time(:millisecond)}.json")

    try do
      case System.cmd("xcrun", ["devicectl", "list", "devices", "--json-output", tmp],
             stderr_to_stdout: true
           ) do
        {_, 0} ->
          tmp
          |> File.read!()
          |> Jason.decode!()
          |> get_in(["result", "devices"])
          |> List.wrap()
          |> Enum.any?(fn dev ->
            dev["identifier"] == identifier &&
              get_in(dev, ["connectionProperties", "tunnelState"]) not in [nil, "unavailable"]
          end)

        _ ->
          false
      end
    rescue
      _ -> false
    after
      File.rm(tmp)
    end
  end

  # ── Misc ─────────────────────────────────────────────────────────────────────

  # Query xcodebuild -list to find the scheme name instead of guessing from the
  # Elixir app name — the Xcode project/scheme name often differs from the Mix
  # app atom (e.g. project "Provision" scheme "MobProvision" vs app :smoke_test).
  defp detect_scheme!(workspace_kind, workspace_path) do
    type_flag =
      case workspace_kind do
        :workspace -> ["-workspace", workspace_path]
        :project -> ["-project", workspace_path]
      end

    case System.cmd("xcodebuild", type_flag ++ ["-list"], stderr_to_stdout: true) do
      {output, 0} ->
        schemes =
          output
          |> String.split("\n")
          |> Enum.drop_while(&(not String.contains?(&1, "Schemes:")))
          |> Enum.drop(1)
          |> Enum.take_while(&String.match?(&1, ~r/^\s+\S/))
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        camelized = Macro.camelize(app_name())

        case schemes do
          [] ->
            Mix.raise(
              "No schemes found in #{Path.basename(workspace_path)}. " <>
                "Use --scheme NAME or set ios_scheme in mob.exs."
            )

          [single] ->
            single

          multiple ->
            if camelized in multiple do
              camelized
            else
              Mix.raise("""
              Multiple schemes found in #{Path.basename(workspace_path)}:
                #{Enum.join(multiple, "\n  ")}

              Use --scheme NAME to select one, or add to mob.exs:
                config :mob_dev, ios_scheme: "YourSchemeName"
              """)
            end
        end

      {output, _} ->
        fallback = Macro.camelize(app_name())
        IO.puts("  (warning: xcodebuild -list failed, assuming scheme \"#{fallback}\")")
        IO.puts("  #{String.trim(output)}")
        fallback
    end
  end

  # Non-raising variant used by dry_run! where ios/ may not exist.
  defp find_workspace do
    ios_dir = Path.join(File.cwd!(), "ios")

    if File.dir?(ios_dir) do
      workspaces = Path.wildcard(Path.join(ios_dir, "*.xcworkspace"))
      projects = Path.wildcard(Path.join(ios_dir, "*.xcodeproj"))

      case {workspaces, projects} do
        {[ws | _], _} -> {:ok, {:workspace, ws}}
        {[], [proj | _]} -> {:ok, {:project, proj}}
        _ -> :error
      end
    else
      :error
    end
  end

  defp app_name, do: Mix.Project.config()[:app] |> to_string()

  defp time_string do
    {{_y, _mo, _d}, {h, m, s}} = :calendar.local_time()
    :io_lib.format("~2..0B:~2..0B:~2..0B", [h, m, s]) |> IO.iodata_to_binary()
  end
end
