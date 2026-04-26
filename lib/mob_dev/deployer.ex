defmodule MobDev.Deployer do
  @moduledoc """
  Pushes compiled BEAM files from `_build/dev/lib/*/ebin/` to connected devices.

  Does NOT rebuild APKs or recompile native code — that's `deploy.sh` (first-time setup).
  Use this for day-to-day code iteration: edit Elixir → `mix mob.deploy` → code running.

  ## Transport selection

  **Erlang dist (preferred)**: when a device node is already reachable via Erlang
  distribution, BEAMs are hot-loaded via RPC. No restart needed — modules are
  loaded in place exactly like `nl/1` in IEx.

  **adb push / cp (fallback)**: when no dist connection exists (first deploy, app not
  running), falls back to the traditional push-then-restart path.

  ## Platform behaviour

  **Android**: pushes via `adb push` (requires `adb root`, i.e. emulator or debug build),
  or falls back to `adb push` → `/data/local/tmp/` → `run-as tar xf` for real devices.

  **iOS simulator**: copies files locally into `/tmp/otp-ios-sim/beamhello/` (no network
  hop — the simulator shares the Mac filesystem).
  """

  alias MobDev.Discovery.{Android, IOS}
  alias MobDev.{Device, HotPush, Tunnel}

  @cookie :mob_secret

  @android_activity ".MainActivity"

  defp app_name, do: Mix.Project.config()[:app] |> to_string()
  defp bundle_id, do: MobDev.Config.bundle_id()
  defp android_package, do: bundle_id()
  defp android_app_data, do: "/data/data/#{android_package()}/files"
  defp android_beams_dir, do: "#{android_app_data()}/otp/#{app_name()}"
  defp ios_bundle_id, do: bundle_id()

  defp ios_beams_dir do
    # mob_beam.m hardcodes /tmp/otp-ios-sim as OTP_ROOT.
    # If that directory exists (manually set up or from a prior native deploy),
    # deploy beams there so the running BEAM picks them up immediately.
    # Fall back to the cache dir otherwise (e.g. fresh machine before first --native).
    tmp_path = Path.join("/tmp/otp-ios-sim", app_name())
    cache_path = Path.join(MobDev.OtpDownloader.ios_sim_otp_dir(), app_name())
    if File.dir?("/tmp/otp-ios-sim"), do: tmp_path, else: cache_path
  end

  @doc """
  Discovers devices, pushes BEAMs, and optionally restarts apps.
  Returns `{deployed, failed}` lists of `%Device{}`.
  """
  @spec deploy_all(keyword()) :: {[Device.t()], [Device.t()]}
  def deploy_all(opts \\ []) do
    restart = Keyword.get(opts, :restart, true)
    platforms = Keyword.get(opts, :platforms, [:android, :ios])
    force_fs = Keyword.get(opts, :force_fs, false)
    device_id = Keyword.get(opts, :device, nil)
    ios_device_id = Keyword.get(opts, :ios_device, nil)
    beam_flags = Keyword.get(opts, :beam_flags, nil)
    beam_dirs = collect_beam_dirs()

    android =
      if :android in platforms,
        do:
          Android.list_devices()
          |> Enum.reject(&(&1.status == :unauthorized))
          |> filter_by_device_id(device_id),
        else: []

    ios =
      if :ios in platforms,
        do: IOS.list_devices() |> filter_by_device_id(ios_device_id || device_id),
        else: []

    all = android ++ ios

    if all == [] do
      IO.puts("  #{color(:yellow)}No devices found.#{color(:reset)}")
      {[], []}
    else
      IO.puts("  Pushing #{count_beams(beam_dirs)} BEAM file(s) to #{length(all)} device(s)...")

      # Try Erlang dist first — hot-loads modules with no restart. We set up
      # tunnels and attempt Node.connect for each device; those that respond
      # get BEAMs via RPC, the rest fall back to adb/cp + restart.
      # force_fs: true skips dist and always writes to the filesystem — required
      # after a native build/install where the old BEAM process is dead.
      dist_nodes = if force_fs, do: [], else: connect_dist(all)

      results =
        all
        |> Enum.with_index()
        |> Enum.map(fn {device, idx} ->
          IO.write("  #{device.name || device.serial}  →  pushing...")
          dist_port = Tunnel.dist_port(idx)
          node = Device.node_name(device)

          {method, result} =
            if node in dist_nodes do
              {:dist, push_via_dist(node, device)}
            else
              fallback =
                case device.platform do
                  :android ->
                    deploy_android(device, beam_dirs,
                      restart: restart,
                      dist_port: dist_port,
                      beam_flags: beam_flags
                    )

                  :ios ->
                    deploy_ios(device, beam_dirs,
                      restart: restart,
                      dist_port: dist_port,
                      beam_flags: beam_flags
                    )
                end

              {:adb, fallback}
            end

          case result do
            {:ok, d} ->
              suffix = if method == :dist, do: " (dist, no restart)", else: ""
              IO.puts(" #{color(:green)}✓#{suffix}#{color(:reset)}")
              {:ok, d}

            {:error, reason} ->
              IO.puts(" #{color(:red)}✗#{color(:reset)}")
              IO.puts("    #{color(:red)}#{reason}#{color(:reset)}")
              {:error, %{device | status: :error, error: reason}}
          end
        end)

      deployed = for {:ok, d} <- results, do: d
      failed = for {:error, d} <- results, do: d
      {deployed, failed}
    end
  end

  # ── Device filtering ─────────────────────────────────────────────────────────

  defp filter_by_device_id(devices, nil), do: devices

  defp filter_by_device_id(devices, id) do
    case Enum.filter(devices, &Device.match_id?(&1, id)) do
      [] ->
        IO.puts("  #{color(:red)}No device matched \"#{id}\".#{color(:reset)}")

        IO.puts(
          "  Run #{color(:cyan)}mix mob.devices#{color(:reset)} to see available device IDs."
        )

        []

      matched ->
        matched
    end
  end

  # ── Android ─────────────────────────────────────────────────────────────────

  defp deploy_android(%Device{serial: serial} = device, beam_dirs, opts) do
    restart = Keyword.get(opts, :restart, true)
    dist_port = Keyword.get(opts, :dist_port, 9100)
    beam_flags = Keyword.get(opts, :beam_flags, nil)
    pkg = android_package()

    {pm_out, _} =
      System.cmd("adb", ["-s", serial, "shell", "pm", "list", "packages", pkg],
        stderr_to_stdout: true
      )

    if not String.contains?(pm_out, "package:#{pkg}") do
      {:error,
       "#{pkg} is not installed on #{device.name || serial} — skipping (ABI mismatch or missing install)"}
    else
      case push_beams_android(serial, beam_dirs) do
        :ok ->
          sync_elixir_stdlib_android(serial)
          write_beam_flags_android(serial, beam_flags)
          setup_exqlite_android(serial)
          setup_app_priv_android(serial)
          if restart, do: restart_android(serial, dist_port: dist_port)
          {:ok, device}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # If the Elixir stdlib on the device was installed by a different Elixir version
  # than the host (e.g. after `asdf` upgrade), regex literals and other stdlib
  # internals will be incompatible. Detect the mismatch and push updated BEAMs.
  defp sync_elixir_stdlib_android(serial) do
    host_vsn = System.version()
    pkg = android_package()
    app_data = android_app_data()
    elixir_app = "#{app_data}/otp/lib/elixir/ebin/elixir.app"

    device_vsn =
      case run_adb(["-s", serial, "shell", "run-as #{pkg} cat #{elixir_app}"]) do
        {:ok, content} ->
          case Regex.run(~r/\{vsn,"([^"]+)"\}/, content) do
            [_, v] -> v
            _ -> nil
          end

        _ ->
          nil
      end

    if device_vsn != host_vsn do
      Mix.shell().info([
        :yellow,
        "* Elixir version mismatch (device: #{device_vsn || "unknown"}, host: #{host_vsn}) — syncing stdlib...",
        :reset
      ])

      elixir_lib = :code.lib_dir(:elixir) |> to_string() |> Path.dirname()

      Enum.each([:elixir, :logger, :eex], fn app ->
        src = Path.join(elixir_lib, "#{app}/ebin")
        dst = "#{app_data}/otp/lib/#{app}/ebin"

        if File.dir?(src) do
          run_adb(["-s", serial, "shell", "run-as #{pkg} mkdir -p #{dst}"])
          run_adb(["-s", serial, "push", "#{src}/.", "#{dst}/"])
        end
      end)

      Mix.shell().info([:green, "* Elixir stdlib synced to #{host_vsn}", :reset])
    end
  end

  defp write_beam_flags_android(_serial, nil), do: :ok

  defp write_beam_flags_android(serial, flags) do
    beams_dir = android_beams_dir()
    tmp = Path.join(System.tmp_dir!(), "mob_beam_flags_#{serial}")
    File.write!(tmp, flags)

    case System.cmd(
           "adb",
           ["-s", serial, "shell", "run-as", android_package(), "test", "-d", beams_dir],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        System.cmd("adb", ["-s", serial, "push", tmp, "#{beams_dir}/mob_beam_flags"],
          stderr_to_stdout: true
        )

      _ ->
        :ok
    end

    File.rm(tmp)
    :ok
  end

  # Ensure exqlite lives in $OTP_ROOT/lib/exqlite-VERSION/{ebin,priv} so that
  # the OTP boot-time lib scan registers a correct lib_dir for the application.
  # Without this, code:lib_dir(:exqlite) returns {:error, :bad_name} and exqlite's
  # NIF on_load callback (which calls :code.priv_dir(:exqlite)) fails.
  # mob_beam.c creates the sqlite3_nif.so symlink in priv/ at runtime (it knows
  # the APK-hash-dependent nativeLibraryDir; we don't at deploy time).
  defp setup_exqlite_android(serial) do
    with vsn when is_binary(vsn) <- exqlite_version(),
         exqlite_ebin when exqlite_ebin != nil <-
           Path.wildcard("_build/dev/lib/exqlite/ebin") |> List.first() do
      app_data = android_app_data()
      exqlite_lib = "#{app_data}/otp/lib/exqlite-#{vsn}"

      rooted? =
        case run_adb(["-s", serial, "root"]) do
          {:ok, out} -> out =~ "restarting" or out =~ "already running as root"
          _ -> false
        end

      if rooted? do
        pkg = android_package()
        :timer.sleep(600)
        run_adb(["-s", serial, "shell", "mkdir -p #{exqlite_lib}/ebin #{exqlite_lib}/priv"])
        run_adb(["-s", serial, "push", "#{Path.expand(exqlite_ebin)}/.", "#{exqlite_lib}/ebin/"])
        # Read label from cache/ (has full s0:cXXX,cYYY MCS categories on Android 15),
        # not files/ which carries a bare s0 label.
        run_adb([
          "-s",
          serial,
          "shell",
          "chcon -hR $(stat -c %C /data/data/#{pkg}/cache) #{app_data}/otp/lib/exqlite-#{vsn}"
        ])

        create_exqlite_nif_symlink(serial, exqlite_lib, :rooted)
      else
        push_exqlite_runas(serial, exqlite_ebin, exqlite_lib)
      end
    else
      # exqlite not present or version unknown — skip silently
      _ -> :ok
    end
  end

  # Push the app's priv/ directory to {beams_dir}/priv/ on the device so that
  # migration .exs files are available at runtime.
  #
  # WHY THIS IS NECESSARY
  #
  # Ecto.Migrator locates migration files via :code.priv_dir(app), which looks
  # up the app's OTP lib directory ($OTP_ROOT/lib/APP-VERSION/ebin/). Mob apps
  # are deployed as flat .beam files in a -pa directory — there is no versioned
  # lib structure — so :code.priv_dir/1 returns {error, bad_name}. When that
  # happens Ecto.Migrator.run silently finds zero migrations and logs "Migrations
  # already up" without creating any tables.
  #
  # The fix has two parts:
  #   1. This function pushes priv/ to {beams_dir}/priv/ on the device.
  #   2. mob_beam.c sets MOB_BEAMS_DIR=beams_dir before erl_start so app code
  #      can call Ecto.Migrator.run(repo, beams_dir <> "/priv/repo/migrations", ...)
  #      with an explicit path instead of relying on :code.priv_dir/1.
  #
  # PERMISSION TRAP: chmod -R 755 is not optional.
  #
  # `mkdir -p` executed via `adb root` shell creates directories owned by
  # system:system with mode drwxrwx--x (owner=rwx, group=rwx, other=--x).
  # The BEAM process runs as the app user (u0_a0), which is "other" relative to
  # system:system, so it gets only --x (traverse, no read). Path.wildcard calls
  # opendir(3) on the directory, which requires read permission (r bit). Without
  # it, wildcard returns [] even though the .exs file is right there — and Ecto
  # again logs "Migrations already up". chmod -R 755 gives world-readable
  # directories (r-x for other) while keeping files at their pushed permissions.
  defp setup_app_priv_android(serial) do
    local_priv = Path.join(File.cwd!(), "priv")

    if File.dir?(local_priv) do
      device_priv = "#{android_beams_dir()}/priv"

      rooted? =
        case run_adb(["-s", serial, "root"]) do
          {:ok, out} -> out =~ "restarting" or out =~ "already running as root"
          _ -> false
        end

      if rooted? do
        :timer.sleep(600)
        run_adb(["-s", serial, "shell", "mkdir -p #{device_priv}"])
        run_adb(["-s", serial, "push", "#{Path.expand(local_priv)}/.", "#{device_priv}/"])
        # Make directories world-readable. mkdir as root creates them system:system
        # drwxrwx--x; the app process (other) gets only --x → Path.wildcard returns
        # [] → migrations silently skipped. See comment above for the full story.
        run_adb(["-s", serial, "shell", "chmod -R 755 #{device_priv}"])
        # Fix SELinux MCS categories so the app can actually open the files.
        # Read label from cache/ (full s0:cXXX,cYYY) not files/ (bare s0 on Android 15).
        run_adb([
          "-s",
          serial,
          "shell",
          "chcon -hR $(stat -c %C /data/data/#{android_package()}/cache) #{android_beams_dir()}"
        ])
      else
        push_priv_android_runas(serial, local_priv, device_priv)
      end
    end

    :ok
  end

  # Non-rooted path: stage priv/ into a tar on /data/local/tmp (world-writable),
  # then extract into the app sandbox via `run-as`. Files created by run-as are
  # owned by the app user (u0_a0) so no chmod is needed — the app can read its
  # own files without any extra permission fixup.
  defp push_priv_android_runas(serial, local_priv, device_priv) do
    stage_local = Path.join(System.tmp_dir!(), "mob_priv_#{serial}.tar")
    stage_device = "/data/local/tmp/mob_priv.tar"

    try do
      # Tar with priv/ as the top-level entry; extract relative to beams_dir so
      # the result lands at {beams_dir}/priv/repo/migrations/... etc.
      case System.cmd(
             "tar",
             ["cf", stage_local, "-C", Path.dirname(local_priv), Path.basename(local_priv)],
             env: [{"COPYFILE_DISABLE", "1"}],
             stderr_to_stdout: true
           ) do
        {_, 0} -> :ok
        {out, _} -> throw({:error, "tar create failed: #{out}"})
      end

      case run_adb(["-s", serial, "push", stage_local, stage_device]) do
        {:ok, _} -> :ok
        {:error, r} -> throw({:error, "adb push failed: #{r}"})
      end

      run_adb(["-s", serial, "shell", "run-as #{android_package()} mkdir -p #{device_priv}"])

      cmd =
        "run-as #{android_package()} tar xf #{stage_device} -C #{android_beams_dir()} 2>/dev/null; true"

      case run_adb(["-s", serial, "shell", cmd]) do
        {:ok, _} -> :ok
        {:error, r} -> throw({:error, "run-as tar failed: #{r}"})
      end

      run_adb(["-s", serial, "shell", "rm -f #{stage_device}"])
    catch
      {:error, reason} ->
        IO.puts("    (warning: priv push failed: #{reason})")
    after
      File.rm(stage_local)
    end
  end

  defp push_exqlite_runas(serial, exqlite_ebin, exqlite_lib) do
    stage_local = Path.join(System.tmp_dir!(), "mob_exqlite_#{serial}.tar")
    stage_device = "/data/local/tmp/mob_exqlite.tar"
    tmp = Path.join(System.tmp_dir!(), "mob_exqlite_stage_#{serial}")

    try do
      File.rm_rf!(tmp)
      File.mkdir_p!(Path.join(tmp, "ebin"))
      File.mkdir_p!(Path.join(tmp, "priv"))

      System.cmd("cp", ["-r", "#{exqlite_ebin}/.", Path.join(tmp, "ebin")],
        stderr_to_stdout: true
      )

      # Tar with ebin/ and priv/ as top-level entries; extract to exqlite_lib/.
      case System.cmd("tar", ["cf", stage_local, "-C", tmp, "."],
             env: [{"COPYFILE_DISABLE", "1"}],
             stderr_to_stdout: true
           ) do
        {_, 0} -> :ok
        {out, _} -> throw({:error, "tar create failed: #{out}"})
      end

      case run_adb(["-s", serial, "push", stage_local, stage_device]) do
        {:ok, _} -> :ok
        {:error, r} -> throw({:error, "adb push failed: #{r}"})
      end

      cmd =
        "run-as #{android_package()} mkdir -p #{exqlite_lib}/ebin #{exqlite_lib}/priv && " <>
          "run-as #{android_package()} tar xf #{stage_device} -C #{exqlite_lib}/ 2>/dev/null; true"

      case run_adb(["-s", serial, "shell", cmd]) do
        {:ok, _} -> :ok
        {:error, r} -> throw({:error, "run-as tar failed: #{r}"})
      end

      run_adb(["-s", serial, "shell", "rm -f #{stage_device}"])
      create_exqlite_nif_symlink(serial, exqlite_lib, :runas)
      :ok
    catch
      {:error, reason} ->
        IO.puts("    (warning: exqlite lib setup failed: #{reason})")
        :ok
    after
      File.rm(stage_local)
      File.rm_rf(tmp)
    end
  end

  # Create sqlite3_nif.so symlink in the exqlite priv dir pointing at the APK's
  # native lib. Uses `pm path` to locate the APK (its parent dir contains lib/arm64/).
  # On non-rooted devices we use `run-as` since the priv dir is in the app sandbox.
  defp create_exqlite_nif_symlink(serial, exqlite_lib, mode) do
    case run_adb(["-s", serial, "shell", "pm path #{android_package()}"]) do
      {:ok, path_out} ->
        # path_out looks like: "package:/data/app/~~hash==/com.pkg-hash==/base.apk"
        apk_path = path_out |> String.trim() |> String.replace_prefix("package:", "")
        native_lib_dir = apk_path |> Path.dirname() |> Path.join("lib/arm64")
        nif_target = "#{native_lib_dir}/libsqlite3_nif.so"
        nif_link = "#{exqlite_lib}/priv/sqlite3_nif.so"

        cmd =
          case mode do
            :runas -> "run-as #{android_package()} ln -sf #{nif_target} #{nif_link}"
            :rooted -> "ln -sf #{nif_target} #{nif_link}"
          end

        case run_adb(["-s", serial, "shell", cmd]) do
          {:ok, _} -> :ok
          {:error, e} -> IO.puts("    (warning: exqlite NIF symlink failed: #{e})")
        end

      _ ->
        IO.puts("    (warning: pm path failed — exqlite NIF symlink skipped)")
    end
  end

  defp exqlite_version do
    # Try mix.lock first (most reliable)
    with {:ok, lock} <- File.read("mix.lock"),
         [_, vsn] <- Regex.run(~r/"exqlite"[^"]*"(\d+\.\d+\.\d+)"/, lock) do
      vsn
    else
      _ ->
        # Fall back to .app file
        case Path.wildcard("_build/dev/lib/exqlite/ebin/exqlite.app") do
          [app_file | _] ->
            case File.read(app_file) do
              {:ok, content} ->
                case Regex.run(~r/\{vsn,"([^"]+)"\}/, content) do
                  [_, vsn] -> vsn
                  _ -> nil
                end

              _ ->
                nil
            end

          [] ->
            nil
        end
    end
  end

  defp push_beams_android(serial, beam_dirs) do
    # Try adb root first (works on emulators and eng builds).
    # Check the output text — non-rooted devices return exit 0 with
    # "cannot run as root in production builds".
    rooted? =
      case run_adb(["-s", serial, "root"]) do
        {:ok, out} -> out =~ "restarting" or out =~ "already running as root"
        _ -> false
      end

    if rooted? do
      :timer.sleep(600)
      run_adb(["-s", serial, "shell", "mkdir -p #{android_beams_dir()}"])

      result =
        Enum.reduce_while(beam_dirs, :ok, fn dir, _ ->
          case run_adb(["-s", serial, "push", "#{Path.expand(dir)}/.", "#{android_beams_dir()}/"]) do
            {:ok, _} -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, "push failed: #{reason}"}}
          end
        end)

      # Fix SELinux MCS categories on pushed files. adb push (as root) labels
      # files with root's categories; restorecon only fixes the type, not MCS.
      # Read label from cache/ (full s0:cXXX,cYYY) not files/ (bare s0 on Android 15).
      run_adb([
        "-s",
        serial,
        "shell",
        "chcon -hR $(stat -c %C /data/data/#{android_package()}/cache) #{android_app_data()}/otp"
      ])

      result
    else
      # Fall back to run-as tar (non-rooted physical devices).
      push_beams_android_runas(serial, beam_dirs)
    end
  end

  defp push_beams_android_runas(serial, beam_dirs) do
    stage_local = System.tmp_dir!() |> Path.join("mob_beams_#{serial}.tar")
    stage_device = "/data/local/tmp/mob_beams.tar"

    try do
      tmp = Path.join(System.tmp_dir!(), "mob_beam_stage_#{serial}")
      File.rm_rf!(tmp)
      File.mkdir_p!(tmp)

      Enum.each(beam_dirs, fn dir ->
        System.cmd("cp", ["-r", "#{dir}/.", tmp], stderr_to_stdout: true)
      end)

      # Archive from inside tmp so there is no top-level wrapper directory.
      # BusyBox/Toybox tar (Android ≤11) does not support --strip-components, so
      # we avoid needing it by using `tar cf ... -C tmp .`.
      # COPYFILE_DISABLE=1 prevents macOS from adding ._<file> AppleDouble
      # sidecars into the archive.
      case System.cmd("tar", ["cf", stage_local, "-C", tmp, "."],
             env: [{"COPYFILE_DISABLE", "1"}],
             stderr_to_stdout: true
           ) do
        {_, 0} -> :ok
        {out, _} -> throw({:error, "tar create failed: #{out}"})
      end

      case run_adb(["-s", serial, "push", stage_local, stage_device]) do
        {:ok, _} -> :ok
        {:error, r} -> throw({:error, "adb push failed: #{r}"})
      end

      run_adb([
        "-s",
        serial,
        "shell",
        "run-as #{android_package()} mkdir -p #{android_beams_dir()}"
      ])

      # Redirect stderr and always exit 0: Android's Toybox tar cannot chown to
      # macOS UID 501 and exits 1, but the files are extracted correctly.
      cmd =
        "run-as #{android_package()} tar xf #{stage_device} -C #{android_beams_dir()}/ 2>/dev/null; true"

      case run_adb(["-s", serial, "shell", cmd]) do
        {:ok, _} -> :ok
        {:error, r} -> throw({:error, "run-as tar failed: #{r}"})
      end

      run_adb(["-s", serial, "shell", "rm -f #{stage_device}"])
      :ok
    catch
      {:error, reason} -> {:error, reason}
    after
      File.rm(stage_local)
    end
  end

  defp restart_android(serial, opts) do
    dist_port = Keyword.get(opts, :dist_port, 9100)
    run_adb(["-s", serial, "shell", "am", "force-stop", android_package()])
    # Heal SELinux MCS category mismatch before start — APK reinstall changes
    # the app's category but leaves OTP files with stale labels.
    # Read label from cache/ (full s0:cXXX,cYYY) not files/ (bare s0 on Android 15).
    run_adb([
      "-s",
      serial,
      "shell",
      "chcon -hR $(stat -c %C /data/data/#{android_package()}/cache) #{android_app_data()}/otp"
    ])

    :timer.sleep(300)

    run_adb([
      "-s",
      serial,
      "shell",
      "am",
      "start",
      "-n",
      "#{android_package()}/#{@android_activity}",
      "--ei",
      "mob_dist_port",
      to_string(dist_port)
    ])

    :ok
  end

  # ── iOS ─────────────────────────────────────────────────────────────────────

  defp deploy_ios(%Device{type: :physical} = device, beam_dirs, opts) do
    deploy_ios_physical(device, beam_dirs, opts)
  end

  defp deploy_ios(device, beam_dirs, opts) do
    deploy_ios_simulator(device, beam_dirs, opts)
  end

  defp deploy_ios_simulator(%Device{serial: udid} = device, beam_dirs, opts) do
    restart = Keyword.get(opts, :restart, true)
    dist_port = Keyword.get(opts, :dist_port, 9100)
    beam_flags = Keyword.get(opts, :beam_flags, nil)

    try do
      File.mkdir_p!(ios_beams_dir())

      Enum.each(beam_dirs, fn dir ->
        abs_dir = Path.expand(dir)

        case System.cmd("cp", ["-r", "#{abs_dir}/.", ios_beams_dir()], stderr_to_stdout: true) do
          {_, 0} -> :ok
          {out, _} -> throw({:error, "cp failed: #{out}"})
        end
      end)

      # Push priv/ alongside the BEAMs so migrations and other priv assets are
      # available at runtime. On iOS, beams_dir = /tmp/otp-ios-sim/APP_NAME and
      # MOB_DATA_DIR = the app's Documents directory — these are two different
      # paths, so we can't derive beams_dir from MOB_DATA_DIR. mob_beam.m sets
      # MOB_BEAMS_DIR=beams_dir explicitly so app code always knows where to look.
      # No chmod is needed: cp on macOS preserves source permissions and the
      # simulator shares the Mac filesystem (no SELinux, no ownership mismatch).
      local_priv = Path.join(File.cwd!(), "priv")

      if File.dir?(local_priv) do
        priv_dest = Path.join(ios_beams_dir(), "priv")
        File.mkdir_p!(priv_dest)

        case System.cmd("cp", ["-r", "#{Path.expand(local_priv)}/.", priv_dest],
               stderr_to_stdout: true
             ) do
          {_, 0} -> :ok
          {out, _} -> IO.puts("    (warning: iOS priv push failed: #{out})")
        end
      end

      if beam_flags do
        File.write!(Path.join(ios_beams_dir(), "mob_beam_flags"), beam_flags)
      end

      if restart do
        IOS.terminate_app(udid, ios_bundle_id())
        :timer.sleep(300)
        IOS.launch_app(udid, ios_bundle_id(), dist_port: dist_port)
      end

      {:ok, device}
    catch
      {:error, reason} -> {:error, reason}
    end
  end

  # Physical iOS deploy: push BEAMs into the app's Documents container via
  # `xcrun devicectl`. mob_beam.m (MOB_BUNDLE_OTP build) checks
  # Documents/otp/<app>/ at startup and prefers it over the read-only in-bundle
  # copy, enabling fast deploys without a full Xcode rebuild.
  #
  # The merged staging dir is named <app> so that devicectl's directory-copy
  # semantics land the files at Documents/otp/<app>/ on device.
  defp deploy_ios_physical(%Device{serial: udid} = device, beam_dirs, opts) do
    restart = Keyword.get(opts, :restart, true)
    beam_flags = Keyword.get(opts, :beam_flags, nil)
    bundle = ios_bundle_id()
    app = app_name()

    # Stage all BEAMs (and priv/) into a temp dir named <app>.
    staging_parent =
      Path.join(System.tmp_dir!(), "mob_ios_deploy_#{:erlang.unique_integer([:positive])}")

    staging_dir = Path.join(staging_parent, app)
    File.mkdir_p!(staging_dir)

    try do
      Enum.each(beam_dirs, fn dir ->
        case System.cmd("cp", ["-r", "#{Path.expand(dir)}/.", staging_dir],
               stderr_to_stdout: true
             ) do
          {_, 0} -> :ok
          {out, _} -> throw({:error, "cp failed: #{out}"})
        end
      end)

      local_priv = Path.join(File.cwd!(), "priv")

      if File.dir?(local_priv) do
        priv_dest = Path.join(staging_dir, "priv")
        File.mkdir_p!(priv_dest)

        case System.cmd("cp", ["-r", "#{Path.expand(local_priv)}/.", priv_dest],
               stderr_to_stdout: true
             ) do
          {_, 0} -> :ok
          {out, _} -> IO.puts("    (warning: priv copy failed: #{out})")
        end
      end

      if beam_flags do
        File.write!(Path.join(staging_dir, "mob_beam_flags"), beam_flags)
      end

      # devicectl copies the contents of --source into --destination.
      # To land BEAMs at Documents/otp/<app>/, the destination must include
      # the app subdirectory explicitly (staging_dir naming alone is not enough).
      case System.cmd(
             "xcrun",
             [
               "devicectl",
               "device",
               "copy",
               "to",
               "--device",
               udid,
               "--domain-type",
               "appDataContainer",
               "--domain-identifier",
               bundle,
               "--source",
               staging_dir,
               "--destination",
               "Documents/otp/#{app}"
             ],
             stderr_to_stdout: true
           ) do
        {_, 0} ->
          :ok

        {out, _} ->
          reason =
            if String.contains?(out, "ContainerLookupErrorDomain") do
              """
              App '#{bundle}' is not installed on this device.

              To fix this, you need to build and install the app on the device first.
              The easiest way is to open the ios/ directory in Xcode and run on device:

                  open ios/*.xcodeproj    (or ios/*.xcworkspace)

              Then select your device in Xcode and press Run (⌘R).

              Alternatively, if you have another app with a different bundle ID already
              installed on the device, update bundle_id in mob.exs to match it:

                  config :mob_dev, bundle_id: "com.yourcompany.yourapp"
              """
            else
              "devicectl copy failed: #{out}"
            end

          throw({:error, reason})
      end

      if restart, do: IOS.restart_app_physical(udid, bundle)

      {:ok, device}
    catch
      {:error, reason} -> {:error, reason}
    after
      File.rm_rf!(staging_parent)
    end
  end

  # ── Dist push ────────────────────────────────────────────────────────────────

  # Try to connect via Erlang dist to each discovered device. Returns a list of
  # connected node atoms. Devices that don't respond are left for the adb fallback.
  defp connect_dist(devices) do
    ensure_local_dist()

    Enum.flat_map(devices, fn device ->
      node = Device.node_name(device)
      Node.set_cookie(node, @cookie)
      if Node.connect(node), do: [node], else: []
    end)
  rescue
    _ -> []
  end

  defp ensure_local_dist do
    unless Node.alive?() do
      Node.start(:"mob_dev@127.0.0.1", :longnames)
      Node.set_cookie(@cookie)
    end
  end

  # Push all compiled BEAMs to a single dist-connected node, then trigger
  # a re-render of the currently displayed screen so the user sees the changes
  # immediately without a full restart.
  #
  # WHY THE RE-RENDER MESSAGE IS NECESSARY
  #
  # Erlang hot code loading (`code:load_binary`) replaces the module in the
  # code server but does NOT cause running processes to re-execute. A
  # Mob.Screen GenServer that is already mounted and displaying will continue
  # to sit in its receive loop waiting for the next message. Until something
  # sends it a message, `render/1` never runs again — so the user sees the
  # old UI even though the new code is live in memory.
  #
  # The fix: immediately after the push, RPC-send `:__mob_hot_reload__` to the
  # `:mob_screen` registered process on the device. Mob.Screen's handle_info
  # catch-all receives it, delegates to the user module's handle_info (which
  # ignores unknown messages), then calls do_render/2 using the now-current
  # version of the screen module. The screen repaints with the new code, with
  # no restart and no loss of GenServer state.
  #
  # This is why `mix mob.deploy` appeared to do nothing before this fix — the
  # code WAS pushed correctly, the screen just had no trigger to repaint.
  defp push_via_dist(node, device) do
    {_pushed, failed} = HotPush.push_all([node])

    if failed == [] do
      # Best-effort: ignored if no screen is currently registered (nav edge
      # cases, app in background, etc.).
      :rpc.call(node, :erlang, :send, [:mob_screen, :__mob_hot_reload__])
      {:ok, device}
    else
      mods = Enum.map_join(failed, ", ", fn {mod, _} -> inspect(mod) end)
      {:error, "dist push failed for: #{mods}"}
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp collect_beam_dirs do
    # Use the same runtime-dep filter as HotPush so we don't push dev-only
    # tooling (mob_dev, credo, etc.) to the device filesystem.
    app_dirs = HotPush.runtime_beam_dirs()

    # EEx is part of the Elixir stdlib but not in _build/dev/lib/. Ecto depends
    # on it, so include it in every push so it lands in the flat beams_dir
    # (which is already on the -pa code path on both Android and iOS).
    eex_ebin = Path.join(to_string(:code.lib_dir(:eex)), "ebin")
    stdlib_dirs = if File.dir?(eex_ebin), do: [eex_ebin], else: []

    # ssl is a required OTP app (thousand_island lists it as a dependency) but the
    # iOS and Android OTP builds omit it. ssl is pure Erlang (no NIFs), so host
    # BEAM files run identically on both targets. For HTTP-only Phoenix at loopback,
    # ssl starts but no TLS sockets are opened.
    ssl_ebin = Path.join(to_string(:code.lib_dir(:ssl)), "ebin")
    ssl_dirs = if File.dir?(ssl_ebin), do: [ssl_ebin], else: []

    # crypto is a required OTP app (listed in Ecto's .app) but the iOS and
    # Android OTP builds omit it (no OpenSSL). Compile a minimal shim so
    # ensure_all_started can start it. BEAM bytecode is platform-independent
    # so erlc on the Mac produces a .beam that runs on both targets.
    shim_dirs =
      case generate_crypto_shim() do
        {:ok, dir} -> [dir]
        _ -> []
      end

    app_dirs ++ stdlib_dirs ++ ssl_dirs ++ shim_dirs
  end

  # Generates crypto.beam + crypto.app in a temp dir and returns {:ok, dir}.
  # Returns {:error, reason} if erlc is not available.
  @doc false
  @spec generate_crypto_shim() :: {:ok, String.t()} | {:error, term()}
  def generate_crypto_shim do
    dir = Path.join(System.tmp_dir!(), "mob_crypto_shim")
    File.mkdir_p!(dir)

    src = Path.join(dir, "crypto.erl")

    File.write!(src, """
    -module(crypto).
    -export([strong_rand_bytes/1, hash/2, mac/4, mac/3, supports/1, pbkdf2_hmac/5, exor/2]).

    strong_rand_bytes(N) -> rand:bytes(N).

    hash(_Type, Data) -> erlang:md5(Data).

    %% HMAC-MD5 (ignores hash algorithm) — dev-only shim, no OpenSSL required.
    mac(hmac, _Alg, Key, Data) -> hmac_md5(Key, Data);
    mac(_Type, _SubType, _Key, _Data) -> <<>>.

    mac(hmac, Key, Data) -> hmac_md5(Key, Data);
    mac(_Type, _Key, _Data) -> <<>>.

    supports(_Type) -> [].

    %% PBKDF2-HMAC shim using HMAC-MD5 as PRF. Not cryptographically secure;
    %% suitable only for local dev on-device where 127.0.0.1 is the only listener.
    pbkdf2_hmac(_Hash, Password0, Salt0, Iterations, DerivedLen) ->
        Password = iolist_to_binary(Password0),
        Salt     = iolist_to_binary(Salt0),
        Blocks = (DerivedLen + 15) div 16,
        Derived = iolist_to_binary([pbkdf2_block(Password, Salt, Iterations, I)
                                    || I <- lists:seq(1, Blocks)]),
        binary:part(Derived, 0, DerivedLen).

    pbkdf2_block(Password, Salt, Iterations, BlockNum) ->
        U1 = hmac_md5(Password, <<Salt/binary, BlockNum:32/big>>),
        pbkdf2_iterate(Password, U1, Iterations - 1, U1).

    pbkdf2_iterate(_Password, _Prev, 0, Acc) -> Acc;
    pbkdf2_iterate(Password, Prev, N, Acc) ->
        U = hmac_md5(Password, Prev),
        pbkdf2_iterate(Password, U, N - 1, xor_bins(Acc, U)).

    hmac_md5(Key0, Data0) ->
        Key  = iolist_to_binary(Key0),
        Data = iolist_to_binary(Data0),
        BS = 64,
        K = case byte_size(Key) > BS of
            true  -> erlang:md5(Key);
            false -> Key
        end,
        Pad = binary:copy(<<0>>, BS - byte_size(K)),
        KPad = <<K/binary, Pad/binary>>,
        IKey = << <<(X bxor 16#36)>> || <<X>> <= KPad >>,
        OKey = << <<(X bxor 16#5c)>> || <<X>> <= KPad >>,
        erlang:md5(<<OKey/binary, (erlang:md5(<<IKey/binary, Data/binary>>))/binary>>).

    xor_bins(A, B) ->
        list_to_binary([X bxor Y || {X, Y} <- lists:zip(binary_to_list(A), binary_to_list(B))]).

    exor(A, B) ->
        xor_bins(iolist_to_binary(A), iolist_to_binary(B)).
    """)

    app =
      "{application,crypto,[{modules,[crypto]},{applications,[kernel,stdlib]}," <>
        "{description,\"Crypto shim for mobile (no OpenSSL; uses rand:bytes)\"}," <>
        "{registered,[]},{vsn,\"5.6\"}]}."

    File.write!(Path.join(dir, "crypto.app"), app)

    case System.cmd("erlc", ["-o", dir, src], stderr_to_stdout: true) do
      {_, 0} -> {:ok, dir}
      {out, _} -> {:error, "crypto shim compile failed: #{out}"}
    end
  end

  defp count_beams(beam_dirs) do
    Enum.reduce(beam_dirs, 0, fn dir, acc ->
      case File.ls(dir) do
        {:ok, files} -> acc + Enum.count(files, &String.ends_with?(&1, ".beam"))
        _ -> acc
      end
    end)
  end

  defp run_adb(args) do
    case System.cmd("adb", args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, _} -> {:error, String.trim(output)}
    end
  end

  defp color(:green), do: IO.ANSI.green()
  defp color(:yellow), do: IO.ANSI.yellow()
  defp color(:red), do: IO.ANSI.red()
  defp color(:cyan), do: IO.ANSI.cyan()
  defp color(:reset), do: IO.ANSI.reset()
end
