defmodule MobDev.SecurityScan.BundledRuntime.AdvisoriesTest do
  use ExUnit.Case, async: true

  alias MobDev.SecurityScan.BundledRuntime.Advisories
  alias MobDev.SecurityScan.Finding

  # Real records from GET /repos/erlang/otp/security-advisories (2026-10-22,
  # `description` truncated), the real openssl-library.org vulnerabilities-3.4
  # page cut to three CVE blocks, and real endoflife.date cycles.
  @fixtures Path.expand("../../../fixtures/security_scan", __DIR__)
  @otp_advisories @fixtures
                  |> Path.join("otp_security_advisories.json")
                  |> File.read!()
                  |> Jason.decode!()
  @openssl_html File.read!(Path.join(@fixtures, "openssl_vulnerabilities_3.4.html"))
  @eol_cycles @fixtures |> Path.join("endoflife_openssl.json") |> File.read!() |> Jason.decode!()

  # The 5c9c69fc runtime: OTP 29.0 as fingerprinted from the cache.
  @runtime_29_0 %{
    otp: "29.0",
    apps: [
      {"erts", "17.0"},
      {"public_key", "1.21"},
      {"ssh", "6.0"},
      {"ssl", "11.7"},
      {"stdlib", "8.0"}
    ]
  }

  describe "otp_findings/2" do
    test "flags the critical ssl advisories against OTP 29.0 with the track's fix" do
      findings = Advisories.otp_findings(@otp_advisories, @runtime_29_0)
      by_id = Map.new(findings, &{&1.id, &1})

      assert %Finding{
               severity: :critical,
               package: "otp/ssl",
               version: "11.7",
               fixed_in: "11.7.7",
               url: "https://github.com/erlang/otp/security/advisories/GHSA-rgxr-4g4w-j875",
               source: :otp_security_advisories,
               layer: :bundled_runtime
             } = by_id["CVE-2026-89422"]

      assert by_id["CVE-2026-89422"].title ==
               "TLS 1.3 Client Skips Server Authentication on Unsolicited PSK"

      assert %Finding{severity: :critical, fixed_in: "11.7.4"} = by_id["CVE-2026-55953"]
      assert %Finding{severity: :medium, fixed_in: "11.7.8"} = by_id["CVE-2026-105236"]

      assert %Finding{severity: :high, package: "otp/erts", fixed_in: "17.0.6"} =
               by_id["CVE-2026-75538"]
    end

    test "app entries win over the OTP umbrella entry" do
      # CVE-2025-46712 lists OTP ranges with no patched version for old
      # tracks; judged on OTP 29.0 alone that would read as unfixed. Its
      # ssh entries put 6.0 above every patched version.
      ids = @otp_advisories |> Advisories.otp_findings(@runtime_29_0) |> Enum.map(& &1.id)

      refute "CVE-2025-46712" in ids
      refute "CVE-2020-35733" in ids

      refute Enum.any?(
               @otp_advisories |> Advisories.otp_findings(@runtime_29_0),
               &(&1.package == "otp")
             )
    end

    test "a runtime with every fix applied has no findings" do
      patched = %{
        otp: "29.1.2",
        apps: [
          {"erts", "17.0.6"},
          {"public_key", "1.21.8"},
          {"ssh", "6.0.6"},
          {"ssl", "11.7.8"},
          {"stdlib", "8.1.1"}
        ]
      }

      assert Advisories.otp_findings(@otp_advisories, patched) == []
    end

    test "an application the runtime doesn't ship can't be affected" do
      no_ssl = %{@runtime_29_0 | apps: List.keydelete(@runtime_29_0.apps, "ssl", 0)}
      packages = @otp_advisories |> Advisories.otp_findings(no_ssl) |> Enum.map(& &1.package)

      refute "otp/ssl" in packages
      assert "otp/erts" in packages
    end

    test "withdrawn advisories are skipped" do
      withdrawn =
        Enum.map(@otp_advisories, fn
          %{"cve_id" => "CVE-2026-89422"} = adv ->
            %{adv | "withdrawn_at" => "2026-10-20T00:00:00Z"}

          adv ->
            adv
        end)

      ids = withdrawn |> Advisories.otp_findings(@runtime_29_0) |> Enum.map(& &1.id)
      refute "CVE-2026-89422" in ids
      assert "CVE-2026-55953" in ids
    end

    test "an advisory naming only OTP is matched on the release version" do
      [adv] = Enum.filter(@otp_advisories, &(&1["cve_id"] == "CVE-2026-89422"))

      otp_only = %{
        adv
        | "vulnerabilities" =>
            Enum.filter(adv["vulnerabilities"], &(&1["package"]["name"] == "OTP"))
      }

      assert [%Finding{package: "otp", version: "29.0", fixed_in: "29.1.1"}] =
               Advisories.otp_findings([otp_only], @runtime_29_0)

      assert [] = Advisories.otp_findings([otp_only], %{@runtime_29_0 | otp: "29.1.1"})
      assert [] = Advisories.otp_findings([otp_only], %{@runtime_29_0 | otp: nil})
    end
  end

  describe "otp_verdict/2" do
    @ssl [
      %{
        "vulnerable_version_range" => ">= 7.0",
        "patched_versions" => "11.7.8, 11.6.0.7, 11.2.12.14"
      }
    ]

    test "vulnerable until the version reaches a patched version on its own branch" do
      assert Advisories.otp_verdict("11.7", @ssl) == {:vulnerable, "11.7.8"}
      assert Advisories.otp_verdict("11.7.7", @ssl) == {:vulnerable, "11.7.8"}
      assert Advisories.otp_verdict("11.7.8", @ssl) == :not_affected
      assert Advisories.otp_verdict("11.7.9", @ssl) == :not_affected
      # 11.6 is the base of the 11.6.0. maintenance branch.
      assert Advisories.otp_verdict("11.6", @ssl) == {:vulnerable, "11.6.0.7"}
      assert Advisories.otp_verdict("11.6.0.7", @ssl) == :not_affected
      assert Advisories.otp_verdict("11.2.12.3", @ssl) == {:vulnerable, "11.2.12.14"}
    end

    test "a version is fixed only by a patched ancestor, not a numerically lower one" do
      # 11.6.1 is trunk after 11.6; the 11.6.0.7 fix lives on a branch it
      # doesn't contain, so its fix is the trunk's 11.7.8.
      assert Advisories.otp_verdict("11.6.1", @ssl) == {:vulnerable, "11.7.8"}
      # An unmaintained trunk version is fixed by the closest descendant.
      assert Advisories.otp_verdict("11.5", @ssl) == {:vulnerable, "11.6.0.7"}
      assert Advisories.otp_verdict("10.1", @ssl) == {:vulnerable, "11.2.12.14"}
      # A later trunk version descends from 11.7.8 and carries the fix.
      assert Advisories.otp_verdict("11.8", @ssl) == :not_affected
      assert Advisories.otp_verdict("12.0", @ssl) == :not_affected
      # An unpatched sibling branch: affected, nothing descends from it.
      assert Advisories.otp_verdict("11.2.13.1", @ssl) == {:vulnerable, nil}
    end

    test "below the affected range is not affected" do
      assert Advisories.otp_verdict("6.2", @ssl) == :not_affected
    end

    test "range parsing tolerates whitespace and combined constraints" do
      entry = fn range ->
        [%{"vulnerable_version_range" => range, "patched_versions" => "11.7.8"}]
      end

      assert Advisories.otp_verdict("11.7", entry.(">=5.3.4 ")) == {:vulnerable, "11.7.8"}
      assert Advisories.otp_verdict("11.7", entry.(">= 11.0, < 11.5")) == :not_affected
      assert Advisories.otp_verdict("11.2", entry.(">= 11.0, < 11.5")) == {:vulnerable, "11.7.8"}
    end

    test "no patched version listed means vulnerable with no fix" do
      entries = [%{"vulnerable_version_range" => ">= 4.9.1.5", "patched_versions" => ""}]

      assert Advisories.otp_verdict("4.9.1.6", entries) == {:vulnerable, nil}
      # Trunk 6.0 doesn't descend from the 4.9.1. branch the bug was introduced on.
      assert Advisories.otp_verdict("6.0", entries) == :not_affected
    end

    test "entries for one package are merged; each introduction point covers its own subtree" do
      # CVE-2025-46712's OTP entries, verbatim.
      entries = [
        %{"vulnerable_version_range" => ">= 26.2.1", "patched_versions" => "26.2.5.12, 27.3.4"},
        %{"vulnerable_version_range" => ">= 25.3.2.8", "patched_versions" => "25.3.2.21"},
        %{"vulnerable_version_range" => ">= 24.3.4.15", "patched_versions" => ""},
        %{"vulnerable_version_range" => ">= 23.3.4.20", "patched_versions" => ""},
        %{"vulnerable_version_range" => ">= 22.3.4.27", "patched_versions" => ""}
      ]

      assert Advisories.otp_verdict("29.0", entries) == :not_affected
      assert Advisories.otp_verdict("27.3.4", entries) == :not_affected
      assert Advisories.otp_verdict("27.3.3", entries) == {:vulnerable, "27.3.4"}
      assert Advisories.otp_verdict("26.2.5.11", entries) == {:vulnerable, "26.2.5.12"}
      assert Advisories.otp_verdict("25.3.2.9", entries) == {:vulnerable, "25.3.2.21"}
      # The 24.3.4. branch was never patched.
      assert Advisories.otp_verdict("24.3.4.15", entries) == {:vulnerable, nil}

      # Each just below its own branch's introduction point, which another
      # branch's (numerically lower) introduction point must not catch.
      for version <- ["26.2", "25.3.2.7", "24.3.4.14", "23.3.4.19", "22.3.4.26"] do
        assert Advisories.otp_verdict(version, entries) == :not_affected, version
      end
    end

    test "a release candidate precedes its release" do
      entries = [%{"vulnerable_version_range" => ">= 17.0", "patched_versions" => "29.0"}]

      assert Advisories.otp_verdict("29.0-rc3", entries) == {:vulnerable, "29.0"}
      assert Advisories.otp_verdict("29.0", entries) == :not_affected
    end

    test "an unparseable installed version is not judged" do
      assert Advisories.otp_verdict("not-a-version", @ssl) == :not_affected
    end
  end

  test "otp_compare/2 follows the OTP version tree (system principles example)" do
    # Every version in the documented example, against 35.3.0.2.2.
    for {version, relation} <- [
          {"35.2.7", :ancestor},
          {"35.3", :ancestor},
          {"35.3.1", :undefined},
          {"35.3.0.1", :ancestor},
          {"35.3.0.2", :ancestor},
          {"35.3.0.3", :undefined},
          {"35.3.0.4", :undefined},
          {"35.3.0.2.1", :ancestor},
          {"35.3.0.2.2", :same},
          {"35.3.0.2.3", :descendant},
          {"35.3.0.2.4", :descendant},
          {"35.3.0.2.3.1", :descendant}
        ] do
      assert Advisories.otp_compare(version, "35.3.0.2.2") == relation, version
    end

    assert Advisories.otp_compare("23.3", "23.2.7") == :descendant
    assert Advisories.otp_compare("23.2.7.1", "23.3") == :undefined
    assert Advisories.otp_compare("11.7.0", "11.7") == :same
    assert Advisories.otp_compare("x", "1.0") == :error
  end

  describe "parse_openssl_page/2" do
    test "extracts each CVE's severity, title, and affected ranges" do
      assert {:ok, entries} = Advisories.parse_openssl_page(@openssl_html, "3.4")

      assert Enum.map(entries, &{&1.cve, &1.severity}) == [
               {"CVE-2026-35189", :low},
               {"CVE-2026-84782", :high},
               {"CVE-2026-63072", :medium}
             ]

      high = Enum.find(entries, &(&1.cve == "CVE-2026-84782"))
      assert high.title == "DTLS Retransmits Handshake Messages From a Stale Buffer Offset"
      assert {"3.4.0", "3.4.8"} in high.affected
      assert {"1.1.1", "1.1.1zj"} in high.affected
    end

    test "decodes HTML entities in titles" do
      html = """
      <h1>Vulnerabilities 3.4</h1>
      <h2 id="CVE-2024-12797">CVE-2024-12797</h2>
      <div><span class="font-semibold">Severity</span></div>
      <div class="col-span-5">High</div>
      <div><span class="font-semibold">Title</span></div>
      <div class="col-span-5">Servers don&#39;t abort &amp; R&#x26;D</div>
      <li>from 3.4.0 before 3.4.1 </li>
      """

      assert {:ok, [%{title: "Servers don't abort & R&D"}]} =
               Advisories.parse_openssl_page(html, "3.4")
    end

    test "a page for another branch, or not an advisory page, is rejected" do
      assert {:error, :unrecognised_page} = Advisories.parse_openssl_page(@openssl_html, "3.5")

      assert {:error, :unrecognised_page} =
               Advisories.parse_openssl_page("<html>rate limited</html>", "3.4")
    end

    test "a page whose CVE blocks no longer parse is rejected, not read as clean" do
      # Heading kept, CVE markup changed: would otherwise be "0 CVEs".
      redesigned = String.replace(@openssl_html, ~s(<h2 id="CVE-), ~s(<h3 data-cve="CVE-))
      assert {:error, :unrecognised_page} = Advisories.parse_openssl_page(redesigned, "3.4")

      no_severity = String.replace(@openssl_html, ">Severity<", ">Impact<")
      assert {:error, :unrecognised_page} = Advisories.parse_openssl_page(no_severity, "3.4")

      no_ranges = String.replace(@openssl_html, "<li>from ", "<li>since ")
      assert {:error, :unrecognised_page} = Advisories.parse_openssl_page(no_ranges, "3.4")

      # A branch with no CVEs yet is a real, empty answer.
      assert {:ok, []} =
               Advisories.parse_openssl_page("<h1>Vulnerabilities 4.1</h1><p>None.</p>", "4.1")
    end
  end

  describe "openssl_findings/3" do
    setup do
      {:ok, entries} = Advisories.parse_openssl_page(@openssl_html, "3.4")
      %{entries: entries}
    end

    test "3.4.0 is affected by every listed CVE with its 3.4 fix", %{entries: entries} do
      findings = Advisories.openssl_findings(entries, "3.4.0", "3.4")

      assert Enum.map(findings, &{&1.id, &1.severity, &1.fixed_in}) == [
               {"CVE-2026-35189", :low, "3.4.8"},
               {"CVE-2026-84782", :high, "3.4.8"},
               {"CVE-2026-63072", :medium, "3.4.7"}
             ]

      assert %Finding{
               package: "openssl",
               version: "3.4.0",
               url: "https://openssl-library.org/news/vulnerabilities-3.4/#CVE-2026-84782",
               source: :openssl_vulnerabilities
             } = Enum.at(findings, 1)
    end

    test "the 'before' version is the fix and is not affected", %{entries: entries} do
      ids = entries |> Advisories.openssl_findings("3.4.7", "3.4") |> Enum.map(& &1.id)
      assert ids == ["CVE-2026-35189", "CVE-2026-84782"]
      assert Advisories.openssl_findings(entries, "3.4.8", "3.4") == []
    end

    test "only ranges on the installed branch apply" do
      entry = %{
        cve: "CVE-X",
        severity: :high,
        title: "t",
        affected: [{"3.0.0", nil}, {"3.4.2", "3.4.5"}]
      }

      # "from 3.0.0 before" (open-ended, 3.0 branch) must not catch 3.4.x.
      assert Advisories.openssl_findings([entry], "3.4.1", "3.4") == []
      assert [%Finding{fixed_in: "3.4.5"}] = Advisories.openssl_findings([entry], "3.4.2", "3.4")

      assert [%Finding{fixed_in: nil}] =
               Advisories.openssl_findings(
                 [%{entry | affected: [{"3.4.0", nil}]}],
                 "3.4.9",
                 "3.4"
               )
    end
  end

  describe "openssl_eol/3" do
    test "3.4 is past end of life from its EOL date onward, as a :high finding" do
      assert {:eol, ~D[2026-10-22], finding} =
               Advisories.openssl_eol(@eol_cycles, "3.4.0", ~D[2026-10-22])

      assert %Finding{
               id: "OPENSSL-EOL-3.4",
               severity: :high,
               package: "openssl",
               version: "3.4.0",
               fixed_in: "3.5.9",
               source: :endoflife_date
             } = finding

      assert finding.title == "OpenSSL 3.4 reached end of life on 2026-10-22"
      assert finding.description =~ "3.5 LTS"
    end

    test "a branch before its EOL date is supported" do
      assert Advisories.openssl_eol(@eol_cycles, "3.4.0", ~D[2026-10-21]) ==
               {:supported, ~D[2026-10-22]}

      assert Advisories.openssl_eol(@eol_cycles, "3.5.9", ~D[2026-10-22]) ==
               {:supported, ~D[2030-04-08]}
    end

    test "an unknown branch is reported as such" do
      assert Advisories.openssl_eol(@eol_cycles, "9.9.0", ~D[2026-10-22]) == :unknown_branch
    end

    test "eol: true without a date is end of life" do
      cycles = [%{"cycle" => "3.4", "eol" => true}]

      assert {:eol, nil, %Finding{severity: :high, title: "OpenSSL 3.4 reached end of life"}} =
               Advisories.openssl_eol(cycles, "3.4.0", ~D[2026-10-22])

      assert {:supported, nil} =
               Advisories.openssl_eol(
                 [%{"cycle" => "3.4", "eol" => false}],
                 "3.4.0",
                 ~D[2026-10-22]
               )
    end
  end

  test "openssl_branch/1 names the advisory page" do
    assert Advisories.openssl_branch("3.4.0") == {:ok, "3.4"}
    assert Advisories.openssl_branch("3.5.9") == {:ok, "3.5"}
    assert Advisories.openssl_branch("1.1.1w") == {:ok, "1.1.1"}
    assert Advisories.openssl_branch("junk") == :error
  end

  test "severity/1 maps GitHub and OpenSSL labels" do
    assert Advisories.severity("critical") == :critical
    assert Advisories.severity("High") == :high
    assert Advisories.severity("MODERATE") == :medium
    assert Advisories.severity("medium") == :medium
    assert Advisories.severity("Low") == :low
    assert Advisories.severity("other") == :unknown
    assert Advisories.severity(nil) == :unknown
  end

  test "openssl_compare/2 orders OpenSSL versions" do
    assert Advisories.openssl_compare("3.4.0", "3.4") == :eq
    assert Advisories.openssl_compare("3.0.10", "3.0.9") == :gt
    assert Advisories.openssl_compare("3.4.0-beta1", "3.4.0") == :eq
    assert Advisories.openssl_compare("1.1.1", "1.1.1a") == :lt
    assert Advisories.openssl_compare("1.1.1z", "1.1.1za") == :lt
    assert Advisories.openssl_compare("1.1.1zj", "1.1.1zi") == :gt
    assert Advisories.openssl_compare("x", "1.0") == :error
  end

  describe "SQLite CVE page" do
    # The real www.sqlite.org/cves.html (2026-10-22) with its table cut to 13
    # rows: ten with a fixing release, three SQLite disputes.
    @sqlite_html File.read!(Path.join(@fixtures, "sqlite_cves.html"))

    @before_3_45 ~w(CVE-2025-29087 CVE-2025-29088 CVE-2025-3277 CVE-2025-52099 CVE-2025-6965
                    CVE-2025-70873 CVE-2025-7709 CVE-2026-11822 CVE-2026-11824)

    setup do
      {:ok, entries} = Advisories.parse_sqlite_cves_page(@sqlite_html)
      %{entries: entries}
    end

    test "parses each row's CVEs, fixing release and comment", %{entries: entries} do
      assert Enum.count(entries, & &1.fixed_in) == 10

      assert %{
               cves: ["CVE-2026-11822", "CVE-2026-11824"],
               fixed_in: "3.53.2",
               severity: nil,
               comment: "An attacker who can execute arbitrary SQL" <> _
             } = hd(entries)

      disputed = for %{fixed_in: nil, cves: cves} <- entries, cve <- cves, do: cve

      assert Enum.sort(disputed) ==
               ~w(CVE-2022-46908 CVE-2023-32697 CVE-2026-51296 CVE-2026-51297 CVE-2026-51300
                  CVE-2026-51302 CVE-2026-51303 CVE-2026-51304)
    end

    test "SQLite 3.53.2 (exqlite 0.37.0) has none: 11822/11824 were fixed in it",
         %{entries: entries} do
      assert Advisories.sqlite_findings(entries, "3.53.2") == []
      assert Advisories.sqlite_findings(entries, "3.100.0") == []
    end

    test "SQLite 3.53.1 is one release short of the 3.53.2 fix", %{entries: entries} do
      assert [
               %Finding{
                 id: "CVE-2026-11822",
                 severity: :medium,
                 package: "sqlite",
                 version: "3.53.1",
                 fixed_in: "3.53.2",
                 source: :sqlite_cves,
                 layer: :bundled_runtime,
                 url: "https://www.sqlite.org/cves.html#CVE-2026-11822"
               } = finding,
               %Finding{id: "CVE-2026-11824", fixed_in: "3.53.2"}
             ] = Advisories.sqlite_findings(entries, "3.53.1")

      assert String.starts_with?(finding.title, "An attacker who can execute arbitrary SQL")
      assert String.ends_with?(finding.title, "write off the end of a heap buffer.")
      assert finding.description =~ "SQLITE_DBCONFIG_DEFENSIVE disabled"
    end

    test "SQLite 3.45.0 gets every CVE fixed after it, disputes skipped", %{entries: entries} do
      findings = Advisories.sqlite_findings(entries, "3.45.0")

      assert findings |> Enum.map(& &1.id) |> Enum.sort() == @before_3_45
      assert Enum.all?(findings, &(&1.severity == :medium))

      fixes = Map.new(findings, &{&1.id, &1.fixed_in})
      assert fixes["CVE-2025-6965"] == "3.50.2"
      assert fixes["CVE-2025-70873"] == "3.52.0"
    end

    test "versions compare numerically, not as strings", %{entries: entries} do
      ids = entries |> Advisories.sqlite_findings("3.9.0") |> Enum.map(& &1.id)
      assert "CVE-2022-35737" in ids
      refute "CVE-2023-32697" in ids
    end

    test "an 'unreproducible' Fix cell is a dispute, not a fix or a parse failure" do
      html =
        String.replace(
          @sqlite_html,
          "<td valign='top'>Not a bug in SQLite</td>",
          "<td valign='top'>Unreproducible</td>"
        )

      assert {:ok, entries} = Advisories.parse_sqlite_cves_page(html)
      assert Enum.count(entries, &is_nil(&1.fixed_in)) == 3
      assert Enum.count(Advisories.sqlite_findings(entries, "3.0.0")) == 13
    end

    test "a Severity column, when the page has one, sets the severity" do
      html =
        @sqlite_html
        |> String.replace(
          ~s(<th valign="bottom">Comments</th>),
          ~s(<th valign="bottom">Comments</th>\n<th valign="bottom">Severity</th>)
        )
        |> String.replace("</td>\n</tr>", "</td>\n<td valign='top'>High</td>\n</tr>")

      assert {:ok, entries} = Advisories.parse_sqlite_cves_page(html)
      assert [%Finding{severity: :high}, _] = Advisories.sqlite_findings(entries, "3.53.1")
    end

    test "a redesigned or wrong page is rejected, not read as clean" do
      unknown_fix = String.replace(@sqlite_html, "Not a bug in SQLite</td>", "Pending</td>")
      no_fix_column = String.replace(@sqlite_html, ">Fix</th>", ">Fixed by</th>")

      no_table =
        String.replace(@sqlite_html, "Status Of Recent SQLite CVEs", "Recent SQLite news")

      no_versions =
        Regex.replace(
          Regex.compile!("<a href=\"releaselog/[^\"]+\">[^<]+</a><br>\\([^)]+\\)"),
          @sqlite_html,
          "Not a bug in SQLite"
        )

      for html <- [unknown_fix, no_fix_column, no_table, no_versions, "<html>maintenance</html>"] do
        assert Advisories.parse_sqlite_cves_page(html) == {:error, :unrecognised_page}
      end
    end
  end
end
