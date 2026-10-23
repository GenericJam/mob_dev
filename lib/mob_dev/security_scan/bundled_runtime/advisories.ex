defmodule MobDev.SecurityScan.BundledRuntime.Advisories do
  @moduledoc """
  Matches upstream advisory data against the OTP and OpenSSL versions
  fingerprinted from a cached runtime, producing `Finding`s.

  Pure: callers pass the decoded feed bodies (fetched or cached by
  `MobDev.SecurityScan.BundledRuntime.AdvisoryFeed`) and the installed
  versions. Three sources:

    * **Erlang/OTP** — the GitHub repository security advisories of
      `erlang/otp`. OSV.dev is no help here: the EEF records it carries
      use `GIT` ranges only, so a `pkg:otp/ssl@11.7` query returns nothing.
    * **OpenSSL** — `openssl-library.org/news/vulnerabilities-<branch>/`,
      one page per release branch. OpenSSL retired its JSON feed; the
      HTML page is the published record.
    * **OpenSSL branch EOL** — `endoflife.date/api/openssl.json`.

  ## How an OTP advisory is matched

  Each advisory lists `vulnerabilities[]`, one entry per package: the
  umbrella `OTP` release plus the individual applications (`ssl`,
  `public_key`, `erts`, ...). `vulnerable_version_range` is the
  introduction point (`">= 9.5"`) and `patched_versions` names one fix
  per maintained branch, e.g. `"11.7.8, 11.6.0.7, 11.2.12.14"`.

  Application entries are matched against the application versions in
  the tarball's `lib/` (what actually gets packaged); the `OTP` entry is
  only used when an advisory names no application, because the app
  entries are the precise statement and an app the runtime doesn't ship
  can't be vulnerable in it. A package may appear more than once with
  different introduction points; its entries are merged.

  OTP and application versions form a tree, not a line: `11.6.0.7` is a
  maintenance branch off `11.6`, and `11.7` neither contains nor precedes
  it. `otp_compare/2` implements the documented comparison (OTP's
  `versions:compare/2`, "Version Scheme" in the OTP system principles),
  which answers `:same`, `:ancestor`, `:descendant` or `:undefined`;
  the advisories use `>=` in that sense. An installed version is:

    * **affected** when it is the same as, or a descendant of, some
      entry's introduction point;
    * **fixed** when it is the same as, or a descendant of, some patched
      version;
    * vulnerable when affected and not fixed. The fix reported is the
      patched version descending from it that shares the longest prefix
      with it (`11.7` → `11.7.8`, `11.2` → `11.2.12.14`), or none when no
      patched version descends from it (an unmaintained branch).

  A release candidate (`29.0-rc3`) is treated as an ancestor of its
  release.
  """

  alias MobDev.SecurityScan.Finding

  @typedoc """
  Versions fingerprinted from one runtime tarball. `:otp` is the full
  OTP release version (`releases/*/OTP_VERSION`); `:apps` lists
  `{name, version}` for each application directory, including `erts`.
  """
  @type installed :: %{otp: String.t() | nil, apps: [{String.t(), String.t()}]}

  @typedoc "Outcome of matching a branch against endoflife.date data."
  @type eol_status ::
          {:eol, Date.t() | nil, Finding.t()}
          | {:supported, Date.t() | nil}
          | :unknown_branch

  @otp_advisories_url "https://github.com/erlang/otp/security/advisories"

  @doc "Human-facing index of the Erlang/OTP advisories."
  @spec otp_advisories_url() :: String.t()
  def otp_advisories_url, do: @otp_advisories_url

  @doc """
  Findings for every published, non-withdrawn OTP advisory that affects
  the installed versions.
  """
  @spec otp_findings([map()], installed()) :: [Finding.t()]
  def otp_findings(advisories, installed) when is_list(advisories) do
    advisories
    |> Enum.filter(&published?/1)
    |> Enum.flat_map(&advisory_findings(&1, installed))
  end

  defp published?(advisory) do
    advisory["withdrawn_at"] == nil and advisory["state"] in [nil, "published"]
  end

  defp advisory_findings(advisory, installed) do
    {otp_entries, app_entries} =
      advisory
      |> Map.get("vulnerabilities", [])
      |> Enum.group_by(&package_name/1)
      |> Map.pop("otp")

    targets =
      case {otp_entries, map_size(app_entries)} do
        {[_ | _], 0} -> [{"otp", otp_entries}]
        _ -> app_entries
      end

    for {package, entries} <- targets,
        version <- installed_versions(installed, package),
        {:vulnerable, fixed_in} <- [otp_verdict(version, entries)] do
      otp_finding(advisory, package, version, fixed_in, entries)
    end
  end

  defp package_name(%{"package" => %{"name" => name}}) when is_binary(name),
    do: String.downcase(name)

  defp package_name(_entry), do: nil

  defp installed_versions(%{otp: otp}, "otp"), do: List.wrap(otp)

  defp installed_versions(%{apps: apps}, package) do
    for {^package, version} <- apps, uniq: true, do: version
  end

  @doc """
  Verdict for one installed `version` against the merged advisory
  entries for its package. See the moduledoc for the rules.
  """
  @spec otp_verdict(String.t(), [map()]) :: {:vulnerable, String.t() | nil} | :not_affected
  def otp_verdict(version, entries) do
    with {:ok, installed} <- parse_otp_version(version),
         true <- Enum.any?(entries, &in_range?(installed, &1["vulnerable_version_range"])) do
      patched = Enum.flat_map(entries, &split_otp_versions(&1["patched_versions"]))

      if Enum.any?(patched, fn {_raw, p} -> otp_cmp(installed, p) in [:same, :descendant] end),
        do: :not_affected,
        else: {:vulnerable, closest_fix(installed, patched)}
    else
      _ -> :not_affected
    end
  end

  defp closest_fix({nums, _pre} = installed, patched) do
    patched
    |> Enum.filter(fn {_raw, p} -> otp_cmp(installed, p) == :ancestor end)
    |> Enum.sort_by(fn {_raw, {p_nums, _}} -> {-common_prefix(nums, p_nums), p_nums} end)
    |> case do
      [{raw, _} | _] -> raw
      [] -> nil
    end
  end

  defp common_prefix([x | xs], [x | ys]), do: 1 + common_prefix(xs, ys)
  defp common_prefix(_xs, _ys), do: 0

  defp split_otp_versions(nil), do: []

  defp split_otp_versions(list) when is_binary(list) do
    list
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.flat_map(fn raw ->
      case parse_otp_version(raw) do
        {:ok, parsed} -> [{raw, parsed}]
        :error -> []
      end
    end)
  end

  # GitHub ranges seen so far are all ">= X"; accept the general
  # comma-separated `op version` form. An unparseable range is treated as
  # matching, so a format change shows up as a finding, not silence.
  defp in_range?(_installed, range) when range in [nil, ""], do: true

  defp in_range?(installed, range) do
    range
    |> String.split(",", trim: true)
    |> Enum.all?(&constraint_holds?(installed, String.trim(&1)))
  end

  defp constraint_holds?(installed, constraint) do
    pattern = Regex.compile!("^(>=|<=|>|<|=)?\\s*(\\S+)$")

    with [_, op, raw] <- Regex.run(pattern, constraint),
         {:ok, bound} <- parse_otp_version(raw) do
      cmp = otp_cmp(installed, bound)

      case op do
        ">=" -> cmp in [:same, :descendant]
        ">" -> cmp == :descendant
        "<=" -> cmp in [:same, :ancestor]
        "<" -> cmp == :ancestor
        _ -> cmp == :same
      end
    else
      _ -> true
    end
  end

  @doc """
  Compare two OTP or OTP-application versions per the OTP version scheme:
  how `v1` relates to `v2` in the version tree. `:error` when either is
  not a version.
  """
  @spec otp_compare(String.t(), String.t()) ::
          :same | :ancestor | :descendant | :undefined | :error
  def otp_compare(v1, v2) do
    with {:ok, a} <- parse_otp_version(v1),
         {:ok, b} <- parse_otp_version(v2) do
      otp_cmp(a, b)
    end
  end

  # `{components, rc}`: trailing-zero patch dropped ("11.7.0" is "11.7"),
  # rc is the release-candidate number or nil, and an otp_patch_apply
  # `**` marker is ignored.
  defp parse_otp_version(raw) when is_binary(raw) do
    pattern = Regex.compile!("^(\\d+(?:\\.\\d+)*)(?:-rc(\\d+))?(?:\\*\\*)?$")

    case Regex.run(pattern, String.trim(raw)) do
      [_, nums | rc] ->
        components = nums |> String.split(".") |> Enum.map(&String.to_integer/1)
        {:ok, {normalize_otp(components), rc |> List.first() |> parse_rc()}}

      nil ->
        :error
    end
  end

  defp parse_otp_version(_raw), do: :error

  defp normalize_otp([major]), do: [major, 0]
  defp normalize_otp([major, minor, 0]), do: [major, minor]
  defp normalize_otp(components), do: components

  defp parse_rc(nil), do: nil
  defp parse_rc(""), do: nil
  defp parse_rc(n), do: String.to_integer(n)

  defp otp_cmp({a, rc_a}, {b, rc_b}) do
    case {otp_tree_cmp(a, b, 1), rc_a, rc_b} do
      {:same, nil, nil} -> :same
      {:same, nil, _rc} -> :descendant
      {:same, _rc, nil} -> :ancestor
      {:same, x, y} when x < y -> :ancestor
      {:same, x, y} when x > y -> :descendant
      {result, _, _} -> result
    end
  end

  # Port of OTP's versions:cmp/3. A list "ends on the trunk" when the
  # version has at most three components (n + remaining <= 3); a smaller
  # component is an ancestor only from the trunk or as the last component
  # of its own branch, otherwise the two sit on unrelated branches.
  defp otp_tree_cmp([x | xs], [x | ys], n), do: otp_tree_cmp(xs, ys, n + 1)
  defp otp_tree_cmp([], [], _n), do: :same
  defp otp_tree_cmp([], [_ | _], _n), do: :ancestor
  defp otp_tree_cmp([_ | _], [], _n), do: :descendant

  defp otp_tree_cmp([x | xs], [y | _], n) when x < y do
    if xs == [] or n + length(xs) <= 3, do: :ancestor, else: :undefined
  end

  defp otp_tree_cmp([_x | _], [_y | ys], n) do
    if ys == [] or n + length(ys) <= 3, do: :descendant, else: :undefined
  end

  defp otp_finding(advisory, package, version, fixed_in, entries) do
    ghsa = advisory["ghsa_id"]
    ranges = entries |> Enum.map(& &1["vulnerable_version_range"]) |> Enum.reject(&is_nil/1)

    patched =
      entries
      |> Enum.flat_map(&split_otp_versions(&1["patched_versions"]))
      |> Enum.map(&elem(&1, 0))

    label = if package == "otp", do: "Erlang/OTP", else: "OTP application #{package}"

    fix_text =
      if fixed_in,
        do: "Upgrade to #{fixed_in} or a descendant (patched: #{Enum.join(patched, ", ")}).",
        else: "No patched version descends from it (patched: #{Enum.join(patched, ", ")})."

    %Finding{
      id: advisory["cve_id"] || ghsa,
      severity: severity(advisory["severity"]),
      package: if(package == "otp", do: "otp", else: "otp/#{package}"),
      version: version,
      fixed_in: fixed_in,
      title: advisory |> Map.get("summary", "") |> String.trim(),
      description:
        "#{label} #{version} is affected (#{ghsa}; affected #{Enum.join(ranges, " | ")}). " <>
          fix_text,
      url: advisory["html_url"] || @otp_advisories_url,
      source: :otp_security_advisories,
      layer: :bundled_runtime
    }
  end

  @doc """
  The OpenSSL release branch a version belongs to, which names its
  advisory page: `3.4.0` → `3.4`, `1.1.1w` → `1.1.1` (pre-3.0 branches
  were three components wide).
  """
  @spec openssl_branch(String.t()) :: {:ok, String.t()} | :error
  def openssl_branch(version) do
    case parse_version(version) do
      {:ok, {[major, minor | _], _}} when major >= 3 -> {:ok, "#{major}.#{minor}"}
      {:ok, {[major, minor, patch | _], _}} -> {:ok, "#{major}.#{minor}.#{patch}"}
      _ -> :error
    end
  end

  @doc "URL of the advisory page for an OpenSSL branch."
  @spec openssl_page_url(String.t()) :: String.t()
  def openssl_page_url(branch),
    do: "https://openssl-library.org/news/vulnerabilities-#{branch}/index.html"

  @doc """
  Parse an `openssl-library.org/news/vulnerabilities-<branch>/` page into
  `%{cve, severity, title, affected: [{from, before | nil}]}` entries.

  Returns `{:error, :unrecognised_page}` when the page doesn't parse the
  way the published layout does, so a redesigned or wrong page fails
  loudly instead of reading as "no CVEs": it must carry the
  `Vulnerabilities <branch>` heading, every CVE block must yield a known
  severity and at least one affected range, and a page that mentions a
  CVE must yield at least one block.
  """
  @spec parse_openssl_page(String.t(), String.t()) ::
          {:ok, [map()]} | {:error, :unrecognised_page}
  def parse_openssl_page(html, branch) do
    heading = Regex.compile!("<h1>\\s*Vulnerabilities\\s+#{Regex.escape(branch)}\\s*</h1>")
    block = Regex.compile!(~S{<h2 id="(CVE-\d+-\d+)">(.*?)(?=<h2 id="CVE-|\z)}, "s")

    entries =
      if Regex.match?(heading, html),
        do: block |> Regex.scan(html, capture: :all_but_first) |> Enum.map(&openssl_entry/1),
        else: :no_heading

    cond do
      entries == :no_heading ->
        {:error, :unrecognised_page}

      entries == [] and String.contains?(html, "CVE-") ->
        {:error, :unrecognised_page}

      Enum.any?(entries, &(&1.severity == :unknown or &1.affected == [])) ->
        {:error, :unrecognised_page}

      true ->
        {:ok, entries}
    end
  end

  defp openssl_entry([cve, body]) do
    affected =
      ~S{<li>\s*from\s+([0-9][0-9a-z.]*)\s+before\s*([0-9][0-9a-z.]*)?\s*</li>}
      |> Regex.compile!()
      |> Regex.scan(body, capture: :all_but_first)
      |> Enum.map(fn
        [from] -> {from, nil}
        [from, ""] -> {from, nil}
        [from, before] -> {from, before}
      end)

    %{
      cve: cve,
      severity: body |> grid_value("Severity") |> severity(),
      title: body |> grid_value("Title") |> decode_entities(),
      affected: affected
    }
  end

  defp decode_entities(nil), do: nil

  defp decode_entities(text) do
    Regex.replace(Regex.compile!("&(#x[0-9a-fA-F]+|#[0-9]+|amp|lt|gt|quot|apos);"), text, fn
      _, "amp" -> "&"
      _, "lt" -> "<"
      _, "gt" -> ">"
      _, "quot" -> "\""
      _, "apos" -> "'"
      _, "#x" <> hex -> <<String.to_integer(hex, 16)::utf8>>
      _, "#" <> dec -> <<String.to_integer(dec)::utf8>>
    end)
  end

  defp grid_value(body, label) do
    pattern =
      Regex.compile!(
        "#{label}</span></div>\\s*<div[^>]*>\\s*([^<]*?)\\s*</div>",
        "s"
      )

    case Regex.run(pattern, body, capture: :all_but_first) do
      [value] -> value
      nil -> nil
    end
  end

  @doc """
  Findings for every CVE on a branch page whose affected range on the
  installed version's branch contains it.
  """
  @spec openssl_findings([map()], String.t(), String.t()) :: [Finding.t()]
  def openssl_findings(entries, version, branch) do
    with {:ok, installed} <- parse_version(version) do
      for entry <- entries,
          {:ok, before} <- [affecting_range(entry.affected, installed, branch)] do
        openssl_finding(entry, version, before, branch)
      end
    else
      _ -> []
    end
  end

  # A range applies only on its own branch: the page for 3.4 also lists
  # "from 3.0.0 before 3.0.23", and an open-ended "from 3.0.0 before"
  # would otherwise swallow every later branch.
  defp affecting_range(affected, installed, branch) do
    Enum.find_value(affected, :none, fn {from, before} ->
      with {:ok, ^branch} <- openssl_branch(from),
           {:ok, from_v} <- parse_version(from),
           true <- compare(installed, from_v) != :lt,
           true <- below?(installed, before) do
        {:ok, before}
      else
        _ -> nil
      end
    end)
  end

  defp below?(_installed, nil), do: true

  defp below?(installed, before) do
    case parse_version(before) do
      {:ok, bound} -> compare(installed, bound) == :lt
      :error -> true
    end
  end

  defp openssl_finding(entry, version, before, branch) do
    fix_text = if before, do: "Fixed in #{before}.", else: "No fixed release is listed."

    %Finding{
      id: entry.cve,
      severity: entry.severity,
      package: "openssl",
      version: version,
      fixed_in: before,
      title: entry.title,
      description: "The bundled OpenSSL #{version} (libcrypto.a) is affected. " <> fix_text,
      url: "https://openssl-library.org/news/vulnerabilities-#{branch}/##{entry.cve}",
      source: :openssl_vulnerabilities,
      layer: :bundled_runtime
    }
  end

  @doc """
  Whether the OpenSSL branch of `version` is past end of life on `today`
  according to endoflife.date data. A branch is treated as EOL from its
  EOL date onward: on that day it stops receiving fixes. `eol: true`
  (end of life, date not given) is EOL with a `nil` date.
  """
  @spec openssl_eol([map()], String.t(), Date.t()) :: eol_status()
  def openssl_eol(cycles, version, today) do
    with {:ok, branch} <- openssl_branch(version),
         %{} = cycle <- Enum.find(cycles, &(&1["cycle"] == branch)) do
      case {parse_eol(cycle["eol"]), cycle["eol"]} do
        {%Date{} = eol, _} ->
          if Date.compare(today, eol) == :lt,
            do: {:supported, eol},
            else: {:eol, eol, eol_finding(branch, version, eol, cycles, today)}

        {nil, true} ->
          {:eol, nil, eol_finding(branch, version, nil, cycles, today)}

        {nil, _} ->
          {:supported, nil}
      end
    else
      _ -> :unknown_branch
    end
  end

  defp parse_eol(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      {:error, _} -> nil
    end
  end

  defp parse_eol(_value), do: nil

  defp eol_finding(branch, version, eol, cycles, today) do
    supported_lts =
      cycles
      |> Enum.filter(fn c -> c["lts"] == true and supported?(c, today) end)
      |> Enum.map(&{&1["latest"], &1["cycle"]})
      |> Enum.max_by(fn {_latest, cycle} -> version_key(cycle) end, fn -> nil end)

    {fixed_in, hint} =
      case supported_lts do
        {latest, cycle} -> {latest, " Move to a supported branch, e.g. #{cycle} LTS (#{latest})."}
        nil -> {nil, ""}
      end

    %Finding{
      id: "OPENSSL-EOL-#{branch}",
      severity: :high,
      package: "openssl",
      version: version,
      fixed_in: fixed_in,
      title:
        "OpenSSL #{branch} reached end of life" <>
          if(eol, do: " on #{Date.to_iso8601(eol)}", else: ""),
      description:
        "The bundled OpenSSL #{version} is on the #{branch} branch, which no longer " <>
          "receives security fixes; vulnerabilities found from now on will not be " <>
          "listed for it." <> hint,
      url: "https://endoflife.date/openssl",
      source: :endoflife_date,
      layer: :bundled_runtime
    }
  end

  defp supported?(cycle, today) do
    case parse_eol(cycle["eol"]) do
      nil -> cycle["eol"] == false
      eol -> Date.compare(today, eol) == :lt
    end
  end

  defp version_key(version) do
    case parse_version(version) do
      {:ok, {nums, _}} -> pad(nums, 4)
      :error -> []
    end
  end

  @doc """
  Map an upstream severity label (GitHub `critical/high/medium/low`,
  OpenSSL `Critical/High/Moderate/Low`) to a `Finding` severity.
  """
  @spec severity(String.t() | nil) :: Finding.severity()
  def severity(label) when is_binary(label) do
    case label |> String.trim() |> String.downcase() do
      "critical" -> :critical
      "high" -> :high
      sev when sev in ["medium", "moderate"] -> :medium
      "low" -> :low
      _ -> :unknown
    end
  end

  def severity(_label), do: :unknown

  @doc """
  Compare two OpenSSL versions, which are linearly ordered: dotted numbers
  with an optional letter suffix (`1.1.1zj`). Missing components count as
  zero; letter suffixes order by length, then alphabetically (`z` < `za`).
  A pre-release tail (`3.4.0-beta1`) compares as its release, so a beta
  is reported against the release's CVEs rather than none.
  """
  @spec openssl_compare(String.t(), String.t()) :: :lt | :eq | :gt | :error
  def openssl_compare(a, b) do
    with {:ok, pa} <- parse_version(a),
         {:ok, pb} <- parse_version(b) do
      compare(pa, pb)
    end
  end

  defp parse_version(raw) when is_binary(raw) do
    pattern = Regex.compile!("^v?(\\d+(?:\\.\\d+)*)([a-z]*)(?:-\\S*)?$")

    case Regex.run(pattern, String.trim(raw)) do
      [_, nums, suffix] ->
        {:ok, {nums |> String.split(".") |> Enum.map(&String.to_integer/1), suffix}}

      nil ->
        :error
    end
  end

  defp parse_version(_raw), do: :error

  defp compare({nums_a, suffix_a}, {nums_b, suffix_b}) do
    width = max(length(nums_a), length(nums_b))

    case {pad(nums_a, width), pad(nums_b, width)} do
      {same, same} ->
        compare_terms({byte_size(suffix_a), suffix_a}, {byte_size(suffix_b), suffix_b})

      {a, b} ->
        compare_terms(a, b)
    end
  end

  defp compare_terms(a, b) when a < b, do: :lt
  defp compare_terms(a, b) when a > b, do: :gt
  defp compare_terms(_a, _b), do: :eq

  defp pad(nums, width), do: nums ++ List.duplicate(0, max(width - length(nums), 0))
end
