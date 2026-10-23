defmodule MobDev.SecurityScan.Layers.BundledRuntimeTest do
  use ExUnit.Case, async: true

  alias MobDev.SecurityScan.Finding
  alias MobDev.SecurityScan.Layers.BundledRuntime

  @moduletag :tmp_dir

  defp build_tarball(cache_dir, platform, hash, opts) do
    dir_name =
      case platform do
        :android -> "otp-android-#{hash}"
        :android_arm32 -> "otp-android-arm32-#{hash}"
        :ios_sim -> "otp-ios-sim-#{hash}"
        :ios_device -> "otp-ios-device-#{hash}"
      end

    path = Path.join(cache_dir, dir_name)

    erts_lib =
      Path.join([path, "erts-#{MobDev.SecurityScan.BundledVersions.active().erts}", "lib"])

    File.mkdir_p!(erts_lib)

    if openssl = opts[:openssl] do
      content =
        :crypto.strong_rand_bytes(256) <>
          "OpenSSL default\0" <>
          "OpenSSL #{openssl} 22 Oct 2024\0"

      File.write!(Path.join(erts_lib, "libcrypto.a"), content)
    end

    if elixir_vsn = opts[:elixir] do
      ebin = Path.join([path, "lib", "elixir", "ebin"])
      File.mkdir_p!(ebin)

      File.write!(
        Path.join(ebin, "elixir.app"),
        ~s({application,elixir,[{vsn,"#{elixir_vsn}"}]})
      )
    end

    if exqlite_vsn = opts[:exqlite] do
      File.mkdir_p!(Path.join([path, "lib", "exqlite-#{exqlite_vsn}"]))
    end

    # A real tarball always has releases/*/OTP_VERSION; default to the
    # active bundle's so only tests about it need to say so.
    if otp_vsn =
         Keyword.get(opts, :otp, MobDev.SecurityScan.BundledVersions.active()[:otp_version]) do
      release_dir = Path.join([path, "releases", otp_vsn |> String.split(".") |> hd()])
      File.mkdir_p!(release_dir)
      File.write!(Path.join(release_dir, "OTP_VERSION"), otp_vsn <> "\n")
    end

    for {app, vsn} <- Keyword.get(opts, :apps, []) do
      File.mkdir_p!(Path.join([path, "lib", "#{app}-#{vsn}"]))
    end

    path
  end

  test ":not_applicable when no cached tarballs", %{tmp_dir: dir} do
    cache = Path.join(dir, "empty_cache")
    File.mkdir_p!(cache)

    result = run_offline(dir, cache)

    assert result.status == :not_applicable
    assert Enum.any?(result.notes, &String.contains?(&1, "no cached OTP tarballs"))
  end

  test ":ok with no findings when versions match manifest", %{tmp_dir: dir} do
    cache = Path.join(dir, "cache")
    File.mkdir_p!(cache)

    bundle = real_bundle()

    build_tarball(cache, :android, real_hash(),
      openssl: bundle.openssl,
      elixir: bundle.elixir,
      exqlite: bundle.exqlite_beam
    )

    result = run_offline(dir, cache)

    assert result.status == :ok
    assert result.findings == []
    assert Enum.any?(result.notes, &String.contains?(&1, "android"))
  end

  test ":high finding when an Elixir version drifts", %{tmp_dir: dir} do
    cache = Path.join(dir, "cache")
    File.mkdir_p!(cache)

    bundle = real_bundle()

    build_tarball(cache, :android, real_hash(),
      openssl: bundle.openssl,
      elixir: "9.9.9-rc.1",
      exqlite: bundle.exqlite_beam
    )

    result = run_offline(dir, cache)

    assert result.status == :ok

    assert [
             %Finding{
               severity: :high,
               id: "MOB-DRIFT-android-elixir",
               source: :bundled_runtime,
               layer: :bundled_runtime
             } = finding
           ] = result.findings

    assert finding.title =~ "Elixir manifest=#{bundle.elixir}"
    assert finding.title =~ "binary=9.9.9-rc.1"
  end

  test ":high finding when the OTP release drifts from the manifest's otp_version", %{
    tmp_dir: dir
  } do
    cache = Path.join(dir, "cache")
    File.mkdir_p!(cache)

    bundle = real_bundle()

    build_tarball(cache, :android, real_hash(),
      openssl: bundle.openssl,
      elixir: bundle.elixir,
      exqlite: bundle.exqlite_beam,
      otp: "29.0"
    )

    result = run_offline(dir, cache)

    assert [%Finding{severity: :high, id: "MOB-DRIFT-android-otp_version"} = finding] =
             Enum.filter(result.findings, &String.starts_with?(&1.id, "MOB-DRIFT"))

    assert finding.title =~ "OTP manifest=#{bundle.otp_version} binary=29.0"
  end

  test "a cached older bundle that records no otp_version gets no OTP drift finding", %{
    tmp_dir: dir
  } do
    cache = Path.join(dir, "cache")
    File.mkdir_p!(cache)

    {:ok, old} = MobDev.SecurityScan.BundledVersions.for_hash("5c9c69fc")
    refute Map.has_key?(old, :otp_version)

    build_tarball(cache, :android, "5c9c69fc",
      openssl: old.openssl,
      elixir: old.elixir,
      exqlite: old.exqlite_beam,
      otp: "29.0"
    )

    result = run_offline(dir, cache)

    refute Enum.any?(result.findings, &(&1.id =~ "otp_version"))
  end

  test "per-platform override suppresses missing-artifact drift", %{tmp_dir: dir} do
    # iOS sim does NOT ship exqlite per the active manifest. Building a
    # tarball without exqlite should NOT generate a drift finding for it.
    cache = Path.join(dir, "cache")
    File.mkdir_p!(cache)

    bundle = real_bundle()

    build_tarball(cache, :ios_sim, real_hash(),
      openssl: bundle.openssl,
      elixir: bundle.elixir
      # no exqlite — matches per_platform override
    )

    result = run_offline(dir, cache)

    refute Enum.any?(result.findings, &(&1.id == "MOB-DRIFT-ios_sim-exqlite_beam"))
  end

  # MOB-289: the iOS native build installs the project's exqlite into the
  # cached OTP dir, which iOS tarballs don't otherwise ship (manifest nil).
  # That copy is exempt only when it matches the project's mix.lock.
  describe "deploy_installed_exqlite?/3" do
    test "manifest ships none and cache matches the project's lock → exempt" do
      assert BundledRuntime.deploy_installed_exqlite?(nil, "0.41.0", "0.41.0")
    end

    test "cache differs from the project's lock → not exempt" do
      refute BundledRuntime.deploy_installed_exqlite?(nil, "0.40.0", "0.41.0")
    end

    test "project has no exqlite → not exempt" do
      refute BundledRuntime.deploy_installed_exqlite?(nil, "0.41.0", nil)
    end

    test "manifest tracks exqlite for the platform → not exempt even when it matches the lock" do
      refute BundledRuntime.deploy_installed_exqlite?("0.36.0", "0.41.0", "0.41.0")
    end
  end

  defp write_lock(dir, exqlite_vsn) do
    File.write!(
      Path.join(dir, "mix.lock"),
      ~s(%{\n  "exqlite": {:hex, :exqlite, "#{exqlite_vsn}", "abc", [:make], [], "hexpm", "def"},\n}\n)
    )
  end

  defp ios_cache_with_exqlite(dir, exqlite_vsn) do
    cache = Path.join(dir, "cache")
    File.mkdir_p!(cache)
    bundle = real_bundle()

    for platform <- [:ios_sim, :ios_device] do
      build_tarball(cache, platform, real_hash(),
        openssl: bundle.openssl,
        elixir: bundle.elixir,
        exqlite: exqlite_vsn
      )
    end

    cache
  end

  test "iOS exqlite matching the project's lock is reported, not flagged", %{tmp_dir: dir} do
    write_lock(dir, "0.41.0")
    cache = ios_cache_with_exqlite(dir, "0.41.0")

    result = run_offline(dir, cache)

    assert result.findings == []

    for platform <- ["ios_sim", "ios_device"] do
      assert Enum.any?(
               result.notes,
               &(&1 =~ platform and &1 =~ "exqlite 0.41.0 (deploy-installed, not tracked)")
             )
    end
  end

  test "iOS exqlite differing from the project's lock stays HIGH drift", %{tmp_dir: dir} do
    write_lock(dir, "0.41.0")
    cache = ios_cache_with_exqlite(dir, "0.40.0")

    result = run_offline(dir, cache)

    ids = result.findings |> Enum.map(& &1.id) |> Enum.sort()
    assert ids == ["MOB-DRIFT-ios_device-exqlite_beam", "MOB-DRIFT-ios_sim-exqlite_beam"]
    assert Enum.all?(result.findings, &(&1.severity == :high))

    assert Enum.all?(
             result.findings,
             &(&1.title =~ "0.40.0 is not this project's exqlite (project locks 0.41.0)")
           )
  end

  test "iOS exqlite in a project without exqlite stays HIGH drift", %{tmp_dir: dir} do
    cache = ios_cache_with_exqlite(dir, "0.41.0")

    result = run_offline(dir, cache)

    assert [_, _] = result.findings
    assert Enum.all?(result.findings, &(&1.title =~ "project has no exqlite"))
  end

  test "version pointers and SQLite note appear in notes when exqlite present", %{tmp_dir: dir} do
    cache = Path.join(dir, "cache")
    File.mkdir_p!(cache)

    bundle = real_bundle()

    build_tarball(cache, :android, real_hash(),
      openssl: bundle.openssl,
      elixir: bundle.elixir,
      exqlite: bundle.exqlite_beam
    )

    c_src = Path.join([dir, "deps", "exqlite", "c_src"])
    File.mkdir_p!(c_src)
    File.write!(Path.join(c_src, "sqlite3.c"), ~s(#define SQLITE_VERSION "3.51.3"\n))

    result = run_offline(dir, cache)

    assert Enum.any?(result.notes, &String.contains?(&1, "upstream advisories"))
    assert Enum.any?(result.notes, &String.contains?(&1, "SQLite 3.51.3"))
    assert Enum.any?(result.notes, &String.contains?(&1, "openssl-library.org"))
  end

  test "tarball with unknown hash gets an info note, not a finding", %{tmp_dir: dir} do
    cache = Path.join(dir, "cache")
    File.mkdir_p!(cache)

    bundle = real_bundle()

    build_tarball(cache, :android, "deadbe",
      openssl: bundle.openssl,
      elixir: bundle.elixir,
      exqlite: bundle.exqlite_beam
    )

    result = run_offline(dir, cache)

    assert result.findings == []
    assert Enum.any?(result.notes, &String.contains?(&1, "hash not in manifest"))
  end

  describe "upstream advisories" do
    @fixtures Path.expand("../../../fixtures/security_scan", __DIR__)
    @advisory_sources [:otp_security_advisories, :openssl_vulnerabilities, :endoflife_date]

    test "flags OTP and OpenSSL advisories for the active runtime, once across platforms",
         %{tmp_dir: dir} do
      cache = Path.join(dir, "cache")
      runtime_29_0(cache, :android, real_hash())
      runtime_29_0(cache, :ios_sim, real_hash())

      result = run_with_feeds(dir, cache, feed_server())
      by_id = Enum.group_by(result.findings, & &1.id)

      assert [
               %Finding{
                 severity: :critical,
                 package: "otp/ssl",
                 version: "11.7",
                 fixed_in: "11.7.7",
                 layer: :bundled_runtime
               } = psk
             ] = by_id["CVE-2026-89422"]

      assert psk.description =~ "for: android, ios_sim."
      assert [%Finding{severity: :critical, package: "otp/ssl"}] = by_id["CVE-2026-55953"]

      assert [%Finding{severity: :high, package: "openssl", version: "3.4.0"}] =
               by_id["CVE-2026-84782"]

      assert [%Finding{severity: :high, title: "OpenSSL 3.4 reached end of life on 2026-10-22"}] =
               by_id["OPENSSL-EOL-3.4"]

      assert result.status == :ok
      assert "GitHub erlang/otp security advisories" in result.tools_used
      assert "endoflife.date" in result.tools_used

      assert Enum.any?(
               result.notes,
               &(&1 =~ "erlang/otp security advisories apply (fetched just now)")
             )

      assert Enum.any?(result.notes, &(&1 =~ "OpenSSL 3.4: END OF LIFE since 2026-10-22"))
    end

    test "a runtime rebuilt on OTP 29.1.2 / OpenSSL 3.5.9 reports none of them", %{tmp_dir: dir} do
      cache = Path.join(dir, "cache")

      build_tarball(cache, :android, real_hash(),
        openssl: "3.5.9",
        otp: "29.1.2",
        apps: [{"kernel", "11.0"}, {"ssl", "11.7.8"}, {"public_key", "1.21.8"}]
      )

      result = run_with_feeds(dir, cache, feed_server())
      ids = Enum.map(result.findings, & &1.id)

      for id <- ["CVE-2026-89422", "CVE-2026-55953", "CVE-2026-105236", "OPENSSL-EOL-3.4"] do
        refute id in ids
      end

      assert Enum.any?(result.notes, &(&1 =~ "OpenSSL 3.5: supported until 2030-04-08"))
    end

    test "offline with no cached data still runs drift checks and warns", %{tmp_dir: dir} do
      cache = Path.join(dir, "cache")
      runtime_29_0(cache, :android, real_hash())

      result = run_offline(dir, cache)

      assert result.status == :ok
      refute Enum.any?(result.findings, &(&1.source in @advisory_sources))

      assert Enum.any?(
               result.notes,
               &(&1 =~ "⚠ Erlang/OTP 29.0: advisory data unavailable" and
                   &1 =~ "https://github.com/erlang/otp/security/advisories")
             )

      assert Enum.any?(
               result.notes,
               &(&1 =~ "⚠ OpenSSL 3.4.0: advisory data unavailable" and
                   &1 =~ "vulnerabilities-3.4")
             )
    end

    test "offline after a successful scan reuses the cached data, flagged stale",
         %{tmp_dir: dir} do
      cache = Path.join(dir, "cache")
      runtime_29_0(cache, :android, real_hash())
      run_with_feeds(dir, cache, feed_server())

      result = run_offline(dir, cache, advisory_ttl: 0)

      assert Enum.any?(result.findings, &(&1.id == "CVE-2026-89422"))
      assert Enum.any?(result.findings, &(&1.id == "OPENSSL-EOL-3.4"))
      assert Enum.any?(result.notes, &(&1 =~ "⚠ Erlang/OTP 29.0" and &1 =~ "STALE copy"))
    end

    test "cached tarballs of another hash are not matched against advisories", %{tmp_dir: dir} do
      cache = Path.join(dir, "cache")
      runtime_29_0(cache, :android, "deadbe")

      result = run_with_feeds(dir, cache, feed_server())

      refute Enum.any?(result.findings, &(&1.source in @advisory_sources))
      assert Enum.any?(result.notes, &(&1 =~ "active runtime #{real_hash()} is not in the cache"))
    end

    test "a tarball with no OTP application versions under lib/ is called out, not passed",
         %{tmp_dir: dir} do
      cache = Path.join(dir, "cache")

      # Versioned non-OTP dirs (exqlite, a deploy-installed project app) and
      # the top-level erts are there; the OTP apps are not.
      build_tarball(cache, :android, real_hash(),
        openssl: "3.4.0",
        otp: "29.0",
        exqlite: "0.36.0",
        apps: [{"my_app", "0.1.0"}]
      )

      result = run_with_feeds(dir, cache, feed_server())

      refute Enum.any?(result.findings, &(&1.source == :otp_security_advisories))

      assert Enum.any?(
               result.notes,
               &(&1 =~ "⚠ android (#{real_hash()}): no OTP application versions found under" and
                   &1 =~ "OTP advisories not checked")
             )

      refute Enum.any?(result.notes, &(&1 =~ "erlang/otp security advisories apply"))
      # OpenSSL is still checked.
      assert Enum.any?(result.findings, &(&1.id == "OPENSSL-EOL-3.4"))
    end
  end

  describe "SQLite CVEs" do
    @sqlite_ids_after_3_45 ~w(CVE-2025-29087 CVE-2025-29088 CVE-2025-3277 CVE-2025-52099
                              CVE-2025-6965 CVE-2025-70873 CVE-2025-7709 CVE-2026-11822
                              CVE-2026-11824)

    defp write_sqlite(dir, version) do
      c_src = Path.join([dir, "deps", "exqlite", "c_src"])
      File.mkdir_p!(c_src)

      File.write!(
        Path.join(c_src, "sqlite3.c"),
        ~s(/* amalgamation */\n#define SQLITE_VERSION        "#{version}"\n)
      )
    end

    defp sqlite_ids(result) do
      for %Finding{source: :sqlite_cves, id: id} <- result.findings, do: id
    end

    test "exqlite 0.37.0's SQLite 3.53.2 has no CVEs, even with no tarball cache",
         %{tmp_dir: dir} do
      write_sqlite(dir, "3.53.2")
      cache = Path.join(dir, "empty_cache")
      File.mkdir_p!(cache)

      result = run_with_feeds(dir, cache, feed_server())

      assert result.status == :ok
      assert sqlite_ids(result) == []
      assert "sqlite.org CVE table" in result.tools_used

      assert Enum.any?(
               result.notes,
               &(&1 =~ "SQLite 3.53.2 (deps/exqlite/c_src/sqlite3.c): 0 of 13 fixed CVEs on " and
                   &1 =~ "(fetched just now)")
             )
    end

    test "an older SQLite reports each CVE fixed after it, beside the runtime findings",
         %{tmp_dir: dir} do
      write_sqlite(dir, "3.45.0")
      cache = Path.join(dir, "cache")
      runtime_29_0(cache, :android, real_hash())

      result = run_with_feeds(dir, cache, feed_server())

      assert Enum.sort(sqlite_ids(result)) == @sqlite_ids_after_3_45
      assert Enum.any?(result.findings, &(&1.id == "OPENSSL-EOL-3.4"))

      assert %Finding{severity: :medium, package: "sqlite", version: "3.45.0", fixed_in: "3.52.0"} =
               Enum.find(result.findings, &(&1.id == "CVE-2025-70873"))

      assert Enum.any?(result.notes, &(&1 =~ "SQLite 3.45.0" and &1 =~ "9 of 13 fixed CVEs"))
    end

    test "offline without a cached page still completes and warns", %{tmp_dir: dir} do
      write_sqlite(dir, "3.45.0")
      cache = Path.join(dir, "empty_cache")
      File.mkdir_p!(cache)

      result = run_offline(dir, cache)

      assert result.status == :ok
      assert sqlite_ids(result) == []

      assert Enum.any?(
               result.notes,
               &(&1 =~ "⚠ SQLite 3.45.0 (deps/exqlite/c_src/sqlite3.c): advisory data unavailable" and
                   &1 =~ "https://www.sqlite.org/cves.html")
             )
    end

    test "offline after a successful scan reuses the cached page, flagged stale",
         %{tmp_dir: dir} do
      write_sqlite(dir, "3.45.0")
      cache = Path.join(dir, "empty_cache")
      File.mkdir_p!(cache)
      run_with_feeds(dir, cache, feed_server())

      result = run_offline(dir, cache, advisory_ttl: 0)

      assert Enum.sort(sqlite_ids(result)) == @sqlite_ids_after_3_45
      assert Enum.any?(result.notes, &(&1 =~ "⚠ SQLite 3.45.0" and &1 =~ "STALE copy"))
    end
  end

  # The 5c9c69fc runtime as cached: OTP 29.0, ssl 11.7, OpenSSL 3.4.0.
  defp runtime_29_0(cache, platform, hash) do
    build_tarball(cache, platform, hash,
      openssl: "3.4.0",
      otp: "29.0",
      apps: [{"kernel", "11.0"}, {"stdlib", "8.0"}, {"ssl", "11.7"}, {"public_key", "1.21"}]
    )
  end

  # Serves the real feed snapshots in test/fixtures by URL, as the network would.
  defp feed_server do
    otp = File.read!(Path.join(@fixtures, "otp_security_advisories.json"))
    openssl = File.read!(Path.join(@fixtures, "openssl_vulnerabilities_3.4.html"))
    eol = File.read!(Path.join(@fixtures, "endoflife_openssl.json"))
    sqlite = File.read!(Path.join(@fixtures, "sqlite_cves.html"))

    fn
      "https://api.github.com/repos/erlang/otp/" <> _, _ ->
        {:ok, 200, [], otp}

      "https://openssl-library.org/news/vulnerabilities-3.4/index.html", _ ->
        {:ok, 200, [], openssl}

      "https://endoflife.date/api/openssl.json", _ ->
        {:ok, 200, [], eol}

      "https://www.sqlite.org/cves.html", _ ->
        {:ok, 200, [], sqlite}

      _url, _ ->
        {:ok, 404, [], "Not Found"}
    end
  end

  defp run_offline(dir, cache, extra \\ []) do
    run_with_feeds(dir, cache, fn _url, _headers -> {:error, :nxdomain} end, extra)
  end

  defp run_with_feeds(dir, cache, http_get, extra \\ []) do
    BundledRuntime.run(
      [
        project_root: dir,
        cache_dir: cache,
        advisory_cache_dir: Path.join(dir, "advisories"),
        advisory_http_get: http_get,
        github_token: nil,
        today: ~D[2026-10-22]
      ] ++ extra
    )
  end

  defp real_bundle, do: MobDev.SecurityScan.BundledVersions.active()

  defp real_hash, do: MobDev.SecurityScan.BundledVersions.load().active_hash
end
