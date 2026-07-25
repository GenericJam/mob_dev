defmodule Mix.Tasks.Mob.Release do
  use Mix.Task

  @shortdoc "Build a signed release artifact (.ipa or .aab) for the app store"

  @moduledoc """
  Builds a release-signed artifact ready to upload to the app store.

      mix mob.release                     # iOS .ipa (default)
      mix mob.release --ios               # iOS .ipa (explicit)
      mix mob.release --android           # Android .aab
      mix mob.release --security-gate     # run mix mob.security_scan first;
                                          # abort the release on any
                                          # critical/high/medium finding

  ## --security-gate

  Runs the full security scan against the project (every layer:
  Hex/Gradle/Swift dep CVEs, bundled-runtime drift, C/Kotlin/Swift
  static analysis) **before** building or signing. If the scan
  surfaces any critical/high/medium finding, the release aborts
  with a non-zero exit code — nothing is built, nothing is signed.
  Combine with the rest of your release flags as needed:

      mix mob.release --android --security-gate
      mix mob.release --ios --security-gate

  Equivalent to running `mix mob.security_scan --strict` and only
  proceeding to `mix mob.release` if the scan exits 0; the gate
  flag just bundles the two into one command so a wrong-order
  invocation can't slip through.

  ## --ios output

  `_build/mob_release/<App>.ipa`

  ## --android output

  `android/app/build/outputs/bundle/release/app-release.aab`

  ## --ios prerequisites

    1. Apple Developer Program membership (paid, $99/yr)
    2. An "Apple Distribution" certificate in your keychain
       (Xcode → Settings → Accounts → Manage Certificates → +)
    3. An App Store provisioning profile for your bundle ID, downloaded
       to `~/Library/Developer/Xcode/UserData/Provisioning Profiles/`.
       `mix mob.provision --distribution` automates the profile download.

  ## --android prerequisites

    1. `android/keystore.properties` filled in with your upload keystore
       credentials. `android/upload_jks.keystore` must exist. See
       `android/keystore.properties.example`.

  ## What --android does

    1. Ensures the Android OTP runtime is cached (`~/.mob/cache/otp-android-*`).
    2. Stages a temp tree: OTP runtime + app BEAMs + exqlite BEAMs.
    3. Runs `MobDev.OtpAssetBundle.build/2` to produce
       `android/app/src/release/assets/otp.zip` — stripped and compressed.
       `MobBridge.extractOtpIfNeeded()` extracts this on first launch. The
       release-variant asset dir keeps this out of debug builds.
    4. Runs `./gradlew bundleRelease` to produce the signed AAB.

  Use `mix mob.publish --android` to upload to Google Play.
  """

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [
          ios: :boolean,
          android: :boolean,
          slim: :boolean,
          security_gate: :boolean
        ]
      )

    if opts[:security_gate], do: run_security_gate()

    if opts[:android] do
      run_android(opts)
    else
      run_ios(opts)
    end
  end

  # Runs the full security scan before the build kicks off. Aborts
  # the release on any critical/high/medium finding so a vulnerable
  # build never reaches signing. Tip: mention `--security-gate` in
  # the success printouts so users discover it next time.
  defp run_security_gate do
    Mix.shell().info("→ #{cyan()}--security-gate#{reset()}: running mix mob.security_scan first")

    report = MobDev.SecurityScan.run([])
    counts = MobDev.SecurityScan.Report.severity_counts(report)
    blocking = counts.critical + counts.high + counts.medium

    if blocking > 0 do
      Mix.shell().error("")
      IO.write(MobDev.SecurityScan.Formatter.terminal(report))

      Mix.raise(
        "--security-gate: #{blocking} blocking finding(s) — release aborted before build. " <>
          "Run `mix mob.security_scan` for the full breakdown, fix or `--skip` the offending layer, " <>
          "and rerun."
      )
    end

    Mix.shell().info(
      "→ #{green()}✓ security scan clean#{reset()} (#{counts.low} low, #{counts.unknown} unknown — non-blocking)\n"
    )
  end

  defp run_android(opts) do
    unless File.dir?("android") do
      Mix.raise("No android/ directory found. Run from the root of a Mob Android project.")
    end

    Mix.Task.run("compile")

    case MobDev.ReleaseAndroid.build_aab(slim: Keyword.get(opts, :slim, true)) do
      {:ok, path} ->
        Mix.shell().info("")
        Mix.shell().info("#{green()}✓ Release build complete#{reset()}")
        Mix.shell().info("  AAB: #{cyan()}#{path}#{reset()}")
        Mix.shell().info("  Size: #{file_size_human(path)}")
        Mix.shell().info("")

        Mix.shell().info(
          "Next: #{cyan()}mix mob.publish --android#{reset()} to upload to Google Play."
        )

        maybe_security_gate_tip(opts)

      {:error, reason} ->
        Mix.raise(reason)
    end
  end

  defp run_ios(opts) do
    case :os.type() do
      {:unix, :darwin} -> :ok
      _ -> Mix.raise("mix mob.release --ios is only supported on macOS.")
    end

    unless File.dir?("ios") do
      Mix.raise("No ios/ directory found. Run from the root of a mob iOS project.")
    end

    slim = Keyword.get(opts, :slim, true)

    Mix.Task.run("compile")

    case MobDev.Release.build_ipa(slim: slim) do
      {:ok, path} ->
        Mix.shell().info("")
        Mix.shell().info("#{green()}✓ Release build complete#{reset()}")
        Mix.shell().info("  IPA: #{cyan()}#{path}#{reset()}")
        Mix.shell().info("  Size: #{file_size_human(path)}")
        Mix.shell().info("")

        Mix.shell().info(
          "Next: #{cyan()}mix mob.publish --ios#{reset()} to upload to TestFlight."
        )

        maybe_security_gate_tip(opts)

      {:error, reason} ->
        Mix.raise(reason)
    end
  end

  # Surface --security-gate in the post-build "next steps" block when
  # it wasn't used. Discovery via the same terminal printout that
  # already lists `mix mob.publish` keeps the option visible.
  defp maybe_security_gate_tip(opts) do
    unless opts[:security_gate] do
      Mix.shell().info(
        "Tip: #{cyan()}mix mob.release --security-gate#{reset()} " <>
          "to run mix mob.security_scan first and abort on critical/high/medium findings."
      )
    end
  end

  defp file_size_human(path) do
    case File.stat(path) do
      {:ok, %{size: bytes}} ->
        cond do
          bytes >= 1024 * 1024 ->
            :io_lib.format("~.1fM", [bytes / (1024 * 1024)]) |> List.flatten()

          bytes >= 1024 ->
            :io_lib.format("~.1fK", [bytes / 1024]) |> List.flatten()

          true ->
            "#{bytes}B"
        end
        |> to_string()

      _ ->
        "?"
    end
  end

  defp green, do: IO.ANSI.green()
  defp cyan, do: IO.ANSI.cyan()
  defp reset, do: IO.ANSI.reset()
end
