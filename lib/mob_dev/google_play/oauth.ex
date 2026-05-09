defmodule MobDev.GooglePlay.OAuth do
  @moduledoc """
  OAuth2 browser-based authorization for Google APIs.

  Opens the user's default browser to Google's consent screen, then listens
  on a random localhost port for the authorization code callback. No external
  CLI tool (gcloud, etc.) is required — only a browser.

  ## OAuth client registration

  This module ships with placeholder client credentials. Before `authorize/1`
  will work you must register a Google OAuth "Desktop app" client:

    1. Go to https://console.cloud.google.com/apis/credentials
    2. Click **Create credentials → OAuth client ID**
    3. Application type: **Desktop app** — name it `mob_dev CLI`
    4. Click **Create** — note the **Client ID** and **Client secret**
    5. Fill in `@default_client_id` and `@default_client_secret` in this file

  For installed CLI tools, the client_secret is not actually secret — this
  follows Google's documented guidance for desktop applications (the same
  model used by the gcloud CLI). The token is only obtainable by a user who
  explicitly grants consent via their browser.

  You can also override with environment variables:
  `GOOGLE_OAUTH_CLIENT_ID` / `GOOGLE_OAUTH_CLIENT_SECRET`.
  """

  alias MobDev.GooglePlay.HTTP

  # TODO: register at https://console.cloud.google.com/apis/credentials
  # Application type: Desktop app. Fill in the values below after registration.
  @default_client_id "TODO_REGISTER.apps.googleusercontent.com"
  @default_client_secret "TODO_REGISTER_SECRET"

  @auth_url "https://accounts.google.com/o/oauth2/v2/auth"
  @token_url "https://oauth2.googleapis.com/token"

  # Scopes for the setup wizard:
  # cloud-platform  → enable APIs, create service accounts and keys (GCP APIs)
  # androidpublisher → grant Play Console access to the service account
  @setup_scopes [
    "https://www.googleapis.com/auth/cloud-platform",
    "https://www.googleapis.com/auth/androidpublisher"
  ]

  @doc """
  Returns the scopes requested during the setup wizard OAuth flow.
  """
  @spec setup_scopes() :: [String.t()]
  def setup_scopes, do: @setup_scopes

  @doc """
  Runs the browser-based OAuth2 flow and returns a bearer access token.

  Opens the user's browser to the Google consent screen, then waits up to
  `timeout_ms` milliseconds (default 120 000) for the callback redirect.

  Options:
  - `:scopes` — list of OAuth scope strings (required)
  - `:timeout_ms` — callback wait timeout in ms (default: 120_000)

  Returns `{:ok, access_token}` or `{:error, reason}`.
  """
  @spec authorize(keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def authorize(opts \\ []) do
    scopes = Keyword.fetch!(opts, :scopes)
    timeout_ms = Keyword.get(opts, :timeout_ms, 120_000)
    client_id = System.get_env("GOOGLE_OAUTH_CLIENT_ID", @default_client_id)
    client_secret = System.get_env("GOOGLE_OAUTH_CLIENT_SECRET", @default_client_secret)

    if String.starts_with?(client_id, "TODO") do
      {:error,
       "OAuth client not registered yet. " <>
         "See MobDev.GooglePlay.OAuth moduledoc for registration steps."}
    else
      HTTP.ensure_started!()

      with {:ok, port} <- find_free_port(),
           redirect_uri = "http://localhost:#{port}/callback",
           url = build_auth_url(client_id, scopes, redirect_uri),
           :ok <- open_browser(url),
           {:ok, code} <- await_callback(port, timeout_ms),
           {:ok, tokens} <- exchange_code(client_id, client_secret, code, redirect_uri) do
        {:ok, tokens["access_token"]}
      end
    end
  end

  @doc """
  Builds the Google OAuth2 authorization URL.

  Pure function — useful for testing and for displaying the URL in case
  the automatic browser open fails.
  """
  @spec build_auth_url(String.t(), [String.t()], String.t()) :: String.t()
  def build_auth_url(client_id, scopes, redirect_uri) do
    params = %{
      "client_id" => client_id,
      "redirect_uri" => redirect_uri,
      "response_type" => "code",
      "scope" => Enum.join(scopes, " "),
      "access_type" => "offline",
      "prompt" => "consent"
    }

    "#{@auth_url}?#{URI.encode_query(params)}"
  end

  @doc """
  Parses the authorization code from an OAuth callback HTTP request line.

  The request line has the form:
      GET /callback?code=AUTH_CODE&scope=... HTTP/1.1

  Returns `{:ok, code}` or `{:error, reason}`.
  """
  @spec parse_callback_request(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def parse_callback_request(request_line) do
    case Regex.run(Regex.compile!(~S{(?:GET|HEAD) /[^?]*\?([^ ]+)}), request_line) do
      [_, query] ->
        params = URI.decode_query(query)

        case {params["code"], params["error"]} do
          {code, nil} when is_binary(code) and code != "" ->
            {:ok, code}

          {_, error} when is_binary(error) ->
            {:error, "Google denied access: #{error}"}

          _ ->
            {:error, "No code or error in callback query: #{query}"}
        end

      _ ->
        {:error, "Unexpected callback request: #{String.slice(request_line, 0, 100)}"}
    end
  end

  # ── Internals ────────────────────────────────────────────────────────────────

  defp find_free_port do
    case :gen_tcp.listen(0, [:binary, active: false]) do
      {:ok, sock} ->
        {:ok, port} = :inet.port(sock)
        :gen_tcp.close(sock)
        {:ok, port}

      {:error, reason} ->
        {:error, "Could not find a free port: #{inspect(reason)}"}
    end
  end

  defp open_browser(url) do
    cmd =
      case :os.type() do
        {:unix, :darwin} -> {"open", [url]}
        {:unix, _} -> {"xdg-open", [url]}
        {:win32, _} -> {"cmd", ["/c", "start", url]}
      end

    Mix.shell().info("  Opening browser to Google sign-in...")
    Mix.shell().info("  If it doesn't open automatically, visit:")
    Mix.shell().info("    #{url}")
    Mix.shell().info("")

    {bin, args} = cmd

    case System.find_executable(bin) do
      nil -> :ok
      _ -> System.cmd(bin, args, stderr_to_stdout: true)
    end

    :ok
  end

  defp await_callback(port, timeout_ms) do
    case :gen_tcp.listen(port, [:binary, packet: :line, active: false, reuseaddr: true]) do
      {:ok, server} ->
        Mix.shell().info("  Waiting for browser sign-in (#{div(timeout_ms, 1000)}s timeout)...")

        result =
          case :gen_tcp.accept(server, timeout_ms) do
            {:ok, conn} ->
              handle_callback_connection(conn)

            {:error, :timeout} ->
              {:error, "Timed out waiting for OAuth callback — did the browser open?"}

            {:error, reason} ->
              {:error, "Callback listener error: #{inspect(reason)}"}
          end

        :gen_tcp.close(server)
        result

      {:error, reason} ->
        {:error, "Could not start callback listener on port #{port}: #{inspect(reason)}"}
    end
  end

  defp handle_callback_connection(conn) do
    result =
      case :gen_tcp.recv(conn, 0, 10_000) do
        {:ok, request_line} -> parse_callback_request(request_line)
        {:error, reason} -> {:error, "Could not read callback request: #{inspect(reason)}"}
      end

    html = callback_html(result)

    response =
      "HTTP/1.1 200 OK\r\n" <>
        "Content-Type: text/html\r\n" <>
        "Content-Length: #{byte_size(html)}\r\n" <>
        "Connection: close\r\n\r\n" <>
        html

    :gen_tcp.send(conn, response)
    :gen_tcp.close(conn)
    result
  end

  defp callback_html({:ok, _}) do
    "<html><body><h1>Authenticated</h1>" <>
      "<p>Sign-in successful. You can close this tab and return to the terminal.</p>" <>
      "</body></html>"
  end

  defp callback_html({:error, reason}) do
    "<html><body><h1>Authentication failed</h1>" <>
      "<p>#{html_escape(reason)}</p>" <>
      "<p>Close this tab and check the terminal for details.</p>" <>
      "</body></html>"
  end

  # Minimal HTML entity escaping — the error message comes from Google, not user input,
  # but be safe.
  defp html_escape(str) do
    str
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp exchange_code(client_id, client_secret, code, redirect_uri) do
    body =
      URI.encode_query(%{
        "code" => code,
        "client_id" => client_id,
        "client_secret" => client_secret,
        "redirect_uri" => redirect_uri,
        "grant_type" => "authorization_code"
      })

    headers = [{"content-type", "application/x-www-form-urlencoded"}]

    case HTTP.post(@token_url, headers, body) do
      {:ok, %{"access_token" => _} = tokens} ->
        {:ok, tokens}

      {:ok, resp} ->
        {:error, "Token exchange returned unexpected response: #{inspect(resp)}"}

      {:error, _} = err ->
        err
    end
  end
end
