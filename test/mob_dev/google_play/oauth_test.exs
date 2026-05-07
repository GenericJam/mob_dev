defmodule MobDev.GooglePlay.OAuthTest do
  use ExUnit.Case, async: true

  alias MobDev.GooglePlay.OAuth

  # ── build_auth_url/3 ─────────────────────────────────────────────────────────

  describe "build_auth_url/3" do
    test "includes client_id" do
      url = OAuth.build_auth_url("my_client_id", ["scope1"], "http://localhost:1234/callback")
      assert url =~ "client_id=my_client_id"
    end

    test "includes redirect_uri encoded" do
      url = OAuth.build_auth_url("id", ["scope1"], "http://localhost:1234/callback")
      assert url =~ "redirect_uri="
      assert url =~ "localhost"
    end

    test "joins multiple scopes with a space (URL-encoded as +)" do
      url =
        OAuth.build_auth_url(
          "id",
          [
            "https://www.googleapis.com/auth/cloud-platform",
            "https://www.googleapis.com/auth/androidpublisher"
          ],
          "http://localhost:9/callback"
        )

      decoded = URI.decode_query(URI.parse(url).query)
      assert decoded["scope"] =~ "cloud-platform"
      assert decoded["scope"] =~ "androidpublisher"
    end

    test "requests offline access" do
      url = OAuth.build_auth_url("id", ["s"], "http://localhost:1/callback")
      assert url =~ "access_type=offline"
    end

    test "includes prompt=consent to force refresh token" do
      url = OAuth.build_auth_url("id", ["s"], "http://localhost:1/callback")
      assert url =~ "prompt=consent"
    end

    test "points to Google OAuth endpoint" do
      url = OAuth.build_auth_url("id", ["s"], "http://localhost:1/callback")
      assert String.starts_with?(url, "https://accounts.google.com/o/oauth2/v2/auth")
    end
  end

  # ── parse_callback_request/1 ─────────────────────────────────────────────────

  describe "parse_callback_request/1" do
    test "extracts authorization code from typical callback" do
      line = "GET /callback?code=4%2F0AVJP&scope=openid HTTP/1.1\r\n"
      assert {:ok, code} = OAuth.parse_callback_request(line)
      assert code == "4/0AVJP"
    end

    test "URL-decodes the code value" do
      line = "GET /callback?code=4%2F0AX4XfWhABC%3D HTTP/1.1\r\n"
      assert {:ok, code} = OAuth.parse_callback_request(line)
      assert code == "4/0AX4XfWhABC="
    end

    test "returns error when Google denies access" do
      line = "GET /callback?error=access_denied HTTP/1.1\r\n"
      assert {:error, reason} = OAuth.parse_callback_request(line)
      assert reason =~ "access_denied"
    end

    test "returns error for unrecognised error value" do
      line = "GET /callback?error=server_error HTTP/1.1\r\n"
      assert {:error, reason} = OAuth.parse_callback_request(line)
      assert reason =~ "server_error"
    end

    test "returns error when no code or error param present" do
      line = "GET /callback?state=xyz HTTP/1.1\r\n"
      assert {:error, _} = OAuth.parse_callback_request(line)
    end

    test "returns error for completely unrecognisable request" do
      assert {:error, _} = OAuth.parse_callback_request("garbage line")
    end

    test "handles HEAD method (same parsing)" do
      line = "HEAD /callback?code=mycode HTTP/1.1\r\n"
      assert {:ok, "mycode"} = OAuth.parse_callback_request(line)
    end
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
      assert length(scopes) > 0
      assert Enum.all?(scopes, &is_binary/1)
    end
  end
end
