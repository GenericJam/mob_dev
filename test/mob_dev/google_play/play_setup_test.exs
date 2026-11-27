defmodule MobDev.GooglePlay.PlaySetupTest do
  use ExUnit.Case, async: true

  alias MobDev.GooglePlay.PlaySetup

  # Regression: the wizard POSTed to /v3/accounts/{id}/grants, which does not
  # exist (HTTP 404), with permission names that are not in the API enums.

  @play "https://androidpublisher.googleapis.com/androidpublisher/v3"

  # Every value of AppLevelPermission / DeveloperLevelPermission in the Play
  # Developer API v3 reference, apart from UNSPECIFIED and deprecated ones.
  @api_app_permissions ~w(
    CAN_VIEW_FINANCIAL_DATA CAN_MANAGE_PERMISSIONS CAN_REPLY_TO_REVIEWS
    CAN_MANAGE_PUBLIC_APKS CAN_MANAGE_TRACK_APKS CAN_MANAGE_TRACK_USERS
    CAN_MANAGE_PUBLIC_LISTING CAN_MANAGE_DRAFT_APPS CAN_MANAGE_ORDERS
    CAN_MANAGE_APP_CONTENT CAN_VIEW_NON_FINANCIAL_DATA CAN_VIEW_APP_QUALITY
    CAN_MANAGE_DEEPLINKS
  )

  @api_developer_permissions ~w(
    CAN_VIEW_FINANCIAL_DATA_GLOBAL CAN_MANAGE_PERMISSIONS_GLOBAL
    CAN_EDIT_GAMES_GLOBAL CAN_PUBLISH_GAMES_GLOBAL CAN_REPLY_TO_REVIEWS_GLOBAL
    CAN_MANAGE_PUBLIC_APKS_GLOBAL CAN_MANAGE_TRACK_APKS_GLOBAL
    CAN_MANAGE_TRACK_USERS_GLOBAL CAN_MANAGE_PUBLIC_LISTING_GLOBAL
    CAN_MANAGE_DRAFT_APPS_GLOBAL CAN_CREATE_MANAGED_PLAY_APPS_GLOBAL
    CAN_MANAGE_ORDERS_GLOBAL CAN_MANAGE_APP_CONTENT_GLOBAL
    CAN_VIEW_NON_FINANCIAL_DATA_GLOBAL CAN_VIEW_APP_QUALITY_GLOBAL
    CAN_MANAGE_DEEPLINKS_GLOBAL CAN_VIEW_CONNECTED_APPS_GLOBAL
    CAN_EDIT_CONNECTED_APPS_GLOBAL
  )

  # ── URLs ─────────────────────────────────────────────────────────────────────

  describe "build_users_url/1" do
    test "targets users.create under developers/{id}" do
      assert PlaySetup.build_users_url("8569215364300153981") ==
               "#{@play}/developers/8569215364300153981/users"
    end
  end

  describe "build_grants_url/2" do
    test "targets grants.create under developers/{id}/users/{email}" do
      assert PlaySetup.build_grants_url("123", "sa@proj.iam.gserviceaccount.com") ==
               "#{@play}/developers/123/users/sa%40proj.iam.gserviceaccount.com/grants"
    end
  end

  # ── Request bodies ───────────────────────────────────────────────────────────

  describe "build_user_request/2 — account-level (nil package)" do
    test "names the service account and grants account-wide release permissions" do
      assert PlaySetup.build_user_request("sa@proj.iam.gserviceaccount.com", nil) == %{
               "email" => "sa@proj.iam.gserviceaccount.com",
               "developerAccountPermissions" => PlaySetup.release_manager_permissions(:developer)
             }
    end
  end

  describe "build_user_request/2 — app-level (with package)" do
    test "creates the user with no account-level permission" do
      assert PlaySetup.build_user_request("sa@proj.iam.gserviceaccount.com", "com.example.app") ==
               %{"email" => "sa@proj.iam.gserviceaccount.com"}
    end
  end

  describe "build_grant_request/1" do
    test "grants the release permissions on the package" do
      assert PlaySetup.build_grant_request("com.example.app") == %{
               "packageName" => "com.example.app",
               "appLevelPermissions" => PlaySetup.release_manager_permissions(:app)
             }
    end
  end

  # ── Permissions ──────────────────────────────────────────────────────────────

  describe "release_manager_permissions/1" do
    test "app-level permissions are AppLevelPermission values" do
      perms = PlaySetup.release_manager_permissions(:app)
      assert [_ | _] = perms
      assert perms -- @api_app_permissions == []
    end

    test "developer-level permissions are DeveloperLevelPermission values" do
      perms = PlaySetup.release_manager_permissions(:developer)
      assert [_ | _] = perms
      assert perms -- @api_developer_permissions == []
    end

    test "both levels can release to testing tracks and production" do
      assert "CAN_MANAGE_TRACK_APKS" in PlaySetup.release_manager_permissions(:app)
      assert "CAN_MANAGE_PUBLIC_APKS" in PlaySetup.release_manager_permissions(:app)
      assert "CAN_MANAGE_TRACK_APKS_GLOBAL" in PlaySetup.release_manager_permissions(:developer)
      assert "CAN_MANAGE_PUBLIC_APKS_GLOBAL" in PlaySetup.release_manager_permissions(:developer)
    end
  end
end
