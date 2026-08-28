defmodule MobDev.DeployerTest do
  use ExUnit.Case, async: true

  alias MobDev.Deployer

  describe "physical iOS override" do
    test "requires staged bootstrap bytes to match the active compile output" do
      root = Path.join(System.tmp_dir!(), "mob_ios_override_#{System.unique_integer()}")
      compile_path = Path.join(root, "compile")
      staging_dir = Path.join(root, "staging")
      File.mkdir_p!(compile_path)
      File.mkdir_p!(staging_dir)
      on_exit(fn -> File.rm_rf!(root) end)

      assert {:error, message} =
               Deployer.validate_ios_override(compile_path, staging_dir, "sample_app")

      assert message =~ "active Mix compile output"
      assert message =~ Path.join(compile_path, "sample_app.beam")

      File.write!(Path.join(compile_path, "sample_app.beam"), "current bootstrap")

      assert {:error, message} =
               Deployer.validate_ios_override(compile_path, staging_dir, "sample_app")

      assert message =~ "does not match active compile output"

      File.write!(Path.join(staging_dir, "sample_app.beam"), "stale dependency bootstrap")

      assert {:error, message} =
               Deployer.validate_ios_override(compile_path, staging_dir, "sample_app")

      assert message =~ "verification mismatch"

      File.write!(Path.join(staging_dir, "sample_app.beam"), "current bootstrap")

      assert :ok =
               Deployer.validate_ios_override(compile_path, staging_dir, "sample_app")
    end

    test "copy command replaces the exact override directory" do
      args = Deployer.ios_override_copy_args("device-id", "com.example.app", "/tmp/app", "app")

      assert args == [
               "devicectl",
               "device",
               "copy",
               "to",
               "--device",
               "device-id",
               "--domain-type",
               "appDataContainer",
               "--domain-identifier",
               "com.example.app",
               "--source",
               "/tmp/app",
               "--destination",
               "Documents/otp/app",
               "--remove-existing-content",
               "true"
             ]
    end

    test "verification command retrieves the exact remote bootstrap" do
      assert Deployer.ios_override_verify_args(
               "device-id",
               "com.example.app",
               "/tmp/received.beam",
               "app"
             ) == [
               "devicectl",
               "device",
               "copy",
               "from",
               "--device",
               "device-id",
               "--domain-type",
               "appDataContainer",
               "--domain-identifier",
               "com.example.app",
               "--source",
               "Documents/otp/app/app.beam",
               "--destination",
               "/tmp/received.beam"
             ]
    end

    test "remote bootstrap must match staged bytes" do
      dir = Path.join(System.tmp_dir!(), "mob_ios_verify_#{System.unique_integer()}")
      staged = Path.join(dir, "staged.beam")
      received = Path.join(dir, "received.beam")
      File.mkdir_p!(dir)
      File.write!(staged, "same beam")
      File.write!(received, "same beam")
      on_exit(fn -> File.rm_rf!(dir) end)

      assert :ok = Deployer.verify_ios_bootstrap(staged, received)

      File.write!(received, "different beam")

      assert {:error, "physical iOS bootstrap verification mismatch"} =
               Deployer.verify_ios_bootstrap(staged, received)

      File.rm!(received)

      assert {:error, "physical iOS bootstrap verification failed: enoent"} =
               Deployer.verify_ios_bootstrap(staged, received)
    end
  end

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

      {:ok, {_, chunks}} =
        :beam_lib.chunks(Path.join(dir, "crypto.beam") |> String.to_charlist(), [:exports])

      exports = chunks[:exports]
      assert {:pbkdf2_hmac, 5} in exports
    end

    test "shim exports exor/2" do
      {:ok, dir} = Deployer.generate_crypto_shim()

      {:ok, {_, chunks}} =
        :beam_lib.chunks(Path.join(dir, "crypto.beam") |> String.to_charlist(), [:exports])

      exports = chunks[:exports]
      assert {:exor, 2} in exports
    end

    test "shim exports strong_rand_bytes/1, mac/4, mac/3, hash/2, supports/1" do
      {:ok, dir} = Deployer.generate_crypto_shim()

      {:ok, {_, chunks}} =
        :beam_lib.chunks(Path.join(dir, "crypto.beam") |> String.to_charlist(), [:exports])

      exports = chunks[:exports]

      for {name, arity} <- [
            {:strong_rand_bytes, 1},
            {:mac, 4},
            {:mac, 3},
            {:hash, 2},
            {:supports, 1}
          ] do
        assert {name, arity} in exports, "expected #{name}/#{arity} in exports"
      end
    end

    test "pbkdf2_hmac/5 returns binary of requested length" do
      {:ok, dir} = Deployer.generate_crypto_shim()
      :code.add_patha(String.to_charlist(dir))
      # Call via apply to avoid compile-time crypto dependency
      result = apply(:crypto, :pbkdf2_hmac, [:sha256, "password", "salt", 1000, 32])
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

  # ── categorize_results/1 ────────────────────────────────────────────────

  describe "categorize_results/1" do
    # Use minimal Device structs (just the fields the function reads, plus
    # the ones the production code threads through for display).
    defp device(name), do: %MobDev.Device{name: name, serial: name, platform: :android}

    test "buckets :ok results as deployed" do
      a = device("a")
      b = device("b")

      assert {[^a, ^b], [], []} = Deployer.categorize_results([{:ok, a}, {:ok, b}])
    end

    test "buckets :error results as failed" do
      a = device("a")

      assert {[], [^a], []} = Deployer.categorize_results([{:error, a}])
    end

    test "buckets :skipped results as skipped" do
      a = device("a")

      assert {[], [], [^a]} = Deployer.categorize_results([{:skipped, a}])
    end

    test "skipped does NOT leak into failed (regression pin)" do
      # The original behaviour returned `:error` for app-not-installed,
      # so the count of "failed" devices included multi-platform sweep
      # skips. categorize_results pins the three-way split.
      deployed = device("deployed")
      stale = device("stale_lock_skipped")
      busted = device("real_failure")

      assert {[^deployed], [^busted], [^stale]} =
               Deployer.categorize_results([
                 {:ok, deployed},
                 {:skipped, stale},
                 {:error, busted}
               ])
    end

    test "empty input returns three empty lists" do
      assert {[], [], []} = Deployer.categorize_results([])
    end

    test "mixed real-world shape — iOS deploy + 5 Android skips" do
      iphone = device("iPhone")
      androids = for i <- 1..5, do: device("emulator-#{i}")

      results = [{:ok, iphone} | Enum.map(androids, &{:skipped, &1})]

      {deployed, failed, skipped} = Deployer.categorize_results(results)
      assert deployed == [iphone]
      assert failed == []
      assert length(skipped) == 5
    end
  end

  # ── android_package_installed?/2 ────────────────────────────────────────

  describe "android_package_installed?/2" do
    test "true when pm output contains the package line" do
      pm_out = "package:com.example.test_migration\n"
      assert Deployer.android_package_installed?(pm_out, "com.example.test_migration")
    end

    test "false when pm output is empty (no matching package)" do
      # Adb's `pm list packages <pkg>` returns empty output when there's
      # no match — NOT a 'package:' line with empty body.
      refute Deployer.android_package_installed?("", "com.example.test_migration")
    end

    test "false when pm output lists a DIFFERENT package" do
      pm_out = "package:com.example.different_app\n"
      refute Deployer.android_package_installed?(pm_out, "com.example.test_migration")
    end

    test "true when pm output has the target package among others" do
      pm_out = """
      package:com.example.test_migration
      package:com.example.different_app
      """

      assert Deployer.android_package_installed?(pm_out, "com.example.test_migration")
    end

    test "false on partial match without 'package:' prefix" do
      # Defensive: substring match must require the 'package:' prefix so
      # output like "com.example.test_migration is your app" doesn't
      # falsely register as installed.
      pm_out = "com.example.test_migration unrelated text\n"
      refute Deployer.android_package_installed?(pm_out, "com.example.test_migration")
    end
  end

  describe "__sqlite_nif_target__/1 (exqlite NIF symlink target, ABI-aware)" do
    test "picks the 64-bit lib on an arm64 device" do
      lines = ["/data/app/com.example.app-hash==/lib/arm64/libsqlite3_nif.so"]
      assert Deployer.__sqlite_nif_target__(lines) =~ "/lib/arm64/libsqlite3_nif.so"
    end

    test "picks the 32-bit lib on an armeabi-v7a device (the bug: was hardcoded arm64)" do
      # Android extracts only the active ABI, so a 32-bit phone has lib/arm —
      # hardcoding lib/arm64 produced a dangling symlink and crashed boot.
      lines = ["/data/app/com.example.app-hash==/lib/arm/libsqlite3_nif.so"]
      assert Deployer.__sqlite_nif_target__(lines) == hd(lines)
    end

    test "nil when the glob matched nothing (ls returned no real path)" do
      assert Deployer.__sqlite_nif_target__([]) == nil
    end

    test "ignores trailing whitespace and unrelated lines" do
      lines = ["  /data/app/x/lib/arm/libsqlite3_nif.so  ", "ls: bad: No such file"]
      assert Deployer.__sqlite_nif_target__(lines) == "/data/app/x/lib/arm/libsqlite3_nif.so"
    end
  end
end
