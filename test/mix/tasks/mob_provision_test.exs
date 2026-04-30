defmodule Mix.Tasks.Mob.ProvisionTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Mob.Provision

  # ── diagnose_xcodebuild_failure/1 — the user-visible improvement ────────────
  #
  # Each match preserves Apple's exact text so users can paste it into a search
  # engine and find existing community answers. The hint is additive, not a
  # replacement. Snippets below are excerpts of actual `xcodebuild` output we've
  # seen — keep them realistic so future Apple wording changes show up as
  # broken tests.

  describe "diagnose_xcodebuild_failure/1" do
    test "matches 'The attribute name is invalid' (App ID rejected for too long / bad chars)" do
      output = """
      ** BUILD FAILED **

      The following build commands failed:
              Check provisioning profile in another_political_name_app_bis.app
      (1 failure)

      error: An attribute in the provided entity has invalid value:
       The attribute 'name' is invalid: 'XC com example another_political_name_app_bis'
      """

      assert {label, snippet, hint} = Provision.diagnose_xcodebuild_failure(output)
      assert label =~ "Apple rejected"
      assert label =~ "App ID display name"
      # Snippet preserves Apple's exact words — googleable.
      assert snippet =~ "The attribute 'name' is invalid"
      # Hint is actionable — points at mob.exs and `mix mob.new`.
      assert hint =~ "config :mob_dev"
      assert hint =~ "bundle_id"
    end

    test "matches 'No signing certificate' (cert not in keychain)" do
      output = """
      error: No signing certificate "iOS Development" found:
       No "iOS Development" signing certificates matching team ID
      "Q89CW299G8" with a private key were found.
      """

      assert {label, snippet, hint} = Provision.diagnose_xcodebuild_failure(output)
      assert label =~ "signing certificate"
      assert snippet =~ "No signing certificate"
      assert hint =~ "Xcode → Settings → Accounts"
    end

    test "matches 'requires a development team' (no team selected)" do
      output = """
      error: Signing for "MobProvision" requires a development team.
      Select a development team in the Signing & Capabilities editor.
      """

      assert {_, snippet, _} = Provision.diagnose_xcodebuild_failure(output)
      assert snippet =~ "requires a development team"
    end

    test "matches 'There are too many App IDs' (free-tier 3-per-7-days quota)" do
      output = """
      error: Failed to register bundle identifier:
        There are too many App IDs registered. Please delete some
        currently registered App IDs and try again.
      """

      assert {label, snippet, hint} = Provision.diagnose_xcodebuild_failure(output)
      assert label =~ "Free-tier App ID limit"
      assert snippet =~ "too many App IDs"
      assert hint =~ "wait"
      assert hint =~ "reuse"
    end

    test "matches 'Failed to register bundle identifier' (bundle ID owned by another team)" do
      output = """
      error: Failed to register bundle identifier:
       The app identifier "com.acme.foo" cannot be registered to your
       development team. Change your bundle identifier to a unique string.
      """

      assert {label, snippet, hint} = Provision.diagnose_xcodebuild_failure(output)
      assert label =~ "different team"
      assert snippet =~ "Failed to register bundle identifier"
      assert hint =~ "unique"
    end

    test "returns nil for unrecognised errors so caller falls back to generic message" do
      output = """
      ** BUILD FAILED **
      error: Some entirely new Apple error string nobody has seen before.
      """

      assert Provision.diagnose_xcodebuild_failure(output) == nil
    end

    test "snippet is a single-line excerpt, not the full multi-line output" do
      # Important so the snippet is paste-into-Google sized, not a wall of text.
      output = """
      Build settings from command line:
          ...big preamble...

      error: An attribute in the provided entity has invalid value:
       The attribute 'name' is invalid: 'XC com example foo'

      ...trailing build chatter...
      """

      assert {_, snippet, _} = Provision.diagnose_xcodebuild_failure(output)
      refute snippet =~ "preamble"
      refute snippet =~ "trailing"

      refute String.contains?(snippet, "\n"),
             "snippet should be one line so it's pasteable into a search engine; got: #{inspect(snippet)}"
    end

    test "patterns ordered by specificity — App-ID-name matches before bundle-id-taken" do
      # The 'name is invalid' pattern is more specific than the
      # 'Failed to register bundle identifier' header that often
      # accompanies it. We want the more actionable diagnosis to win.
      output = """
      error: Failed to register bundle identifier
      error: The attribute 'name' is invalid: 'XC com example x'
      """

      assert {label, _, _} = Provision.diagnose_xcodebuild_failure(output)
      assert label =~ "App ID display name"
    end
  end
end
