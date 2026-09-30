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

    path
  end

  test ":not_applicable when no cached tarballs", %{tmp_dir: dir} do
    cache = Path.join(dir, "empty_cache")
    File.mkdir_p!(cache)

    result = BundledRuntime.run(project_root: dir, cache_dir: cache)

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

    result = BundledRuntime.run(project_root: dir, cache_dir: cache)

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

    result = BundledRuntime.run(project_root: dir, cache_dir: cache)

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

    result = BundledRuntime.run(project_root: dir, cache_dir: cache)

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

    result = BundledRuntime.run(project_root: dir, cache_dir: cache)

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

    result = BundledRuntime.run(project_root: dir, cache_dir: cache)

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

    result = BundledRuntime.run(project_root: dir, cache_dir: cache)

    assert length(result.findings) == 2
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

    result = BundledRuntime.run(project_root: dir, cache_dir: cache)

    assert Enum.any?(result.notes, &String.contains?(&1, "version pointers"))
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

    result = BundledRuntime.run(project_root: dir, cache_dir: cache)

    assert result.findings == []
    assert Enum.any?(result.notes, &String.contains?(&1, "hash not in manifest"))
  end

  defp real_bundle, do: MobDev.SecurityScan.BundledVersions.active()

  defp real_hash, do: MobDev.SecurityScan.BundledVersions.load().active_hash
end
