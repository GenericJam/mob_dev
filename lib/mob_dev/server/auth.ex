defmodule MobDev.Server.Auth do
  @moduledoc """
  Per-run access control for the `mix mob.server` dashboard.

  The dashboard listens on the LAN so a phone can open it from the printed QR
  code, and it can stream device logs and start deploys. Each run generates a
  random access token; the printed URLs carry it as `?token=...`. The first
  request with a valid token stores a SHA-256 digest of it in the signed
  session cookie and redirects to `/` without the query string. Every later
  HTTP request and the LiveView socket connect must present that session. The
  digest, not the token, is what LiveView's debug logging prints when it logs
  the session.

  The token and the endpoint's `secret_key_base` both come from
  `:crypto.strong_rand_bytes/1` per run, so a cookie from an earlier run is
  worthless.
  """

  @behaviour Plug

  import Plug.Conn

  @session_key "mob_dev_auth"
  @query_param "token"

  @doc "A random access token for one dashboard run."
  @spec generate_token() :: String.t()
  def generate_token, do: random(32)

  @doc "A random `secret_key_base` for one dashboard run."
  @spec generate_secret_key_base() :: String.t()
  def generate_secret_key_base, do: random(64)

  @doc "The current run's access token, or `nil` when none is configured."
  @spec token() :: String.t() | nil
  def token, do: Application.get_env(:mob_dev, :dashboard_token)

  @doc "`base` with the access token appended as the `token` query parameter."
  @spec url_with_token(String.t(), String.t()) :: String.t()
  def url_with_token(base, token), do: base <> "/?" <> URI.encode_query(%{@query_param => token})

  @doc """
  Whether `given` matches `expected`, compared in constant time.

  An unset or empty expected token matches nothing, so a server started
  without one refuses every request.
  """
  @spec valid?(term(), term()) :: boolean()
  def valid?(given, expected)
      when is_binary(given) and is_binary(expected) and expected != "",
      do: Plug.Crypto.secure_compare(given, expected)

  def valid?(_given, _expected), do: false

  @doc "Whether a Plug session map carries the current run's token digest."
  @spec authorized_session?(map() | nil) :: boolean()
  def authorized_session?(%{@session_key => given}), do: valid?(given, session_value(token()))
  def authorized_session?(_session), do: false

  @doc "The session entry a browser holding `token` carries."
  @spec session(String.t()) :: %{String.t() => String.t()}
  def session(token), do: %{@session_key => session_value(token)}

  defp session_value(token) when token in [nil, ""], do: nil

  defp session_value(token),
    do: :sha256 |> :crypto.hash(token) |> Base.url_encode64(padding: false)

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    conn = conn |> fetch_session() |> fetch_query_params()
    expected = token()

    cond do
      valid?(conn.query_params[@query_param], expected) ->
        conn
        |> configure_session(renew: true)
        |> put_session(@session_key, session_value(expected))
        |> put_resp_header("location", "/")
        |> send_resp(302, "")
        |> halt()

      authorized_session?(get_session(conn)) ->
        conn

      true ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(401, "Unauthorized. Open the URL printed by `mix mob.server`.\n")
        |> halt()
    end
  end

  defp random(bytes),
    do: bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
