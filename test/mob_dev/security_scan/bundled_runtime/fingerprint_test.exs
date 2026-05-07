defmodule MobDev.SecurityScan.BundledRuntime.FingerprintTest do
  use ExUnit.Case, async: true

  alias MobDev.SecurityScan.BundledRuntime.Fingerprint

  @moduletag :tmp_dir

  defp build_tarball(dir, opts) do
    erts_vsn = Keyword.get(opts, :erts, "16.3")
    elixir_vsn = Keyword.get(opts, :elixir, "1.19.5")
    openssl_vsn = Keyword.get(opts, :openssl, "3.4.0")
    exqlite_vsn = Keyword.get(opts, :exqlite, "0.36.0")

    erts = Path.join(dir, "erts-#{erts_vsn}")
    erts_lib = Path.join(erts, "lib")
    File.mkdir_p!(erts_lib)

    if openssl_vsn do
      libcrypto_content =
        :crypto.strong_rand_bytes(1024) <>
          "Some unrelated string\0" <>
          "OpenSSL default\0" <>
          "OpenSSL #{openssl_vsn} 22 Oct 2024\0" <>
          :crypto.strong_rand_bytes(1024)

      File.write!(Path.join(erts_lib, "libcrypto.a"), libcrypto_content)
    end

    if elixir_vsn do
      ebin = Path.join([dir, "lib", "elixir", "ebin"])
      File.mkdir_p!(ebin)
      File.write!(Path.join(ebin, "elixir.app"), ~s({application,elixir,[{vsn,"#{elixir_vsn}"}]}))
    end

    if exqlite_vsn do
      File.mkdir_p!(Path.join([dir, "lib", "exqlite-#{exqlite_vsn}", "ebin"]))
    end

    dir
  end

  describe "locate_cached_tarballs/1" do
    test "decodes android, android_arm32, ios_sim, ios_device dirs", %{tmp_dir: dir} do
      for name <- [
            "otp-android-abc123",
            "otp-android-arm32-abc123",
            "otp-ios-sim-abc123",
            "otp-ios-device-abc123",
            "otp-something-else-zzz",
            "not-a-tarball"
          ] do
        File.mkdir_p!(Path.join(dir, name))
      end

      tarballs = Fingerprint.locate_cached_tarballs(cache_dir: dir)

      platforms = Enum.map(tarballs, & &1.platform) |> Enum.sort()
      assert platforms == [:android, :android_arm32, :ios_device, :ios_sim]
      assert Enum.all?(tarballs, &(&1.hash == "abc123"))
    end

    test "returns [] when cache dir missing", %{tmp_dir: dir} do
      missing = Path.join(dir, "nope")
      assert Fingerprint.locate_cached_tarballs(cache_dir: missing) == []
    end

    test "ignores non-directory entries", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "otp-android-abc"), "not a dir")
      assert Fingerprint.locate_cached_tarballs(cache_dir: dir) == []
    end
  end

  describe "fingerprint_tarball/1" do
    test "extracts every version field from a well-formed tarball", %{tmp_dir: dir} do
      build_tarball(dir, [])

      versions = Fingerprint.fingerprint_tarball(dir)

      assert versions.erts == "16.3"
      assert versions.elixir == "1.19.5"
      assert versions.openssl == "3.4.0"
      assert versions.exqlite_beam == "0.36.0"
    end

    test "returns nil for fields whose source files are missing", %{tmp_dir: dir} do
      build_tarball(dir, openssl: nil, elixir: nil, exqlite: nil)
      versions = Fingerprint.fingerprint_tarball(dir)

      assert versions.erts == "16.3"
      assert versions.elixir == nil
      assert versions.openssl == nil
      assert versions.exqlite_beam == nil
    end

    test "OpenSSL: ignores non-version 'OpenSSL ' strings and finds the digit-form one",
         %{tmp_dir: dir} do
      build_tarball(dir, openssl: "3.5.1")
      assert %{openssl: "3.5.1"} = Fingerprint.fingerprint_tarball(dir)
    end

    test "OpenSSL: returns nil when no version banner exists in libcrypto.a", %{tmp_dir: dir} do
      build_tarball(dir, openssl: nil)

      erts_lib = Path.join([dir, "erts-16.3", "lib"])
      File.mkdir_p!(erts_lib)
      File.write!(Path.join(erts_lib, "libcrypto.a"), "OpenSSL default only, no version\0")

      assert %{openssl: nil} = Fingerprint.fingerprint_tarball(dir)
    end
  end

  describe "fingerprint_sqlite/1" do
    test "extracts SQLITE_VERSION from a project's deps/exqlite/c_src/sqlite3.c",
         %{tmp_dir: dir} do
      c_src = Path.join([dir, "deps", "exqlite", "c_src"])
      File.mkdir_p!(c_src)

      File.write!(Path.join(c_src, "sqlite3.c"), """
      /* synthetic SQLite source */
      #define SQLITE_VERSION        "3.51.3"
      #define SQLITE_SOURCE_ID      "2026-03-13 some hash"
      """)

      assert {:ok, "3.51.3"} = Fingerprint.fingerprint_sqlite(dir)
    end

    test "{:error, :not_found} when exqlite source is absent", %{tmp_dir: dir} do
      assert {:error, :not_found} = Fingerprint.fingerprint_sqlite(dir)
    end

    test "{:error, :unparseable} when file exists but has no version macro",
         %{tmp_dir: dir} do
      c_src = Path.join([dir, "deps", "exqlite", "c_src"])
      File.mkdir_p!(c_src)
      File.write!(Path.join(c_src, "sqlite3.c"), "/* no version macro here */\n")

      assert {:error, :unparseable} = Fingerprint.fingerprint_sqlite(dir)
    end
  end
end
