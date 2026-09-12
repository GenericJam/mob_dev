defmodule MobDev.GooglePlay.SetupWizardTest do
  use ExUnit.Case, async: true

  # SetupWizard is interactive (Mix.shell prompts) and makes network calls,
  # so we test the pure helper logic extracted from it rather than the wizard flow.
  #
  # Integration testing of the full wizard is done manually on a real developer
  # account — see guides/publishing_to_google_play.md for the expected flow.

  alias MobDev.GooglePlay.CloudSetup
  alias MobDev.GooglePlay.PlaySetup
  alias MobDev.GooglePlay.SetupWizard

  # ── Key filename derivation ──────────────────────────────────────────────────
  # Mirrors the logic in SetupWizard.default_key_filename/1.

  describe "key filename from package name" do
    test "uses the last segment of the package name" do
      assert key_filename_for("com.example.myapp") == "myapp-service-account"
    end

    test "works for two-segment package names" do
      assert key_filename_for("example.myapp") == "myapp-service-account"
    end

    test "works for single-segment package name" do
      assert key_filename_for("myapp") == "myapp-service-account"
    end
  end

  # ── Project selection logic ──────────────────────────────────────────────────
  # Mirrors SetupWizard.pick_project/2 logic for unit testing.

  describe "project selection by number" do
    test "selects first project when user enters 1" do
      projects = [
        %{"projectId" => "proj-a", "displayName" => "A"},
        %{"projectId" => "proj-b", "displayName" => "B"}
      ]

      assert pick_project(projects, "1") == {:ok, "proj-a"}
    end

    test "selects last project when user enters the last number" do
      projects = [
        %{"projectId" => "proj-a", "displayName" => "A"},
        %{"projectId" => "proj-b", "displayName" => "B"},
        %{"projectId" => "proj-c", "displayName" => "C"}
      ]

      assert pick_project(projects, "3") == {:ok, "proj-c"}
    end

    test "selects by project ID string" do
      projects = [%{"projectId" => "my-project-123", "displayName" => "My Project"}]
      assert pick_project(projects, "my-project-123") == {:ok, "my-project-123"}
    end

    test "returns error for out-of-range number" do
      projects = [%{"projectId" => "proj-a", "displayName" => "A"}]
      assert {:error, _} = pick_project(projects, "5")
    end

    test "returns error for unknown project ID" do
      projects = [%{"projectId" => "proj-a", "displayName" => "A"}]
      assert {:error, _} = pick_project(projects, "proj-unknown")
    end

    test "returns error for 0" do
      projects = [%{"projectId" => "proj-a", "displayName" => "A"}]
      assert {:error, _} = pick_project(projects, "0")
    end
  end

  # ── grant_request shape integration ─────────────────────────────────────────
  # Verify the JSON body we'd POST to the grants API is well-formed.

  describe "grant request body" do
    test "account-level request is valid JSON with required fields" do
      req = PlaySetup.build_grant_request("sa@proj.iam.gserviceaccount.com", nil)
      json = Jason.encode!(req)
      decoded = Jason.decode!(json)

      assert decoded["grantee"] == "sa@proj.iam.gserviceaccount.com"
      assert length(decoded["developerAccountPermissions"]) > 0
    end

    test "app-level request is valid JSON with required fields" do
      req = PlaySetup.build_grant_request("sa@proj.iam.gserviceaccount.com", "com.example.app")
      json = Jason.encode!(req)
      decoded = Jason.decode!(json)

      assert decoded["grantee"] == "sa@proj.iam.gserviceaccount.com"
      assert decoded["packageName"] == "com.example.app"
      assert length(decoded["appLevelPermissions"]) > 0
    end
  end

  # ── Cloud setup URL construction ─────────────────────────────────────────────

  describe "enable API URL for well-known projects" do
    test "project IDs with dashes are handled correctly" do
      url =
        CloudSetup.build_enable_api_url("my-cool-project-123", "androidpublisher.googleapis.com")

      assert url =~ "my-cool-project-123"
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  # Mirrors SetupWizard.default_key_filename/1
  defp key_filename_for(package_name) do
    package_name
    |> String.split(".")
    |> List.last()
    |> Kernel.<>("-service-account")
  end

  # Mirrors SetupWizard.pick_project/2
  defp pick_project(projects, input) do
    case Integer.parse(input) do
      {n, ""} when n >= 1 and n <= length(projects) ->
        {:ok, Enum.at(projects, n - 1)["projectId"]}

      _ ->
        if Enum.any?(projects, &(&1["projectId"] == input)) do
          {:ok, input}
        else
          {:error, "Unknown project: #{input}"}
        end
    end
  end

  # ── keystore.properties passphrase handling (MOB-71) ─────────────────────────

  describe "keystore_properties_content/1" do
    test "does NOT bake a trailing newline from Mix.shell().prompt/1 into the stored password" do
      # `Mix.shell().prompt/1` returns the whole line including the trailing
      # \n. Before MOB-71 that newline flowed straight into `-storepass` at
      # keytool time AND into `keystore.properties`, so Gradle later signed
      # every release with `secret\n` — a password nobody can retype on the
      # next Play upload. Revert the `String.trim/1` in
      # `keystore_properties_content/1` and this assertion fails: the file
      # would contain `storePassword=secret\n\nkeyAlias=...`.
      content = SetupWizard.keystore_properties_content("secret\n")

      assert content =~ ~r/^storePassword=secret$/m
      assert content =~ ~r/^keyPassword=secret$/m
      refute content =~ "storePassword=secret\n\n"
    end

    test "strips leading/trailing whitespace so a pasted password does not carry surrounding blanks" do
      # Password managers often add a leading space when auto-typing into a
      # terminal prompt; users occasionally add a trailing space by habit.
      # Either would produce a keystore Gradle can never open again.
      content = SetupWizard.keystore_properties_content("  secret  ")

      assert content =~ ~r/^storePassword=secret$/m
      assert content =~ ~r/^keyPassword=secret$/m
    end

    test "leaves an already-clean passphrase alone" do
      content = SetupWizard.keystore_properties_content("secret")

      assert content =~ ~r/^storePassword=secret$/m
      assert content =~ ~r/^keyPassword=secret$/m
      assert content =~ ~r/^storeFile=upload_jks\.keystore$/m
      assert content =~ ~r/^keyAlias=upload$/m
    end
  end
end
