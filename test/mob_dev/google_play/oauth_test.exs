defmodule MobDev.GooglePlay.OAuthTest do
  use ExUnit.Case, async: true

  alias MobDev.GooglePlay.OAuth

  @request %{state: "st4te", code_verifier: "v3rifier", code_challenge: "ch4llenge"}

  defp auth_params(url), do: URI.decode_query(URI.parse(url).query)

  # ── build_auth_url/4 ─────────────────────────────────────────────────────────

  describe "build_auth_url/4" do
    test "includes client_id" do
      url =
        OAuth.build_auth_url(
          "my_client_id",
          ["scope1"],
          "http://127.0.0.1:1234/callback",
          @request
        )

      assert url =~ "client_id=my_client_id"
    end

    test "includes redirect_uri encoded" do
      url = OAuth.build_auth_url("id", ["scope1"], "http://127.0.0.1:1234/callback", @request)
      assert auth_params(url)["redirect_uri"] == "http://127.0.0.1:1234/callback"
    end

    test "joins multiple scopes with a space (URL-encoded as +)" do
      url =
        OAuth.build_auth_url(
          "id",
          [
            "https://www.googleapis.com/auth/cloud-platform",
            "https://www.googleapis.com/auth/androidpublisher"
          ],
          "http://127.0.0.1:9/callback",
          @request
        )

      decoded = auth_params(url)
      assert decoded["scope"] =~ "cloud-platform"
      assert decoded["scope"] =~ "androidpublisher"
    end

    test "requests offline access" do
      url = OAuth.build_auth_url("id", ["s"], "http://127.0.0.1:1/callback", @request)
      assert url =~ "access_type=offline"
    end

    test "includes prompt=consent to force refresh token" do
      url = OAuth.build_auth_url("id", ["s"], "http://127.0.0.1:1/callback", @request)
      assert url =~ "prompt=consent"
    end

    test "points to Google OAuth endpoint" do
      url = OAuth.build_auth_url("id", ["s"], "http://127.0.0.1:1/callback", @request)
      assert String.starts_with?(url, "https://accounts.google.com/o/oauth2/v2/auth")
    end

    test "carries the request's state and S256 PKCE challenge, never the verifier" do
      params =
        auth_params(OAuth.build_auth_url("id", ["s"], "http://127.0.0.1:1/callback", @request))

      assert params["state"] == "st4te"
      assert params["code_challenge"] == "ch4llenge"
      assert params["code_challenge_method"] == "S256"
      refute Enum.any?(Map.values(params), &(&1 =~ "v3rifier"))
    end
  end

  # ── new_request/0 and code_challenge/1 ───────────────────────────────────────

  describe "new_request/0" do
    test "every sign-in gets a fresh random state and verifier" do
      a = OAuth.new_request()
      b = OAuth.new_request()

      refute a.state == b.state
      refute a.code_verifier == b.code_verifier
      assert byte_size(a.state) >= 43
    end

    test "the verifier is RFC 7636 shaped and the challenge is its S256 hash" do
      %{code_verifier: verifier, code_challenge: challenge} = OAuth.new_request()

      assert byte_size(verifier) in 43..128
      assert verifier =~ Regex.compile!("^[A-Za-z0-9._~-]+$")
      assert challenge == OAuth.code_challenge(verifier)
    end

    test "code_challenge/1 matches the RFC 7636 appendix B example" do
      # Public test vector from RFC 7636 Appendix B, not a secret.
      # ggignore
      verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"

      assert OAuth.code_challenge(verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
    end
  end

  # ── token_request_body/5 ─────────────────────────────────────────────────────

  describe "token_request_body/5" do
    test "sends the PKCE verifier with the code" do
      body =
        OAuth.token_request_body(
          "id",
          "secret",
          "c0de",
          "http://127.0.0.1:1/callback",
          "v3rifier"
        )

      assert URI.decode_query(body) == %{
               "code" => "c0de",
               "client_id" => "id",
               "client_secret" => "secret",
               "redirect_uri" => "http://127.0.0.1:1/callback",
               "grant_type" => "authorization_code",
               "code_verifier" => "v3rifier"
             }
    end
  end

  # ── parse_callback_request/2 ─────────────────────────────────────────────────

  describe "parse_callback_request/2" do
    test "extracts authorization code from typical callback" do
      line = "GET /callback?state=st4te&code=4%2F0AVJP&scope=openid HTTP/1.1\r\n"
      assert {:ok, "4/0AVJP"} = OAuth.parse_callback_request(line, "st4te")
    end

    test "URL-decodes the code value" do
      line = "GET /callback?code=4%2F0AX4XfWhABC%3D&state=st4te HTTP/1.1\r\n"
      assert {:ok, "4/0AX4XfWhABC="} = OAuth.parse_callback_request(line, "st4te")
    end

    test "returns error when Google denies access" do
      line = "GET /callback?error=access_denied&state=st4te HTTP/1.1\r\n"
      assert {:error, reason} = OAuth.parse_callback_request(line, "st4te")
      assert reason =~ "access_denied"
    end

    test "returns error for unrecognised error value" do
      line = "GET /callback?error=server_error&state=st4te HTTP/1.1\r\n"
      assert {:error, reason} = OAuth.parse_callback_request(line, "st4te")
      assert reason =~ "server_error"
    end

    test "returns error when no code or error param present" do
      line = "GET /callback?state=st4te HTTP/1.1\r\n"
      assert {:error, _} = OAuth.parse_callback_request(line, "st4te")
    end

    test "handles HEAD method (same parsing)" do
      line = "HEAD /callback?code=mycode&state=st4te HTTP/1.1\r\n"
      assert {:ok, "mycode"} = OAuth.parse_callback_request(line, "st4te")
    end

    test "ignores a code whose state does not match" do
      line = "GET /callback?code=c0de&state=other HTTP/1.1\r\n"
      assert {:ignore, _} = OAuth.parse_callback_request(line, "st4te")
    end

    test "ignores a code with no state" do
      line = "GET /callback?code=c0de HTTP/1.1\r\n"
      assert {:ignore, _} = OAuth.parse_callback_request(line, "st4te")
    end

    test "ignores an error whose state does not match" do
      line = "GET /callback?error=access_denied&state=other HTTP/1.1\r\n"
      assert {:ignore, _} = OAuth.parse_callback_request(line, "st4te")
    end

    test "ignores a repeated state parameter it cannot match" do
      line = "GET /callback?code=c0de&state[]=st4te HTTP/1.1\r\n"
      assert {:ignore, _} = OAuth.parse_callback_request(line, "st4te")
    end

    test "ignores other paths and unrecognisable requests" do
      assert {:ignore, _} =
               OAuth.parse_callback_request("GET /favicon.ico?state=st4te HTTP/1.1\r\n", "st4te")

      assert {:ignore, _} = OAuth.parse_callback_request("garbage line", "st4te")
    end
  end

  # ── open_listener/0 and await_callback/3 ─────────────────────────────────────

  describe "callback listener" do
    setup do
      {:ok, server, port} = OAuth.open_listener()
      on_exit(fn -> :gen_tcp.close(server) end)
      %{server: server, port: port}
    end

    test "listens on loopback only", %{server: server, port: port} do
      assert {:ok, {{127, 0, 0, 1}, ^port}} = :inet.sockname(server)

      case MobDev.Network.lan_ip() do
        nil -> :ok
        lan_ip -> assert {:error, _} = :gen_tcp.connect(lan_ip, port, [], 1_000)
      end
    end

    test "answers a wrong-state callback with 400 and keeps waiting for the right one",
         %{server: server, port: port} do
      waiter = Task.async(fn -> OAuth.await_callback(server, "st4te", 5_000) end)

      assert callback(port, "/callback?code=stolen&state=other") =~ "400 Bad Request"
      assert callback(port, "/callback?code=stolen") =~ "400 Bad Request"
      assert Task.yield(waiter, 100) == nil

      assert callback(port, "/callback?code=g00d&state=st4te") =~ "200 OK"
      assert Task.await(waiter) == {:ok, "g00d"}
    end

    test "times out when only wrong-state callbacks arrive", %{server: server, port: port} do
      waiter = Task.async(fn -> OAuth.await_callback(server, "st4te", 1_000) end)

      assert callback(port, "/callback?code=stolen&state=other") =~ "400 Bad Request"
      assert {:error, reason} = Task.await(waiter)
      assert reason =~ "Timed out"
    end

    test "idle connections cannot hold the wait past its deadline", %{server: server, port: port} do
      idle = for _ <- 1..2, do: connect(port)
      started = System.monotonic_time(:millisecond)

      assert {:error, reason} = OAuth.await_callback(server, "st4te", 500)
      assert reason =~ "Timed out"
      assert System.monotonic_time(:millisecond) - started < 2_000

      Enum.each(idle, &:gen_tcp.close/1)
    end

    test "a connection reset before accept does not end the wait", %{server: server, port: port} do
      reset = connect(port)
      :ok = :inet.setopts(reset, linger: {true, 0})
      :ok = :gen_tcp.close(reset)

      waiter = Task.async(fn -> OAuth.await_callback(server, "st4te", 5_000) end)

      assert callback(port, "/callback?code=g00d&state=st4te") =~ "200 OK"
      assert Task.await(waiter) == {:ok, "g00d"}
    end
  end

  # ── sign_in/6 ────────────────────────────────────────────────────────────────

  describe "sign_in/6" do
    setup do
      {:ok, server, port} = OAuth.open_listener()
      on_exit(fn -> :gen_tcp.close(server) end)
      %{server: server, port: port}
    end

    # A browser that first delivers `forged` callbacks (wrong state), then,
    # if `deliver_real?`, the real one built from the auth URL's state.
    defp fake_io(test_pid, forged, deliver_real?) do
      open_browser = fn url ->
        send(test_pid, {:auth_url, url})
        params = auth_params(url)
        port = URI.parse(params["redirect_uri"]).port

        spawn_link(fn ->
          Enum.each(forged, &callback(port, &1))

          if deliver_real?,
            do:
              callback(port, "/callback?code=c0de&state=#{URI.encode_www_form(params["state"])}")
        end)
      end

      exchange_code = fn body ->
        send(test_pid, {:exchange, body})
        {:ok, %{"access_token" => "acc3ss"}}
      end

      %{open_browser: open_browser, exchange_code: exchange_code}
    end

    defp run_sign_in(server, port, io, timeout_ms) do
      ExUnit.CaptureIO.with_io(fn ->
        OAuth.sign_in(server, port, {"id", "secret"}, ["s"], timeout_ms, io)
      end)
      |> elem(0)
    end

    test "redirects to loopback and redeems the code with the matching PKCE verifier",
         %{server: server, port: port} do
      io = fake_io(self(), [], true)

      assert run_sign_in(server, port, io, 5_000) == {:ok, "acc3ss"}

      assert_received {:auth_url, url}
      assert_received {:exchange, body}
      url_params = auth_params(url)
      exchange = URI.decode_query(body)

      assert url_params["redirect_uri"] == "http://127.0.0.1:#{port}/callback"
      assert exchange["redirect_uri"] == url_params["redirect_uri"]
      assert exchange["code"] == "c0de"
      assert OAuth.code_challenge(exchange["code_verifier"]) == url_params["code_challenge"]
    end

    test "never exchanges a code from a callback with the wrong state",
         %{server: server, port: port} do
      io = fake_io(self(), ["/callback?code=stolen&state=other"], true)

      assert run_sign_in(server, port, io, 5_000) == {:ok, "acc3ss"}
      assert_received {:exchange, body}
      assert URI.decode_query(body)["code"] == "c0de"
      refute_received {:exchange, _}
    end

    test "times out without any exchange when only wrong-state callbacks arrive",
         %{server: server, port: port} do
      io = fake_io(self(), ["/callback?code=stolen&state=other"], false)

      assert {:error, reason} = run_sign_in(server, port, io, 1_000)
      assert reason =~ "Timed out"
      refute_received {:exchange, _}
    end
  end

  defp connect(port) do
    {:ok, sock} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
    sock
  end

  defp callback(port, path) do
    sock = connect(port)
    :ok = :gen_tcp.send(sock, "GET #{path} HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
    {:ok, response} = :gen_tcp.recv(sock, 0, 5_000)
    :gen_tcp.close(sock)
    response
  end

  # ── setup_scopes/0 ───────────────────────────────────────────────────────────

  describe "setup_scopes/0" do
    test "includes cloud-platform scope" do
      assert "https://www.googleapis.com/auth/cloud-platform" in OAuth.setup_scopes()
    end

    test "includes androidpublisher scope" do
      assert "https://www.googleapis.com/auth/androidpublisher" in OAuth.setup_scopes()
    end

    test "returns a non-empty list of strings" do
      scopes = OAuth.setup_scopes()
      assert [_ | _] = scopes
      assert Enum.all?(scopes, &is_binary/1)
    end
  end
end
