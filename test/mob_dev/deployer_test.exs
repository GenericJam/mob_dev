defmodule MobDev.DeployerTest do
  use ExUnit.Case, async: true

  alias MobDev.Deployer

  # ── generate_crypto_shim/0 ────────────────────────────────────────────────

  describe "generate_crypto_shim/0" do
    test "compiles successfully" do
      # Delete cached shim so we always test a fresh compile
      File.rm_rf!(Path.join(System.tmp_dir!(), "mob_crypto_shim"))
      assert {:ok, dir} = Deployer.generate_crypto_shim()
      assert File.exists?(Path.join(dir, "crypto.beam"))
      assert File.exists?(Path.join(dir, "crypto.app"))
    end

    test "is idempotent — second call reuses cached shim" do
      assert {:ok, dir1} = Deployer.generate_crypto_shim()
      assert {:ok, dir2} = Deployer.generate_crypto_shim()
      assert dir1 == dir2
    end

    test "shim exports pbkdf2_hmac/5" do
      {:ok, dir} = Deployer.generate_crypto_shim()
      {:ok, {_, chunks}} = :beam_lib.chunks(Path.join(dir, "crypto.beam") |> String.to_charlist(), [:exports])
      exports = chunks[:exports]
      assert {:pbkdf2_hmac, 5} in exports
    end

    test "shim exports exor/2" do
      {:ok, dir} = Deployer.generate_crypto_shim()
      {:ok, {_, chunks}} = :beam_lib.chunks(Path.join(dir, "crypto.beam") |> String.to_charlist(), [:exports])
      exports = chunks[:exports]
      assert {:exor, 2} in exports
    end

    test "shim exports strong_rand_bytes/1, mac/4, mac/3, hash/2, supports/1" do
      {:ok, dir} = Deployer.generate_crypto_shim()
      {:ok, {_, chunks}} = :beam_lib.chunks(Path.join(dir, "crypto.beam") |> String.to_charlist(), [:exports])
      exports = chunks[:exports]
      for {name, arity} <- [{:strong_rand_bytes, 1}, {:mac, 4}, {:mac, 3}, {:hash, 2}, {:supports, 1}] do
        assert {name, arity} in exports, "expected #{name}/#{arity} in exports"
      end
    end

    test "pbkdf2_hmac/5 returns binary of requested length" do
      {:ok, dir} = Deployer.generate_crypto_shim()
      :code.add_patha(String.to_charlist(dir))
      # Call via apply to avoid compile-time crypto dependency
      result = apply(:crypto, :pbkdf2_hmac, [:sha256, "password", "salt", 1000, 32])
      assert is_binary(result)
      assert byte_size(result) == 32
      :code.del_path(String.to_charlist(dir))
    end

    test "pbkdf2_hmac/5 is deterministic" do
      {:ok, dir} = Deployer.generate_crypto_shim()
      :code.add_patha(String.to_charlist(dir))
      r1 = apply(:crypto, :pbkdf2_hmac, [:sha256, "pw", "salt", 100, 16])
      r2 = apply(:crypto, :pbkdf2_hmac, [:sha256, "pw", "salt", 100, 16])
      assert r1 == r2
      :code.del_path(String.to_charlist(dir))
    end

    test "exor/2 XORs two binaries" do
      {:ok, dir} = Deployer.generate_crypto_shim()
      :code.add_patha(String.to_charlist(dir))
      result = apply(:crypto, :exor, [<<0xFF, 0x00>>, <<0x0F, 0xFF>>])
      assert result == <<0xF0, 0xFF>>
      :code.del_path(String.to_charlist(dir))
    end

    test "mac/4 returns a non-empty binary" do
      {:ok, dir} = Deployer.generate_crypto_shim()
      :code.add_patha(String.to_charlist(dir))
      result = apply(:crypto, :mac, [:hmac, :sha256, "key", "data"])
      assert is_binary(result)
      assert byte_size(result) > 0
      :code.del_path(String.to_charlist(dir))
    end

    test "mac/4 is deterministic for same inputs" do
      {:ok, dir} = Deployer.generate_crypto_shim()
      :code.add_patha(String.to_charlist(dir))
      r1 = apply(:crypto, :mac, [:hmac, :sha256, "key", "data"])
      r2 = apply(:crypto, :mac, [:hmac, :sha256, "key", "data"])
      assert r1 == r2
      :code.del_path(String.to_charlist(dir))
    end
  end
end
