defmodule MobDev.SecurityScan.BundledRuntime.AdvisoryFeedTest do
  use ExUnit.Case, async: true

  alias MobDev.SecurityScan.BundledRuntime.AdvisoryFeed

  @moduletag :tmp_dir

  @fixtures Path.expand("../../../fixtures/security_scan", __DIR__)
  @otp_json File.read!(Path.join(@fixtures, "otp_security_advisories.json"))
  @openssl_html File.read!(Path.join(@fixtures, "openssl_vulnerabilities_3.4.html"))
  @eol_json File.read!(Path.join(@fixtures, "endoflife_openssl.json"))

  @now ~U[2026-10-22 12:00:00Z]

  defp opts(dir, http_get, extra \\ []) do
    Keyword.merge(
      [advisory_cache_dir: dir, advisory_http_get: http_get, github_token: nil, now: @now],
      extra
    )
  end

  defp offline(_url, _headers), do: {:error, :nxdomain}

  defp serving(body) do
    test = self()

    fn url, headers ->
      send(test, {:http_get, url, headers})
      {:ok, 200, [], body}
    end
  end

  defp age_cache(dir, seconds) do
    for file <- File.ls!(dir) do
      File.touch!(Path.join(dir, file), DateTime.to_unix(@now) - seconds)
    end
  end

  test "fetches on a cold cache, then serves the cached copy without the network", %{tmp_dir: dir} do
    assert {:ok, [_ | _] = advisories, {:fetched, @now}} =
             AdvisoryFeed.load(:otp, opts(dir, serving(@otp_json)))

    assert_received {:http_get,
                     "https://api.github.com/repos/erlang/otp/security-advisories?per_page=100",
                     _}

    age_cache(dir, 60)

    assert {:ok, ^advisories, {:cached, _at}} =
             AdvisoryFeed.load(
               :otp,
               opts(dir, fn _, _ -> flunk("fresh cache must not refetch") end)
             )
  end

  test "a cache older than the TTL is refetched", %{tmp_dir: dir} do
    AdvisoryFeed.load(:openssl_eol, opts(dir, serving(@eol_json)))
    age_cache(dir, 3_600)

    assert {:ok, _cycles, {:fetched, @now}} =
             AdvisoryFeed.load(:openssl_eol, opts(dir, serving(@eol_json), advisory_ttl: 1_800))
  end

  test "offline with an expired cache returns the stale copy and why", %{tmp_dir: dir} do
    {:ok, entries, _} = AdvisoryFeed.load({:openssl, "3.4"}, opts(dir, serving(@openssl_html)))
    age_cache(dir, 3 * 86_400)

    assert {:ok, ^entries, {:stale, at, reason}} =
             AdvisoryFeed.load({:openssl, "3.4"}, opts(dir, &offline/2))

    assert DateTime.diff(@now, at) == 3 * 86_400
    assert reason =~ "nxdomain"
  end

  test "offline with no cache is an error", %{tmp_dir: dir} do
    assert {:error, reason} = AdvisoryFeed.load(:otp, opts(dir, &offline/2))
    assert reason =~ "GitHub advisories"
    assert File.ls!(dir) == []
  end

  test "an invalid response never replaces a good cache", %{tmp_dir: dir} do
    {:ok, entries, _} = AdvisoryFeed.load({:openssl, "3.4"}, opts(dir, serving(@openssl_html)))
    age_cache(dir, 3 * 86_400)
    [file] = File.ls!(dir)
    before = File.read!(Path.join(dir, file))

    assert {:ok, ^entries, {:stale, _at, reason}} =
             AdvisoryFeed.load({:openssl, "3.4"}, opts(dir, serving("<html>maintenance</html>")))

    assert reason =~ "not recognised"
    assert File.read!(Path.join(dir, file)) == before
  end

  test "empty or misshapen feed bodies are refused, keeping the good cache", %{tmp_dir: dir} do
    {:ok, advisories, _} = AdvisoryFeed.load(:otp, opts(dir, serving(@otp_json)))
    {:ok, cycles, _} = AdvisoryFeed.load(:openssl_eol, opts(dir, serving(@eol_json)))
    age_cache(dir, 3 * 86_400)

    for body <- ["[]", "[{}]", ~s([{"ghsa_id":"GHSA-x","vulnerabilities":[{"pkg":"ssl"}]}])] do
      assert {:ok, ^advisories, {:stale, _at, reason}} =
               AdvisoryFeed.load(:otp, opts(dir, serving(body)))

      assert reason =~ "GitHub advisories response", body
    end

    for body <- ["[]", ~s([{"cycle":"3.4"}]), ~s({"cycle":"3.4","eol":"2026-10-22"})] do
      assert {:ok, ^cycles, {:stale, _at, reason}} =
               AdvisoryFeed.load(:openssl_eol, opts(dir, serving(body)))

      assert reason =~ "endoflife.date response", body
    end
  end

  test "a fetch that can't be cached says so", %{tmp_dir: dir} do
    blocked = Path.join(dir, "not_a_dir")
    File.write!(blocked, "")

    assert {:ok, [_ | _], {:fetched, @now, {:cache_write_failed, reason}}} =
             AdvisoryFeed.load(:otp, opts(blocked, serving(@otp_json)))

    assert reason =~ "not_a_dir"
  end

  test "GitHub rate limiting surfaces the API message", %{tmp_dir: dir} do
    limited = fn _url, _headers ->
      {:ok, 403, [], ~s({"message":"API rate limit exceeded for 1.2.3.4."})}
    end

    assert {:error, reason} = AdvisoryFeed.load(:otp, opts(dir, limited))
    assert reason =~ "HTTP 403 (API rate limit exceeded"
  end

  test "follows GitHub's Link pagination and concatenates pages", %{tmp_dir: dir} do
    [first | rest] = Jason.decode!(@otp_json)
    page2 = "https://api.github.com/repositories/374927/security-advisories?per_page=100&after=X"

    http_get = fn
      "https://api.github.com/repos/erlang/otp/security-advisories?per_page=100", _ ->
        {:ok, 200, [{"link", ~s(<#{page2}>; rel="next")}], Jason.encode!([first])}

      ^page2, _ ->
        {:ok, 200, [], Jason.encode!(rest)}
    end

    assert {:ok, advisories, _} = AdvisoryFeed.load(:otp, opts(dir, http_get))
    assert Enum.map(advisories, & &1["ghsa_id"]) == Enum.map([first | rest], & &1["ghsa_id"])
  end

  test "a rejected token falls back to unauthenticated access", %{tmp_dir: dir} do
    http_get = fn _url, headers ->
      if List.keymember?(headers, "authorization", 0),
        do: {:ok, 401, [], ~s({"message":"Bad credentials"})},
        else: {:ok, 200, [], @otp_json}
    end

    assert {:ok, [_ | _], {:fetched, _}} =
             AdvisoryFeed.load(:otp, opts(dir, http_get, github_token: "expired"))
  end

  test "sends the token when one is available", %{tmp_dir: dir} do
    AdvisoryFeed.load(:otp, opts(dir, serving(@otp_json), github_token: "tok"))
    assert_received {:http_get, _url, headers}
    assert {"authorization", "Bearer tok"} in headers
  end

  test "next_link/1 reads rel=next from a Link header" do
    link =
      ~s(<https://api.github.com/x?after=a>; rel="next", <https://api.github.com/x>; rel="first")

    assert AdvisoryFeed.next_link([{"link", link}]) == "https://api.github.com/x?after=a"
    assert AdvisoryFeed.next_link([{"link", ~s(<https://api.github.com/x>; rel="prev")}]) == nil
    assert AdvisoryFeed.next_link([]) == nil
  end
end
