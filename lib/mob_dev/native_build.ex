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
  Runs iOS build script if `ios/build.sh` exists (simulator), or
  `xcodebuild` if targeting a physical iOS device via `device:` opt.
  """
  @spec build_all(keyword()) :: [:ok | {:error, term()}]
  def build_all(opts \\ []) do
    cfg = load_config()
    platforms = Keyword.get(opts, :platforms, [:android, :ios])
    device_id = Keyword.get(opts, :device, nil)

    results = []

    results =
      if :android in platforms and File.dir?("android"),
        do: [build_android(cfg) | results],
        else: results

    results =
      if :ios in platforms do
        physical_udid =
          cond do
            is_binary(device_id) and ios_physical_udid?(device_id) ->
              device_id

            is_nil(device_id) ->
              auto_detect_physical_ios()

            true ->
              nil
          end

        if physical_udid do
          [build_ios_physical(cfg, physical_udid) | results]
        else
          if File.exists?("ios/build.sh"), do: [build_ios(cfg) | results], else: results
        end
      else
        results
      end

    if results == [] do
      IO.puts(
        "  #{IO.ANSI.yellow()}No native build targets found (missing android/ or ios/build.sh)#{IO.ANSI.reset()}"
      )
    end

    Enum.each(results, fn
      {:ok, platform} ->
        IO.puts("  #{IO.ANSI.green()}✓ #{platform} native build complete#{IO.ANSI.reset()}")

      {:error, platform, reason} ->
        IO.puts(
          "  #{IO.ANSI.red()}✗ #{platform} native build failed: #{reason}#{IO.ANSI.reset()}"
        )
    end)

    ok_count = Enum.count(results, &match?({:ok, _}, &1))
    ok_count == length(results)
  end

  # ── Android ──────────────────────────────────────────────────────────────────

  defp build_android(cfg) do
    IO.puts("  Building Android APK...")
    bundle_id = cfg[:bundle_id] || MobDev.Config.bundle_id()
    apk = "android/app/build/outputs/apk/debug/app-debug.apk"

    with {:ok, otp_arm64} <- MobDev.OtpDownloader.ensure_android("arm64-v8a"),
         {:ok, otp_arm32} <- MobDev.OtpDownloader.ensure_android("armeabi-v7a"),
         :ok <- ensure_jni_libs(otp_arm64, "arm64-v8a"),
         :ok <- ensure_jni_libs(otp_arm32, "armeabi-v7a"),
         :ok <- gradle_assemble(),
         :ok <- adb_install_all(apk, bundle_id),
         :ok <- push_otp_release_android(bundle_id, cfg[:elixir_lib], otp_arm64, otp_arm32) do
      {:ok, "Android"}
    else
      {:error, reason} -> {:error, "Android", reason}
    end
  end

  # Copies ERTS helper executables into jniLibs as lib*.so so Android grants
  # them the apk_data_file SELinux label (required for execve).
  defp ensure_jni_libs(otp_dir, abi) do
    jni_libs = "android/app/src/main/jniLibs/#{abi}"
    File.mkdir_p!(jni_libs)

    erts_bins = Path.wildcard("#{otp_dir}/erts-*/bin") |> List.first()

    if erts_bins do
      for {exe, lib} <- [
            {"erl_child_setup", "liberl_child_setup.so"},
            {"inet_gethost", "libinet_gethost.so"},
            {"epmd", "libepmd.so"}
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
    IO.puts("  (first build may take a few minutes while CMake compiles native code)")
    android_dir = Path.join(File.cwd!(), "android")
    gradlew = Path.join(android_dir, "gradlew")

    # Stale Gradle daemon registry locks accumulate when builds are killed (Ctrl+C,
    # force-stop, etc.) and cause subsequent runs to hang silently while the wrapper
    # waits to acquire the lock. Clear them before every build.
    clear_stale_gradle_locks()

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
            stderr_to_stdout: true
          )

          System.cmd("adb", ["-s", serial, "uninstall", bundle_id], stderr_to_stdout: true)

          {install_out, install_rc} =
            System.cmd("adb", ["-s", serial, "install", apk], stderr_to_stdout: true)

          if install_rc != 0 or String.contains?(install_out, "INSTALL_FAILED") do
            reason =
              install_out
              |> String.split("\n")
              |> Enum.find(&String.contains?(&1, "INSTALL_FAILED")) || String.trim(install_out)

            IO.puts(
              "  #{IO.ANSI.yellow()}⚠  #{serial}: APK install failed — #{reason}#{IO.ANSI.reset()}"
            )

            IO.puts("     (OTP push will be skipped for this device)")
          else
            fix_erts_helper_labels(serial, bundle_id)
          end
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
    rooted? =
      case adb.(["root"]) do
        {out, 0} -> out =~ "restarting" or out =~ "already running as root"
        _ -> false
      end

    if rooted? do
      :timer.sleep(800)

      {lib_dir_out, _} =
        adb.([
          "shell",
          "pm dump #{bundle_id} | grep nativeLibraryDir | head -1 | awk '{print $NF}'"
        ])

      lib_dir = String.trim(lib_dir_out)

      if lib_dir != "" do
        for lib <- ["liberl_child_setup.so", "libinet_gethost.so", "libepmd.so"] do
          adb.(["shell", "chcon", "u:object_r:apk_data_file:s0", "#{lib_dir}/#{lib}"])
        end
      end
    end
  end

  defp push_otp_release_android(bundle_id, elixir_lib, otp_arm64, otp_arm32) do
    app_data = "/data/data/#{bundle_id}/files"

    IO.puts("  Pushing OTP release to device(s)...")

    case System.cmd("adb", ["devices"], stderr_to_stdout: true) do
      {output, 0} ->
        serials = parse_adb_serials(output)
        if serials == [], do: IO.puts("  (no devices connected, skipping OTP push)")

        Enum.reduce_while(serials, :ok, fn serial, _ ->
          otp_dir = device_otp_dir(serial, otp_arm64, otp_arm32)

          result =
            try do
              push_otp_to_device(serial, bundle_id, app_data, otp_dir, elixir_lib)
            catch
              {:skip, _} -> :ok
            end

          case result do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      {out, _} ->
        {:error, "adb devices failed: #{out}"}
    end
  end

  defp device_otp_dir(serial, otp_arm64, otp_arm32) do
    {abi_out, _} =
      System.cmd("adb", ["-s", serial, "shell", "getprop", "ro.product.cpu.abi"],
        stderr_to_stdout: true
      )

    abi = String.trim(abi_out)
    otp_dir_for_abi(abi, otp_arm64, otp_arm32)
  end

  @doc "Returns the OTP directory for the given Android ABI string."
  @spec otp_dir_for_abi(String.t(), String.t(), String.t()) :: String.t()
  def otp_dir_for_abi("armeabi-v7a", _arm64, arm32), do: arm32
  def otp_dir_for_abi(_abi, arm64, _arm32), do: arm64

  defp push_otp_to_device(serial, bundle_id, app_data, otp_dir, elixir_lib) do
    adb = fn args -> System.cmd("adb", ["-s", serial | args], stderr_to_stdout: true) end

    {pm_out, _} = adb.(["shell", "pm", "list", "packages", bundle_id])

    unless String.contains?(pm_out, "package:#{bundle_id}") do
      IO.puts(
        "  #{IO.ANSI.yellow()}⚠  #{serial}: #{bundle_id} not installed — skipping OTP push#{IO.ANSI.reset()}"
      )

      throw({:skip, serial})
    end

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
    stage_local = Path.join(System.tmp_dir!(), "mob_otp_#{serial}.tar")
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

      System.cmd(
        "cp",
        ["-r", "#{elixir_lib}/elixir/ebin/.", Path.join(otp_tmp, "lib/elixir/ebin")],
        stderr_to_stdout: true
      )

      System.cmd(
        "cp",
        ["-r", "#{elixir_lib}/logger/ebin/.", Path.join(otp_tmp, "lib/logger/ebin")],
        stderr_to_stdout: true
      )

      System.cmd("cp", ["-r", "#{elixir_lib}/eex/ebin/.", Path.join(otp_tmp, "lib/eex/ebin")],
        stderr_to_stdout: true
      )

      # COPYFILE_DISABLE=1 prevents macOS from inserting ._<file> AppleDouble
      # sidecars into the archive (Toybox tar on Android can't chown to macOS UID).
      case System.cmd("tar", ["cf", stage_local, "-C", tmp, "otp"],
             env: [{"COPYFILE_DISABLE", "1"}],
             stderr_to_stdout: true
           ) do
        {_, 0} -> :ok
        {out, _} -> throw({:error, "tar create failed: #{out}"})
      end

      case System.cmd("adb", ["-s", serial, "push", stage_local, stage_device],
             stderr_to_stdout: true
           ) do
        {_, 0} -> :ok
        {out, _} -> throw({:error, "adb push failed: #{out}"})
      end

      # `2>/dev/null; true` — Toybox tar cannot chown files to macOS UID 501
      # and exits 1, but extraction succeeds. Suppress errors and always succeed.
      cmd =
        "run-as #{bundle_id} mkdir -p #{app_data} && " <>
          "run-as #{bundle_id} tar xf #{stage_device} -C #{app_data} 2>/dev/null; true"

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
    with :ok <- check_path(cfg[:mob_dir], "mob_dir"),
         :ok <- check_path(cfg[:elixir_lib], "elixir_lib"),
         {:ok, otp_root} <- MobDev.OtpDownloader.ensure_ios_sim() do
      IO.puts("  Building iOS simulator app...")

      env = [
        {"MOB_DIR", Path.expand(cfg[:mob_dir])},
        {"MOB_ELIXIR_LIB", Path.expand(cfg[:elixir_lib])},
        {"MOB_IOS_OTP_ROOT", otp_root}
      ]

      case System.cmd("bash", ["ios/build.sh"],
             env: env,
             stderr_to_stdout: true,
             into: IO.stream()
           ) do
        {_, 0} -> {:ok, "iOS"}
        {_, _} -> {:error, "iOS", "build.sh failed — check output above"}
      end
    else
      {:error, reason} -> {:error, "iOS", reason}
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
  #   ios_epmd_build_src — path to OTP source tree used for EPMD compilation
  #                        (default: /tmp/otp_ios_device_build/otp)
  defp build_ios_physical(cfg, udid) do
    IO.puts("  Building iOS app for physical device #{udid}...")

    with {:ok, cfg} <- check_device_signing_config(cfg),
         {:ok, otp_root} <- MobDev.OtpDownloader.ensure_ios_device() do
      script = generate_build_device_sh(cfg, otp_root)
      script_path = "ios/build_device.sh"
      File.write!(script_path, script)
      File.chmod!(script_path, 0o755)

      env = build_device_env(cfg, otp_root)

      case System.cmd("bash", [script_path, udid],
             env: env,
             stderr_to_stdout: true,
             into: IO.stream()
           ) do
        {_, 0} -> {:ok, "iOS (device)"}
        {_, _} -> {:error, "iOS", "build_device.sh failed — check output above"}
      end
    else
      {:error, reason} -> {:error, "iOS", reason}
    end
  end

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
          Regex.scan(~r/\d+\) [0-9A-F]+ "([^"]+)"/, output)
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
      |> Enum.flat_map(&parse_mobileprovision/1)

    # Prefer exact bundle ID match; fall back to wildcard profiles (app_id "TEAMID.*")
    exact_profiles =
      Enum.filter(all_profiles, fn {_u, app_id, _team} ->
        String.ends_with?(app_id, ".#{bundle_id}")
      end)

    profiles =
      if exact_profiles != [] do
        exact_profiles
      else
        Enum.filter(all_profiles, fn {_u, app_id, _team} ->
          String.ends_with?(app_id, ".*")
        end)
      end

    candidates =
      if is_binary(uuid) do
        Enum.filter(profiles, fn {u, _, _} -> u == uuid end)
      else
        profiles
      end

    case candidates do
      [] ->
        {:error,
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
         """}

      [{found_uuid, app_id, team}] ->
        unless is_binary(uuid) do
          IO.puts(
            "  #{IO.ANSI.cyan()}Auto-detected provisioning profile: #{found_uuid} (team #{team})#{IO.ANSI.reset()}"
          )
        end

        if String.ends_with?(app_id, ".*") do
          IO.puts(
            "  #{IO.ANSI.cyan()}  (using wildcard profile — run `mix mob.provision` to create a dedicated profile for #{bundle_id})#{IO.ANSI.reset()}"
          )
        end

        {:ok, {found_uuid, team}}

      many ->
        choices = Enum.map_join(many, "\n", fn {u, app_id, _} -> "    #{u}  (#{app_id})" end)

        {:error,
         """
         Multiple provisioning profiles match '#{bundle_id}' — add ios_profile_uuid to mob.exs:

             config :mob_dev, ios_profile_uuid: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

         Matching profiles:
         #{choices}
         """}
    end
  end

  # Parses a .mobileprovision file (DER-wrapped plist) and returns [{uuid, app_id, team_id}].
  # The plist XML is embedded as plain text inside the DER envelope.
  defp parse_mobileprovision(path) do
    with {:ok, data} <- File.read(path),
         {s, _} <- :binary.match(data, "<?xml"),
         {e, len} <- :binary.match(data, "</plist>") do
      xml = binary_part(data, s, e - s + len)
      uuid_match = Regex.run(~r/<key>UUID<\/key>\s*<string>([^<]+)<\/string>/, xml)

      bundle_match =
        Regex.run(~r/<key>application-identifier<\/key>\s*<string>([^<]+)<\/string>/, xml)

      team_match =
        Regex.run(~r/<key>TeamIdentifier<\/key>\s*<array>\s*<string>([^<]+)<\/string>/, xml)

      case {uuid_match, bundle_match, team_match} do
        {[_, u], [_, b], [_, t]} -> [{String.trim(u), String.trim(b), String.trim(t)}]
        _ -> []
      end
    else
      _ -> []
    end
  end

  defp build_device_env(cfg, otp_root) do
    app_atom = Mix.Project.config()[:app]
    app_name = app_atom |> to_string() |> Macro.camelize()
    app_module = to_string(app_atom)
    elixir_lib = resolve_elixir_lib(cfg[:elixir_lib])
    epmd_src = cfg[:ios_epmd_build_src] || "/tmp/otp_ios_device_build/otp"

    [
      {"MOB_DIR", Path.expand(cfg[:mob_dir])},
      {"MOB_ELIXIR_LIB", Path.expand(elixir_lib)},
      {"MOB_IOS_DEVICE_OTP_ROOT", otp_root},
      {"MOB_IOS_EPMD_BUILD_SRC", epmd_src},
      {"MOB_IOS_BUNDLE_ID", cfg[:bundle_id]},
      {"MOB_IOS_TEAM_ID", cfg[:ios_team_id]},
      {"MOB_IOS_SIGN_IDENTITY", cfg[:ios_sign_identity]},
      {"MOB_IOS_PROFILE_UUID", cfg[:ios_profile_uuid]},
      {"MOB_APP_NAME", app_name},
      {"MOB_APP_MODULE", app_module}
    ]
  end

  defp generate_build_device_sh(_cfg, _otp_root) do
    ~S"""
    #!/bin/bash
    # ios/build_device.sh — Physical iOS device build (generated by mix mob.deploy --native).
    # All config comes from environment variables set by NativeBuild. Do not hardcode values here.
    set -e
    cd "$(dirname "$0")/.."

    # ── Config from mob.exs (set by mix mob.deploy --native) ─────────────────────
    MOB_DIR="${MOB_DIR:?MOB_DIR not set}"
    ELIXIR_LIB="${MOB_ELIXIR_LIB:?MOB_ELIXIR_LIB not set}"
    OTP_ROOT="${MOB_IOS_DEVICE_OTP_ROOT:?MOB_IOS_DEVICE_OTP_ROOT not set}"
    EPMD_BUILD_SRC="${MOB_IOS_EPMD_BUILD_SRC:-/tmp/otp_ios_device_build/otp}"
    BUNDLE_ID="${MOB_IOS_BUNDLE_ID:?bundle_id not set in mob.exs}"
    TEAM_ID="${MOB_IOS_TEAM_ID:?ios_team_id not set in mob.exs}"
    SIGN_IDENTITY="${MOB_IOS_SIGN_IDENTITY:?ios_sign_identity not set in mob.exs}"
    PROFILE_UUID="${MOB_IOS_PROFILE_UUID:?ios_profile_uuid not set in mob.exs}"
    APP_NAME="${MOB_APP_NAME:?MOB_APP_NAME not set}"   # CamelCase binary name, e.g. MobDemo
    APP_MODULE="${MOB_APP_MODULE:?MOB_APP_MODULE not set}" # snake_case, e.g. mob_demo
    DEVICE_UDID="${1:?Usage: build_device.sh <device-udid>}"

    ERTS_VSN=$(ls "$OTP_ROOT" | grep '^erts-' | sort -V | tail -1)
    [ -z "$ERTS_VSN" ] && echo "ERROR: No erts-* in $OTP_ROOT" && exit 1
    echo "=== ERTS: $ERTS_VSN, App: $APP_NAME, Bundle: $BUNDLE_ID ==="

    BEAMS_DIR="$OTP_ROOT/$APP_MODULE"
    SDKROOT=$(xcrun -sdk iphoneos --show-sdk-path)
    HOSTCC=$(xcrun -find cc)
    CC="$HOSTCC -arch arm64 -miphoneos-version-min=17.0 -isysroot $SDKROOT"

    IFLAGS="-I$OTP_ROOT/$ERTS_VSN/include \
            -I$OTP_ROOT/$ERTS_VSN/include/internal \
            -I$MOB_DIR/ios"

    LIBS="
      $OTP_ROOT/$ERTS_VSN/lib/libbeam.a
      $OTP_ROOT/$ERTS_VSN/lib/internal/liberts_internal_r.a
      $OTP_ROOT/$ERTS_VSN/lib/internal/libethread.a
      $OTP_ROOT/$ERTS_VSN/lib/libzstd.a
      $OTP_ROOT/$ERTS_VSN/lib/libepcre.a
      $OTP_ROOT/$ERTS_VSN/lib/libryu.a
      $OTP_ROOT/$ERTS_VSN/lib/asn1rt_nif.a
      $OTP_ROOT/$ERTS_VSN/lib/libmicro_openssl.a
    "

    # ── Compile Elixir/Erlang ─────────────────────────────────────────────────────
    echo "=== Compiling Erlang/Elixir ==="
    mix compile

    echo "=== Copying BEAM files to $BEAMS_DIR ==="
    mkdir -p "$BEAMS_DIR"
    for lib_dir in _build/dev/lib/*/ebin; do
        cp "$lib_dir"/* "$BEAMS_DIR/" 2>/dev/null || true
    done

    SQLITE_STATIC_LIB=""
    if [ -d "_build/dev/lib/exqlite" ]; then
        echo "=== Installing exqlite as OTP library (static NIF) ==="
        EXQLITE_VSN=$(grep '"exqlite"' mix.lock \
            | grep -o '"[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*"' | head -1 | tr -d '"')
        [ -z "$EXQLITE_VSN" ] && EXQLITE_VSN=$(grep -o '{vsn,"[^"]*"}' \
            _build/dev/lib/exqlite/ebin/exqlite.app | grep -o '"[^"]*"' | tr -d '"')
        EXQLITE_LIB_DIR="$OTP_ROOT/lib/exqlite-${EXQLITE_VSN}"
        rm -rf "$OTP_ROOT/lib/exqlite-"*
        mkdir -p "$EXQLITE_LIB_DIR/ebin" "$EXQLITE_LIB_DIR/priv"
        cp _build/dev/lib/exqlite/ebin/*.beam "$EXQLITE_LIB_DIR/ebin/"
        cp _build/dev/lib/exqlite/ebin/exqlite.app "$EXQLITE_LIB_DIR/ebin/"

        echo "=== Building sqlite3_nif.a (static NIF for iOS device) ==="
        EXQLITE_SRC="deps/exqlite/c_src"
        BUILD_DIR_TMP=$(mktemp -d)
        $CC -I "$EXQLITE_SRC" -I "$OTP_ROOT/$ERTS_VSN/include" \
            -I "$OTP_ROOT/$ERTS_VSN/include/internal" \
            -DSQLITE_THREADSAFE=1 -DSTATIC_ERLANG_NIF_LIBNAME=sqlite3_nif \
            -Wno-\#warnings \
            -c "$EXQLITE_SRC/sqlite3_nif.c" -o "$BUILD_DIR_TMP/sqlite3_nif.o"
        $CC -I "$EXQLITE_SRC" -DSQLITE_THREADSAFE=1 -Wno-\#warnings \
            -c "$EXQLITE_SRC/sqlite3.c" -o "$BUILD_DIR_TMP/sqlite3.o"
        $(xcrun -find ar) rcs "$EXQLITE_LIB_DIR/priv/sqlite3_nif.a" \
            "$BUILD_DIR_TMP/sqlite3_nif.o" "$BUILD_DIR_TMP/sqlite3.o"
        SQLITE_STATIC_LIB="$EXQLITE_LIB_DIR/priv/sqlite3_nif.a"
        rm -rf "$BUILD_DIR_TMP"
    else
        echo "=== exqlite not in project — skipping static NIF build ==="
    fi

    echo "=== Creating crypto shim ==="
    CRYPTO_TMP=$(mktemp -d)
    cat > "$CRYPTO_TMP/crypto.erl" << 'ERLEOF'
    -module(crypto).
    -behaviour(application).
    -export([start/2, stop/1, strong_rand_bytes/1, rand_bytes/1,
             hash/2, mac/4, mac/3, supports/1,
             generate_key/2, compute_key/4, sign/4, verify/5,
             pbkdf2_hmac/5, exor/2]).
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
    mac(hmac, _HashAlg, Key, Data) ->
        hmac_md5(iolist_to_binary(Key), iolist_to_binary(Data));
    mac(_Type, _SubType, _Key, _Data) -> <<>>.
    mac(_Type, _Key, _Data) -> <<>>.
    pbkdf2_hmac(_DigestType, Password, Salt, Iterations, DerivedKeyLen) ->
        Pwd = iolist_to_binary(Password), S = iolist_to_binary(Salt),
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
    exor(A, B) -> xor_bytes(iolist_to_binary(A), iolist_to_binary(B)).
    xor_bytes(A, B) -> xor_bytes(A, B, []).
    xor_bytes(<<X, Ra/binary>>, <<Y, Rb/binary>>, Acc) ->
        xor_bytes(Ra, Rb, [X bxor Y | Acc]);
    xor_bytes(<<>>, <<>>, Acc) -> list_to_binary(lists:reverse(Acc)).
    ERLEOF
    erlc -o "$BEAMS_DIR" "$CRYPTO_TMP/crypto.erl"
    cat > "$BEAMS_DIR/crypto.app" << 'APPEOF'
    {application,crypto,[{modules,[crypto]},{applications,[kernel,stdlib]},{description,"Crypto shim for iOS (no OpenSSL)"},{registered,[]},{vsn,"5.6"},{mod,{crypto,[]}}]}.
    APPEOF
    rm -rf "$CRYPTO_TMP"

    echo "=== Copying Elixir stdlib ==="
    mkdir -p "$OTP_ROOT/lib/elixir/ebin" "$OTP_ROOT/lib/logger/ebin"
    cp "$ELIXIR_LIB/elixir/ebin/"*.beam    "$OTP_ROOT/lib/elixir/ebin/"
    cp "$ELIXIR_LIB/elixir/ebin/elixir.app" "$OTP_ROOT/lib/elixir/ebin/"
    cp "$ELIXIR_LIB/logger/ebin/"*.beam    "$OTP_ROOT/lib/logger/ebin/"
    cp "$ELIXIR_LIB/logger/ebin/logger.app" "$OTP_ROOT/lib/logger/ebin/"
    cp "$ELIXIR_LIB/eex/ebin/"*.beam  "$BEAMS_DIR/"
    cp "$ELIXIR_LIB/eex/ebin/eex.app" "$BEAMS_DIR/"

    echo "=== Copying runtime_tools OTP library ==="
    RUNTIME_TOOLS_SRC=$(elixir -e "IO.puts(:code.lib_dir(:runtime_tools))" 2>/dev/null)
    if [ -n "$RUNTIME_TOOLS_SRC" ] && [ -d "$RUNTIME_TOOLS_SRC/ebin" ]; then
        RUNTIME_TOOLS_VSN=$(basename "$RUNTIME_TOOLS_SRC")
        mkdir -p "$OTP_ROOT/lib/$RUNTIME_TOOLS_VSN/ebin"
        cp "$RUNTIME_TOOLS_SRC/ebin/"*.beam "$OTP_ROOT/lib/$RUNTIME_TOOLS_VSN/ebin/"
        cp "$RUNTIME_TOOLS_SRC/ebin/runtime_tools.app" "$OTP_ROOT/lib/$RUNTIME_TOOLS_VSN/ebin/"
    else
        echo "Warning: runtime_tools not found on host — skipping"
    fi

    echo "=== Copying migrations ==="
    mkdir -p "$BEAMS_DIR/priv/repo/migrations"
    if ls priv/repo/migrations/*.exs >/dev/null 2>&1; then
        cp priv/repo/migrations/*.exs "$BEAMS_DIR/priv/repo/migrations/"
    fi

    echo "=== Copying logos ==="
    cp "$MOB_DIR/assets/logo/logo_dark.png"  "$OTP_ROOT/mob_logo_dark.png"  2>/dev/null || true
    cp "$MOB_DIR/assets/logo/logo_light.png" "$OTP_ROOT/mob_logo_light.png" 2>/dev/null || true

    # ── Compile native sources ────────────────────────────────────────────────────
    echo "=== Compiling native sources ==="
    BUILD_DIR=$(mktemp -d)
    SWIFT_BRIDGING="$MOB_DIR/ios/MobDemo-Bridging-Header.h"

    $CC -fobjc-arc -fmodules $IFLAGS \
        -c "$MOB_DIR/ios/MobNode.m" -o "$BUILD_DIR/MobNode.o"

    xcrun -sdk iphoneos swiftc \
        -target arm64-apple-ios17.0 \
        -module-name "$APP_NAME" \
        -emit-objc-header -emit-objc-header-path "$BUILD_DIR/MobApp-Swift.h" \
        -import-objc-header "$SWIFT_BRIDGING" \
        -I "$MOB_DIR/ios" \
        -parse-as-library -wmo \
        "$MOB_DIR/ios/MobViewModel.swift" \
        "$MOB_DIR/ios/MobRootView.swift" \
        -c -o "$BUILD_DIR/swift_mob.o"

    $CC -fobjc-arc -fmodules $IFLAGS \
        -I "$BUILD_DIR" -DSTATIC_ERLANG_NIF \
        -c "$MOB_DIR/ios/mob_nif.m" -o "$BUILD_DIR/mob_nif.o"

    $CC -fobjc-arc -fmodules $IFLAGS \
        -DMOB_BUNDLE_OTP \
        -DERTS_VSN=\"$ERTS_VSN\" \
        -DOTP_RELEASE=\"28\" \
        -c "$MOB_DIR/ios/mob_beam.m" -o "$BUILD_DIR/mob_beam.o"

    echo "=== Compiling in-process EPMD ==="
    EPMD_SRC="$EPMD_BUILD_SRC/erts/epmd/src"
    EPMD_FLAGS="-DHAVE_CONFIG_H -DEPMD_PORT_NO=4369 -Dmain=epmd_ios_main \
        -I $EPMD_BUILD_SRC/erts/aarch64-apple-ios \
        -I $EPMD_SRC \
        -I $EPMD_BUILD_SRC/erts/include \
        -I $EPMD_BUILD_SRC/erts/include/internal"
    xcrun -sdk iphoneos clang -arch arm64 -miphoneos-version-min=17.0 \
        $EPMD_FLAGS -c "$EPMD_SRC/epmd.c"     -o "$BUILD_DIR/epmd_main.o"
    xcrun -sdk iphoneos clang -arch arm64 -miphoneos-version-min=17.0 \
        $EPMD_FLAGS -c "$EPMD_SRC/epmd_srv.c" -o "$BUILD_DIR/epmd_srv.o"
    xcrun -sdk iphoneos clang -arch arm64 -miphoneos-version-min=17.0 \
        $EPMD_FLAGS -c "$EPMD_SRC/epmd_cli.c" -o "$BUILD_DIR/epmd_cli.o"

    SQLITE_FLAG=""
    [ -n "$SQLITE_STATIC_LIB" ] && SQLITE_FLAG="-DMOB_STATIC_SQLITE_NIF"
    $CC $IFLAGS $SQLITE_FLAG \
        -c "$MOB_DIR/ios/driver_tab_ios.c" -o "$BUILD_DIR/driver_tab_ios.o"

    $CC -fobjc-arc -fmodules $IFLAGS \
        -I "$BUILD_DIR" \
        -c ios/AppDelegate.m -o "$BUILD_DIR/AppDelegate.o"

    $CC -fobjc-arc -fmodules $IFLAGS \
        -c ios/beam_main.m -o "$BUILD_DIR/beam_main.o"

    # ── Link ─────────────────────────────────────────────────────────────────────
    echo "=== Linking $APP_NAME binary ==="
    xcrun -sdk iphoneos swiftc \
        -target arm64-apple-ios17.0 \
        "$BUILD_DIR/driver_tab_ios.o" \
        "$BUILD_DIR/MobNode.o" \
        "$BUILD_DIR/swift_mob.o" \
        "$BUILD_DIR/mob_nif.o" \
        "$BUILD_DIR/mob_beam.o" \
        "$BUILD_DIR/epmd_main.o" \
        "$BUILD_DIR/epmd_srv.o" \
        "$BUILD_DIR/epmd_cli.o" \
        "$BUILD_DIR/AppDelegate.o" \
        "$BUILD_DIR/beam_main.o" \
        $LIBS \
        "$SQLITE_STATIC_LIB" \
        -lz -lc++ -lpthread \
        -Xlinker -framework -Xlinker UIKit \
        -Xlinker -framework -Xlinker Foundation \
        -Xlinker -framework -Xlinker CoreGraphics \
        -Xlinker -framework -Xlinker QuartzCore \
        -Xlinker -framework -Xlinker SwiftUI \
        -o "$BUILD_DIR/$APP_NAME"

    # ── Bundle ────────────────────────────────────────────────────────────────────
    echo "=== Building .app bundle ==="
    APP="$BUILD_DIR/$APP_NAME.app"
    rm -rf "$APP"
    mkdir -p "$APP"
    cp "$BUILD_DIR/$APP_NAME" "$APP/"

    # Patch bundle ID in Info.plist, then copy
    cp ios/Info.plist "$APP/"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $APP_NAME"   "$APP/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME"         "$APP/Info.plist"

    if [ -d "ios/Assets.xcassets/AppIcon.appiconset" ]; then
        ACTOOL_PLIST=$(mktemp /tmp/actool_XXXXXX.plist)
        xcrun actool ios/Assets.xcassets \
            --compile "$APP" --platform iphoneos \
            --minimum-deployment-target 17.0 \
            --app-icon AppIcon \
            --output-partial-info-plist "$ACTOOL_PLIST" 2>/dev/null || true
        /usr/libexec/PlistBuddy -c "Merge $ACTOOL_PLIST" "$APP/Info.plist" 2>/dev/null || true
        rm -f "$ACTOOL_PLIST"
    fi

    echo "=== Bundling OTP runtime inside .app ==="
    OTP_BUNDLE="$APP/otp"
    mkdir -p "$OTP_BUNDLE"
    rsync -a --delete "$OTP_ROOT/lib/"      "$OTP_BUNDLE/lib/"
    rsync -a --delete "$OTP_ROOT/releases/" "$OTP_BUNDLE/releases/"
    rsync -a --delete "$OTP_ROOT/$APP_MODULE/" "$OTP_BUNDLE/$APP_MODULE/"
    for f in "$OTP_ROOT"/*.png "$OTP_ROOT"/*.jpg; do
        [ -f "$f" ] && cp "$f" "$OTP_BUNDLE/"
    done
    mkdir -p "$OTP_BUNDLE/$ERTS_VSN/bin"
    echo "  OTP bundle: $(du -sh "$OTP_BUNDLE" | cut -f1)"

    echo "=== Embedding provisioning profile ==="
    PROFILE_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
    PROFILE="$PROFILE_DIR/${PROFILE_UUID}.mobileprovision"
    if [ ! -f "$PROFILE" ]; then
        # Also check MobileDevice path (older Xcode versions)
        PROFILE="$HOME/Library/MobileDevice/Provisioning Profiles/${PROFILE_UUID}.mobileprovision"
    fi
    if [ ! -f "$PROFILE" ]; then
        echo "ERROR: Provisioning profile $PROFILE_UUID not found."
        echo "       Open Xcode → Settings → Accounts → Download Profiles"
        exit 1
    fi
    cp "$PROFILE" "$APP/embedded.mobileprovision"

    echo "=== Code signing ==="
    # Use project entitlements if present; otherwise generate minimal ones.
    ENTITLEMENTS_FILE=$(ls ios/*.entitlements 2>/dev/null | head -1 || true)
    if [ -z "$ENTITLEMENTS_FILE" ]; then
        ENTITLEMENTS_FILE="$BUILD_DIR/mob_device.entitlements"
        cat > "$ENTITLEMENTS_FILE" << ENTEOF
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>application-identifier</key>
        <string>${TEAM_ID}.${BUNDLE_ID}</string>
        <key>com.apple.developer.team-identifier</key>
        <string>${TEAM_ID}</string>
        <key>get-task-allow</key>
        <true/>
    </dict>
    </plist>
    ENTEOF
    fi
    codesign --force --sign "$SIGN_IDENTITY" \
        --entitlements "$ENTITLEMENTS_FILE" \
        --timestamp=none \
        "$APP"

    echo "=== Installing on device $DEVICE_UDID ==="
    xcrun devicectl device install app --device "$DEVICE_UDID" "$APP"

    echo "=== Build and install complete ==="
    """
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
      physical =
        MobDev.Discovery.IOS.list_devices()
        |> Enum.filter(&(&1.type == :physical and &1.status in [:connected, :discovered]))

      case physical do
        [device] ->
          IO.puts(
            "  #{IO.ANSI.cyan()}Auto-detected physical device: #{device.name || device.serial}#{IO.ANSI.reset()}"
          )

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
  defp ios_physical_udid?(id) do
    Regex.match?(~r/^[0-9A-Fa-f]{40}$/, id) or
      Regex.match?(
        ~r/^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$/,
        id
      ) or
      Regex.match?(~r/^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}$/, id)
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

    elixir_lib = resolve_elixir_lib(cfg[:elixir_lib])
    bundle_id = cfg[:bundle_id] || MobDev.Config.bundle_id()

    cfg
    |> Keyword.put(:elixir_lib, elixir_lib)
    |> Keyword.put_new(:bundle_id, bundle_id)
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
