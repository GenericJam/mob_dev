defmodule Mix.Tasks.Mob.BatteryBenchIos do
  use Mix.Task

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

  ## Usage

      mix mob.battery_bench_ios
      mix mob.battery_bench_ios --no-beam
      mix mob.battery_bench_ios --preset nerves
      mix mob.battery_bench_ios --flags "-sbwt none -S 1:1"
      mix mob.battery_bench_ios --duration 3600 --device UDID
      mix mob.battery_bench_ios --no-build   # re-run without rebuilding

  ## Options

    * `--duration N`      — benchmark duration in seconds (default: 1800)
    * `--device UDID`     — device UDID (auto-detected if one device connected)
    * `--no-beam`         — baseline: build without starting the BEAM at all
    * `--preset NAME`     — named BEAM flag preset: `untuned`, `sbwt`, or `nerves`
    * `--flags "..."`     — arbitrary BEAM VM flags (space-separated)
    * `--no-build`        — skip Xcode build and install; benchmark current install
    * `--scheme NAME`     — Xcode scheme name (default: camelized app name)

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
    no_beam: :boolean,
    preset: :string,
    flags: :string,
    no_build: :boolean,
    scheme: :string,
    dry_run: :boolean
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

    udid =
      case opts[:device] || auto_detect_device() do
        nil ->
          Mix.raise("""
          No iOS device found. Options:
            Connect an iPhone/iPad via USB and accept "Trust This Computer"
            mix mob.battery_bench_ios --device UDID
          List connected devices with: idevice_id -l
          """)

        d ->
          d
      end

    pkg = MobDev.Config.bundle_id()
    cfg = MobDev.Config.load_mob_config()

    scheme = opts[:scheme] || cfg[:ios_scheme] || default_scheme()

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
      Mix.raise("""
      Cannot reach device #{udid}.
      Check: ideviceinfo -u #{udid} -k DeviceName
      The device must be connected via USB and trusted on this Mac.
      """)
    end

    # ── Build ──────────────────────────────────────────────────────────────────

    derived_data = Path.join(System.tmp_dir!(), "mob_bench_ios_#{System.os_time(:second)}")

    unless no_build do
      {other_cflags, header_dir} = resolve_build_flags(opts)

      IO.puts("=== Building iOS app ===")
      {workspace_kind, workspace_path} = find_workspace!()
      app_path = build_app(workspace_kind, workspace_path, scheme, other_cflags, derived_data)

      IO.puts("=== Installing on device ===")
      install_app!(udid, app_path)

      if header_dir, do: File.rm_rf!(header_dir)
    end

    # ── Pre-run checks ─────────────────────────────────────────────────────────

    max_mah = read_max_capacity_mah(udid)
    battery = read_battery_required(udid, max_mah)
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
    IO.puts("=== Launching app ===")
    pid = launch_app!(udid, pkg)
    :timer.sleep(3000)

    total_min = div(duration, 60)
    start_b = read_battery_required(udid, max_mah)
    start_val = battery_value(start_b, max_mah)
    start_time = System.monotonic_time(:second)

    IO.puts("Start:  #{format_battery(start_b, max_mah)}")

    IO.puts("=== Locking screen ===")
    lock_screen(udid)

    IO.puts("")
    IO.puts("Running for #{div(duration, 60)} min — do not touch the phone...")
    IO.puts("")
    IO.puts("")

    Enum.each(1..duration, fn i ->
      :timer.sleep(1000)

      if rem(i, 10) == 0 do
        elapsed_sec = System.monotonic_time(:second) - start_time
        elapsed_min = Float.round(elapsed_sec / 60, 1)
        ts = time_string()

        case read_battery(udid, max_mah) do
          nil ->
            IO.puts("  [#{ts}] #{elapsed_min}/#{total_min} min — device unreachable (screen locked?)")

          current_b ->
            current_val = battery_value(current_b, max_mah)
            drain = start_val - current_val

            rate_str =
              if elapsed_sec > 30 do
                rate = Float.round(drain * 3600 / elapsed_sec, 1)
                " @ #{rate} #{unit}/hr"
              else
                ""
              end

            IO.puts(
              "  [#{ts}] #{elapsed_min}/#{total_min} min — #{format_battery(current_b, max_mah)}  " <>
                "(−#{Float.round(drain * 1.0, 1)} #{unit}#{rate_str})"
            )
        end
      end
    end)

    # ── Results ────────────────────────────────────────────────────────────────

    IO.puts("")
    IO.puts("=== Collecting results ===")
    if pid, do: terminate_app(udid, pid)
    :timer.sleep(1000)

    IO.puts("  Unlock the phone to read final battery level...")
    end_b = read_battery_required(udid, max_mah, 1, 60)
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

    File.rm_rf!(derived_data)
  end

  # ── Prerequisites ─────────────────────────────────────────────────────────────

  defp check_prerequisites! do
    unless System.find_executable("ideviceinfo") do
      Mix.raise("""
      ideviceinfo not found. Install libimobiledevice:

          brew install libimobiledevice

      This is required to read battery levels from the device.
      """)
    end

    unless System.find_executable("xcrun") do
      Mix.raise("xcrun not found. Install Xcode command-line tools: xcode-select --install")
    end
  end

  # ── Dry run ───────────────────────────────────────────────────────────────────

  defp dry_run!(opts) do
    cfg = MobDev.Config.load_mob_config()
    pkg = MobDev.Config.bundle_id()
    scheme = opts[:scheme] || cfg[:ios_scheme] || default_scheme()
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

    # Prefer .xcworkspace (CocoaPods/SPM), fall back to .xcodeproj
    workspaces = Path.wildcard(Path.join(ios_dir, "*.xcworkspace"))
    projects = Path.wildcard(Path.join(ios_dir, "*.xcodeproj"))

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
           ], stderr_to_stdout: true) do
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
           ], stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {out, _} ->
        # Non-fatal — app may have already exited
        IO.puts("  terminate warning: #{String.trim(out)}")
    end
  end

  # ── Screen lock ──────────────────────────────────────────────────────────────

  defp lock_screen(udid) do
    case System.cmd("idevicediagnostics", ["-u", udid, "sleep"], stderr_to_stdout: true) do
      {_, 0} ->
        IO.puts("  Screen locked.")
        :timer.sleep(1000)

      _ ->
        IO.puts("""
          Could not lock screen automatically (idevicediagnostics sleep).
          Please lock the phone manually now, then press Enter.
        """)

        IO.gets("")
    end
  end

  # ── Battery readings ─────────────────────────────────────────────────────────

  # Returns the max design capacity in mAh, or nil if unavailable.
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

  # Returns %{pct: integer, mah: integer | nil} or nil if device unreachable.
  defp read_battery(udid, max_mah) do
    case read_battery_pct(udid) do
      nil ->
        nil

      pct ->
        mah = if max_mah, do: round(max_mah * pct / 100), else: nil
        %{pct: pct, mah: mah}
    end
  end

  # Returns integer % or nil if the device is unreachable (e.g. screen locked,
  # iOS USB restriction active). Callers that need a definite value should use
  # read_battery_required/2 which retries before raising.
  defp read_battery_pct(udid) do
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

  # Like read_battery but retries up to max_attempts times (2s apart) before raising.
  # Used for the mandatory start/end readings.
  defp read_battery_required(udid, max_mah), do: read_battery_required(udid, max_mah, 1, 5)
  defp read_battery_required(udid, max_mah, attempt, max_attempts) do
    case read_battery_pct(udid) do
      nil when attempt < max_attempts ->
        :timer.sleep(2000)
        read_battery_required(udid, max_mah, attempt + 1, max_attempts)

      nil ->
        Mix.raise(
          "Could not read battery from device #{udid} after #{attempt} attempts. " <>
            "Check device is unlocked and trusted (Settings → Privacy & Security → USB Accessories)."
        )

      pct ->
        mah = if max_mah, do: round(max_mah * pct / 100), else: nil
        %{pct: pct, mah: mah}
    end
  end

  defp ideviceinfo(udid, key) do
    case System.cmd("ideviceinfo", ["-u", udid, "-q", @battery_domain, "-k", key],
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        val = String.trim(out)
        if val == "", do: {:error, "empty"}, else: {:ok, val}

      {out, _} ->
        {:error, String.trim(out)}
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

  defp auto_detect_device do
    case System.cmd("idevice_id", ["-l"], stderr_to_stdout: true) do
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

  defp device_ok?(udid) do
    case System.cmd("ideviceinfo", ["-u", udid, "-k", "DeviceName"], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  # ── Misc ─────────────────────────────────────────────────────────────────────

  defp default_scheme, do: app_name() |> Macro.camelize()
  defp app_name, do: Mix.Project.config()[:app] |> to_string()

  defp time_string do
    {{_y, _mo, _d}, {h, m, s}} = :calendar.local_time()
    :io_lib.format("~2..0B:~2..0B:~2..0B", [h, m, s]) |> IO.iodata_to_binary()
  end
end
