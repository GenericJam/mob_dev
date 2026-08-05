defmodule MobDev.AndroidDeployRecoveryProof do
  @moduledoc false

  alias MobDev.AndroidDeployRecovery

  @max_output_bytes 8_192
  @record_pattern ~r/\A1\|[A-Za-z0-9_-]{16}\|[0-9a-f]{64}\|native_ready\z/
  @lock_owner_file "owner.term"
  @lock_version 1
  @refusal_codes [
    :payload_identity_invalid,
    :payload_invalid,
    :host_lock_unavailable,
    :transport_identity_mismatch,
    :lease_record_invalid,
    :apk_signature_invalid,
    :apk_identity_mismatch,
    :runtime_provenance_mismatch,
    :staging_not_clear,
    :recovery_transition_refused
  ]

  @type refusal_code ::
          :payload_identity_invalid
          | :payload_invalid
          | :host_lock_unavailable
          | :transport_identity_mismatch
          | :lease_record_invalid
          | :apk_signature_invalid
          | :apk_identity_mismatch
          | :runtime_provenance_mismatch
          | :staging_not_clear
          | :recovery_transition_refused

  @doc false
  @spec resume(map(), ([String.t()] -> {binary(), integer()}), keyword()) ::
          {:ok, map()}
          | {:error, {:recovery_proof_refused, refusal_code()}}
          | {:error, :recovery_cas_ambiguous, map()}
  def resume(payload_plan, runner, opts \\ [])

  def resume(payload_plan, runner, opts) when is_map(payload_plan) and is_function(runner, 1) do
    validator = Keyword.get(opts, :payload_validator, &default_payload_validator/1)
    host_lock? = Keyword.get(opts, :host_lock_held?, &host_lock_held?/0)
    signature? = Keyword.get(opts, :apk_signature_verified?, &apk_signature_verified?/1)
    minimum_age = Keyword.get(opts, :minimum_age_seconds, 900)
    runtime_provenance = Keyword.get(opts, :runtime_provenance)

    with {:ok, identity} <- tagged(payload_identity(payload_plan), :payload_identity_invalid),
         :ok <- callback_ok(validator, payload_plan, :payload_invalid),
         :ok <- callback_true0(host_lock?, :host_lock_unavailable),
         {:ok, transport} <-
           tagged(exact_usb_transport(identity.serial, runner), :transport_identity_mismatch),
         {:ok, record, age} <- tagged(lease_record(identity, runner), :lease_record_invalid),
         :ok <- callback_true(signature?, identity.apk_path, :apk_signature_invalid),
         :ok <- tagged(installed_apk_matches(identity, runner), :apk_identity_mismatch),
         {:ok, runtime_provenance_proven?} <-
           tagged(
             runtime_provenance_matches(identity, runtime_provenance, runner),
             :runtime_provenance_mismatch
           ),
         :ok <- proven(staging_clear?(identity, runner), :staging_not_clear) do
      proof = %{
        version: 1,
        bundle_id: identity.bundle_id,
        serial: identity.serial,
        target_digest: target_digest(identity.serial),
        phase: :native_ready,
        record: record,
        lease_age_seconds: age,
        transport: transport,
        adb_tcp_disabled?: true,
        host_deployer_absent?: true,
        exact_topology?: true,
        package_identity_matches?: true,
        apk_signature_verified?: true,
        apk_digest_matches?: true,
        runtime_provenance_matches?: runtime_provenance_proven?,
        payload_valid?: true,
        staging_clear?: true
      }

      recovery_opts =
        [minimum_age_seconds: minimum_age]
        |> maybe_put_owner(opts)

      case AndroidDeployRecovery.resume(proof, runner, recovery_opts) do
        {:error, :recovery_proof_refused} -> refusal(:recovery_transition_refused)
        result -> result
      end
    else
      {:error, {:recovery_proof_refused, code}} when code in @refusal_codes -> refusal(code)
    end
  end

  def resume(_payload_plan, _runner, _opts), do: refusal(:payload_identity_invalid)

  defp tagged({:ok, _value} = result, _code), do: result
  defp tagged({:ok, _first, _second} = result, _code), do: result
  defp tagged(:ok, _code), do: :ok
  defp tagged(_unproven, code), do: refusal(code)

  defp proven(true, _code), do: :ok
  defp proven(_unproven, code), do: refusal(code)

  defp callback_ok(callback, value, code) do
    try do
      proven(callback.(value) == :ok, code)
    rescue
      _error -> refusal(code)
    catch
      _kind, _reason -> refusal(code)
    end
  end

  defp callback_true(callback, value, code) do
    try do
      proven(callback.(value) == true, code)
    rescue
      _error -> refusal(code)
    catch
      _kind, _reason -> refusal(code)
    end
  end

  defp callback_true0(callback, code) do
    try do
      proven(callback.() == true, code)
    rescue
      _error -> refusal(code)
    catch
      _kind, _reason -> refusal(code)
    end
  end

  defp refusal(code) when code in @refusal_codes,
    do: {:error, {:recovery_proof_refused, code}}

  @doc false
  @spec with_host_lock(binary(), (-> term())) ::
          term() | {:error, :recovery_host_lock_unavailable}
  def with_host_lock(bundle_id, operation)
      when is_binary(bundle_id) and is_function(operation, 0) do
    with true <- Regex.match?(~r/\A[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)+\z/, bundle_id),
         {:ok, lock} <- acquire_host_lock(bundle_id) do
      Process.put(:mob_dev_android_recovery_host_lock, lock)

      try do
        operation.()
      after
        Process.delete(:mob_dev_android_recovery_host_lock)
        release_host_lock(lock)
      end
    else
      _unavailable_or_held -> {:error, :recovery_host_lock_unavailable}
    end
  end

  def with_host_lock(_bundle_id, _operation), do: {:error, :recovery_host_lock_unavailable}

  @doc false
  @spec __test_only__(:lock_path, binary()) :: binary()
  def __test_only__(:lock_path, bundle_id), do: host_lock_path(bundle_id)

  @doc false
  @spec __test_only__(:set_release_hook, (-> term())) :: :ok
  def __test_only__(:set_release_hook, hook) when is_function(hook, 0) do
    Process.put(:mob_dev_android_recovery_release_hook, hook)
    :ok
  end

  defp payload_identity(%{
         version: 1,
         package: bundle_id,
         serials: [serial],
         apk: %{path: apk_path, sha256: apk_sha256}
       })
       when is_binary(bundle_id) and is_binary(serial) and is_binary(apk_path) and
              is_binary(apk_sha256) do
    if Regex.match?(~r/\A[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)+\z/, bundle_id) and
         byte_size(serial) in 1..128 and Regex.match?(~r/\A[A-Za-z0-9._:-]+\z/, serial) and
         File.regular?(apk_path) and Regex.match?(~r/\A[0-9a-f]{64}\z/, apk_sha256) do
      {:ok, %{bundle_id: bundle_id, serial: serial, apk_path: apk_path, apk_sha256: apk_sha256}}
    else
      :error
    end
  end

  defp payload_identity(_payload_plan), do: :error

  defp exact_usb_transport(serial, runner) do
    with {:ok, output} <- invoke(runner, ["devices", "-l"]),
         [line] <-
           output
           |> String.split("\n", trim: true)
           |> Enum.reject(&String.starts_with?(&1, "List of devices")),
         [^serial, "device" | fields] <- String.split(line),
         true <- Enum.any?(fields, &String.starts_with?(&1, "usb:")),
         {:ok, tcp_state} <-
           invoke(runner, [
             "-s",
             serial,
             "shell",
             "printf '%s|%s' \"$(getprop service.adb.tcp.port)\" \"$(getprop persist.adb.tcp.port)\""
           ]),
         true <- tcp_state in ["|", "-1|-1", "0|0", "-1|", "|-1"] do
      {:ok, :usb}
    else
      _invalid_or_network_transport -> :error
    end
  end

  defp lease_record(identity, runner) do
    fixed = "/data/data/#{identity.bundle_id}/files/.mob_native_deploy_lock"

    command =
      "run-as #{identity.bundle_id} sh -c 'set -e; " <>
        "for path in /data/data/#{identity.bundle_id}/files/.mob_native_deploy_releasing_*; " <>
        "do test ! -e \"$path\" || exit 1; done; " <>
        "test -d #{fixed}; entries=$(find #{fixed} -mindepth 1 -maxdepth 1 -print | wc -l); " <>
        "test \"$entries\" -eq 1; test -f #{fixed}/record; " <>
        "cat #{fixed}/record; printf \"\\n%s\\n%s\\n\" \"$(stat -c %Y #{fixed}/record)\" \"$(date +%s)\"'"

    with {:ok, output} <- invoke(runner, ["-s", identity.serial, "shell", command]),
         [record, modified, current] <- String.split(output, "\n", trim: true),
         true <- Regex.match?(@record_pattern, record),
         {modified_at, ""} <- Integer.parse(modified),
         {current_at, ""} <- Integer.parse(current),
         age when age >= 0 <- current_at - modified_at do
      {:ok, record, age}
    else
      _invalid_or_ambiguous -> :error
    end
  end

  defp installed_apk_matches(identity, runner) do
    with {:ok, path_output} <-
           invoke(runner, ["-s", identity.serial, "shell", "pm path #{identity.bundle_id}"]),
         ["package:" <> installed_path] <- String.split(path_output, "\n", trim: true),
         true <-
           Regex.match?(~r{\A/data/app/[A-Za-z0-9._~+/=-]+/base\.apk\z}, installed_path),
         {:ok, digest_output} <-
           invoke(runner, ["-s", identity.serial, "shell", "sha256sum #{installed_path}"]),
         [digest, ^installed_path] <- String.split(digest_output),
         true <- digest == identity.apk_sha256 do
      :ok
    else
      _mismatch_or_ambiguity -> :error
    end
  end

  defp staging_clear?(identity, runner) do
    root = "/data/data/#{identity.bundle_id}/files"

    command =
      "run-as #{identity.bundle_id} sh -c 'set -e; " <>
        "for path in #{root}/.mob_otp_stage_* #{root}/.mob_beams_stage_* " <>
        "#{root}/.mob_beams_backup_* #{root}/.mob_beams_activation_lock; " <>
        "do test ! -e \"$path\" || exit 1; done'"

    match?({:ok, ""}, invoke(runner, ["-s", identity.serial, "shell", command]))
  end

  defp runtime_provenance_matches(identity, provenance, runner)
       when is_list(provenance) and provenance != [] and length(provenance) <= 32 do
    app_data = "/data/data/#{identity.bundle_id}/files"

    with true <- valid_runtime_provenance?(provenance),
         paths <- Enum.map(provenance, &Path.join(app_data, &1.path)),
         command <-
           "run-as #{identity.bundle_id} sh -c 'set -e; sha256sum #{Enum.join(paths, " ")}'",
         {:ok, output} <- invoke(runner, ["-s", identity.serial, "shell", command]),
         {:ok, observed} <- parse_runtime_digests(output, paths),
         expected <- Map.new(Enum.zip(paths, Enum.map(provenance, & &1.sha256))),
         true <- observed == expected do
      {:ok, true}
    else
      _missing_or_changed -> :error
    end
  end

  defp runtime_provenance_matches(_identity, _provenance, _runner), do: :error

  defp valid_runtime_provenance?(provenance) do
    paths = Enum.map(provenance, &Map.get(&1, :path))

    Enum.uniq(paths) == paths and
      Enum.all?(provenance, fn entry ->
        is_map(entry) and MapSet.new(Map.keys(entry)) == MapSet.new([:path, :sha256]) and
          is_binary(entry.path) and byte_size(entry.path) in 1..1_024 and
          Regex.match?(~r{\Aotp/[A-Za-z0-9_./-]+\z}, entry.path) and
          not Enum.member?(Path.split(entry.path), "..") and is_binary(entry.sha256) and
          Regex.match?(~r/\A[0-9a-f]{64}\z/, entry.sha256)
      end)
  end

  defp parse_runtime_digests(output, expected_paths) do
    parsed =
      output
      |> String.split("\n", trim: true)
      |> Enum.map(fn line -> String.split(line) end)

    with true <- length(parsed) == length(expected_paths),
         true <- Enum.all?(parsed, &(length(&1) == 2)),
         observed <- Map.new(parsed, fn [digest, path] -> {path, digest} end),
         true <- map_size(observed) == length(expected_paths),
         true <- Map.keys(observed) |> Enum.sort() == Enum.sort(expected_paths),
         true <-
           Enum.all?(observed, fn {_path, digest} ->
             Regex.match?(~r/\A[0-9a-f]{64}\z/, digest)
           end) do
      {:ok, observed}
    else
      _invalid_or_ambiguous -> :error
    end
  end

  defp invoke(runner, args) do
    try do
      case runner.(args) do
        {output, 0} when is_binary(output) and byte_size(output) <= @max_output_bytes ->
          {:ok, String.trim(output)}

        _failure_or_oversize ->
          :error
      end
    rescue
      _error -> :error
    catch
      _kind, _reason -> :error
    end
  end

  defp default_payload_validator(payload_plan) do
    MobDev.NativeBuild.validate_android_recovery_payload(payload_plan)
  end

  defp apk_signature_verified?(apk_path) do
    with executable when is_binary(executable) <- System.find_executable("apksigner"),
         {_output, 0} <- System.cmd(executable, ["verify", "--print-certs", apk_path]) do
      true
    else
      _unavailable_or_invalid -> false
    end
  end

  defp acquire_host_lock(bundle_id) do
    path = host_lock_path(bundle_id)

    with {:ok, owner} <- current_lock_owner() do
      publish_or_recover_lock(path, owner, 0)
    end
  end

  defp host_lock_held? do
    case Process.get(:mob_dev_android_recovery_host_lock) do
      %{owner_path: owner_path, owner: owner} -> read_lock_owner(owner_path) == {:ok, owner}
      _missing -> false
    end
  end

  defp release_host_lock(lock) do
    with {:ok, owner} <- read_lock_owner(lock.owner_path),
         true <- owner == lock.owner,
         release_path <-
           "#{lock.path}.released.#{Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)}",
         :ok <- File.rename(lock.path, release_path) do
      run_release_hook()
      _ = File.rm(Path.join(release_path, @lock_owner_file))
      _ = File.rmdir(release_path)
      :ok
    else
      _changed_or_missing -> :ok
    end
  end

  defp run_release_hook do
    case Process.get(:mob_dev_android_recovery_release_hook) do
      hook when is_function(hook, 0) -> hook.()
      _missing -> :ok
    end
  end

  defp publish_or_recover_lock(_path, _owner, attempts) when attempts > 8,
    do: {:error, :ambiguous}

  defp publish_or_recover_lock(path, owner, attempts) do
    candidate =
      "#{path}.candidate.#{Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)}"

    owner_path = Path.join(candidate, @lock_owner_file)

    result =
      with :ok <- File.mkdir(candidate),
           :ok <-
             File.write(owner_path, :erlang.term_to_binary(owner), [:write, :exclusive, :binary]) do
        case File.rename(candidate, path) do
          :ok ->
            {:ok, %{path: path, owner_path: Path.join(path, @lock_owner_file), owner: owner}}

          {:error, reason} when reason in [:eexist, :enotempty] ->
            case existing_lock_state(path, owner) do
              :held -> {:error, :held}
              :ambiguous -> {:error, :ambiguous}
              :stale -> quarantine_stale_lock(path, owner, attempts)
            end

          _failure ->
            {:error, :ambiguous}
        end
      else
        _failure -> {:error, :ambiguous}
      end

    _ = File.rm(owner_path)
    _ = File.rmdir(candidate)
    result
  end

  defp quarantine_stale_lock(path, owner, attempts) do
    quarantine =
      "#{path}.stale.#{Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)}"

    case File.rename(path, quarantine) do
      :ok ->
        _ = File.rm(Path.join(quarantine, @lock_owner_file))
        _ = File.rmdir(quarantine)
        publish_or_recover_lock(path, owner, attempts + 1)

      {:error, :enoent} ->
        publish_or_recover_lock(path, owner, attempts + 1)

      _failure ->
        {:error, :ambiguous}
    end
  end

  defp existing_lock_state(path, current_owner) do
    case read_lock_owner(Path.join(path, @lock_owner_file)) do
      {:ok, owner} -> owner_liveness(owner, current_owner)
      {:error, :enoent} -> :ambiguous
      {:error, _reason} -> :ambiguous
    end
  end

  defp owner_liveness(owner, current) do
    cond do
      owner.boot_id != current.boot_id ->
        :stale

      owner.vm_id == current.vm_id ->
        local_owner_liveness(owner)

      true ->
        os_owner_liveness(owner)
    end
  end

  defp local_owner_liveness(owner) do
    with {:ok, pid} <- local_pid(owner.beam_pid) do
      if Process.alive?(pid), do: :held, else: :stale
    else
      _invalid -> :ambiguous
    end
  end

  defp os_owner_liveness(owner) do
    case os_process_start(owner.os_pid) do
      {:ok, start} when start == owner.os_start -> :held
      {:ok, _reused_pid} -> :stale
      {:error, :not_found} -> :stale
      {:error, _reason} -> :ambiguous
    end
  end

  defp current_lock_owner do
    with {:ok, boot_id} <- machine_boot_id(),
         {os_pid, ""} <- Integer.parse(System.pid()),
         {:ok, os_start} <- os_process_start(os_pid) do
      {:ok,
       %{
         version: @lock_version,
         boot_id: boot_id,
         os_pid: os_pid,
         os_start: os_start,
         vm_id: vm_id(boot_id, os_pid, os_start),
         beam_pid: List.to_string(:erlang.pid_to_list(self()))
       }}
    else
      _unavailable -> {:error, :ambiguous}
    end
  end

  defp read_lock_owner(path) do
    try do
      with {:ok, bytes} <- File.read(path),
           true <- byte_size(bytes) <= 4_096,
           owner when is_map(owner) <- :erlang.binary_to_term(bytes, [:safe]),
           true <- valid_lock_owner?(owner) do
        {:ok, owner}
      else
        {:error, reason} -> {:error, reason}
        _invalid -> {:error, :invalid}
      end
    catch
      _kind, _reason -> {:error, :invalid}
    end
  end

  defp valid_lock_owner?(owner) do
    Map.keys(owner) |> Enum.sort() ==
      Enum.sort([:version, :boot_id, :os_pid, :os_start, :vm_id, :beam_pid]) and
      owner.version == @lock_version and is_binary(owner.boot_id) and
      byte_size(owner.boot_id) == 64 and is_integer(owner.os_pid) and owner.os_pid > 0 and
      is_binary(owner.os_start) and byte_size(owner.os_start) in 1..256 and
      is_binary(owner.vm_id) and byte_size(owner.vm_id) == 64 and
      is_binary(owner.beam_pid) and byte_size(owner.beam_pid) in 3..64
  end

  defp local_pid(encoded) do
    {:ok, :erlang.list_to_pid(String.to_charlist(encoded))}
  catch
    _kind, _reason -> {:error, :invalid}
  end

  defp machine_boot_id do
    case File.read("/proc/sys/kernel/random/boot_id") do
      {:ok, value} -> {:ok, fingerprint(value)}
      {:error, _reason} -> command_fingerprint("sysctl", ["-n", "kern.boottime"])
    end
  end

  defp os_process_start(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} -> linux_process_start(stat)
      {:error, :enoent} -> ps_process_start(pid)
      {:error, _reason} -> ps_process_start(pid)
    end
  end

  defp linux_process_start(stat) do
    with close when is_integer(close) <- last_paren_index(stat),
         fields <- binary_part(stat, close + 1, byte_size(stat) - close - 1) |> String.split(),
         value when is_binary(value) <- Enum.at(fields, 19),
         true <- Regex.match?(~r/\A\d+\z/, value) do
      {:ok, value}
    else
      _invalid -> {:error, :ambiguous}
    end
  end

  defp last_paren_index(stat) do
    case :binary.matches(stat, ")") do
      [] -> nil
      matches -> matches |> List.last() |> elem(0)
    end
  end

  defp ps_process_start(pid) do
    case System.find_executable("ps") do
      nil ->
        {:error, :ambiguous}

      executable ->
        case System.cmd(executable, ["-o", "lstart=", "-p", Integer.to_string(pid)],
               stderr_to_stdout: true
             ) do
          {output, 0} ->
            case String.trim(output) do
              "" -> {:error, :not_found}
              value -> {:ok, fingerprint(value)}
            end

          {_output, 1} ->
            {:error, :not_found}

          _failure ->
            {:error, :ambiguous}
        end
    end
  end

  defp command_fingerprint(command, args) do
    case System.find_executable(command) do
      nil ->
        {:error, :ambiguous}

      executable ->
        case System.cmd(executable, args, stderr_to_stdout: true) do
          {output, 0} when output != "" -> {:ok, fingerprint(output)}
          _failure -> {:error, :ambiguous}
        end
    end
  end

  defp vm_id(boot_id, os_pid, os_start),
    do: fingerprint("#{boot_id}\0#{os_pid}\0#{os_start}")

  defp fingerprint(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp host_lock_path(bundle_id) do
    digest = :crypto.hash(:sha256, bundle_id) |> Base.url_encode64(padding: false)
    Path.join(System.tmp_dir!(), "mob_native_recovery_#{digest}.lock")
  end

  defp maybe_put_owner(recovery_opts, opts) do
    case Keyword.fetch(opts, :owner) do
      {:ok, owner} -> Keyword.put(recovery_opts, :owner, owner)
      :error -> recovery_opts
    end
  end

  defp target_digest(serial),
    do: :crypto.hash(:sha256, serial) |> Base.encode16(case: :lower)
end
