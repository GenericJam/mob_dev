defmodule MobDev.GooglePlay do
  @moduledoc """
  Google Play Developer API client for uploading Android App Bundles.

  Authenticates using a service account JSON key (RSA JWT → OAuth2 access token),
  then drives the Play edit workflow:
    create edit → upload .aab → assign track → commit

  ## Service account setup (one-time)

  1. Go to Play Console → Setup → API access → link to a Google Cloud project.
  2. In Google Cloud Console → IAM → Service Accounts → Create a service account.
  3. Download the JSON key for that service account.
  4. Back in Play Console → Setup → API access → grant the service account
     "Release manager" (or "Admin") permission.

  ## mob.exs config

      config :mob_dev,
        google_play: [
          package_name:         "com.example.myapp",
          service_account_json: "~/.google_play/my-service-account.json",
          track:                "internal"   # internal | alpha | beta | production
        ]
  """

  alias MobDev.GooglePlay.HTTP

  @play "https://androidpublisher.googleapis.com/androidpublisher/v3/applications"
  @upload "https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications"
  @token_url "https://oauth2.googleapis.com/token"
  @scope "https://www.googleapis.com/auth/androidpublisher"

  @doc """
  Uploads `aab_path` to Google Play and assigns it to `track`.

  Options (all required unless noted):
    - `:service_account_json` — path to the service account JSON key file
    - `:package_name` — Android applicationId (e.g. "com.beyondagronomy.aircartmax")
    - `:track` — "internal" | "alpha" | "beta" | "production" (default: "internal")

  Returns `{:ok, version_code}` or `{:error, reason}`.
  """
  @spec upload(Path.t(), keyword()) :: {:ok, integer()} | {:error, String.t()}
  def upload(aab_path, opts) do
    sa_path = Keyword.fetch!(opts, :service_account_json) |> Path.expand()
    package = Keyword.fetch!(opts, :package_name)
    track = Keyword.get(opts, :track, "internal")

    ensure_started!()

    with {:ok, sa} <- load_service_account(sa_path),
         log("Authenticating with Google..."),
         {:ok, token} <- fetch_access_token(sa),
         log("Creating edit..."),
         {:ok, edit_id} <- create_edit(token, package),
         log("Uploading #{file_size(aab_path)}..."),
         {:ok, version_code} <- upload_bundle(token, package, edit_id, aab_path),
         log("Assigning versionCode #{version_code} to #{track} track..."),
         :ok <- assign_track(token, package, edit_id, track, version_code),
         log("Committing edit..."),
         :ok <- commit_edit(token, package, edit_id) do
      {:ok, version_code}
    end
  end

  # ── Service account ──────────────────────────────────────────────────────────

  defp load_service_account(path) do
    case File.read(path) do
      {:ok, json} ->
        Jason.decode(json)

      {:error, reason} ->
        {:error, "Cannot read service account file #{path}: #{:file.format_error(reason)}"}
    end
  end

  # ── JWT / OAuth2 ─────────────────────────────────────────────────────────────

  defp fetch_access_token(sa) do
    jwt = sign_jwt(sa)

    body =
      URI.encode_query(%{
        "grant_type" => "urn:ietf:params:oauth:grant-type:jwt-bearer",
        "assertion" => jwt
      })

    case post(@token_url, [{"content-type", "application/x-www-form-urlencoded"}], body) do
      {:ok, %{"access_token" => token}} -> {:ok, token}
      {:ok, resp} -> {:error, "Token exchange failed: #{inspect(resp)}"}
      {:error, _} = err -> err
    end
  end

  defp sign_jwt(sa) do
    now = System.os_time(:second)

    header =
      %{"alg" => "RS256", "typ" => "JWT"}
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

    payload =
      %{
        "iss" => sa["client_email"],
        "scope" => @scope,
        "aud" => @token_url,
        "iat" => now,
        "exp" => now + 3600
      }
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

    input = "#{header}.#{payload}"
    key = decode_private_key(sa["private_key"])
    sig = :public_key.sign(input, :sha256, key) |> Base.url_encode64(padding: false)
    "#{input}.#{sig}"
  end

  # Google service account keys are PKCS#8 ("BEGIN PRIVATE KEY").
  # pem_entry_decode/1 handles unwrapping to the inner RSAPrivateKey.
  defp decode_private_key(pem) do
    [entry] = :public_key.pem_decode(pem)
    :public_key.pem_entry_decode(entry)
  end

  # ── Play API edit workflow ───────────────────────────────────────────────────

  defp create_edit(token, package) do
    case post("#{@play}/#{package}/edits", json_headers(token), "{}") do
      {:ok, %{"id" => id}} -> {:ok, id}
      {:ok, resp} -> {:error, "Create edit: #{inspect(resp)}"}
      err -> err
    end
  end

  defp upload_bundle(token, package, edit_id, aab_path) do
    url = "#{@upload}/#{package}/edits/#{edit_id}/bundles?uploadType=media"
    aab = File.read!(aab_path)

    headers = [
      {"authorization", "Bearer #{token}"},
      {"content-type", "application/octet-stream"}
    ]

    case post(url, headers, aab) do
      {:ok, %{"versionCode" => vc}} -> {:ok, vc}
      {:ok, resp} -> {:error, "Upload bundle: #{inspect(resp)}"}
      err -> err
    end
  end

  defp assign_track(token, package, edit_id, track, version_code) do
    url = "#{@play}/#{package}/edits/#{edit_id}/tracks/#{track}"

    body =
      Jason.encode!(%{
        "releases" => [
          %{
            "versionCodes" => [Integer.to_string(version_code)],
            "status" => "completed"
          }
        ]
      })

    case put(url, json_headers(token), body) do
      {:ok, _} -> :ok
      err -> err
    end
  end

  defp commit_edit(token, package, edit_id) do
    url = "#{@play}/#{package}/edits/#{edit_id}:commit"

    case post(url, json_headers(token), "{}") do
      {:ok, _} ->
        :ok

      {:error, msg} = err ->
        if needs_changes_not_sent_for_review?(msg) do
          # Google won't auto-send these changes for review (e.g. a release while
          # the app is under policy review). Commit without sending — the changes
          # are then sent for review from the Play Console UI.
          log(
            "changes can't be auto-sent for review — committing with " <>
              "changesNotSentForReview=true (send for review from the Console)"
          )

          case post("#{url}?changesNotSentForReview=true", json_headers(token), "{}") do
            {:ok, _} -> :ok
            retry_err -> retry_err
          end
        else
          err
        end
    end
  end

  # True when a commit failed solely because Google requires the
  # changesNotSentForReview flag (app under policy review, etc). The Play API
  # names the query parameter verbatim in the 400 body.
  @doc false
  @spec needs_changes_not_sent_for_review?(String.t()) :: boolean()
  def needs_changes_not_sent_for_review?(error_message) when is_binary(error_message) do
    String.contains?(error_message, "changesNotSentForReview")
  end

  # ── HTTP ─────────────────────────────────────────────────────────────────────

  defp post(url, headers, body), do: HTTP.post(url, headers, body)
  defp put(url, headers, body), do: HTTP.put(url, headers, body)
  defp json_headers(token), do: HTTP.json_headers(token)

  defp ensure_started!, do: HTTP.ensure_started!()

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: b}} when b >= 1_048_576 ->
        :io_lib.format("~.1fMB", [b / 1_048_576]) |> List.flatten() |> to_string()

      {:ok, %{size: b}} ->
        :io_lib.format("~.1fKB", [b / 1024]) |> List.flatten() |> to_string()

      _ ->
        "?"
    end
  end

  defp log(msg), do: Mix.shell().info("  #{msg}")
end
