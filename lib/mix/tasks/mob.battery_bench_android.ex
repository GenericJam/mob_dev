defmodule Mix.Tasks.Mob.BatteryBenchAndroid do
  use Mix.Task

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

  ## Usage

      mix mob.battery_bench_android
      mix mob.battery_bench_android --no-beam
      mix mob.battery_bench_android --preset nerves
      mix mob.battery_bench_android --flags "-sbwt none -S 1:1"
      mix mob.battery_bench_android --duration 3600 --device 192.168.1.42:5555
      mix mob.battery_bench_android --no-build   # re-run without rebuilding

  ## Options

    * `--duration N`      — benchmark duration in seconds (default: 1800)
    * `--device SERIAL`   — adb device serial or IP:port (auto-detected if omitted)
    * `--no-beam`         — baseline: build without starting the BEAM at all
    * `--preset NAME`     — named BEAM flag preset: `untuned`, `sbwt`, or `nerves`
    * `--flags "..."`     — arbitrary BEAM VM flags (space-separated, e.g. "-sbwt none")
    * `--no-build`        — skip APK build and install; run benchmark on current install

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
    preset: :string,
    flags: :string,
    no_build: :boolean,
    dry_run: :boolean
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

      case IO.gets("") |> String.trim() do
        "y" -> :ok
        _ -> Mix.raise("Aborted.")
      end
    end

    IO.puts("")
    IO.puts("==========================================")
    IO.puts("  Unplug the USB cable now if connected.")
    IO.puts("  Press Enter when ready to start the run.")
    IO.puts("==========================================")
    IO.gets("")

    unless adb_ok?(device) do
      Mix.raise("""
      Lost connection after unplug. Is WiFi ADB active?
        adb -s SERIAL tcpip 5555
        adb connect PHONE_IP:5555
      """)
    end

    # ── Benchmark ──────────────────────────────────────────────────────────────

    IO.puts("")
    IO.puts("=== Resetting battery stats ===")
    adb!(device, ~w[shell dumpsys batterystats --reset])
    :timer.sleep(2000)

    start_mah = read_charge_counter_mah(device)
    IO.puts("Start charge: #{start_mah} mAh")

    IO.puts("")
    IO.puts("=== Launching app ===")
    adb!(device, ~w[shell am start -n #{pkg}/#{@android_activity}])
    :timer.sleep(3000)

    screen_off(device)

    IO.puts("")
    IO.puts("Running for #{div(duration, 60)} min — do not touch the phone...")
    IO.puts("")

    total_min = div(duration, 60)
    start_time = System.monotonic_time(:second)

    Enum.each(1..duration, fn i ->
      :timer.sleep(1000)

      if rem(i, 10) == 0 do
        elapsed_sec = System.monotonic_time(:second) - start_time
        current_mah = read_charge_counter_mah(device)
        drain_so_far = start_mah - current_mah
        elapsed_min = Float.round(elapsed_sec / 60, 1)
        ts = time_string()

        rate_str =
          if elapsed_sec > 30 do
            rate = Float.round(drain_so_far * 3600 / elapsed_sec, 1)
            " @ #{rate} mAh/hr"
          else
            ""
          end

        IO.puts(
          "  [#{ts}] #{elapsed_min}/#{total_min} min — #{current_mah} mAh  (−#{drain_so_far} mAh#{rate_str})"
        )
      end
    end)

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
    adb(device, ~w[uninstall #{pkg}])
    IO.puts("  Installing #{apk}...")

    case adb(device, ~w[install #{apk}]) do
      {:ok, _} -> :ok
      {:error, reason} -> Mix.raise("APK install failed: #{reason}")
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

  defp time_string do
    {{_y, _mo, _d}, {h, m, s}} = :calendar.local_time()
    :io_lib.format("~2..0B:~2..0B:~2..0B", [h, m, s]) |> IO.iodata_to_binary()
  end
end
