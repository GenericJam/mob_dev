defmodule MobDev.HotPushTest do
  use ExUnit.Case, async: true

  alias MobDev.HotPush

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "mob_hot_push_test_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{tmp_root: root}
  end

  # ── snapshot_beams/0 ─────────────────────────────────────────────────────────

  describe "snapshot_beams/0" do
    test "returns a non-empty map" do
      assert map_size(HotPush.snapshot_beams()) > 0
    end

    test "all keys are .beam paths" do
      HotPush.snapshot_beams()
      |> Map.keys()
      |> Enum.each(fn path -> assert String.ends_with?(path, ".beam") end)
    end

    test "all values are integer mtimes" do
      HotPush.snapshot_beams()
      |> Map.values()
      |> Enum.each(fn mtime -> assert is_integer(mtime) end)
    end
  end

  # ── push_changed/2 ───────────────────────────────────────────────────────────

  describe "push_changed/2" do
    test "returns {0, []} when nothing changed since snapshot" do
      snapshot = HotPush.snapshot_beams()
      # Snapshot taken, no compile ran — nothing should differ.
      assert {0, []} = HotPush.push_changed([], snapshot)
    end

    test "detects beam files not in snapshot (empty snapshot)" do
      # Empty snapshot means every runtime beam is "new".
      # push_changed only counts runtime deps — not dev-only deps like mob_dev itself.
      {pushed, failed} = HotPush.push_changed([], %{})
      assert failed == []
      assert pushed > 0
    end

    test "does not push files that haven't changed" do
      snapshot = HotPush.snapshot_beams()
      # Immediately re-check — mtimes are identical, so nothing should be pushed.
      {pushed, _} = HotPush.push_changed([], snapshot)
      assert pushed == 0
    end

    test "returns ok with no nodes (no RPC attempted)" do
      snapshot = HotPush.snapshot_beams()
      # Even with an empty node list, must not raise.
      assert {_pushed, _failed} = HotPush.push_changed([], snapshot)
    end
  end

  # ── push_all/1 ───────────────────────────────────────────────────────────────

  describe "push_all/1" do
    test "returns {count, []} with no nodes" do
      {pushed, failed} = HotPush.push_all([])
      assert is_integer(pushed)
      assert failed == []
    end

    test "push count is less than total beam files in _build" do
      # push_all only pushes runtime deps — dev-only deps (mob_dev itself, Bandit,
      # Phoenix, etc.) must be excluded even though their BEAMs are in _build/dev.
      total_beams = Path.wildcard("_build/dev/lib/*/ebin/*.beam") |> length()
      {pushed, _} = HotPush.push_all([])
      assert pushed > 0
      assert pushed < total_beams
    end
  end

  describe "immutable prepared snapshots" do
    test "loads the exact captured bytes after the source is replaced", %{tmp_root: root} do
      {path, original} = write_loaded_beam(root, MobDev.Device)
      assert {:ok, [prepared]} = HotPush.prepare([path])

      File.write!(path, "replaced after snapshot")

      rpc = fn _node, module, filename, binary ->
        assert module == MobDev.Device
        assert filename == String.to_charlist(path)
        assert binary == original
        {:module, module}
      end

      assert {1, []} = HotPush.push_prepared([:"ios_snapshot@127.0.0.1"], [prepared], rpc)
    end

    test "rejects malformed BEAMs, duplicate paths, and module/path mismatch", %{
      tmp_root: root
    } do
      malformed = Path.join(root, "Malformed.beam")
      File.write!(malformed, "not a beam")
      assert {:error, _bounded} = HotPush.prepare([malformed])

      {path, _binary} = write_loaded_beam(root, MobDev.Device)
      assert {:error, _bounded} = HotPush.prepare([path, path])

      wrong_name = Path.join(root, "Wrong.Module.beam")
      File.cp!(path, wrong_name)
      assert {:error, _bounded} = HotPush.prepare([wrong_name])
    end

    test "pure validation rejects tampered bytes, hash, module, and extra identity", %{
      tmp_root: root
    } do
      {path, _binary} = write_loaded_beam(root, MobDev.Device)
      assert {:ok, [prepared]} = HotPush.prepare([path])
      assert :ok = HotPush.validate_prepared_snapshot([prepared])

      assert {:error, _reason} =
               HotPush.validate_prepared_snapshot([%{prepared | binary: prepared.binary <> "x"}])

      assert {:error, _reason} =
               HotPush.validate_prepared_snapshot([
                 %{prepared | sha256: :crypto.hash(:sha256, "forged")}
               ])

      assert {:error, _reason} =
               HotPush.validate_prepared_snapshot([%{prepared | module: MobDev.Tunnel}])

      assert {:error, _reason} =
               HotPush.validate_prepared_snapshot([Map.put(prepared, :extra, true)])
    end

    test "fails closed on badrpc, on-load failure, mismatch, and stops at first ambiguity", %{
      tmp_root: root
    } do
      {path_a, _binary_a} = write_loaded_beam(root, MobDev.Device)
      {path_b, _binary_b} = write_loaded_beam(root, MobDev.Tunnel)
      assert {:ok, snapshot} = HotPush.prepare([path_b, path_a])

      for {reply, category} <- [
            {{:badrpc, :lost}, :badrpc},
            {{:error, :on_load_failure}, :on_load_failure},
            {{:module, MobDev.Tunnel}, :unexpected_reply},
            {:unexpected, :unexpected_reply}
          ] do
        {:ok, calls} = Agent.start_link(fn -> [] end)

        rpc = fn node, module, _filename, binary ->
          Agent.update(calls, &[{node, module, :crypto.hash(:sha256, binary)} | &1])
          reply
        end

        [first | _] = snapshot

        assert {0, [{module, [{:"node-a@127.0.0.1", ^category}]}]} =
                 HotPush.push_prepared([:"node-a@127.0.0.1", :"node-b@127.0.0.1"], snapshot, rpc)

        assert module == first.module
        assert Agent.get(calls, &Enum.reverse/1) |> length() == 1
      end
    end
  end

  describe "ordinary Android hot-push lease" do
    test "raw prepared APIs reject Android-looking nodes before RPC", %{tmp_root: root} do
      {path, _binary} = write_loaded_beam(root, MobDev.Device)
      assert {:ok, snapshot} = HotPush.prepare([path])

      assert {0, [{:android_deploy_lock, :required}]} =
               HotPush.push_prepared([android_node()], snapshot, fn _, _, _, _ ->
                 flunk("raw Android RPC must be fenced")
               end)
    end

    test "acquires, proves, commits, and releases around exact RPC bytes", %{tmp_root: root} do
      {path, _binary} = write_loaded_beam(root, MobDev.Device)
      assert {:ok, snapshot} = HotPush.prepare([path])
      {runner, state} = lock_runner()
      node = android_node()
      {:ok, rpc_calls} = Agent.start_link(fn -> 0 end)

      rpc = fn ^node, module, _filename, binary ->
        Agent.update(rpc_calls, &(&1 + 1))
        assert :crypto.hash(:sha256, binary) == hd(snapshot).sha256
        {:module, module}
      end

      assert {1, []} =
               HotPush.push_prepared_fenced([node], snapshot,
                 package: "com.example.casein",
                 android_devices: [%{platform: :android, node: node, serial: "serial-a"}],
                 lock_runner: runner,
                 rpc: rpc
               )

      assert Agent.get(rpc_calls, & &1) == 1

      final = Agent.get(state, & &1)
      assert final.fixed == nil
      assert final.tombstone == nil
      assert Enum.any?(final.commands, &String.contains?(&1, "|fast_committed"))
      assert Enum.any?(final.commands, &exact_tombstone_cleanup?/1)
      refute Enum.any?(final.commands, &String.contains?(&1, "rm -rf"))
    end

    test "known lock block and unknown Android mapping perform zero RPC or mutation", %{
      tmp_root: root
    } do
      {path, _binary} = write_loaded_beam(root, MobDev.Device)
      assert {:ok, snapshot} = HotPush.prepare([path])
      node = android_node()
      {:ok, calls} = Agent.start_link(fn -> [] end)

      blocked_runner = fn args ->
        Agent.update(calls, &[args | &1])
        {"blocked", 1}
      end

      rpc = fn _node, _module, _filename, _binary ->
        flunk("RPC must not run before an exact lease is held")
      end

      assert {0, [{:android_deploy_lock, :unavailable}]} =
               HotPush.push_prepared_fenced([node], snapshot,
                 package: "com.example.casein",
                 android_devices: [%{platform: :android, node: node, serial: "serial-a"}],
                 lock_runner: blocked_runner,
                 rpc: rpc
               )

      refute Agent.get(calls, & &1)
             |> Enum.any?(fn args -> List.last(args) |> String.contains?("mkdir ") end)

      assert {0, [{:android_deploy_lock, :target_ambiguous}]} =
               HotPush.push_prepared_fenced([node], snapshot,
                 package: "com.example.casein",
                 android_devices: [],
                 lock_runner: blocked_runner,
                 rpc: rpc
               )
    end

    test "RPC ambiguity retains the acquired fixed lease and stops", %{tmp_root: root} do
      {path, _binary} = write_loaded_beam(root, MobDev.Device)
      assert {:ok, snapshot} = HotPush.prepare([path])
      {runner, state} = lock_runner()
      node = android_node()

      assert {0, [{MobDev.Device, [{^node, :badrpc}]}, {:android_deploy_lock, :retained}]} =
               HotPush.push_prepared_fenced([node], snapshot,
                 package: "com.example.casein",
                 android_devices: [%{platform: :android, node: node, serial: "serial-a"}],
                 lock_runner: runner,
                 rpc: fn _node, _module, _filename, _binary -> {:badrpc, :lost} end
               )

      final = Agent.get(state, & &1)

      assert final.fixed =~
               ~r/\A1\|[A-Za-z0-9_-]{16}\|[0-9a-f]{64}\|acquired\z/

      assert final.tombstone == nil
      refute Enum.any?(final.commands, &String.contains?(&1, "rm -rf"))
    end

    test "RPC throw is bounded and retains the exact acquired lease", %{tmp_root: root} do
      {path, _binary} = write_loaded_beam(root, MobDev.Device)
      assert {:ok, snapshot} = HotPush.prepare([path])
      {runner, state} = lock_runner()
      node = android_node()

      assert {0, [{MobDev.Device, [{^node, :load_failed}]}, {:android_deploy_lock, :retained}]} =
               HotPush.push_prepared_fenced([node], snapshot,
                 package: "com.example.casein",
                 android_devices: [%{platform: :android, node: node, serial: "serial-a"}],
                 lock_runner: runner,
                 rpc: fn _node, _module, _filename, _binary -> throw(:transport_lost) end
               )

      final = Agent.get(state, & &1)

      assert final.fixed =~
               ~r/\A1\|[A-Za-z0-9_-]{16}\|[0-9a-f]{64}\|acquired\z/

      assert final.tombstone == nil
    end

    test "partial Android module delivery reports zero success and retains authority", %{
      tmp_root: root
    } do
      {path_a, _binary_a} = write_loaded_beam(root, MobDev.Device)
      {path_b, _binary_b} = write_loaded_beam(root, MobDev.Tunnel)
      assert {:ok, snapshot} = HotPush.prepare([path_a, path_b])
      {runner, state} = lock_runner()
      node = android_node()
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      rpc = fn ^node, module, _filename, _binary ->
        call = Agent.get_and_update(calls, &{&1 + 1, &1 + 1})
        if call == 1, do: {:module, module}, else: {:badrpc, :lost}
      end

      assert {0, [failure, {:android_deploy_lock, :retained}]} =
               HotPush.push_prepared_fenced([node], snapshot,
                 package: "com.example.casein",
                 android_devices: [%{platform: :android, node: node, serial: "serial-a"}],
                 lock_runner: runner,
                 rpc: rpc
               )

      assert {_module, [{^node, :badrpc}]} = failure
      assert Agent.get(calls, & &1) == 2

      final = Agent.get(state, & &1)
      assert String.ends_with?(final.fixed, "|acquired")
      assert final.tombstone == nil
      refute Enum.any?(final.commands, &String.contains?(&1, "rm -rf"))
    end

    test "transition and release ambiguity report zero success and retain recovery state", %{
      tmp_root: root
    } do
      {path, _binary} = write_loaded_beam(root, MobDev.Device)
      assert {:ok, snapshot} = HotPush.prepare([path])
      node = android_node()

      {transition_runner, transition_state} = lock_runner()

      ambiguous_transition = fn args ->
        if List.last(args) |> String.contains?("record_next_") do
          {"lost", 1}
        else
          transition_runner.(args)
        end
      end

      assert {0,
              [
                {:android_deploy_lock, :transition_ambiguous},
                {:android_deploy_lock, :retained}
              ]} =
               HotPush.push_prepared_fenced([node], snapshot,
                 package: "com.example.casein",
                 android_devices: [%{platform: :android, node: node, serial: "serial-a"}],
                 lock_runner: ambiguous_transition,
                 rpc: fn _node, module, _filename, _binary -> {:module, module} end
               )

      transition_final = Agent.get(transition_state, & &1)
      assert String.ends_with?(transition_final.fixed, "|acquired")
      assert transition_final.tombstone == nil

      {release_runner, release_state} = lock_runner()

      ambiguous_release = fn args ->
        if tombstone_record_proof?(List.last(args)) do
          {"lost", 1}
        else
          release_runner.(args)
        end
      end

      assert {0,
              [
                {:android_deploy_lock, :release_ambiguous},
                {:android_deploy_lock, :retained}
              ]} =
               HotPush.push_prepared_fenced([node], snapshot,
                 package: "com.example.casein",
                 android_devices: [%{platform: :android, node: node, serial: "serial-a"}],
                 lock_runner: ambiguous_release,
                 rpc: fn _node, module, _filename, _binary -> {:module, module} end
               )

      release_final = Agent.get(release_state, & &1)
      assert release_final.fixed == nil
      assert String.ends_with?(release_final.tombstone, "|fast_committed")
      refute Enum.any?(release_final.commands, &String.contains?(&1, "rm -rf"))
    end

    test "fenced post-push runs once per Android target before commit and release", %{
      tmp_root: root
    } do
      {path, _binary} = write_loaded_beam(root, MobDev.Device)
      assert {:ok, snapshot} = HotPush.prepare([path])
      {runner, state} = lock_runner()
      node = android_node()
      {:ok, callbacks} = Agent.start_link(fn -> [] end)

      post_push = fn ^node ->
        held = Agent.get(state, & &1)
        assert String.ends_with?(held.fixed, "|acquired")
        assert held.tombstone == nil
        Agent.update(callbacks, &[node | &1])
        :ok
      end

      assert {1, []} =
               HotPush.push_prepared_fenced([node], snapshot,
                 package: "com.example.casein",
                 android_devices: [%{platform: :android, node: node, serial: "serial-a"}],
                 lock_runner: runner,
                 rpc: fn _node, module, _filename, _binary -> {:module, module} end,
                 post_push: post_push
               )

      assert Agent.get(callbacks, &Enum.reverse/1) == [node]
      assert %{fixed: nil, tombstone: nil} = Agent.get(state, & &1)
    end

    test "post-push ambiguity reports zero and retains the uncommitted lease", %{
      tmp_root: root
    } do
      {path, _binary} = write_loaded_beam(root, MobDev.Device)
      assert {:ok, snapshot} = HotPush.prepare([path])
      {runner, state} = lock_runner()
      node = android_node()

      assert {0,
              [
                {:android_post_push, :ambiguous},
                {:android_deploy_lock, :retained}
              ]} =
               HotPush.push_prepared_fenced([node], snapshot,
                 package: "com.example.casein",
                 android_devices: [%{platform: :android, node: node, serial: "serial-a"}],
                 lock_runner: runner,
                 rpc: fn _node, module, _filename, _binary -> {:module, module} end,
                 post_push: fn ^node -> throw(:reply_lost) end
               )

      final = Agent.get(state, & &1)
      assert String.ends_with?(final.fixed, "|acquired")
      assert final.tombstone == nil
      refute Enum.any?(final.commands, &String.contains?(&1, "record_next_"))
    end

    test "exact lease target equality rejects empty, subset, superset, iOS-only, and mixed requests before RPC",
         %{tmp_root: root} do
      {path, _binary} = write_loaded_beam(root, MobDev.Device)
      assert {:ok, snapshot} = HotPush.prepare([path])
      node_a = android_node("a")
      node_b = android_node("b")
      ios_node = :"ios-test@127.0.0.1"

      cases = [
        {
          [],
          [],
          existing_lease(["serial-a"], :native_ready)
        },
        {
          [node_a],
          [%{platform: :android, node: node_a, serial: "serial-a"}],
          existing_lease(["serial-a", "serial-b"], :native_ready)
        },
        {
          [node_a, node_b],
          [
            %{platform: :android, node: node_a, serial: "serial-a"},
            %{platform: :android, node: node_b, serial: "serial-b"}
          ],
          existing_lease(["serial-a"], :native_ready)
        },
        {
          [ios_node],
          [],
          existing_lease(["serial-a"], :native_ready)
        },
        {
          [node_a, ios_node],
          [%{platform: :android, node: node_a, serial: "serial-a"}],
          existing_lease(["serial-a"], :native_ready)
        }
      ]

      Enum.each(cases, fn {nodes, devices, lease} ->
        assert {0,
                [
                  {:android_deploy_lock, :authority_ambiguous},
                  {:android_deploy_lock, :retained}
                ]} =
                 HotPush.push_prepared_fenced(nodes, snapshot,
                   package: "com.example.casein",
                   android_devices: devices,
                   android_deploy_lock: lease,
                   expected_lock_phase: :native_ready,
                   lock_runner: fn _args -> flunk("invalid exact-set request must not probe") end,
                   rpc: fn _, _, _, _ -> flunk("invalid exact-set request must not RPC") end
                 )
      end)
    end

    test "mixed ordinary push releases Android before iOS and reports later iOS partial as zero",
         %{tmp_root: root} do
      {path_a, _binary_a} = write_loaded_beam(root, MobDev.Device)
      {path_b, _binary_b} = write_loaded_beam(root, MobDev.Tunnel)
      assert {:ok, snapshot} = HotPush.prepare([path_a, path_b])
      {runner, state} = lock_runner()
      android = android_node()
      ios = :"ios-test@127.0.0.1"
      {:ok, calls} = Agent.start_link(fn -> [] end)
      {:ok, ios_count} = Agent.start_link(fn -> 0 end)

      rpc = fn node, module, _filename, _binary ->
        Agent.update(calls, &[node | &1])

        if node == ios do
          released = Agent.get(state, & &1)
          assert released.fixed == nil
          assert released.tombstone == nil
          call = Agent.get_and_update(ios_count, &{&1 + 1, &1 + 1})
          if call == 1, do: {:module, module}, else: {:badrpc, :lost}
        else
          {:module, module}
        end
      end

      assert {0, [failure, {:hot_push, :partial_after_android_commit}]} =
               HotPush.push_prepared_fenced([ios, android], snapshot,
                 package: "com.example.casein",
                 android_devices: [
                   %{platform: :android, node: android, serial: "serial-a"}
                 ],
                 lock_runner: runner,
                 rpc: rpc
               )

      assert {_module, [{^ios, :badrpc}]} = failure
      assert Agent.get(calls, &Enum.reverse/1) == [android, android, ios, ios]
      assert %{fixed: nil, tombstone: nil} = Agent.get(state, & &1)
    end

    test "a target-set authority flip before target B prevents B post-push callback", %{
      tmp_root: root
    } do
      {path, _binary} = write_loaded_beam(root, MobDev.Device)
      assert {:ok, snapshot} = HotPush.prepare([path])
      node_a = android_node("a")
      node_b = android_node("b")
      lease = existing_lease(["serial-a", "serial-b"], :native_ready)
      record = expected_lock_record(lease)
      {:ok, a_proofs} = Agent.start_link(fn -> 0 end)
      {:ok, callbacks} = Agent.start_link(fn -> [] end)

      runner = fn ["-s", serial, "shell", _command] ->
        if serial == "serial-a" do
          proof_number = Agent.get_and_update(a_proofs, &{&1 + 1, &1 + 1})
          if proof_number <= 4, do: {record, 0}, else: {"flipped", 0}
        else
          {record, 0}
        end
      end

      assert {0,
              [
                {:android_post_push, :ambiguous},
                {:android_deploy_lock, :retained}
              ]} =
               HotPush.push_prepared_fenced([node_a, node_b], snapshot,
                 package: "com.example.casein",
                 android_devices: [
                   %{platform: :android, node: node_a, serial: "serial-a"},
                   %{platform: :android, node: node_b, serial: "serial-b"}
                 ],
                 android_deploy_lock: lease,
                 expected_lock_phase: :native_ready,
                 lock_runner: runner,
                 rpc: fn _node, module, _filename, _binary -> {:module, module} end,
                 post_push: fn node ->
                   Agent.update(callbacks, &[node | &1])
                   :ok
                 end
               )

      assert Agent.get(callbacks, &Enum.reverse/1) == [node_a]
    end

    test "post-push callback without an Android lease is rejected before invocation", %{
      tmp_root: root
    } do
      {path, _binary} = write_loaded_beam(root, MobDev.Device)
      assert {:ok, snapshot} = HotPush.prepare([path])

      assert {0, [{:android_post_push, :requires_android_lease}]} =
               HotPush.push_prepared_fenced([:"ios-test@127.0.0.1"], snapshot,
                 rpc: fn _, _, _, _ -> flunk("RPC must not run") end,
                 post_push: fn _node -> flunk("callback must not run") end
               )
    end

    test "a full-set owner flip after target A prevents every RPC to target B", %{
      tmp_root: root
    } do
      {path, _binary} = write_loaded_beam(root, MobDev.Device)
      assert {:ok, snapshot} = HotPush.prepare([path])
      node_a = android_node("a")
      node_b = android_node("b")
      lease = existing_lease(["serial-a", "serial-b"], :native_ready)
      record = expected_lock_record(lease)
      {:ok, a_proofs} = Agent.start_link(fn -> 0 end)
      {:ok, rpc_nodes} = Agent.start_link(fn -> [] end)

      runner = fn ["-s", serial, "shell", _command] ->
        if serial == "serial-a" do
          proof_number = Agent.get_and_update(a_proofs, &{&1 + 1, &1 + 1})
          if proof_number <= 2, do: {record, 0}, else: {"flipped", 0}
        else
          {record, 0}
        end
      end

      rpc = fn node, module, _filename, _binary ->
        Agent.update(rpc_nodes, &[node | &1])
        {:module, module}
      end

      assert {0,
              [
                {MobDev.Device, [{^node_b, :authority_ambiguous}]},
                {:android_deploy_lock, :retained}
              ]} =
               HotPush.push_prepared_fenced([node_a, node_b], snapshot,
                 package: "com.example.casein",
                 android_devices: [
                   %{platform: :android, node: node_a, serial: "serial-a"},
                   %{platform: :android, node: node_b, serial: "serial-b"}
                 ],
                 android_deploy_lock: lease,
                 expected_lock_phase: :native_ready,
                 lock_runner: runner,
                 rpc: rpc
               )

      assert Agent.get(rpc_nodes, &Enum.reverse/1) == [node_a]
    end

    test "committed existing leases are non-mutable and perform zero RPC", %{tmp_root: root} do
      {path, _binary} = write_loaded_beam(root, MobDev.Device)
      assert {:ok, snapshot} = HotPush.prepare([path])
      node = android_node()

      for phase <- [:final_committed, :fast_committed] do
        lease = existing_lease(["serial-a"], phase)

        assert {0,
                [
                  {:android_deploy_lock, :authority_ambiguous},
                  {:android_deploy_lock, :retained}
                ]} =
                 HotPush.push_prepared_fenced([node], snapshot,
                   package: "com.example.casein",
                   android_devices: [%{platform: :android, node: node, serial: "serial-a"}],
                   android_deploy_lock: lease,
                   expected_lock_phase: phase,
                   lock_runner: fn _args -> flunk("committed phase must not probe") end,
                   rpc: fn _, _, _, _ -> flunk("committed phase must not mutate") end
                 )
      end
    end
  end

  defp write_loaded_beam(root, module) do
    {:module, ^module} = Code.ensure_loaded(module)
    {^module, binary, _filename} = :code.get_object_code(module)
    path = Path.join(root, "#{module}.beam")
    File.write!(path, binary)
    {path, binary}
  end

  defp android_node(suffix \\ "test") do
    app = Mix.Project.config()[:app]
    String.to_atom("#{app}_android_#{suffix}@127.0.0.1")
  end

  defp existing_lease(serials, phase) do
    serials = Enum.sort(serials)

    %{
      bundle_id: "com.example.casein",
      owner: "ownerproof000001",
      serials: serials,
      target_digest:
        serials
        |> Enum.join(<<0>>)
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower),
      phase: phase,
      state: :held_success
    }
  end

  defp expected_lock_record(lease) do
    "1|#{lease.owner}|#{lease.target_digest}|#{lease.phase}"
  end

  defp lock_runner do
    {:ok, state} = Agent.start_link(fn -> %{fixed: nil, tombstone: nil, commands: []} end)

    runner = fn ["-s", "serial-a", "shell", command] ->
      Agent.get_and_update(state, fn lock ->
        lock = %{lock | commands: lock.commands ++ [command]}

        cond do
          String.contains?(command, "mkdir ") ->
            record = quoted_record(command)
            {{"", 0}, %{lock | fixed: record}}

          String.contains?(command, "record_next_") ->
            record = quoted_record(command)
            {{"", 0}, %{lock | fixed: record}}

          String.contains?(command, "mv ") and
              String.contains?(command, ".mob_native_deploy_releasing_") ->
            {{"", 0}, %{lock | fixed: nil, tombstone: lock.fixed}}

          exact_tombstone_cleanup?(command) ->
            result = if is_binary(lock.tombstone), do: {"", 0}, else: {"", 1}
            next_lock = if result == {"", 0}, do: %{lock | tombstone: nil}, else: lock
            {result, next_lock}

          tombstone_record_proof?(command) ->
            {{lock.tombstone || "", if(is_binary(lock.tombstone), do: 0, else: 1)}, lock}

          fixed_record_proof?(command) ->
            {{lock.fixed || "", if(is_binary(lock.fixed), do: 0, else: 1)}, lock}

          String.contains?(command, "set -e; test ! -e") and
              String.contains?(command, "test -d /data/data/") ->
            result = if is_nil(lock.fixed) and is_nil(lock.tombstone), do: {"", 0}, else: {"", 1}
            {result, lock}

          true ->
            {{"", 1}, lock}
        end
      end)
    end

    {runner, state}
  end

  defp quoted_record(command) do
    Regex.scan(Regex.compile!(~s|printf %s "([^"]+)"|), command)
    |> List.last()
    |> Enum.at(1)
  end

  defp fixed_record_proof?(command) do
    String.ends_with?(command, ".mob_native_deploy_lock/record'") and
      not String.contains?(command, "value=$(cat")
  end

  defp tombstone_record_proof?(command) do
    Regex.match?(
      ~r/cat \/data\/data\/[^ ]+\/files\/\.mob_native_deploy_releasing_[A-Za-z0-9_-]+\/record'\z/,
      command
    ) and not String.contains?(command, "value=$(cat")
  end

  defp exact_tombstone_cleanup?(command) do
    case Regex.run(
           ~r/; rm (\/data\/data\/[^ ;]+\/files\/\.mob_native_deploy_releasing_[A-Za-z0-9_-]+)\/record; rmdir (\/data\/data\/[^ ;']+\/files\/\.mob_native_deploy_releasing_[A-Za-z0-9_-]+)'\z/,
           command,
           capture: :all_but_first
         ) do
      [record_directory, removed_directory] -> record_directory == removed_directory
      _no_exact_cleanup -> false
    end
  end
end
