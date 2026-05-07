defmodule MobDev.SecurityScan.BundledVersionsTest do
  use ExUnit.Case, async: true

  alias MobDev.SecurityScan.BundledVersions

  describe "load/0 (real manifest)" do
    test "loads without raising" do
      assert %{active_hash: hash, bundles: bundles} = BundledVersions.load()
      assert is_binary(hash) and byte_size(hash) > 0
      assert is_map(bundles) and map_size(bundles) > 0
      assert Map.has_key?(bundles, hash)
    end

    test "active bundle has required fields" do
      bundle = BundledVersions.active()

      assert is_binary(bundle.erts) and byte_size(bundle.erts) > 0
      assert is_binary(bundle.otp_release) and byte_size(bundle.otp_release) > 0
      assert is_binary(bundle.elixir) and byte_size(bundle.elixir) > 0
      assert is_binary(bundle.openssl) and byte_size(bundle.openssl) > 0
      assert is_binary(bundle.exqlite_beam) and byte_size(bundle.exqlite_beam) > 0
    end
  end

  describe "for_hash/1" do
    test "{:ok, bundle} when hash is present" do
      manifest = BundledVersions.load()
      hash = manifest.active_hash
      assert {:ok, _} = BundledVersions.for_hash(hash)
    end

    test "{:error, :unknown_hash} for unknown hash" do
      assert {:error, :unknown_hash} = BundledVersions.for_hash("nope12345")
    end
  end

  describe "validation (synthetic manifest written to a tmp file)" do
    @tag :tmp_dir
    test "valid manifest loads", %{tmp_dir: dir} do
      path = Path.join(dir, "manifest.exs")

      File.write!(path, """
      %{
        active_hash: "abcdef",
        bundles: %{
          "abcdef" => %{
            erts: "16.3",
            otp_release: "28",
            elixir: "1.19.5",
            openssl: "3.4.0",
            exqlite_beam: "0.36.0"
          }
        }
      }
      """)

      {manifest, _} = Code.eval_file(path)
      assert manifest.active_hash == "abcdef"
    end
  end
end
