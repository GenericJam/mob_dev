defmodule MobDev.DeployerTest do
  use ExUnit.Case, async: true

  alias MobDev.Deployer

  describe "authoritative iOS restart results" do
    test "simulator and physical restart paths require authoritative callback success" do
      parent = self()

      simulator_launcher = fn udid, bundle, opts ->
        send(parent, {:simulator_restart, udid, bundle, opts})
        {"launched", 0}
      end

      assert Deployer.restart_ios_simulator(true, "SIM-UDID", "com.example.app",
               dist_port: 9120,
               node_suffix: "sim-a",
               ios_launcher: simulator_launcher
             ) == :ok

      assert_received {:simulator_restart, "SIM-UDID", "com.example.app", simulator_opts}
      assert simulator_opts[:dist_port] == 9120
      assert simulator_opts[:node_suffix] == "sim-a"

      assert Deployer.restart_ios_simulator(true, "SIM-UDID", "com.example.app",
               ios_launcher: fn _udid, _bundle, _opts -> {"private output", 9} end
             ) == {:error, "iOS app restart failed with exit status 9"}

      physical_restarter = fn udid, bundle ->
        send(parent, {:physical_restart, udid, bundle})
        {"launched", 0}
      end

      assert Deployer.restart_ios_physical(true, "PHONE-UDID", "com.example.app",
               ios_physical_restarter: physical_restarter
             ) == :ok

      assert_received {:physical_restart, "PHONE-UDID", "com.example.app"}

      assert Deployer.restart_ios_physical(true, "PHONE-UDID", "com.example.app",
               ios_physical_restarter: fn _udid, _bundle -> :malformed end
             ) == {:error, "iOS app restart returned a malformed result"}
    end

    test "restart false skips both platform callbacks" do
      assert Deployer.restart_ios_simulator(false, "SIM-UDID", "com.example.app",
               ios_launcher: fn _udid, _bundle, _opts -> flunk("simulator callback ran") end
             ) == :ok

      assert Deployer.restart_ios_physical(false, "PHONE-UDID", "com.example.app",
               ios_physical_restarter: fn _udid, _bundle -> flunk("physical callback ran") end
             ) == :ok
    end

    test "accepts only a well-formed zero exit status" do
      assert Deployer.execute_ios_restart(fn -> {"launched", 0} end) == :ok

      assert Deployer.execute_ios_restart(fn -> {"private command output", 7} end) ==
               {:error, "iOS app restart failed with exit status 7"}

      assert Deployer.execute_ios_restart(fn -> :ok end) ==
               {:error, "iOS app restart returned a malformed result"}
    end

    test "normalizes raised, thrown, exited, and invalid callbacks without leaking output" do
      assert Deployer.execute_ios_restart(fn -> raise "private device output" end) ==
               {:error, "iOS app restart failed before an authoritative result"}

      assert Deployer.execute_ios_restart(fn -> throw(:private_device_output) end) ==
               {:error, "iOS app restart failed before an authoritative result"}

      assert Deployer.execute_ios_restart(fn -> exit(:private_device_output) end) ==
               {:error, "iOS app restart failed before an authoritative result"}

      assert Deployer.execute_ios_restart(:invalid) ==
               {:error, "iOS app restart callback is invalid"}
    end

    test "invokes the restart callback exactly once" do
      parent = self()

      assert Deployer.execute_ios_restart(fn ->
               send(parent, :restart_called)
               {"launched", 0}
             end) == :ok

      assert_received :restart_called
      refute_received :restart_called
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

  describe "select_canonical_android_devices/2" do
    defp canonical_device(serial, status \\ :discovered) do
      %MobDev.Device{platform: :android, serial: serial, status: status, abi: "arm64-v8a"}
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

  describe "authoritative Android payload plan" do
    @describetag :tmp_dir

    test "emits the exact shared schema and validates registered immutable bytes", %{tmp_dir: dir} do
      {context, opts} = android_payload_fixture!(dir)

      assert {:ok, plan} = Deployer.prepare_android_payload(context, opts)

      assert Enum.sort(Map.keys(plan)) ==
               Enum.sort([
                 :version,
                 :package,
                 :attempt_id,
                 :serials,
                 :selected_abis,
                 :selected_abis_by_serial,
                 :apk,
                 :beam,
                 :exqlite,
                 :restart_by_serial
               ])

      assert Enum.sort(Map.keys(plan.beam)) ==
               Enum.sort([
                 :archive,
                 :stage_device,
                 :app_stage,
                 :app_backup,
                 :activation_lock,
                 :dist_snapshot,
                 :runtime_version,
                 :beam_flags
               ])

      assert plan.exqlite == nil
      assert plan.beam.beam_flags == "+S 1:1"
      assert %{restart?: true, mode: :checked_restart} = plan.restart_by_serial["serial-a"]
      refute Map.has_key?(plan, :cleanup_token)
      refute Map.has_key?(plan.beam, :live_dir)
      refute Map.has_key?(plan.beam, :checks)

      identity = %{package: context.bundle_id, serials: context.serials}
      assert Deployer.valid_android_payload?(plan, identity)

      for path <- [plan.apk.path, plan.beam.archive.path] do
        assert {:ok, %{type: :regular, mode: mode}} = File.stat(path)
        assert Bitwise.band(mode, 0o222) == 0
      end

      assert :ok = Deployer.cleanup_android_payload(plan)
      assert :ok = Deployer.cleanup_android_payload(plan)
      refute File.exists?(plan.apk.path)
    end

    test "rejects changed or writable payload bytes but cleanup remains registry-scoped", %{
      tmp_dir: dir
    } do
      {context, opts} = android_payload_fixture!(dir)
      assert {:ok, plan} = Deployer.prepare_android_payload(context, opts)
      identity = %{package: context.bundle_id, serials: context.serials}

      File.chmod!(plan.beam.archive.path, 0o600)
      File.write!(plan.beam.archive.path, "changed")
      refute Deployer.valid_android_payload?(plan, identity)

      forged = put_in(plan.apk.sha256, String.duplicate("0", 64))
      assert {:error, _reason} = Deployer.cleanup_android_payload(forged)
      assert File.exists?(plan.apk.path)

      assert :ok = Deployer.cleanup_android_payload(plan)
      refute File.exists?(plan.apk.path)
    end

    test "dist snapshot and filesystem archive use the same staged bytes after source mutation",
         %{
           tmp_dir: dir
         } do
      {context, opts} = android_payload_fixture!(dir)
      beam_dir = opts |> Keyword.fetch!(:beam_dirs) |> List.first()
      source_path = Path.join(beam_dir, "Elixir.MobDev.Deployer.beam")
      mutated_source = alternate_deployer_beam!()

      local_runner = fn executable, args, command_opts ->
        result = System.cmd(executable, args, command_opts)

        if executable == "cp" and elem(result, 1) == 0 do
          File.write!(source_path, mutated_source)
        end

        result
      end

      assert {:ok, plan} =
               Deployer.prepare_android_payload(
                 context,
                 Keyword.put(opts, :local_runner, local_runner)
               )

      archive_dir = Path.join(dir, "archive-contents")
      File.mkdir_p!(archive_dir)
      assert {"", 0} = System.cmd("tar", ["xf", plan.beam.archive.path, "-C", archive_dir])

      archived_beam = File.read!(Path.join(archive_dir, "Elixir.MobDev.Deployer.beam"))

      assert [%{module: MobDev.Deployer, binary: dist_beam}] = plan.beam.dist_snapshot
      assert dist_beam == archived_beam
      refute dist_beam == mutated_source

      assert :ok = Deployer.cleanup_android_payload(plan)
    end

    test "rejects unchecked restart before reserving any artifact root", %{tmp_dir: dir} do
      {context, opts} = android_payload_fixture!(dir)

      assert {:error, "Native Android payload requires checked restart"} =
               Deployer.prepare_android_payload(context, Keyword.put(opts, :restart, false))

      assert Path.wildcard(Path.join(dir, "mob_android_payload_*")) == []
    end

    test "an unregistered structurally valid copy in another process has no cleanup authority", %{
      tmp_dir: dir
    } do
      {context, opts} = android_payload_fixture!(dir)
      assert {:ok, plan} = Deployer.prepare_android_payload(context, opts)

      task = Task.async(fn -> Deployer.cleanup_android_payload(plan) end)
      assert {:error, _reason} = Task.await(task)
      assert File.exists?(plan.apk.path)
      assert :ok = Deployer.cleanup_android_payload(plan)
    end
  end

  describe "deploy_all/1 native canonical Android selection" do
    @describetag :tmp_dir

    test "mutates the exact canonical set once and ignores unrelated late devices", %{
      tmp_dir: dir
    } do
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
                     [
                       platforms: [:android],
                       force_fs: true,
                       canonical_android_serials: ["ABC", "serial-b"],
                       android_lister: lister,
                       device_deployer: deploy
                     ] ++ fast_deploy_test_opts(dir)
                   )
        end)

      assert result =~ "2 device(s)"
      assert_received {:mutated, "ABC"}
      assert_received {:mutated, "serial-b"}
      refute_received {:mutated, _}
    end

    test "validates the complete canonical set before any mutation", %{tmp_dir: dir} do
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
                           [
                             platforms: [:android],
                             force_fs: true,
                             canonical_android_serials: ["ABC"],
                             android_lister: fn -> devices end,
                             device_deployer: deploy
                           ] ++ fast_deploy_test_opts(dir)
                         )
                       end)
                     end

        refute_received {:mutated, _}
      end)
    end

    test "ordinary --device matching remains case-insensitive", %{tmp_dir: dir} do
      parent = self()
      abc = canonical_device("ABC")

      deploy = fn device ->
        send(parent, {:mutated, device.serial})
        {:ok, device}
      end

      ExUnit.CaptureIO.capture_io(fn ->
        assert {[^abc], [], []} =
                 Deployer.deploy_all(
                   [
                     platforms: [:android],
                     force_fs: true,
                     device: "abc",
                     android_lister: fn -> [abc, canonical_device("unrelated")] end,
                     device_deployer: deploy
                   ] ++ fast_deploy_test_opts(dir)
                 )
      end)

      assert_received {:mutated, "ABC"}
      refute_received {:mutated, _}
    end
  end

  describe "fast Android transaction boundaries" do
    @describetag :tmp_dir

    test "an absent package is read-only skipped and never prepares, locks, or mutates" do
      device = canonical_device("serial-a")
      parent = self()

      assert {[], [], [%{serial: "serial-a", status: :skipped}]} =
               Deployer.deploy_all(
                 platforms: [:android],
                 android_lister: fn -> [device] end,
                 android_package_runner: fn args ->
                   send(parent, {:package_probe, args})
                   {"", 0}
                 end,
                 fast_android_payload_preparer: fn _devices, _package, _opts ->
                   send(parent, :prepared)
                   {:error, "unexpected"}
                 end,
                 android_lock_runner: fn args ->
                   send(parent, {:locked, args})
                   {"", 0}
                 end,
                 device_deployer: fn target ->
                   send(parent, {:mutated, target.serial})
                   {:ok, target}
                 end
               )

      assert_received {:package_probe, ["-s", "serial-a", "shell", "pm", "list", "packages", _]}
      refute_received :prepared
      refute_received {:locked, _}
      refute_received {:mutated, _}
    end

    test "payload preparation failure happens before lease acquisition or mutation" do
      device = canonical_device("serial-a")
      parent = self()

      ExUnit.CaptureIO.capture_io(fn ->
        assert {[], [%{serial: "serial-a", status: :error}], []} =
                 Deployer.deploy_all(
                   platforms: [:android],
                   android_lister: fn -> [device] end,
                   android_package_runner: installed_package_runner(),
                   fast_android_payload_preparer: fn _devices, _package, _opts ->
                     send(parent, :prepared)
                     {:error, "snapshot failed"}
                   end,
                   android_lock_runner: fn args ->
                     send(parent, {:locked, args})
                     {"", 0}
                   end,
                   device_deployer: fn target ->
                     send(parent, {:mutated, target.serial})
                     {:ok, target}
                   end
                 )
      end)

      assert_received :prepared
      refute_received {:locked, _}
      refute_received {:mutated, _}
    end

    test "a later-target failure reports zero deployed and retains the exact-set lease", %{
      tmp_dir: dir
    } do
      first = canonical_device("serial-a")
      second = canonical_device("serial-b")
      parent = self()

      opts =
        [
          platforms: [:android],
          canonical_android_serials: ["serial-a", "serial-b"],
          android_lister: fn -> [second, first] end,
          device_deployer: fn
            %{serial: "serial-a"} = target ->
              send(parent, {:mutated, "serial-a"})
              {:ok, target}

            %{serial: "serial-b"} ->
              send(parent, {:mutated, "serial-b"})
              {:error, "second target failed"}
          end
        ] ++ fast_deploy_test_opts(dir)

      ExUnit.CaptureIO.capture_io(fn ->
        assert {{[], failed, []}, %{state: :retained_failure, serials: serials}} =
                 Deployer.deploy_all_with_lease(opts)

        assert serials == ["serial-a", "serial-b"]
        assert Enum.map(failed, & &1.serial) == ["serial-a", "serial-b"]
        assert Enum.all?(failed, &(&1.status == :error))
      end)

      assert_received {:mutated, "serial-a"}
      assert_received {:mutated, "serial-b"}
      refute_received {:mutated, _}
    end

    test "a target throw after the first filesystem mutation retains the lease and never starts iOS",
         %{
           tmp_dir: dir
         } do
      first = canonical_device("serial-a")
      second = canonical_device("serial-b")
      ios = %MobDev.Device{platform: :ios, serial: "ios-a", status: :discovered}
      parent = self()

      opts =
        [
          platforms: [:android, :ios],
          force_fs: true,
          canonical_android_serials: ["serial-a", "serial-b"],
          android_lister: fn -> [second, first] end,
          ios_lister: fn ->
            send(parent, :ios_discovery_started)
            [ios]
          end,
          device_deployer: fn
            %{platform: :android, serial: "serial-a"} = target ->
              send(parent, {:mutated, :android, "serial-a"})
              {:ok, target}

            %{platform: :android, serial: "serial-b"} ->
              send(parent, {:mutated, :android, "serial-b"})
              throw(:target_runner_lost)

            %{platform: :ios, serial: serial} = target ->
              send(parent, {:mutated, :ios, serial})
              {:ok, target}
          end
        ] ++ fast_deploy_test_opts(dir)

      ExUnit.CaptureIO.capture_io(fn ->
        assert {{[], failed, []}, retained} = Deployer.deploy_all_with_lease(opts)

        assert retained.state == :retained_failure
        assert retained.phase == :acquired
        assert retained.serials == ["serial-a", "serial-b"]
        assert Enum.map(failed, & &1.serial) == ["serial-a", "serial-b"]
        assert Enum.all?(failed, &(&1.status == :error))
      end)

      assert_received {:mutated, :android, "serial-a"}
      assert_received {:mutated, :android, "serial-b"}
      refute_received :ios_discovery_started
      refute_received {:mutated, :ios, _}
    end

    test "an entirely connected exact set hot-pushes and repaints inside one lease", %{
      tmp_dir: dir
    } do
      first = canonical_device("serial-a")
      second = canonical_device("serial-b")
      node_a = MobDev.Device.node_name(first)
      node_b = MobDev.Device.node_name(second)
      parent = self()
      base_lock_runner = successful_android_lock_runner()

      lock_runner = fn args ->
        send(parent, {:lease_command, args})
        base_lock_runner.(args)
      end

      rpc = fn node, module, _filename, _binary ->
        send(parent, {:hot_rpc, node, module})
        {:module, module}
      end

      repaint = fn node ->
        send(parent, {:repaint, node})
        :ok
      end

      opts =
        [
          platforms: [:android],
          canonical_android_serials: ["serial-a", "serial-b"],
          android_lister: fn -> [second, first] end,
          connected_nodes: [node_b, node_a],
          android_lock_runner: lock_runner,
          hot_push_rpc: rpc,
          hot_push_post_push: repaint,
          device_deployer: fn _target -> flunk("filesystem deploy must not run") end
        ] ++ fast_deploy_test_opts(dir)

      ExUnit.CaptureIO.capture_io(fn ->
        assert {[^first, ^second], [], []} = Deployer.deploy_all(opts)
      end)

      assert_received {:hot_rpc, ^node_a, MobDev.Deployer}
      assert_received {:hot_rpc, ^node_b, MobDev.Deployer}
      assert_received {:repaint, ^node_a}
      assert_received {:repaint, ^node_b}

      lease_commands = recorded_lease_commands()

      transition_index =
        Enum.find_index(lease_commands, &adb_command_contains?([&1], "|fast_committed"))

      assert is_integer(transition_index)
      assert adb_command_contains?(lease_commands, ".mob_native_deploy_releasing_")
      assert adb_command_contains?(lease_commands, "/record; rmdir ")
      refute adb_command_contains?(lease_commands, "rm -rf")
    end

    test "one disconnected target forces an exact-set filesystem transaction", %{tmp_dir: dir} do
      first = canonical_device("serial-a")
      second = canonical_device("serial-b")
      node_a = MobDev.Device.node_name(first)
      parent = self()

      opts =
        [
          platforms: [:android],
          canonical_android_serials: ["serial-a", "serial-b"],
          android_lister: fn -> [second, first] end,
          connected_nodes: [node_a],
          hot_push_rpc: fn _, _, _, _ -> flunk("mixed transport must not hot-push") end,
          hot_push_post_push: fn _ -> flunk("mixed transport must not repaint") end,
          device_deployer: fn target ->
            send(parent, {:filesystem_mutation, target.serial})
            {:ok, target}
          end
        ] ++ fast_deploy_test_opts(dir)

      ExUnit.CaptureIO.capture_io(fn ->
        assert {[^first, ^second], [], []} = Deployer.deploy_all(opts)
      end)

      assert_received {:filesystem_mutation, "serial-a"}
      assert_received {:filesystem_mutation, "serial-b"}
      refute_received {:filesystem_mutation, _}
    end

    test "hot-push or repaint ambiguity reports zero deployed and retains the lease", %{
      tmp_dir: dir
    } do
      device = canonical_device("serial-a")
      node = MobDev.Device.node_name(device)

      for {rpc, repaint} <- [
            {fn _node, _module, _filename, _binary -> {:error, :load_failed} end,
             fn _node -> flunk("repaint must not run after load failure") end},
            {fn _node, module, _filename, _binary -> {:module, module} end,
             fn _node -> throw(:repaint_reply_lost) end}
          ] do
        opts =
          [
            platforms: [:android],
            android_lister: fn -> [device] end,
            connected_nodes: [node],
            hot_push_rpc: rpc,
            hot_push_post_push: repaint
          ] ++ fast_deploy_test_opts(dir)

        ExUnit.CaptureIO.capture_io(fn ->
          assert {{[], [%{serial: "serial-a", status: :error}], []},
                  %{state: :retained_failure, phase: :acquired}} =
                   Deployer.deploy_all_with_lease(opts)
        end)
      end
    end
  end

  describe "public Android mutation authority" do
    @describetag :tmp_dir

    test "all legacy mutators reject missing operation-wide authority before any command", %{
      tmp_dir: dir
    } do
      beam_dir = Path.join(dir, "beams")
      File.mkdir_p!(beam_dir)
      File.write!(Path.join(beam_dir, "Elixir.Sample.beam"), "beam")
      ebin = exqlite_fixture!(dir)
      parent = self()

      runner = fn args ->
        send(parent, {:runner, args})
        {:ok, "Status: ok\n"}
      end

      local_runner = fn executable, args, _opts ->
        send(parent, {:local_runner, executable, args})
        {"", 0}
      end

      device = canonical_device("serial-a")

      assert {:error, direct_reason} =
               Deployer.deploy_android_device(device, [beam_dir], [], runner: runner)

      assert direct_reason =~ "Direct Android device mutation is disabled"

      assert {:error, beam_reason} =
               Deployer.push_beams_android_runas("serial-a", [beam_dir],
                 package: "com.example.casein",
                 beams_dir: "/data/data/com.example.casein/files/otp/casein",
                 runner: runner,
                 local_runner: local_runner,
                 tmp_root: dir,
                 attempt_id: "testattempt00001"
               )

      assert beam_reason =~ "operation-wide deploy lease"

      assert {:error, exqlite_reason} =
               Deployer.setup_exqlite_android_runas("serial-a", ebin, "0.35.0",
                 package: "com.example.casein",
                 app_data: "/data/data/com.example.casein/files",
                 runner: runner,
                 local_runner: local_runner,
                 tmp_root: dir,
                 attempt_id: "testattempt00001",
                 nif_target: "/data/app/x/lib/arm64/libsqlite3_nif.so"
               )

      assert exqlite_reason =~ "operation-wide deploy lease"

      assert {:error, restart_reason} =
               Deployer.restart_android(
                 "serial-a",
                 [
                   package: "com.example.casein",
                   node_suffix: "serial_a",
                   sleeper: fn _ -> send(parent, :slept) end
                 ],
                 runner
               )

      assert restart_reason =~ "operation-wide deploy lease"
      refute_received {:runner, _}
      refute_received {:local_runner, _, _}
      refute_received :slept
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

  describe "push_beams_android_runas/3" do
    @describetag :tmp_dir

    test "checks Android 9 no-same-owner extraction and a readable app BEAM", %{tmp_dir: dir} do
      beam_dir = Path.join(dir, "beams")
      File.mkdir_p!(beam_dir)
      File.write!(Path.join(beam_dir, "Elixir.Sample.beam"), "beam")
      runner = android_beam_runner(self())

      assert :ok =
               Deployer.push_beams_android_runas("serial-a", [beam_dir],
                 package: "com.example.casein",
                 operation_authority: android_operation_authority!(),
                 beams_dir: "/data/data/com.example.casein/files/otp/casein",
                 runner: runner,
                 local_runner: &System.cmd/3,
                 tmp_root: dir,
                 attempt_id: "testattempt00001"
               )

      commands = deployer_recorded_commands()

      assert Enum.any?(commands, fn
               ["-s", "serial-a", "shell", command] ->
                 command ==
                   "run-as com.example.casein tar xof /data/local/tmp/mob_beams_testattempt00001.tar -C /data/data/com.example.casein/files/otp/.mob_beams_stage_testattempt00001/"

               _ ->
                 false
             end)

      assert Enum.any?(commands, fn
               ["-s", "serial-a", "shell", command] ->
                 command =~ "test -r" and command =~ "Elixir.Sample.beam"

               _ ->
                 false
             end)

      refute Enum.any?(commands, fn args ->
               Enum.any?(args, &String.contains?(&1, "; true"))
             end)

      assert Enum.all?(commands, &match?(["-s", "serial-a" | _], &1))

      assert Enum.any?(commands, fn
               ["-s", "serial-a", "shell", command] ->
                 command =~ "had_live=0" and command =~ ".mob_beams_backup_testattempt00001"

               _ ->
                 false
             end)
    end

    test "atomically stages requested flags and present priv with readable sentinels", %{
      tmp_dir: dir
    } do
      beam_dir = Path.join(dir, "beams")
      priv_dir = Path.join(dir, "priv")
      File.mkdir_p!(beam_dir)
      File.mkdir_p!(Path.join(priv_dir, "repo/migrations"))
      File.write!(Path.join(beam_dir, "Elixir.Sample.beam"), "beam")
      File.write!(Path.join(priv_dir, "repo/migrations/001_create.exs"), "migration")

      local_runner = fn executable, args, opts ->
        result = System.cmd(executable, args, opts)

        if executable == "tar" and elem(result, 1) == 0 do
          archive = Enum.at(args, 1)
          {listing, 0} = System.cmd("tar", ["tf", archive])
          send(self(), {:archive_listing, listing})
        end

        result
      end

      assert :ok =
               Deployer.push_beams_android_runas("serial-a", [beam_dir],
                 package: "com.example.casein",
                 operation_authority: android_operation_authority!(),
                 beams_dir: "/data/data/com.example.casein/files/otp/casein",
                 runner: android_beam_runner(self()),
                 local_runner: local_runner,
                 tmp_root: dir,
                 attempt_id: "testattempt00001",
                 beam_flags: "-S 1:1",
                 priv_dir: priv_dir
               )

      assert_received {:archive_listing, listing}
      assert listing =~ "mob_beam_flags"
      assert listing =~ "priv/repo/migrations/001_create.exs"

      commands = deployer_recorded_commands()

      assert adb_command_contains?(commands, "test -r")
      assert adb_command_contains?(commands, "mob_beam_flags")
      assert adb_command_contains?(commands, "priv/repo/migrations/001_create.exs")
      assert adb_command_contains?(commands, "mv /data/data/com.example.casein/files/otp/casein")
    end

    test "flags write and priv copy failures issue zero adb commands", %{tmp_dir: dir} do
      beam_dir = Path.join(dir, "beams")
      priv_dir = Path.join(dir, "priv")
      File.mkdir_p!(beam_dir)
      File.mkdir_p!(priv_dir)
      File.write!(Path.join(beam_dir, "Elixir.Sample.beam"), "beam")
      File.write!(Path.join(priv_dir, "asset.txt"), "asset")

      assert {:error, "stage Android BEAM flags failed"} =
               Deployer.push_beams_android_runas("serial-a", [beam_dir],
                 package: "com.example.casein",
                 operation_authority: android_operation_authority!(),
                 beams_dir: "/data/data/com.example.casein/files/otp/casein",
                 runner: android_beam_runner(self()),
                 local_runner: &System.cmd/3,
                 file_writer: fn _path, _contents -> {:error, :eacces} end,
                 tmp_root: dir,
                 attempt_id: "testattempt00001",
                 beam_flags: "-S 1:1"
               )

      refute_received {:adb_command, _}

      local_runner = fn executable, args, opts ->
        if executable == "cp" and Enum.any?(args, &String.contains?(&1, "priv/.")) do
          {"sensitive child output", 1}
        else
          System.cmd(executable, args, opts)
        end
      end

      assert {:error, reason} =
               Deployer.push_beams_android_runas("serial-a", [beam_dir],
                 package: "com.example.casein",
                 operation_authority: android_operation_authority!(),
                 beams_dir: "/data/data/com.example.casein/files/otp/casein",
                 runner: android_beam_runner(self()),
                 local_runner: local_runner,
                 tmp_root: dir,
                 attempt_id: "testattempt00001",
                 priv_dir: priv_dir
               )

      assert reason == "stage Android priv files failed"
      refute reason =~ "sensitive child output"
      refute_received {:adb_command, _}
    end

    test "fails closed for copy, tar, push, mkdir, extract, and BEAM verification errors", %{
      tmp_dir: dir
    } do
      beam_dir = Path.join(dir, "beams")
      File.mkdir_p!(beam_dir)
      File.write!(Path.join(beam_dir, "Elixir.Sample.beam"), "beam")

      for {failure, expected} <- [
            {:copy, "stage BEAM files"},
            {:tar, "create BEAM archive"},
            {:push, "push BEAM archive"},
            {:mkdir, "prepare BEAM directory"},
            {:extract, "extract BEAM archive"},
            {:verify, "verify deployed BEAM"},
            {:activate, "activate deployed BEAMs"}
          ] do
        runner = android_beam_runner(self(), failure)

        local_runner = fn executable, args, opts ->
          send(self(), {:local_command, executable, args})

          if (failure == :copy and executable == "cp") or
               (failure == :tar and executable == "tar") do
            {"#{failure} failed", 1}
          else
            System.cmd(executable, args, opts)
          end
        end

        assert {:error, reason} =
                 Deployer.push_beams_android_runas("serial-a", [beam_dir],
                   package: "com.example.casein",
                   operation_authority: android_operation_authority!(),
                   beams_dir: "/data/data/com.example.casein/files/otp/casein",
                   runner: runner,
                   local_runner: local_runner,
                   tmp_root: dir,
                   attempt_id: "testattempt00001"
                 )

        assert reason =~ expected
        refute reason =~ "sensitive child output"
        assert byte_size(reason) <= 512
        commands = deployer_recorded_commands()

        assert Enum.all?(commands, &match?(["-s", "serial-a" | _], &1))

        case failure do
          local when local in [:copy, :tar] ->
            assert commands == []

          :push ->
            refute adb_command_contains?(commands, "tar xof")
            refute adb_command_contains?(commands, "test -r")

          :mkdir ->
            refute adb_command_contains?(commands, "tar xof")
            refute adb_command_contains?(commands, "test -r")

          :extract ->
            refute adb_command_contains?(commands, "test -r")

          :verify ->
            refute adb_command_contains?(commands, "had_live=0")

          :activate ->
            cleanup_commands =
              Enum.filter(commands, fn args ->
                adb_command_contains?([args], "run-as com.example.casein rm -rf")
              end)

            assert cleanup_commands == []
        end

        flush_local_commands()
      end
    end

    test "rejects an empty BEAM source before issuing adb commands", %{tmp_dir: dir} do
      beam_dir = Path.join(dir, "empty-beams")
      File.mkdir_p!(beam_dir)
      runner = android_beam_runner(self())

      assert {:error, reason} =
               Deployer.push_beams_android_runas("serial-a", [beam_dir],
                 package: "com.example.casein",
                 operation_authority: android_operation_authority!(),
                 beams_dir: "/data/data/com.example.casein/files/otp/casein",
                 runner: runner,
                 local_runner: &System.cmd/3,
                 tmp_root: dir,
                 attempt_id: "testattempt00001"
               )

      assert reason =~ "BEAM sentinel"
      refute_received {:adb_command, _}
    end

    test "refuses a stale backup and never deletes it", %{tmp_dir: dir} do
      beam_dir = Path.join(dir, "beams")
      File.mkdir_p!(beam_dir)
      File.write!(Path.join(beam_dir, "Elixir.Sample.beam"), "beam")

      runner = fn args ->
        send(self(), {:adb_command, args})

        if adb_command_contains?([args], "test ! -e") and
             adb_command_contains?([args], ".mob_beams_backup_testattempt00001") do
          {:error, "stale backup exists"}
        else
          {:ok, ""}
        end
      end

      assert {:error, reason} =
               Deployer.push_beams_android_runas("serial-a", [beam_dir],
                 package: "com.example.casein",
                 operation_authority: android_operation_authority!(),
                 beams_dir: "/data/data/com.example.casein/files/otp/casein",
                 runner: runner,
                 local_runner: &System.cmd/3,
                 tmp_root: dir,
                 attempt_id: "testattempt00001"
               )

      assert reason == "prepare BEAM directory failed"
      commands = deployer_recorded_commands()
      refute adb_command_contains?(commands, "tar xof")

      cleanup_commands =
        Enum.filter(commands, &adb_command_contains?([&1], "run-as com.example.casein rm -rf"))

      assert cleanup_commands == []
    end

    test "rejects an unsafe attempt id before local or device commands", %{tmp_dir: dir} do
      beam_dir = Path.join(dir, "beams")
      File.mkdir_p!(beam_dir)
      File.write!(Path.join(beam_dir, "Elixir.Sample.beam"), "beam")

      local_runner = fn executable, args, _opts ->
        send(self(), {:local_command, executable, args})
        {"unexpected", 0}
      end

      assert {:error, reason} =
               Deployer.push_beams_android_runas("serial-a", [beam_dir],
                 package: "com.example.casein",
                 operation_authority: android_operation_authority!(),
                 beams_dir: "/data/data/com.example.casein/files/otp/casein",
                 runner: android_beam_runner(self()),
                 local_runner: local_runner,
                 tmp_root: dir,
                 attempt_id: "../../unsafe"
               )

      assert reason =~ "Invalid Android deploy attempt id"
      refute_received {:local_command, _, _}
      refute_received {:adb_command, _}
    end

    test "rejects an unsafe adb serial before local or device commands", %{tmp_dir: dir} do
      beam_dir = Path.join(dir, "beams")
      File.mkdir_p!(beam_dir)
      File.write!(Path.join(beam_dir, "Elixir.Sample.beam"), "beam")

      local_runner = fn executable, args, _opts ->
        send(self(), {:local_command, executable, args})
        {"unexpected", 0}
      end

      assert {:error, reason} =
               Deployer.push_beams_android_runas("-serial-a", [beam_dir],
                 package: "com.example.casein",
                 operation_authority: android_operation_authority!(),
                 beams_dir: "/data/data/com.example.casein/files/otp/casein",
                 runner: android_beam_runner(self()),
                 local_runner: local_runner,
                 tmp_root: dir,
                 attempt_id: "testattempt00001"
               )

      assert reason =~ "Invalid adb serial"
      refute_received {:local_command, _, _}
      refute_received {:adb_command, _}
    end

    test "does not put an adb serial into local staging paths", %{tmp_dir: dir} do
      beam_dir = Path.join(dir, "beams")
      File.mkdir_p!(beam_dir)
      File.write!(Path.join(beam_dir, "Elixir.Sample.beam"), "beam")
      serial = "serial-with-local-path-marker"

      local_runner = fn executable, args, opts ->
        send(self(), {:local_command, executable, args})
        System.cmd(executable, args, opts)
      end

      assert :ok =
               Deployer.push_beams_android_runas(serial, [beam_dir],
                 package: "com.example.casein",
                 operation_authority: android_operation_authority!(serial),
                 beams_dir: "/data/data/com.example.casein/files/otp/casein",
                 runner: android_beam_runner(self()),
                 local_runner: local_runner,
                 tmp_root: dir,
                 attempt_id: "testattempt00001"
               )

      local_commands = recorded_local_commands()

      refute Enum.any?(local_commands, fn {_executable, args} ->
               Enum.any?(args, &String.contains?(&1, serial))
             end)

      _ = deployer_recorded_commands()
    end
  end

  describe "ensure_erts_on_device/3" do
    test "fails closed when adb cannot verify the runtime" do
      runner = fn _args -> {:error, "device offline " <> String.duplicate("x", 1_000)} end

      assert {:error, reason} =
               Deployer.ensure_erts_on_device("serial-a", "com.example.casein", runner)

      assert reason =~ "Could not verify OTP runtime on serial-a"
      assert byte_size(reason) <= 512
    end

    test "accepts a readable runtime sentinel" do
      runner = fn args ->
        assert Enum.any?(args, &String.contains?(&1, "erl_child_setup"))
        {:ok, ""}
      end

      assert :ok = Deployer.ensure_erts_on_device("serial-a", "com.example.casein", runner)
    end

    test "rejects invalid serial or package before the runner" do
      runner = fn args ->
        send(self(), {:adb_command, args})
        {:ok, ""}
      end

      assert {:error, _reason} =
               Deployer.ensure_erts_on_device("-serial-a", "com.example.casein", runner)

      assert {:error, _reason} =
               Deployer.ensure_erts_on_device("serial-a", "com.example.bad;id", runner)

      refute_received {:adb_command, _}
    end
  end

  describe "verify_elixir_runtime_version_android/5" do
    test "accepts an exact version and fails closed for mismatch, malformed, and adb errors" do
      app_data = "/data/data/com.example.casein/files"

      runner = fn _args -> {:ok, ~s({application,elixir,[{vsn,"1.20.0"}]}. )} end

      assert :ok =
               Deployer.verify_elixir_runtime_version_android(
                 "serial-a",
                 "com.example.casein",
                 app_data,
                 "1.20.0",
                 runner
               )

      for result <- [
            {:ok, ~s({application,elixir,[{vsn,"1.19.0"}]}. )},
            {:ok, "malformed"},
            {:error, "sensitive child output"},
            :invalid
          ] do
        runner = fn _args -> result end

        assert {:error, reason} =
                 Deployer.verify_elixir_runtime_version_android(
                   "serial-a",
                   "com.example.casein",
                   app_data,
                   "1.20.0",
                   runner
                 )

        refute reason =~ "sensitive child output"
      end
    end

    test "validates all interpolated inputs before runner invocation" do
      runner = fn args ->
        send(self(), {:adb_command, args})
        {:ok, ""}
      end

      assert {:error, _} =
               Deployer.verify_elixir_runtime_version_android(
                 "serial-a",
                 "com.example.bad;id",
                 "/data/data/com.example.bad;id/files",
                 "1.20.0",
                 runner
               )

      assert {:error, _} =
               Deployer.verify_elixir_runtime_version_android(
                 "serial-a",
                 "com.example.casein",
                 "/data/data/com.example.other/files",
                 "1.20.0",
                 runner
               )

      refute_received {:adb_command, _}
    end

    test "uses a dedicated bounded metadata cap without exposing content" do
      app_data = "/data/data/com.example.casein/files"
      valid = ~s({application,elixir,[{vsn,"1.20.0"}]}. )

      verify = fn content ->
        Deployer.verify_elixir_runtime_version_android(
          "serial-a",
          "com.example.casein",
          app_data,
          "1.20.0",
          fn _args -> {:ok, content} end
        )
      end

      # The artifact that exposed the old shared 8 KiB query limit is valid
      # structured metadata and remains comfortably below the dedicated cap.
      current_artifact = valid <> String.duplicate(" ", 8_319 - byte_size(valid))
      assert byte_size(current_artifact) == 8_319
      assert :ok = verify.(current_artifact)

      at_limit = valid <> String.duplicate(" ", 65_536 - byte_size(valid))
      assert byte_size(at_limit) == 65_536
      assert :ok = verify.(at_limit)

      over_limit = at_limit <> "x"
      assert byte_size(over_limit) == 65_537

      assert {:error, "Could not verify Elixir runtime version: output_too_large"} =
               verify.(over_limit)

      sensitive = at_limit <> "TOP_SECRET_METADATA"

      assert {:error, reason} = verify.(sensitive)
      assert reason == "Could not verify Elixir runtime version: output_too_large"
      refute reason =~ "TOP_SECRET_METADATA"
    end
  end

  describe "setup_exqlite_android_runas/4" do
    @describetag :tmp_dir

    test "stages, verifies, locks, swaps, and separately commits exqlite", %{tmp_dir: dir} do
      ebin = exqlite_fixture!(dir)
      runner = android_exqlite_runner(self())

      assert :ok =
               Deployer.setup_exqlite_android_runas("serial-a", ebin, "0.35.0",
                 package: "com.example.casein",
                 operation_authority: android_operation_authority!(),
                 app_data: "/data/data/com.example.casein/files",
                 runner: runner,
                 local_runner: &System.cmd/3,
                 tmp_root: dir,
                 attempt_id: "testattempt00001",
                 nif_target: "/data/app/~~hash/base/lib/arm64/libsqlite3_nif.so"
               )

      commands = deployer_recorded_commands()
      assert Enum.all?(commands, &match?(["-s", "serial-a" | _], &1))
      assert adb_command_contains?(commands, "tar xof")
      assert adb_command_contains?(commands, "ln -sf")
      assert adb_command_contains?(commands, "ebin/exqlite.app")
      assert adb_command_contains?(commands, "ebin/Elixir.Exqlite.beam")
      assert adb_command_contains?(commands, "test -L")

      activation = Enum.find(commands, &adb_command_contains?([&1], "had_live=0"))

      assert adb_command_contains?([activation], "mkdir ")
      assert adb_command_contains?([activation], ".mob_exqlite_activation_lock")

      refute adb_command_contains?(
               [activation],
               "rm -rf /data/data/com.example.casein/files/otp/lib/.mob_exqlite_backup_"
             )

      lock_release =
        Enum.find(commands, fn args ->
          adb_command_contains?([args], "rmdir") and
            adb_command_contains?([args], ".mob_exqlite_activation_lock")
        end)

      expected_backup_cleanup = [
        "-s",
        "serial-a",
        "shell",
        "run-as com.example.casein rm -rf /data/data/com.example.casein/files/otp/lib/.mob_exqlite_backup_testattempt00001"
      ]

      backup_cleanup = Enum.find(commands, &(&1 == expected_backup_cleanup))

      assert lock_release == [
               "-s",
               "serial-a",
               "shell",
               "run-as com.example.casein rmdir /data/data/com.example.casein/files/otp/lib/.mob_exqlite_activation_lock"
             ]

      assert backup_cleanup == expected_backup_cleanup
    end

    test "rejects incomplete local exqlite before adb", %{tmp_dir: dir} do
      ebin = Path.join(dir, "exqlite-ebin")
      File.mkdir_p!(ebin)
      File.write!(Path.join(ebin, "exqlite.app"), "app")

      assert {:error, reason} =
               Deployer.setup_exqlite_android_runas("serial-a", ebin, "0.35.0",
                 package: "com.example.casein",
                 operation_authority: android_operation_authority!(),
                 app_data: "/data/data/com.example.casein/files",
                 runner: android_exqlite_runner(self()),
                 tmp_root: dir,
                 attempt_id: "testattempt00001",
                 nif_target: "/data/app/x/lib/arm64/libsqlite3_nif.so"
               )

      assert reason =~ "exqlite ebin is incomplete"
      refute_received {:adb_command, _}
    end

    test "activation ambiguity preserves backup and lock and never commits", %{tmp_dir: dir} do
      ebin = exqlite_fixture!(dir)
      runner = android_exqlite_runner(self(), :activate)

      assert {:error, reason} =
               Deployer.setup_exqlite_android_runas("serial-a", ebin, "0.35.0",
                 package: "com.example.casein",
                 operation_authority: android_operation_authority!(),
                 app_data: "/data/data/com.example.casein/files",
                 runner: runner,
                 local_runner: &System.cmd/3,
                 tmp_root: dir,
                 attempt_id: "testattempt00001",
                 nif_target: "/data/app/x/lib/arm64/libsqlite3_nif.so"
               )

      assert reason == "activate exqlite runtime failed"
      commands = deployer_recorded_commands()
      activation = Enum.find(commands, &adb_command_contains?([&1], "had_live=0"))

      expected_activation =
        "run-as com.example.casein sh -c 'set -e; " <>
          "mkdir /data/data/com.example.casein/files/otp/lib/.mob_exqlite_activation_lock; " <>
          "had_live=0; " <>
          "if [ -e /data/data/com.example.casein/files/otp/lib/exqlite-0.35.0 ]; " <>
          "then mv /data/data/com.example.casein/files/otp/lib/exqlite-0.35.0 " <>
          "/data/data/com.example.casein/files/otp/lib/.mob_exqlite_backup_testattempt00001; " <>
          "had_live=1; fi; " <>
          "if mv /data/data/com.example.casein/files/otp/lib/.mob_exqlite_stage_testattempt00001 " <>
          "/data/data/com.example.casein/files/otp/lib/exqlite-0.35.0 && " <>
          "test -r /data/data/com.example.casein/files/otp/lib/exqlite-0.35.0/ebin/exqlite.app && " <>
          "test -r /data/data/com.example.casein/files/otp/lib/exqlite-0.35.0/ebin/Elixir.Exqlite.beam && " <>
          "test -L /data/data/com.example.casein/files/otp/lib/exqlite-0.35.0/priv/sqlite3_nif.so && " <>
          "test -r /data/data/com.example.casein/files/otp/lib/exqlite-0.35.0/priv/sqlite3_nif.so; " <>
          "then :; else rm -rf /data/data/com.example.casein/files/otp/lib/exqlite-0.35.0; " <>
          "if [ \"$had_live\" -eq 1 ]; then " <>
          "mv /data/data/com.example.casein/files/otp/lib/.mob_exqlite_backup_testattempt00001 " <>
          "/data/data/com.example.casein/files/otp/lib/exqlite-0.35.0; fi; exit 1; fi'"

      assert activation == ["-s", "serial-a", "shell", expected_activation]

      refute adb_command_contains?(
               [activation],
               "rm -rf /data/data/com.example.casein/files/otp/lib/.mob_exqlite_backup_"
             )

      refute adb_command_contains?(commands, "rmdir")

      cleanup_commands =
        Enum.filter(commands, &adb_command_contains?([&1], "run-as com.example.casein rm -rf"))

      refute Enum.any?(cleanup_commands, &adb_command_contains?([&1], ".mob_exqlite_backup_"))

      refute Enum.any?(
               cleanup_commands,
               &adb_command_contains?([&1], ".mob_exqlite_activation_lock")
             )
    end

    test "fails closed for zero, multiple, malformed, and oversized NIF query output", %{
      tmp_dir: dir
    } do
      ebin = exqlite_fixture!(dir)

      for nif_output <- [
            "",
            "/data/app/a/lib/arm64/libsqlite3_nif.so\n/data/app/b/lib/arm64/libsqlite3_nif.so\n",
            <<255, 254>>,
            String.duplicate("x", 8_193)
          ] do
        runner = fn args ->
          send(self(), {:adb_command, args})

          cond do
            adb_command_contains?([args], "pm path") ->
              {:ok, "package:/data/app/~~hash/base.apk\n"}

            adb_command_contains?([args], "libsqlite3_nif.so") ->
              {:ok, nif_output}

            true ->
              {:ok, ""}
          end
        end

        assert {:error, reason} =
                 Deployer.setup_exqlite_android_runas("serial-a", ebin, "0.35.0",
                   package: "com.example.casein",
                   operation_authority: android_operation_authority!(),
                   app_data: "/data/data/com.example.casein/files",
                   runner: runner,
                   local_runner: &System.cmd/3,
                   tmp_root: dir,
                   attempt_id: "testattempt00001"
                 )

        assert reason =~ "exqlite NIF" or reason =~ "invalid adb output"
        commands = deployer_recorded_commands()
        refute Enum.any?(commands, &("push" in &1))
      end
    end
  end

  describe "restart_android/3" do
    test "uses am start -W and propagates a launch failure" do
      runner = fn args ->
        send(self(), {:restart_command, args})

        if "start" in args do
          {:error, "activity failed"}
        else
          {:ok, ""}
        end
      end

      assert {:error, reason} =
               Deployer.restart_android(
                 "serial-a",
                 [
                   package: "com.example.casein",
                   operation_authority: android_operation_authority!(),
                   activity: ".MainActivity",
                   node_suffix: "serial_a",
                   sleeper: fn _ -> :ok end
                 ],
                 runner
               )

      assert reason =~ "launch Android app"

      assert_received {:restart_command, ["-s", "serial-a", "shell", "am", "start", "-W" | _]}
    end

    test "stops before relabel or launch when force-stop fails" do
      runner = fn args ->
        send(self(), {:restart_command, args})

        if "force-stop" in args,
          do: {:error, "sensitive child output"},
          else: {:ok, "Status: ok\n"}
      end

      assert {:error, reason} =
               Deployer.restart_android(
                 "serial-a",
                 [
                   package: "com.example.casein",
                   operation_authority: android_operation_authority!(),
                   node_suffix: "serial_a",
                   sleeper: fn _ -> send(self(), :slept) end
                 ],
                 runner
               )

      assert reason == "force-stop Android app failed"
      refute reason =~ "sensitive child output"
      refute_received :slept

      remaining_commands = restart_recorded_commands()
      refute Enum.any?(remaining_commands, &("chcon" in &1))
      refute Enum.any?(remaining_commands, &("start" in &1))
    end

    test "requires an exact bounded Status: ok launch marker" do
      for launch_output <- [
            "",
            "Starting: Intent",
            "Status: okay",
            "Status: ok\nError: bad",
            "Status: ok\nStatus: ok",
            "Status: ok\nStatus: timeout"
          ] do
        runner = fn args ->
          if "start" in args, do: {:ok, launch_output}, else: {:ok, ""}
        end

        assert {:error, reason} =
                 Deployer.restart_android(
                   "serial-a",
                   [
                     package: "com.example.casein",
                     operation_authority: android_operation_authority!(),
                     node_suffix: "serial_a",
                     sleeper: fn _ -> :ok end
                   ],
                   runner
                 )

        assert reason =~ "no success status"
      end

      runner = fn args ->
        if "start" in args, do: {:ok, "Status: ok\nLaunchState: COLD\n"}, else: {:ok, ""}
      end

      assert :ok =
               Deployer.restart_android(
                 "serial-a",
                 [
                   package: "com.example.casein",
                   operation_authority: android_operation_authority!(),
                   node_suffix: "serial_a",
                   sleeper: fn _ -> :ok end
                 ],
                 runner
               )

      exact_limit = "Status: ok\n" <> String.duplicate("x", 4_085)
      assert byte_size(exact_limit) == 4_096

      runner = fn args ->
        if "start" in args, do: {:ok, exact_limit}, else: {:ok, ""}
      end

      assert :ok =
               Deployer.restart_android(
                 "serial-a",
                 [
                   package: "com.example.casein",
                   operation_authority: android_operation_authority!(),
                   node_suffix: "serial_a",
                   sleeper: fn _ -> :ok end
                 ],
                 runner
               )

      for invalid_output <- [exact_limit <> "x", <<"Status: ok\n", 255>>] do
        runner = fn args ->
          if "start" in args, do: {:ok, invalid_output}, else: {:ok, ""}
        end

        assert {:error, reason} =
                 Deployer.restart_android(
                   "serial-a",
                   [
                     package: "com.example.casein",
                     operation_authority: android_operation_authority!(),
                     node_suffix: "serial_a",
                     sleeper: fn _ -> :ok end
                   ],
                   runner
                 )

        assert reason =~ "invalid adb output"
      end
    end

    test "rejects shell-significant launch options before runner or sleeper" do
      for opts <- [
            [package: "com.example.bad;id", node_suffix: "serial_a"],
            [package: "com.example.casein", activity: ".Main$Activity", node_suffix: "serial_a"],
            [package: "com.example.casein", activity: ".MainActivity'", node_suffix: "serial_a"],
            [package: "com.example.casein", node_suffix: "bad;suffix"]
          ] do
        runner = fn args ->
          send(self(), {:restart_command, args})
          {:ok, "Status: ok\n"}
        end

        opts = Keyword.put(opts, :sleeper, fn _ -> send(self(), :slept) end)
        assert {:error, _reason} = Deployer.restart_android("serial-a", opts, runner)
        refute_received {:restart_command, _}
        refute_received :slept
      end
    end

    test "rejects an unsafe serial before suffix derivation or runner invocation" do
      runner = fn args ->
        send(self(), {:restart_command, args})
        {:ok, "Status: ok\n"}
      end

      assert {:error, "Invalid adb serial; refusing BEAM delivery"} =
               Deployer.restart_android("-serial-a", [sleeper: fn _ -> :ok end], runner)

      refute_received {:restart_command, _}
    end
  end

  defp android_beam_runner(owner, failure \\ nil) do
    fn args ->
      send(owner, {:adb_command, args})

      cond do
        failure == :push and "push" in args ->
          {:error, "push failed"}

        failure == :mkdir and Enum.any?(args, &String.contains?(&1, "mkdir -p")) ->
          {:error, "mkdir failed"}

        failure == :extract and Enum.any?(args, &String.contains?(&1, "tar xof")) ->
          {:error, "extract failed"}

        failure == :verify and Enum.any?(args, &String.contains?(&1, "test -r")) ->
          {:error, "verify failed: sensitive child output"}

        failure == :activate and Enum.any?(args, &String.contains?(&1, "had_live=0")) ->
          {:error, "activate failed: sensitive child output"}

        true ->
          {:ok, ""}
      end
    end
  end

  defp android_payload_fixture!(dir) do
    apk = Path.join(dir, "source.apk")
    File.write!(apk, "immutable-apk")

    beam_dir = Path.join(dir, "beam-source")
    File.mkdir_p!(beam_dir)
    source_beam = :code.which(MobDev.Deployer) |> List.to_string()
    File.cp!(source_beam, Path.join(beam_dir, "Elixir.MobDev.Deployer.beam"))

    apk_bytes = File.read!(apk)

    context = %{
      apk: apk,
      apk_sha256: :crypto.hash(:sha256, apk_bytes) |> Base.encode16(case: :lower),
      apk_size: byte_size(apk_bytes),
      bundle_id: "com.example.casein",
      serials: ["serial-a"],
      selected_abis: ["arm64-v8a"],
      selected_abis_by_serial: %{"serial-a" => "arm64-v8a"}
    }

    opts = [
      attempt_id: "payloadtest00001",
      beam_dirs: [beam_dir],
      priv_dir: nil,
      exqlite_source: nil,
      tmp_root: dir,
      restart: true,
      beam_flags: "+S 1:1",
      dist_port: 9_100,
      node_suffix_resolver: fn "serial-a" -> "serial_a" end
    ]

    {context, opts}
  end

  defp alternate_deployer_beam! do
    forms = [
      {:attribute, 1, :module, MobDev.Deployer},
      {:attribute, 1, :export, [{:staged_snapshot_marker, 0}]},
      {:function, 1, :staged_snapshot_marker, 0,
       [{:clause, 1, [], [], [{:atom, 1, :mutated_live_source}]}]}
    ]

    assert {:ok, MobDev.Deployer, binary} = :compile.forms(forms, [:return_errors])
    binary
  end

  defp fast_deploy_test_opts(dir) do
    beam_dir = Path.join(dir, "fast-beam-source")
    File.mkdir_p!(beam_dir)
    source_beam = :code.which(MobDev.Deployer) |> List.to_string()
    File.cp!(source_beam, Path.join(beam_dir, "Elixir.MobDev.Deployer.beam"))
    package = MobDev.Config.bundle_id()

    [
      android_package_runner: fn _args -> {"package:#{package}\n", 0} end,
      android_lock_runner: successful_android_lock_runner(),
      beam_dirs: [beam_dir],
      priv_dir: nil,
      exqlite_source: nil,
      tmp_root: dir,
      node_suffix_resolver: fn serial ->
        serial |> String.downcase() |> String.replace("-", "_")
      end
    ]
  end

  defp installed_package_runner do
    package = MobDev.Config.bundle_id()
    fn _args -> {"package:#{package}\n", 0} end
  end

  defp successful_android_lock_runner do
    {:ok, state} = Agent.start_link(fn -> %{} end)

    fn ["-s", serial, "shell", command] ->
      cond do
        String.contains?(command, "printf %s \"") ->
          record =
            Regex.scan(Regex.compile!(~S|printf %s "([^"]+)"|), command)
            |> List.last()
            |> List.last()

          Agent.update(state, &Map.put(&1, serial, record))
          {"", 0}

        String.contains?(command, ".mob_native_deploy_releasing_") and
            String.ends_with?(command, "/record'") ->
          {Agent.get(state, &Map.get(&1, serial, "")), 0}

        String.ends_with?(command, ".mob_native_deploy_lock/record'") ->
          {Agent.get(state, &Map.get(&1, serial, "")), 0}

        true ->
          {"", 0}
      end
    end
  end

  defp android_operation_authority!(serial \\ "serial-a") do
    cache_key = {:android_operation_authority, serial}

    case Process.get(cache_key) do
      nil ->
        root =
          Path.join(
            System.tmp_dir!(),
            "mob_deployer_authority_#{System.unique_integer([:positive, :monotonic])}"
          )

        File.mkdir_p!(root)
        {context, opts} = android_payload_fixture!(root)

        attempt_id =
          System.unique_integer([:positive, :monotonic])
          |> Integer.to_string(36)
          |> String.pad_leading(16, "0")
          |> String.slice(-16, 16)

        context = %{
          context
          | serials: [serial],
            selected_abis_by_serial: %{serial => "arm64-v8a"}
        }

        opts =
          opts
          |> Keyword.put(:attempt_id, attempt_id)
          |> Keyword.put(:node_suffix_resolver, fn _serial -> "serial_a" end)

        assert {:ok, plan} = Deployer.prepare_android_payload(context, opts)
        serials = [serial]
        digest = :crypto.hash(:sha256, Enum.join(serials, <<0>>)) |> Base.encode16(case: :lower)

        lease = %{
          bundle_id: context.bundle_id,
          owner: "testauthority001",
          serials: serials,
          target_digest: digest,
          phase: :native_ready,
          state: :held_success
        }

        record = "1|#{lease.owner}|#{lease.target_digest}|native_ready"
        lock_runner = fn _args -> {record, 0} end
        authority = {plan, %{package: context.bundle_id, serials: serials}, lease, lock_runner}
        Process.put(cache_key, authority)
        on_exit(fn -> File.rm_rf(root) end)
        authority

      authority ->
        authority
    end
  end

  defp exqlite_fixture!(dir) do
    ebin = Path.join(dir, "exqlite-ebin")
    File.mkdir_p!(ebin)

    File.write!(
      Path.join(ebin, "exqlite.app"),
      ~s|{application,exqlite,[{vsn,"0.35.0"}]}.
|
    )

    File.write!(Path.join(ebin, "Elixir.Exqlite.beam"), "beam")
    ebin
  end

  defp android_exqlite_runner(owner, failure \\ nil) do
    fn args ->
      send(owner, {:adb_command, args})

      if failure == :activate and adb_command_contains?([args], "had_live=0") do
        {:error, "sensitive child output"}
      else
        {:ok, ""}
      end
    end
  end

  defp deployer_recorded_commands(commands \\ []) do
    receive do
      {:adb_command, args} -> deployer_recorded_commands([args | commands])
    after
      0 -> Enum.reverse(commands)
    end
  end

  defp restart_recorded_commands(commands \\ []) do
    receive do
      {:restart_command, args} -> restart_recorded_commands([args | commands])
    after
      0 -> Enum.reverse(commands)
    end
  end

  defp recorded_lease_commands(commands \\ []) do
    receive do
      {:lease_command, args} -> recorded_lease_commands([args | commands])
    after
      0 -> Enum.reverse(commands)
    end
  end

  defp flush_local_commands do
    receive do
      {:local_command, _, _} -> flush_local_commands()
    after
      0 -> :ok
    end
  end

  defp recorded_local_commands(commands \\ []) do
    receive do
      {:local_command, executable, args} ->
        recorded_local_commands([{executable, args} | commands])
    after
      0 -> Enum.reverse(commands)
    end
  end

  defp adb_command_contains?(commands, needle) do
    Enum.any?(commands, fn args ->
      Enum.any?(args, &String.contains?(&1, needle))
    end)
  end
end
