defmodule Mix.Tasks.Mob.BatteryBenchAndroid do
  use Mix.Task

  alias MobDev.Bench.{DeviceObserver, Logger, Preflight, Probe, Reconnector, Summary}

  @shortdoc "Run a battery benchmark on an Android device"

  @moduledoc """
  Builds a benchmark APK, deploys it, and measures battery drain over time.

  Run this from your Mob app project directory (the one containing `android/`,
  `mob.exs`, and your Elixir source). It requires `bundle_id` to be set in
  `mob.exs`:

      config :mob_dev,
        mob_dir:   "/path/to/mob",
        bundle_id: "com.example.myapp"

  Reports mAh every 10 seconds and prints a summary at the end.
  WiFi ADB is required for accurate measurements (USB cable charges the battery).

  ## Setup (one-time, while plugged in)

      adb -s SERIAL tcpip 5555
      adb connect PHONE_IP:5555
      # then unplug and pass PHONE_IP:5555 as --device

  ## Recommended workflow

  Same two-step pattern as iOS — push BEAM flags via `mix mob.deploy`, then
  bench with `--no-build`. Lets you change tuning without a Gradle rebuild.

      # 1. Push BEAM flags via mob.deploy (no APK rebuild — ~10 sec).
      mix mob.deploy --beam-flags "" --android              # tuned (Nerves)
      mix mob.deploy --beam-flags "-S 4:4 -A 8" --android   # untuned variant

      # 2. Run the bench with --no-build.
      mix mob.battery_bench_android --no-build --device 192.168.1.42:5555

  See `README.md` for the full rationale and recovery procedure.

  ## Usage (with built-in Gradle build path)

      mix mob.battery_bench_android
      mix mob.battery_bench_android --no-beam
      mix mob.battery_bench_android --preset nerves
      mix mob.battery_bench_android --flags "-sbwt none -S 1:1"
      mix mob.battery_bench_android --duration 3600 --device 192.168.1.42:5555
      mix mob.battery_bench_android --no-build   # re-run without rebuilding

  ## Options

    * `--duration N`      — benchmark duration in **seconds** (default: 1800 = 30 min)
    * `--device SERIAL`   — adb device serial or IP:port (auto-detected if omitted)
    * `--no-beam`         — baseline: build without starting the BEAM at all
    * `--no-keep-alive`   — skip the foreground-service background keep-alive call
    * `--preset NAME`     — named BEAM flag preset (Gradle-build path only)
    * `--flags "..."`     — arbitrary BEAM VM flags (Gradle-build path only)
    * `--no-build`        — skip APK build and install; run benchmark on current install
    * `--log-path PATH`   — override CSV log location (default: `_build/bench/run_android_<ts>.csv`)
    * `--no-csv`          — skip CSV logging
    * `--skip-preflight`  — bypass the preflight checks (adb/app/BEAM/RPC/NIF/keep-alive)

  ## What the presets do

    * `untuned`   — raw BEAM with no tuning flags (highest power use baseline)
    * `sbwt`      — only busy-wait disabled (`-sbwt none`)
    * `nerves`    — full Nerves set: single scheduler + busy-wait off + multi_time_warp
    * (default)   — same as `nerves` (production default)

  ## Understanding the results

  The BEAM with Nerves-style tuning flags uses roughly the same power as an app
  with no BEAM at all (~200 mAh/hr on a Moto G, 30-min run). The untuned BEAM
  uses ~25% more power due to scheduler busy-waiting. For most apps the overhead
  is in the noise; tune if you have stricter power budgets.

  ## Under the hood

  `mix mob.battery_bench_android` orchestrates the following adb and Gradle commands:

      # Build and install
      ./gradlew assembleDebug [-PextraCppFlags="-DNO_BEAM|..."]
      adb install -r app/build/outputs/apk/debug/app-debug.apk

      # Push BEAMs
      adb push _build/dev/lib/*/ebin/*.beam /data/data/<pkg>/files/otp/<app>/

      # Reset battery stats and launch
      adb shell dumpsys batterystats --reset
      adb shell am start -n <pkg>/.MainActivity

      # Turn screen off
      adb shell input keyevent 26          # KEYCODE_POWER

      # Poll battery every 10s
      adb shell dumpsys battery            # reads "Charge counter: <µAh>"

      # Stop app and collect final reading
      adb shell am force-stop <pkg>
      adb shell dumpsys battery

  BEAM tuning flags are injected as C preprocessor defines (`-DBEAM_UNTUNED`,
  `-DBEAM_FULL_NERVES`, etc.) or via a generated `mob_beam_flags.h` header, so
  each preset compiles a different variant of the BEAM startup C code.
  """

  @switches [
    duration: :integer,
    device: :string,
    no_beam: :boolean,
    no_keep_alive: :boolean,
    preset: :string,
    flags: :string,
    no_build: :boolean,
    dry_run: :boolean,
    log_path: :string,
    no_csv: :boolean,
    skip_preflight: :boolean
  ]

  @android_activity ".MainActivity"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: @switches)

    if opts[:dry_run] do
      dry_run!(opts)
      exit(:normal)
    end

    duration = opts[:duration] || 1800
    no_build = opts[:no_build] || false

    device =
      case opts[:device] || auto_detect_device() do
        nil ->
          Mix.raise("""
          No Android device found. Options:
            mix mob.battery_bench_android --device 192.168.1.42:5555
            adb connect PHONE_IP:5555 then re-run
          """)

        d ->
          d
      end

    pkg = MobDev.Config.bundle_id()
    app = app_name()

    IO.puts("")
    IO.puts("=== Mob Battery Benchmark ===")
    IO.puts("")
    IO.puts("  Device:   #{device}")
    IO.puts("  Package:  #{pkg}")
    IO.puts("  Duration: #{duration}s (#{div(duration, 60)} min)")
    IO.puts("  Mode:     #{describe_mode(opts)}")
    IO.puts("")

    unless adb_ok?(device) do
      Mix.raise("Cannot reach device #{device}. Check: adb connect #{device}")
    end

    # ── Build ──────────────────────────────────────────────────────────────────

    unless no_build do
      {extra_cpp_flags, header_dir} = resolve_build_flags(opts)

      IO.puts("=== Building APK ===")
      build_apk(extra_cpp_flags, header_dir)

      IO.puts("=== Installing APK ===")
      apk = "android/app/build/outputs/apk/debug/app-debug.apk"
      unless File.exists?(apk), do: Mix.raise("APK not found at #{apk}. Build may have failed.")
      install_apk(device, apk, pkg)

      IO.puts("=== Pushing BEAMs ===")
      Mix.Task.run("compile")
      push_beams(device, pkg, app)

      # Clean up temp header dir
      if header_dir, do: File.rm_rf!(header_dir)
    end

    # ── Pre-run checks ─────────────────────────────────────────────────────────

    battery_pct = read_battery_pct(device)
    IO.puts("")
    IO.puts("Battery level: #{battery_pct}%")

    if battery_pct < 80 do
      IO.puts("WARNING: Battery below 80%. Charge to >90% for comparable results.")
      IO.puts("Continue? (y/N)")

      case prompt_yn("") do
        "y" -> :ok
        _ -> Mix.raise("Aborted.")
      end
    end

    # ── Promote USB → WiFi ADB so the connection survives unplug ──
    # If the user passed a USB serial, auto-enable WiFi adb and switch the
    # bench's `device` to <ip>:5555. If it's already an IP:port (WiFi adb
    # already active), pass through unchanged. Saves the user from the
    # tcpip/connect dance manually.
    device = ensure_wifi_adb!(device)

    IO.puts("")
    IO.puts("==========================================")
    IO.puts("  Unplug the USB cable now if connected.")
    IO.puts("  Press Enter when ready to start the run.")
    IO.puts("==========================================")
    wait_for_enter()

    unless adb_ok?(device) do
      Mix.raise("""
      Lost connection after unplug.

      The bench tried to switch to WiFi ADB automatically; that's failing
      now. Common causes:
        - Device not on WiFi
        - WiFi network blocking ADB port (5555)
        - Device's WiFi went to sleep when screen locked

      You can do it manually before re-running:
        adb -s <USB-SERIAL> tcpip 5555
        adb connect <PHONE-WIFI-IP>:5555
        mix mob.battery_bench_android --no-build --device <PHONE-WIFI-IP>:5555
      """)
    end

    # ── Benchmark ──────────────────────────────────────────────────────────────

    IO.puts("")
    IO.puts("=== Resetting battery stats ===")
    adb!(device, ~w[shell dumpsys batterystats --reset])
    :timer.sleep(2000)

    start_mah = read_charge_counter_mah(device)
    IO.puts("Start charge: #{start_mah} mAh")

    # ── Set up adb tunnels BEFORE launching the app ─────────────────────
    # The BEAM tries to register with Mac's EPMD via 127.0.0.1:4369 during
    # startup. That works only if the adb reverse tunnel is already up
    # before mob_start_beam runs. If we set up tunnels after launch, the
    # BEAM has already tried and failed to register, and verify_app_running!
    # will (correctly) report "BEAM never registered".
    ensure_tunnels(device)

    IO.puts("")
    IO.puts("=== Launching app ===")
    adb!(device, ~w[shell am start -n #{pkg}/#{@android_activity}])
    :timer.sleep(3000)

    # ── Verify the app actually started ─────────────────────────────────
    # If the BEAM crashes on launch (missing native libs, bad flags, etc.)
    # the app process disappears within seconds. Catching it here saves a
    # 30-minute meaningless run.
    verify_app_running!(device, pkg)

    node = :"#{app}_android@127.0.0.1"

    # Poll Node.connect for up to 10 s. The BEAM's `Mob.Dist` waits ~3 s
    # after app launch and only then registers — and the EPMD-name->port
    # path can be briefly stale if a previous run held the slot. A single-
    # shot connect here would race with all of that and `active_node = nil`
    # for the rest of the run, leaving every probe stuck on `:unreachable`
    # even when the BEAM is healthy and Erlang dist works fine seconds later.
    node_alive? = try_connect_with_retry(node, 10_000)

    active_node = if node_alive?, do: node, else: nil

    if node_alive? and opts[:no_keep_alive] != true do
      IO.puts("  Starting background keep-alive...")
      :rpc.call(node, :mob_nif, :background_keep_alive, [], 5000)
    end

    # ── Preflight ──────────────────────────────────────────────────────────
    unless opts[:skip_preflight] do
      IO.puts("")
      IO.puts("=== Preflight checks ===")

      preflight_results =
        Preflight.run(
          platform: :android,
          node: active_node,
          host: "127.0.0.1",
          cookie: :mob_secret,
          bundle_id: pkg,
          adb_serial: device,
          require_keep_alive: opts[:no_keep_alive] != true
        )

      IO.puts(Preflight.pretty(preflight_results))

      unless Preflight.all_ok?(preflight_results) do
        IO.puts("")
        IO.puts(">>> Preflight reported issues. Continue anyway? (y/N)")

        case IO.gets("") |> String.trim() do
          "y" -> :ok
          _ -> Mix.raise("Aborted at preflight.")
        end
      end
    end

    screen_off(device)

    IO.puts("")
    IO.puts("Running for #{div(duration, 60)} min — do not touch the phone...")
    IO.puts("")

    total_min = div(duration, 60)
    start_time = System.monotonic_time(:second)

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
              "run_android_#{System.os_time(:second)}.csv"
            ])

        IO.puts("  Logging samples to #{log_path}")
        Logger.open(log_path, start_ts_ms: System.monotonic_time(:millisecond))
      end

    reconnector = Reconnector.new(active_node || :unset@unset, :mob_secret)

    observer =
      DeviceObserver.subscribe(active_node, categories: [:app, :display, :memory])

    if observer.subscribed? do
      IO.puts("  Subscribed to Mob.Device events on #{inspect(active_node)}")
    end

    {final_log, _final_reconnector, _final_observer} =
      Enum.reduce(1..duration, {log, reconnector, observer}, fn i,
                                                                {log_acc, recon_acc, obs_acc} ->
        :timer.sleep(1000)

        if rem(i, 10) == 0 do
          poll_tick(
            log_acc,
            recon_acc,
            obs_acc,
            node: active_node,
            host: "127.0.0.1",
            adb_serial: device,
            bundle_id: pkg,
            expected_screen: :off,
            start_time: start_time,
            start_mah: start_mah,
            total_min: total_min
          )
        else
          {log_acc, recon_acc, DeviceObserver.consume_messages(obs_acc)}
        end
      end)

    log = final_log

    # ── Results ────────────────────────────────────────────────────────────────

    IO.puts("")
    IO.puts("=== Collecting results ===")
    adb!(device, ~w[shell am force-stop #{pkg}])
    :timer.sleep(1000)

    end_mah = read_charge_counter_mah(device)
    end_pct = read_battery_pct(device)
    drain_mah = start_mah - end_mah
    elapsed_actual = System.monotonic_time(:second) - start_time

    rate =
      if elapsed_actual > 0,
        do: Float.round(drain_mah * 3600 / elapsed_actual, 1),
        else: 0.0

    IO.puts("")
    IO.puts("=== Summary: #{describe_mode(opts)} ===")
    IO.puts("")
    IO.puts("  Duration:     #{div(elapsed_actual, 60)} min #{rem(elapsed_actual, 60)} sec")
    IO.puts("  Start:        #{start_mah} mAh  (#{battery_pct}%)")
    IO.puts("  End:          #{end_mah} mAh  (#{end_pct}%)")
    IO.puts("  Drain:        #{drain_mah} mAh")
    IO.puts("  Rate:         #{rate} mAh/hr")
    IO.puts("")
    IO.puts("Lower mAh/hr = better. No-BEAM baseline is ~200 mAh/hr on Moto G.")
    IO.puts("")

    # ── CSV-based summary ───────────────────────────────────────────────
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
        e -> IO.puts("  (could not parse #{log_path}: #{Exception.message(e)})")
      end

      IO.puts("")
    end
  end

  # ── Probe-driven poll tick ────────────────────────────────────────────────

  defp poll_tick(log, reconnector, observer, opts) do
    elapsed_sec = System.monotonic_time(:second) - opts[:start_time]
    elapsed_min = Float.round(elapsed_sec / 60, 1)
    ts = time_string()

    observer = DeviceObserver.consume_messages(observer)

    probe =
      Probe.snapshot(
        platform: :android,
        node: opts[:node],
        host: opts[:host],
        adb_serial: opts[:adb_serial],
        bundle_id: opts[:bundle_id],
        expected_screen: opts[:expected_screen]
      )

    probe = DeviceObserver.apply_to_probe(observer, probe)
    log = if log, do: Logger.append(log, probe), else: log

    fragment = Probe.format(probe)

    line =
      case probe.battery_pct do
        nil ->
          "  [#{ts}] #{elapsed_min}/#{opts[:total_min]} min — #{fragment}"

        pct ->
          # Note: Android USB probe returns battery percentage. We separately
          # track mAh via dumpsys for the Android-specific drain calculation
          # below, but the live trace uses % to align with iOS bench output.
          "  [#{ts}] #{elapsed_min}/#{opts[:total_min]} min — #{fragment} (#{pct}%)"
      end

    IO.puts(line)

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

  # ── Dry run ───────────────────────────────────────────────────────────────────

  defp dry_run!(opts) do
    pkg = MobDev.Config.bundle_id()
    duration = opts[:duration] || 1800

    # Validate preset / flags (raises on bad preset name)
    {cflags, header_dir} = resolve_build_flags(opts)
    if header_dir, do: File.rm_rf!(header_dir)

    IO.puts("")
    IO.puts("=== Mob Battery Benchmark (Android) — Dry Run ===")
    IO.puts("")
    IO.puts("  Device:   #{opts[:device] || "(auto-detect at run time)"}")
    IO.puts("  Package:  #{pkg || "(NOT SET)"}")
    IO.puts("  Duration: #{duration}s (#{div(duration, 60)} min)")
    IO.puts("  Mode:     #{describe_mode(opts)}")
    IO.puts("  Flags:    #{if cflags == "", do: "(default Nerves tuning)", else: cflags}")
    IO.puts("  Build:    #{if opts[:no_build], do: "skip (--no-build)", else: "yes"}")
    IO.puts("")

    IO.puts("Dry run complete — no prerequisites checked, no device contacted.")
    IO.puts("")
  end

  # ── Build flags ──────────────────────────────────────────────────────────────

  # Returns {extra_cpp_flags_string, header_temp_dir_or_nil}
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
          "/* generated by mix mob.battery_bench_android -- do not edit */\n" <>
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
        # Production default (full Nerves tuning)
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

  # ── APK build ────────────────────────────────────────────────────────────────

  defp build_apk(extra_cpp_flags, _header_dir) do
    android_dir = Path.join(File.cwd!(), "android")
    gradlew = Path.join(android_dir, "gradlew")

    unless File.exists?(gradlew), do: Mix.raise("gradlew not found at #{gradlew}")

    IO.puts("  Running Gradle assembleDebug...")

    args =
      ["assembleDebug", "-q"] ++
        if extra_cpp_flags != "", do: ["-PextraCppFlags=#{extra_cpp_flags}"], else: []

    case System.cmd(gradlew, args, cd: android_dir, stderr_to_stdout: true, into: IO.stream()) do
      {_, 0} -> :ok
      {_, _} -> Mix.raise("Gradle assembleDebug failed — check output above")
    end
  end

  defp install_apk(device, apk, pkg) do
    IO.puts("  Stopping app...")
    adb(device, ~w[shell am force-stop #{pkg}])
    IO.puts("  Installing #{apk}...")

    # `adb install -r` replaces the APK in-place. It re-extracts native libs
    # to /data/app/<pkg>/lib/<abi>/ but preserves /data/data/<pkg>/, which is
    # critical: that directory holds files/otp/erts-*/bin/ — pushed by
    # `mix mob.deploy --native` during initial provisioning. A previous
    # version of this code did `adb uninstall && adb install`, which nuked
    # /data/data/ and left the device with no ERTS, so mob_start_beam would
    # crash on every subsequent launch with "symlink erl_child_setup failed".
    #
    # Falls back to uninstall+install on signature mismatch
    # (INSTALL_FAILED_UPDATE_INCOMPATIBLE) — that path will rebuild the OTP
    # runtime via the next `mix mob.deploy --native`, but the user has been
    # warned.
    case adb(device, ~w[install -r #{apk}]) do
      {:ok, out} ->
        if String.contains?(out, "INSTALL_FAILED") do
          handle_install_failure(device, apk, pkg, out)
        else
          :ok
        end

      {:error, reason} ->
        if String.contains?(reason, "INSTALL_FAILED_UPDATE_INCOMPATIBLE") do
          handle_install_failure(device, apk, pkg, reason)
        else
          Mix.raise("APK install failed: #{reason}")
        end
    end
  end

  # When `install -r` fails because the new APK has a different signing
  # certificate from the installed one, fall back to uninstall + install. This
  # destroys /data/data/<pkg>/ and any OTP runtime there, so warn the user
  # they'll need to rerun `mix mob.deploy --native` to restore ERTS before
  # launching the app again.
  defp handle_install_failure(device, apk, pkg, reason) do
    IO.puts("  #{IO.ANSI.yellow()}⚠  install -r failed: #{String.slice(reason, 0, 200)}#{IO.ANSI.reset()}")
    IO.puts("     Falling back to full uninstall+install. This will erase the")
    IO.puts("     OTP runtime in /data/data/#{pkg}/files/. After the bench finishes,")
    IO.puts("     re-run `mix mob.deploy --native --device #{device}` to restore ERTS.")

    adb(device, ~w[uninstall #{pkg}])

    case adb(device, ~w[install #{apk}]) do
      {:ok, _} -> :ok
      {:error, why} -> Mix.raise("APK install failed: #{why}")
    end
  end

  # ── BEAM push ────────────────────────────────────────────────────────────────

  defp push_beams(device, pkg, app) do
    beam_dirs = collect_beam_dirs()
    beams_dir = "/data/data/#{pkg}/files/otp/#{app}"

    # Check if we can root
    rooted? =
      case adb(device, ["root"]) do
        {:ok, out} -> out =~ "restarting" or out =~ "already running as root"
        _ -> false
      end

    if rooted? do
      :timer.sleep(600)
      adb!(device, ~w[shell mkdir -p #{beams_dir}])

      Enum.each(beam_dirs, fn dir ->
        adb!(device, ["push", "#{dir}/.", "#{beams_dir}/"])
      end)
    else
      push_beams_runas(device, pkg, beams_dir, beam_dirs)
    end
  end

  defp push_beams_runas(device, pkg, beams_dir, beam_dirs) do
    stage_local = Path.join(System.tmp_dir!(), "mob_bench_beams.tar")
    stage_device = "/data/local/tmp/mob_bench_beams.tar"

    tmp = Path.join(System.tmp_dir!(), "mob_bench_stage")
    File.rm_rf!(tmp)
    File.mkdir_p!(tmp)
    Enum.each(beam_dirs, fn dir -> System.cmd("cp", ["-r", "#{dir}/.", tmp]) end)

    System.cmd("tar", ["cf", stage_local, "-C", Path.dirname(tmp), Path.basename(tmp)])
    adb!(device, ["push", stage_local, stage_device])
    adb!(device, ~w[shell run-as #{pkg} mkdir -p #{beams_dir}])

    cmd = "run-as #{pkg} tar xf #{stage_device} -C #{beams_dir}/ --strip-components=1"
    adb!(device, ["shell", cmd])
    adb(device, ~w[shell rm -f #{stage_device}])

    File.rm(stage_local)
    File.rm_rf!(tmp)
  end

  defp collect_beam_dirs do
    case File.ls("_build/dev/lib") do
      {:ok, libs} ->
        libs
        |> Enum.map(&"_build/dev/lib/#{&1}/ebin")
        |> Enum.filter(&File.dir?/1)

      {:error, _} ->
        []
    end
  end

  # ── Screen off ───────────────────────────────────────────────────────────────

  defp screen_off(device) do
    IO.puts("=== Turning screen off ===")
    # Check current state, press KEYCODE_POWER (26) to toggle off.
    # If it ended up on (was already off before), press again.
    adb!(device, ~w[shell input keyevent 26])
    :timer.sleep(1000)
    screen = adb_out(device, ~w[shell dumpsys display])

    if screen =~ ~r/mScreenState.*ON/i or screen =~ ~r/mState.*ON/i do
      adb!(device, ~w[shell input keyevent 26])
    end

    IO.puts("  Screen off.")
  end

  # ── Battery readings ─────────────────────────────────────────────────────────

  # Charge counter in µAh → divide by 1000 for mAh.
  # Falls back to percentage-based estimate if charge counter is unavailable.
  defp read_charge_counter_mah(device) do
    out = adb_out(device, ~w[shell dumpsys battery])

    case Regex.run(~r/Charge counter:\s*(\d+)/, out) do
      [_, uah] ->
        div(String.to_integer(uah), 1000)

      nil ->
        # Fallback: no charge counter on this device
        read_battery_pct(device)
    end
  end

  defp read_battery_pct(device) do
    out = adb_out(device, ~w[shell dumpsys battery])

    case Regex.run(~r/level:\s*(\d+)/, out) do
      [_, pct] -> String.to_integer(pct)
      nil -> 0
    end
  end

  # ── ADB helpers ──────────────────────────────────────────────────────────────

  defp auto_detect_device do
    case System.cmd("adb", ["devices"], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n")
        |> Enum.drop(1)
        |> Enum.filter(&String.contains?(&1, "\tdevice"))
        |> Enum.map(&(&1 |> String.split("\t") |> hd() |> String.trim()))
        |> List.first()

      _ ->
        nil
    end
  end

  defp adb_ok?(device) do
    case System.cmd("adb", ["-s", device, "shell", "echo", "ok"], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp adb(device, args) do
    case System.cmd("adb", ["-s", device | args], stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, _} -> {:error, String.trim(out)}
    end
  end

  defp adb!(device, args) do
    case adb(device, args) do
      {:ok, out} ->
        out

      {:error, reason} ->
        IO.puts("  adb warning: #{reason}")
        ""
    end
  end

  defp adb_out(device, args) do
    case System.cmd("adb", ["-s", device | args], stderr_to_stdout: true) do
      {out, _} -> out
    end
  end

  # ── Misc ──────────────────────────────────────────────────────────────────────

  defp app_name, do: Mix.Project.config()[:app] |> to_string()

  # IO.gets returns :eof in non-interactive contexts (piped stdin, certain
  # CI runners). Treat EOF as "no answer" rather than crashing in
  # String.trim/1.
  defp prompt_yn(prompt) do
    case IO.gets(prompt) do
      :eof -> "n"
      {:error, _} -> "n"
      str when is_binary(str) -> str |> String.trim() |> String.downcase()
    end
  end

  defp wait_for_enter do
    case IO.gets("") do
      :eof ->
        IO.puts("  (stdin not interactive — proceeding without confirmation)")
        :ok

      {:error, _} ->
        :ok

      _ ->
        :ok
    end
  end

  # Verify both that (a) the Android process is up and (b) the BEAM has
  # finished booting and registered its node in EPMD with a *live* listener.
  # Catches four failure modes:
  #   1. App crashes immediately       → pidof returns empty
  #   2. App shell up, BEAM crashed    → pidof returns pid, EPMD never has node
  #   3. Stale EPMD entry from prior   → EPMD has node but TCP-probe fails
  #      run (different device, etc.)    (the listener at the registered
  #                                       port isn't actually accepting)
  #   4. Healthy startup               → pidof + live EPMD entry both succeed
  #
  # The stale-entry case is especially nasty: another device/run can leave a
  # name registered in Mac's EPMD that points to a port nothing is listening
  # on. Without the TCP probe, the bench thinks the BEAM is up and lets a
  # 30-minute run proceed where every RPC will fail.
  defp verify_app_running!(device, pkg) do
    app = app_name()
    expected_node_name = "#{app}_android"

    deadline_ms = System.monotonic_time(:millisecond) + 10_000

    result =
      verify_loop(device, pkg, expected_node_name, deadline_ms,
        last_pid: nil,
        last_epmd_entries: nil
      )

    case result do
      {:ok, pid, port} ->
        IO.puts("  ✓ App running on device (pid #{pid})")
        IO.puts("  ✓ BEAM registered in EPMD as #{expected_node_name} (port #{port})")

      {:error, :no_process, _state} ->
        Mix.raise(crash_diagnosis_no_process(device, pkg))

      {:error, :process_no_beam, state} ->
        Mix.raise(crash_diagnosis_no_beam(device, pkg, state[:last_pid]))

      # Stale EPMD entry isn't fatal — the bench can still run with USB-only
      # battery readings. Warn loudly so the user knows BEAM-driven probes
      # (RPC, NIF version checks) won't work, then fall through.
      {:error, :stale_epmd, state} ->
        IO.puts("  ✓ App running on device (pid #{state[:last_pid]})")

        IO.puts(
          "  #{IO.ANSI.yellow()}⚠  EPMD has #{expected_node_name} at port #{state[:stale_port]} but Node.connect fails — stale entry from a prior run#{IO.ANSI.reset()}"
        )

        IO.puts(stale_epmd_recovery_hint(device, pkg))
    end
  end

  defp verify_loop(device, pkg, expected_node_name, deadline_ms, state) do
    :timer.sleep(500)

    pid = pid_of(device, pkg)
    epmd_entries = epmd_names_local()
    registered_port = Map.get(epmd_entries, expected_node_name)
    expected_node = :"#{expected_node_name}@127.0.0.1"

    cond do
      pid && registered_port && beam_reachable?(expected_node) ->
        {:ok, pid, registered_port}

      System.monotonic_time(:millisecond) >= deadline_ms ->
        cond do
          is_nil(pid) ->
            {:error, :no_process, [last_pid: state[:last_pid], last_epmd_entries: epmd_entries]}

          # EPMD has an entry but Node.connect can't actually reach the BEAM
          # — almost always a stale entry from a prior run.
          registered_port ->
            {:error, :stale_epmd,
             [last_pid: pid, last_epmd_entries: epmd_entries, stale_port: registered_port]}

          true ->
            {:error, :process_no_beam, [last_pid: pid, last_epmd_entries: epmd_entries]}
        end

      true ->
        verify_loop(device, pkg, expected_node_name, deadline_ms,
          last_pid: pid || state[:last_pid],
          last_epmd_entries: epmd_entries
        )
    end
  end

  defp pid_of(device, pkg) do
    case System.cmd("adb", ["-s", device, "shell", "pidof", pkg], stderr_to_stdout: true) do
      {out, 0} ->
        case String.trim(out) do
          "" -> nil
          s -> s
        end

      _ ->
        nil
    end
  end

  # Returns a map of %{node_name => port} for everything Mac's EPMD knows.
  defp epmd_names_local do
    case :gen_tcp.connect(~c"127.0.0.1", 4369, [:binary, active: false], 500) do
      {:ok, sock} ->
        :gen_tcp.send(sock, <<0, 1, ?n>>)

        entries =
          case :gen_tcp.recv(sock, 0, 500) do
            {:ok, <<_::32, body::binary>>} ->
              body
              |> String.split("\n", trim: true)
              |> Enum.flat_map(fn line ->
                case Regex.run(~r/^name (\S+) at port (\d+)$/, line) do
                  [_, name, port] -> [{name, String.to_integer(port)}]
                  _ -> []
                end
              end)
              |> Map.new()

            _ ->
              %{}
          end

        :gen_tcp.close(sock)
        entries

      _ ->
        %{}
    end
  end

  # Confirm the registered BEAM is actually reachable over Erlang
  # distribution — the only check that distinguishes a live BEAM from a
  # stale EPMD entry. A plain TCP-connect on the registered port is
  # unreliable here because `adb forward` accepts host-side connections
  # eagerly and only later finds out the device-side socket is dead, so a
  # raw `gen_tcp:connect/3` returns `:ok` even when nothing is listening
  # inside the app.
  defp beam_reachable?(node) do
    Node.set_cookie(node, :mob_secret)
    Node.connect(node) == true
  rescue
    _ -> false
  end

  # Repeatedly try Node.connect until success or timeout. Used right after
  # `verify_app_running!` to handle the timing window where the device-side
  # `Mob.Dist` is still bringing up its listener — a single Node.connect
  # would fail and leave `active_node = nil` for the entire run, sending
  # every probe to `:unreachable` even when the BEAM is healthy.
  defp try_connect_with_retry(node, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_try_connect(node, deadline, _attempts = 0)
  end

  defp do_try_connect(node, deadline, attempts) do
    if beam_reachable?(node) do
      IO.puts("  BEAM connected: #{node}")
      true
    else
      if System.monotonic_time(:millisecond) < deadline do
        :timer.sleep(500)
        do_try_connect(node, deadline, attempts + 1)
      else
        IO.puts("  (BEAM not reachable after #{attempts + 1} attempts — USB-only readings)")

        false
      end
    end
  end

  defp crash_diagnosis_no_process(device, pkg) do
    """

    ✗ App #{pkg} is not running ~10 seconds after launch.

    The Android process is gone — BEAM crashed before the iOS shell could
    keep it alive. Common causes:

      - Missing ERTS helper libs in the APK (check lib/<abi>/ contains
        liberl_child_setup.so, libinet_gethost.so, libepmd.so — for
        32-bit ARM devices they need to be in lib/arm, not just
        lib/arm64).
      - Bad BEAM flags in mob.exs (try `mix mob.deploy --beam-flags ""`)
      - App crashed for an unrelated reason — check logcat:

          adb -s #{device} logcat -d | grep -iE "MobBeam|MobNIF|FATAL|tombstone"

    Re-run the bench after the app launches cleanly.
    """
  end

  defp crash_diagnosis_no_beam(device, pkg, pid) do
    """

    ✗ App #{pkg} is running (pid #{pid}) but the BEAM never registered.

    The Android process is alive but the embedded BEAM either crashed
    during startup or isn't reachable via Erlang distribution. Common
    causes:

      - BEAM crashed in mob_start_beam — check logcat for SIGABRT in
        beam-main:

          adb -s #{device} logcat -d | grep -iE "MobBeam|FATAL|SIGABRT|beam-main"

      - OTP runtime never deployed to this device. The app is installed
        but /data/data/<pkg>/files/otp/erts-*/bin/ is missing. Common when
        the device wasn't connected during a previous `mix mob.deploy
        --native`. Provision it now:

          mix mob.deploy --native --device #{device}

      - BEAMs stale on device. If OTP is present, push fresh BEAMs:

          mix mob.deploy --android --device #{device}

      - Bad BEAM flags in mob.exs (try `mix mob.deploy --beam-flags ""`)
      - adb tunnels not set up (the bench tries automatically; if your
        Mac's EPMD is occupied by another node, things may collide)

    The Android process may be the foreground service / notification
    process keeping the package alive even though the BEAM died. Don't
    take a green `pidof` as proof the BEAM is up — EPMD registration is
    the authoritative signal.
    """
  end

  defp stale_epmd_recovery_hint(device, pkg) do
    others = other_devices_running(device, pkg)

    collision_block =
      case others do
        [] ->
          """
             No other adb-connected device appears to be running #{pkg}, so
             the EPMD entry is most likely stale (left by a previous run).
          """

        _ ->
          formatted =
            Enum.map_join(others, "\n", fn {serial, pid} ->
              "         adb -s #{serial} shell am force-stop #{pkg}   # pid #{pid}"
            end)

          """
             Other adb-connected device(s) are also running #{pkg} — they're
             holding the EPMD `<app>_android` slot. Force-stop them so this
             bench's BEAM can register, OR disconnect those devices:

          #{formatted}

             (Each Android device hardcodes the same node name, so only one
             can register in Mac's EPMD via adb-reverse at a time. The
             structural fix is per-device unique node names, like iOS sims
             do with their UDID suffix — not yet implemented.)
          """
      end

    """
       Bench will fall back to USB-only readings (no per-second RPC probes).

    #{collision_block}
       Other recovery options:

         # Force EPMD to forget every node (kills any other Mob iEx sessions):
         pkill -9 epmd && epmd -daemon
         adb -s #{device} reverse --remove-all && \\
           adb -s #{device} reverse tcp:4369 tcp:4369

       Logcat tells you whether the BEAM tried distribution this run:
         adb -s #{device} logcat -d | grep -iE "Mob.Dist|step [0-9]"
    """
  end

  # Walk every adb-connected device, check whether it has `pkg` running, and
  # return the [{serial, pid}] list excluding the bench's own target. Used to
  # tell the user which other phone is squatting on the EPMD slot.
  defp other_devices_running(this_device, pkg) do
    case System.cmd("adb", ["devices"], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n")
        |> Enum.drop(1)
        |> Enum.filter(&String.contains?(&1, "\tdevice"))
        |> Enum.map(&hd(String.split(&1, "\t")))
        |> Enum.reject(&same_device?(&1, this_device))
        |> Enum.flat_map(fn serial ->
          case System.cmd("adb", ["-s", serial, "shell", "pidof", pkg], stderr_to_stdout: true) do
            {out, 0} ->
              case String.trim(out) do
                "" -> []
                pid -> [{serial, pid}]
              end

            _ ->
              []
          end
        end)

      _ ->
        []
    end
  end

  # Two adb identifiers refer to the same physical device when one is the
  # USB serial and the other is `<ip>:5555` for the same phone. We can't
  # always tell that from the strings alone, so be lenient: equal-string match
  # plus IP-port form for the bench's own device.
  defp same_device?(serial, this_device) do
    serial == this_device or
      serial == strip_port(this_device) or
      "#{serial}:5555" == this_device
  end

  defp strip_port(s) do
    case String.split(s, ":", parts: 2) do
      [host, _port] -> host
      _ -> s
    end
  end

  # If the user passed a USB serial (no IP:port), auto-enable WiFi ADB so
  # the bench's `device` argument keeps working after the user unplugs the
  # USB cable. Returns the (possibly-promoted) device identifier.
  #
  # Steps:
  #   1. Detect device is USB-connected (serial doesn't match IP:port format)
  #   2. Find its WiFi IP via `adb shell ip route get 1.1.1.1`
  #   3. `adb -s SERIAL tcpip 5555` to enable WiFi adb
  #   4. Sleep briefly for the device to switch
  #   5. `adb connect IP:5555`
  #   6. Verify the IP:5555 connection works
  #   7. Return "IP:5555" — caller uses this for all subsequent adb commands
  #
  # If anything fails along the way, raise with a clear hint to do it
  # manually rather than surprising the user later when unplug fails.
  defp ensure_wifi_adb!(device) do
    if String.contains?(device, ":") do
      # Already IP:port — assume user has WiFi adb working.
      device
    else
      promote_usb_to_wifi!(device)
    end
  end

  defp promote_usb_to_wifi!(serial) do
    IO.puts("")
    IO.puts("=== Switching to WiFi ADB ===")
    IO.puts("  Finding device WiFi IP...")
    ip = wifi_ip_for_serial!(serial)
    IO.puts("  Device IP: #{ip}")

    IO.puts("  Enabling WiFi ADB on port 5555...")

    case System.cmd("adb", ["-s", serial, "tcpip", "5555"], stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {out, _} ->
        Mix.raise("""
        Failed to enable WiFi ADB:
          #{String.trim(out)}

        Try manually:
          adb -s #{serial} tcpip 5555
          adb connect <PHONE-IP>:5555
        """)
    end

    # Device needs a moment to restart adbd in TCP mode.
    :timer.sleep(2_000)

    new_device = "#{ip}:5555"
    IO.puts("  Connecting to #{new_device}...")

    case System.cmd("adb", ["connect", new_device], stderr_to_stdout: true) do
      {out, 0} ->
        if String.contains?(out, "connected") or String.contains?(out, "already connected") do
          # Verify it actually works.
          if adb_ok?(new_device) do
            IO.puts("  ✓ WiFi ADB connected as #{new_device}")
            new_device
          else
            Mix.raise("""
            adb connect reported success but the device isn't responding.
            Check WiFi network and re-run with the WiFi-ADB serial:
              mix mob.battery_bench_android --no-build --device #{new_device}
            """)
          end
        else
          Mix.raise("""
          adb connect failed:
            #{String.trim(out)}
          """)
        end

      {out, _} ->
        Mix.raise("""
        adb connect failed:
          #{String.trim(out)}

        Try manually:
          adb -s #{serial} tcpip 5555
          adb connect #{new_device}
        """)
    end
  end

  # Find the device's WiFi IPv4 by running `ip route get 1.1.1.1` on it
  # and parsing the `src` field from the output.
  defp wifi_ip_for_serial!(serial) do
    case System.cmd("adb", ["-s", serial, "shell", "ip", "route", "get", "1.1.1.1"],
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        case Regex.run(~r/\bsrc\s+(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})/, out) do
          [_, ip] ->
            ip

          nil ->
            Mix.raise("""
            Couldn't determine the device's WiFi IP from:
              #{String.trim(out)}

            Is the device connected to WiFi? Settings → Network & internet → Internet.
            """)
        end

      {out, _} ->
        Mix.raise("""
        adb shell ip route failed:
          #{String.trim(out)}
        """)
    end
  end

  # Set up the adb tunnels needed for Erlang dist:
  #   adb reverse tcp:4369 tcp:4369   — Android BEAM registers in Mac's EPMD
  #   adb forward tcp:9100 tcp:9100   — Mac reaches device's dist port
  # No-op on failure — the bench will detect the missing connection during
  # preflight and the user can investigate.
  defp ensure_tunnels(serial) when is_binary(serial) do
    System.cmd("adb", ["-s", serial, "reverse", "tcp:4369", "tcp:4369"], stderr_to_stdout: true)

    System.cmd("adb", ["-s", serial, "forward", "tcp:9100", "tcp:9100"], stderr_to_stdout: true)

    # Local Erlang dist must be alive for Node.connect/1 to work.
    unless Node.alive?() do
      Node.start(:"mob_bench_android@127.0.0.1", :longnames)
      Node.set_cookie(:mob_secret)
    end

    :ok
  end

  defp time_string do
    {{_y, _mo, _d}, {h, m, s}} = :calendar.local_time()
    :io_lib.format("~2..0B:~2..0B:~2..0B", [h, m, s]) |> IO.iodata_to_binary()
  end
end
