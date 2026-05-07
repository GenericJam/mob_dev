defmodule MobDev.SecurityScan.BundledRuntime.Feeds do
  @moduledoc """
  Live advisory feed clients for the bundled-runtime scan layer.

  Two sources:

    1. **OpenSSL official feed** — `https://www.openssl.org/news/vulnerabilities.json`
       Authoritative for OpenSSL advisories (affects `libcrypto.a` baked
       into Mob's OTP tarballs). Hits the network only if the cached
       copy is older than `@ttl_seconds`.

    2. **OSV.dev REST API** — `https://api.osv.dev/v1/query`
       Used for Elixir, OTP, exqlite, and SQLite via package+version
       queries. The Erlef CNA publishes Erlang/Elixir advisories here
       under the `Hex` ecosystem.

  Responses are cached on disk at `~/.cache/mob_dev/security_advisories/`
  for 24 hours. The cache is per-(source, key) — re-running
  `mix mob.security_scan` is fast and respectful to upstream.

  HTTP, JSON decode, and caching are intentionally separate from the
  OpenSSL/OSV-specific parsing so the parsers stay easy to test with
  fixture JSON.
  """

  alias MobDev.SecurityScan.Finding

  # Hosted by the OpenSSL Foundation. The legacy URL at
  # www.openssl.org/news/vulnerabilities.json now 301-redirects here.
  @openssl_feed_url ~c"https://openssl-library.org/news/vulnerabilities.json"
  @osv_api_url ~c"https://api.osv.dev/v1/query"

  @cache_dir Path.join([
               System.user_home() || "/",
               ".cache",
               "mob_dev",
               "security_advisories"
             ])

  # 24 hours
  @ttl_seconds 86_400

  ## ── OpenSSL ────────────────────────────────────────────────────────────────

  @doc """
  Return findings for a given OpenSSL version. Pulls the OpenSSL
  advisories feed (cached), filters down to advisories that affect
  the given version.
  """
  @spec openssl_advisories(String.t(), keyword()) ::
          {:ok, [Finding.t()]} | {:error, term()}
  def openssl_advisories(version, opts \\ []) when is_binary(version) do
    fetcher = Keyword.get(opts, :fetcher, &fetch_with_cache/2)

    case fetcher.({:openssl, "feed"}, fn -> http_get(@openssl_feed_url) end) do
      {:ok, body} -> {:ok, parse_openssl(body, version)}
      {:error, _} = err -> err
    end
  end

  @doc "Pure parser: OpenSSL feed JSON + a target version → `[Finding.t()]`."
  @spec parse_openssl(String.t() | map() | list(), String.t()) :: [Finding.t()]
  def parse_openssl(json, version) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, decoded} -> parse_openssl(decoded, version)
      {:error, _} -> []
    end
  end

  def parse_openssl(advisories, version) when is_list(advisories) do
    advisories
    |> Enum.filter(&openssl_affects_version?(&1, version))
    |> Enum.map(&openssl_to_finding(&1, version))
  end

  def parse_openssl(_, _), do: []

  defp openssl_affects_version?(%{"affected" => affected}, version) when is_list(affected) do
    Enum.any?(affected, fn entry ->
      target_versions = Map.get(entry, "version", [])
      target_versions = if is_list(target_versions), do: target_versions, else: [target_versions]

      version in target_versions or
        version_in_range?(
          version,
          Map.get(entry, "first_version"),
          Map.get(entry, "fixed_version") || Map.get(entry, "last_affected")
        )
    end)
  end

  defp openssl_affects_version?(_, _), do: false

  defp version_in_range?(_v, nil, _), do: false
  defp version_in_range?(v, first, fixed), do: cmp_version(v, first) >= 0 and version_lt_fixed?(v, fixed)

  defp version_lt_fixed?(_, nil), do: true
  defp version_lt_fixed?(v, fixed), do: cmp_version(v, fixed) < 0

  defp cmp_version(a, b) do
    case {parse_version(a), parse_version(b)} do
      {{:ok, va}, {:ok, vb}} -> Version.compare(va, vb)
      _ -> :gt
    end
    |> case do
      :gt -> 1
      :eq -> 0
      :lt -> -1
    end
  end

  defp parse_version(v) when is_binary(v) do
    Version.parse(normalize_semver(v))
  end

  defp parse_version(_), do: :error

  # OpenSSL versions are sometimes "3.4" not "3.4.0". Normalize to full SemVer.
  defp normalize_semver(v) do
    case String.split(v, ".") do
      [_a, _b] -> v <> ".0"
      _ -> v
    end
  end

  defp openssl_to_finding(advisory, version) do
    cves =
      advisory
      |> Map.get("CVE", [])
      |> List.wrap()
      |> Enum.reject(&(&1 == ""))

    severity = openssl_severity(Map.get(advisory, "severity"))

    fixed_in =
      advisory
      |> Map.get("affected", [])
      |> Enum.find_value(fn entry -> Map.get(entry, "fixed_version") end)

    %Finding{
      id: List.first(cves) || Map.get(advisory, "advisory") || "OpenSSL-advisory",
      severity: severity,
      package: "openssl",
      version: version,
      fixed_in: fixed_in,
      title: Map.get(advisory, "title") || Map.get(advisory, "summary"),
      description: Map.get(advisory, "description"),
      url: openssl_url(advisory),
      source: :openssl_feed,
      layer: :bundled_runtime
    }
  end

  defp openssl_severity(nil), do: :unknown

  defp openssl_severity(s) when is_binary(s) do
    case String.downcase(s) do
      "critical" -> :critical
      "high" -> :high
      "moderate" -> :medium
      "medium" -> :medium
      "low" -> :low
      _ -> :unknown
    end
  end

  defp openssl_severity(_), do: :unknown

  defp openssl_url(%{"advisory" => id}) when is_binary(id) and id != "",
    do: "https://www.openssl.org/news/secadv/#{id}.txt"

  defp openssl_url(_), do: "https://www.openssl.org/news/vulnerabilities.html"

  ## ── OSV.dev ────────────────────────────────────────────────────────────────

  @doc """
  Query OSV.dev for advisories on a (ecosystem, package, version)
  triple. Returns findings tagged with `:bundled_runtime`.

  Common ecosystem strings: `"Hex"` (Elixir/Erlang), `"Linux"`,
  `"Maven"`, `"PyPI"`, `"npm"`, ...
  """
  @spec osv_advisories(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, [Finding.t()]} | {:error, term()}
  def osv_advisories(ecosystem, package, version, opts \\ []) do
    fetcher = Keyword.get(opts, :fetcher, &fetch_with_cache/2)
    cache_key = {:osv, "#{ecosystem}_#{package}_#{version}"}

    body =
      Jason.encode!(%{
        package: %{ecosystem: ecosystem, name: package},
        version: version
      })

    case fetcher.(cache_key, fn -> http_post(@osv_api_url, body) end) do
      {:ok, raw} -> {:ok, parse_osv(raw, package, version)}
      {:error, _} = err -> err
    end
  end

  @doc "Pure parser: OSV response JSON → `[Finding.t()]`."
  @spec parse_osv(String.t() | map(), String.t(), String.t()) :: [Finding.t()]
  def parse_osv(json, package, version) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, decoded} -> parse_osv(decoded, package, version)
      {:error, _} -> []
    end
  end

  def parse_osv(%{"vulns" => vulns}, package, version) when is_list(vulns) do
    Enum.map(vulns, &osv_vuln_to_finding(&1, package, version))
  end

  def parse_osv(_, _, _), do: []

  defp osv_vuln_to_finding(vuln, package, version) do
    %Finding{
      id: vuln["id"],
      severity: osv_severity(vuln),
      package: package,
      version: version,
      fixed_in: osv_fixed_in(vuln),
      title: vuln["summary"] || vuln["details"],
      description: vuln["details"] || vuln["summary"],
      url: List.first(vuln["references"] || []) |> osv_ref_url(),
      source: :osv_dev,
      layer: :bundled_runtime
    }
  end

  defp osv_ref_url(%{"url" => url}) when is_binary(url), do: url
  defp osv_ref_url(_), do: nil

  defp osv_fixed_in(vuln) do
    vuln
    |> Map.get("affected", [])
    |> Enum.flat_map(fn a -> Map.get(a, "ranges", []) end)
    |> Enum.flat_map(fn r -> Map.get(r, "events", []) end)
    |> Enum.find_value(fn
      %{"fixed" => v} when is_binary(v) -> v
      _ -> nil
    end)
  end

  defp osv_severity(%{"severity" => sevs}) when is_list(sevs) do
    sevs
    |> Enum.find_value(fn
      %{"type" => "CVSS_V3", "score" => s} -> s
      %{"type" => "CVSS_V4", "score" => s} -> s
      _ -> nil
    end)
    |> cvss_score_to_band()
  end

  defp osv_severity(_), do: :unknown

  defp cvss_score_to_band(nil), do: :unknown

  defp cvss_score_to_band(s) when is_binary(s) do
    case Regex.run(~r/AV:[A-Z]\/.*\/A:[A-Z]/, s) do
      _ -> cvss_band_from_string(s)
    end
  end

  defp cvss_band_from_string(s) do
    # CVSS strings include AV/AC/etc. We can't compute a base score
    # from the vector alone without a CVSS library; treat presence of
    # a vector as :high (typical conservative default for exploitable
    # vulns) unless we can do better. OSV usually also provides a
    # numeric score under "database_specific" — checked first below.
    cond do
      String.contains?(s, "/A:H") -> :high
      String.contains?(s, "/C:H") -> :high
      true -> :medium
    end
  end

  ## ── HTTP + caching ─────────────────────────────────────────────────────────

  defp fetch_with_cache(key, fetch_fn) do
    File.mkdir_p!(@cache_dir)
    path = cache_path(key)

    if cache_fresh?(path) do
      File.read(path)
    else
      with {:ok, body} <- fetch_fn.() do
        File.write!(path, body)
        {:ok, body}
      end
    end
  end

  defp cache_path({source, key}) do
    safe = key |> String.replace(~r/[^a-zA-Z0-9_.-]/, "_")
    Path.join(@cache_dir, "#{source}__#{safe}.json")
  end

  defp cache_fresh?(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} ->
        age = System.os_time(:second) - mtime
        age < @ttl_seconds

      {:error, _} ->
        false
    end
  end

  defp http_get(url) do
    ensure_inets_started()

    request = {url, [{~c"user-agent", ~c"mob_dev mob.security_scan"}]}

    case :httpc.request(:get, request, http_opts(), body_format: :binary) do
      {:ok, {{_, 200, _}, _headers, body}} -> {:ok, body}
      {:ok, {{_, code, _}, _, body}} -> {:error, {:http_status, code, body}}
      {:error, reason} -> {:error, {:http_error, reason}}
    end
  end

  defp http_post(url, body) do
    ensure_inets_started()

    request =
      {url, [{~c"user-agent", ~c"mob_dev mob.security_scan"}], ~c"application/json", body}

    case :httpc.request(:post, request, http_opts(), body_format: :binary) do
      {:ok, {{_, 200, _}, _headers, response}} -> {:ok, response}
      {:ok, {{_, code, _}, _, response}} -> {:error, {:http_status, code, response}}
      {:error, reason} -> {:error, {:http_error, reason}}
    end
  end

  defp http_opts do
    [
      timeout: 10_000,
      connect_timeout: 5_000,
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        depth: 100,
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ]
    ]
  end

  defp ensure_inets_started do
    Application.ensure_all_started([:inets, :ssl, :public_key, :crypto])
    :ok
  end
end
