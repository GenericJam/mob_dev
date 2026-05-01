defmodule Mix.Tasks.Mob.Release do
  use Mix.Task

  @shortdoc "Build a signed iOS .ipa for App Store / TestFlight"

  @moduledoc """
  Builds a release-signed iOS `.ipa` ready to upload to App Store Connect.

      mix mob.release

  ## Output

  `_build/mob_release/<App>.ipa`

  Use `mix mob.publish` to upload it to TestFlight.

  ## Prerequisites

    1. Apple Developer Program membership (paid, $99/yr)
    2. An "Apple Distribution" certificate in your keychain
       (Xcode → Settings → Accounts → Manage Certificates → +)
    3. An App Store provisioning profile for your bundle ID, downloaded
       to `~/Library/Developer/Xcode/UserData/Provisioning Profiles/`.
       `mix mob.provision --distribution` automates the profile download.

  ## What it does

    1. Resolves a distribution signing identity + App Store profile
       (auto-detect, or `:ios_dist_sign_identity` / `:ios_dist_profile_uuid`
       in `mob.exs`)
    2. Generates `ios/release_device.sh` and runs it:
       - Compiles BEAMs and copies them into the OTP runtime
       - Builds native sources with `-DMOB_RELEASE` so `mob_beam.m`
         drops EPMD + the distribution BEAM args
       - Links the iOS device binary, no EPMD object files
       - Signs the `.app` with the distribution identity (no `get-task-allow`)
       - Packages as `Payload/<App>.app` zipped into `<App>.ipa`

  The shipped `.ipa` runs the full BEAM but with no Erlang distribution
  surface — `Mob.Dist.ensure_started/1` no-ops at runtime when
  `MOB_RELEASE=1`.
  """

  @impl Mix.Task
  def run(_args) do
    case :os.type() do
      {:unix, :darwin} -> :ok
      _ -> Mix.raise("mix mob.release is only supported on macOS.")
    end

    unless File.dir?("ios") do
      Mix.raise("No ios/ directory found. Run from the root of a mob iOS project.")
    end

    Mix.Task.run("compile")

    case MobDev.Release.build_ipa() do
      {:ok, path} ->
        Mix.shell().info("")
        Mix.shell().info("#{green()}✓ Release build complete#{reset()}")
        Mix.shell().info("  IPA: #{cyan()}#{path}#{reset()}")
        Mix.shell().info("  Size: #{file_size_human(path)}")
        Mix.shell().info("")
        Mix.shell().info("Next: #{cyan()}mix mob.publish#{reset()} to upload to TestFlight.")

      {:error, reason} ->
        Mix.raise(reason)
    end
  end

  defp file_size_human(path) do
    case File.stat(path) do
      {:ok, %{size: bytes}} ->
        cond do
          bytes >= 1024 * 1024 -> :io_lib.format("~.1fM", [bytes / (1024 * 1024)]) |> List.flatten()
          bytes >= 1024 -> :io_lib.format("~.1fK", [bytes / 1024]) |> List.flatten()
          true -> "#{bytes}B"
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
