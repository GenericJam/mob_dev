defmodule MobDev.ReleaseAndroid do
  @moduledoc """
  Builds the signed release AAB for a Mob Android app.

  Called by `mix mob.release --android`. The pipeline:

    1. Download the Android OTP runtime (arm64) if not already cached.
    2. Copy the OTP tree to a temp staging dir and add:
       - App + dep BEAMs (flattened into `{app_name}/`)
       - App `priv/` → `{app_name}/priv/`
       - exqlite BEAMs → `lib/exqlite-{vsn}/ebin/` (OTP lib structure needed
         for `:code.lib_dir(:exqlite)` to resolve correctly at runtime)
    3. Run `MobDev.OtpAssetBundle.build/2` — strips unused OTP libs and
       optional BEAM chunks, then zips the tree to
       `src/release/assets/otp.zip`.
    4. Run `./gradlew bundleRelease` — signs the AAB using the keystore
       configured in `android/keystore.properties`.

  `MobBridge.extractOtpIfNeeded()` (Kotlin) extracts `otp.zip` into
  `<filesDir>/otp/` on first launch. Without this zip the app crashes
  immediately — the BEAM has no runtime or application BEAMs to load.

  The zip is written to the `release`-variant asset source set, not the
  shared `main` one — Gradle only merges `src/release/assets/` into release
  builds, so a leftover zip from a prior release build can never leak into
  (and silently poison) a subsequent debug build. See
  `decisions/2026-07-24-release-otp-zip-variant-scoped-assets.md`.
  """

  @app_assets "android/app/src/release/assets"

  @doc false
  @spec otp_zip_path() :: String.t()
  def otp_zip_path, do: Path.expand(Path.join(@app_assets, "otp.zip"))

  @doc """
  Runs the full Android release pipeline and returns `{:ok, aab_path}` or
  `{:error, reason}`.
  """
  @spec build_aab(keyword()) :: {:ok, Path.t()} | {:error, String.t()}
  def build_aab(opts \\ []) do
    app_name = Mix.Project.config()[:app] |> to_string()
    slim = Keyword.get(opts, :slim, true)

    with :ok <- check_android_project(),
         log("Ensuring Android OTP runtime..."),
         {:ok, otp_arm64} <- MobDev.OtpDownloader.ensure_android("arm64-v8a"),
         log("Staging OTP tree + app BEAMs..."),
         {:ok, staging} <- stage_otp_tree(otp_arm64, app_name),
         log("Building otp.zip (stripping unused OTP libs)..."),
         {:ok, info} <- build_zip(staging, slim),
         _ = File.rm_rf!(staging),
         log(
           "  #{info.zipped_files} files, " <>
             "#{div(info.original_size_kb, 1024)}MB → #{div(info.zip_size_kb, 1024)}MB"
         ),
         log("Running ./gradlew bundleRelease..."),
         {:ok, aab} <- gradle_bundle_release() do
      {:ok, aab}
    end
  end

  # ── Staging ──────────────────────────────────────────────────────────────────

  defp stage_otp_tree(otp_dir, app_name) do
    staging =
      Path.join(System.tmp_dir!(), "mob_android_release_#{:erlang.unique_integer([:positive])}")

    File.rm_rf!(staging)

    case System.cmd("cp", ["-R", otp_dir <> "/.", staging], stderr_to_stdout: true) do
      {_, 0} ->
        add_app_beams!(staging, app_name)
        add_app_priv!(staging, app_name)
        add_exqlite!(staging)

        # Only stub :crypto when the OTP runtime genuinely lacks the
        # OpenSSL NIF. When crypto.a is present (the Android CMakeLists.txt
        # statically links crypto.a + libcrypto.a and registers
        # crypto_nif_init in the driver table), the real :crypto works —
        # stubbing it replaces crypto.beam with one whose supports/1
        # returns [], making :ssl.versions/0 raise and breaking every
        # HTTPS request (TLS handshake never starts).
        if real_crypto_available?(otp_dir) do
          log("  real crypto.a present — keeping OpenSSL crypto (no stub)")
        else
          patch_crypto_deps!(staging)
          add_crypto_stub!(staging, app_name)
        end

        {:ok, staging}

      {out, _} ->
        {:error, "Failed to copy OTP tree: #{out}"}
    end
  end

  # True when the OTP runtime ships the real OpenSSL crypto NIF static
  # archive (crypto.a). The Android native build links it into the app
  # .so, so the BEAM has working :crypto and must not get the stub.
  # Public for testing.
  @doc false
  @spec real_crypto_available?(Path.t()) :: boolean()
  def real_crypto_available?(otp_dir) do
    Path.wildcard(Path.join(otp_dir, "erts-*/lib/crypto.a")) != []
  end

  # Flatten all runtime BEAMs (app + deps) into {staging}/{app_name}/.
  # This mirrors how the deployer stages BEAMs for adb push:
  # all dirs are copied into one flat directory on the -pa code path.
  defp add_app_beams!(staging, app_name) do
    beam_dirs = collect_beam_dirs()
    dest = Path.join(staging, app_name)
    File.mkdir_p!(dest)

    Enum.each(beam_dirs, fn dir ->
      System.cmd("cp", ["-r", "#{Path.expand(dir)}/.", dest], stderr_to_stdout: true)
    end)
  end

  defp add_app_priv!(staging, app_name) do
    local_priv = Path.join(File.cwd!(), "priv")

    if File.dir?(local_priv) do
      dest = Path.join([staging, app_name, "priv"])
      File.rm_rf!(dest)
      System.cmd("cp", ["-R", local_priv, dest], stderr_to_stdout: true)
    end

    :ok
  end

  # exqlite BEAMs must live at lib/exqlite-VSN/ebin/ in the OTP root so that
  # :code.lib_dir(:exqlite) resolves correctly. mob_beam.c creates the
  # sqlite3_nif.so symlink at runtime from the APK's nativeLibraryDir.
  defp add_exqlite!(staging) do
    with vsn when is_binary(vsn) <- exqlite_version(),
         [ebin | _] <- Path.wildcard("_build/dev/lib/exqlite/ebin") do
      lib_dir = Path.join(staging, "lib/exqlite-#{vsn}")
      File.mkdir_p!(Path.join(lib_dir, "ebin"))
      File.mkdir_p!(Path.join(lib_dir, "priv"))

      System.cmd("cp", ["-r", "#{Path.expand(ebin)}/.", Path.join(lib_dir, "ebin")],
        stderr_to_stdout: true
      )
    else
      _ -> :ok
    end
  end

  # Same runtime BEAM collection as deployer.collect_beam_dirs/0: app + deps +
  # eex (Elixir stdlib, not in _build/) + ssl (Thousand Island dep, not in OTP tree).
  defp collect_beam_dirs do
    app_dirs = MobDev.HotPush.runtime_beam_dirs()

    eex_ebin = Path.join(to_string(:code.lib_dir(:eex)), "ebin")
    eex = if File.dir?(eex_ebin), do: [eex_ebin], else: []

    ssl_ebin = Path.join(to_string(:code.lib_dir(:ssl)), "ebin")
    ssl = if File.dir?(ssl_ebin), do: [ssl_ebin], else: []

    app_dirs ++ eex ++ ssl
  end

  defp exqlite_version, do: MobDev.AppFile.dep_version(:exqlite)

  # The Android OTP release lacks :crypto (no cross-compiled OpenSSL NIF).
  # Many deps (ecto, phoenix_pubsub, plug_crypto, …) declare it as a required
  # application dependency, which causes Application.ensure_all_started to fail
  # at startup. We patch every .app file in the staging tree to remove :crypto
  # from the applications list, then inject a minimal crypto.beam stub
  # (priv/android/crypto.erl) that implements strong_rand_bytes/1 via :rand.
  defp patch_crypto_deps!(staging) do
    staging
    |> Path.join("**/*.app")
    |> Path.wildcard()
    |> Enum.each(&remove_crypto_from_app_file/1)
  end

  defp remove_crypto_from_app_file(path) do
    case :file.consult(String.to_charlist(path)) do
      {:ok, [{:application, name, props}]} ->
        apps = Keyword.get(props, :applications, [])
        new_apps = Enum.reject(apps, &(&1 == :crypto))

        if new_apps != apps do
          new_props = Keyword.put(props, :applications, new_apps)
          term_str = :io_lib.format("~p.~n", [{:application, name, new_props}])
          File.write!(path, IO.chardata_to_string(term_str))
        end

      _ ->
        :ok
    end
  end

  defp add_crypto_stub!(staging, app_name) do
    stub_src =
      :code.priv_dir(:mob_dev)
      |> to_string()
      |> Path.join("android/crypto.erl")

    dest_dir = Path.join(staging, app_name)
    tmp_dir = Path.join(System.tmp_dir!(), "mob_crypto_stub")
    File.mkdir_p!(tmp_dir)

    case System.cmd("erlc", ["-o", tmp_dir, stub_src], stderr_to_stdout: true) do
      {_, 0} ->
        beam = Path.join(tmp_dir, "crypto.beam")

        if File.exists?(beam) do
          File.cp!(beam, Path.join(dest_dir, "crypto.beam"))
          File.rm!(beam)
        end

        # Write crypto.app so the OTP application controller can load and
        # start the :crypto application. Without this file, ensure_all_started
        # fails with {error, {crypto, {"no such file or directory", "crypto.app"}}}
        # even when crypto.beam is present — the app controller requires the
        # .app spec to register the application before starting it.
        # No {mod, ...} entry: starting :crypto just marks it as started,
        # with no NIF initialization (our stub uses :rand instead).
        crypto_app = """
        {application,crypto,[
          {description,"CRYPTO stub for Android"},
          {vsn,"5.5"},
          {modules,[crypto]},
          {registered,[]},
          {applications,[kernel,stdlib]},
          {env,[]}
        ]}.
        """

        File.write!(Path.join(dest_dir, "crypto.app"), crypto_app)

      {out, _} ->
        Mix.shell().info("  warning: could not compile crypto stub: #{out}")
    end
  end

  # ── otp.zip ──────────────────────────────────────────────────────────────────

  defp build_zip(staging, slim) do
    zip_path = otp_zip_path()
    File.mkdir_p!(Path.dirname(zip_path))
    MobDev.OtpAssetBundle.build(staging, zip_path, slim: slim)
  end

  # ── Gradle ───────────────────────────────────────────────────────────────────

  defp gradle_bundle_release do
    gradlew = Path.expand("android/gradlew")
    aab = Path.expand("android/app/build/outputs/bundle/release/app-release.aab")

    case System.cmd("bash", [gradlew, "bundleRelease", "--no-daemon"],
           cd: Path.expand("android"),
           stderr_to_stdout: true,
           into: IO.stream()
         ) do
      {_, 0} ->
        if File.exists?(aab) do
          {:ok, aab}
        else
          {:error, "Gradle succeeded but AAB not found at #{aab}"}
        end

      {_, rc} ->
        {:error, "Gradle bundleRelease failed (exit #{rc}) — see output above."}
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp check_android_project do
    cond do
      not File.dir?("android") ->
        {:error, "No android/ directory — run from the root of a Mob Android project."}

      not File.exists?("android/gradlew") ->
        {:error, "android/gradlew not found."}

      true ->
        :ok
    end
  end

  defp log(msg), do: Mix.shell().info("  #{msg}")
end
