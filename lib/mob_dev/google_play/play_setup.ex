defmodule MobDev.GooglePlay.PlaySetup do
  @moduledoc """
  Google Play Developer API operations for granting service account access.

  Handles the one automatable step in the Play Console setup: granting
  "Release manager" permissions to the service account via the Play
  Developer API `accounts.grants` resource.

  ## What this replaces

  The manual steps documented in the publishing guide (Part A and Part B of
  section 1.4.4) grant the service account two types of access:

  - **API access page** (Part A) — account-level permissions to manage releases
  - **Users and permissions** (Part B) — the same grant surfaced via a different
    Play Console UI path

  Both are handled by a single `accounts.grants.create` API call here.

  ## Prerequisite that cannot be automated

  Before this call will work, you must manually link your Google Cloud project
  to Play Console:

    Play Console → Setup → API access → Link to a Google Cloud project

  This one-time step has no API — it must be done in the browser.

  ## Finding your developer account ID

  The `developer_account_id` is the numeric ID visible in the Play Console URL:

      https://play.google.com/console/u/0/developers/**5074092065751960701**/...

  It is also printed on the Play Console dashboard.

  ## Permission note

  The Release Manager role grants `CAN_MANAGE_RELEASES` and `CAN_ACCESS_DRAFT_APPS`.
  Verify the exact permission enum values against the Play Developer API docs if this
  call returns a 400 — Google has not always published these consistently.
  """

  alias MobDev.GooglePlay.HTTP

  @play "https://androidpublisher.googleapis.com/androidpublisher/v3"

  # Permissions that together approximate the "Release Manager" role in Play Console.
  # Verify these at: https://developers.google.com/android-publisher/api-ref/rest/v3/accounts.grants
  @release_manager_permissions ["CAN_MANAGE_RELEASES", "CAN_ACCESS_DRAFT_APPS"]

  @doc """
  Grants Release Manager access to a service account on the developer's Play account.

  `developer_account_id` — the numeric ID from the Play Console URL (see moduledoc).
  `service_account_email` — the service account email (e.g. `play-publisher@project.iam.gserviceaccount.com`).
  `package_name` — optional; if provided, grants app-level access only.
                   Omit (or pass `nil`) for account-level access.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec grant_release_manager(String.t(), String.t(), String.t(), String.t() | nil) ::
          :ok | {:error, String.t()}
  def grant_release_manager(
        token,
        developer_account_id,
        service_account_email,
        package_name \\ nil
      ) do
    HTTP.ensure_started!()
    url = "#{@play}/accounts/#{developer_account_id}/grants"

    body = build_grant_request(service_account_email, package_name)

    case HTTP.post(url, HTTP.json_headers(token), Jason.encode!(body)) do
      {:ok, _} -> :ok
      {:error, "HTTP 409: " <> _} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc """
  Builds the request body for an `accounts.grants.create` API call.

  Pure function — useful for testing without making HTTP calls.

  When `package_name` is nil, returns an account-level grant (Release Manager
  permissions on all apps in the developer account). When `package_name` is
  provided, returns an app-level grant for that package only.
  """
  @spec build_grant_request(String.t(), String.t() | nil) :: map()
  def build_grant_request(service_account_email, nil) do
    %{
      "grantee" => service_account_email,
      "developerAccountPermissions" => @release_manager_permissions
    }
  end

  def build_grant_request(service_account_email, package_name) do
    %{
      "grantee" => service_account_email,
      "packageName" => package_name,
      "appLevelPermissions" => @release_manager_permissions
    }
  end

  @doc """
  Returns the permission strings used for the Release Manager role.
  """
  @spec release_manager_permissions() :: [String.t()]
  def release_manager_permissions, do: @release_manager_permissions
end
