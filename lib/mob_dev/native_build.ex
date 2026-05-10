defmodule MobDev.NativeBuild do
  alias MobDev.Release

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
    slim = Keyword.get(opts, :slim, true)
    platforms = narrow_platforms_for_device(platforms, device_id)
    Process.put(:mob_slim, slim)

    results = []

    # Skip Android when its toolchain isn't installed instead of failing the
    # build half an hour into a partial-setup user's first deploy. Default
    # `mix mob.deploy` (no platform flag) targets every platform with a
    # `<dir>/` scaffold, but users who only set up iOS hit a Gradle error
    # half a build later — annoying, and fixable by checking up front.
    results =
      cond do
        :android not in platforms ->
          results

        not File.dir?("android") ->
          results

        not android_toolchain_available?() ->
          warn_skipped_android()
          results

        true ->
          [build_android(cfg, device_id) | results]
      end

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

        cond do
          not ios_toolchain_available?() ->
            warn_skipped_ios()
            results

          physical_udid ->
            [build_ios_physical(cfg, physical_udid) | results]

          File.exists?("ios/build.zig") ->
            [build_ios(cfg, device_id) | results]

          true ->
            results
        end
      else
        results
      end

    if results == [] do
      IO.puts(
        "  #{IO.ANSI.yellow()}No native build targets found (missing android/ or ios/build.sh, or toolchains)#{IO.ANSI.reset()}"
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

  defp build_android(cfg, device_id) do
    IO.puts("  Building Android APK...")
    bundle_id = cfg[:bundle_id] || MobDev.Config.bundle_id()
    apk = "android/app/build/outputs/apk/debug/app-debug.apk"
    mob_dir = Path.expand(cfg[:mob_dir])

    with {:ok, otp_arm64} <- MobDev.OtpDownloader.ensure_android("arm64-v8a"),
         {:ok, otp_arm32} <- MobDev.OtpDownloader.ensure_android("armeabi-v7a"),
         {:ok, python_android_bundle} <- maybe_ensure_python_android_bundle(),
         :ok <- ensure_jni_libs(otp_arm64, "arm64-v8a"),
         :ok <- ensure_jni_libs(otp_arm32, "armeabi-v7a"),
         :ok <- ensure_python_android_libs(python_android_bundle),
         :ok <- zig_build_android_objects(mob_dir, otp_arm64, otp_arm32),
         :ok <- gradle_assemble(),
         :ok <- adb_install_all(apk, bundle_id, device_id),
         :ok <-
           push_otp_release_android(
             bundle_id,
             cfg[:elixir_lib],
             otp_arm64,
             otp_arm32,
             device_id
           ) do
      {:ok, "Android"}
    else
      {:error, reason} -> {:error, "Android", reason}
    end
  end

  # Phase 2 iter 8: invoke build.zig per-ABI before Gradle. Produces
  # android/app/build/zig-out/<abi>/driver_tab_android.o which CMakeLists.txt
  # picks up via its `if(EXISTS ${ZIG_DRIVER_TAB_O})` check; the per-ABI
  # path is what CMake's ${ANDROID_ABI} variable resolves to.
  #
  # Skips silently if the project has no jni/build.zig (older projects from
  # before this iter still work via CMake compiling driver_tab_android.c
  # directly through the Phase 0 fallback).
  defp zig_build_android_objects(mob_dir, otp_arm64, otp_arm32) do
    build_zig = "android/app/src/main/jni/build.zig"

    cond do
      not File.exists?(build_zig) ->
        :ok

      not zig_available?() ->
        IO.puts(
          "  #{IO.ANSI.yellow()}zig not on PATH — skipping build.zig step (CMake will compile sources directly)#{IO.ANSI.reset()}"
        )

        :ok

      true ->
        driver_tab = resolve_driver_tab_android(mob_dir)
        erts_vsn = detect_erts_vsn(otp_arm64) || "erts-17.0"

        IO.puts("  Compiling Android C objects via zig build (per-ABI)...")

        Enum.reduce_while(
          [{otp_arm64, "arm64-v8a"}, {otp_arm32, "armeabi-v7a"}],
          :ok,
          fn {otp_dir, abi}, _acc ->
            case run_zig_android_objects(build_zig, abi, otp_dir, erts_vsn, mob_dir, driver_tab) do
              :ok -> {:cont, :ok}
              {:error, reason} -> {:halt, {:error, reason}}
            end
          end
        )
    end
  end

  defp run_zig_android_objects(build_zig, abi, otp_dir, erts_vsn, mob_dir, driver_tab) do
    app_name = Mix.Project.config() |> Keyword.fetch!(:app) |> Atom.to_string()
    project_root = Path.expand(".")
    project_jni_dir = Path.join(project_root, "android/app/src/main/jni")
    jni_libs_abi = Path.join([project_root, "android/app/src/main/jniLibs", abi])
    File.mkdir_p!(jni_libs_abi)

    args = [
      "build",
      "native-lib",
      "--build-file",
      build_zig,
      "--prefix",
      "android/app/build/zig-out",
      "-Dabi=#{abi}",
      "-Dotp_dir=#{otp_dir}",
      "-Derts_vsn=#{erts_vsn}",
      "-Dmob_dir=#{mob_dir}",
      "-Ddriver_tab=#{driver_tab}",
      "-Dproject_jni_dir=#{project_jni_dir}",
      "-Dndk_sysroot=#{ndk_sysroot()}",
      "-Dapp_name=#{app_name}",
      "-Dproject_root=#{project_root}",
      "-Dexqlite_src=#{Path.join(project_root, "deps/exqlite/c_src")}"
    ]

    case System.cmd("zig", args, stderr_to_stdout: true, into: IO.stream()) do
      {_, 0} -> :ok
      {_, code} -> {:error, "zig build for #{abi} exited #{code}"}
    end
  end

  defp ndk_sysroot do
    # NDK ships only one prebuilt — darwin-x86_64 even on Apple Silicon
    # (Apple's Rosetta 2 covers it). On Linux it'd be linux-x86_64.
    host =
      case :os.type() do
        {:unix, :darwin} -> "darwin-x86_64"
        {:unix, :linux} -> "linux-x86_64"
        other -> raise "unsupported host for NDK: #{inspect(other)}"
      end

    sdk_root = System.get_env("ANDROID_HOME") || Path.expand("~/Library/Android/sdk")
    ndk_version = MobDev.NdkVersion.effective()
    Path.join([sdk_root, "ndk", ndk_version, "toolchains", "llvm", "prebuilt", host, "sysroot"])
  end

  defp resolve_driver_tab_android(mob_dir) do
    cond do
      File.exists?("priv/generated/driver_tab_android.c") ->
        Path.expand("priv/generated/driver_tab_android.c")

      true ->
        Path.join([mob_dir, "android", "jni", "driver_tab_android.c"])
    end
  end

  defp detect_erts_vsn(otp_dir) do
    case File.ls(otp_dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.starts_with?(&1, "erts-"))
        |> Enum.sort(:desc)
        |> List.first()

      _ ->
        nil
    end
  end

  defp zig_available?, do: not is_nil(System.find_executable("zig"))

  # Downloads Chaquopy's CPython distribution iff Pythonx is a dep.
  # Returns `{:ok, nil}` for projects without Pythonx so the rest of the
  # Android pipeline runs unchanged.
  defp maybe_ensure_python_android_bundle do
    if pythonx_in_project?() do
      MobDev.PythonAndroidSupport.ensure()
    else
      {:ok, nil}
    end
  end

  # Copies Chaquopy's libpython*.so + bundled OpenSSL/SQLite into the
  # user's android/app/src/main/jniLibs/<abi>/ tree so the APK packager
  # picks them up. lib-dynload + stdlib go into assets/python/ for
  # runtime extraction by the user's app on first launch.
  #
  # No-op when bundle is nil (project without Pythonx).
  #
  # NOTE: this places the Python distribution but does NOT yet
  # cross-compile libpythonx.so (the Pythonx NIF) for Android NDK.
  # Without that, Pythonx.NIF.__on_load__/0 raises at runtime. The NDK
  # cross-compile is the next piece — see python_embedding guide.
  @android_python_abis ~w(arm64-v8a x86_64)
  defp ensure_python_android_libs(nil), do: :ok

  defp ensure_python_android_libs(bundle_dir) do
    Enum.each(@android_python_abis, fn abi ->
      copy_python_jni_libs(bundle_dir, abi)
      cross_compile_libpythonx_android(abi, bundle_dir)
    end)

    generate_android_enif_keepalive()
    install_pythonx_otp_lib_android()
    copy_python_assets(bundle_dir)
    :ok
  end

  # Mirrors the iOS enif_* keep-alive table. Without it, --gc-sections
  # in the user's CMakeLists strips enif_* symbols from
  # libpython_android_test.so, and dlopen of libpythonx.so fails at
  # runtime with "cannot locate symbol enif_keep_resource".
  #
  # Generates `android/app/src/main/jni/enif_keepalive.c` with one
  # __attribute__((used)) reference per `T _enif_*` exported by
  # erl_nif.o inside the Android OTP cache's libbeam.a. The CMakeLists
  # template (in mob_new) picks it up if present.
  defp generate_android_enif_keepalive do
    otp_dir = MobDev.OtpDownloader.android_otp_dir("arm64-v8a")

    libbeam =
      Path.wildcard("#{otp_dir}/erts-*/lib/libbeam.a")
      |> List.first()

    cond do
      is_nil(libbeam) or not File.exists?(libbeam) ->
        :ok

      true ->
        # macOS BSD `ar` chokes on the Linux-format archive Mob ships
        # (entries listed as "erl_nif.o/" with trailing slash). Use the
        # NDK's llvm-ar / llvm-nm, which handle either format cleanly.
        sdk_root = MobDev.NdkVersion.sdk_root()
        ndk_version = MobDev.NdkVersion.effective()

        bin =
          Path.join([
            sdk_root || "",
            "ndk",
            ndk_version,
            "toolchains",
            "llvm",
            "prebuilt",
            android_ndk_host(),
            "bin"
          ])

        ar = Path.join(bin, "llvm-ar")
        nm = Path.join(bin, "llvm-nm")

        if File.regular?(ar) and File.regular?(nm) do
          generate_android_enif_keepalive_with(ar, nm, libbeam)
        else
          IO.puts("  ⚠  NDK llvm-ar / llvm-nm not found — skipping enif_* keep-alive table")
          :ok
        end
    end
  end

  defp generate_android_enif_keepalive_with(ar, nm, libbeam) do
    tmp = System.tmp_dir!() |> Path.join("mob_enif_extract_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    System.cmd(ar, ["x", libbeam, "erl_nif.o"], cd: tmp, stderr_to_stdout: true)
    erl_nif_o = Path.join(tmp, "erl_nif.o")

    if File.exists?(erl_nif_o) do
      {nm_out, _} = System.cmd(nm, [erl_nif_o], stderr_to_stdout: true)

      symbols =
        nm_out
        |> String.split("\n")
        |> Enum.filter(&Regex.match?(Regex.compile!(~S{\sT\senif_}), &1))
        |> Enum.map(fn line -> line |> String.split() |> List.last() end)
        |> Enum.uniq()

      out = "android/app/src/main/jni/enif_keepalive.c"
      File.mkdir_p!(Path.dirname(out))
      File.write!(out, generate_android_enif_keepalive_source(symbols))
      IO.puts("  ✓ generated #{out} (#{length(symbols)} enif_* symbols pinned)")
    end

    File.rm_rf(tmp)
    :ok
  end

  defp generate_android_enif_keepalive_source(symbols) do
    refs =
      symbols
      |> Enum.map_join("\n", fn sym ->
        "extern void #{sym}(void); __attribute__((used)) static void *_keep_#{sym} = (void *)&#{sym};"
      end)

    """
    /* Auto-generated by mob_dev/native_build.ex.
     * References every enif_* symbol exported by libbeam.a's erl_nif.o
     * so the user's CMakeLists --gc-sections doesn't strip them. Without
     * these references, dlopen of dynamic NIFs (libpythonx.so) fails at
     * runtime with "cannot locate symbol enif_*".
     *
     * Regenerated on every `mix mob.deploy --native --device <android>`.
     */
    #{refs}
    """
  end

  # Mirrors the "Installing pythonx as OTP library" step in iOS's
  # build_device.sh: places the pythonx beams + .app into
  # <otp_arm64>/lib/pythonx-VSN/ebin and copies libpythonx.so to
  # priv/, so `:code.priv_dir(:pythonx)` resolves on device once the
  # OTP runtime is pushed.
  #
  # Only the arm64-v8a NIF goes into priv/ — Mob's Android OTP cache
  # is per-cache, not per-device. x86_64 emulator support would require
  # a per-device push (TODO). Apple Silicon Macs run arm64 Android
  # emulators natively, so the arm64-only restriction is rarely felt.
  defp install_pythonx_otp_lib_android do
    pythonx_vsn = read_pythonx_version()

    if pythonx_vsn do
      otp_dir = MobDev.OtpDownloader.android_otp_dir("arm64-v8a")
      pythonx_lib_dir = Path.join([otp_dir, "lib", "pythonx-#{pythonx_vsn}"])

      File.rm_rf!(pythonx_lib_dir)
      File.mkdir_p!(Path.join(pythonx_lib_dir, "ebin"))
      File.mkdir_p!(Path.join(pythonx_lib_dir, "priv"))

      Path.wildcard("_build/dev/lib/pythonx/ebin/*.beam")
      |> Enum.each(fn src ->
        cp(src, Path.join([pythonx_lib_dir, "ebin", Path.basename(src)]))
      end)

      if File.exists?("_build/dev/lib/pythonx/ebin/pythonx.app") do
        cp(
          "_build/dev/lib/pythonx/ebin/pythonx.app",
          Path.join([pythonx_lib_dir, "ebin", "pythonx.app"])
        )
      end

      src = "android/app/src/main/jniLibs/arm64-v8a/libpythonx.so"

      if File.exists?(src) do
        cp(src, Path.join([pythonx_lib_dir, "priv", "libpythonx.so"]))
      end
    end

    :ok
  end

  defp read_pythonx_version do
    cond do
      File.exists?("_build/dev/lib/pythonx/ebin/pythonx.app") ->
        case File.read("_build/dev/lib/pythonx/ebin/pythonx.app") do
          {:ok, content} ->
            case Regex.run(Regex.compile!(~S<{vsn,\s*"([^"]+)"}>), content) do
              [_, vsn] -> vsn
              _ -> nil
            end

          _ ->
            nil
        end

      true ->
        nil
    end
  end

  # Chaquopy's arm64-v8a slice corresponds to the standard android arm64
  # OTP cache; x86_64 emulators use the same arm64 cache (Mob doesn't
  # build a separate x86_64 OTP, so the 64-bit emulator runs the arm64
  # OTP under translation).
  defp android_otp_abi("arm64-v8a"), do: "arm64-v8a"
  defp android_otp_abi("x86_64"), do: "arm64-v8a"

  # Cross-compiles Pythonx's NIF (deps/pythonx/c_src/{pythonx,python}.cpp)
  # for Android against the NDK and the Chaquopy headers. Output drops
  # into android/app/src/main/jniLibs/<abi>/libpythonx.so so the APK
  # packager picks it up alongside the OTP runtime helper libs.
  #
  # Pythonx's design — runtime dlopen+dlsym for libpython AND enif_*
  # symbols resolved by the loaded BEAM — means libpythonx.so has many
  # undefined symbols at link time. `--unresolved-symbols=ignore-all`
  # tells lld this is intentional. Apps that load the NIF via
  # `:erlang.load_nif/2` resolve enif_* against the host BEAM, and
  # Pythonx.init/4 resolves Py* against the dlopen'd libpython.so.
  defp cross_compile_libpythonx_android(abi, bundle_dir) do
    pythonx_src = "deps/pythonx/c_src"

    if File.dir?(pythonx_src) do
      ndk_version = MobDev.NdkVersion.effective()
      sdk_root = MobDev.NdkVersion.sdk_root()

      cond do
        is_nil(sdk_root) ->
          IO.puts("  ⚠  Android SDK not found — skipping libpythonx.so cross-compile")
          :ok

        not MobDev.NdkVersion.installed?(ndk_version) ->
          IO.puts("  ⚠  Android NDK #{ndk_version} not installed — skipping libpythonx.so")
          IO.puts("     Install with: #{MobDev.NdkVersion.install_command()}")
          :ok

        true ->
          do_cross_compile_libpythonx_android(abi, bundle_dir, sdk_root, ndk_version)
      end
    else
      :ok
    end
  end

  defp do_cross_compile_libpythonx_android(abi, bundle_dir, sdk_root, ndk_version) do
    triple = android_triple(abi)
    api = android_api_level()
    host = android_ndk_host()

    bin_dir =
      Path.join([sdk_root, "ndk", ndk_version, "toolchains", "llvm", "prebuilt", host, "bin"])

    clang = Path.join(bin_dir, "#{triple}#{api}-clang++")

    unless File.regular?(clang) do
      IO.puts("  ⚠  NDK clang++ not found at #{clang} — skipping libpythonx.so")
      :ok
    end

    pythonx_src = "deps/pythonx/c_src"
    fine_inc = "deps/fine/c_include"
    python_inc = MobDev.PythonAndroidSupport.headers_dir(bundle_dir, abi)

    erts_inc =
      Path.wildcard("#{MobDev.OtpDownloader.android_otp_dir()}/erts-*/include")
      |> List.first()

    out = "android/app/src/main/jniLibs/#{abi}/libpythonx.so"
    File.mkdir_p!(Path.dirname(out))

    # libpythonx.so references enif_* symbols defined by the user's
    # libpython_android_test.so (via libbeam.a, statically linked into
    # it by Gradle). For Android's loader to resolve those at dlopen
    # time, libpythonx.so needs a `NEEDED libpython_android_test.so`
    # entry — otherwise the lookup happens in the wrong namespace and
    # fails with "cannot locate symbol enif_*".
    #
    # The real lib is built by Gradle AFTER this step. We work around
    # the chicken-and-egg with a tiny stub library that exports the
    # enif_* symbols and carries SONAME=libpython_android_test.so. At
    # runtime Android resolves the NEEDED entry by SONAME match, so
    # the real lib (already loaded via System.loadLibrary) provides
    # the implementations.
    stub_so = build_libpython_android_test_stub_so(bin_dir, triple, api, abi)

    # `-l<name>` looks for `lib<name>.so` — derive `<name>` from the
    # actual stub SONAME we just built so projects whose main lib
    # isn't `libpython_android_test.so` (every real project) still
    # link. Strip the `lib` prefix and `.so` suffix.
    stub_lib_name =
      if stub_so do
        stub_so
        |> Path.basename()
        |> String.replace_prefix("lib", "")
        |> String.replace_suffix(".so", "")
      end

    # Static-link libc++ so the resulting .so doesn't depend on
    # libc++_shared.so being in the app's jniLibs/.
    # Link against the stub: gives libpythonx.so a NEEDED
    # lib<app>.so entry plus link-time symbol resolution for enif_*.
    # The stub itself is discarded after link.
    args =
      ["-shared", "-fPIC", "-fvisibility=hidden", "-std=c++17", "-Os"] ++
        ["-ffunction-sections", "-fdata-sections"] ++
        ["-static-libstdc++"] ++
        ["-I", erts_inc, "-I", "#{erts_inc}/internal"] ++
        ["-I", fine_inc, "-I", python_inc] ++
        ["-Wno-unused-parameter", "-Wno-comment"] ++
        if(stub_so, do: ["-L", Path.dirname(stub_so), "-l#{stub_lib_name}"], else: []) ++
        ["#{pythonx_src}/pythonx.cpp", "#{pythonx_src}/python.cpp"] ++
        ["-o", out]

    case System.cmd(clang, args, stderr_to_stdout: true) do
      {_, 0} ->
        IO.puts("  ✓ cross-compiled #{out}")
        if stub_so, do: File.rm_rf!(Path.dirname(stub_so))
        :ok

      {output, code} ->
        if stub_so, do: File.rm_rf!(Path.dirname(stub_so))
        IO.puts(:stderr, "  ✗ libpythonx.so cross-compile failed (exit #{code})")
        IO.puts(:stderr, output)
        {:error, "libpythonx.so cross-compile failed for #{abi}"}
    end
  end

  # Builds a tiny stub `libpython_android_test.so` (or whatever the user's
  # main lib is called, which we read from the keepalive .c we generated)
  # that exports the enif_* symbols libpythonx.so references. Link-time only;
  # the real lib provides symbols at runtime via SONAME match.
  defp build_libpython_android_test_stub_so(bin_dir, triple, api, abi) do
    cc = Path.join(bin_dir, "#{triple}#{api}-clang")
    keepalive = "android/app/src/main/jni/enif_keepalive.c"

    if File.regular?(cc) and File.exists?(keepalive) do
      build_stub_with_symbols(cc, keepalive, abi)
    end
  end

  defp build_stub_with_symbols(cc, keepalive, abi) do
    symbols =
      keepalive
      |> File.read!()
      |> String.split("\n")
      |> Enum.map(&Regex.run(Regex.compile!(~S{extern void (enif_\w+)}), &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(fn [_, name] -> name end)
      |> Enum.uniq()

    if symbols != [] do
      # Mob's main lib SONAME is `lib<app_name>.so`. Detect from the
      # generated CMakeLists' `add_library` directive.
      soname = detect_main_lib_soname() || "libpython_android_test.so"

      tmp =
        System.tmp_dir!()
        |> Path.join("mob_pythonx_stub_#{abi}_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)
      stub_c = Path.join(tmp, "stub.c")
      stub_so = Path.join(tmp, soname)

      body = Enum.map_join(symbols, "\n", fn sym -> "void #{sym}(void) {}" end)
      File.write!(stub_c, body <> "\n")

      case System.cmd(
             cc,
             ["-shared", "-fPIC", "-Wl,-soname,#{soname}", stub_c, "-o", stub_so],
             stderr_to_stdout: true
           ) do
        {_, 0} ->
          stub_so

        _ ->
          File.rm_rf!(tmp)
          nil
      end
    end
  end

  defp detect_main_lib_soname do
    case File.read("android/app/src/main/jni/CMakeLists.txt") do
      {:ok, content} ->
        case Regex.run(Regex.compile!(~S{add_library\(\s*(\S+)\s+SHARED}), content) do
          [_, name] -> "lib#{name}.so"
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp android_triple("arm64-v8a"), do: "aarch64-linux-android"
  defp android_triple("x86_64"), do: "x86_64-linux-android"

  # Match mob_new's android template `minSdk 28`. Using API 28 keeps
  # the NIF compatible with the same device floor as the rest of the
  # Mob-generated app code.
  defp android_api_level, do: "28"

  # Pre-built NDK toolchains are named for the host that runs them.
  # Mob is a macOS-first dev environment; Linux hosts use the same
  # `darwin-x86_64` directory name on Apple Silicon thanks to Rosetta.
  defp android_ndk_host do
    case :os.type() do
      {:unix, :darwin} -> "darwin-x86_64"
      {:unix, _} -> "linux-x86_64"
      _ -> "darwin-x86_64"
    end
  end

  defp copy_python_jni_libs(bundle_dir, abi) do
    src_dir = MobDev.PythonAndroidSupport.jni_libs_dir(bundle_dir, abi)
    dst_dir = "android/app/src/main/jniLibs/#{abi}"
    File.mkdir_p!(dst_dir)

    if File.dir?(src_dir) do
      Path.wildcard(Path.join(src_dir, "*.so"))
      |> Enum.each(fn src ->
        dst = Path.join(dst_dir, Path.basename(src))
        cp(src, dst)
      end)
    end

    copy_project_python_jni_libs(abi, dst_dir)

    :ok
  end

  # Project-supplied native libs that need to land in jniLibs/<abi>/
  # rather than site-packages. Wheels for cffi-using packages
  # (cryptography, etc.) reference `libffi.so` via a NEEDED entry,
  # which the Android dynamic loader resolves out of the app's
  # `nativeLibraryDir` — i.e. the jniLibs/<abi>/ contents. Putting
  # the .so under filesDir/python/ doesn't help because the loader
  # has already given up by the time Python imports happen.
  #
  # Convention: project drops <name>.so files into
  # `priv/python_jni_libs/<abi>/`. Each one is copied into
  # `android/app/src/main/jniLibs/<abi>/` verbatim. Mob doesn't try
  # to know what's inside — that's the project's call.
  defp copy_project_python_jni_libs(abi, dst_dir) do
    src_dir = Path.join(["priv", "python_jni_libs", abi])

    if File.dir?(src_dir) do
      Path.wildcard(Path.join(src_dir, "*.so"))
      |> Enum.each(fn src ->
        dst = Path.join(dst_dir, Path.basename(src))
        cp(src, dst)
      end)
    end

    :ok
  end

  # Place the (slice-independent) stdlib and per-abi lib-dynload into
  # android/app/src/main/assets/python/. The APK packager will ship
  # them as packaged assets; the user's app extracts them to internal
  # storage on first launch (see <App>.PythonPaths).
  defp copy_python_assets(bundle_dir) do
    # Extract layout follows the PYTHONHOME contract:
    #   <filesDir>/python/lib/python3.13/        ← shared pure-Python stdlib
    #   <filesDir>/python/lib/python3.13/lib-dynload/<abi>/  ← arch-specific .so
    # Mirrors iOS's <App>.app/otp/python/ layout — Python's own bootstrap
    # walks `<home>/lib/pythonX.Y` to find encodings/ etc. before sys.path
    # is even initialized.
    assets_root = "android/app/src/main/assets/python"
    File.mkdir_p!(assets_root)

    stdlib_src = MobDev.PythonAndroidSupport.stdlib_dir(bundle_dir)
    stdlib_dst = Path.join([assets_root, "lib", "python3.13"])

    if File.dir?(stdlib_src) and not File.dir?(stdlib_dst) do
      File.mkdir_p!(stdlib_dst)
      System.cmd("cp", ["-R", stdlib_src <> "/.", stdlib_dst])
    end

    Enum.each(@android_python_abis, fn abi ->
      ld_src = MobDev.PythonAndroidSupport.lib_dynload_dir(bundle_dir, abi)
      # lib-dynload nests under stdlib for Python's own discovery, but
      # we keep per-abi subdirs since we ship multiple architectures.
      ld_dst = Path.join([assets_root, "lib", "python3.13", "lib-dynload", abi])

      if File.dir?(ld_src) and not File.dir?(ld_dst) do
        File.mkdir_p!(ld_dst)
        System.cmd("cp", ["-R", ld_src <> "/.", ld_dst])
      end
    end)

    copy_project_python_wheels(assets_root)

    :ok
  end

  # Drops project-supplied Python packages from `priv/python_wheels/`
  # into the APK's `assets/python/.../site-packages/`.
  #
  # Each subdirectory of `priv/python_wheels/` is treated as an
  # already-extracted wheel — copy the directory contents directly into
  # site-packages. Wheel-extraction is the project's job (the wheel
  # format is package-specific and per-platform), but landing the
  # extracted layout into the APK is a generic step worth owning here
  # so every Mob+Pythonx project doesn't reimplement asset placement.
  #
  # Layout convention: `priv/python_wheels/<wheel-name>/` contains the
  # wheel's unzipped contents. A typical `cryptography-X.Y/` directory
  # holds `cryptography/`, `cryptography-X.Y.dist-info/`, and any
  # `*.cpython-313-android_*.so` files. Everything inside gets copied
  # verbatim — site-packages discovery handles the rest.
  defp copy_project_python_wheels(assets_root) do
    wheels_dir = Path.join("priv", "python_wheels")

    if File.dir?(wheels_dir) do
      site_packages = Path.join([assets_root, "lib", "python3.13", "site-packages"])
      File.mkdir_p!(site_packages)

      wheels_dir
      |> File.ls!()
      |> Enum.each(fn entry ->
        src = Path.join(wheels_dir, entry)

        if File.dir?(src) do
          System.cmd("cp", ["-R", src <> "/.", site_packages])
        end
      end)
    end

    :ok
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

  defp adb_install_all(apk, bundle_id, device_id) do
    case System.cmd("adb", ["devices"], stderr_to_stdout: true) do
      {output, 0} ->
        serials =
          output
          |> String.split("\n")
          |> Enum.drop(1)
          |> Enum.filter(&String.contains?(&1, "\tdevice"))
          |> Enum.map(&hd(String.split(&1, "\t")))
          |> filter_serials(device_id)

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

  defp push_otp_release_android(bundle_id, elixir_lib, otp_arm64, otp_arm32, device_id) do
    app_data = "/data/data/#{bundle_id}/files"

    IO.puts("  Pushing OTP release to device(s)...")

    case System.cmd("adb", ["devices"], stderr_to_stdout: true) do
      {output, 0} ->
        serials = parse_adb_serials(output) |> filter_serials(device_id)
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

  # Filters a list of adb serials by `--device <id>`. The id is matched against
  # the serial directly, against an `IP:port` form (auto-strip `:5555`), and
  # against a bare IP for WiFi-adb devices. Returns all serials when device_id
  # is nil. Returns empty + warning if device_id matches no connected serial.
  @doc false
  @spec filter_serials([String.t()], String.t() | nil) :: [String.t()]
  def filter_serials(serials, nil), do: serials

  def filter_serials(serials, id) when is_binary(id) do
    matches =
      Enum.filter(serials, fn s ->
        s == id or s == "#{id}:5555" or strip_port(s) == id
      end)

    if matches == [] do
      IO.puts(
        "  #{IO.ANSI.yellow()}⚠  --device #{id} matched no connected adb device — skipping#{IO.ANSI.reset()}"
      )
    end

    matches
  end

  defp strip_port(s) do
    case String.split(s, ":", parts: 2) do
      [host, _port] -> host
      _ -> s
    end
  end

  # ── iOS ──────────────────────────────────────────────────────────────────────

  defp build_ios(cfg, device_id) do
    with :ok <- check_path(cfg[:mob_dir], "mob_dir"),
         :ok <- check_path(cfg[:elixir_lib], "elixir_lib"),
         {:ok, otp_root} <- MobDev.OtpDownloader.ensure_ios_sim(),
         {:ok, python_bundle} <- maybe_ensure_python_bundle() do
      IO.puts("  Building iOS simulator app...")

      mob_dir = Path.expand(cfg[:mob_dir])
      elixir_lib = Path.expand(cfg[:elixir_lib])
      app_module = Mix.Project.config() |> Keyword.fetch!(:app) |> Atom.to_string()
      display_name = ios_display_name()
      erts_vsn = detect_erts_vsn(otp_root)

      with {:ok, sdkroot} <- xcrun_sdk_path("iphonesimulator"),
           :ok <- compile_elixir_for_ios(),
           :ok <- copy_app_beams(otp_root, app_module),
           :ok <- install_exqlite_otp_lib(otp_root),
           :ok <- cross_compile_exqlite_nif_sim(otp_root, erts_vsn, sdkroot),
           :ok <- maybe_setup_pythonx_sim(otp_root, erts_vsn, sdkroot, python_bundle, app_module),
           :ok <- maybe_install_crypto_shim(otp_root, app_module),
           :ok <- maybe_copy_ssl_beams(otp_root, app_module),
           :ok <- maybe_build_phoenix_assets(otp_root, app_module),
           :ok <- copy_priv_repo_assets(otp_root, app_module),
           :ok <- copy_elixir_stdlib_to_otp(elixir_lib, otp_root),
           :ok <- copy_eex_stdlib_to_app(elixir_lib, otp_root, app_module),
           :ok <- sync_otp_runtime_sim(otp_root),
           :ok <- copy_mob_logos_sim(mob_dir, otp_root),
           :ok <- spot_check_app_beams(otp_root, app_module, display_name),
           {:ok, build_dir} <- create_native_build_dir("ios_sim"),
           :ok <- generate_enif_keepalive(otp_root, erts_vsn, build_dir),
           :ok <-
             zig_build_binary_ios_sim(
               mob_dir,
               otp_root,
               erts_vsn,
               sdkroot,
               build_dir,
               display_name
             ),
           {:ok, sim_id} <- pick_ios_sim(device_id),
           binary_path = "ios/zig-out/#{display_name}",
           :ok <- check_path(binary_path, "iOS binary"),
           {:ok, app_path} <- bundle_ios_app(binary_path, display_name),
           :ok <- install_ios_sim(sim_id, app_path) do
        {:ok, "iOS"}
      else
        {:error, reason} -> {:error, "iOS", reason}
      end
    else
      {:error, reason} -> {:error, "iOS", reason}
    end
  end

  # Phase 2 iter 13b: iOS sim build pipeline ported out of build.sh.
  # Each helper mirrors a section of the prior shell script.

  defp xcrun_sdk_path(sdk) do
    case System.cmd("xcrun", ["-sdk", sdk, "--show-sdk-path"], stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      {_, _} -> {:error, "xcrun -sdk #{sdk} --show-sdk-path failed — Xcode CLT installed?"}
    end
  end

  defp compile_elixir_for_ios do
    # Tells `mix compile` we're building for iOS so any `unless
    # System.get_env("MOB_TARGET") == "ios" do …` compile-time gates short-circuit.
    System.put_env("MOB_TARGET", "ios")
    Mix.Task.run("compile")
    :ok
  end

  defp copy_app_beams(otp_root, app_module) do
    beams_dir = Path.join(otp_root, app_module)
    File.mkdir_p!(beams_dir)
    chmod_writable(beams_dir)

    # Glob every compiled dep's ebin dir — covers vanilla (mob + ecto +
    # ecto_sqlite3 + decimal + telemetry + jason + nimble_parsec) AND
    # LiveView (Phoenix + Plug + Bandit + thousand_island + websock + etc.)
    # without having to maintain a hardcoded dep list.
    Path.wildcard("_build/dev/lib/*/ebin/*")
    |> Enum.each(fn src ->
      File.cp!(src, Path.join(beams_dir, Path.basename(src)))
    end)

    :ok
  end

  defp liveview_project? do
    # Treat as LV iff the project has its own Phoenix asset pipeline
    # (`assets/` at project root with package.json or tailwind config).
    # Just having phoenix_live_view as a transitive dep (via mob) doesn't
    # qualify — vanilla mob apps pull it in but have no `assets/` dir and
    # no `mix assets.build` task. Without this guard, `Mix.Task.run("assets.build")`
    # raises on vanilla projects.
    File.exists?("assets/tailwind.config.js") or
      File.exists?("assets/package.json") or
      File.exists?("assets/css/app.css")
  end

  defp chmod_writable(dir) do
    _ = System.cmd("chmod", ["-R", "u+w", dir], stderr_to_stdout: true)
    :ok
  end

  defp install_exqlite_otp_lib(otp_root) do
    case detect_dep_version("exqlite") do
      nil ->
        :ok

      vsn ->
        IO.puts("  === Installing exqlite as OTP library")
        lib_dir = Path.join([otp_root, "lib", "exqlite-#{vsn}"])
        # Remove any previous broken empty-version dir from older builds.
        File.rm_rf!(Path.join(otp_root, "lib/exqlite-"))
        File.mkdir_p!(Path.join(lib_dir, "ebin"))
        File.mkdir_p!(Path.join(lib_dir, "priv"))

        ebin = Path.join(["_build", "dev", "lib", "exqlite", "ebin"])

        Path.wildcard("#{ebin}/*.beam")
        |> Enum.each(&File.cp!(&1, Path.join([lib_dir, "ebin", Path.basename(&1)])))

        File.cp!(Path.join(ebin, "exqlite.app"), Path.join([lib_dir, "ebin", "exqlite.app"]))
        :ok
    end
  end

  defp cross_compile_exqlite_nif_sim(otp_root, erts_vsn, sdkroot) do
    if File.dir?("deps/exqlite/c_src") do
      vsn = detect_dep_version("exqlite")
      out_so = Path.join([otp_root, "lib/exqlite-#{vsn}/priv/sqlite3_nif.so"])
      IO.puts("  === Cross-compiling sqlite3_nif.so for iOS simulator")

      # The macOS-compiled NIF from `mix deps.compile` is incompatible with
      # the iOS sim (wrong platform tag). Recompile against iphonesimulator
      # SDK so dlopen succeeds inside the simulator process.
      args = [
        "-sdk",
        "iphonesimulator",
        "cc",
        "-arch",
        "arm64",
        "-mios-simulator-version-min=17.0",
        "-isysroot",
        sdkroot,
        "-Os",
        "-ffunction-sections",
        "-fdata-sections",
        "-dynamiclib",
        "-undefined",
        "dynamic_lookup",
        "-I",
        "deps/exqlite/c_src",
        "-I",
        "#{otp_root}/#{erts_vsn}/include",
        "-I",
        "#{otp_root}/#{erts_vsn}/include/aarch64-apple-iossimulator",
        "-DSQLITE_THREADSAFE=1",
        "-Wno-#warnings",
        "deps/exqlite/c_src/sqlite3_nif.c",
        "deps/exqlite/c_src/sqlite3.c",
        "-o",
        out_so
      ]

      case System.cmd("xcrun", args, stderr_to_stdout: true, into: IO.stream()) do
        {_, 0} -> :ok
        {_, _} -> {:error, "exqlite NIF cross-compile failed for iOS sim"}
      end
    else
      :ok
    end
  end

  defp maybe_setup_pythonx_sim(_otp_root, _erts_vsn, _sdkroot, nil, _app_module), do: :ok

  defp maybe_setup_pythonx_sim(otp_root, erts_vsn, sdkroot, python_bundle, app_module) do
    if File.dir?("_build/dev/lib/pythonx") do
      vsn = detect_dep_version("pythonx")
      lib_dir = Path.join([otp_root, "lib", "pythonx-#{vsn}"])
      beams_dir = Path.join(otp_root, app_module)

      IO.puts("  === Installing pythonx as OTP library")
      # Wipe any previous version
      Path.wildcard(Path.join(otp_root, "lib/pythonx-*")) |> Enum.each(&File.rm_rf!/1)
      File.mkdir_p!(Path.join(lib_dir, "ebin"))
      File.mkdir_p!(Path.join(lib_dir, "priv"))

      ebin = "_build/dev/lib/pythonx/ebin"

      Path.wildcard("#{ebin}/*.beam")
      |> Enum.each(&File.cp!(&1, Path.join([lib_dir, "ebin", Path.basename(&1)])))

      File.cp!(Path.join(ebin, "pythonx.app"), Path.join([lib_dir, "ebin", "pythonx.app"]))

      Path.wildcard("#{ebin}/*")
      |> Enum.each(&File.cp!(&1, Path.join(beams_dir, Path.basename(&1))))

      if File.dir?("_build/dev/lib/fine") do
        Path.wildcard("_build/dev/lib/fine/ebin/*")
        |> Enum.each(&File.cp!(&1, Path.join(beams_dir, Path.basename(&1))))
      end

      python_framework =
        Path.join([
          python_bundle,
          "Python.xcframework/ios-arm64_x86_64-simulator/Python.framework"
        ])

      python_stdlib = Path.join([python_bundle, "Python.xcframework/lib/python3.13"])

      python_lib_dynload =
        Path.join([
          python_bundle,
          "Python.xcframework/ios-arm64_x86_64-simulator/lib-arm64/python3.13/lib-dynload"
        ])

      cond do
        not File.dir?(python_framework) ->
          {:error, "Python.framework missing at #{python_framework}"}

        not File.dir?(python_stdlib) ->
          {:error, "Python stdlib missing at #{python_stdlib}"}

        not File.dir?(python_lib_dynload) ->
          {:error, "lib-dynload missing at #{python_lib_dynload}"}

        true ->
          IO.puts("  === Cross-compiling libpythonx.so for iOS simulator")

          xcrun_args = [
            "-sdk",
            "iphonesimulator",
            "clang++",
            "-arch",
            "arm64",
            "-dynamiclib",
            "-undefined",
            "dynamic_lookup",
            "-fPIC",
            "-fvisibility=hidden",
            "-std=c++17",
            "-isysroot",
            sdkroot,
            "-mios-simulator-version-min=17.0",
            "-install_name",
            "@rpath/libpythonx.so",
            "-Os",
            "-ffunction-sections",
            "-fdata-sections",
            "-I",
            "#{otp_root}/#{erts_vsn}/include",
            "-I",
            "#{otp_root}/#{erts_vsn}/include/aarch64-apple-iossimulator",
            "-I",
            "deps/fine/c_include",
            "-Wno-unused-parameter",
            "-Wno-comment",
            "deps/pythonx/c_src/pythonx.cpp",
            "deps/pythonx/c_src/python.cpp",
            "-o",
            Path.join(lib_dir, "priv/libpythonx.so")
          ]

          case System.cmd("xcrun", xcrun_args, stderr_to_stdout: true, into: IO.stream()) do
            {_, 0} ->
              IO.puts("  === Bundling Python.framework + stdlib + lib-dynload (sim slice)")
              python_dir = Path.join(otp_root, "python")
              File.mkdir_p!(Path.join(python_dir, "lib"))
              chmod_writable(python_dir)

              File.rm_rf!(Path.join(python_dir, "Python.framework"))
              File.rm_rf!(Path.join(python_dir, "lib/python3.13"))

              copy_dir!(python_framework, Path.join(python_dir, "Python.framework"))
              copy_dir!(python_stdlib, Path.join(python_dir, "lib/python3.13"))
              copy_dir!(python_lib_dynload, Path.join(python_dir, "lib/python3.13/lib-dynload"))
              :ok

            {_, _} ->
              {:error, "pythonx NIF cross-compile failed"}
          end
      end
    else
      :ok
    end
  end

  defp copy_dir!(src, dst) do
    {_, 0} = System.cmd("cp", ["-R", src, dst], stderr_to_stdout: true)
    :ok
  end

  defp detect_dep_version(name) do
    # Try mix.lock first; fall back to .app file's vsn.
    lock_match =
      case File.read("mix.lock") do
        {:ok, content} ->
          Regex.run(~r/"#{name}"[^"]*"([0-9]+\.[0-9]+\.[0-9]+)"/, content)

        _ ->
          nil
      end

    case lock_match do
      [_, vsn] ->
        vsn

      _ ->
        app_file = "_build/dev/lib/#{name}/ebin/#{name}.app"

        case File.read(app_file) do
          {:ok, content} ->
            case Regex.run(~r/\{vsn,\s*"([^"]+)"\}/, content) do
              [_, vsn] -> vsn
              _ -> nil
            end

          _ ->
            nil
        end
    end
  end

  defp maybe_install_crypto_shim(otp_root, app_module) do
    if liveview_project?() do
      # The iOS OTP build does not include OpenSSL/crypto. Phoenix and
      # plug_crypto declare :crypto as a required application; without a
      # shim, application:ensure_started(:crypto) fails and the app won't
      # boot. The shim implements the subset of crypto functions
      # plug_crypto + Plug.CSRFProtection actually call in the loopback
      # HTTP-only path: pbkdf2_hmac/5 (KeyGenerator), exor/2 (CSRF token
      # masking), mac/3+/4 (HMAC-MD5 via erlang:md5/1), and start/2.
      IO.puts("  === Creating crypto shim (LV)")

      crypto_tmp =
        Path.join(System.tmp_dir!(), "mob_crypto_#{System.unique_integer([:positive])}")

      File.mkdir_p!(crypto_tmp)
      beams_dir = Path.join(otp_root, app_module)

      try do
        File.write!(Path.join(crypto_tmp, "crypto.erl"), crypto_shim_erl())

        case System.cmd("erlc", ["-o", beams_dir, Path.join(crypto_tmp, "crypto.erl")],
               stderr_to_stdout: true,
               into: IO.stream()
             ) do
          {_, 0} ->
            File.write!(Path.join(beams_dir, "crypto.app"), crypto_shim_app())
            :ok

          {_, _} ->
            {:error, "crypto shim erlc failed"}
        end
      after
        File.rm_rf!(crypto_tmp)
      end
    else
      :ok
    end
  end

  defp crypto_shim_erl do
    """
    -module(crypto).
    -behaviour(application).
    -export([start/2, stop/1, strong_rand_bytes/1, rand_bytes/1,
             hash/2, mac/4, mac/3, supports/1, exor/2,
             generate_key/2, compute_key/4, sign/4, verify/5,
             pbkdf2_hmac/5]).
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
    exor(A, B) -> xor_bytes(iolist_to_binary(A), iolist_to_binary(B)).
    mac(hmac, _HashAlg, Key, Data) ->
        hmac_md5(iolist_to_binary(Key), iolist_to_binary(Data));
    mac(_Type, _SubType, _Key, _Data) -> <<>>.
    mac(_Type, _Key, _Data) -> <<>>.
    pbkdf2_hmac(_DigestType, Password, Salt, Iterations, DerivedKeyLen) ->
        Pwd = iolist_to_binary(Password),
        S   = iolist_to_binary(Salt),
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
    xor_bytes(A, B) -> xor_bytes(A, B, []).
    xor_bytes(<<X, Ra/binary>>, <<Y, Rb/binary>>, Acc) ->
        xor_bytes(Ra, Rb, [X bxor Y | Acc]);
    xor_bytes(<<>>, <<>>, Acc) ->
        list_to_binary(lists:reverse(Acc)).
    """
  end

  defp crypto_shim_app do
    ~S|{application,crypto,[{modules,[crypto]},{applications,[kernel,stdlib]},{description,"Crypto shim for iOS (HTTP-only; no OpenSSL)"},{registered,[]},{vsn,"5.6"},{mod,{crypto,[]}}]}.| <>
      "\n"
  end

  defp maybe_copy_ssl_beams(otp_root, app_module) do
    if liveview_project?() do
      # thousand_island lists :ssl as a required app. Pure Erlang — host
      # macOS .beam files run unchanged on iOS sim. We grab the latest
      # available ssl-* dir from the host OTP install.
      home = System.get_env("HOME") || ""
      host_ssl_dirs = Path.wildcard(home <> "/.local/share/mise/installs/erlang/*/lib/ssl-*")
      latest_ssl = host_ssl_dirs |> Enum.sort(:desc) |> List.first()

      case latest_ssl do
        nil ->
          IO.puts("  === ssl beams not found in host OTP -- thousand_island may fail to start")
          :ok

        host_ssl ->
          IO.puts("  === Copying ssl beams from host OTP")
          beams_dir = Path.join(otp_root, app_module)
          ebin = Path.join(host_ssl, "ebin")

          if File.dir?(ebin) do
            Path.wildcard("#{ebin}/*.beam")
            |> Enum.each(&File.cp!(&1, Path.join(beams_dir, Path.basename(&1))))

            ssl_app = Path.join(ebin, "ssl.app")
            if File.exists?(ssl_app), do: File.cp!(ssl_app, Path.join(beams_dir, "ssl.app"))
            IO.puts("  * ssl copied from #{host_ssl}")
          end

          :ok
      end
    else
      :ok
    end
  end

  defp maybe_build_phoenix_assets(otp_root, app_module) do
    if liveview_project?() do
      IO.puts("  === Building Phoenix static assets")
      Mix.Task.run("assets.build")

      beams_dir = Path.join(otp_root, app_module)
      static_src = "priv/static"

      if File.dir?(static_src) do
        static_dst = Path.join(beams_dir, "priv/static")
        File.mkdir_p!(static_dst)
        copy_dir!(static_src <> "/.", static_dst)
      end
    end

    :ok
  end

  defp copy_priv_repo_assets(otp_root, app_module) do
    src = "priv/repo/migrations"

    if File.dir?(src) do
      IO.puts("  === Copying priv/repo assets")
      dst = Path.join([otp_root, app_module, "priv/repo/migrations"])
      File.mkdir_p!(dst)

      Path.wildcard("#{src}/*.exs")
      |> Enum.each(&File.cp!(&1, Path.join(dst, Path.basename(&1))))
    end

    :ok
  end

  defp copy_elixir_stdlib_to_otp(elixir_lib, otp_root) do
    IO.puts("  === Copying Elixir stdlib")

    for app <- ~w(elixir logger) do
      dst = Path.join([otp_root, "lib", app, "ebin"])
      File.mkdir_p!(dst)
      chmod_writable(dst)

      src_ebin = Path.join([elixir_lib, app, "ebin"])

      if File.dir?(src_ebin) do
        Path.wildcard("#{src_ebin}/*.beam")
        |> Enum.each(&File.cp!(&1, Path.join(dst, Path.basename(&1))))

        app_file = Path.join(src_ebin, "#{app}.app")

        if File.exists?(app_file),
          do: File.cp!(app_file, Path.join(dst, "#{app}.app"))
      end
    end

    :ok
  end

  defp copy_eex_stdlib_to_app(elixir_lib, otp_root, app_module) do
    # EEx is part of Elixir but mob_beam.m doesn't add it to the code path.
    # Drop it into BEAMS_DIR (flat) so code:where_is_file("eex.app") resolves
    # — Ecto's startup needs it.
    IO.puts("  === Copying EEx stdlib")
    dst = Path.join(otp_root, app_module)
    File.mkdir_p!(dst)
    src_ebin = Path.join([elixir_lib, "eex", "ebin"])

    if File.dir?(src_ebin) do
      Path.wildcard("#{src_ebin}/*.beam")
      |> Enum.each(&File.cp!(&1, Path.join(dst, Path.basename(&1))))

      app_file = Path.join(src_ebin, "eex.app")
      if File.exists?(app_file), do: File.cp!(app_file, Path.join(dst, "eex.app"))
    end

    :ok
  end

  defp sync_otp_runtime_sim(otp_root) do
    runtime_dir = System.get_env("MOB_SIM_RUNTIME_DIR") || Path.expand("~/.mob/runtime/ios-sim")
    IO.puts("  === Syncing OTP runtime to #{runtime_dir}")
    File.mkdir_p!(runtime_dir)
    chmod_writable(runtime_dir)

    # --no-perms is essential on Nix systems where ELIXIR_LIB lives in
    # /nix/store at mode 444 — without it, BSD cp's preserved-mode would
    # leave 444 .beam files in OTP_ROOT, which then carry over into
    # RUNTIME_DIR and break the next deploy's overwrite.
    {_, status} =
      System.cmd("rsync", ["-a", "--delete", "--no-perms", "#{otp_root}/", "#{runtime_dir}/"],
        stderr_to_stdout: true,
        into: IO.stream()
      )

    chmod_writable(runtime_dir)
    if status == 0, do: :ok, else: {:error, "rsync to #{runtime_dir} failed"}
  end

  defp copy_mob_logos_sim(mob_dir, otp_root) do
    runtime_dir = System.get_env("MOB_SIM_RUNTIME_DIR") || Path.expand("~/.mob/runtime/ios-sim")
    IO.puts("  === Copying Mob logos")

    for variant <- ~w(dark light) do
      src = Path.join(mob_dir, "assets/logo/logo_#{variant}.png")
      dst = Path.join(runtime_dir, "mob_logo_#{variant}.png")
      if File.exists?(src), do: File.cp!(src, dst)
    end

    _ = otp_root
    :ok
  end

  defp spot_check_app_beams(otp_root, app_module, display_name) do
    IO.puts("  === Spot-check")
    beams_dir = Path.join(otp_root, app_module)

    candidates = [
      "Elixir.#{display_name}.App.beam",
      "Elixir.#{display_name}.HomeScreen.beam"
    ]

    Enum.each(candidates, fn beam ->
      path = Path.join(beams_dir, beam)
      if File.exists?(path), do: IO.puts("  ✓ #{path}")
    end)

    :ok
  end

  defp create_native_build_dir(suffix) do
    dir = Path.join(System.tmp_dir!(), "mob_#{suffix}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    {:ok, dir}
  end

  defp generate_enif_keepalive(otp_root, erts_vsn, build_dir) do
    # Pull every `T _enif_*` symbol out of erl_nif.o inside libbeam.a and
    # generate a __attribute__((used)) reference for each. -dead_strip on
    # the final link otherwise drops them, and runtime dlopen of dynamic
    # NIFs (libpythonx.so etc.) fails with "symbol not found in flat
    # namespace '_enif_is_pid'".
    IO.puts("  === Generating enif_* keep-alive table")
    libbeam = Path.join([otp_root, erts_vsn, "lib/libbeam.a"])
    nif_o_dir = Path.join(System.tmp_dir!(), "mob_nifo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(nif_o_dir)

    try do
      ar = ar_path()

      # Try the GNU ar --output flag first, fall back to BSD ar (extracts to cwd).
      _ =
        case System.cmd(ar, ["x", libbeam, "--output=#{nif_o_dir}", "erl_nif.o"],
               stderr_to_stdout: true
             ) do
          {_, 0} ->
            :ok

          _ ->
            {_, 0} =
              System.cmd(ar, ["x", libbeam, "erl_nif.o"], cd: nif_o_dir, stderr_to_stdout: true)

            :ok
        end

      erl_nif_o = Path.join(nif_o_dir, "erl_nif.o")
      if not File.exists?(erl_nif_o), do: throw({:error, "ar x failed to extract erl_nif.o"})

      {nm_out, 0} =
        System.cmd("xcrun", ["nm", "-arch", "arm64", erl_nif_o], stderr_to_stdout: true)

      symbols =
        nm_out
        |> String.split("\n")
        |> Enum.flat_map(fn line ->
          case Regex.run(~r/ T _(enif_\w+)$/, line) do
            [_, sym] -> [sym]
            _ -> []
          end
        end)
        |> Enum.uniq()

      content =
        [
          "/* Auto-generated. References every enif_* in erl_nif.o so dead_strip keeps them. */\n"
          | Enum.map(symbols, fn sym ->
              "extern void #{sym}(void); __attribute__((used)) static void *_keep_#{sym} = (void *)&#{sym};\n"
            end)
        ]

      File.write!(Path.join(build_dir, "enif_keepalive.c"), content)
      IO.puts("  #{length(symbols)} enif_* symbols pinned")
      :ok
    after
      File.rm_rf!(nif_o_dir)
    end
  end

  defp ar_path do
    case System.cmd("xcrun", ["-find", "ar"], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> "ar"
    end
  end

  defp zig_build_binary_ios_sim(mob_dir, otp_root, erts_vsn, sdkroot, build_dir, display_name) do
    driver_tab =
      cond do
        File.exists?("priv/generated/driver_tab_ios.c") ->
          Path.expand("priv/generated/driver_tab_ios.c")

        true ->
          Path.join([mob_dir, "ios", "driver_tab_ios.c"])
      end

    args = [
      "build",
      "binary",
      "--build-file",
      "ios/build.zig",
      "-Dmob_dir=#{mob_dir}",
      "-Dotp_root=#{otp_root}",
      "-Derts_vsn=#{erts_vsn}",
      "-Dsdkroot=#{sdkroot}",
      "-Ddriver_tab=#{driver_tab}",
      "-Denif_keepalive=#{Path.join(build_dir, "enif_keepalive.c")}",
      "-Dproject_ios_dir=#{Path.expand("ios")}",
      "-Dmodule_name=#{display_name}"
    ]

    case System.cmd("zig", args, stderr_to_stdout: true, into: IO.stream()) do
      {_, 0} -> :ok
      {_, code} -> {:error, "zig build binary (iOS sim) exited #{code}"}
    end
  end

  # Phase 2 iter 6: Bundle assembly + simctl install moved out of build.sh.
  # The shell script now ends after `zig build binary`; everything below
  # used to live as the `# ── Bundle + install ──` block in ios/build.sh.eex.

  defp ios_display_name do
    Mix.Project.config()
    |> Keyword.fetch!(:app)
    |> Atom.to_string()
    |> Macro.camelize()
  end

  defp pick_ios_sim(device_id) when is_binary(device_id), do: {:ok, device_id}

  defp pick_ios_sim(nil) do
    case System.cmd("xcrun", ~w(simctl list devices booted -j), stderr_to_stdout: true) do
      {json, 0} ->
        with {:ok, %{"devices" => by_runtime}} <- Jason.decode(json),
             udid when is_binary(udid) <- find_booted_udid(by_runtime) do
          {:ok, udid}
        else
          _ ->
            {:error, "No booted simulator. Boot one in Simulator.app or pass `--device <UDID>`."}
        end

      _ ->
        {:error, "xcrun simctl list failed — is Xcode installed?"}
    end
  end

  defp find_booted_udid(by_runtime) do
    by_runtime
    |> Map.values()
    |> List.flatten()
    |> Enum.find_value(fn
      %{"state" => "Booted", "udid" => udid} -> udid
      _ -> nil
    end)
  end

  defp bundle_ios_app(binary_path, display_name) do
    build_dir =
      Path.join(System.tmp_dir!(), "mob_ios_bundle_#{System.unique_integer([:positive])}")

    File.mkdir_p!(build_dir)
    app_path = Path.join(build_dir, "#{display_name}.app")
    File.rm_rf!(app_path)
    File.mkdir_p!(app_path)

    IO.puts("  Building .app bundle at #{app_path}...")
    File.cp!(binary_path, Path.join(app_path, display_name))

    cond do
      not File.exists?("ios/Info.plist") ->
        {:error, "ios/Info.plist not found — required for the .app bundle"}

      true ->
        File.cp!("ios/Info.plist", Path.join(app_path, "Info.plist"))
        if File.dir?("ios/Assets.xcassets/AppIcon.appiconset"), do: compile_ios_icons(app_path)
        {:ok, app_path}
    end
  end

  defp compile_ios_icons(app_path) do
    actool_plist =
      Path.join(System.tmp_dir!(), "mob_actool_#{System.unique_integer([:positive])}.plist")

    # actool can be flaky and is non-critical (the binary still runs without
    # icons compiled — just shows the system default). Mirror the build.sh
    # `2>/dev/null || true` posture so a broken Assets.xcassets doesn't kill
    # an otherwise-successful native build.
    case System.cmd(
           "xcrun",
           [
             "actool",
             "ios/Assets.xcassets",
             "--compile",
             app_path,
             "--platform",
             "iphonesimulator",
             "--minimum-deployment-target",
             "17.0",
             "--app-icon",
             "AppIcon",
             "--output-partial-info-plist",
             actool_plist
           ],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        _ =
          System.cmd(
            "/usr/libexec/PlistBuddy",
            [
              "-c",
              "Merge #{actool_plist}",
              Path.join(app_path, "Info.plist")
            ],
            stderr_to_stdout: true
          )

      _ ->
        :ok
    end

    File.rm(actool_plist)
  end

  defp install_ios_sim(sim_id, app_path) do
    IO.puts("  Installing on simulator #{sim_id}...")

    case System.cmd("xcrun", ["simctl", "install", sim_id, app_path],
           stderr_to_stdout: true,
           into: IO.stream()
         ) do
      {_, 0} -> :ok
      {_, _} -> {:error, "xcrun simctl install failed — check output above"}
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
  #   ios_epmd_build_src — path to an OTP tree that exposes EPMD source under
  #                        erts/epmd/src/ and iOS headers under erts/include/.
  #                        Defaults to the iOS-device OTP cache, which ships
  #                        these files starting with the post-(c) tarball.
  defp build_ios_physical(cfg, udid) do
    IO.puts("  Building iOS app for physical device #{udid}...")

    with {:ok, cfg} <- check_device_signing_config(cfg),
         {:ok, otp_root} <- MobDev.OtpDownloader.ensure_ios_device(),
         {:ok, python_bundle} <- maybe_ensure_python_bundle() do
      script = generate_build_device_sh(cfg, otp_root)
      script_path = "ios/build_device.sh"
      File.write!(script_path, script)
      File.chmod!(script_path, 0o755)

      build_dir =
        Path.join(System.tmp_dir!(), "mob_ios_device_#{System.unique_integer([:positive])}")

      File.mkdir_p!(build_dir)

      env = [{"MOB_BUILD_DIR", build_dir} | build_device_env(cfg, otp_root, python_bundle)]

      with {_, 0} <-
             System.cmd("bash", [script_path, udid],
               env: env,
               stderr_to_stdout: true,
               into: IO.stream()
             ),
           app_name = ios_display_name(),
           binary_path = Path.join(build_dir, app_name),
           :ok <- check_path(binary_path, "iOS device binary"),
           {:ok, app_path} <- bundle_ios_device_app(binary_path, otp_root, cfg, build_dir),
           :ok <- maybe_slim_otp_bundle(app_path, cfg),
           :ok <- embed_provisioning_profile(app_path, cfg[:ios_profile_uuid]),
           :ok <- codesign_ios_device_app(app_path, cfg, build_dir),
           :ok <- devicectl_install(udid, app_path) do
        {:ok, "iOS (device)"}
      else
        {:error, reason} ->
          {:error, "iOS", reason}

        {_, exit_code} when is_integer(exit_code) ->
          {:error, "iOS", "build_device.sh exited #{exit_code} — check output above"}
      end
    else
      {:error, reason} -> {:error, "iOS", reason}
    end
  end

  # Phase 2 iter 12d: bundle + codesign + devicectl install moved out of
  # build_device.sh. The shell script now ends after `zig build binary`
  # produces the Mach-O at MOB_BUILD_DIR/<app_name>; everything below used
  # to live as the `# ── Bundle / Code signing / Installing ──` blocks.

  defp bundle_ios_device_app(binary_path, otp_root, cfg, build_dir) do
    app_name = ios_display_name()
    app_module = Mix.Project.config() |> Keyword.fetch!(:app) |> Atom.to_string()
    bundle_id = cfg[:ios_bundle_id] || cfg[:bundle_id]

    if is_nil(bundle_id), do: throw_bundle_id_error()

    erts_vsn = detect_erts_vsn(otp_root) || "erts-17.0"
    app_path = Path.join(build_dir, "#{app_name}.app")

    IO.puts("  === Building .app bundle at #{app_path}")
    File.rm_rf!(app_path)
    File.mkdir_p!(app_path)
    File.cp!(binary_path, Path.join(app_path, app_name))

    cond do
      not File.exists?("ios/Info.plist") ->
        {:error, "ios/Info.plist not found"}

      true ->
        info_plist = Path.join(app_path, "Info.plist")
        File.cp!("ios/Info.plist", info_plist)
        plist_set!(info_plist, ":CFBundleIdentifier", bundle_id)
        plist_set!(info_plist, ":CFBundleExecutable", app_name)
        plist_set!(info_plist, ":CFBundleName", app_name)

        if File.dir?("ios/Assets.xcassets/AppIcon.appiconset"),
          do: compile_ios_device_icons(app_path)

        bundle_otp_runtime(app_path, otp_root, app_module, erts_vsn)
        {:ok, app_path}
    end
  end

  defp plist_set!(plist, key, value) do
    {_, 0} =
      System.cmd("/usr/libexec/PlistBuddy", ["-c", "Set #{key} #{value}", plist],
        stderr_to_stdout: true
      )

    :ok
  end

  defp compile_ios_device_icons(app_path) do
    actool_plist =
      Path.join(System.tmp_dir!(), "mob_actool_#{System.unique_integer([:positive])}.plist")

    case System.cmd(
           "xcrun",
           [
             "actool",
             "ios/Assets.xcassets",
             "--compile",
             app_path,
             "--platform",
             "iphoneos",
             "--minimum-deployment-target",
             "17.0",
             "--app-icon",
             "AppIcon",
             "--output-partial-info-plist",
             actool_plist
           ],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        _ =
          System.cmd(
            "/usr/libexec/PlistBuddy",
            [
              "-c",
              "Merge #{actool_plist}",
              Path.join(app_path, "Info.plist")
            ],
            stderr_to_stdout: true
          )

      _ ->
        :ok
    end

    File.rm(actool_plist)
  end

  defp bundle_otp_runtime(app_path, otp_root, app_module, erts_vsn) do
    IO.puts("  === Bundling OTP runtime inside .app")
    otp_bundle = Path.join(app_path, "otp")
    File.mkdir_p!(otp_bundle)

    rsync_dir!(Path.join(otp_root, "lib") <> "/", Path.join(otp_bundle, "lib") <> "/")
    rsync_dir!(Path.join(otp_root, "releases") <> "/", Path.join(otp_bundle, "releases") <> "/")
    rsync_dir!(Path.join(otp_root, app_module) <> "/", Path.join(otp_bundle, app_module) <> "/")

    python_src = Path.join(otp_root, "python")

    if File.dir?(python_src),
      do: rsync_dir!(python_src <> "/", Path.join(otp_bundle, "python") <> "/")

    for ext <- ["png", "jpg"] do
      Path.wildcard("#{otp_root}/*.#{ext}")
      |> Enum.each(&File.cp!(&1, Path.join(otp_bundle, Path.basename(&1))))
    end

    File.mkdir_p!(Path.join([otp_bundle, erts_vsn, "bin"]))

    {size, _} = System.cmd("du", ["-sh", otp_bundle])
    IO.puts("  OTP bundle: #{size |> String.split() |> List.first()}")
    :ok
  end

  defp rsync_dir!(src, dst) do
    {_, 0} =
      System.cmd("rsync", ["-a", "--delete", src, dst], stderr_to_stdout: true, into: IO.stream())

    :ok
  end

  defp maybe_slim_otp_bundle(app_path, _cfg) do
    if System.get_env("MOB_SLIM") == "1" do
      otp_bundle = Path.join(app_path, "otp")
      erts_vsn = detect_erts_vsn(otp_bundle) || ""
      IO.puts("  === Slim strip pass")

      slim_step("apple_binaries", otp_bundle, fn ->
        # Apple-policy parity: no .so/.a in the bundle, no standalone executables.
        Path.wildcard("#{otp_bundle}/**/*.so") |> Enum.each(&File.rm!/1)
        Path.wildcard("#{otp_bundle}/**/*.a") |> Enum.each(&File.rm!/1)

        Path.wildcard("#{otp_bundle}/**/priv/bin/*")
        |> Enum.each(fn p -> if File.regular?(p), do: File.rm!(p) end)

        if erts_vsn != "" do
          erts_bin = Path.join([otp_bundle, erts_vsn, "bin"])

          if File.dir?(erts_bin) do
            File.ls!(erts_bin)
            |> Enum.map(&Path.join(erts_bin, &1))
            |> Enum.each(fn p -> if File.regular?(p), do: File.rm!(p) end)
          end
        end
      end)

      slim_step("prefix_libs", otp_bundle, fn ->
        # OTP libs we don't need at runtime on a mobile device.
        prefixes = ~w(
          megaco runtime_tools erl_interface os_mon wx et eunit
          observer debugger diameter edoc tools snmp dialyzer
          syntax_tools parsetools xmerl reltool inets ftp tftp
          common_test mnesia eldap odbc
          compiler ssh
        )

        for prefix <- prefixes do
          Path.wildcard("#{otp_bundle}/lib/#{prefix}-*") |> Enum.each(&File.rm_rf!/1)
        end
      end)

      slim_step("foreign_apps", otp_bundle, fn ->
        # Cache hygiene — apps from other projects that snuck into the OTP cache.
        for prefix <- ~w(toy_ test_ mob_test scratch_) do
          Path.wildcard("#{otp_bundle}/lib/#{prefix}*-*") |> Enum.each(&File.rm_rf!/1)
        end
      end)

      slim_step("dedup_versions", otp_bundle, fn ->
        # Multiple installed versions of the same app — keep the latest.
        lib_dir = Path.join(otp_bundle, "lib")

        if File.dir?(lib_dir) do
          File.ls!(lib_dir)
          |> Enum.map(&Path.join(lib_dir, &1))
          |> Enum.filter(&File.dir?/1)
          |> Enum.group_by(fn dir ->
            dir |> Path.basename() |> String.replace(~r/-[\d.]+$/, "")
          end)
          |> Enum.each(fn {_name, dirs} ->
            if length(dirs) > 1 do
              latest = Enum.max_by(dirs, &Path.basename/1)
              dirs |> Enum.reject(&(&1 == latest)) |> Enum.each(&File.rm_rf!/1)
            end
          end)
        end
      end)

      slim_step("src_and_headers", otp_bundle, fn ->
        # Runtime doesn't need source code or .h headers.
        for name <- ~w(src include) do
          Path.wildcard("#{otp_bundle}/**/#{name}")
          |> Enum.filter(&File.dir?/1)
          |> Enum.each(&File.rm_rf!/1)
        end
      end)

      slim_step("beam_chunks", otp_bundle, fn ->
        # `:beam_lib.strip_release/1` drops Debug/Doc chunks from .beam files
        # in lib/<app>/ebin/ — analog to the C-side -ffunction-sections +
        # -dead_strip. Same behaviour as MobDev.Release uses for App Store builds.
        case :beam_lib.strip_release(String.to_charlist(otp_bundle)) do
          {:ok, _} ->
            :ok

          {:error, :beam_lib, reason} ->
            IO.warn("strip_release error: #{inspect(reason)}")
        end
      end)

      {size, _} = System.cmd("du", ["-sh", otp_bundle])
      IO.puts("  Slim OTP bundle: #{size |> String.split() |> List.first()}")
    else
      IO.puts("  [SLIM:skipped] MOB_SLIM=0 — keeping full OTP runtime")
    end

    :ok
  end

  defp slim_step(label, otp_bundle, fun) do
    before = bundle_size_kb(otp_bundle)
    fun.()
    after_size = bundle_size_kb(otp_bundle)
    delta = before - after_size
    IO.puts("  [SLIM:#{label}] #{before} KB → #{after_size} KB  (-#{delta} KB)")
  end

  defp bundle_size_kb(dir) do
    case System.cmd("du", ["-sk", dir], stderr_to_stdout: true) do
      {out, 0} ->
        out |> String.split() |> List.first() |> String.to_integer()

      _ ->
        0
    end
  end

  defp embed_provisioning_profile(app_path, profile_uuid) do
    candidates = [
      Path.expand(
        "~/Library/Developer/Xcode/UserData/Provisioning Profiles/#{profile_uuid}.mobileprovision"
      ),
      Path.expand("~/Library/MobileDevice/Provisioning Profiles/#{profile_uuid}.mobileprovision")
    ]

    case Enum.find(candidates, &File.exists?/1) do
      nil ->
        {:error,
         "Provisioning profile #{profile_uuid} not found in either Xcode UserData or MobileDevice paths.\n" <>
           "Open Xcode → Settings → Accounts → Download Profiles."}

      profile_path ->
        IO.puts("  === Embedding provisioning profile")
        File.cp!(profile_path, Path.join(app_path, "embedded.mobileprovision"))
        :ok
    end
  end

  defp codesign_ios_device_app(app_path, cfg, build_dir) do
    sign_identity = cfg[:ios_sign_identity]
    team_id = cfg[:ios_team_id]
    bundle_id = cfg[:ios_bundle_id] || cfg[:bundle_id]

    IO.puts("  === Code signing")
    entitlements = resolve_or_generate_entitlements(app_path, build_dir, team_id, bundle_id)

    otp_bundle = Path.join(app_path, "otp")

    if File.dir?(Path.join(otp_bundle, "python")),
      do: codesign_python_dylibs(otp_bundle, sign_identity)

    {_, 0} =
      System.cmd(
        "codesign",
        [
          "--force",
          "--sign",
          sign_identity,
          "--entitlements",
          entitlements,
          "--timestamp=none",
          app_path
        ],
        stderr_to_stdout: true,
        into: IO.stream()
      )

    :ok
  end

  defp resolve_or_generate_entitlements(app_path, build_dir, team_id, bundle_id) do
    case Path.wildcard("ios/*.entitlements") do
      [entitlements | _] ->
        entitlements

      [] ->
        path = Path.join(build_dir, "mob_device.entitlements")

        # Mirror aps-environment from the profile so the binary entitlement
        # matches what the profile grants — without this APNs registration
        # silently fails and the push token is never delivered.
        aps_env = read_aps_environment(Path.join(app_path, "embedded.mobileprovision"))

        File.write!(path, """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>application-identifier</key>
            <string>#{team_id}.#{bundle_id}</string>
            <key>com.apple.developer.team-identifier</key>
            <string>#{team_id}</string>
            <key>get-task-allow</key>
            <true/>
        #{if aps_env, do: "    <key>aps-environment</key>\n    <string>#{aps_env}</string>\n", else: ""}\
        </dict>
        </plist>
        """)

        path
    end
  end

  defp read_aps_environment(profile_path) do
    # `security cms -D -i <profile>` decodes the CMS-wrapped XML plist;
    # we route it through a temp file because PlistBuddy doesn't read
    # stdin reliably and System.cmd doesn't pipe.
    tmp_plist =
      Path.join(System.tmp_dir!(), "mob_aps_#{System.unique_integer([:positive])}.plist")

    try do
      case System.cmd("security", ["cms", "-D", "-i", profile_path, "-o", tmp_plist],
             stderr_to_stdout: true
           ) do
        {_, 0} ->
          case System.cmd(
                 "/usr/libexec/PlistBuddy",
                 ["-c", "Print :Entitlements:aps-environment", tmp_plist],
                 stderr_to_stdout: true
               ) do
            {value, 0} -> String.trim(value)
            _ -> nil
          end

        _ ->
          nil
      end
    after
      File.rm(tmp_plist)
    end
  end

  defp codesign_python_dylibs(otp_bundle, sign_identity) do
    IO.puts("  === Codesigning bundled Python dylibs")
    lib_dynload = Path.join([otp_bundle, "python", "lib", "python3.13", "lib-dynload"])

    so_files = Path.wildcard("#{lib_dynload}/**/*.so")

    Enum.each(so_files, fn so ->
      {_, 0} =
        System.cmd(
          "codesign",
          ["--force", "--sign", sign_identity, "--timestamp=none", so],
          stderr_to_stdout: true
        )
    end)

    IO.puts("  signed #{length(so_files)} lib-dynload extensions")

    framework = Path.join([otp_bundle, "python", "Python.framework", "Python"])

    if File.exists?(framework) do
      {_, 0} =
        System.cmd(
          "codesign",
          ["--force", "--sign", sign_identity, "--timestamp=none", framework],
          stderr_to_stdout: true
        )

      IO.puts("  signed Python.framework/Python")
    end

    Path.wildcard("#{otp_bundle}/lib/**/libpythonx.so")
    |> Enum.each(fn pythonx ->
      {_, 0} =
        System.cmd(
          "codesign",
          ["--force", "--sign", sign_identity, "--timestamp=none", pythonx],
          stderr_to_stdout: true
        )

      IO.puts("  signed #{Path.relative_to(pythonx, otp_bundle)}")
    end)
  end

  defp devicectl_install(udid, app_path) do
    IO.puts("  === Installing on device #{udid}")

    case System.cmd(
           "xcrun",
           ["devicectl", "device", "install", "app", "--device", udid, app_path],
           stderr_to_stdout: true,
           into: IO.stream()
         ) do
      {_, 0} -> :ok
      {_, code} -> {:error, "devicectl install failed (exit #{code}) — check output above"}
    end
  end

  defp throw_bundle_id_error,
    do: throw({:error, "bundle_id not set in mob.exs"})

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
          Regex.scan(Regex.compile!("\\d+\\) [0-9A-F]+ \"([^\"]+)\""), output)
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
      |> Enum.flat_map(&Release.parse_mobileprovision/1)

    # `mix mob.deploy --native` is for installing dev builds on registered
    # test devices (via xcrun devicectl). devicectl rejects App Store / Beta
    # profiles with "Attempted to install a Beta profile without the proper
    # entitlement" — so filter to Development profiles only:
    #   - Development:  provisioned_devices? = true,  provisions_all_devices? = false
    #   - Ad Hoc:       provisioned_devices? = true,  provisions_all_devices? = false (signed
    #                   with Distribution cert; rare for our flow)
    #   - App Store:    provisioned_devices? = false, provisions_all_devices? = false
    #   - Enterprise:   provisioned_devices? = false, provisions_all_devices? = true
    # We require provisioned_devices? = true. App Store profiles fall through to release.ex.
    dev_profiles = Enum.filter(all_profiles, & &1.provisioned_devices?)

    # Prefer exact bundle ID match; fall back to wildcard profiles (app_id "TEAMID.*")
    exact_profiles =
      Enum.filter(dev_profiles, fn %{app_id: app_id} ->
        String.ends_with?(app_id, ".#{bundle_id}")
      end)

    profiles =
      if exact_profiles != [] do
        exact_profiles
      else
        Enum.filter(dev_profiles, fn %{app_id: app_id} ->
          String.ends_with?(app_id, ".*")
        end)
      end

    candidates =
      if is_binary(uuid) do
        Enum.filter(profiles, &(&1.uuid == uuid))
      else
        profiles
      end

    case candidates do
      [] ->
        {:error, no_dev_profile_message(bundle_id, all_profiles)}

      [%{uuid: found_uuid, app_id: app_id, team_id: team}] ->
        unless is_binary(uuid) do
          IO.puts(
            "  #{IO.ANSI.cyan()}Auto-detected Development profile: #{found_uuid} (team #{team})#{IO.ANSI.reset()}"
          )
        end

        if String.ends_with?(app_id, ".*") do
          IO.puts(
            "  #{IO.ANSI.cyan()}  (using wildcard profile — run `mix mob.provision` to create a dedicated profile for #{bundle_id})#{IO.ANSI.reset()}"
          )
        end

        {:ok, {found_uuid, team}}

      many ->
        choices = Enum.map_join(many, "\n", fn %{uuid: u, app_id: a} -> "    #{u}  (#{a})" end)

        {:error,
         """
         Multiple Development profiles match '#{bundle_id}' — add ios_profile_uuid to mob.exs:

             config :mob_dev, ios_profile_uuid: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

         Matching Development profiles:
         #{choices}
         """}
    end
  end

  # Distinguish "no profiles at all" from "have App Store profile but no Development one".
  # The latter is the conflict case we hit after setting up TestFlight publishing —
  # the user has a working App Store profile but `mob.deploy` needs a Development one.
  defp no_dev_profile_message(bundle_id, all_profiles) do
    has_app_store_profile? =
      Enum.any?(all_profiles, fn %{app_id: app_id} = p ->
        not p.provisioned_devices? and not p.provisions_all_devices? and
          String.ends_with?(app_id, ".#{bundle_id}")
      end)

    if has_app_store_profile? do
      """
      No Development profile found for bundle ID '#{bundle_id}', but an App Store
      profile exists. `mix mob.deploy --native` needs a Development profile —
      App Store profiles can only be installed via TestFlight / App Store, not via
      xcrun devicectl.

      To get one (one-time):
        1. Open https://developer.apple.com/account/resources/profiles/list
        2. Click + → iOS App Development → choose '#{bundle_id}' → select your dev cert
           and the device(s) you want to install on → Generate
        3. Open Xcode → Settings → Accounts → select your team → "Download Manual Profiles"
        4. Re-run `mix mob.deploy --native`

      Now your machine has both profiles. mob_dev picks Development for `mob.deploy`
      and App Store for `mob.release` automatically.
      """
    else
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
      """
    end
  end

  defp build_device_env(cfg, otp_root, python_bundle) do
    app_atom = Mix.Project.config()[:app]
    app_name = app_atom |> to_string() |> Macro.camelize()
    app_module = to_string(app_atom)
    elixir_lib = resolve_elixir_lib(cfg[:elixir_lib])
    # The iOS device OTP cache (under ~/.mob/cache/otp-ios-device-<hash>/) ships
    # the EPMD source files needed for static EPMD compilation, so the cache dir
    # itself is the EPMD build root. The `ios_epmd_build_src` config remains as
    # an escape hatch for advanced users pointing at a custom OTP tree.
    epmd_src = cfg[:ios_epmd_build_src] || otp_root

    # Dev path defaults to OFF (slim adds ~5-10s per build that dev iteration
    # doesn't want). `mix mob.deploy --slim` opts in. `mix mob.release` flips
    # this default in its own env via MobDev.Release.
    slim_flag = if Process.get(:mob_slim, false), do: "1", else: "0"

    base = [
      {"MOB_DIR", Path.expand(cfg[:mob_dir])},
      {"MOB_ELIXIR_LIB", Path.expand(elixir_lib)},
      {"MOB_IOS_DEVICE_OTP_ROOT", otp_root},
      {"MOB_IOS_EPMD_BUILD_SRC", epmd_src},
      {"MOB_IOS_BUNDLE_ID", cfg[:bundle_id]},
      {"MOB_IOS_TEAM_ID", cfg[:ios_team_id]},
      {"MOB_IOS_SIGN_IDENTITY", cfg[:ios_sign_identity]},
      {"MOB_IOS_PROFILE_UUID", cfg[:ios_profile_uuid]},
      {"MOB_APP_NAME", app_name},
      {"MOB_APP_MODULE", app_module},
      {"MOB_SLIM", slim_flag}
    ]

    base ++ python_apple_support_env(pythonx_in_project?(), python_bundle)
  end

  @doc """
  Returns true when the user's project has a built `:pythonx` dependency.
  Public for testing — callers see it via `build_device_env`.

  Detection is via `_build/dev/lib/pythonx/` rather than scanning `mix.exs`
  so users get the same behavior whether they `mix mob.enable python` and
  rely on the dep being added, or vendor pythonx some other way.
  """
  @spec pythonx_in_project?(String.t()) :: boolean()
  def pythonx_in_project?(project_dir \\ File.cwd!()) do
    File.dir?(Path.join([project_dir, "_build", "dev", "lib", "pythonx"]))
  end

  @doc """
  Builds the env list passed to `build_device.sh` when Pythonx is in the
  project. Returns `[]` when the project doesn't depend on Pythonx — the
  generated script's `if [ -d "_build/dev/lib/pythonx" ]` gate makes the
  unset env var harmless in that case.

  Public for testing.
  """
  @spec python_apple_support_env(boolean(), String.t() | nil) :: [{String.t(), String.t()}]
  def python_apple_support_env(false, _bundle), do: []
  def python_apple_support_env(true, nil), do: []

  def python_apple_support_env(true, bundle) when is_binary(bundle),
    do: [{"PYTHON_APPLE_SUPPORT", bundle}]

  # Downloads the BeeWare Python-Apple-support bundle iff Pythonx is a dep.
  # Skipped silently for projects without Pythonx — the generated build
  # script's gate handles the absent-bundle case.
  defp maybe_ensure_python_bundle do
    if pythonx_in_project?() do
      MobDev.PythonAppleSupport.ensure()
    else
      {:ok, nil}
    end
  end

  @doc """
  Returns the bash script that `mix mob.deploy --native --device` writes
  to `ios/build_device.sh` and runs.

  Public to enable shape-tests (per AGENTS.md convention) — the Pythonx,
  exqlite, and signing blocks all matter and shouldn't regress silently.
  Don't call this from production code; the build flow always pairs it
  with `build_device_env/3`.
  """
  @spec generate_build_device_sh(keyword(), String.t()) :: String.t()
  def generate_build_device_sh(_cfg, _otp_root) do
    ~S"""
    #!/bin/bash
    # ios/build_device.sh — Physical iOS device build (generated by mix mob.deploy --native).
    # All config comes from environment variables set by NativeBuild. Do not hardcode values here.
    set -e
    cd "$(dirname "$0")/.."

    # Tell `mix compile` we're building for iOS so any `unless
    # System.get_env("MOB_TARGET") == "ios" do …` compile-time gates in the
    # user's config.exs short-circuit. The python feature uses this gate to
    # skip Pythonx's desktop `:uv_init` (which can't run on device — no uv,
    # no internet at compile time). Harmless for non-Python apps.
    export MOB_TARGET=ios

    # ── Config from mob.exs (set by mix mob.deploy --native) ─────────────────────
    MOB_DIR="${MOB_DIR:?MOB_DIR not set}"
    # Always use the Elixir lib dir that matches the running `elixir` binary so
    # the bundled Elixir stdlib matches the version that compiled the BEAMs.
    ELIXIR_LIB=$(elixir -e "IO.puts(Path.dirname(to_string(:code.lib_dir(:elixir))))" 2>/dev/null)
    if [ -z "$ELIXIR_LIB" ] || [ ! -d "$ELIXIR_LIB/elixir/ebin" ]; then
        ELIXIR_LIB="${MOB_ELIXIR_LIB:?MOB_ELIXIR_LIB not set}"
    fi
    OTP_ROOT="${MOB_IOS_DEVICE_OTP_ROOT:?MOB_IOS_DEVICE_OTP_ROOT not set}"
    # MOB_IOS_EPMD_BUILD_SRC is exported by `mix mob.deploy --native` (defaults
    # to the iOS-device OTP cache at ~/.mob/cache/otp-ios-device-<hash>/, which
    # ships the EPMD source files). The fallback below covers the rare case of
    # running this script directly without going through `mix mob.deploy`.
    EPMD_BUILD_SRC="${MOB_IOS_EPMD_BUILD_SRC:-$OTP_ROOT}"
    BUNDLE_ID="${MOB_IOS_BUNDLE_ID:?bundle_id not set in mob.exs}"
    TEAM_ID="${MOB_IOS_TEAM_ID:?ios_team_id not set in mob.exs}"
    SIGN_IDENTITY="${MOB_IOS_SIGN_IDENTITY:?ios_sign_identity not set in mob.exs}"
    PROFILE_UUID="${MOB_IOS_PROFILE_UUID:?ios_profile_uuid not set in mob.exs}"
    APP_NAME="${MOB_APP_NAME:?MOB_APP_NAME not set}"   # CamelCase binary name, e.g. MobDemo
    APP_MODULE="${MOB_APP_MODULE:?MOB_APP_MODULE not set}" # snake_case, e.g. mob_demo
    DEVICE_UDID="${1:?Usage: build_device.sh <device-udid>}"

    ERTS_VSN=$(ls "$OTP_ROOT" | grep '^erts-' | sort -V | tail -1)
    [ -z "$ERTS_VSN" ] && echo "ERROR: No erts-* in $OTP_ROOT" && exit 1

    # Auto-detect OTP release number (e.g. "27", "28", "29") from the tarball
    # so mob_beam.m's hard-coded `-boot $ROOTDIR/releases/<N>/start_clean`
    # matches what was actually shipped. Crash mode if mismatched:
    #   "Runtime terminating during boot ({'cannot get bootfile', ...})"
    OTP_RELEASE=$(ls "$OTP_ROOT/releases" 2>/dev/null | grep -E '^[0-9]+$' | sort -V | tail -1)
    [ -z "$OTP_RELEASE" ] && echo "ERROR: No releases/<N>/ in $OTP_ROOT" && exit 1
    echo "=== ERTS: $ERTS_VSN, OTP: $OTP_RELEASE, App: $APP_NAME, Bundle: $BUNDLE_ID ==="

    BEAMS_DIR="$OTP_ROOT/$APP_MODULE"
    SDKROOT=$(xcrun -sdk iphoneos --show-sdk-path)
    HOSTCC=$(xcrun -find cc)
    # -Os + per-section emission for linker dead-strip on the final app
    # binary. Per GRiSP nano 2025-06-11 — the C-side analog of
    # beam_lib:strip_release/1 for BEAMs.
    CC="$HOSTCC -arch arm64 -miphoneos-version-min=17.0 -isysroot $SDKROOT -Os -ffunction-sections -fdata-sections"

    IFLAGS="-I$OTP_ROOT/$ERTS_VSN/include \
            -I$OTP_ROOT/$ERTS_VSN/include/internal \
            -I$MOB_DIR/ios"

    # Same lib set as the iOS sim build. `crypto.a` is OTP's crypto NIF
    # built with -DSTATIC_ERLANG_NIF; `libcrypto.a` is statically-linked
    # OpenSSL 3.x. App-Store-friendly (no separate dynamic libs ship).
    LIBS="
      $OTP_ROOT/$ERTS_VSN/lib/libbeam.a
      $OTP_ROOT/$ERTS_VSN/lib/internal/liberts_internal_r.a
      $OTP_ROOT/$ERTS_VSN/lib/internal/libethread.a
      $OTP_ROOT/$ERTS_VSN/lib/libzstd.a
      $OTP_ROOT/$ERTS_VSN/lib/libepcre.a
      $OTP_ROOT/$ERTS_VSN/lib/libryu.a
      $OTP_ROOT/$ERTS_VSN/lib/asn1rt_nif.a
      $OTP_ROOT/$ERTS_VSN/lib/crypto.a
      $OTP_ROOT/$ERTS_VSN/lib/libcrypto.a
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

    # ── Pythonx + bundled CPython (BeeWare Python-Apple-support) ────────────────
    # Mirrors the exqlite block above. When `_build/dev/lib/pythonx` is present
    # the project depends on Pythonx; we install the OTP lib, cross-compile the
    # NIF as `libpythonx.so`, and bundle the matching Python.framework + stdlib
    # + arch-specific lib-dynload into `<otp_root>/python/`. Per-dylib codesign
    # happens later, before the final `.app` sign.
    if [ -d "_build/dev/lib/pythonx" ]; then
        echo "=== Installing pythonx as OTP library ==="
        PYTHONX_VSN=$(grep '"pythonx"' mix.lock \
            | grep -o '"[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*"' | head -1 | tr -d '"')
        [ -z "$PYTHONX_VSN" ] && PYTHONX_VSN=$(grep -o '{vsn,"[^"]*"}' \
            _build/dev/lib/pythonx/ebin/pythonx.app | grep -o '"[^"]*"' | tr -d '"')
        PYTHONX_LIB_DIR="$OTP_ROOT/lib/pythonx-${PYTHONX_VSN}"
        rm -rf "$OTP_ROOT/lib/pythonx-"*
        mkdir -p "$PYTHONX_LIB_DIR/ebin" "$PYTHONX_LIB_DIR/priv"
        cp _build/dev/lib/pythonx/ebin/*.beam "$PYTHONX_LIB_DIR/ebin/"
        cp _build/dev/lib/pythonx/ebin/pythonx.app "$PYTHONX_LIB_DIR/ebin/"
        cp _build/dev/lib/pythonx/ebin/* "$BEAMS_DIR/"
        # `fine` is Pythonx's NIF-helper companion; pythonx.cpp #includes it.
        [ -d "_build/dev/lib/fine" ] && cp _build/dev/lib/fine/ebin/* "$BEAMS_DIR/"

        : "${PYTHON_APPLE_SUPPORT:?pythonx in deps but PYTHON_APPLE_SUPPORT not set — re-run mix mob.deploy --native (which downloads the BeeWare bundle) instead of running this script directly}"
        PYTHON_FRAMEWORK="$PYTHON_APPLE_SUPPORT/Python.xcframework/ios-arm64/Python.framework"
        PYTHON_STDLIB="$PYTHON_APPLE_SUPPORT/Python.xcframework/lib/python3.13"
        PYTHON_LIB_DYNLOAD="$PYTHON_APPLE_SUPPORT/Python.xcframework/ios-arm64/lib-arm64/python3.13/lib-dynload"

        [ ! -d "$PYTHON_FRAMEWORK" ] && \
            echo "ERROR: Python.framework missing at $PYTHON_FRAMEWORK" && exit 1
        [ ! -d "$PYTHON_STDLIB" ] && \
            echo "ERROR: Python stdlib missing at $PYTHON_STDLIB" && exit 1
        [ ! -d "$PYTHON_LIB_DYNLOAD" ] && \
            echo "ERROR: lib-dynload missing at $PYTHON_LIB_DYNLOAD" && exit 1

        echo "=== Cross-compiling libpythonx.so for iOS device (iphoneos arm64) ==="
        # Pythonx's design: -undefined dynamic_lookup so ERL_NIF_* + libpython
        # symbols resolve at runtime against the loaded BEAM and Python framework.
        # @rpath/libpythonx.so install_name lets the loader locate it relative
        # to the bundled OTP runtime in <App>.app/otp/lib/pythonx-VSN/priv/.
        PYTHONX_SRC="deps/pythonx/c_src"
        FINE_INC="deps/fine/c_include"
        xcrun -sdk iphoneos clang++ \
            -arch arm64 \
            -dynamiclib \
            -undefined dynamic_lookup \
            -fPIC -fvisibility=hidden -std=c++17 \
            -isysroot "$SDKROOT" \
            -miphoneos-version-min=17.0 \
            -install_name "@rpath/libpythonx.so" \
            -Os -ffunction-sections -fdata-sections \
            -I "$OTP_ROOT/$ERTS_VSN/include" \
            -I "$OTP_ROOT/$ERTS_VSN/include/internal" \
            -I "$FINE_INC" \
            -Wno-unused-parameter -Wno-comment \
            "$PYTHONX_SRC/pythonx.cpp" \
            "$PYTHONX_SRC/python.cpp" \
            -o "$PYTHONX_LIB_DIR/priv/libpythonx.so" \
            || { echo "ERROR: pythonx NIF cross-compile failed"; exit 1; }

        echo "=== Bundling Python.framework + stdlib + lib-dynload (device arch) ==="
        # PYTHONHOME contract: Python expects <home>/lib/python3.13/... at
        # runtime. lib-dynload sits inside the stdlib dir; the .so files there
        # are arch-specific (iphoneos arm64).
        mkdir -p "$OTP_ROOT/python/lib"
        chmod -R u+w "$OTP_ROOT/python" 2>/dev/null || true
        rm -rf "$OTP_ROOT/python/Python.framework" "$OTP_ROOT/python/lib/python3.13"
        cp -R "$PYTHON_FRAMEWORK"   "$OTP_ROOT/python/Python.framework"
        cp -R "$PYTHON_STDLIB"      "$OTP_ROOT/python/lib/python3.13"
        cp -R "$PYTHON_LIB_DYNLOAD" "$OTP_ROOT/python/lib/python3.13/lib-dynload"
        echo "  framework:    $(ls -la "$OTP_ROOT/python/Python.framework/Python" | awk '{print $5, "bytes"}')"
        echo "  stdlib:       $(du -sh "$OTP_ROOT/python/lib/python3.13" | awk '{print $1}')"
        echo "  lib-dynload:  $(ls "$OTP_ROOT/python/lib/python3.13/lib-dynload" | wc -l) extensions"
    else
        echo "=== pythonx not in project — skipping CPython bundle ==="
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

    echo "=== Creating ssl shim ==="
    SSL_TMP=$(mktemp -d)
    cat > "$SSL_TMP/ssl.erl" << 'SSLEOF'
    -module(ssl).
    -behaviour(application).
    -export([start/2, stop/1, start/0, stop/0,
             connect/3, connect/4, connect/5,
             listen/2, accept/2, accept/3,
             close/1, send/2, recv/2, recv/3,
             controlling_process/2, getopts/2, setopts/2,
             peername/1, sockname/1, peercert/1,
             negotiated_protocol/1, cipher_suites/0,
             cipher_suites/2, cipher_suites/3,
             versions/0, format_error/1,
             clear_pem_cache/0, handshake/1, handshake/2, handshake/3,
             handshake_continue/2, handshake_continue/3,
             handshake_cancel/1, shutdown/2,
             transport_info/1, connection_information/1,
             connection_information/2]).
    start(_Type, _Args) ->
        Pid = spawn(fun() -> receive stop -> ok end end),
        {ok, Pid}.
    stop(_State) -> ok.
    start() -> ok.
    stop() -> ok.
    connect(_, _, _) -> {error, ssl_not_supported}.
    connect(_, _, _, _) -> {error, ssl_not_supported}.
    connect(_, _, _, _, _) -> {error, ssl_not_supported}.
    listen(_, _) -> {error, ssl_not_supported}.
    accept(_, _) -> {error, ssl_not_supported}.
    accept(_, _, _) -> {error, ssl_not_supported}.
    close(_) -> ok.
    send(_, _) -> {error, closed}.
    recv(_, _) -> {error, closed}.
    recv(_, _, _) -> {error, closed}.
    controlling_process(_, _) -> ok.
    getopts(_, _) -> {ok, []}.
    setopts(_, _) -> ok.
    peername(_) -> {error, ssl_not_supported}.
    sockname(_) -> {error, ssl_not_supported}.
    peercert(_) -> {error, ssl_not_supported}.
    negotiated_protocol(_) -> {error, ssl_not_supported}.
    cipher_suites() -> [].
    cipher_suites(_, _) -> [].
    cipher_suites(_, _, _) -> [].
    versions() -> [].
    format_error(_) -> "ssl not available on iOS (HTTP-only)".
    clear_pem_cache() -> ok.
    handshake(_) -> {error, ssl_not_supported}.
    handshake(_, _) -> {error, ssl_not_supported}.
    handshake(_, _, _) -> {error, ssl_not_supported}.
    handshake_continue(_, _) -> {error, ssl_not_supported}.
    handshake_continue(_, _, _) -> {error, ssl_not_supported}.
    handshake_cancel(_) -> ok.
    shutdown(_, _) -> ok.
    transport_info(_) -> {error, ssl_not_supported}.
    connection_information(_) -> {error, ssl_not_supported}.
    connection_information(_, _) -> {error, ssl_not_supported}.
    SSLEOF
    erlc -o "$BEAMS_DIR" "$SSL_TMP/ssl.erl"
    cat > "$BEAMS_DIR/ssl.app" << 'SSLAPPEOF'
    {application,ssl,[{modules,[ssl]},{applications,[kernel,stdlib,crypto,public_key]},{description,"SSL shim for iOS (HTTP-only)"},{registered,[]},{vsn,"11.2"},{mod,{ssl,[]}}]}.
    SSLAPPEOF
    rm -rf "$SSL_TMP"

    echo "=== Copying Elixir stdlib ==="
    mkdir -p "$OTP_ROOT/lib/elixir/ebin" "$OTP_ROOT/lib/logger/ebin"
    cp "$ELIXIR_LIB/elixir/ebin/"*.beam    "$OTP_ROOT/lib/elixir/ebin/"
    cp "$ELIXIR_LIB/elixir/ebin/elixir.app" "$OTP_ROOT/lib/elixir/ebin/"
    cp "$ELIXIR_LIB/logger/ebin/"*.beam    "$OTP_ROOT/lib/logger/ebin/"
    cp "$ELIXIR_LIB/logger/ebin/logger.app" "$OTP_ROOT/lib/logger/ebin/"
    cp "$ELIXIR_LIB/eex/ebin/"*.beam  "$BEAMS_DIR/"
    cp "$ELIXIR_LIB/eex/ebin/eex.app" "$BEAMS_DIR/"

    # Phoenix and its deps require several OTP standard libraries beyond what the
    # Mob iOS OTP tarball bundles. Copy them from the host OTP installation.
    # - runtime_tools: listed in Phoenix apps' extra_applications
    # - asn1: required by public_key (asn1rt_nif is already statically linked)
    # - public_key: required by Phoenix for cookie/cert infrastructure
    copy_otp_lib() {
        local APP="$1"
        local SRC
        SRC=$(elixir -e "IO.puts(:code.lib_dir(:${APP}))" 2>/dev/null)
        if [ -n "$SRC" ] && [ -d "$SRC/ebin" ]; then
            local VSN
            VSN=$(basename "$SRC")
            mkdir -p "$OTP_ROOT/lib/$VSN/ebin"
            cp "$SRC/ebin/"*.beam "$OTP_ROOT/lib/$VSN/ebin/"
            cp "$SRC/ebin/${APP}.app" "$OTP_ROOT/lib/$VSN/ebin/"
            echo "  + $VSN"
        else
            echo "  ! $APP not found on host — skipping"
        fi
    }
    echo "=== Copying OTP standard libraries (Phoenix deps) ==="
    copy_otp_lib runtime_tools
    copy_otp_lib asn1
    copy_otp_lib public_key

    echo "=== Copying migrations ==="
    mkdir -p "$BEAMS_DIR/priv/repo/migrations"
    if ls priv/repo/migrations/*.exs >/dev/null 2>&1; then
        cp priv/repo/migrations/*.exs "$BEAMS_DIR/priv/repo/migrations/"
    fi

    echo "=== Building and bundling static assets ==="
    if [ -d "assets" ]; then
        mix assets.build
        if [ -d "priv/static" ]; then
            mkdir -p "$BEAMS_DIR/priv/static"
            rsync -a "priv/static/" "$BEAMS_DIR/priv/static/"
            echo "  Static assets: $(du -sh priv/static | cut -f1)"
        fi
    else
        echo "  No assets/ dir — skipping static build"
    fi

    # Plug.Static (from: :app_name) resolves the priv dir via code:lib_dir/1, which
    # requires a code-path entry named "app_name-vsn" (not just "app_name").
    # Install the app into $OTP_ROOT/lib/app-vsn/ alongside runtime_tools, asn1 etc.
    # The -root flag makes $OTP_ROOT/lib/*/ebin available, so code:lib_dir finds it.
    echo "=== Installing app into OTP lib/ (required for code:priv_dir) ==="
    APP_VSN=$(grep -o '{vsn,"[^"]*"}' "$BEAMS_DIR/${APP_MODULE}.app" | grep -o '"[^"]*"' | tr -d '"')
    if [ -n "$APP_VSN" ]; then
        APP_LIB_DIR="$OTP_ROOT/lib/${APP_MODULE}-${APP_VSN}"
        rm -rf "$APP_LIB_DIR"
        mkdir -p "$APP_LIB_DIR/ebin"
        cp "$BEAMS_DIR/${APP_MODULE}.app" "$APP_LIB_DIR/ebin/"
        if [ -d "$BEAMS_DIR/priv" ]; then
            rsync -a "$BEAMS_DIR/priv/" "$APP_LIB_DIR/priv/"
        fi
        echo "  + ${APP_MODULE}-${APP_VSN}"
    else
        echo "  ! Could not read version — code:priv_dir(:${APP_MODULE}) may not work"
    fi

    echo "=== Copying logos ==="
    cp "$MOB_DIR/assets/logo/logo_dark.png"  "$OTP_ROOT/mob_logo_dark.png"  2>/dev/null || true
    cp "$MOB_DIR/assets/logo/logo_light.png" "$OTP_ROOT/mob_logo_light.png" 2>/dev/null || true

    # ── Compile native sources ────────────────────────────────────────────────────
    echo "=== Compiling native sources ==="
    # MOB_BUILD_DIR is provided by Mix's build_ios_physical so the
    # post-script bundle/codesign/install steps can find what we produced.
    # Falls back to mktemp for direct script invocation outside Mix.
    BUILD_DIR="${MOB_BUILD_DIR:-$(mktemp -d)}"

    # Phase 2 iter 12: the standard 7 native sources (5 ObjC + 1 Swift +
    # driver_tab + enif_keepalive) move into build_device.zig. EPMD,
    # erl_errno_id_compat stub, and the link still happen in this script
    # for now — they migrate in iter 12b/c. The zig build invocation is
    # below, after EPMD compile and enif_keepalive.c generation so all
    # the inputs to the build.zig graph exist when it runs.

    echo "=== Compiling in-process EPMD ==="
    # `-DNO_DAEMON` strips EPMD's `run_daemon()` (which calls fork()) from the
    # compiled object. We never run EPMD in daemon mode (epmd_thread starts it
    # in-process), but the linker still sees fork() as referenced from the
    # dead code, leaving an undefined `_fork` symbol that pulls in libSystem's
    # fork stub at link time. iOS device sandbox then denies the syscall when
    # something else (an Apple framework, debug infra) calls into the bound
    # symbol path — and the BEAM dies during startup. NO_DAEMON elides the
    # whole `#ifndef NO_DAEMON` block so fork is never linked in.
    EPMD_SRC="$EPMD_BUILD_SRC/erts/epmd/src"

    # Stock OTP epmd.c calls `run_daemon(g)` unconditionally inside `if
    # (g->is_daemon)`. With -DNO_DAEMON the function body is stripped but the
    # call site still references the symbol, so the link fails with
    # "Undefined symbols: _run_daemon". Idempotent inline patch wraps the
    # call in `#ifndef NO_DAEMON` so both halves go away together. Future
    # iOS-device tarballs ship with the patch already applied (see
    # mob_dev/scripts/release/patches/0002-ios-device-epmd-no-daemon.patch).
    if ! grep -q "ifndef NO_DAEMON" "$EPMD_SRC/epmd.c"; then
        echo "  patching $EPMD_SRC/epmd.c (NO_DAEMON guard around run_daemon call)"
        python3 -c "
    import re, sys
    p = '$EPMD_SRC/epmd.c'
    src = open(p).read()
    patched = re.sub(
    r'(    if \(g->is_daemon\)  \{\n)(\trun_daemon\(g\);\n)(    \} else \{\n)',
    r'\1#ifndef NO_DAEMON\n\2#endif\n\3',
    src,
    count=1,
    )
    if patched == src:
    sys.stderr.write('WARNING: patch pattern did not match — manual fix required\n')
    sys.exit(1)
    open(p, 'w').write(patched)
    "
    fi

    # SQLITE_STATIC_LIB presence is signaled to build_device.zig via
    # -Dsqlite_static=true so it adds -DMOB_STATIC_SQLITE_NIF to the
    # driver_tab compile. EPMD + erl_errno_id_compat both live in
    # build_device.zig as of Phase 2 iter 12b — only their generated
    # input files are still produced here.

    # ── Stub for erl_errno_id_unknown ────────────────────────────────────────────
    # Missing from libbeam.a in OTP 17.0 (function was split into a separate
    # compilation unit but the pre-built tarball omits it). A weak definition
    # satisfies the linker and loses to the real symbol if a future tarball
    # includes it again. build_device.zig compiles it via the -Derrno_compat
    # path option below.
    cat > "$BUILD_DIR/erl_errno_id_compat.c" << 'COMPATEOF'
    __attribute__((weak)) const char *erl_errno_id_unknown(int error) {
        (void)error;
        return "unknown";
    }
    COMPATEOF

    # ── enif_* keep-alive: prevent -dead_strip from removing enif_* symbols ──────
    # `dead_strip` on the final link drops every enif_* symbol that nothing
    # in the main binary references. Dynamic NIFs loaded via dlopen at
    # runtime (libpythonx.so via Pythonx, etc.) reference enif_* via the
    # flat namespace — the linker doesn't see those references at link time,
    # so dead_strip silently removes them. Result: dlopen fails at runtime
    # with "symbol not found in flat namespace '_enif_is_pid'".
    #
    # `__attribute__((used))` only protects the listed symbol, NOT siblings
    # in the same .o file — so referencing one enif_* doesn't transitively
    # keep the others. We need a `used` attribute on each.
    #
    # Generate one void * reference per `T _enif_*` symbol exported by
    # erl_nif.o inside libbeam.a. Re-runs idempotently because nm/awk
    # always produces the same list.
    echo "=== Generating enif_* keep-alive table ==="
    NIF_O_TMP=$(mktemp -d)
    $(xcrun -find ar) x "$OTP_ROOT/$ERTS_VSN/lib/libbeam.a" --output="$NIF_O_TMP" erl_nif.o 2>/dev/null \
        || $(xcrun -find ar) x "$OTP_ROOT/$ERTS_VSN/lib/libbeam.a" erl_nif.o
    [ ! -f erl_nif.o ] || mv erl_nif.o "$NIF_O_TMP/erl_nif.o"

    {
        echo "/* Auto-generated by mob_dev/native_build.ex — references every enif_*"
        echo " * symbol in erl_nif.o so -dead_strip keeps them in the main binary."
        echo " */"
        xcrun nm -arch arm64 "$NIF_O_TMP/erl_nif.o" 2>/dev/null \
            | awk '/ T _enif_/ { sym = substr($3, 2); printf "extern void %s(void); __attribute__((used)) static void *_keep_%s = (void *)&%s;\n", sym, sym, sym }'
    } > "$BUILD_DIR/enif_keepalive.c"
    rm -rf "$NIF_O_TMP"
    KEEP_COUNT=$(grep -c '^extern void enif_' "$BUILD_DIR/enif_keepalive.c" || true)
    echo "  $KEEP_COUNT enif_* symbols pinned"

    # Phase 2 iter 12: invoke build_device.zig now that all its inputs
    # exist (driver_tab_ios.c per-app, enif_keepalive.c just generated,
    # MobApp-Swift.h is emitted by the swift step inside build.zig).
    SQLITE_STATIC_FLAG=""
    [ -n "$SQLITE_STATIC_LIB" ] && SQLITE_STATIC_FLAG="-Dsqlite_static=true"
    DRIVER_TAB_IOS="$(pwd)/priv/generated/driver_tab_ios.c"
    [ ! -f "$DRIVER_TAB_IOS" ] && DRIVER_TAB_IOS="$MOB_DIR/ios/driver_tab_ios.c"
    SQLITE_STATIC_LIB_FLAG=""
    [ -n "$SQLITE_STATIC_LIB" ] && SQLITE_STATIC_LIB_FLAG="-Dsqlite_static_lib=$SQLITE_STATIC_LIB"
    zig build binary --build-file ios/build_device.zig \
        -Dmob_dir="$MOB_DIR" \
        -Dotp_root="$OTP_ROOT" \
        -Derts_vsn="$ERTS_VSN" \
        -Dotp_release="$OTP_RELEASE" \
        -Dsdkroot="$SDKROOT" \
        -Ddriver_tab="$DRIVER_TAB_IOS" \
        -Denif_keepalive="$BUILD_DIR/enif_keepalive.c" \
        -Dproject_ios_dir="$(pwd)/ios" \
        -Dmodule_name="$APP_NAME" \
        -Depmd_build_src="$EPMD_BUILD_SRC" \
        -Derrno_compat="$BUILD_DIR/erl_errno_id_compat.c" \
        $SQLITE_STATIC_FLAG \
        $SQLITE_STATIC_LIB_FLAG
    cp "ios/zig-out/$APP_NAME" "$BUILD_DIR/$APP_NAME"

    echo "=== Native build complete ==="
    # Bundle assembly + OTP runtime bundling + slim strip + provisioning
    # profile embed + codesign + devicectl install all live in
    # MobDev.NativeBuild.build_ios_physical as of Phase 2 iter 12d.
    # This script's job ends here — Mix takes over from BUILD_DIR/$APP_NAME.
    echo "BUILD_DIR=$BUILD_DIR"
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
  @doc """
  When `--device <id>` is given, narrow `platforms` to just the platform
  the device lives on. Drops Android when the id resolves to an iOS
  device (sim or physical), drops iOS otherwise.

  Public so `mix mob.deploy` can apply the same narrowing before calling
  `MobDev.Deployer.deploy_all/1` — otherwise the deployer's per-platform
  `filter_by_device_id` complains "No device matched" against the
  irrelevant platform even though the build itself was correctly
  targeted.

  Returns `platforms` unchanged when `device_id` is nil.
  """
  @spec narrow_platforms_for_device([atom()], String.t() | nil) :: [atom()]
  def narrow_platforms_for_device(platforms, nil), do: platforms

  def narrow_platforms_for_device(platforms, device_id) when is_binary(device_id) do
    narrow_platforms_for_device(platforms, device_id, &MobDev.Discovery.IOS.list_devices/0)
  end

  @doc """
  Variant that takes an iOS-discovery function so tests (and other
  callers that already have the device list in hand) can avoid the
  network-bound `IOS.list_devices/0` LAN scan.

  The lister is called at most once per invocation; both `ios_device?`
  and the physical-UDID format fallback consume the same result.
  """
  @spec narrow_platforms_for_device([atom()], String.t() | nil, (-> [MobDev.Device.t()])) ::
          [atom()]
  def narrow_platforms_for_device(platforms, nil, _lister), do: platforms

  def narrow_platforms_for_device(platforms, device_id, lister)
      when is_binary(device_id) and is_function(lister, 0) do
    devices = lister.()

    if ios_device?(device_id, devices) do
      platforms -- [:android]
    else
      platforms -- [:ios]
    end
  end

  # iOS device UDID matchers — string-based instead of regex so the check
  # works across BEAM/OTP versions (OTP 28 won't reuse precompiled regexes
  # stored in module attributes — `:re.import/1` is undefined or private).
  defp matches_ios_udid_long?(id) when is_binary(id),
    do: byte_size(id) == 40 and all_hex?(id)

  defp matches_ios_udid_long?(_), do: false

  defp matches_ios_udid_short?(id) when is_binary(id) and byte_size(id) == 25 do
    case String.split(id, "-", parts: 2) do
      [a, b] -> byte_size(a) == 8 and all_hex?(a) and byte_size(b) == 16 and all_hex?(b)
      _ -> false
    end
  end

  defp matches_ios_udid_short?(_), do: false

  defp all_hex?(s) when is_binary(s), do: s |> String.to_charlist() |> Enum.all?(&hex?/1)

  defp hex?(c)
       when (c >= ?0 and c <= ?9) or
              (c >= ?a and c <= ?f) or
              (c >= ?A and c <= ?F),
       do: true

  defp hex?(_), do: false

  # True when `id` matches *any* iOS device (sim or physical) in the
  # given `devices` list, OR matches an offline physical-UDID format.
  # Used to decide whether `--device <id>` narrows `platforms` to iOS or
  # Android. Accepts the full serial, the human-friendly `display_id`
  # (e.g. the first 8 chars of a sim UUID which `mix mob.devices`
  # prints), or — for offline devices that discovery doesn't return —
  # the format-based fallback below.
  defp ios_device?(id, devices) do
    Enum.any?(devices, fn d -> MobDev.Device.match_id?(d, id) end) or
      ios_physical_udid?(id, devices)
  end

  # Single-arg form used by build_all/1 — fetches iOS discovery itself
  # since the caller doesn't already have the list. Tests should use the
  # 2-arg form below (or call narrow_platforms_for_device/3) to avoid
  # the network-bound LAN scan.
  defp ios_physical_udid?(id) do
    ios_physical_udid?(id, MobDev.Discovery.IOS.list_devices())
  end

  # True when `id` is recognised as a connected physical iOS device.
  # Both simulator and physical UDIDs are UUIDs in modern Xcode (the
  # 36-char form), so format-only matching is ambiguous. We resolve by
  # consulting `devices` for the device type. Falls back to a format
  # check only when discovery returns nothing for that id — covers the
  # case where a UDID was passed but the device is offline / not yet
  # enumerable, in which case we err on the side of "physical" so the
  # device build is attempted (40-char and short forms are
  # physical-only).
  defp ios_physical_udid?(id, devices) do
    case Enum.find(devices, &(&1.serial == id)) do
      %MobDev.Device{type: :physical} ->
        true

      %MobDev.Device{type: :simulator} ->
        false

      nil ->
        matches_ios_udid_long?(id) or matches_ios_udid_short?(id)
    end
  end

  # ── Toolchain availability ──────────────────────────────────────────────────

  @doc """
  Returns true when the Android build toolchain looks usable from the given
  project directory. Three signals must all be present:

    1. `adb` is on PATH (build needs it to install the APK after Gradle)
    2. `<project_dir>/android/local.properties` exists and sets `sdk.dir`
    3. The directory `sdk.dir` points at exists on disk

  Returns false otherwise so the deploy can skip Android cleanly instead of
  failing late inside Gradle. Pure of side effects.
  """
  @spec android_toolchain_available?(String.t()) :: boolean()
  def android_toolchain_available?(project_dir \\ File.cwd!()) do
    with true <- adb_available?(),
         {:ok, sdk_dir} <- read_sdk_dir(project_dir) do
      File.dir?(sdk_dir)
    else
      _ -> false
    end
  end

  @doc """
  Returns true when an iOS build is feasible: macOS host with `xcrun`
  installed. Linux/Windows always returns false. Pure of side effects.
  """
  @spec ios_toolchain_available?() :: boolean()
  def ios_toolchain_available? do
    macos?() and System.find_executable("xcrun") != nil
  end

  @doc false
  @spec read_sdk_dir(String.t()) :: {:ok, String.t()} | :error
  def read_sdk_dir(project_dir) do
    path = Path.join([project_dir, "android", "local.properties"])

    with {:ok, content} <- File.read(path),
         [_, raw] <- Regex.run(Regex.compile!("^\\s*sdk\\.dir\\s*=\\s*(.+?)\\s*$", "m"), content) do
      {:ok, expand_sdk_dir(raw)}
    else
      _ -> :error
    end
  end

  # Java's `Properties.store()` writes "/Users/me/Android/sdk" but with
  # backslash-colons on Windows; on Unix it round-trips fine. Just trim.
  defp expand_sdk_dir(raw), do: String.trim(raw) |> Path.expand()

  @doc """
  Generates the fallback entitlements plist that `build_device.sh` writes when
  no `ios/*.entitlements` file is found in the project.

  `aps_env` should be `"development"`, `"production"`, or `nil`.  When non-nil
  the `aps-environment` key is included, allowing APNs push token registration
  to succeed.  When nil the key is omitted (the historic default, suitable for
  apps that do not use push notifications).

  This function is public so it can be unit-tested independently of the shell
  script that actually writes the file on device builds.
  """
  @spec fallback_entitlements_plist(String.t(), String.t(), String.t() | nil) :: String.t()
  def fallback_entitlements_plist(team_id, bundle_id, aps_env \\ nil) do
    aps_entry =
      if aps_env do
        "    <key>aps-environment</key>\n    <string>#{aps_env}</string>\n"
      else
        ""
      end

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>application-identifier</key>
        <string>#{team_id}.#{bundle_id}</string>
        <key>com.apple.developer.team-identifier</key>
        <string>#{team_id}</string>
        <key>get-task-allow</key>
        <true/>
    #{aps_entry}</dict>
    </plist>
    """
  end

  defp adb_available?, do: System.find_executable("adb") != nil

  defp macos?, do: match?({:unix, :darwin}, :os.type())

  defp warn_skipped_android do
    IO.puts(
      "  #{IO.ANSI.yellow()}⚠  Skipping Android build — toolchain not detected#{IO.ANSI.reset()}"
    )

    cond do
      not adb_available?() ->
        IO.puts("     `adb` not found on PATH. Install Android Studio (it bundles")
        IO.puts("     adb) or platform-tools, then re-run.")

      not File.exists?(Path.join(["android", "local.properties"])) ->
        IO.puts("     android/local.properties is missing. Run `mix mob.install`")
        IO.puts("     to generate it (auto-detects ANDROID_HOME / Android Studio).")

      true ->
        IO.puts("     android/local.properties has no `sdk.dir` set. Either:")
        IO.puts("       export ANDROID_HOME=/path/to/android/sdk && mix mob.install")
        IO.puts("     or edit android/local.properties and add a sdk.dir= line.")
    end
  end

  defp warn_skipped_ios do
    IO.puts(
      "  #{IO.ANSI.yellow()}⚠  Skipping iOS build — Xcode command-line tools not detected#{IO.ANSI.reset()}"
    )

    if macos?() do
      IO.puts("     Install Xcode and run `xcode-select --install`, then re-run.")
    else
      IO.puts("     iOS builds require macOS.")
    end
  end

  # ── Config ───────────────────────────────────────────────────────────────────

  @doc false
  @spec __load_config__() :: keyword()
  def __load_config__, do: load_config()

  @doc false
  @spec __resolve_elixir_lib__(String.t() | nil) :: String.t()
  def __resolve_elixir_lib__(configured), do: resolve_elixir_lib(configured)

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
