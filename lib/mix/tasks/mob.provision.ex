defmodule Mix.Tasks.Mob.Provision do
  use Mix.Task

  @shortdoc "Register your app ID and download an iOS provisioning profile"

  @moduledoc """
  Registers your app's bundle ID with Apple and downloads a development
  provisioning profile so `mix mob.deploy --native` can install to a
  physical iPhone.

  Run this once before your first physical device deploy:

      mix mob.provision

  ## What you need first

    1. **Apple ID** — free at https://appleid.apple.com
    2. **Xcode signed in** with that Apple ID:
       open Xcode → Settings → Accounts → [+] → Apple ID
    3. **Apple Developer Program** — optional for personal device development,
       required for App Store distribution ($99/year).
       Free accounts can deploy to your own devices; profiles expire every 7 days.
       Paid accounts get 1-year profiles and App Store access.
       Enroll at https://developer.apple.com/programs/enroll/

  That's it. `mix mob.provision` handles everything else automatically.

  ## What it does

    1. Reads your signing team from the macOS keychain or existing profiles
    2. Generates `ios/Provision.xcodeproj` — a minimal Xcode project used only
       for provisioning (safe to commit; useful if you ever need to open Xcode)
    3. Generates `ios/MobProvision.swift` — a two-line SwiftUI stub the project
       compiles to satisfy xcodebuild
    4. Runs `xcodebuild -allowProvisioningUpdates` which contacts Apple to:
       - Register your bundle ID in your developer account (if not registered)
       - Create a development provisioning profile
       - Download it to ~/Library/Developer/Xcode/.../Provisioning Profiles/
    5. Verifies the profile is present

  After provisioning, `mix mob.deploy --native` finds the profile automatically.
  Re-run `mix mob.provision` when your profile expires.
  """

  @impl Mix.Task
  def run(_args) do
    unless macos?() do
      Mix.raise("mix mob.provision is only supported on macOS.")
    end

    unless File.dir?("ios") do
      Mix.raise("No ios/ directory found. Run from the root of a mob iOS project.")
    end

    IO.puts("")
    IO.puts("#{cyan()}=== iOS Provisioning ===#{reset()}")
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

    check_signing_identity!()
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

    run_xcodebuild!()
    verify_profile!(bundle_id)

    IO.puts("")
    IO.puts("#{green()}✓ Provisioning complete!#{reset()}")
    IO.puts("")
    IO.puts("Next step: #{cyan()}mix mob.deploy --native#{reset()}")
    IO.puts("")

    IO.puts(
      "#{faint()}Free Apple ID profiles expire every 7 days — re-run mix mob.provision when that happens."
    )

    IO.puts("Paid Developer Program profiles last 1 year.#{reset()}")
  end

  # ── Prerequisite checks ───────────────────────────────────────────────────────

  defp check_signing_identity! do
    case System.cmd("security", ["find-identity", "-v", "-p", "codesigning"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        identities =
          Regex.scan(Regex.compile!("\\d+\\) [0-9A-F]+ \"([^\"]+)\""), output)
          |> Enum.map(fn [_, id] -> id end)
          |> Enum.filter(&String.contains?(&1, "Apple Development"))
          |> Enum.uniq()

        case identities do
          [] ->
            IO.puts("  #{red()}✗#{reset()} Apple Development certificate — not found in keychain")

            Mix.raise("""

            No Apple Development signing certificate found.

            One-time setup:
              1. Open Xcode
              2. Xcode → Settings → Accounts → [+] → add your Apple ID
              3. Select your team → click "Download Manual Profiles"
              4. Re-run: mix mob.provision
            """)

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

        IO.puts(
          "     Find yours at #{cyan()}https://developer.apple.com/account#{reset()} → Membership → Team ID"
        )

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

  defp run_xcodebuild! do
    args = [
      "-project",
      "ios/Provision.xcodeproj",
      "-target",
      "MobProvision",
      "-destination",
      "generic/platform=iOS",
      "-allowProvisioningUpdates",
      "-allowProvisioningDeviceRegistration",
      "SYMROOT=/tmp/mob_provision_build",
      "OBJROOT=/tmp/mob_provision_build",
      "build"
    ]

    {output, rc} = System.cmd("xcodebuild", args, stderr_to_stdout: true)

    if rc != 0 do
      # On failure, show the full output so the user can diagnose
      IO.puts(output)

      Mix.raise("""

      xcodebuild provisioning failed (exit #{rc}).

      Common causes:
        - Xcode not signed in: open Xcode → Settings → Accounts → add Apple ID
        - Bundle ID registered to a different team
        - No internet connection (provisioning contacts Apple's servers)

      To debug, run manually from #{File.cwd!()}:
          xcodebuild #{Enum.join(args, " ")}
      """)
    end

    # Print only the summary line on success
    output
    |> String.split("\n")
    |> Enum.filter(&(&1 =~ Regex.compile!("^\\*\\* BUILD (SUCCEEDED|FAILED)")))
    |> Enum.each(&IO.puts/1)

    :ok
  end

  defp verify_profile!(bundle_id) do
    profile_dirs = [
      Path.expand("~/Library/Developer/Xcode/UserData/Provisioning Profiles"),
      Path.expand("~/Library/MobileDevice/Provisioning Profiles")
    ]

    # Accept an exact bundle ID match or a wildcard profile (covers any bundle ID)
    found =
      Enum.flat_map(profile_dirs, &Path.wildcard(Path.join(&1, "*.mobileprovision")))
      |> Enum.any?(fn path ->
        case File.read(path) do
          {:ok, data} ->
            String.contains?(data, bundle_id) or
              Regex.match?(
                Regex.compile!(
                  "<key>application-identifier</key>\\s*<string>[^<]+\\.\\*</string>"
                ),
                data
              )

          _ ->
            false
        end
      end)

    if found do
      IO.puts("  #{green()}✓#{reset()} Provisioning profile ready")
    else
      IO.puts(
        "  #{yellow()}⚠#{reset()}  Profile not found — re-run `mix mob.provision` if deploy fails"
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
  defp red, do: IO.ANSI.red()
  defp cyan, do: IO.ANSI.cyan()
  defp bright, do: IO.ANSI.bright()
  defp faint, do: IO.ANSI.faint()
  defp reset, do: IO.ANSI.reset()
end
