defmodule MobDev.GooglePlay.PlaySetupTest do
  use ExUnit.Case, async: true

  alias MobDev.GooglePlay.PlaySetup

  # ── build_grant_request/2 ────────────────────────────────────────────────────

  describe "build_grant_request/2 — account-level (nil package)" do
    test "sets grantee to the service account email" do
      req = PlaySetup.build_grant_request("play-publisher@proj.iam.gserviceaccount.com", nil)
      assert req["grantee"] == "play-publisher@proj.iam.gserviceaccount.com"
    end

    test "includes developerAccountPermissions" do
      req = PlaySetup.build_grant_request("email@example.com", nil)
      assert length(req["developerAccountPermissions"]) > 0
    end

    test "does not include packageName for account-level grant" do
      req = PlaySetup.build_grant_request("email@example.com", nil)
      refute Map.has_key?(req, "packageName")
    end

    test "does not include appLevelPermissions for account-level grant" do
      req = PlaySetup.build_grant_request("email@example.com", nil)
      refute Map.has_key?(req, "appLevelPermissions")
    end

    test "includes CAN_MANAGE_RELEASES permission" do
      req = PlaySetup.build_grant_request("email@example.com", nil)
      assert "CAN_MANAGE_RELEASES" in req["developerAccountPermissions"]
    end
  end

  describe "build_grant_request/2 — app-level (with package)" do
    test "sets grantee to the service account email" do
      req = PlaySetup.build_grant_request("sa@proj.iam.gserviceaccount.com", "com.example.app")
      assert req["grantee"] == "sa@proj.iam.gserviceaccount.com"
    end

    test "sets packageName for app-level grant" do
      req = PlaySetup.build_grant_request("email@example.com", "com.example.app")
      assert req["packageName"] == "com.example.app"
    end

    test "includes appLevelPermissions for app-level grant" do
      req = PlaySetup.build_grant_request("email@example.com", "com.example.app")
      assert length(req["appLevelPermissions"]) > 0
    end

    test "does not include developerAccountPermissions for app-level grant" do
      req = PlaySetup.build_grant_request("email@example.com", "com.example.app")
      refute Map.has_key?(req, "developerAccountPermissions")
    end
  end

  # ── release_manager_permissions/0 ───────────────────────────────────────────

  describe "release_manager_permissions/0" do
    test "returns a non-empty list of strings" do
      perms = PlaySetup.release_manager_permissions()
      assert length(perms) > 0
      assert Enum.all?(perms, &is_binary/1)
    end

    test "includes CAN_MANAGE_RELEASES" do
      assert "CAN_MANAGE_RELEASES" in PlaySetup.release_manager_permissions()
    end
  end
end
