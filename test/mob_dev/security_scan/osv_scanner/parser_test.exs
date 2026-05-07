defmodule MobDev.SecurityScan.OsvScanner.ParserTest do
  use ExUnit.Case, async: true

  alias MobDev.SecurityScan.Finding
  alias MobDev.SecurityScan.OsvScanner.Parser

  defp osv_json(opts \\ []) do
    %{
      "results" => [
        %{
          "source" => %{"path" => "/p/mix.lock", "type" => "lockfile"},
          "packages" => [
            %{
              "package" => %{
                "name" => Keyword.get(opts, :name, "bandit"),
                "version" => Keyword.get(opts, :version, "1.10.4"),
                "ecosystem" => "Hex"
              },
              "groups" => [
                %{
                  "ids" => Keyword.get(opts, :ids, ["GHSA-1"]),
                  "max_severity" => Keyword.get(opts, :max_severity, "8.2")
                }
              ],
              "vulnerabilities" =>
                Keyword.get(opts, :vulnerabilities, [
                  %{
                    "id" => "GHSA-1",
                    "aliases" => ["CVE-2026-1", "GHSA-1"],
                    "summary" => "Path traversal in bandit",
                    "details" => "Long description",
                    "affected" => [
                      %{
                        "ranges" => [
                          %{"events" => [%{"introduced" => "0.5.9"}, %{"fixed" => "1.11.0"}]}
                        ]
                      }
                    ],
                    "references" => [%{"url" => "https://example.com/advisory/1"}]
                  }
                ])
            }
          ]
        }
      ]
    }
  end

  describe "findings/2" do
    test "extracts a finding from a single vulnerability" do
      [finding] = Parser.findings(osv_json(), :hex_deps)

      assert %Finding{
               id: "GHSA-1",
               severity: :high,
               package: "bandit",
               version: "1.10.4",
               fixed_in: "1.11.0",
               source: :osv_scanner,
               layer: :hex_deps,
               title: "Path traversal in bandit",
               description: "Long description",
               url: "https://example.com/advisory/1"
             } = finding
    end

    test "tags findings with the supplied layer atom" do
      [%Finding{layer: :gradle_deps}] = Parser.findings(osv_json(), :gradle_deps)
    end

    test "returns [] for an empty results list" do
      assert Parser.findings(%{"results" => []}, :hex_deps) == []
    end

    test "returns [] when the package has no vulnerabilities key" do
      json = %{
        "results" => [
          %{"packages" => [%{"package" => %{"name" => "p", "version" => "1"}}]}
        ]
      }

      assert Parser.findings(json, :hex_deps) == []
    end

    test "handles missing groups field gracefully (severity becomes :unknown)" do
      pkg = %{
        "package" => %{"name" => "p", "version" => "1.0"},
        "vulnerabilities" => [%{"id" => "X", "summary" => "s"}]
      }

      json = %{"results" => [%{"packages" => [pkg]}]}

      assert [%Finding{severity: :unknown, id: "X"}] = Parser.findings(json, :hex_deps)
    end
  end

  describe "CVSS severity bands" do
    test "9.0+ is critical" do
      [%Finding{severity: :critical}] = Parser.findings(osv_json(max_severity: "9.0"), :hex_deps)
      [%Finding{severity: :critical}] = Parser.findings(osv_json(max_severity: "10.0"), :hex_deps)
    end

    test "7.0–8.9 is high" do
      [%Finding{severity: :high}] = Parser.findings(osv_json(max_severity: "7.0"), :hex_deps)
      [%Finding{severity: :high}] = Parser.findings(osv_json(max_severity: "8.9"), :hex_deps)
    end

    test "4.0–6.9 is medium" do
      [%Finding{severity: :medium}] = Parser.findings(osv_json(max_severity: "4.0"), :hex_deps)
      [%Finding{severity: :medium}] = Parser.findings(osv_json(max_severity: "6.9"), :hex_deps)
    end

    test "0.1–3.9 is low" do
      [%Finding{severity: :low}] = Parser.findings(osv_json(max_severity: "0.1"), :hex_deps)
      [%Finding{severity: :low}] = Parser.findings(osv_json(max_severity: "3.9"), :hex_deps)
    end

    test "unparseable / missing scores are :unknown" do
      [%Finding{severity: :unknown}] = Parser.findings(osv_json(max_severity: nil), :hex_deps)
      [%Finding{severity: :unknown}] = Parser.findings(osv_json(max_severity: ""), :hex_deps)
      [%Finding{severity: :unknown}] = Parser.findings(osv_json(max_severity: "garbage"), :hex_deps)
    end
  end

  describe "fixed_in extraction" do
    test "picks the first 'fixed' event from affected.ranges.events" do
      [%Finding{fixed_in: "1.11.0"}] = Parser.findings(osv_json(), :hex_deps)
    end

    test "returns nil when no range has a fixed event" do
      vulns = [
        %{
          "id" => "X",
          "aliases" => ["X"],
          "affected" => [%{"ranges" => [%{"events" => [%{"introduced" => "0.0.0"}]}]}]
        }
      ]

      [%Finding{fixed_in: nil}] = Parser.findings(osv_json(vulnerabilities: vulns), :hex_deps)
    end
  end

  describe "url extraction" do
    test "picks the first reference URL" do
      [%Finding{url: "https://example.com/advisory/1"}] =
        Parser.findings(osv_json(), :hex_deps)
    end

    test "returns nil when references is missing" do
      vulns = [%{"id" => "X", "aliases" => ["X"]}]
      [%Finding{url: nil}] = Parser.findings(osv_json(vulnerabilities: vulns), :hex_deps)
    end
  end
end
