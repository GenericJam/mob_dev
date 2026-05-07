defmodule MobDev.GooglePlay.CloudSetup do
  @moduledoc """
  Google Cloud REST API operations for the Play Store setup wizard.

  Covers the three Google Cloud steps that `mix mob.setup.google_play` automates:
  - Enabling the Android Publisher API in a Cloud project
  - Creating a `play-publisher` service account
  - Generating and saving a JSON key for that service account

  All functions take an OAuth2 `access_token` obtained from `MobDev.GooglePlay.OAuth`.

  ## API surface used

  | Step | API |
  |------|-----|
  | List projects | Cloud Resource Manager v3 |
  | Enable Android Publisher API | Service Usage v1 |
  | Create service account | IAM v1 |
  | Create JSON key | IAM v1 |
  """

  alias MobDev.GooglePlay.HTTP

  @crm "https://cloudresourcemanager.googleapis.com/v3"
  @iam "https://iam.googleapis.com/v1"
  @service_usage "https://serviceusage.googleapis.com/v1"
  @publisher_api "androidpublisher.googleapis.com"
  @service_account_id "play-publisher"

  # ── Projects ─────────────────────────────────────────────────────────────────

  @doc """
  Lists Google Cloud projects accessible to the authenticated user.

  Returns `{:ok, [%{"projectId" => id, "displayName" => name, ...}]}` or
  `{:error, reason}`.
  """
  @spec list_projects(String.t()) :: {:ok, [map()]} | {:error, String.t()}
  def list_projects(token) do
    HTTP.ensure_started!()
    url = "#{@crm}/projects?pageSize=100"

    case HTTP.get(url, HTTP.json_headers(token)) do
      {:ok, %{"projects" => projects}} -> {:ok, projects}
      {:ok, resp} -> {:ok, Map.get(resp, "projects", [])}
      {:error, _} = err -> err
    end
  end

  @doc """
  Parses the `projects` list from a Cloud Resource Manager response body.

  Pure function — used for testing without HTTP calls.
  """
  @spec parse_projects_response(map()) :: [map()]
  def parse_projects_response(%{"projects" => projects}), do: projects
  def parse_projects_response(_), do: []

  # ── Enable API ───────────────────────────────────────────────────────────────

  @doc """
  Enables the Android Publisher API in the given Cloud project.

  The operation may take up to 60 seconds; this function polls until complete.
  Returns `:ok` or `{:error, reason}`.
  """
  @spec enable_publisher_api(String.t(), String.t()) :: :ok | {:error, String.t()}
  def enable_publisher_api(token, project_id) do
    HTTP.ensure_started!()
    url = build_enable_api_url(project_id, @publisher_api)

    case HTTP.post(url, HTTP.json_headers(token), "{}") do
      {:ok, %{"name" => op_name}} ->
        poll_operation(token, op_name)

      {:ok, %{"done" => true}} ->
        :ok

      {:ok, resp} ->
        {:error, "Unexpected enable API response: #{inspect(resp)}"}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Builds the Service Usage API URL for enabling a specific service.

  Pure function — useful for testing and debugging.
  """
  @spec build_enable_api_url(String.t(), String.t()) :: String.t()
  def build_enable_api_url(project_id, service_name) do
    "#{@service_usage}/projects/#{project_id}/services/#{service_name}:enable"
  end

  # ── Service account ──────────────────────────────────────────────────────────

  @doc """
  Creates the `play-publisher` service account in the given Cloud project.

  Returns `{:ok, email}` where `email` is the service account email, or
  `{:error, reason}`.

  If the service account already exists (HTTP 409), returns its email
  without error.
  """
  @spec create_service_account(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def create_service_account(token, project_id, display_name \\ "Mob Play Publisher") do
    HTTP.ensure_started!()
    url = "#{@iam}/projects/#{project_id}/serviceAccounts"

    body =
      Jason.encode!(%{
        "accountId" => @service_account_id,
        "serviceAccount" => %{"displayName" => display_name}
      })

    case HTTP.post(url, HTTP.json_headers(token), body) do
      {:ok, %{"email" => email}} ->
        {:ok, email}

      {:error, "HTTP 409: " <> _} ->
        # Already exists — derive the email from the project ID.
        {:ok, "#{@service_account_id}@#{project_id}.iam.gserviceaccount.com"}

      {:error, _} = err ->
        err
    end
  end

  # ── JSON key ─────────────────────────────────────────────────────────────────

  @doc """
  Creates a JSON key for the given service account and saves it to disk.

  The key is written to `~/.google_play/{filename}.json` (mode 600).
  Returns `{:ok, path}` where `path` is the absolute path to the saved file,
  or `{:error, reason}`.
  """
  @spec create_and_save_key(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, Path.t()} | {:error, String.t()}
  def create_and_save_key(token, project_id, service_account_email, filename) do
    HTTP.ensure_started!()
    url = "#{@iam}/projects/#{project_id}/serviceAccounts/#{service_account_email}/keys"

    case HTTP.post(url, HTTP.json_headers(token), "{}") do
      {:ok, %{"privateKeyData" => b64_json}} ->
        save_key_file(b64_json, filename)

      {:ok, resp} ->
        {:error, "Unexpected key creation response: #{inspect(resp)}"}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Decodes a base64url-encoded service account JSON key and saves it to disk.

  The `b64_json` parameter is the `privateKeyData` field from the IAM keys API
  response (standard base64, not URL-safe). Saved to `~/.google_play/{filename}.json`
  with mode 600.

  Pure IO side-effect (no HTTP) — useful for testing.
  """
  @spec save_key_file(String.t(), String.t()) :: {:ok, Path.t()} | {:error, String.t()}
  def save_key_file(b64_json, filename) do
    dir = Path.expand("~/.google_play")
    File.mkdir_p!(dir)
    path = Path.join(dir, "#{filename}.json")

    with {:ok, json_bytes} <- Base.decode64(b64_json, padding: true),
         :ok <- File.write(path, json_bytes),
         :ok <- File.chmod(path, 0o600) do
      {:ok, path}
    else
      :error -> {:error, "Could not base64-decode the key data returned by Google"}
      {:error, reason} -> {:error, "Could not write key file: #{inspect(reason)}"}
    end
  end

  # ── Long-running operation polling ──────────────────────────────────────────

  defp poll_operation(token, op_name, attempts \\ 0)

  defp poll_operation(_token, op_name, 20) do
    {:error, "Timed out waiting for operation #{op_name} to complete"}
  end

  defp poll_operation(token, op_name, attempts) do
    url = "#{@service_usage}/#{op_name}"

    case HTTP.get(url, HTTP.json_headers(token)) do
      {:ok, %{"done" => true, "error" => err}} ->
        {:error, "Operation failed: #{inspect(err)}"}

      {:ok, %{"done" => true}} ->
        :ok

      {:ok, _} ->
        Process.sleep(3_000 + attempts * 1_000)
        poll_operation(token, op_name, attempts + 1)

      {:error, _} = err ->
        err
    end
  end
end
