defmodule MobDev.GooglePlay.HTTP do
  @moduledoc false
  # Shared `:httpc` wrapper used by GooglePlay, CloudSetup, PlaySetup, and OAuth.

  @type result :: {:ok, map()} | {:error, String.t()}

  @spec get(String.t(), list()) :: result()
  def get(url, headers), do: request(:get, url, headers, nil)

  @spec post(String.t(), list(), String.t()) :: result()
  def post(url, headers, body), do: request(:post, url, headers, body)

  @spec put(String.t(), list(), String.t()) :: result()
  def put(url, headers, body), do: request(:put, url, headers, body)

  @spec json_headers(String.t()) :: list()
  def json_headers(token) do
    [{"authorization", "Bearer #{token}"}, {"content-type", "application/json"}]
  end

  @spec ensure_started!() :: :ok
  def ensure_started! do
    Application.ensure_all_started(:inets)
    Application.ensure_all_started(:ssl)
    :ok
  end

  @spec request(atom(), String.t(), list(), String.t() | nil) :: result()
  def request(:get, url, headers, _body) do
    host = URI.parse(url).host
    httpc_headers = encode_headers(headers)

    :httpc.request(
      :get,
      {to_charlist(url), httpc_headers},
      [ssl: ssl_opts(host), timeout: 30_000, connect_timeout: 15_000],
      body_format: :binary
    )
    |> decode_response()
  end

  def request(method, url, headers, body) do
    {ct, rest} = pop_content_type(headers)
    host = URI.parse(url).host
    httpc_headers = encode_headers(rest)
    body_bin = if is_binary(body), do: body, else: ""

    :httpc.request(
      method,
      {to_charlist(url), httpc_headers, to_charlist(ct), body_bin},
      [ssl: ssl_opts(host), timeout: 300_000, connect_timeout: 15_000],
      body_format: :binary
    )
    |> decode_response()
  end

  defp decode_response({:ok, {{_, status, _}, _hdrs, resp}}) when status in 200..299 do
    {:ok, Jason.decode!(resp)}
  end

  defp decode_response({:ok, {{_, status, _}, _hdrs, resp}}) do
    msg =
      case Jason.decode(resp) do
        {:ok, %{"error" => %{"message" => m}}} -> m
        {:ok, %{"error" => %{"errors" => [%{"message" => m} | _]}}} -> m
        {:ok, %{"error_description" => m}} -> m
        _ -> inspect(resp)
      end

    {:error, "HTTP #{status}: #{msg}"}
  end

  defp decode_response({:error, reason}) do
    {:error, "HTTP request failed: #{inspect(reason)}"}
  end

  defp encode_headers(headers) do
    Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)
  end

  defp pop_content_type(headers) do
    case Enum.split_with(headers, fn {k, _} -> String.downcase(k) == "content-type" end) do
      {[{_, ct} | _], rest} -> {ct, rest}
      {[], rest} -> {"application/json", rest}
    end
  end

  defp ssl_opts(host) do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      server_name_indication: to_charlist(host),
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]
  end
end
