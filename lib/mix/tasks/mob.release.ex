defmodule Mix.Tasks.Mob.Release do
  use Mix.Task

  @shortdoc "Build a signed release artifact (.ipa or .aab) for the app store"

  @moduledoc """
  Builds a release-signed artifact ready to upload to the app store.

      mix mob.release           # iOS .ipa (default)
      mix mob.release --ios     # iOS .ipa (explicit)
      mix mob.release --android # Android .aab

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
       `android/app/src/main/assets/otp.zip` — stripped and compressed.
       `MobBridge.extractOtpIfNeeded()` extracts this on first launch.
    4. Runs `./gradlew bundleRelease` to produce the signed AAB.

  Use `mix mob.publish --android` to upload to Google Play.
  """

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args, switches: [ios: :boolean, android: :boolean, slim: :boolean])

    if opts[:android] do
      run_android(opts)
    else
      run_ios(opts)
    end
  end

  defp run_android(_opts) do
    unless File.dir?("android") do
      Mix.raise("No android/ directory found. Run from the root of a Mob Android project.")
    end

    Mix.Task.run("compile")

    case MobDev.ReleaseAndroid.build_aab() do
      {:ok, path} ->
        Mix.shell().info("")
        Mix.shell().info("#{green()}✓ Release build complete#{reset()}")
        Mix.shell().info("  AAB: #{cyan()}#{path}#{reset()}")
        Mix.shell().info("  Size: #{file_size_human(path)}")
        Mix.shell().info("")

        Mix.shell().info(
          "Next: #{cyan()}mix mob.publish --android#{reset()} to upload to Google Play."
        )

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

      {:error, reason} ->
        Mix.raise(reason)
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
