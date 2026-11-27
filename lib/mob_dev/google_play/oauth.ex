defmodule MobDev.GooglePlay.OAuth do
  @moduledoc """
  OAuth2 browser-based authorization for Google APIs.

  Opens the user's default browser to Google's consent screen, then listens
  on a random port on `127.0.0.1` for the authorization code callback. No
  external CLI tool (gcloud, etc.) is required — only a browser.

  Each sign-in sends a random `state` and a PKCE (S256) code challenge. A
  callback whose `state` does not match is answered with 400 and ignored, and
  the code is exchanged together with the PKCE verifier, so only this process
  can redeem it.

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

  @loopback {127, 0, 0, 1}

  # Scopes for the setup wizard:
  # cloud-platform  → enable APIs, create service accounts and keys (GCP APIs)
  # androidpublisher → grant Play Console access to the service account
  @setup_scopes [
    "https://www.googleapis.com/auth/cloud-platform",
    "https://www.googleapis.com/auth/androidpublisher"
  ]

  @typedoc "The per-sign-in secrets: the `state` value and the PKCE verifier and challenge."
  @type request :: %{state: String.t(), code_verifier: String.t(), code_challenge: String.t()}

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

      with {:ok, server, port} <- open_listener() do
        try do
          io = %{open_browser: &open_browser/1, exchange_code: &exchange_code/1}
          sign_in(server, port, {client_id, client_secret}, scopes, timeout_ms, io)
        after
          :gen_tcp.close(server)
        end
      end
    end
  end

  @doc false
  # One sign-in on an open listener. `io` carries the browser opener and the
  # token exchange so tests can drive the whole flow without either.
  @spec sign_in(
          :gen_tcp.socket(),
          :inet.port_number(),
          {String.t(), String.t()},
          [String.t()],
          non_neg_integer(),
          %{open_browser: (String.t() -> term()), exchange_code: (String.t() -> term())}
        ) :: {:ok, String.t()} | {:error, String.t()}
  def sign_in(server, port, {client_id, client_secret}, scopes, timeout_ms, io) do
    request = new_request()
    redirect_uri = "http://127.0.0.1:#{port}/callback"

    io.open_browser.(build_auth_url(client_id, scopes, redirect_uri, request))
    Mix.shell().info("  Waiting for browser sign-in (#{div(timeout_ms, 1000)}s timeout)...")

    with {:ok, code} <- await_callback(server, request.state, timeout_ms),
         body =
           token_request_body(client_id, client_secret, code, redirect_uri, request.code_verifier),
         {:ok, tokens} <- io.exchange_code.(body) do
      {:ok, tokens["access_token"]}
    end
  end

  @doc """
  Generates the per-sign-in secrets: a random `state` and a PKCE verifier
  with its S256 challenge.
  """
  @spec new_request() :: request()
  def new_request do
    verifier = random_urlsafe(32)

    %{
      state: random_urlsafe(32),
      code_verifier: verifier,
      code_challenge: code_challenge(verifier)
    }
  end

  @doc "The PKCE S256 code challenge for `verifier` (RFC 7636 §4.2)."
  @spec code_challenge(String.t()) :: String.t()
  def code_challenge(verifier),
    do: :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false)

  @doc """
  Builds the Google OAuth2 authorization URL, carrying the request's `state`
  and PKCE code challenge.

  Pure function — useful for testing and for displaying the URL in case
  the automatic browser open fails.
  """
  @spec build_auth_url(String.t(), [String.t()], String.t(), request()) :: String.t()
  def build_auth_url(client_id, scopes, redirect_uri, %{state: state, code_challenge: challenge}) do
    params = %{
      "client_id" => client_id,
      "redirect_uri" => redirect_uri,
      "response_type" => "code",
      "scope" => Enum.join(scopes, " "),
      "access_type" => "offline",
      "prompt" => "consent",
      "state" => state,
      "code_challenge" => challenge,
      "code_challenge_method" => "S256"
    }

    "#{@auth_url}?#{URI.encode_query(params)}"
  end

  @doc """
  Parses an OAuth callback HTTP request line against the expected `state`.

  The request line has the form:
      GET /callback?state=STATE&code=AUTH_CODE&scope=... HTTP/1.1

  Returns `{:ok, code}`, `{:error, reason}` when Google reports an error for
  this sign-in, or `{:ignore, reason}` when the request is not this sign-in's
  callback (wrong or missing `state`, another path, unparseable). An ignored
  request never yields a code.
  """
  @spec parse_callback_request(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()} | {:ignore, String.t()}
  def parse_callback_request(request_line, expected_state) do
    with [_, query] <-
           Regex.run(Regex.compile!(~S{^(?:GET|HEAD) /callback\?([^ ]+)}), request_line),
         params = URI.decode_query(query),
         true <- state_matches?(params["state"], expected_state) do
      case {params["code"], params["error"]} do
        {code, nil} when is_binary(code) and code != "" ->
          {:ok, code}

        {_, error} when is_binary(error) ->
          {:error, "Google denied access: #{error}"}

        _ ->
          {:error, "No code or error in callback query"}
      end
    else
      false -> {:ignore, "Callback state does not match this sign-in"}
      _ -> {:ignore, "Unexpected callback request: #{String.slice(request_line, 0, 100)}"}
    end
  end

  @doc false
  # Listens on a random loopback port. The socket stays open from here until
  # the callback arrives, so no other process can take the port in between.
  @spec open_listener() :: {:ok, :gen_tcp.socket(), :inet.port_number()} | {:error, String.t()}
  def open_listener do
    case :gen_tcp.listen(0, [:binary, packet: :line, active: false, ip: @loopback]) do
      {:ok, server} ->
        {:ok, port} = :inet.port(server)
        {:ok, server, port}

      {:error, reason} ->
        {:error, "Could not start callback listener: #{inspect(reason)}"}
    end
  end

  @doc false
  # Accepts connections until one carries this sign-in's state, or the
  # timeout passes. Other requests get 400 and do not end the wait.
  @spec await_callback(:gen_tcp.socket(), String.t(), non_neg_integer()) ::
          {:ok, String.t()} | {:error, String.t()}
  def await_callback(server, expected_state, timeout_ms) do
    accept_until(server, expected_state, System.monotonic_time(:millisecond) + timeout_ms)
  end

  @doc false
  # The token endpoint form body; carries the PKCE verifier.
  @spec token_request_body(String.t(), String.t(), String.t(), String.t(), String.t()) ::
          String.t()
  def token_request_body(client_id, client_secret, code, redirect_uri, code_verifier) do
    URI.encode_query(%{
      "code" => code,
      "client_id" => client_id,
      "client_secret" => client_secret,
      "redirect_uri" => redirect_uri,
      "grant_type" => "authorization_code",
      "code_verifier" => code_verifier
    })
  end

  # ── Internals ────────────────────────────────────────────────────────────────

  defp random_urlsafe(bytes),
    do: bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp state_matches?(given, expected) when is_binary(given) and is_binary(expected),
    do: Plug.Crypto.secure_compare(given, expected)

  defp state_matches?(_given, _expected), do: false

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

  # Errors from a client that connected and reset before accept; the
  # listener is still good, so keep waiting.
  @transient_accept_errors [:einval, :econnaborted, :econnreset]
  @recv_timeout_ms 10_000

  defp accept_until(server, expected_state, deadline) do
    case remaining_ms(deadline) do
      0 ->
        callback_timeout()

      remaining ->
        server |> :gen_tcp.accept(remaining) |> on_accept(server, expected_state, deadline)
    end
  end

  defp on_accept({:ok, conn}, server, expected_state, deadline) do
    recv_timeout = min(@recv_timeout_ms, remaining_ms(deadline))

    case handle_callback_connection(conn, expected_state, recv_timeout) do
      {:ignore, _reason} -> accept_until(server, expected_state, deadline)
      result -> result
    end
  end

  defp on_accept({:error, :timeout}, _server, _expected_state, _deadline), do: callback_timeout()

  defp on_accept({:error, reason}, server, expected_state, deadline)
       when reason in @transient_accept_errors,
       do: accept_until(server, expected_state, deadline)

  defp on_accept({:error, reason}, _server, _expected_state, _deadline),
    do: {:error, "Callback listener error: #{inspect(reason)}"}

  defp remaining_ms(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp callback_timeout,
    do: {:error, "Timed out waiting for OAuth callback — did the browser open?"}

  defp handle_callback_connection(conn, expected_state, recv_timeout) do
    result =
      case :gen_tcp.recv(conn, 0, recv_timeout) do
        {:ok, request_line} -> parse_callback_request(request_line, expected_state)
        {:error, reason} -> {:ignore, "Could not read callback request: #{inspect(reason)}"}
      end

    html = callback_html(result)
    status = if match?({:ignore, _}, result), do: "400 Bad Request", else: "200 OK"

    response =
      "HTTP/1.1 #{status}\r\n" <>
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

  defp callback_html({:ignore, _reason}) do
    "<html><body><h1>Not this sign-in</h1>" <>
      "<p>This request does not match the sign-in in progress.</p>" <>
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

  defp exchange_code(body) do
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
