defmodule MobDev.AndroidDeployLock do
  @moduledoc false

  @max_targets 32
  @max_serial_bytes 128
  @max_record_bytes 128
  @max_command_output_bytes 256
  @owner_pattern "\\A[A-Za-z0-9_-]{16}\\z"
  @digest_pattern "\\A[0-9a-f]{64}\\z"
  @bundle_pattern "\\A[A-Za-z][A-Za-z0-9_]*(?:\\.[A-Za-z0-9_]+)+\\z"
  @phases [:acquired, :native_ready, :final_committed, :fast_committed]
  @committed_phases [:final_committed, :fast_committed]

  @type runner :: ([String.t()] -> {String.t(), integer()})
  @type phase :: :acquired | :native_ready | :final_committed | :fast_committed
  @type lease_state ::
          :not_acquired | :held_success | :retained_failure | :retained_ambiguous
  @type lease :: %{
          required(:bundle_id) => String.t(),
          required(:owner) => String.t(),
          required(:serials) => [String.t()],
          required(:target_digest) => String.t(),
          required(:phase) => phase(),
          required(:state) => lease_state()
        }
  @type failure :: %{
          required(:reason) => atom(),
          required(:phase) => atom(),
          required(:serial) => String.t() | nil,
          required(:lease) => lease(),
          optional(:affected_serials) => [String.t()],
          optional(:transitioned_serials) => [String.t()],
          optional(:renamed_serials) => [String.t()],
          optional(:released_serials) => [String.t()],
          optional(:transition) => {phase(), phase()}
        }

  @doc false
  @spec valid?(term(), phase() | nil) :: boolean()
  def valid?(lease, expected_phase \\ nil) do
    validate_lease(lease) == :ok and lease.state == :held_success and
      (is_nil(expected_phase) or lease.phase == expected_phase)
  end

  @doc false
  @spec acquire(String.t(), [String.t()], runner(), keyword()) ::
          {:ok, lease()} | {:error, failure()}
  def acquire(bundle_id, serials, runner, opts \\ [])

  def acquire(bundle_id, serials, runner, opts) when is_function(runner, 1) do
    owner = Keyword.get_lazy(opts, :owner, &new_owner/0)

    with :ok <- validate_bundle_id(bundle_id),
         :ok <- validate_owner(owner),
         {:ok, ordered_serials} <- validate_serials(serials) do
      lease = %{
        bundle_id: bundle_id,
        owner: owner,
        serials: ordered_serials,
        target_digest: target_digest(ordered_serials),
        phase: :acquired,
        state: :not_acquired
      }

      with :ok <- preflight_available(lease, runner) do
        acquire_ordered(lease, runner)
      end
    else
      {:error, reason} ->
        {:error,
         %{
           reason: reason,
           phase: :validate,
           serial: nil,
           lease: invalid_lease(bundle_id, owner, serials)
         }}
    end
  end

  def acquire(bundle_id, serials, _runner, opts) do
    owner = Keyword.get(opts, :owner, "<invalid>")

    {:error,
     %{
       reason: :invalid_runner,
       phase: :validate,
       serial: nil,
       lease: invalid_lease(bundle_id, owner, serials)
     }}
  end

  @doc false
  @spec verify_owner(lease(), String.t(), runner()) :: :ok | {:error, failure()}
  def verify_owner(lease, serial, runner) when is_function(runner, 1) do
    with :ok <- validate_lease(lease),
         :ok <- require_held(lease),
         :ok <- require_target(lease, serial),
         :ok <- validate_serial(serial) do
      expected = record(lease, lease.phase)

      case invoke(runner, serial, record_proof_command(lease.bundle_id)) do
        {^expected, 0} ->
          :ok

        _missing_mismatched_or_ambiguous ->
          {:error, failure(lease, :record_mismatch, :verify_owner, serial)}
      end
    else
      {:error, reason} -> {:error, failure(normalize_lease(lease), reason, :validate, serial)}
    end
  end

  def verify_owner(lease, serial, _runner),
    do: {:error, failure(normalize_lease(lease), :invalid_runner, :validate, serial)}

  @doc false
  @spec transition(lease(), phase(), phase(), runner()) ::
          {:ok, lease()} | {:error, failure()}
  def transition(lease, expected_phase, next_phase, runner) when is_function(runner, 1) do
    with :ok <- validate_lease(lease),
         true <- lease.state == :held_success,
         true <- lease.phase == expected_phase,
         :ok <- validate_transition(expected_phase, next_phase),
         :ok <- preflight_records(lease, runner) do
      transition_ordered(lease, expected_phase, next_phase, runner)
    else
      false ->
        {:error, failure(normalize_lease(lease), :phase_mismatch, :transition_validate, nil)}

      {:error, %{lease: _lease} = failure} ->
        {:error, failure}

      {:error, reason} ->
        {:error, failure(normalize_lease(lease), reason, :transition_validate, nil)}
    end
  end

  def transition(lease, _expected_phase, _next_phase, _runner),
    do: {:error, failure(normalize_lease(lease), :invalid_runner, :transition_validate, nil)}

  @doc false
  @spec release(lease(), runner()) :: :ok | {:error, failure()}
  def release(lease, runner) when is_function(runner, 1) do
    with :ok <- validate_lease(lease),
         true <- lease.state == :held_success,
         true <- lease.phase in @committed_phases,
         :ok <- preflight_records(lease, runner) do
      release_ordered(lease, runner)
    else
      false -> {:error, failure(normalize_lease(lease), :lease_not_releasable, :validate, nil)}
      {:error, %{lease: _lease} = failure} -> {:error, failure}
      {:error, reason} -> {:error, failure(normalize_lease(lease), reason, :validate, nil)}
    end
  end

  def release(lease, _runner),
    do: {:error, failure(normalize_lease(lease), :invalid_runner, :validate, nil)}

  @doc false
  @spec status(String.t(), String.t(), runner()) ::
          {:ok, :clear | :held | :released_tombstone | :ambiguous} | {:error, atom()}
  def status(bundle_id, serial, runner) when is_function(runner, 1) do
    with :ok <- validate_bundle_id(bundle_id),
         :ok <- validate_serial(serial) do
      case invoke(runner, serial, status_command(bundle_id)) do
        {"clear", 0} -> {:ok, :clear}
        {"held", 0} -> {:ok, :held}
        {"released_tombstone", 0} -> {:ok, :released_tombstone}
        {"ambiguous", 0} -> {:ok, :ambiguous}
        _invalid_or_failed -> {:error, :status_ambiguous}
      end
    end
  end

  def status(_bundle_id, _serial, _runner), do: {:error, :invalid_runner}

  @doc false
  @spec cleanup_committed_tombstone(String.t(), String.t(), runner()) ::
          :ok | {:error, atom()}
  def cleanup_committed_tombstone(bundle_id, serial, runner) when is_function(runner, 1) do
    with :ok <- validate_bundle_id(bundle_id),
         :ok <- validate_serial(serial),
         {:ok, owner, record} <- probe_committed_tombstone(bundle_id, serial, runner),
         {"", 0} <-
           invoke(runner, serial, cleanup_tombstone_command(bundle_id, owner, record)) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _failure_or_ambiguity -> {:error, :cleanup_ambiguous}
    end
  end

  def cleanup_committed_tombstone(_bundle_id, _serial, _runner),
    do: {:error, :invalid_runner}

  @doc false
  @spec message(failure()) :: String.t()
  def message(%{phase: phase, reason: reason}) do
    "Android deploy lease #{phase_label(phase)} failed (#{reason_label(reason)}); manual recovery required"
  end

  def message(_failure), do: "Android deploy lease failed; manual recovery required"

  defp preflight_available(lease, runner) do
    Enum.reduce_while(lease.serials, :ok, fn serial, :ok ->
      case invoke(runner, serial, available_command(lease.bundle_id)) do
        {"", 0} ->
          {:cont, :ok}

        _blocked_or_ambiguous ->
          {:halt,
           {:error,
            failure(
              %{lease | state: :not_acquired},
              :lease_present_or_ambiguous,
              :preflight,
              serial
            )}}
      end
    end)
  end

  defp preflight_records(lease, runner) do
    Enum.reduce_while(lease.serials, :ok, fn serial, :ok ->
      case verify_owner(lease, serial, runner) do
        :ok ->
          {:cont, :ok}

        {:error, failure} ->
          retained = %{lease | state: :retained_ambiguous}
          {:halt, {:error, %{failure | lease: retained}}}
      end
    end)
  end

  defp acquire_ordered(lease, runner) do
    lease.serials
    |> Enum.reduce_while({:ok, []}, fn serial, {:ok, acquired} ->
      case invoke(runner, serial, acquire_command(lease)) do
        {"", 0} ->
          {:cont, {:ok, [serial | acquired]}}

        _failure_or_ambiguity ->
          affected = Enum.sort([serial | acquired])
          retained_lease = %{lease | state: :retained_ambiguous}

          {:halt,
           {:error,
            failure(retained_lease, :acquire_ambiguous, :acquire, serial,
              affected_serials: affected
            )}}
      end
    end)
    |> case do
      {:ok, _acquired} -> {:ok, %{lease | state: :held_success}}
      {:error, _failure} = error -> error
    end
  end

  defp transition_ordered(lease, expected_phase, next_phase, runner) do
    old_record = record(lease, expected_phase)
    next_record = record(lease, next_phase)

    lease.serials
    |> Enum.reduce_while({:ok, []}, fn serial, {:ok, transitioned} ->
      case invoke(
             runner,
             serial,
             transition_command(lease.bundle_id, lease.owner, old_record, next_record)
           ) do
        {"", 0} ->
          {:cont, {:ok, [serial | transitioned]}}

        _failure_or_ambiguity ->
          retained = %{lease | state: :retained_ambiguous}

          {:halt,
           {:error,
            failure(retained, :transition_ambiguous, :transition, serial,
              transition: {expected_phase, next_phase},
              affected_serials: Enum.sort([serial | transitioned]),
              transitioned_serials: Enum.sort(transitioned)
            )}}
      end
    end)
    |> case do
      {:ok, _transitioned} -> {:ok, %{lease | phase: next_phase}}
      {:error, _failure} = error -> error
    end
  end

  defp release_ordered(lease, runner) do
    ordered = Enum.sort(lease.serials, :desc)

    with {:ok, renamed} <- rename_all(lease, ordered, runner),
         :ok <- verify_all_tombstones(lease, ordered, renamed, runner),
         {:ok, _released} <- delete_all_tombstones(lease, ordered, runner) do
      :ok
    else
      {:error, _failure} = error -> error
    end
  end

  defp rename_all(lease, ordered, runner) do
    Enum.reduce_while(ordered, {:ok, []}, fn serial, {:ok, renamed} ->
      case release_fixed_lock(lease, serial, runner) do
        :ok ->
          {:cont, {:ok, [serial | renamed]}}

        {:error, %{phase: phase, reason: reason}} ->
          retained = %{lease | state: :retained_ambiguous}

          {:halt,
           {:error,
            failure(retained, reason, phase, serial,
              affected_serials: Enum.sort([serial | renamed]),
              renamed_serials: Enum.sort(renamed)
            )}}
      end
    end)
  end

  defp verify_all_tombstones(lease, ordered, renamed, runner) do
    Enum.reduce_while(ordered, :ok, fn serial, :ok ->
      case verify_tombstone_record(lease, serial, runner) do
        :ok ->
          {:cont, :ok}

        {:error, %{phase: phase, reason: reason}} ->
          retained = %{lease | state: :retained_ambiguous}

          {:halt,
           {:error, failure(retained, reason, phase, serial, renamed_serials: Enum.sort(renamed))}}
      end
    end)
  end

  defp delete_all_tombstones(lease, ordered, runner) do
    Enum.reduce_while(ordered, {:ok, []}, fn serial, {:ok, released} ->
      case delete_tombstone(lease, serial, runner) do
        :ok ->
          {:cont, {:ok, [serial | released]}}

        {:error, %{phase: phase, reason: reason}} ->
          retained = %{lease | state: :retained_ambiguous}

          {:halt,
           {:error,
            failure(retained, reason, phase, serial, released_serials: Enum.sort(released))}}
      end
    end)
  end

  defp release_fixed_lock(lease, serial, runner) do
    case invoke(runner, serial, rename_command(lease)) do
      {"", 0} ->
        :ok

      _failure_or_ambiguity ->
        {:error, failure(lease, :rename_ambiguous, :release_rename, serial)}
    end
  end

  defp verify_tombstone_record(lease, serial, runner) do
    expected = record(lease, lease.phase)

    case invoke(runner, serial, tombstone_record_proof_command(lease.bundle_id, lease.owner)) do
      {^expected, 0} ->
        :ok

      _failure_or_ambiguity ->
        {:error, failure(lease, :tombstone_record_ambiguous, :release_verify, serial)}
    end
  end

  defp delete_tombstone(lease, serial, runner) do
    case invoke(runner, serial, delete_command(lease)) do
      {"", 0} ->
        :ok

      _failure_or_ambiguity ->
        {:error, failure(lease, :delete_ambiguous, :release_delete, serial)}
    end
  end

  defp available_command(bundle_id) do
    {files, fixed, tombstones} = lock_paths(bundle_id)

    "run-as #{bundle_id} sh -c 'set -e; test ! -e #{fixed}; " <>
      "for path in #{tombstones}; do test ! -e \"$path\" || exit 1; done; " <>
      "test -d #{files}'"
  end

  defp acquire_command(lease) do
    {_files, fixed, tombstones} = lock_paths(lease.bundle_id)
    value = record(lease, :acquired)

    "run-as #{lease.bundle_id} sh -c 'set -e; " <>
      "for path in #{tombstones}; do test ! -e \"$path\" || exit 1; done; " <>
      "mkdir #{fixed}; printf %s \"#{value}\" > #{fixed}/record'"
  end

  defp record_proof_command(bundle_id) do
    {_files, fixed, tombstones} = lock_paths(bundle_id)

    "run-as #{bundle_id} sh -c 'set -e; " <>
      "for path in #{tombstones}; do test ! -e \"$path\" || exit 1; done; " <>
      "size=$(wc -c < #{fixed}/record); test \"$size\" -le #{@max_record_bytes}; " <>
      "cat #{fixed}/record'"
  end

  defp transition_command(bundle_id, owner, old_record, next_record) do
    {_files, fixed, tombstones} = lock_paths(bundle_id)
    next_file = "#{fixed}/record_next_#{owner}"
    old_size = byte_size(old_record)

    "run-as #{bundle_id} sh -c 'set -e; " <>
      "for path in #{tombstones}; do test ! -e \"$path\" || exit 1; done; " <>
      "size=$(wc -c < #{fixed}/record); test \"$size\" -eq #{old_size}; " <>
      "value=$(cat #{fixed}/record); test \"$value\" = \"#{old_record}\"; " <>
      "test ! -e #{next_file}; printf %s \"#{next_record}\" > #{next_file}; " <>
      "mv #{next_file} #{fixed}/record'"
  end

  defp rename_command(lease) do
    {_files, fixed, tombstones} = lock_paths(lease.bundle_id)
    tombstone = tombstone_path(lease.bundle_id, lease.owner)
    expected = record(lease, lease.phase)
    expected_size = byte_size(expected)

    "run-as #{lease.bundle_id} sh -c 'set -e; " <>
      "for path in #{tombstones}; do test ! -e \"$path\" || exit 1; done; " <>
      "size=$(wc -c < #{fixed}/record); test \"$size\" -eq #{expected_size}; " <>
      "value=$(cat #{fixed}/record); test \"$value\" = \"#{expected}\"; " <>
      "mv #{fixed} #{tombstone}'"
  end

  defp tombstone_record_proof_command(bundle_id, owner) do
    {_files, fixed, tombstones} = lock_paths(bundle_id)
    tombstone = tombstone_path(bundle_id, owner)

    "run-as #{bundle_id} sh -c 'set -e; test ! -e #{fixed}; " <>
      "set -- #{tombstones}; test \"$#\" -eq 1; test \"$1\" = \"#{tombstone}\"; " <>
      "entries=$(find #{tombstone} -mindepth 1 -maxdepth 1 -print | wc -l); " <>
      "test \"$entries\" -eq 1; test -f #{tombstone}/record; " <>
      "size=$(wc -c < #{tombstone}/record); test \"$size\" -le #{@max_record_bytes}; " <>
      "cat #{tombstone}/record'"
  end

  defp delete_command(lease) do
    {_files, fixed, tombstones} = lock_paths(lease.bundle_id)
    tombstone = tombstone_path(lease.bundle_id, lease.owner)
    expected = record(lease, lease.phase)
    expected_size = byte_size(expected)

    "run-as #{lease.bundle_id} sh -c 'set -e; test ! -e #{fixed}; " <>
      "set -- #{tombstones}; test \"$#\" -eq 1; test \"$1\" = \"#{tombstone}\"; " <>
      "entries=$(find #{tombstone} -mindepth 1 -maxdepth 1 -print | wc -l); " <>
      "test \"$entries\" -eq 1; test -f #{tombstone}/record; " <>
      "size=$(wc -c < #{tombstone}/record); test \"$size\" -eq #{expected_size}; " <>
      "value=$(cat #{tombstone}/record); test \"$value\" = \"#{expected}\"; " <>
      "rm #{tombstone}/record; rmdir #{tombstone}'"
  end

  defp status_command(bundle_id) do
    {_files, fixed, tombstones} = lock_paths(bundle_id)

    "run-as #{bundle_id} sh -c 'fixed=0; tombstones=0; " <>
      "if [ -e #{fixed} ]; then fixed=1; fi; " <>
      "for path in #{tombstones}; do if [ -e \"$path\" ]; then tombstones=$((tombstones + 1)); fi; done; " <>
      "if [ \"$fixed\" -eq 0 ] && [ \"$tombstones\" -eq 0 ]; then printf clear; " <>
      "elif [ \"$fixed\" -eq 1 ] && [ \"$tombstones\" -eq 0 ]; then printf held; " <>
      "elif [ \"$fixed\" -eq 0 ] && [ \"$tombstones\" -eq 1 ]; then printf released_tombstone; " <>
      "else printf ambiguous; fi'"
  end

  defp probe_committed_tombstone(bundle_id, serial, runner) do
    case invoke(runner, serial, committed_tombstone_probe_command(bundle_id)) do
      {output, 0} -> parse_committed_tombstone(output)
      _missing_malformed_or_ambiguous -> {:error, :tombstone_ambiguous}
    end
  end

  defp committed_tombstone_probe_command(bundle_id) do
    {_files, fixed, tombstones} = lock_paths(bundle_id)

    "run-as #{bundle_id} sh -c 'set -e; test ! -e #{fixed}; " <>
      "set -- #{tombstones}; test \"$#\" -eq 1; test \"$1\" != \"#{tombstones}\"; " <>
      "test -d \"$1\"; base=${1##*/}; " <>
      "entries=$(find \"$1\" -mindepth 1 -maxdepth 1 -print | wc -l); " <>
      "test \"$entries\" -eq 1; test -f \"$1/record\"; " <>
      "size=$(wc -c < \"$1/record\"); test \"$size\" -le #{@max_record_bytes}; " <>
      "printf \"%s\\n\" \"$base\"; cat \"$1/record\"'"
  end

  defp parse_committed_tombstone(output) when is_binary(output) do
    with [basename, record] <- String.split(output, "\n", parts: 2),
         ["1", owner, digest, phase] <- String.split(record, "|", parts: 4),
         true <- basename == ".mob_native_deploy_releasing_#{owner}",
         :ok <- validate_owner(owner),
         true <- valid_digest?(digest),
         true <- phase in Enum.map(@committed_phases, &Atom.to_string/1),
         true <- byte_size(record) <= @max_record_bytes do
      {:ok, owner, record}
    else
      _malformed_or_uncommitted -> {:error, :tombstone_not_committed}
    end
  end

  defp cleanup_tombstone_command(bundle_id, owner, record) do
    {_files, fixed, tombstones} = lock_paths(bundle_id)
    tombstone = tombstone_path(bundle_id, owner)
    expected_size = byte_size(record)

    "run-as #{bundle_id} sh -c 'set -e; test ! -e #{fixed}; " <>
      "set -- #{tombstones}; test \"$#\" -eq 1; test \"$1\" = \"#{tombstone}\"; " <>
      "entries=$(find #{tombstone} -mindepth 1 -maxdepth 1 -print | wc -l); " <>
      "test \"$entries\" -eq 1; test -f #{tombstone}/record; " <>
      "size=$(wc -c < #{tombstone}/record); test \"$size\" -eq #{expected_size}; " <>
      "value=$(cat #{tombstone}/record); test \"$value\" = \"#{record}\"; " <>
      "rm #{tombstone}/record; rmdir #{tombstone}'"
  end

  defp lock_paths(bundle_id) do
    files = "/data/data/#{bundle_id}/files"
    {files, "#{files}/.mob_native_deploy_lock", "#{files}/.mob_native_deploy_releasing_*"}
  end

  defp tombstone_path(bundle_id, owner),
    do: "/data/data/#{bundle_id}/files/.mob_native_deploy_releasing_#{owner}"

  defp record(lease, phase),
    do: "1|#{lease.owner}|#{lease.target_digest}|#{phase}"

  defp target_digest(serials) do
    serials
    |> Enum.join(<<0>>)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp invoke(runner, serial, command) do
    try do
      case runner.(["-s", serial, "shell", command]) do
        {output, status}
        when is_binary(output) and is_integer(status) and
               byte_size(output) <= @max_command_output_bytes ->
          {output, status}

        _invalid ->
          {:invalid, :invalid}
      end
    rescue
      _error -> {:invalid, :invalid}
    catch
      _kind, _reason -> {:invalid, :invalid}
    end
  end

  defp validate_lease(%{
         bundle_id: bundle_id,
         owner: owner,
         serials: serials,
         target_digest: digest,
         phase: phase,
         state: state
       })
       when phase in @phases and
              state in [:not_acquired, :held_success, :retained_failure, :retained_ambiguous] do
    with :ok <- validate_bundle_id(bundle_id),
         :ok <- validate_owner(owner),
         {:ok, ordered} <- validate_serials(serials),
         true <- ordered == serials,
         true <- valid_digest?(digest),
         true <- digest == target_digest(ordered),
         true <-
           byte_size(record(%{owner: owner, target_digest: digest}, phase)) <= @max_record_bytes do
      :ok
    else
      false -> {:error, :invalid_lease_identity}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_lease(_lease), do: {:error, :invalid_lease}

  defp validate_transition(:acquired, :native_ready), do: :ok
  defp validate_transition(:native_ready, :final_committed), do: :ok
  defp validate_transition(:acquired, :fast_committed), do: :ok
  defp validate_transition(_from, _to), do: {:error, :invalid_transition}

  defp require_held(%{state: :held_success}), do: :ok
  defp require_held(_lease), do: {:error, :lease_not_held}

  defp require_target(%{serials: serials}, serial) do
    if serial in serials, do: :ok, else: {:error, :target_not_in_lease}
  end

  defp validate_bundle_id(bundle_id) when is_binary(bundle_id) do
    if byte_size(bundle_id) <= 255 and String.valid?(bundle_id) and
         Regex.match?(Regex.compile!(@bundle_pattern), bundle_id),
       do: :ok,
       else: {:error, :invalid_bundle_id}
  end

  defp validate_bundle_id(_bundle_id), do: {:error, :invalid_bundle_id}

  defp validate_owner(owner) when is_binary(owner) do
    if String.valid?(owner) and Regex.match?(Regex.compile!(@owner_pattern), owner),
      do: :ok,
      else: {:error, :invalid_owner}
  end

  defp validate_owner(_owner), do: {:error, :invalid_owner}

  defp valid_digest?(digest) when is_binary(digest),
    do: String.valid?(digest) and Regex.match?(Regex.compile!(@digest_pattern), digest)

  defp valid_digest?(_digest), do: false

  defp validate_serials(serials) when is_list(serials) do
    cond do
      serials == [] ->
        {:error, :empty_targets}

      length(serials) > @max_targets ->
        {:error, :too_many_targets}

      Enum.any?(serials, &(validate_serial(&1) != :ok)) ->
        {:error, :invalid_target}

      Enum.uniq(serials) != serials ->
        {:error, :duplicate_target}

      serials |> Enum.map(&String.downcase/1) |> Enum.uniq() |> length() != length(serials) ->
        {:error, :ambiguous_target}

      true ->
        {:ok, Enum.sort(serials)}
    end
  end

  defp validate_serials(_serials), do: {:error, :invalid_targets}

  defp validate_serial(serial) when is_binary(serial) do
    valid? =
      byte_size(serial) in 1..@max_serial_bytes and String.valid?(serial) and
        not String.starts_with?(serial, "-") and
        Enum.all?(:binary.bin_to_list(serial), fn byte ->
          byte in ?0..?9 or byte in ?A..?Z or byte in ?a..?z or byte in ~c".:-_"
        end)

    if valid?, do: :ok, else: {:error, :invalid_target}
  end

  defp validate_serial(_serial), do: {:error, :invalid_target}

  defp new_owner, do: :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)

  defp invalid_lease(bundle_id, owner, serials) do
    safe_serials =
      if is_list(serials) do
        serials
        |> Enum.take(@max_targets)
        |> Enum.filter(&(validate_serial(&1) == :ok))
        |> Enum.uniq()
        |> Enum.sort()
      else
        []
      end

    %{
      bundle_id: if(validate_bundle_id(bundle_id) == :ok, do: bundle_id, else: "<invalid>"),
      owner: if(validate_owner(owner) == :ok, do: owner, else: "<invalid>"),
      serials: safe_serials,
      target_digest: target_digest(Enum.sort(safe_serials)),
      phase: :acquired,
      state: :not_acquired
    }
  end

  defp normalize_lease(
         %{
           bundle_id: _,
           owner: _,
           serials: _,
           target_digest: _,
           phase: _,
           state: _
         } = lease
       ),
       do: lease

  defp normalize_lease(_lease), do: invalid_lease("<invalid>", "<invalid>", [])

  defp failure(lease, reason, phase, serial, extra \\ []) do
    Map.merge(%{reason: reason, phase: phase, serial: serial, lease: lease}, Map.new(extra))
  end

  defp phase_label(phase) when is_atom(phase), do: Atom.to_string(phase)
  defp phase_label(_phase), do: "unknown"
  defp reason_label(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_label(_reason), do: "unknown"
end
