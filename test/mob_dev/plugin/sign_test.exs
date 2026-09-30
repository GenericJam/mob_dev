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

    test "lists the manifest and the coverage marker for a manifest with no other inputs",
         %{dir: dir} do
      # After MOB-74 the manifest bytes themselves are always in the signed
      # file_hashes list — even a manifest that declares no sources still
      # has ONE hashed input (itself). Revert-verify: drop @manifest_file
      # from `Sign.build_inputs/2` and this fails.
      manifest = %{name: :mob_x, mob_version: "~> 0.6", plugin_spec_version: 1}
      write_manifest(dir, manifest)
      assert Sign.build_inputs(dir, manifest) == ["priv/mob_plugin.exs"]

      hashes = Sign.compute_file_hashes(dir, manifest)
      assert List.keymember?(hashes, "priv/mob_plugin.exs", 0)
      assert Sign.declares_build_input_coverage?(hashes)
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
      paths = Sign.build_inputs(dir, manifest)
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

    test "hashes every file under a NIF's native_dir, whatever its extension", %{dir: dir} do
      # MOB-297: the old rule kept only .c/.h/.cpp/.zig, so an iOS ObjC NIF's
      # .m (and any .mm/.hpp/.inc it includes) was never signed.
      write_file(dir, "priv/native/ios/mob_x_nif.m", "objc source")
      write_file(dir, "priv/native/ios/bridge.mm", "objc++")
      write_file(dir, "priv/native/ios/nested/util.hpp", "header")
      write_file(dir, "priv/native/ios/table.inc", "data")
      write_file(dir, "priv/native/ios/.DS_Store", "finder litter")

      manifest = %{
        name: :mob_x,
        mob_version: "~> 0.6",
        plugin_spec_version: 1,
        nifs: [%{module: :mob_x_nif, native_dir: "priv/native/ios", lang: :objc}]
      }

      write_manifest(dir, manifest)

      assert Sign.build_inputs(dir, manifest) == [
               "priv/mob_plugin.exs",
               "priv/native/ios/bridge.mm",
               "priv/native/ios/mob_x_nif.m",
               "priv/native/ios/nested/util.hpp",
               "priv/native/ios/table.inc"
             ]
    end

    test "applies the default native_dir to a NIF that declares none", %{dir: dir} do
      write_file(dir, "priv/native/jni/mob_x_nif.zig", "zig source")

      manifest = %{
        name: :mob_x,
        mob_version: "~> 0.6",
        plugin_spec_version: 1,
        nifs: [%{module: :mob_x_nif, lang: :zig}]
      }

      write_manifest(dir, manifest)
      assert "priv/native/jni/mob_x_nif.zig" in Sign.build_inputs(dir, manifest)
    end

    test "covers cpp_archive sources and their directory trees, not {:dep, …} or include roots",
         %{dir: dir} do
      write_file(dir, "c_src/nif.cpp", "cpp")
      write_file(dir, "c_src/fft.hpp", "hpp")
      write_file(dir, "c_src/detail/impl.inl", "inl")
      # Host-provisioned include root (mob_nx_eigen downloads Eigen here at
      # compile time): not shipped, so not signable.
      write_file(dir, "eigen-3.4.0/Eigen/Core", "eigen")

      manifest = %{
        name: :mob_x,
        mob_version: "~> 0.6",
        plugin_spec_version: 1,
        nifs: [
          %{
            module: :mob_x_nif,
            lang: :cpp_archive,
            nm_symbol: "mob_x_nif_nif_init",
            sources: ["c_src/nif.cpp", {:dep, :nx_eigen, "c_src/nx_eigen.cpp"}],
            includes: ["eigen-3.4.0", {:dep, :eigen, "include"}]
          }
        ]
      }

      write_manifest(dir, manifest)

      assert Sign.build_inputs(dir, manifest) == [
               "c_src/detail/impl.inl",
               "c_src/fft.hpp",
               "c_src/nif.cpp",
               "priv/mob_plugin.exs"
             ]
    end

    test "expands directories literally when the plugin path contains glob characters" do
      # `mix mob.plugin.sign` passes the absolute cwd; a `[` or `{` in it must
      # not be read as a pattern, or the signer lists no headers while every
      # host lists them all.
      dir = Path.join(System.tmp_dir!(), "mob_sign [wip]{#{System.unique_integer([:positive])}}")
      on_exit(fn -> File.rm_rf!(dir) end)
      write_file(dir, "priv/native/jni/mob_x_nif.c", "c")
      write_file(dir, "priv/native/jni/util.h", "h")
      write_file(dir, "priv/migrations/1_create.exs", "migration")

      manifest = %{
        name: :mob_x,
        mob_version: "~> 0.6",
        plugin_spec_version: 1,
        nifs: [%{module: :mob_x_nif}],
        migrations: %{migrations_dir: "priv/migrations", repo_namespace: :mob_x}
      }

      write_manifest(dir, manifest)

      assert Sign.build_inputs(dir, manifest) == [
               "priv/migrations/1_create.exs",
               "priv/mob_plugin.exs",
               "priv/native/jni/mob_x_nif.c",
               "priv/native/jni/util.h"
             ]
    end

    test "covers plugin migrations, fonts and images the build copies", %{dir: dir} do
      write_file(dir, "priv/migrations/20260101_create.exs", "migration")
      write_file(dir, "priv/migrations/README.md", "not copied")
      write_file(dir, "priv/fonts/Inter.ttf", "font")
      write_file(dir, "priv/images/logo.png", "png")

      manifest = %{
        name: :mob_x,
        mob_version: "~> 0.6",
        plugin_spec_version: 1,
        migrations: %{migrations_dir: "priv/migrations", repo_namespace: :mob_x},
        assets: %{fonts: ["priv/fonts/Inter.ttf"], images: ["priv/images/logo.png"]},
        default_font: %{family: "Inter", file: "priv/fonts/Inter.ttf"}
      }

      write_manifest(dir, manifest)

      assert Sign.build_inputs(dir, manifest) == [
               "priv/fonts/Inter.ttf",
               "priv/images/logo.png",
               "priv/migrations/20260101_create.exs",
               "priv/mob_plugin.exs"
             ]
    end

    test "never lists priv/mob_plugin.sig, even when a NIF's native_dir is priv/",
         %{dir: dir} do
      # Hashing the signature into itself would make every signature stale
      # the moment it is written.
      write_file(dir, "priv/mob_x_nif.c", "c")

      manifest = %{
        name: :mob_x,
        mob_version: "~> 0.6",
        plugin_spec_version: 1,
        nifs: [%{module: :mob_x_nif, native_dir: "priv"}]
      }

      write_manifest(dir, manifest)
      {priv, pub} = Crypto.generate_keypair()
      File.write!(Path.join(dir, "priv/mob_plugin.pub"), Base.encode64(pub) <> "\n")
      :ok = Sign.sign_plugin(dir, priv)

      refute "priv/mob_plugin.sig" in Sign.build_inputs(dir, manifest)
      assert :ok = Verify.verify_plugin(dir)
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

      {_, hash_a} =
        List.keyfind(Sign.compute_file_hashes(dir, manifest), "priv/mob_plugin.exs", 0)

      File.write!(Path.join(dir, "priv/mob_plugin.exs"), "# tampered\n" <> inspect(manifest))

      {_, hash_b} =
        List.keyfind(Sign.compute_file_hashes(dir, manifest), "priv/mob_plugin.exs", 0)

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
