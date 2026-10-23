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
      # The scan's OTP drift check and advisory match key off it.
      assert is_binary(bundle.otp_version) and byte_size(bundle.otp_version) > 0
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

  describe "validate!/1" do
    @base %{
      erts: "17.1.1",
      otp_release: "29",
      elixir: "1.20.1",
      openssl: "3.5.9",
      exqlite_beam: "0.36.0"
    }

    test "the active bundle must record its OTP release; older bundles needn't" do
      legacy = %{"old" => @base}

      assert BundledVersions.validate!(%{
               active_hash: "new",
               bundles: Map.put(legacy, "new", Map.put(@base, :otp_version, "29.1.2"))
             }) == :ok

      assert_raise RuntimeError,
                   ~r/active bundle "new" missing required field :otp_version/,
                   fn ->
                     BundledVersions.validate!(%{
                       active_hash: "new",
                       bundles: Map.put(legacy, "new", @base)
                     })
                   end
    end
  end
end
