defmodule MobDev.AndroidDeployRecoveryProofTest do
  # These tests intentionally contend on the production global filesystem lock.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias MobDev.AndroidDeployRecoveryProof

  @bundle "com.example.casein"
  @serial "serial-a"
  @old_owner "oldownerproof001"
  @new_owner "newownerproof001"
  @apk_sha String.duplicate("a", 64)
  @runtime_sha String.duplicate("b", 64)
  @runtime_path "otp/lib/elixir/ebin/Elixir.Kernel.beam"

  test "collects bounded read-only production evidence and immediately resumes with same runner" do
    apk = tmp_apk!()
    runner = runner(self())

    assert {:ok, lease} =
             AndroidDeployRecoveryProof.resume(payload(apk), runner,
               owner: @new_owner,
               minimum_age_seconds: 900,
               runtime_provenance: runtime_provenance(),
               payload_validator: fn _plan -> :ok end,
               host_lock_held?: fn -> true end,
               apk_signature_verified?: fn ^apk -> true end
             )

    assert lease.owner == @new_owner
    assert lease.phase == :native_ready
    assert lease.state == :held_success

    commands = drain_commands([])
    assert Enum.any?(commands, &(&1 == ["devices", "-l"]))
    assert Enum.any?(commands, &read_only_record?/1)
    assert Enum.any?(commands, &installed_digest?/1)
    assert Enum.any?(commands, &runtime_provenance_probe?/1)
    assert Enum.any?(commands, &staging_proof?/1)
    assert Enum.any?(commands, &cas?/1)
    assert Enum.any?(commands, &post_cas_proof?/1)

    first_cas = Enum.find_index(commands, &cas?/1)
    assert Enum.all?(Enum.take(commands, first_cas), &(not mutating_before_cas?(&1)))
  end

  test "refuses any failed proof before CAS" do
    apk = tmp_apk!()

    assert {:error, {:recovery_proof_refused, :host_lock_unavailable}} =
             AndroidDeployRecoveryProof.resume(payload(apk), runner(self()),
               owner: @new_owner,
               payload_validator: fn _plan -> :ok end,
               host_lock_held?: fn -> false end,
               apk_signature_verified?: fn _path -> true end
             )

    commands = drain_commands([])
    refute Enum.any?(commands, &cas?/1)
  end

  test "refuses unsafe package and serial identity before invoking adb" do
    apk = tmp_apk!()

    for invalid_payload <- [
          put_in(payload(apk).package, "com.example.casein;id"),
          put_in(payload(apk).serials, ["serial-a\nother-device"]),
          put_in(payload(apk).apk.sha256, String.duplicate("A", 64))
        ] do
      assert {:error, {:recovery_proof_refused, :payload_identity_invalid}} =
               AndroidDeployRecoveryProof.resume(invalid_payload, runner(self()),
                 payload_validator: fn _plan -> :ok end,
                 host_lock_held?: fn -> true end,
                 apk_signature_verified?: fn _path -> true end
               )
    end

    refute_receive {:command, _args}
  end

  test "requires exactly one USB target and refuses network adb" do
    apk = tmp_apk!()

    runner = fn
      ["devices", "-l"] -> {"List of devices attached\n#{@serial}:5555 device product:x\n", 0}
      args -> send(self(), {:command, args}) && {"", 0}
    end

    assert {:error, {:recovery_proof_refused, :transport_identity_mismatch}} =
             AndroidDeployRecoveryProof.resume(payload(apk), runner,
               owner: @new_owner,
               payload_validator: fn _plan -> :ok end,
               host_lock_held?: fn -> true end,
               apk_signature_verified?: fn _path -> true end
             )

    refute_receive {:command, _args}
  end

  test "refuses an unsafe installed APK path before digest or CAS" do
    apk = tmp_apk!()
    base_runner = runner(self())

    runner = fn args ->
      case args do
        ["-s", @serial, "shell", "pm path " <> @bundle] ->
          send(self(), {:command, args})
          {"package:/data/app/example;touch${IFS}/tmp/pwn/base.apk\n", 0}

        _other ->
          base_runner.(args)
      end
    end

    assert {:error, {:recovery_proof_refused, :apk_identity_mismatch}} =
             AndroidDeployRecoveryProof.resume(payload(apk), runner,
               owner: @new_owner,
               runtime_provenance: runtime_provenance(),
               payload_validator: fn _plan -> :ok end,
               host_lock_held?: fn -> true end,
               apk_signature_verified?: fn _path -> true end
             )

    commands = drain_commands([])
    refute Enum.any?(commands, &installed_digest?/1)
    refute Enum.any?(commands, &cas?/1)
  end

  test "refuses missing or mismatched device runtime provenance before CAS" do
    apk = tmp_apk!()

    for {provenance, runtime_reply} <- [
          {nil, ""},
          {[%{path: "otp/../unsafe", sha256: @runtime_sha}], ""},
          {runtime_provenance(), "#{String.duplicate("c", 64)} #{runtime_device_path()}\n"},
          {runtime_provenance(), ""}
        ] do
      base_runner = runner(self())

      runner = fn args ->
        if runtime_provenance_probe?(args) do
          send(self(), {:command, args})
          {runtime_reply, 0}
        else
          base_runner.(args)
        end
      end

      assert {:error, {:recovery_proof_refused, :runtime_provenance_mismatch}} =
               AndroidDeployRecoveryProof.resume(payload(apk), runner,
                 owner: @new_owner,
                 runtime_provenance: provenance,
                 payload_validator: fn _plan -> :ok end,
                 host_lock_held?: fn -> true end,
                 apk_signature_verified?: fn _path -> true end
               )

      commands = drain_commands([])
      refute Enum.any?(commands, &cas?/1)
    end
  end

  test "refusal diagnostics are fixed enums and never reflect payload, callback, or runner values" do
    secret = "secret-canary-#{System.unique_integer([:positive])}"
    apk = tmp_apk!()
    default_runner = runner(self())

    cases = [
      {put_in(payload(apk).package, secret), default_runner, [], :payload_identity_invalid},
      {payload(apk), default_runner, [payload_validator: fn _ -> raise secret end],
       :payload_invalid},
      {payload(apk), default_runner, [host_lock_held?: fn -> raise secret end],
       :host_lock_unavailable},
      {payload(apk), default_runner,
       [apk_signature_verified?: fn _ -> throw({:secret, secret}) end], :apk_signature_invalid},
      {payload(apk), fn _args -> {secret, 1} end, [], :transport_identity_mismatch}
    ]

    Enum.each(cases, fn {candidate, recovery_runner, overrides, expected_code} ->
      opts =
        [
          owner: @new_owner,
          runtime_provenance: runtime_provenance(),
          payload_validator: fn _ -> :ok end,
          host_lock_held?: fn -> true end,
          apk_signature_verified?: fn _ -> true end
        ]
        |> Keyword.merge(overrides)

      logs =
        capture_log(fn ->
          io =
            capture_io(fn ->
              refusal = AndroidDeployRecoveryProof.resume(candidate, recovery_runner, opts)
              send(self(), {:refusal, refusal})
            end)

          send(self(), {:captured_io, io})
        end)

      assert_receive {:refusal, refusal = {:error, {:recovery_proof_refused, ^expected_code}}}

      assert_receive {:captured_io, io}
      refute inspect(refusal) =~ secret
      refute io =~ secret
      refute logs =~ secret
    end)
  end

  test "operation-wide host lock is exclusive and remains held for the callback" do
    assert :ok =
             AndroidDeployRecoveryProof.with_host_lock(@bundle, fn ->
               assert {:error, :recovery_host_lock_unavailable} =
                        Task.async(fn ->
                          AndroidDeployRecoveryProof.with_host_lock(@bundle, fn -> :wrong end)
                        end)
                        |> Task.await()

               :ok
             end)
  end

  test "a killed BEAM owner is fenced stale and does not permanently block recovery" do
    parent = self()

    owner =
      spawn(fn ->
        AndroidDeployRecoveryProof.with_host_lock(@bundle, fn ->
          send(parent, :lock_acquired)
          receive do: (:release -> :ok)
        end)
      end)

    assert_receive :lock_acquired
    monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, _, :killed}

    assert :recovered ==
             AndroidDeployRecoveryProof.with_host_lock(@bundle, fn -> :recovered end)
  end

  test "a SIGKILLed external VM leaves a provably stale lock that is reclaimed" do
    elixir = System.find_executable("elixir")

    ebin = Path.expand("_build/test/lib/mob_dev/ebin")

    expression = """
    MobDev.AndroidDeployRecoveryProof.with_host_lock(#{inspect(@bundle)}, fn ->
      IO.puts("LOCK_READY")
      Process.sleep(:infinity)
    end)
    """

    port =
      Port.open({:spawn_executable, elixir}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["-pa", ebin, "-e", expression]
      ])

    assert_receive {^port, {:data, output}}, 5_000
    assert output =~ "LOCK_READY"
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    assert {_output, 0} = System.cmd("kill", ["-9", Integer.to_string(os_pid)])
    assert_receive {^port, {:exit_status, _status}}, 5_000

    assert :recovered ==
             AndroidDeployRecoveryProof.with_host_lock(@bundle, fn -> :recovered end)
  end

  test "a hard exit after atomic release rename cannot strand the canonical lock" do
    parent = self()

    owner =
      spawn(fn ->
        :ok =
          AndroidDeployRecoveryProof.__test_only__(:set_release_hook, fn ->
            send(parent, :release_renamed)
            receive do: (:finish_release -> :ok)
          end)

        AndroidDeployRecoveryProof.with_host_lock(@bundle, fn -> :done end)
      end)

    assert_receive :release_renamed
    lock_path = AndroidDeployRecoveryProof.__test_only__(:lock_path, @bundle)
    refute File.exists?(lock_path)
    monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, _, :killed}

    on_exit(fn ->
      for path <- Path.wildcard("#{lock_path}.released.*") do
        File.rm(Path.join(path, "owner.term"))
        File.rmdir(path)
      end
    end)

    assert :recovered ==
             AndroidDeployRecoveryProof.with_host_lock(@bundle, fn -> :recovered end)
  end

  test "PID reuse and boot changes cannot preserve stale ownership" do
    for field <- [:os_start, :boot_id] do
      leave_stale_local_lock!()
      owner_path = lock_owner_path()
      owner = owner_path |> File.read!() |> :erlang.binary_to_term([:safe])

      changed =
        owner
        |> Map.update!(field, fn _value -> String.duplicate("f", 64) end)
        |> then(fn changed ->
          if field == :os_start,
            do: %{changed | vm_id: String.duplicate("e", 64)},
            else: changed
        end)

      File.write!(owner_path, :erlang.term_to_binary(changed))

      assert :recovered ==
               AndroidDeployRecoveryProof.with_host_lock(@bundle, fn -> :recovered end)
    end
  end

  test "two recoverers racing a stale owner admit exactly one operation" do
    leave_stale_local_lock!()
    parent = self()

    contenders =
      for id <- 1..2 do
        Task.async(fn ->
          AndroidDeployRecoveryProof.with_host_lock(@bundle, fn ->
            send(parent, {:entered, id})
            receive do: (:release -> :won)
          end)
        end)
      end

    assert_receive {:entered, winner}
    refute_receive {:entered, _other}, 100
    loser = Enum.find(contenders, &(&1.pid != Enum.at(contenders, winner - 1).pid))
    assert {:error, :recovery_host_lock_unavailable} = Task.await(loser)
    winning_task = Enum.at(contenders, winner - 1)
    send(winning_task.pid, :release)
    assert :won = Task.await(winning_task)
  end

  test "malformed ownership is ambiguous and never stolen" do
    path = AndroidDeployRecoveryProof.__test_only__(:lock_path, @bundle)
    File.mkdir!(path)
    File.write!(Path.join(path, "owner.term"), "malformed")

    on_exit(fn ->
      File.rm(Path.join(path, "owner.term"))
      File.rmdir(path)
    end)

    assert {:error, :recovery_host_lock_unavailable} =
             AndroidDeployRecoveryProof.with_host_lock(@bundle, fn -> :wrong end)
  end

  defp tmp_apk! do
    path = Path.join(System.tmp_dir!(), "mob-recovery-proof-#{System.unique_integer()}.apk")
    File.write!(path, "apk")
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp leave_stale_local_lock! do
    parent = self()

    task =
      spawn(fn ->
        AndroidDeployRecoveryProof.with_host_lock(@bundle, fn ->
          send(parent, :stale_lock_ready)
          receive do: (:release -> :ok)
        end)
      end)

    assert_receive :stale_lock_ready
    monitor = Process.monitor(task)
    Process.exit(task, :kill)
    assert_receive {:DOWN, ^monitor, :process, _, :killed}
  end

  defp lock_owner_path do
    AndroidDeployRecoveryProof.__test_only__(:lock_path, @bundle)
    |> Path.join("owner.term")
  end

  defp payload(apk) do
    %{
      version: 1,
      package: @bundle,
      serials: [@serial],
      apk: %{path: apk, sha256: @apk_sha}
    }
  end

  defp runner(test_pid) do
    digest = :crypto.hash(:sha256, @serial) |> Base.encode16(case: :lower)
    old_record = "1|#{@old_owner}|#{digest}|native_ready"
    new_record = "1|#{@new_owner}|#{digest}|native_ready"

    fn args ->
      send(test_pid, {:command, args})
      command = List.last(args)

      cond do
        args == ["devices", "-l"] ->
          {"List of devices attached\n#{@serial} device usb:1-1 product:x\n", 0}

        String.contains?(command, "getprop service.adb.tcp.port") ->
          {"-1|-1", 0}

        read_only_record?(args) ->
          {"#{old_record}\n100\n3700\n", 0}

        String.starts_with?(command, "pm path ") ->
          {"package:/data/app/example/base.apk\n", 0}

        String.starts_with?(command, "sha256sum ") ->
          {"#{@apk_sha} /data/app/example/base.apk\n", 0}

        runtime_provenance_probe?(args) ->
          {"#{@runtime_sha} #{runtime_device_path()}\n", 0}

        staging_proof?(args) ->
          {"", 0}

        cas?(args) ->
          {"", 0}

        post_cas_proof?(args) ->
          {new_record, 0}
      end
    end
  end

  defp drain_commands(acc) do
    receive do
      {:command, args} -> drain_commands([args | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp read_only_record?(args), do: List.last(args) |> String.contains?("stat -c %Y")
  defp installed_digest?(args), do: List.last(args) |> String.starts_with?("sha256sum ")

  defp runtime_provenance_probe?(args),
    do: List.last(args) |> String.contains?("sha256sum /data/data/")

  defp staging_proof?(args), do: List.last(args) |> String.contains?(".mob_otp_stage_")
  defp cas?(args), do: List.last(args) |> String.contains?("record_next_")

  defp post_cas_proof?(args) do
    command = List.last(args)

    String.contains?(command, ".mob_native_deploy_lock/record") and
      not read_only_record?(args) and not cas?(args)
  end

  defp mutating_before_cas?(args) do
    command = List.last(args)

    String.contains?(command, "rm ") or String.contains?(command, "mv ") or
      String.contains?(command, "install") or String.contains?(command, "push")
  end

  defp runtime_provenance, do: [%{path: @runtime_path, sha256: @runtime_sha}]
  defp runtime_device_path, do: "/data/data/#{@bundle}/files/#{@runtime_path}"
end
