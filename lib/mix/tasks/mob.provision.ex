defmodule Mix.Tasks.Mob.Provision do
  use Mix.Task

  @shortdoc "Register your app ID and download an iOS provisioning profile"

  @moduledoc """
  Registers your app's bundle ID with Apple and downloads an iOS
  provisioning profile.

  Two modes:

      mix mob.provision                 # development profile (default)
      mix mob.provision --distribution  # App Store distribution profile

  Run development provisioning once before your first `mix mob.deploy --native`.
  Run distribution provisioning once before your first `mix mob.release`.

  ## What you need first

    1. **Apple ID** — free at https://appleid.apple.com
    2. **Xcode signed in** with that Apple ID:
       open Xcode → Settings → Accounts → [+] → Apple ID
    3. **Apple Developer Program** — optional for personal device development,
       required for App Store distribution ($99/year).
       Free accounts can deploy to their own devices; profiles expire every
       7 days. Paid accounts get 1-year profiles and App Store access.
       Enroll at https://developer.apple.com/programs/enroll/

  Distribution mode requires a paid Developer Program membership.

  ## What it does (development)

    1. Reads your signing team from the macOS keychain or existing profiles
    2. Generates `ios/Provision.xcodeproj` — a minimal Xcode project used
       only for provisioning (safe to commit)
    3. Generates `ios/MobProvision.swift` — a two-line SwiftUI stub
    4. Runs `xcodebuild -allowProvisioningUpdates build` which contacts
       Apple to:
       - Register your bundle ID in your developer account (if not registered)
       - Create a development provisioning profile
       - Download it to ~/Library/Developer/Xcode/.../Provisioning Profiles/
    5. Verifies the profile is present

  ## What it does (distribution)

  Same as above, but runs `xcodebuild archive -allowProvisioningUpdates`
  with `CODE_SIGN_STYLE=Automatic` against the Release configuration.
  Apple creates an App Store provisioning profile (and an Apple
  Distribution certificate, if missing) and downloads them to your
  keychain + provisioning profile directory.
  """

  @switches [distribution: :boolean]

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: @switches)
    mode = if opts[:distribution], do: :distribution, else: :development

    unless macos?() do
      Mix.raise("mix mob.provision is only supported on macOS.")
    end

    unless File.dir?("ios") do
      Mix.raise("No ios/ directory found. Run from the root of a mob iOS project.")
    end

    IO.puts("")
    label = if mode == :distribution, do: "Distribution", else: "Development"
    IO.puts("#{cyan()}=== iOS Provisioning (#{label}) ===#{reset()}")
    IO.puts("")
    IO.puts("#{bright()}What you need before this step:#{reset()}")
    IO.puts("")
    IO.puts("  1. Apple ID — free at #{cyan()}https://appleid.apple.com#{reset()}")
    IO.puts("  2. Xcode signed in with that Apple ID")
    IO.puts("     Open Xcode → Settings → Accounts → [+] → Apple ID")
    IO.puts("  3. (App Store only) Apple Developer Program — $99/year")
    IO.puts("     Free accounts work for deploying to your own devices.")
    IO.puts("")
    IO.puts("#{bright()}Checking...#{reset()}")
    IO.puts("")

    check_signing_identity!(mode)
    team_id = resolve_team_id()
    bundle_id = check_bundle_id!()

    IO.puts("")
    IO.puts("  Bundle ID : #{cyan()}#{bundle_id}#{reset()}")
    IO.puts("  Team ID   : #{cyan()}#{team_id}#{reset()}")
    IO.puts("")

    generate_xcodeproj(bundle_id, team_id)
    generate_swift_stub()

    IO.puts("")
    IO.puts("#{bright()}Contacting Apple to register App ID and download profile...#{reset()}")
    IO.puts("(requires internet — may take 10–30 seconds)")
    IO.puts("")

    run_xcodebuild!(mode)
    verify_profile!(bundle_id, mode)

    IO.puts("")
    IO.puts("#{green()}✓ Provisioning complete!#{reset()}")
    IO.puts("")

    case mode do
      :distribution ->
        IO.puts("Next step: #{cyan()}mix mob.release#{reset()}")

      _ ->
        IO.puts("Next step: #{cyan()}mix mob.deploy --native#{reset()}")
    end

    IO.puts("")

    IO.puts(
      "#{faint()}Free Apple ID profiles expire every 7 days — re-run mix mob.provision when that happens."
    )

    IO.puts("Paid Developer Program profiles last 1 year.#{reset()}")
  end

  # ── Prerequisite checks ───────────────────────────────────────────────────────

  defp check_signing_identity!(mode) do
    cert_kind =
      case mode do
        :distribution -> "Apple Distribution"
        _ -> "Apple Development"
      end

    case System.cmd("security", ["find-identity", "-v", "-p", "codesigning"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        identities =
          Regex.scan(Regex.compile!("\\d+\\) [0-9A-F]+ \"([^\"]+)\""), output)
          |> Enum.map(fn [_, id] -> id end)
          |> Enum.filter(&String.contains?(&1, cert_kind))
          |> Enum.uniq()

        case identities do
          [] ->
            # For distribution, xcodebuild -allowProvisioningUpdates with the
            # archive action can create the cert if missing — so this isn't
            # fatal in distribution mode. Just warn and let xcodebuild try.
            IO.puts("  #{yellow()}?#{reset()} #{cert_kind} certificate — not yet in keychain")

            if mode == :distribution do
              IO.puts(
                "     #{faint()}xcodebuild will attempt to create one when contacting Apple.#{reset()}"
              )
            else
              Mix.raise("""

              No #{cert_kind} signing certificate found.

              One-time setup:
                1. Open Xcode
                2. Xcode → Settings → Accounts → [+] → add your Apple ID
                3. Select your team → click "Manage Certificates" → "+"
                4. Re-run: mix mob.provision
              """)
            end

          [id] ->
            IO.puts("  #{green()}✓#{reset()} Signing certificate — #{faint()}#{id}#{reset()}")

          many ->
            IO.puts(
              "  #{green()}✓#{reset()} Signing certificate — #{faint()}#{hd(many)}#{reset()} (#{length(many)} found, using first)"
            )
        end

      _ ->
        Mix.raise("Could not query keychain — is this macOS?")
    end
  end

  defp resolve_team_id do
    cfg = MobDev.Config.load_mob_config()

    cond do
      team = cfg[:ios_team_id] ->
        IO.puts("  #{green()}✓#{reset()} Team ID — #{team} #{faint()}(from mob.exs)#{reset()}")
        team

      team = team_from_any_profile() ->
        IO.puts(
          "  #{green()}✓#{reset()} Team ID — #{team} #{faint()}(auto-detected from existing profile)#{reset()}"
        )

        team

      true ->
        IO.puts("  #{yellow()}?#{reset()} Team ID — could not auto-detect")

        IO.puts("     Paid Apple Developer Program ($99/yr):")

        IO.puts(
          "       #{cyan()}https://developer.apple.com/account#{reset()} → Membership → Team ID"
        )

        IO.puts("     Free tier (Personal Team, no $99):")
        IO.puts("       Xcode → Settings → Accounts → [your Apple ID] → Team column")

        team = Mix.shell().prompt("  Enter Team ID:") |> String.trim()

        unless Regex.match?(Regex.compile!("^[A-Z0-9]{10}$"), team) do
          Mix.raise(
            "Invalid Team ID '#{team}' — expected 10 uppercase alphanumeric characters (e.g. Q89CW299G8)"
          )
        end

        team
    end
  end

  defp team_from_any_profile do
    profile_dirs = [
      Path.expand("~/Library/Developer/Xcode/UserData/Provisioning Profiles"),
      Path.expand("~/Library/MobileDevice/Provisioning Profiles")
    ]

    Enum.flat_map(profile_dirs, &Path.wildcard(Path.join(&1, "*.mobileprovision")))
    |> Enum.find_value(fn path ->
      with {:ok, data} <- File.read(path),
           {s, _} <- :binary.match(data, "<?xml"),
           {e, len} <- :binary.match(data, "</plist>") do
        xml = binary_part(data, s, e - s + len)

        case Regex.run(
               Regex.compile!("<key>TeamIdentifier</key>\\s*<array>\\s*<string>([^<]+)</string>"),
               xml
             ) do
          [_, team] -> String.trim(team)
          _ -> nil
        end
      else
        _ -> nil
      end
    end)
  end

  defp check_bundle_id! do
    bundle_id = MobDev.Config.bundle_id()
    IO.puts("  #{green()}✓#{reset()} Bundle ID — #{bundle_id}")
    bundle_id
  end

  # ── File generation ───────────────────────────────────────────────────────────

  defp generate_xcodeproj(bundle_id, team_id) do
    proj_dir = "ios/Provision.xcodeproj"
    proj_file = Path.join(proj_dir, "project.pbxproj")

    needs_write =
      if File.exists?(proj_file) do
        content = File.read!(proj_file)
        not (String.contains?(content, bundle_id) and String.contains?(content, team_id))
      else
        true
      end

    if needs_write do
      IO.puts("  Writing ios/Provision.xcodeproj...")
      File.mkdir_p!(proj_dir)
      File.write!(proj_file, project_pbxproj(bundle_id, team_id))
    else
      IO.puts("  #{green()}✓#{reset()} ios/Provision.xcodeproj — up to date")
    end
  end

  defp generate_swift_stub do
    path = "ios/MobProvision.swift"

    if File.exists?(path) do
      IO.puts("  #{green()}✓#{reset()} ios/MobProvision.swift — already exists")
    else
      IO.puts("  Writing ios/MobProvision.swift...")

      File.write!(path, """
      import SwiftUI

      @main
      struct MobProvision: App {
          var body: some Scene { WindowGroup { EmptyView() } }
      }
      """)
    end
  end

  # ── xcodebuild ────────────────────────────────────────────────────────────────

  defp run_xcodebuild!(mode) do
    base = [
      "-project",
      "ios/Provision.xcodeproj",
      "-target",
      "MobProvision",
      "-destination",
      "generic/platform=iOS",
      "-allowProvisioningUpdates",
      "-allowProvisioningDeviceRegistration",
      "SYMROOT=/tmp/mob_provision_build",
      "OBJROOT=/tmp/mob_provision_build"
    ]

    args =
      case mode do
        :distribution ->
          # `archive` + Release config triggers Apple to create or refresh
          # the App Store provisioning profile (and Distribution cert if
          # missing) under automatic signing.
          base ++
            [
              "-configuration",
              "Release",
              "-archivePath",
              "/tmp/mob_provision_build/Provision.xcarchive",
              "archive"
            ]

        _ ->
          base ++ ["build"]
      end

    {output, rc} = System.cmd("xcodebuild", args, stderr_to_stdout: true)

    if rc != 0 do
      # Show the full xcodebuild output first — keeps Apple's exact error
      # text visible for google searches and for users comparing notes with
      # online answers. The targeted hint below it is additive.
      IO.puts(output)

      hint = diagnose_xcodebuild_failure(output)
      Mix.raise(format_xcodebuild_error(rc, hint, args))
    end

    # Print only the summary line on success
    output
    |> String.split("\n")
    |> Enum.filter(&(&1 =~ Regex.compile!("^\\*\\* BUILD (SUCCEEDED|FAILED)")))
    |> Enum.each(&IO.puts/1)

    :ok
  end

  # ── xcodebuild error diagnosis ────────────────────────────────────────────
  #
  # Pattern-match against known Apple error strings and return a {label,
  # snippet, hint} describing the targeted fix. Returns nil for unmatched
  # errors — the caller falls back to a generic "common causes" message.
  #
  # The Apple/xcodebuild text is preserved verbatim in `:snippet` so users
  # can paste it into a search engine and find existing community
  # answers — our hint is additive, not a replacement.
  #
  # ## URL stability
  #
  # Each hint includes a link to Apple's official docs (`developer.apple.com/help/account/...`),
  # which is Apple's account-management knowledge base — more stable than
  # blog posts or Developer Forum threads. Apple does occasionally
  # reorganise these; if a link 404s, search "site:developer.apple.com"
  # for the section title to find its new home, then update the
  # `@apple_url_*` module attributes below. The pattern matchers are the
  # long-term backstop: they catch the error even when the URL goes stale.

  @apple_url_app_id "https://developer.apple.com/help/account/identifiers/register-an-app-id"
  @apple_url_signing_cert "https://developer.apple.com/help/account/create-certificates/create-signing-certificates"
  @apple_url_team_id "https://developer.apple.com/help/account/manage-your-team/locate-your-team-id"

  @doc false
  @spec diagnose_xcodebuild_failure(String.t()) ::
          {label :: String.t(), snippet :: String.t(), hint :: String.t()} | nil
  def diagnose_xcodebuild_failure(output) do
    cond do
      snippet = match_invalid_app_id_name(output) ->
        {"Apple rejected the auto-generated App ID display name", snippet,
         """
         Apple derives the App ID display name from your bundle ID by
         prepending "XC " and replacing dots with spaces. The result has
         to fit Apple's portal validation (~30-char limit, no characters
         their validator rejects — underscores have been flagged in some
         years).

         Fix: shorten the bundle ID's last segment in mob.exs:

             config :mob_dev, bundle_id: "com.example.<short_name>"

         Or regenerate with a shorter app name:

             mix mob.new <short_name>

         Apple's App ID rules: #{@apple_url_app_id}
         """}

      snippet = match_no_signing_cert(output) ->
        {"No Apple Development signing certificate", snippet,
         """
         Open Xcode → Settings → Accounts:
           1. [+] → add your Apple ID (free at https://appleid.apple.com)
           2. select your team → "Manage Certificates" → "+" → Apple Development

         Then re-run `mix mob.provision`.

         Apple's signing certificate guide: #{@apple_url_signing_cert}
         """}

      snippet = match_no_team(output) ->
        {"No team available for signing", snippet,
         """
         Set your Team ID in mob.exs:

             config :mob_dev, ios_team_id: "ABC123XYZ4"

         Find yours at:
           Paid ($99/yr): https://developer.apple.com/account → Membership
           Free (Personal Team): Xcode → Settings → Accounts →
                                 [your Apple ID] → Team column

         Apple's "locate your Team ID" guide: #{@apple_url_team_id}
         """}

      snippet = match_app_id_quota(output) ->
        {"Free-tier App ID limit (3 per 7 days) hit", snippet,
         """
         Apple caps Personal Team accounts at 3 distinct bundle IDs
         registered per rolling 7-day window. Either wait it out, or
         reuse a bundle ID Xcode already provisioned for you by setting
         it explicitly in mob.exs:

             config :mob_dev, bundle_id: "com.example.<previously_registered>"

         Apple's App ID registration page (mentions registration limits):
         #{@apple_url_app_id}
         """}

      snippet = match_bundle_id_taken(output) ->
        {"Bundle ID belongs to a different team", snippet,
         """
         Apple won't let two teams own the same App ID. Pick a unique
         bundle ID — for personal projects, append your initials or a
         random suffix:

             config :mob_dev, bundle_id: "com.example.<app>.<your_suffix>"

         Or change MOB_BUNDLE_PREFIX away from the conflicting reverse-DNS.

         Apple's App ID rules (uniqueness across teams):
         #{@apple_url_app_id}
         """}

      true ->
        nil
    end
  end

  # Each match_* helper returns the verbatim snippet from xcodebuild output
  # if the pattern is present, else nil. Keeping the snippet in the user's
  # output (rather than rephrasing) keeps it google-searchable.

  defp match_invalid_app_id_name(output) do
    grep_first(output, "The attribute 'name' is invalid")
  end

  defp match_no_signing_cert(output) do
    grep_first(output, "No signing certificate") ||
      grep_first(output, "no Apple Development cert") ||
      grep_first(output, "requires a development team")
  end

  defp match_no_team(output) do
    grep_first(output, "no eligible accounts") ||
      grep_first(output, "doesn't include any iOS App Development") ||
      grep_first(output, "No development team")
  end

  defp match_app_id_quota(output) do
    grep_first(output, "There are too many App IDs") ||
      grep_first(output, "maximum allowed number of App IDs") ||
      grep_first(output, "Maximum App IDs Reached")
  end

  defp match_bundle_id_taken(output) do
    grep_first(output, "Failed to register bundle identifier") ||
      grep_first(output, "An App ID with Identifier") ||
      grep_first(output, "is not available. Please enter a different string")
  end

  # First line of `output` containing `needle`, or nil.
  defp grep_first(output, needle) do
    output
    |> String.split("\n")
    |> Enum.find(&String.contains?(&1, needle))
    |> case do
      nil -> nil
      line -> String.trim(line)
    end
  end

  defp format_xcodebuild_error(rc, nil, args) do
    """

    xcodebuild provisioning failed (exit #{rc}).

    Common causes:
      - Xcode not signed in: open Xcode → Settings → Accounts → add Apple ID
      - Bundle ID registered to a different team
      - No internet connection (provisioning contacts Apple's servers)
      - Free-tier Apple ID hit the 3-App-IDs-per-7-days limit

    The full xcodebuild output is above; search any error line you don't
    recognise — Apple's text is fairly distinctive and there's almost always
    a Stack Overflow / forum hit for it.

    To debug, run manually from #{File.cwd!()}:
        xcodebuild #{Enum.join(args, " ")}
    """
  end

  defp format_xcodebuild_error(rc, {label, snippet, hint}, _args) do
    """

    xcodebuild provisioning failed (exit #{rc}).

    #{IO.ANSI.bright()}#{label}#{IO.ANSI.reset()}

    Apple's exact error (paste this into a search engine for community answers):

        #{snippet}

    #{hint}
    """
  end

  defp verify_profile!(bundle_id, mode) do
    profile_dirs = [
      Path.expand("~/Library/Developer/Xcode/UserData/Provisioning Profiles"),
      Path.expand("~/Library/MobileDevice/Provisioning Profiles")
    ]

    matching =
      Enum.flat_map(profile_dirs, &Path.wildcard(Path.join(&1, "*.mobileprovision")))
      |> Enum.filter(fn path ->
        case File.read(path) do
          {:ok, data} ->
            bundle_match =
              String.contains?(data, bundle_id) or
                Regex.match?(
                  Regex.compile!(
                    "<key>application-identifier</key>\\s*<string>[^<]+\\.\\*</string>"
                  ),
                  data
                )

            mode_match =
              case mode do
                :distribution ->
                  # App Store profiles have no ProvisionedDevices array
                  not String.contains?(data, "<key>ProvisionedDevices</key>") and
                    not String.contains?(data, "<key>ProvisionsAllDevices</key>")

                _ ->
                  # Development profiles list ProvisionedDevices
                  String.contains?(data, "<key>ProvisionedDevices</key>")
              end

            bundle_match and mode_match

          _ ->
            false
        end
      end)

    if matching != [] do
      label = if mode == :distribution, do: "App Store", else: "development"
      IO.puts("  #{green()}✓#{reset()} #{label} provisioning profile ready")
    else
      IO.puts(
        "  #{yellow()}⚠#{reset()}  Profile not found — re-run `mix mob.provision#{if mode == :distribution, do: " --distribution", else: ""}` if needed"
      )
    end
  end

  # ── project.pbxproj template ──────────────────────────────────────────────────
  #
  # A minimal Xcode project with a single Swift target. The UUIDs are fixed (they
  # only need to be unique within this file). MobProvision.swift is referenced
  # relative to the ios/ directory (the directory containing Provision.xcodeproj).

  defp project_pbxproj(bundle_id, team_id) do
    """
    // !$*UTF8*$!
    {
    \tarchiveVersion = 1;
    \tclasses = {
    \t};
    \tobjectVersion = 77;
    \tobjects = {

    /* Begin PBXBuildFile section */
    \t\tAA000001 /* MobProvision.swift in Sources */ = {isa = PBXBuildFile; fileRef = AA000002 /* MobProvision.swift */; };
    /* End PBXBuildFile section */

    /* Begin PBXFileReference section */
    \t\tAA000002 /* MobProvision.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = MobProvision.swift; sourceTree = "<group>"; };
    \t\tAA000003 /* MobProvision.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = MobProvision.app; sourceTree = BUILT_PRODUCTS_DIR; };
    /* End PBXFileReference section */

    /* Begin PBXGroup section */
    \t\tAA000004 = {
    \t\t\tisa = PBXGroup;
    \t\t\tchildren = (
    \t\t\t\tAA000002 /* MobProvision.swift */,
    \t\t\t\tAA000005 /* Products */,
    \t\t\t);
    \t\t\tsourceTree = "<group>";
    \t\t};
    \t\tAA000005 /* Products */ = {
    \t\t\tisa = PBXGroup;
    \t\t\tchildren = (
    \t\t\t\tAA000003 /* MobProvision.app */,
    \t\t\t);
    \t\t\tname = Products;
    \t\t\tsourceTree = "<group>";
    \t\t};
    /* End PBXGroup section */

    /* Begin PBXNativeTarget section */
    \t\tAA000006 /* MobProvision */ = {
    \t\t\tisa = PBXNativeTarget;
    \t\t\tbuildConfigurationList = AA000007 /* Build configuration list for PBXNativeTarget "MobProvision" */;
    \t\t\tbuildPhases = (
    \t\t\t\tAA000008 /* Sources */,
    \t\t\t);
    \t\t\tbuildRules = (
    \t\t\t);
    \t\t\tdependencies = (
    \t\t\t);
    \t\t\tname = MobProvision;
    \t\t\tproductName = MobProvision;
    \t\t\tproductReference = AA000003 /* MobProvision.app */;
    \t\t\tproductType = "com.apple.product-type.application";
    \t\t};
    /* End PBXNativeTarget section */

    /* Begin PBXProject section */
    \t\tAA000009 /* Project object */ = {
    \t\t\tisa = PBXProject;
    \t\t\tattributes = {
    \t\t\t\tBuildIndependentTargetsInParallel = YES;
    \t\t\t\tLastUpgradeCheck = 1600;
    \t\t\t};
    \t\t\tbuildConfigurationList = AA00000A /* Build configuration list for PBXProject "Provision" */;
    \t\t\tdevelopmentRegion = en;
    \t\t\thasScannedForEncodings = 0;
    \t\t\tknownRegions = (
    \t\t\t\tBase,
    \t\t\t\ten,
    \t\t\t);
    \t\t\tmainGroup = AA000004;
    \t\t\tproductRefGroup = AA000005 /* Products */;
    \t\t\tprojectDirPath = "";
    \t\t\tprojectRoot = "";
    \t\t\ttargets = (
    \t\t\t\tAA000006 /* MobProvision */,
    \t\t\t);
    \t\t};
    /* End PBXProject section */

    /* Begin PBXSourcesBuildPhase section */
    \t\tAA000008 /* Sources */ = {
    \t\t\tisa = PBXSourcesBuildPhase;
    \t\t\tbuildActionMask = 2147483647;
    \t\t\tfiles = (
    \t\t\t\tAA000001 /* MobProvision.swift in Sources */,
    \t\t\t);
    \t\t\trunOnlyForDeploymentPostprocessing = 0;
    \t\t};
    /* End PBXSourcesBuildPhase section */

    /* Begin XCBuildConfiguration section */
    \t\tAA00000B /* Debug */ = {
    \t\t\tisa = XCBuildConfiguration;
    \t\t\tbuildSettings = {
    \t\t\t\tCODE_SIGN_STYLE = Automatic;
    \t\t\t\tDEVELOPMENT_TEAM = #{team_id};
    \t\t\t\tGENERATE_INFOPLIST_FILE = YES;
    \t\t\t\tINFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES;
    \t\t\t\tINFOPLIST_KEY_UILaunchScreen_Generation = YES;
    \t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 17.0;
    \t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = #{bundle_id};
    \t\t\t\tPRODUCT_NAME = MobProvision;
    \t\t\t\tSDKROOT = iphoneos;
    \t\t\t\tSWIFT_VERSION = 5.9;
    \t\t\t\tTARGETED_DEVICE_FAMILY = "1,2";
    \t\t\t};
    \t\t\tname = Debug;
    \t\t};
    \t\tAA00000C /* Release */ = {
    \t\t\tisa = XCBuildConfiguration;
    \t\t\tbuildSettings = {
    \t\t\t\tCODE_SIGN_STYLE = Automatic;
    \t\t\t\tDEVELOPMENT_TEAM = #{team_id};
    \t\t\t\tGENERATE_INFOPLIST_FILE = YES;
    \t\t\t\tINFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES;
    \t\t\t\tINFOPLIST_KEY_UILaunchScreen_Generation = YES;
    \t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 17.0;
    \t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = #{bundle_id};
    \t\t\t\tPRODUCT_NAME = MobProvision;
    \t\t\t\tSDKROOT = iphoneos;
    \t\t\t\tSWIFT_VERSION = 5.9;
    \t\t\t\tTARGETED_DEVICE_FAMILY = "1,2";
    \t\t\t};
    \t\t\tname = Release;
    \t\t};
    \t\tAA00000D /* Debug */ = {
    \t\t\tisa = XCBuildConfiguration;
    \t\t\tbuildSettings = {
    \t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;
    \t\t\t\tSDKROOT = iphoneos;
    \t\t\t};
    \t\t\tname = Debug;
    \t\t};
    \t\tAA00000E /* Release */ = {
    \t\t\tisa = XCBuildConfiguration;
    \t\t\tbuildSettings = {
    \t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;
    \t\t\t\tSDKROOT = iphoneos;
    \t\t\t};
    \t\t\tname = Release;
    \t\t};
    /* End XCBuildConfiguration section */

    /* Begin XCConfigurationList section */
    \t\tAA000007 /* Build configuration list for PBXNativeTarget "MobProvision" */ = {
    \t\t\tisa = XCConfigurationList;
    \t\t\tbuildConfigurations = (
    \t\t\t\tAA00000B /* Debug */,
    \t\t\t\tAA00000C /* Release */,
    \t\t\t);
    \t\t\tdefaultConfigurationIsVisible = 0;
    \t\t\tdefaultConfigurationName = Debug;
    \t\t};
    \t\tAA00000A /* Build configuration list for PBXProject "Provision" */ = {
    \t\t\tisa = XCConfigurationList;
    \t\t\tbuildConfigurations = (
    \t\t\t\tAA00000D /* Debug */,
    \t\t\t\tAA00000E /* Release */,
    \t\t\t);
    \t\t\tdefaultConfigurationIsVisible = 0;
    \t\t\tdefaultConfigurationName = Debug;
    \t\t};
    /* End XCConfigurationList section */
    \t};
    \trootObject = AA000009 /* Project object */;
    }
    """
  end

  # ── ANSI helpers ──────────────────────────────────────────────────────────────

  defp macos?, do: match?({:unix, :darwin}, :os.type())
  defp green, do: IO.ANSI.green()
  defp yellow, do: IO.ANSI.yellow()
  defp cyan, do: IO.ANSI.cyan()
  defp bright, do: IO.ANSI.bright()
  defp faint, do: IO.ANSI.faint()
  defp reset, do: IO.ANSI.reset()
end
