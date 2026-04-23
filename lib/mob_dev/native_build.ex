defmodule MobDev.NativeBuild do
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
  """

  @doc """
  Builds native binaries for all platforms present in the project.
  Runs Android Gradle build if `android/` dir exists.
  Runs iOS build script if `ios/build.sh` exists.
  """
  @spec build_all(keyword()) :: [:ok | {:error, term()}]
  def build_all(opts \\ []) do
    cfg       = load_config()
    platforms = Keyword.get(opts, :platforms, [:android, :ios])

    results = []
    results = if :android in platforms and File.dir?("android"),
                do: [build_android(cfg) | results], else: results
    results = if :ios in platforms and File.exists?("ios/build.sh"),
                do: [build_ios(cfg) | results], else: results

    if results == [] do
      IO.puts("  #{IO.ANSI.yellow()}No native build targets found (missing android/ or ios/build.sh)#{IO.ANSI.reset()}")
    end

    Enum.each(results, fn
      {:ok, platform} ->
        IO.puts("  #{IO.ANSI.green()}✓ #{platform} native build complete#{IO.ANSI.reset()}")
      {:error, platform, reason} ->
        IO.puts("  #{IO.ANSI.red()}✗ #{platform} native build failed: #{reason}#{IO.ANSI.reset()}")
    end)

    ok_count = Enum.count(results, &match?({:ok, _}, &1))
    ok_count == length(results)
  end

  # ── Android ──────────────────────────────────────────────────────────────────

  defp build_android(cfg) do
    IO.puts("  Building Android APK...")
    bundle_id = cfg[:bundle_id] || MobDev.Config.bundle_id()
    apk = "android/app/build/outputs/apk/debug/app-debug.apk"

    with {:ok, otp_dir} <- MobDev.OtpDownloader.ensure_android(),
         :ok <- ensure_jni_libs(otp_dir),
         :ok <- gradle_assemble(),
         :ok <- adb_install_all(apk, bundle_id),
         :ok <- push_otp_release_android(bundle_id, otp_dir, cfg[:elixir_lib]) do
      {:ok, "Android"}
    else
      {:error, reason} -> {:error, "Android", reason}
    end
  end

  # Copies ERTS helper executables into jniLibs as lib*.so so Android grants
  # them the apk_data_file SELinux label (required for execve).
  defp ensure_jni_libs(otp_dir) do
    jni_libs = "android/app/src/main/jniLibs/arm64-v8a"
    File.mkdir_p!(jni_libs)

    erts_bins = Path.wildcard("#{otp_dir}/erts-*/bin") |> List.first()

    if erts_bins do
      for {exe, lib} <- [
        {"erl_child_setup", "liberl_child_setup.so"},
        {"inet_gethost",    "libinet_gethost.so"},
        {"epmd",            "libepmd.so"}
      ] do
        src = Path.join(erts_bins, exe)
        dst = Path.join(jni_libs, lib)
        if File.exists?(src), do: cp(src, dst)
      end
    end

    :ok
  end

  defp gradle_assemble do
    IO.puts("  Running Gradle assembleDebug...")
    IO.puts("  (first build compiles SQLite from source — may take a few minutes)")
    android_dir = Path.join(File.cwd!(), "android")
    gradlew     = Path.join(android_dir, "gradlew")

    if File.exists?(gradlew) do
      # Stream output live so the user can see progress during the long
      # sqlite3.c / libbeam.a first-time compilation.
      # NOTE: Kotlin errors (lines starting with "e: ") appear in the stream
      # above the final "* What went wrong:" summary. If the build fails,
      # scroll up — or run `cd android && ./gradlew assembleDebug` directly.
      case System.cmd(gradlew, ["assembleDebug", "--no-daemon"],
                      cd: android_dir, stderr_to_stdout: true, into: IO.stream()) do
        {_, 0}   -> :ok
        {_, _}   -> {:error, "Gradle failed — scroll up for Kotlin/build errors\n  (or run: cd android && ./gradlew assembleDebug)"}
      end
    else
      {:error, "gradlew not found at #{gradlew}"}
    end
  end

  defp adb_install_all(apk, bundle_id) do
    case System.cmd("adb", ["devices"], stderr_to_stdout: true) do
      {output, 0} ->
        serials =
          output
          |> String.split("\n")
          |> Enum.drop(1)
          |> Enum.filter(&String.contains?(&1, "\tdevice"))
          |> Enum.map(&hd(String.split(&1, "\t")))

        Enum.each(serials, fn serial ->
          IO.puts("  Installing APK on #{serial}...")
          System.cmd("adb", ["-s", serial, "shell", "am", "force-stop", bundle_id],
                     stderr_to_stdout: true)
          System.cmd("adb", ["-s", serial, "uninstall", bundle_id], stderr_to_stdout: true)
          System.cmd("adb", ["-s", serial, "install", apk], stderr_to_stdout: true)
          fix_erts_helper_labels(serial, bundle_id)
        end)

        :ok

      {out, _} ->
        {:error, "adb devices failed: #{out}"}
    end
  end

  # Android 15 streaming install labels ERTS helper .so files as app_data_file
  # instead of apk_data_file, blocking execute_no_trans by untrusted_app.
  # Fix by chcon-ing them back to apk_data_file (requires root / emulator).
  defp fix_erts_helper_labels(serial, bundle_id) do
    adb = fn args -> System.cmd("adb", ["-s", serial | args], stderr_to_stdout: true) end

    # Only works on rooted/emulator builds — silently skip on real devices.
    rooted? = case adb.(["root"]) do
      {out, 0} -> out =~ "restarting" or out =~ "already running as root"
      _        -> false
    end

    if rooted? do
      :timer.sleep(800)
      {lib_dir_out, _} = adb.(["shell",
        "pm dump #{bundle_id} | grep nativeLibraryDir | head -1 | awk '{print $NF}'"])
      lib_dir = String.trim(lib_dir_out)

      if lib_dir != "" do
        for lib <- ["liberl_child_setup.so", "libinet_gethost.so", "libepmd.so"] do
          adb.(["shell", "chcon", "u:object_r:apk_data_file:s0", "#{lib_dir}/#{lib}"])
        end
      end
    end
  end

  defp push_otp_release_android(bundle_id, otp_dir, elixir_lib) do
    app_data = "/data/data/#{bundle_id}/files"

    IO.puts("  Pushing OTP release to device(s)...")

    case System.cmd("adb", ["devices"], stderr_to_stdout: true) do
      {output, 0} ->
        serials = parse_adb_serials(output)
        if serials == [], do: IO.puts("  (no devices connected, skipping OTP push)")
        Enum.reduce_while(serials, :ok, fn serial, _ ->
          case push_otp_to_device(serial, bundle_id, app_data, otp_dir, elixir_lib) do

            :ok              -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
      {out, _} ->
        {:error, "adb devices failed: #{out}"}
    end
  end

  defp push_otp_to_device(serial, bundle_id, app_data, otp_dir, elixir_lib) do
    adb = fn args -> System.cmd("adb", ["-s", serial | args], stderr_to_stdout: true) end

    # Launch briefly so the app creates its files directory, then stop.
    adb.(["shell", "am", "start", "-n", "#{bundle_id}/.MainActivity"])
    :timer.sleep(2000)
    adb.(["shell", "am", "force-stop", bundle_id])
    :timer.sleep(500)

    case adb.(["root"]) do
      {out, 0} ->
        if out =~ "restarting" or out =~ "already running as root" do
          :timer.sleep(1000)
          push_otp_root(adb, app_data, otp_dir, elixir_lib)
        else
          push_otp_runas(serial, bundle_id, app_data, otp_dir, elixir_lib)
        end
      _ ->
        push_otp_runas(serial, bundle_id, app_data, otp_dir, elixir_lib)
    end
  end

  defp push_otp_root(adb, app_data, otp_dir, elixir_lib) do
    try do
      adb.(["shell", "mkdir -p #{app_data}/otp"])

      case adb.(["push", "#{otp_dir}/.", "#{app_data}/otp/"]) do
        {_, 0} -> :ok
        {out, _} -> throw({:error, "push OTP release failed: #{String.slice(out, -300, 300)}"})
      end

      adb.(["shell", "mkdir -p #{app_data}/otp/lib/elixir/ebin"])
      adb.(["shell", "mkdir -p #{app_data}/otp/lib/logger/ebin"])
      adb.(["shell", "mkdir -p #{app_data}/otp/lib/eex/ebin"])

      case adb.(["push", "#{elixir_lib}/elixir/ebin/.", "#{app_data}/otp/lib/elixir/ebin/"]) do
        {_, 0} -> :ok
        {out, _} -> throw({:error, "push elixir failed: #{String.slice(out, -300, 300)}"})
      end

      case adb.(["push", "#{elixir_lib}/logger/ebin/.", "#{app_data}/otp/lib/logger/ebin/"]) do
        {_, 0} -> :ok
        {out, _} -> throw({:error, "push logger failed: #{String.slice(out, -300, 300)}"})
      end

      case adb.(["push", "#{elixir_lib}/eex/ebin/.", "#{app_data}/otp/lib/eex/ebin/"]) do
        {_, 0} -> :ok
        {out, _} -> throw({:error, "push eex failed: #{String.slice(out, -300, 300)}"})
      end

      # Fix ownership so the app can read its own files.
      {uid_out, _} = adb.(["shell", "stat -c %u #{app_data}/.."])
      uid = String.trim(uid_out)
      if uid != "", do: adb.(["shell", "chown -R #{uid}:#{uid} #{app_data}"])

      :ok
    catch
      {:error, reason} -> {:error, reason}
    end
  end

  defp push_otp_runas(serial, bundle_id, app_data, otp_dir, elixir_lib) do
    stage_local  = Path.join(System.tmp_dir!(), "mob_otp_#{serial}.tar")
    stage_device = "/data/local/tmp/mob_otp.tar"

    try do
      tmp = Path.join(System.tmp_dir!(), "mob_otp_stage_#{serial}")
      File.rm_rf!(tmp)
      otp_tmp = Path.join(tmp, "otp")
      File.mkdir_p!(otp_tmp)

      System.cmd("cp", ["-r", "#{otp_dir}/.", otp_tmp], stderr_to_stdout: true)

      File.mkdir_p!(Path.join(otp_tmp, "lib/elixir/ebin"))
      File.mkdir_p!(Path.join(otp_tmp, "lib/logger/ebin"))
      File.mkdir_p!(Path.join(otp_tmp, "lib/eex/ebin"))
      System.cmd("cp", ["-r", "#{elixir_lib}/elixir/ebin/.", Path.join(otp_tmp, "lib/elixir/ebin")],
                 stderr_to_stdout: true)
      System.cmd("cp", ["-r", "#{elixir_lib}/logger/ebin/.", Path.join(otp_tmp, "lib/logger/ebin")],
                 stderr_to_stdout: true)
      System.cmd("cp", ["-r", "#{elixir_lib}/eex/ebin/.", Path.join(otp_tmp, "lib/eex/ebin")],
                 stderr_to_stdout: true)

      case System.cmd("tar", ["cf", stage_local, "-C", tmp, "otp"], stderr_to_stdout: true) do
        {_, 0} -> :ok
        {out, _} -> throw({:error, "tar create failed: #{out}"})
      end

      case System.cmd("adb", ["-s", serial, "push", stage_local, stage_device],
                      stderr_to_stdout: true) do
        {_, 0} -> :ok
        {out, _} -> throw({:error, "adb push failed: #{out}"})
      end

      cmd = "run-as #{bundle_id} mkdir -p #{app_data} && " <>
            "run-as #{bundle_id} tar xf #{stage_device} -C #{app_data}"
      case System.cmd("adb", ["-s", serial, "shell", cmd], stderr_to_stdout: true) do
        {_, 0} -> :ok
        {out, _} -> throw({:error, "run-as tar failed: #{out}"})
      end

      System.cmd("adb", ["-s", serial, "shell", "rm -f #{stage_device}"], stderr_to_stdout: true)
      :ok
    catch
      {:error, reason} -> {:error, reason}
    after
      File.rm(stage_local)
      File.rm_rf(Path.join(System.tmp_dir!(), "mob_otp_stage_#{serial}"))
    end
  end

  defp parse_adb_serials(output) do
    output
    |> String.split("\n")
    |> Enum.drop(1)
    |> Enum.filter(&String.contains?(&1, "\tdevice"))
    |> Enum.map(&hd(String.split(&1, "\t")))
  end

  # ── iOS ──────────────────────────────────────────────────────────────────────

  defp build_ios(cfg) do
    with :ok <- check_path(cfg[:mob_dir],    "mob_dir"),
         :ok <- check_path(cfg[:elixir_lib], "elixir_lib"),
         {:ok, otp_root} <- MobDev.OtpDownloader.ensure_ios_sim() do
      IO.puts("  Building iOS simulator app...")

      env = [
        {"MOB_DIR",          Path.expand(cfg[:mob_dir])},
        {"MOB_ELIXIR_LIB",   Path.expand(cfg[:elixir_lib])},
        {"MOB_IOS_OTP_ROOT", otp_root}
      ]

      case System.cmd("bash", ["ios/build.sh"], env: env, stderr_to_stdout: true, into: IO.stream()) do
        {_, 0} -> {:ok, "iOS"}
        {_, _} -> {:error, "iOS", "build.sh failed — check output above"}
      end
    else
      {:error, reason} -> {:error, "iOS", reason}
    end
  end

  # ── Config ───────────────────────────────────────────────────────────────────

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

    # elixir_lib is always detectable from the running BEAM — no need to store it
    # in mob.exs. If the stored value is missing or stale (e.g. after a version
    # upgrade or on a different developer's machine), detect it automatically.
    elixir_lib = resolve_elixir_lib(cfg[:elixir_lib])
    Keyword.put(cfg, :elixir_lib, elixir_lib)
  end

  # Use the mob.exs value if it exists on disk; otherwise detect from the running BEAM.
  defp resolve_elixir_lib(configured) when is_binary(configured) do
    expanded = Path.expand(configured)
    if File.exists?(expanded), do: configured, else: detect_elixir_lib()
  end
  defp resolve_elixir_lib(_), do: detect_elixir_lib()

  defp detect_elixir_lib do
    :code.lib_dir(:elixir) |> to_string() |> Path.dirname()
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
