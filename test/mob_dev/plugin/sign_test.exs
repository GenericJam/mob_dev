defmodule MobDev.Plugin.SignTest do
  use ExUnit.Case, async: true

  alias MobDev.Plugin.{Crypto, Manifest, Sign, Verify}

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

    test "returns [] for a manifest with no referenced files", %{dir: dir} do
      manifest = %{name: :mob_x, mob_version: "~> 0.6", plugin_spec_version: 1}
      assert Sign.compute_file_hashes(dir, manifest) == []
    end

    test "hashes ios.swift_files and android paths, sorted by path", %{dir: dir} do
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

      hashes = Sign.compute_file_hashes(dir, manifest)
      paths = Enum.map(hashes, &elem(&1, 0))
      assert paths == Enum.sort(paths)

      assert paths == [
               "android/Bridge.kt",
               "android/jni/Plugin.cpp",
               "ios/A.swift",
               "ios/B.swift"
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

      assert Sign.compute_file_hashes(dir, m1) == Sign.compute_file_hashes(dir, m2)
    end

    test "recursively hashes native sources and headers inside nifs.native_dir", %{dir: dir} do
      write_file(dir, "priv/native/n.c", "c source")
      write_file(dir, "priv/native/nested/n.h", "header")
      write_file(dir, "priv/native/nested/n.m", "objective-c source")
      write_file(dir, "priv/native/nested/n.mm", "objective-c++ source")
      write_file(dir, "priv/native/skip.txt", "should be skipped")
      write_file(dir, "priv/native/build.zig", "zig source")

      manifest = %{
        name: :mob_x,
        mob_version: "~> 0.6",
        plugin_spec_version: 1,
        nifs: [%{module: :mob_x_nif, native_dir: "priv/native"}]
      }

      paths = manifest |> (&Sign.compute_file_hashes(dir, &1)).() |> Enum.map(&elem(&1, 0))
      assert "priv/native/n.c" in paths
      assert "priv/native/nested/n.h" in paths
      assert "priv/native/nested/n.m" in paths
      assert "priv/native/nested/n.mm" in paths
      assert "priv/native/build.zig" in paths
      refute "priv/native/skip.txt" in paths
    end

    test "uses the frozen legacy native extension set for v1 and expanded set for v2", %{
      dir: dir
    } do
      write_file(dir, "priv/native/n.c", "c source")
      write_file(dir, "priv/native/n.m", "objective-c source")
      write_file(dir, "priv/native/n.mm", "objective-c++ source")

      manifest = %{
        name: :mob_x,
        mob_version: "~> 0.6",
        plugin_spec_version: 1,
        nifs: [%{module: :mob_x_nif, native_dir: "priv/native"}]
      }

      v1_paths =
        dir
        |> Sign.compute_file_hashes(manifest, 1)
        |> Enum.map(&elem(&1, 0))

      v2_paths =
        dir
        |> Sign.compute_file_hashes(manifest, 2)
        |> Enum.map(&elem(&1, 0))

      assert v1_paths == ["priv/native/n.c"]
      assert v2_paths == ["priv/native/n.c", "priv/native/n.m", "priv/native/n.mm"]
    end

    test "different file contents produce different hashes", %{dir: dir} do
      write_file(dir, "ios/A.swift", "version 1")

      manifest = %{
        name: :mob_x,
        mob_version: "~> 0.6",
        plugin_spec_version: 1,
        ios: %{swift_files: ["ios/A.swift"]}
      }

      [{_, h1}] = Sign.compute_file_hashes(dir, manifest)

      write_file(dir, "ios/A.swift", "version 2")
      [{_, h2}] = Sign.compute_file_hashes(dir, manifest)

      assert h1 != h2
    end
  end

  describe "build_payload/2" do
    test "defaults to the current v2 payload" do
      payload = Sign.build_payload(%{name: :mob_x}, [{"a", <<1, 2, 3>>}])
      assert payload.manifest == %{name: :mob_x}
      assert payload.file_hashes == [{"a", <<1, 2, 3>>}]
      assert payload.envelope_version == 2
    end

    test "can reconstruct the exact legacy v1 payload" do
      payload = Sign.build_payload(%{name: :mob_x}, [{"a", <<1, 2, 3>>}], 1)

      assert payload == %{
               manifest: %{name: :mob_x},
               file_hashes: [{"a", <<1, 2, 3>>}],
               envelope_version: 1
             }
    end
  end

  describe "sign_plugin/2" do
    test "writes priv/mob_plugin.sig that Verify.verify_plugin accepts", %{dir: dir} do
      manifest = %{name: :mob_demo, mob_version: "~> 0.6", plugin_spec_version: 1}
      write_manifest(dir, manifest)

      {priv, pub} = Crypto.generate_keypair()
      File.write!(Path.join(dir, "priv/mob_plugin.pub"), Base.encode64(pub) <> "\n")

      assert :ok = Sign.sign_plugin(dir, priv)
      assert File.exists?(Sign.signature_path(dir))

      {:ok, loaded_manifest} = Manifest.load(dir)
      assert :ok = Verify.verify_plugin(dir, loaded_manifest)
      assert {:ok, 2} = Verify.verify_plugin_with_version(dir, loaded_manifest)

      raw_envelope = dir |> Sign.signature_path() |> File.read!()

      assert %{signature: signature, envelope_version: 2} =
               envelope =
               :erlang.binary_to_term(raw_envelope, [:safe])

      assert byte_size(signature) == 64
      assert envelope == %{signature: signature, envelope_version: 2}
      assert raw_envelope == Crypto.canonical_encode(envelope)
      assert Sign.envelope_version() == 2
    end

    test "errors when no manifest is present", %{dir: dir} do
      {priv, _pub} = Crypto.generate_keypair()
      assert {:error, _} = Sign.sign_plugin(dir, priv)
    end

    for extension <- [".m", ".mm"] do
      @extension extension

      test "rejects tampering a signed Objective-C source with extension #{extension}", %{
        dir: dir
      } do
        extension = @extension
        plugin_dir = Path.join(dir, String.trim_leading(extension, "."))
        source = "priv/native/ios/mob_demo_nif#{extension}"
        write_file(plugin_dir, source, "native source")

        manifest = %{
          name: :mob_demo,
          mob_version: "~> 0.6",
          plugin_spec_version: 1,
          nifs: [%{module: :mob_demo_nif, native_dir: "priv/native/ios", lang: :objc}]
        }

        write_manifest(plugin_dir, manifest)
        {priv, pub} = Crypto.generate_keypair()
        File.write!(Path.join(plugin_dir, "priv/mob_plugin.pub"), Base.encode64(pub) <> "\n")

        assert :ok = Sign.sign_plugin(plugin_dir, priv)
        assert {:ok, loaded_manifest} = Manifest.load(plugin_dir)
        assert :ok = Verify.verify_plugin(plugin_dir, loaded_manifest)

        File.write!(Path.join(plugin_dir, source), "tampered native source")

        assert {:error, :invalid_signature} = Verify.verify_plugin(plugin_dir, loaded_manifest)
      end
    end
  end
end
