defmodule MobDev.ReleaseAndroid do
  @moduledoc """
  Builds the signed release AAB for a Mob Android app.

  Called by `mix mob.release --android`. The pipeline:

    1. Regenerate the `mob.exs` `url_schemes` intent filter in
       `AndroidManifest.xml` (`MobDev.UrlSchemes`), so the release doesn't
       depend on a dev build having stamped the current setting.
    2. Regenerate the plugin-derived files (runtime manifest, driver tables,
       migrations, images) and run the same native build as
       `mix mob.deploy --native` (`MobDev.NativeBuild.build_android_native/2`)
       for every Gradle `abiFilters` ABI: `jniLibs/<abi>/lib<app>.so` is
       rebuilt with the current plugins linked in, never reused from the last
       deploy (MOB-404). No device needed.
    3. Copy the arm64 OTP tree to a temp staging dir and add:
       - App + dep BEAMs (flattened into `{app_name}/`)
       - App `priv/` → `{app_name}/priv/`
       - exqlite BEAMs → `lib/exqlite-{vsn}/ebin/` (OTP lib structure needed
         for `:code.lib_dir(:exqlite)` to resolve correctly at runtime)
    4. Run `MobDev.OtpAssetBundle.build/2` — strips unused OTP libs (never
       one the app's runtime dependency closure needs, see
       `MobDev.OtpRequiredApps`) and optional BEAM chunks, then zips the tree
       to `src/release/assets/otp.zip`.
    5. Run `./gradlew bundleRelease` — signs the AAB using the keystore
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
         cfg = MobDev.NativeBuild.__load_config__(),
         :ok <- MobDev.MobDirCheck.check!(cfg[:mob_dir]),
         :ok <- MobDev.NativeBuild.apply_android_url_schemes!(cfg),
         :ok <- MobDev.NativeBuild.prepare_plugin_build_state!(),
         {:ok, abis} <- MobDev.NativeBuild.release_android_abis(),
         log("Building native library for #{Enum.join(abis, ", ")}..."),
         {:ok, otp} <- MobDev.NativeBuild.build_android_native(cfg, abis: abis),
         {:ok, otp_arm64} <- release_otp(otp),
         log("Staging OTP tree + app BEAMs..."),
         {:ok, staging} <- stage_otp_tree(otp_arm64, app_name),
         log("Building otp.zip (stripping unused OTP libs)..."),
         {:ok, info} <- build_zip(staging, slim),
         _ = File.rm_rf!(staging),
         log_kept_required(info.kept_required),
         log(
           "  #{info.zipped_files} files, " <>
             "#{div(info.original_size_kb, 1024)}MB → #{div(info.zip_size_kb, 1024)}MB"
         ),
         log("Running ./gradlew bundleRelease..."),
         {:ok, aab} <- gradle_bundle_release() do
      {:ok, aab}
    end
  end

  # otp.zip ships the arm64 OTP tree (BEAMs are ABI-independent; each ABI's
  # ERTS helpers ride in jniLibs). Reuse the native build's copy.
  defp release_otp(%{"arm64-v8a" => dir}), do: {:ok, dir}
  defp release_otp(_otp), do: MobDev.OtpDownloader.ensure_android("arm64-v8a")

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

        {:ok, staging}

      {out, _} ->
        {:error, "Failed to copy OTP tree: #{out}"}
    end
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
  # eex (Elixir stdlib, not in _build/). No host OTP apps: the runtime ships
  # ssl, and a host copy here shadowed it in every release (MOB-493).
  defp collect_beam_dirs do
    app_dirs = MobDev.HotPush.runtime_beam_dirs()

    eex_ebin = Path.join(to_string(:code.lib_dir(:eex)), "ebin")
    eex = if File.dir?(eex_ebin), do: [eex_ebin], else: []

    app_dirs ++ eex
  end

  defp exqlite_version, do: MobDev.AppFile.dep_version(:exqlite)

  # ── otp.zip ──────────────────────────────────────────────────────────────────

  defp build_zip(staging, slim) do
    zip_path = otp_zip_path()
    File.mkdir_p!(Path.dirname(zip_path))

    MobDev.OtpAssetBundle.build(staging, zip_path,
      slim: slim,
      required_apps: MobDev.HotPush.runtime_lib_names()
    )
  end

  defp log_kept_required([]), do: :ok

  defp log_kept_required(libs),
    do: log("  kept OTP libs the app needs (not slimmed): #{Enum.join(libs, ", ")}")

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
