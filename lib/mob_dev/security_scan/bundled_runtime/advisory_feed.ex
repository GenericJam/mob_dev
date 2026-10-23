defmodule MobDev.SecurityScan.BundledRuntime.AdvisoryFeed do
  @moduledoc """
  Fetches and caches the upstream advisory sources the bundled-runtime
  layer matches against (see `MobDev.SecurityScan.BundledRuntime.Advisories`).

  The scan has to complete offline and must not hammer the unauthenticated
  GitHub API (60 requests/hour), so every source goes through a file cache
  at `advisories/` in the runtime cache (`$MOB_CACHE_DIR`, default `~/.mob/cache`):

    1. a cached copy younger than the TTL (default 24 h) is used as-is;
    2. otherwise the source is fetched, validated, and written to the cache;
    3. if the fetch fails, an older cached copy is used and reported as stale;
    4. with no cached copy either, `load/2` returns `{:error, reason}` and
       the layer falls back to manual-check notes.

  A fetched body is validated before it replaces the cache, so a rate-limit
  page or a redesigned site can't overwrite good data with nothing.

  ## Options

    * `:advisory_cache_dir` — cache directory (default `default_cache_dir/0`)
    * `:advisory_ttl` — seconds a cached copy counts as fresh (default 86_400)
    * `:advisory_http_get` — `(url, headers) -> {:ok, status, headers, body} |
      {:error, reason}`; defaults to `:httpc`. Tests inject a stub.
    * `:github_token` — token for the GitHub API; defaults to `GITHUB_TOKEN`,
      `GH_TOKEN`, then `gh auth token`. Unauthenticated access works.
    * `:now` — `DateTime` used for cache age (default `DateTime.utc_now/0`)
  """

  alias MobDev.SecurityScan.BundledRuntime.Advisories

  @type source :: :otp | {:openssl, String.t()} | :openssl_eol | :sqlite
  @typedoc """
  Where the data came from. A fetch whose cache write failed carries the
  write error, since the next offline run will have nothing to fall back to.
  """
  @type provenance ::
          {:fetched, DateTime.t()}
          | {:fetched, DateTime.t(), {:cache_write_failed, String.t()}}
          | {:cached, DateTime.t()}
          | {:stale, DateTime.t(), String.t()}
  @type http_response :: {:ok, non_neg_integer(), [{String.t(), String.t()}], binary()}

  @default_ttl 86_400
  @github_url "https://api.github.com/repos/erlang/otp/security-advisories?per_page=100"
  @eol_url "https://endoflife.date/api/openssl.json"
  @max_pages 20

  @doc "Default cache directory for advisory data: `advisories/` in the runtime cache."
  @spec default_cache_dir() :: Path.t()
  def default_cache_dir,
    do: Path.join(MobDev.SecurityScan.BundledRuntime.Fingerprint.cache_dir(), "advisories")

  @doc """
  Load one source's decoded data: `[advisory]` for `:otp`, the parsed
  page entries for `{:openssl, branch}` and `:sqlite`, `[cycle]` for
  `:openssl_eol`.
  """
  @spec load(source(), keyword()) :: {:ok, term(), provenance()} | {:error, String.t()}
  def load(source, opts) do
    path =
      Path.join(Keyword.get(opts, :advisory_cache_dir, default_cache_dir()), cache_file(source))

    now = Keyword.get(opts, :now, DateTime.utc_now())
    ttl = Keyword.get(opts, :advisory_ttl, @default_ttl)
    cached = read_cache(path, source)

    case cached do
      {:ok, data, fetched_at} ->
        if DateTime.diff(now, fetched_at) < ttl,
          do: {:ok, data, {:cached, fetched_at}},
          else: refresh(source, path, now, opts, cached)

      :none ->
        refresh(source, path, now, opts, cached)
    end
  end

  defp refresh(source, path, now, opts, cached) do
    with {:ok, body} <- fetch(source, opts),
         {:ok, data} <- decode(source, body) do
      case write_cache(path, body) do
        :ok -> {:ok, data, {:fetched, now}}
        {:error, reason} -> {:ok, data, {:fetched, now, {:cache_write_failed, reason}}}
      end
    else
      {:error, reason} ->
        case cached do
          {:ok, data, fetched_at} -> {:ok, data, {:stale, fetched_at, reason}}
          :none -> {:error, reason}
        end
    end
  end

  defp cache_file(:otp), do: "erlang-otp-security-advisories.json"
  defp cache_file({:openssl, branch}), do: "openssl-vulnerabilities-#{branch}.html"
  defp cache_file(:openssl_eol), do: "endoflife-openssl.json"
  defp cache_file(:sqlite), do: "sqlite-cves.html"

  # A cache file that no longer decodes (truncated, or written by an older
  # parser) is treated as absent rather than trusted.
  defp read_cache(path, source) do
    with {:ok, body} <- File.read(path),
         {:ok, data} <- decode(source, body),
         {:ok, %File.Stat{mtime: mtime}} <- File.stat(path, time: :posix) do
      {:ok, data, DateTime.from_unix!(mtime)}
    else
      _ -> :none
    end
  end

  defp write_cache(path, body) do
    tmp = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, body),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} -> {:error, "#{path}: #{:file.format_error(reason)}"}
    end
  end

  # Validation is what keeps a rate-limit page, a schema change or a
  # redesign from being cached as "no advisories": erlang/otp has published
  # advisories, so an empty or misshapen list is never a real answer.
  defp decode(:otp, body) do
    case Jason.decode(body) do
      {:ok, [_ | _] = list} ->
        if Enum.all?(list, &advisory_shaped?/1),
          do: {:ok, list},
          else: {:error, "GitHub advisories response has an unexpected shape"}

      _ ->
        {:error, "GitHub advisories response is not a non-empty JSON list"}
    end
  end

  defp decode({:openssl, branch}, body) do
    case Advisories.parse_openssl_page(body, branch) do
      {:ok, entries} -> {:ok, entries}
      {:error, :unrecognised_page} -> {:error, "OpenSSL #{branch} advisory page not recognised"}
    end
  end

  defp decode(:openssl_eol, body) do
    case Jason.decode(body) do
      {:ok, [_ | _] = cycles} ->
        if Enum.all?(cycles, &match?(%{"cycle" => c, "eol" => _} when is_binary(c), &1)),
          do: {:ok, cycles},
          else: {:error, "endoflife.date response has an unexpected shape"}

      _ ->
        {:error, "endoflife.date response is not a non-empty list of cycles"}
    end
  end

  defp decode(:sqlite, body) do
    case Advisories.parse_sqlite_cves_page(body) do
      {:ok, entries} -> {:ok, entries}
      {:error, :unrecognised_page} -> {:error, "SQLite CVE page not recognised"}
    end
  end

  defp advisory_shaped?(%{"ghsa_id" => id, "vulnerabilities" => vulns})
       when is_binary(id) and is_list(vulns) do
    Enum.all?(vulns, &match?(%{"package" => %{"name" => name}} when is_binary(name), &1))
  end

  defp advisory_shaped?(_advisory), do: false

  defp fetch(:otp, opts) do
    token = Keyword.get_lazy(opts, :github_token, &github_token/0)
    http_get = http_get(opts)

    case fetch_github_pages(http_get, @github_url, token, [], @max_pages) do
      {:error, {:unauthorized, _}} when is_binary(token) ->
        fetch_github_pages(http_get, @github_url, nil, [], @max_pages) |> github_result()

      result ->
        github_result(result)
    end
  end

  defp fetch({:openssl, branch}, opts), do: fetch_page(Advisories.openssl_page_url(branch), opts)
  defp fetch(:openssl_eol, opts), do: fetch_page(@eol_url, opts)
  defp fetch(:sqlite, opts), do: fetch_page(Advisories.sqlite_cves_url(), opts)

  defp fetch_page(url, opts) do
    case http_get(opts).(url, [{"user-agent", user_agent()}]) do
      {:ok, 200, _headers, body} -> {:ok, body}
      {:ok, status, _headers, _body} -> {:error, "#{url}: HTTP #{status}"}
      {:error, reason} -> {:error, "#{url}: #{format_reason(reason)}"}
    end
  end

  defp github_result({:ok, advisories}), do: {:ok, Jason.encode!(advisories)}
  defp github_result({:error, {_kind, message}}), do: {:error, message}

  defp fetch_github_pages(_http_get, _url, _token, _acc, 0),
    do: {:error, {:too_many_pages, "GitHub advisories: more than #{@max_pages} pages"}}

  defp fetch_github_pages(http_get, url, token, acc, pages_left) do
    headers =
      [
        {"accept", "application/vnd.github+json"},
        {"x-github-api-version", "2022-11-28"},
        {"user-agent", user_agent()}
      ] ++ if(token, do: [{"authorization", "Bearer #{token}"}], else: [])

    case http_get.(url, headers) do
      {:ok, 200, resp_headers, body} ->
        case Jason.decode(body) do
          {:ok, page} when is_list(page) ->
            case next_link(resp_headers) do
              nil -> {:ok, acc ++ page}
              next -> fetch_github_pages(http_get, next, token, acc ++ page, pages_left - 1)
            end

          _ ->
            {:error, {:bad_body, "GitHub advisories: response page is not a JSON list"}}
        end

      {:ok, 401, _headers, _body} ->
        {:error, {:unauthorized, "GitHub advisories: HTTP 401 (bad token)"}}

      {:ok, status, _headers, body} ->
        {:error, {:http, "GitHub advisories: HTTP #{status}#{github_message(body)}"}}

      {:error, reason} ->
        {:error, {:transport, "GitHub advisories: #{format_reason(reason)}"}}
    end
  end

  defp github_message(body) do
    case Jason.decode(body) do
      {:ok, %{"message" => message}} -> " (#{message})"
      _ -> ""
    end
  end

  @doc """
  Extract the `rel="next"` URL from a GitHub `Link` header, if any.
  """
  @spec next_link([{String.t(), String.t()}]) :: String.t() | nil
  def next_link(headers) do
    with {_, link} <- List.keyfind(headers, "link", 0),
         [_, url] <- Regex.run(Regex.compile!(~S{<([^>]+)>;\s*rel="next"}), link) do
      url
    else
      _ -> nil
    end
  end

  defp github_token do
    with nil <- non_empty(System.get_env("GITHUB_TOKEN")),
         nil <- non_empty(System.get_env("GH_TOKEN")),
         gh when is_binary(gh) <- System.find_executable("gh"),
         {out, 0} <- System.cmd(gh, ["auth", "token"], stderr_to_stdout: true) do
      # stderr is merged to keep gh's notices off the scan output; the token
      # is the line without whitespace.
      out
      |> String.split("\n", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reverse()
      |> Enum.find(&(&1 != "" and not String.contains?(&1, [" ", "\t"])))
    else
      token when is_binary(token) -> token
      _ -> nil
    end
  end

  defp non_empty(nil), do: nil
  defp non_empty(""), do: nil
  defp non_empty(value), do: value

  defp user_agent, do: "mob_dev-security-scan"

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)

  # :httpc's `{:failed_connect, [{:to_address, _}, {family, opts, reason}]}`.
  defp format_reason({:failed_connect, details}) when is_list(details) do
    case List.last(details) do
      {_family, _opts, reason} -> "connection failed: #{format_reason(reason)}"
      _ -> "connection failed"
    end
  end

  defp format_reason(reason), do: inspect(reason)

  defp http_get(opts), do: Keyword.get(opts, :advisory_http_get, &httpc_get/2)

  defp httpc_get(url, headers) do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)
    host = URI.parse(url).host

    request =
      {to_charlist(url), Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)}

    http_opts = [
      timeout: 30_000,
      connect_timeout: 10_000,
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        server_name_indication: to_charlist(host),
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]
    ]

    case :httpc.request(:get, request, http_opts, body_format: :binary) do
      {:ok, {{_, status, _}, resp_headers, body}} ->
        {:ok, status,
         Enum.map(resp_headers, fn {k, v} -> {String.downcase(to_string(k)), to_string(v)} end),
         body}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
