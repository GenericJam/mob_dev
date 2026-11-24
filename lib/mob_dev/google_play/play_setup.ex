defmodule MobDev.GooglePlay.PlaySetup do
  @moduledoc """
  Google Play Developer API operations for granting service account access.

  Handles the one automatable step in the Play Console setup: inviting the
  service account to the developer account with release permissions, through
  the Play Developer API `users` and `grants` resources.

  ## What this replaces

  The manual steps documented in the publishing guide (Part A and Part B of
  section 1.4.4) both end in the same Play Console invitation of the service
  account. Here it takes one or two API calls:

  - **Account-level** (no package name) — `users.create` with
    `developerAccountPermissions`, which apply to every app in the account.
  - **App-level** (package name given) — `users.create` with no account-level
    permissions, then `grants.create` with `appLevelPermissions` on that
    package.

  A user or grant that already exists (HTTP 409) counts as success, so the
  wizard can be re-run.

  ## Prerequisite that cannot be automated

  Before these calls will work, you must manually link your Google Cloud project
  to Play Console:

    Play Console → Setup → API access → Link to a Google Cloud project

  This one-time step has no API — it must be done in the browser.

  ## Finding your developer account ID

  The `developer_account_id` is the numeric ID visible in the Play Console URL:

      https://play.google.com/console/u/0/developers/**5074092065751960701**/...

  It is also printed on the Play Console dashboard.

  ## Permissions

  Play Console's "Release manager" has no API equivalent. The permissions
  granted are the ones publishing needs: release to testing tracks, release to
  production, and manage draft apps (an app that has never been published is a
  draft). See the `AppLevelPermission` and `DeveloperLevelPermission` enums at
  https://developers.google.com/android-publisher/api-ref/rest/v3/users
  """

  alias MobDev.GooglePlay.HTTP

  @play "https://androidpublisher.googleapis.com/androidpublisher/v3"

  @app_permissions ["CAN_MANAGE_TRACK_APKS", "CAN_MANAGE_PUBLIC_APKS", "CAN_MANAGE_DRAFT_APPS"]

  @developer_permissions [
    "CAN_MANAGE_TRACK_APKS_GLOBAL",
    "CAN_MANAGE_PUBLIC_APKS_GLOBAL",
    "CAN_MANAGE_DRAFT_APPS_GLOBAL"
  ]

  @doc """
  Grants release access to a service account on the developer's Play account.

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
    headers = HTTP.json_headers(token)

    with :ok <-
           create(
             build_users_url(developer_account_id),
             headers,
             build_user_request(service_account_email, package_name)
           ) do
      if package_name do
        create(
          build_grants_url(developer_account_id, service_account_email),
          headers,
          build_grant_request(package_name)
        )
      else
        :ok
      end
    end
  end

  defp create(url, headers, body) do
    case HTTP.post(url, headers, Jason.encode!(body)) do
      {:ok, _} -> :ok
      {:error, "HTTP 409: " <> _} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc """
  Builds the `users.create` URL for a developer account.

  Pure function — useful for testing and debugging.
  """
  @spec build_users_url(String.t()) :: String.t()
  def build_users_url(developer_account_id) do
    "#{@play}/developers/#{developer_account_id}/users"
  end

  @doc """
  Builds the `grants.create` URL for a user of a developer account.

  The email is percent-encoded as one path segment.

  Pure function — useful for testing and debugging.
  """
  @spec build_grants_url(String.t(), String.t()) :: String.t()
  def build_grants_url(developer_account_id, email) do
    "#{build_users_url(developer_account_id)}/#{URI.encode(email, &URI.char_unreserved?/1)}/grants"
  end

  @doc """
  Builds the `users.create` request body (a `User` resource).

  With no package name, the user gets the release permissions on the whole
  developer account. With a package name, the user is created with no
  account-level permission, and `build_grant_request/1` scopes them to the app.

  Pure function — useful for testing without making HTTP calls.
  """
  @spec build_user_request(String.t(), String.t() | nil) :: map()
  def build_user_request(service_account_email, nil) do
    %{
      "email" => service_account_email,
      "developerAccountPermissions" => @developer_permissions
    }
  end

  def build_user_request(service_account_email, _package_name) do
    %{"email" => service_account_email}
  end

  @doc """
  Builds the `grants.create` request body (a `Grant` resource) for one app.

  Pure function — useful for testing without making HTTP calls.
  """
  @spec build_grant_request(String.t()) :: map()
  def build_grant_request(package_name) do
    %{"packageName" => package_name, "appLevelPermissions" => @app_permissions}
  end

  @doc """
  Returns the release permissions granted, at `:app` or `:developer` level.
  """
  @spec release_manager_permissions(:app | :developer) :: [String.t()]
  def release_manager_permissions(:app), do: @app_permissions
  def release_manager_permissions(:developer), do: @developer_permissions
end
