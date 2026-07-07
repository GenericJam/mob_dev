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

      [{_, h1}] = Sign.compute_file_hashes(dir, manifest)

      write_file(dir, "ios/A.swift", "version 2")
      [{_, h2}] = Sign.compute_file_hashes(dir, manifest)

      assert h1 != h2
    end
  end

  describe "build_payload/2" do
    test "wraps manifest + file_hashes in envelope_version: 1" do
      payload = Sign.build_payload(%{name: :mob_x}, [{"a", <<1, 2, 3>>}])
      assert payload.manifest == %{name: :mob_x}
      assert payload.file_hashes == [{"a", <<1, 2, 3>>}]
      assert payload.envelope_version == 1
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
    end

    test "errors when no manifest is present", %{dir: dir} do
      {priv, _pub} = Crypto.generate_keypair()
      assert {:error, _} = Sign.sign_plugin(dir, priv)
    end
  end
end
