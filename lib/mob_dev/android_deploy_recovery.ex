defmodule MobDev.AndroidDeployRecovery do
  @moduledoc false

  @owner_pattern "\\A[A-Za-z0-9_-]{16}\\z"
  @bundle_pattern "\\A[A-Za-z][A-Za-z0-9_]*(?:\\.[A-Za-z0-9_]+)+\\z"
  @digest_pattern "\\A[0-9a-f]{64}\\z"
  @default_minimum_age_seconds 900

  @type runner :: ([String.t()] -> {String.t(), integer()})
  @type lease :: %{
          required(:bundle_id) => String.t(),
          required(:owner) => String.t(),
          required(:serials) => [String.t()],
          required(:target_digest) => String.t(),
          required(:phase) => :native_ready,
          required(:state) => :held_success | :retained_ambiguous
        }

  @doc false
  @spec resume(map(), runner()) ::
          {:ok, lease()}
          | {:error, :recovery_proof_refused}
          | {:error, :recovery_cas_ambiguous, lease()}
  @spec resume(map(), runner(), keyword()) ::
          {:ok, lease()}
          | {:error, :recovery_proof_refused}
          | {:error, :recovery_cas_ambiguous, lease()}
  def resume(proof, runner, opts \\ [])

  def resume(proof, runner, opts) when is_map(proof) and is_function(runner, 1) do
    owner = Keyword.get_lazy(opts, :owner, &new_owner/0)
    minimum_age = Keyword.get(opts, :minimum_age_seconds, @default_minimum_age_seconds)

    with {:ok, old_owner} <- validate_proof(proof, owner, minimum_age),
         next_record = "1|#{owner}|#{proof.target_digest}|native_ready",
         lease = recovered_lease(proof, owner),
         {"", 0} <-
           invoke(runner, proof.serial, cas_command(proof, old_owner, owner, next_record)),
         {^next_record, 0} <- invoke(runner, proof.serial, proof_command(proof.bundle_id)) do
      {:ok, lease}
    else
      {:error, :recovery_proof_refused} = error ->
        error

      _changed_or_ambiguous ->
        {:error, :recovery_cas_ambiguous, recovered_lease(proof, owner, :retained_ambiguous)}
    end
  end

  def resume(_proof, _runner, _opts), do: {:error, :recovery_proof_refused}

  defp validate_proof(proof, owner, minimum_age) do
    with true <- valid_owner?(owner),
         true <- is_integer(minimum_age) and minimum_age >= @default_minimum_age_seconds,
         true <- exact_keys?(proof),
         true <- proof.version == 1,
         true <- valid_bundle?(proof.bundle_id),
         true <- valid_serial?(proof.serial),
         true <- valid_digest?(proof.target_digest),
         true <- proof.target_digest == target_digest(proof.serial),
         true <- proof.phase == :native_ready,
         true <- is_integer(proof.lease_age_seconds),
         true <- proof.lease_age_seconds >= minimum_age,
         true <- proof.transport == :usb,
         true <- required_proofs?(proof),
         {:ok, old_owner} <- parse_record(proof.record, proof.target_digest),
         true <- owner != old_owner do
      {:ok, old_owner}
    else
      _invalid -> {:error, :recovery_proof_refused}
    end
  end

  defp recovered_lease(proof, owner, state \\ :held_success) do
    %{
      bundle_id: proof.bundle_id,
      owner: owner,
      serials: [proof.serial],
      target_digest: proof.target_digest,
      phase: :native_ready,
      state: state
    }
  end

  defp exact_keys?(proof) do
    MapSet.new(Map.keys(proof)) ==
      MapSet.new([
        :version,
        :bundle_id,
        :serial,
        :target_digest,
        :phase,
        :record,
        :lease_age_seconds,
        :transport,
        :adb_tcp_disabled?,
        :host_deployer_absent?,
        :exact_topology?,
        :package_identity_matches?,
        :apk_signature_verified?,
        :apk_digest_matches?,
        :runtime_provenance_matches?,
        :payload_valid?,
        :staging_clear?
      ])
  end

  defp required_proofs?(proof) do
    Enum.all?(
      [
        proof.adb_tcp_disabled?,
        proof.host_deployer_absent?,
        proof.exact_topology?,
        proof.package_identity_matches?,
        proof.apk_signature_verified?,
        proof.apk_digest_matches?,
        proof.runtime_provenance_matches?,
        proof.payload_valid?,
        proof.staging_clear?
      ],
      &(&1 == true)
    )
  end

  defp parse_record(record, digest) when is_binary(record) do
    case String.split(record, "|", parts: 4) do
      ["1", owner, ^digest, "native_ready"] ->
        if valid_owner?(owner), do: {:ok, owner}, else: :error

      _invalid ->
        :error
    end
  end

  defp parse_record(_record, _digest), do: :error

  defp cas_command(proof, old_owner, new_owner, next_record) do
    fixed = "/data/data/#{proof.bundle_id}/files/.mob_native_deploy_lock"
    tombstones = "/data/data/#{proof.bundle_id}/files/.mob_native_deploy_releasing_*"
    next_file = "#{fixed}/record_next_#{new_owner}"
    size = byte_size(proof.record)

    "run-as #{proof.bundle_id} sh -c 'set -e; " <>
      "for path in #{tombstones}; do test ! -e \"$path\" || exit 1; done; " <>
      "entries=$(find #{fixed} -mindepth 1 -maxdepth 1 -print | wc -l); " <>
      "test \"$entries\" -eq 1; test -f #{fixed}/record; " <>
      "size=$(wc -c < #{fixed}/record); test \"$size\" -eq #{size}; " <>
      "value=$(cat #{fixed}/record); test \"$value\" = \"#{proof.record}\"; " <>
      "test \"${value#1|#{old_owner}|}\" != \"$value\"; " <>
      "test ! -e #{next_file}; printf %s \"#{next_record}\" > #{next_file}; " <>
      "mv #{next_file} #{fixed}/record'"
  end

  defp proof_command(bundle_id) do
    fixed = "/data/data/#{bundle_id}/files/.mob_native_deploy_lock"
    tombstones = "/data/data/#{bundle_id}/files/.mob_native_deploy_releasing_*"

    "run-as #{bundle_id} sh -c 'set -e; " <>
      "for path in #{tombstones}; do test ! -e \"$path\" || exit 1; done; " <>
      "entries=$(find #{fixed} -mindepth 1 -maxdepth 1 -print | wc -l); " <>
      "test \"$entries\" -eq 1; test -f #{fixed}/record; " <>
      "size=$(wc -c < #{fixed}/record); test \"$size\" -le 128; cat #{fixed}/record'"
  end

  defp invoke(runner, serial, command) do
    try do
      runner.(["-s", serial, "shell", command])
    rescue
      _error -> {:invalid, 1}
    catch
      _kind, _reason -> {:invalid, 1}
    end
  end

  defp target_digest(serial),
    do: :crypto.hash(:sha256, serial) |> Base.encode16(case: :lower)

  defp valid_owner?(owner), do: matches?(owner, @owner_pattern)
  defp valid_digest?(digest), do: matches?(digest, @digest_pattern)
  defp valid_bundle?(bundle), do: matches?(bundle, @bundle_pattern)

  defp valid_serial?(serial) when is_binary(serial) do
    byte_size(serial) in 1..128 and String.valid?(serial) and
      Enum.all?(:binary.bin_to_list(serial), fn byte ->
        byte in ?0..?9 or byte in ?A..?Z or byte in ?a..?z or byte in ~c".:-_"
      end)
  end

  defp valid_serial?(_serial), do: false

  defp matches?(value, pattern) when is_binary(value),
    do: String.valid?(value) and Regex.match?(Regex.compile!(pattern), value)

  defp matches?(_value, _pattern), do: false

  defp new_owner, do: :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
end
