defmodule MobDev.Plugin.SignTest do
  use ExUnit.Case, async: true

  alias MobDev.Plugin.{Crypto, Sign, Verify}

  setup do
    dir =
      Path.join(System.tmp_dir!(), "mob_sign_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(dir, "priv"))
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp write_manifest(dir, manifest) do
    File.write!(Path.join(dir, "priv/mob_plugin.exs"), inspect(manifest, limit: :infinity))
  end

  defp write_file(dir, rel, contents) do
    path = Path.join(dir, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    path
  end

  describe "compute_file_hashes/2" do
    test "returns [] for nil manifest", %{dir: dir} do
      assert Sign.compute_file_hashes(dir, nil) == []
    end

    test "returns [priv/mob_plugin.exs] for a manifest with no other referenced files",
         %{dir: dir} do
      # After MOB-74 the manifest bytes themselves are always in the signed
      # file_hashes list — even a manifest that declares no sources still
      # has ONE hashed file (itself). Revert-verify: remove the
      # @manifest_file prefix in `Sign.referenced_files/2` and this fails.
      manifest = %{name: :mob_x, mob_version: "~> 0.6", plugin_spec_version: 1}
      write_manifest(dir, manifest)
      hashes = Sign.compute_file_hashes(dir, manifest)
      assert Enum.map(hashes, &elem(&1, 0)) == ["priv/mob_plugin.exs"]
    end

    test "hashes ios.swift_files and android paths, sorted by path, plus the manifest",
         %{dir: dir} do
      write_file(dir, "ios/A.swift", "a contents")
      write_file(dir, "ios/B.swift", "b contents")
      write_file(dir, "android/Bridge.kt", "kt contents")
      write_file(dir, "android/jni/Plugin.cpp", "cpp contents")

      manifest = %{
        name: :mob_x,
        mob_version: "~> 0.6",
        plugin_spec_version: 1,
        ios: %{swift_files: ["ios/B.swift", "ios/A.swift"]},
        android: %{bridge_kt: "android/Bridge.kt", jni_source: "android/jni/Plugin.cpp"}
      }

      write_manifest(dir, manifest)
      hashes = Sign.compute_file_hashes(dir, manifest)
      paths = Enum.map(hashes, &elem(&1, 0))
      assert paths == Enum.sort(paths)

      assert paths == [
               "android/Bridge.kt",
               "android/jni/Plugin.cpp",
               "ios/A.swift",
               "ios/B.swift",
               "priv/mob_plugin.exs"
             ]
    end

    test "hashes android.res_files so copied resource bytes are signed", %{dir: dir} do
      write_file(dir, "android/res/xml/svc.xml", "<host-apdu-service/>")
      write_file(dir, "android/res/values/strings.xml", "<resources/>")

      manifest = %{
        name: :mob_x,
        mob_version: "~> 0.6",
        plugin_spec_version: 1,
        android: %{
          res_files: ["android/res/xml/svc.xml", "android/res/values/strings.xml"]
        }
      }

      write_manifest(dir, manifest)
      paths = Sign.compute_file_hashes(dir, manifest) |> Enum.map(&elem(&1, 0))
      assert "android/res/xml/svc.xml" in paths
      assert "android/res/values/strings.xml" in paths
    end

    test "is independent of the order swift_files appear in the manifest", %{dir: dir} do
      write_file(dir, "ios/A.swift", "alpha")
      write_file(dir, "ios/B.swift", "beta")

      m1 = %{
        name: :mob_x,
        mob_version: "~> 0.6",
        plugin_spec_version: 1,
        ios: %{swift_files: ["ios/A.swift", "ios/B.swift"]}
      }

      m2 = put_in(m1, [:ios, :swift_files], ["ios/B.swift", "ios/A.swift"])

      # Same manifest bytes on disk (only the map arg differs), so the manifest
      # hash contribution is identical for both calls.
      write_manifest(dir, m1)
      assert Sign.compute_file_hashes(dir, m1) == Sign.compute_file_hashes(dir, m2)
    end

    test "recursively hashes .c/.h/.cpp/.zig files inside nifs.native_dir", %{dir: dir} do
      write_file(dir, "priv/native/n.c", "c source")
      write_file(dir, "priv/native/nested/n.h", "header")
      write_file(dir, "priv/native/skip.txt", "should be skipped")
      write_file(dir, "priv/native/build.zig", "zig source")

      manifest = %{
        name: :mob_x,
        mob_version: "~> 0.6",
        plugin_spec_version: 1,
        nifs: [%{module: :mob_x_nif, native_dir: "priv/native"}]
      }

      write_manifest(dir, manifest)
      paths = manifest |> (&Sign.compute_file_hashes(dir, &1)).() |> Enum.map(&elem(&1, 0))
      assert "priv/native/n.c" in paths
      assert "priv/native/nested/n.h" in paths
      assert "priv/native/build.zig" in paths
      refute "priv/native/skip.txt" in paths
    end

    test "different file contents produce different hashes", %{dir: dir} do
      write_file(dir, "ios/A.swift", "version 1")

      manifest = %{
        name: :mob_x,
        mob_version: "~> 0.6",
        plugin_spec_version: 1,
        ios: %{swift_files: ["ios/A.swift"]}
      }

      write_manifest(dir, manifest)
      hashes_v1 = Sign.compute_file_hashes(dir, manifest)
      [{_, h1}] = Enum.filter(hashes_v1, &(elem(&1, 0) == "ios/A.swift"))

      write_file(dir, "ios/A.swift", "version 2")
      hashes_v2 = Sign.compute_file_hashes(dir, manifest)
      [{_, h2}] = Enum.filter(hashes_v2, &(elem(&1, 0) == "ios/A.swift"))

      assert h1 != h2
    end

    test "different manifest bytes produce different hashes for priv/mob_plugin.exs",
         %{dir: dir} do
      # The MOB-74 fix: the manifest bytes are covered by the signed
      # file_hashes, so changing a comment or reordering keys in
      # `priv/mob_plugin.exs` shifts the hash and breaks verification
      # (that's the tamper-detection guarantee).
      manifest = %{name: :mob_x, mob_version: "~> 0.6", plugin_spec_version: 1}

      File.write!(Path.join(dir, "priv/mob_plugin.exs"), "# original\n" <> inspect(manifest))
      [{_, hash_a}] = Sign.compute_file_hashes(dir, manifest)

      File.write!(Path.join(dir, "priv/mob_plugin.exs"), "# tampered\n" <> inspect(manifest))
      [{_, hash_b}] = Sign.compute_file_hashes(dir, manifest)

      assert hash_a != hash_b
    end
  end

  describe "build_payload/1" do
    test "wraps file_hashes in envelope_version: 2 (no manifest field)" do
      payload = Sign.build_payload([{"a", <<1, 2, 3>>}])
      assert payload.file_hashes == [{"a", <<1, 2, 3>>}]
      assert payload.envelope_version == 2

      # MOB-74: v2 payload no longer includes the eval'd manifest map.
      # Its bytes are covered indirectly via the file_hashes entry for
      # `priv/mob_plugin.exs`, and dropping the map lets `Verify` rebuild
      # the payload without eval'ing the manifest first.
      refute Map.has_key?(payload, :manifest)
    end
  end

  describe "sign_plugin/2" do
    test "writes a v2 priv/mob_plugin.sig that Verify.verify_plugin/1 accepts",
         %{dir: dir} do
      manifest = %{name: :mob_demo, mob_version: "~> 0.6", plugin_spec_version: 1}
      write_manifest(dir, manifest)

      {priv, pub} = Crypto.generate_keypair()
      File.write!(Path.join(dir, "priv/mob_plugin.pub"), Base.encode64(pub) <> "\n")

      assert :ok = Sign.sign_plugin(dir, priv)
      assert File.exists?(Sign.signature_path(dir))

      # Verify never touches the manifest map — it works purely off the
      # envelope's embedded file_hashes list and the on-disk file bytes.
      # See MOB-74.
      assert :ok = Verify.verify_plugin(dir)
    end

    test "the on-disk envelope carries signature, file_hashes, and envelope_version: 2",
         %{dir: dir} do
      # Structural regression guard: earlier the envelope carried only the
      # signature, so verify needed the eval'd manifest to rebuild the
      # payload. If someone tries to shrink the envelope back, verify goes
      # back to eval-before-verify and MOB-74 reopens.
      manifest = %{name: :mob_demo, mob_version: "~> 0.6", plugin_spec_version: 1}
      write_manifest(dir, manifest)

      {priv, pub} = Crypto.generate_keypair()
      File.write!(Path.join(dir, "priv/mob_plugin.pub"), Base.encode64(pub) <> "\n")

      :ok = Sign.sign_plugin(dir, priv)

      raw = File.read!(Sign.signature_path(dir))
      envelope = :erlang.binary_to_term(raw, [:safe])

      assert envelope.envelope_version == 2
      assert is_binary(envelope.signature) and byte_size(envelope.signature) == 64

      paths = Enum.map(envelope.file_hashes, &elem(&1, 0))
      assert "priv/mob_plugin.exs" in paths
    end

    test "errors when no manifest is present", %{dir: dir} do
      {priv, _pub} = Crypto.generate_keypair()
      assert {:error, _} = Sign.sign_plugin(dir, priv)
    end
  end
end
