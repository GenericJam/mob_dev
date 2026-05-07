defmodule Mix.Tasks.Mob.Republish do
  use Mix.Task

  @shortdoc "Bump build, rebuild, and upload — one shot (--ios | --android)"

  @moduledoc """
  Convenience wrapper around the per-release flow. Bumps the platform's
  build number, rebuilds the release artifact, and uploads to the store.

      mix mob.republish --ios                         # bump CFBundleVersion, mob.release, mob.publish --ios
      mix mob.republish --ios --no-bump               # skip the bump (Apple will reject same build #; mostly for testing)
      mix mob.republish --android                     # bump versionCode, gradlew bundleRelease, mob.publish --android
      mix mob.republish --android --track production  # publish to a specific track

  Platform flag is **required** — Mob is intentionally platform-agnostic
  and refuses to default to either side.

  ## What --ios does (under the hood)

  Three steps. Each is a standalone command if you'd rather run them
  separately or need to troubleshoot one in isolation:

    1. Bump `CFBundleVersion` in `ios/Info.plist` by 1:

           CURRENT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" ios/Info.plist)
           /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $((CURRENT + 1))" ios/Info.plist

       Apple rejects re-uploads with the same `CFBundleVersion`. The bump
       only touches `CFBundleVersion` (the integer build number); your
       `CFBundleShortVersionString` (the public semver) stays put.

    2. `mix mob.release` — builds `_build/mob_release/<App>.ipa`. See
       `Mix.Tasks.Mob.Release` for what this produces. Bump-then-release
       order matters: the build number is baked into the binary, not
       inferred at upload time.

    3. `mix mob.publish --ios` — uploads via `xcrun altool` with App
       Store Connect API key auth. See `Mix.Tasks.Mob.Publish`.

  ## Failure handling

  If the bump itself fails (e.g. `CFBundleVersion` isn't an integer —
  someone wrote `"1.0"` which actually belongs in `CFBundleShortVersionString`),
  you get a clear error before anything else runs.

  If `mix mob.release` fails, `mix mob.publish` is not invoked. The
  build-number bump is NOT rolled back — you'll see a gap in your
  uploaded versions, which Apple is fine with (gaps are allowed; going
  backward isn't). Re-run after fixing whatever broke the build.

  If `mix mob.publish` itself fails (network, Apple API error, etc.),
  you may need to bump the version *again* before retrying — Apple
  considers the build number "consumed" once they see it, even on
  upload failure. Use `--no-bump` is rarely the right call; usually
  the right move is just `mix mob.republish --ios` again.
  """

  @switches [
    ios: :boolean,
    android: :boolean,
    no_bump: :boolean,
    verbose: :boolean,
    track: :string
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: @switches)

    case pick_platform(opts) do
      :ios -> republish_ios(opts)
      :android -> republish_android(opts)
    end
  end

  defp pick_platform(opts) do
    case {opts[:ios], opts[:android]} do
      {true, true} ->
        Mix.raise(
          "Pass exactly one of --ios or --android, not both. " <>
            "Republish targets one store at a time."
        )

      {true, _} ->
        :ios

      {_, true} ->
        :android

      _ ->
        Mix.raise("""
        mix mob.republish requires --ios or --android.

        Mob is platform-agnostic by design — neither side is the default.

            mix mob.republish --ios
            mix mob.republish --android
        """)
    end
  end

  defp republish_android(opts) do
    gradle = Path.expand("android/app/build.gradle")

    unless File.exists?(gradle) do
      Mix.raise(
        "android/app/build.gradle not found — run from the project root of a Mob Android app."
      )
    end

    unless opts[:no_bump] do
      {old, new} = bump_android_version_code!(gradle)

      Mix.shell().info(
        "#{cyan()}Bumped versionCode: #{old} → #{new}#{reset()} " <>
          "(Play rejects re-uploads of the same versionCode)"
      )
    end

    Mix.Task.run("mob.release", ["--android"])
    Mix.Task.reenable("mob.release")

    publish_argv = ["--android"] ++ if(opts[:track], do: ["--track", opts[:track]], else: [])
    Mix.Task.run("mob.publish", publish_argv)
    Mix.Task.reenable("mob.publish")
  end

  defp republish_ios(opts) do
    plist = "ios/Info.plist"

    unless File.exists?(plist) do
      Mix.raise("ios/Info.plist not found — run from the project root of a Mob iOS app.")
    end

    unless opts[:no_bump] do
      {old, new} = bump_ios_build_number!(plist)

      Mix.shell().info(
        "#{cyan()}Bumped CFBundleVersion: #{old} → #{new}#{reset()} " <>
          "(Apple rejects re-uploads of the same build number)"
      )
    end

    Mix.Task.run("mob.release")
    Mix.Task.reenable("mob.release")

    publish_argv = ["--ios"] ++ if(opts[:verbose], do: ["--verbose"], else: [])
    Mix.Task.run("mob.publish", publish_argv)
    Mix.Task.reenable("mob.publish")
  end

  @doc """
  Read `versionCode` from the given `build.gradle`, integer-bump it, and
  write back. Returns `{old, new}` strings.

  Raises with a clear message if no `versionCode` line is found.
  """
  @spec bump_android_version_code!(Path.t()) :: {String.t(), String.t()}
  def bump_android_version_code!(gradle_path) do
    content = File.read!(gradle_path)

    # Regex.compile! used deliberately — ~r// bakes compiled patterns into the .beam,
    # which breaks on OTP 28.0 (re.import/1 removed; fixed in 28.1).
    find_re = Regex.compile!("\\bversionCode\\s+(\\d+)")
    replace_re = Regex.compile!("\\bversionCode\\s+\\d+")

    case Regex.run(find_re, content, capture: :all_but_first) do
      [current_str] ->
        current = String.to_integer(current_str)
        new_str = Integer.to_string(current + 1)

        updated =
          String.replace(content, replace_re, "versionCode #{new_str}", global: false)

        File.write!(gradle_path, updated)
        {current_str, new_str}

      nil ->
        Mix.raise("""
        No versionCode found in #{gradle_path}.

        Expected a line like:
            versionCode 1

        inside the defaultConfig block.
        """)
    end
  end

  @doc """
  Read `CFBundleVersion` from the given Info.plist, integer-bump it, and
  write back. Returns `{old, new}` strings.

  Raises with a clear message if the current value isn't a clean integer
  — typically that means someone put a semver-style version
  (`"1.0.0"`) where Apple expects an integer build counter; the semver
  belongs in `CFBundleShortVersionString` instead.
  """
  @spec bump_ios_build_number!(String.t()) :: {String.t(), String.t()}
  def bump_ios_build_number!(plist) do
    {raw, 0} =
      System.cmd("/usr/libexec/PlistBuddy", ["-c", "Print :CFBundleVersion", plist])

    current = String.trim(raw)

    case Integer.parse(current) do
      {n, ""} ->
        new = Integer.to_string(n + 1)

        {_, 0} =
          System.cmd("/usr/libexec/PlistBuddy", [
            "-c",
            "Set :CFBundleVersion #{new}",
            plist
          ])

        {current, new}

      _ ->
        Mix.raise("""
        CFBundleVersion in #{plist} is "#{current}" — expected a bare integer.

        CFBundleVersion is the *build number* (an integer counter Apple
        uses to distinguish uploads). The public semver "1.0.0" belongs
        in CFBundleShortVersionString. Fix manually:

            /usr/libexec/PlistBuddy -c "Set :CFBundleVersion 1" #{plist}

        Then re-run `mix mob.republish --ios`.
        """)
    end
  end

  defp cyan, do: IO.ANSI.cyan()
  defp reset, do: IO.ANSI.reset()
end
