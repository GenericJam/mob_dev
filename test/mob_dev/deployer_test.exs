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

  describe "select_canonical_android_devices/2" do
    defp canonical_device(serial, status \\ :discovered) do
      %MobDev.Device{platform: :android, serial: serial, status: status}
    end

    test "selects the full exact set in canonical order and ignores unrelated devices" do
      abc = canonical_device("ABC")
      serial_b = canonical_device("serial-b")

      devices = [
        canonical_device("unrelated"),
        serial_b,
        canonical_device("blocked", :unauthorized),
        abc,
        canonical_device("recovery", :error)
      ]

      assert {:ok, [^abc, ^serial_b]} =
               Deployer.select_canonical_android_devices(devices, ["ABC", "serial-b"])
    end

    test "fails closed on a missing canonical serial" do
      assert {:error, :canonical_target_missing} =
               Deployer.select_canonical_android_devices(
                 [canonical_device("unrelated")],
                 ["ABC"]
               )
    end

    test "fails closed on exact duplicate discovery rows" do
      assert {:error, :canonical_target_duplicated} =
               Deployer.select_canonical_android_devices(
                 [canonical_device("ABC"), canonical_device("ABC")],
                 ["ABC"]
               )
    end

    test "fails closed on case-collision ambiguity" do
      assert {:error, :canonical_case_collision} =
               Deployer.select_canonical_android_devices(
                 [canonical_device("ABC"), canonical_device("abc")],
                 ["ABC"]
               )

      assert {:error, :canonical_case_collision} =
               Deployer.select_canonical_android_devices(
                 [canonical_device("abc")],
                 ["ABC"]
               )
    end

    test "fails closed on duplicated or unavailable canonical targets" do
      assert {:error, :duplicate_canonical_target} =
               Deployer.select_canonical_android_devices(
                 [canonical_device("ABC")],
                 ["ABC", "ABC"]
               )

      assert {:error, :canonical_target_unavailable} =
               Deployer.select_canonical_android_devices(
                 [canonical_device("ABC", :unauthorized)],
                 ["ABC"]
               )

      assert {:error, :canonical_target_unavailable} =
               Deployer.select_canonical_android_devices(
                 [%MobDev.Device{platform: :ios, serial: "ABC", status: :discovered}],
                 ["ABC"]
               )
    end
  end

  describe "deploy_all/1 native canonical Android selection" do
    test "mutates the exact canonical set once and ignores unrelated late devices" do
      parent = self()
      abc = canonical_device("ABC")
      serial_b = canonical_device("serial-b")

      lister = fn ->
        [
          canonical_device("late-device"),
          serial_b,
          canonical_device("blocked", :unauthorized),
          abc
        ]
      end

      deploy = fn device ->
        send(parent, {:mutated, device.serial})
        {:ok, device}
      end

      result =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {[^abc, ^serial_b], [], []} =
                   Deployer.deploy_all(
                     platforms: [:android],
                     force_fs: true,
                     canonical_android_serials: ["ABC", "serial-b"],
                     android_lister: lister,
                     device_deployer: deploy
                   )
        end)

      assert result =~ "2 device(s)"
      assert_received {:mutated, "ABC"}
      assert_received {:mutated, "serial-b"}
      refute_received {:mutated, _}
    end

    test "validates the complete canonical set before any mutation" do
      parent = self()

      deploy = fn device ->
        send(parent, {:mutated, device.serial})
        {:ok, device}
      end

      invalid_snapshots = [
        [canonical_device("unrelated")],
        [canonical_device("ABC"), canonical_device("ABC")],
        [canonical_device("ABC"), canonical_device("abc")]
      ]

      Enum.each(invalid_snapshots, fn devices ->
        assert_raise Mix.Error,
                     "Canonical Android target set no longer matches discovery; refusing final deploy",
                     fn ->
                       ExUnit.CaptureIO.capture_io(fn ->
                         Deployer.deploy_all(
                           platforms: [:android],
                           force_fs: true,
                           canonical_android_serials: ["ABC"],
                           android_lister: fn -> devices end,
                           device_deployer: deploy
                         )
                       end)
                     end

        refute_received {:mutated, _}
      end)
    end

    test "ordinary --device matching remains case-insensitive" do
      parent = self()
      abc = canonical_device("ABC")

      deploy = fn device ->
        send(parent, {:mutated, device.serial})
        {:ok, device}
      end

      ExUnit.CaptureIO.capture_io(fn ->
        assert {[^abc], [], []} =
                 Deployer.deploy_all(
                   platforms: [:android],
                   force_fs: true,
                   device: "abc",
                   android_lister: fn -> [abc, canonical_device("unrelated")] end,
                   device_deployer: deploy
                 )
      end)

      assert_received {:mutated, "ABC"}
      refute_received {:mutated, _}
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
