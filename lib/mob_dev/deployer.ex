defmodule MobDev.Deployer do
  @moduledoc """
  Pushes compiled BEAM files from `_build/dev/lib/*/ebin/` to connected devices.

  Does NOT rebuild APKs or recompile native code — that's `deploy.sh` (first-time setup).
  Use this for day-to-day code iteration: edit Elixir → `mix mob.deploy` → code running.

  ## Transport selection

  **Erlang dist (preferred)**: when a device node is already reachable via Erlang
  distribution, BEAMs are hot-loaded via RPC. No restart needed — modules are
  loaded in place exactly like `nl/1` in IEx.

  **adb push / cp (fallback)**: when no dist connection exists (first deploy, app not
  running), falls back to the traditional push-then-restart path.

  ## Platform behaviour

  **Android**: pushes via `adb push` (requires `adb root`, i.e. emulator or debug build),
  or falls back to `adb push` → `/data/local/tmp/` → `run-as tar xf` for real devices.

  **iOS simulator**: copies files locally into `/tmp/otp-ios-sim/beamhello/` (no network
  hop — the simulator shares the Mac filesystem).
  """

  alias MobDev.Discovery.{Android, IOS}
  alias MobDev.{AndroidDeployLock, Device, HotPush, Tunnel}

  @cookie :mob_secret

  @android_activity ".MainActivity"
  @max_android_launch_output_bytes 4_096
  @max_android_query_output_bytes 8_192
  @max_adb_serial_bytes 128
  @android_attempt_id_pattern "\\A[A-Za-z0-9_-]{16}\\z"
  @max_android_payload_bytes 1_073_741_824
  @android_abis ["arm64-v8a", "armeabi-v7a", "x86_64"]
  @payload_registry_key {__MODULE__, :android_payload_registry}

  defp app_name, do: Mix.Project.config()[:app] |> to_string()
  defp bundle_id, do: MobDev.Config.bundle_id()
  defp android_package, do: bundle_id()
  defp android_app_data, do: "/data/data/#{android_package()}/files"
  defp android_beams_dir, do: "#{android_app_data()}/otp/#{app_name()}"
  defp ios_bundle_id, do: bundle_id()

  @doc false
  @spec collect_android_beam_dirs() :: [String.t()]
  def collect_android_beam_dirs, do: collect_beam_dirs()

  @doc false
  @spec prepare_android_payload(map(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def prepare_android_payload(context, opts \\ [])

  def prepare_android_payload(context, opts) when is_map(context) and is_list(opts) do
    beam_dirs = Keyword.get_lazy(opts, :beam_dirs, &collect_android_beam_dirs/0)
    priv_dir = Keyword.get_lazy(opts, :priv_dir, &default_priv_dir/0)
    tmp_root = Keyword.get(opts, :tmp_root, System.tmp_dir!())

    with {:ok, identity} <- validate_android_payload_context(context),
         {:ok, attempt_id} <- android_attempt_id(opts),
         :ok <- validate_payload_prepare_opts(opts, beam_dirs, priv_dir, tmp_root),
         :ok <- File.mkdir_p(tmp_root) do
      root = Path.join(tmp_root, "mob_android_payload_#{attempt_id}")

      case File.mkdir(root) do
        :ok ->
          prepare_android_payload_root(root, identity, attempt_id, beam_dirs, priv_dir, opts)

        {:error, _reason} ->
          {:error, "Could not reserve immutable Android payload staging"}
      end
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, _reason} -> {:error, "Could not prepare immutable Android payload"}
    end
  rescue
    _error -> {:error, "Could not prepare immutable Android payload"}
  catch
    _kind, _reason -> {:error, "Could not prepare immutable Android payload"}
  end

  def prepare_android_payload(_context, _opts),
    do: {:error, "Android payload context is invalid"}

  defp prepare_fast_android_payload(devices, package, opts) do
    beam_dirs = Keyword.get(opts, :beam_dirs, collect_android_beam_dirs())
    priv_dir = Keyword.get(opts, :priv_dir, default_priv_dir())
    tmp_root = Keyword.get(opts, :tmp_root, System.tmp_dir!())
    serials = Enum.map(devices, & &1.serial)
    selected_by_serial = Map.new(devices, &{&1.serial, &1.abi})

    identity = %{
      package: package,
      serials: serials,
      selected_abis_by_serial: selected_by_serial,
      selected_abis: selected_by_serial |> Map.values() |> Enum.uniq() |> Enum.sort()
    }

    with :ok <- validate_android_package(package),
         :ok <- validate_payload_serials(serials),
         :ok <- validate_selected_abis(identity.selected_abis),
         true <- Enum.all?(selected_by_serial, fn {_serial, abi} -> abi in @android_abis end),
         {:ok, attempt_id} <- android_attempt_id(opts),
         :ok <-
           validate_payload_prepare_opts(
             Keyword.put(opts, :operation, :fast),
             beam_dirs,
             priv_dir,
             tmp_root
           ),
         :ok <- File.mkdir_p(tmp_root) do
      root = Path.join(tmp_root, "mob_android_fast_payload_#{attempt_id}")

      case File.mkdir(root) do
        :ok ->
          prepare_fast_android_payload_root(root, identity, attempt_id, beam_dirs, priv_dir, opts)

        {:error, _reason} ->
          {:error, "Could not reserve immutable fast Android payload staging"}
      end
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      _invalid -> {:error, "Fast Android payload identity is invalid"}
    end
  rescue
    _error -> {:error, "Could not prepare immutable fast Android payload"}
  catch
    _kind, _reason -> {:error, "Could not prepare immutable fast Android payload"}
  end

  defp prepare_fast_android_payload_root(root, identity, attempt_id, beam_dirs, priv_dir, opts) do
    try do
      with {:ok, beam, beam_checks} <-
             prepare_payload_beam(root, identity, attempt_id, beam_dirs, priv_dir, opts),
           {:ok, exqlite} <- prepare_payload_exqlite(root, identity, attempt_id, opts),
           {:ok, restart_by_serial} <- prepare_restart_map(identity, opts) do
        plan = %{
          version: 1,
          operation: :fast,
          package: identity.package,
          attempt_id: attempt_id,
          serials: identity.serials,
          selected_abis: identity.selected_abis,
          beam: beam,
          exqlite: exqlite,
          restart_by_serial: restart_by_serial
        }

        if validate_fast_android_payload_shape(plan) == :ok and
             valid_payload_artifact_identities?(plan) and valid_payload_checks?(beam_checks) do
          case register_android_payload(plan, root, beam_checks) do
            :ok ->
              {:ok, plan}

            {:error, _reason} ->
              cleanup_payload_root(root)
              {:error, "Could not register fast Android payload"}
          end
        else
          cleanup_payload_root(root)
          {:error, "Prepared fast Android payload failed validation"}
        end
      else
        {:error, reason} ->
          cleanup_payload_root(root)
          {:error, reason}
      end
    rescue
      _error ->
        cleanup_payload_root(root)
        {:error, "Could not snapshot fast Android payload"}
    catch
      _kind, _reason ->
        cleanup_payload_root(root)
        {:error, "Could not snapshot fast Android payload"}
    end
  end

  @doc false
  @spec valid_android_payload?(term(), %{
          required(:package) => String.t(),
          required(:serials) => [String.t()]
        }) ::
          boolean()
  def valid_android_payload?(plan, %{package: package, serials: serials}) do
    validate_android_payload_shape(plan) == :ok and plan.package == package and
      plan.serials == serials and registered_android_payload?(plan) and
      valid_payload_artifact_identities?(plan)
  end

  def valid_android_payload?(_plan, _identity), do: false

  defp valid_fast_android_payload?(plan, %{package: package, serials: serials}) do
    validate_fast_android_payload_shape(plan) == :ok and plan.package == package and
      plan.serials == serials and registered_android_payload?(plan) and
      valid_payload_artifact_identities?(plan)
  end

  defp valid_fast_android_payload?(_plan, _identity), do: false

  defp valid_deploy_payload?(%{operation: :fast} = plan, identity),
    do: valid_fast_android_payload?(plan, identity)

  defp valid_deploy_payload?(plan, identity), do: valid_android_payload?(plan, identity)

  @doc false
  @spec cleanup_android_payload(term()) :: :ok | {:error, String.t()}
  def cleanup_android_payload(plan) do
    with :ok <- validate_android_payload_shape(plan),
         {:ok, entry} <- registered_android_payload(plan) do
      cleanup_registered_android_payload(plan, entry)
    else
      _invalid -> {:error, "Android payload cleanup authority is invalid"}
    end
  rescue
    _error -> {:error, "Could not clean Android payload staging"}
  catch
    _kind, _reason -> {:error, "Could not clean Android payload staging"}
  end

  defp cleanup_deploy_payload(%{operation: :fast} = plan) do
    with :ok <- validate_fast_android_payload_shape(plan),
         {:ok, entry} <- registered_android_payload(plan) do
      cleanup_registered_android_payload(plan, entry)
    else
      _invalid -> {:error, "Fast Android payload cleanup authority is invalid"}
    end
  end

  defp cleanup_deploy_payload(plan), do: cleanup_android_payload(plan)

  defp prepare_android_payload_root(root, identity, attempt_id, beam_dirs, priv_dir, opts) do
    try do
      with {:ok, apk} <- snapshot_payload_apk(root, identity),
           {:ok, beam, beam_checks} <-
             prepare_payload_beam(root, identity, attempt_id, beam_dirs, priv_dir, opts),
           {:ok, exqlite} <- prepare_payload_exqlite(root, identity, attempt_id, opts),
           {:ok, restart_by_serial} <- prepare_restart_map(identity, opts) do
        plan = %{
          version: 1,
          package: identity.package,
          attempt_id: attempt_id,
          serials: identity.serials,
          selected_abis: identity.selected_abis,
          selected_abis_by_serial: identity.selected_abis_by_serial,
          apk: apk,
          beam: beam,
          exqlite: exqlite,
          restart_by_serial: restart_by_serial
        }

        if validate_android_payload_shape(plan) == :ok and
             valid_payload_artifact_identities?(plan) and valid_payload_checks?(beam_checks) do
          case register_android_payload(plan, root, beam_checks) do
            :ok ->
              {:ok, plan}

            {:error, _reason} ->
              cleanup_payload_root(root)
              {:error, "Could not register Android payload cleanup authority"}
          end
        else
          cleanup_payload_root(root)
          {:error, "Prepared Android payload failed structural validation"}
        end
      else
        {:error, reason} ->
          cleanup_payload_root(root)
          {:error, reason}
      end
    rescue
      _error ->
        cleanup_payload_root(root)
        {:error, "Could not snapshot immutable Android payload"}
    catch
      _kind, _reason ->
        cleanup_payload_root(root)
        {:error, "Could not snapshot immutable Android payload"}
    end
  end

  defp validate_android_payload_context(
         %{
           apk: apk,
           apk_sha256: apk_sha256,
           apk_size: apk_size,
           bundle_id: package,
           serials: serials,
           selected_abis: selected_abis,
           selected_abis_by_serial: selected_by_serial
         } = context
       ) do
    with true <- map_size(context) == 7,
         :ok <- validate_android_package(package),
         :ok <- validate_payload_serials(serials),
         :ok <- validate_selected_abis(selected_abis),
         true <-
           is_map(selected_by_serial) and Map.keys(selected_by_serial) |> Enum.sort() == serials,
         true <- Enum.all?(selected_by_serial, fn {_serial, abi} -> abi in selected_abis end),
         true <- selected_abis == selected_by_serial |> Map.values() |> Enum.uniq() |> Enum.sort(),
         true <- is_binary(apk) and File.regular?(apk),
         true <- is_integer(apk_size) and apk_size in 1..@max_android_payload_bytes,
         true <- valid_hex_sha256?(apk_sha256),
         {:ok, %{size: ^apk_size}} <- File.stat(apk),
         {:ok, ^apk_sha256} <- file_sha256_hex(apk) do
      {:ok,
       %{
         apk: Path.expand(apk),
         apk_sha256: apk_sha256,
         apk_size: apk_size,
         package: package,
         serials: serials,
         selected_abis: selected_abis,
         selected_abis_by_serial: selected_by_serial
       }}
    else
      _invalid -> {:error, "Android payload context identity is invalid"}
    end
  end

  defp validate_android_payload_context(_context),
    do: {:error, "Android payload context identity is invalid"}

  defp validate_payload_prepare_opts(opts, beam_dirs, priv_dir, tmp_root) do
    restart = Keyword.get(opts, :restart, true)
    operation = Keyword.get(opts, :operation, :native)
    beam_flags = Keyword.get(opts, :beam_flags)

    cond do
      not is_list(beam_dirs) or beam_dirs == [] or not Enum.all?(beam_dirs, &File.dir?/1) ->
        {:error, "Android BEAM source set is invalid"}

      not (is_nil(priv_dir) or (is_binary(priv_dir) and File.dir?(priv_dir))) ->
        {:error, "Android priv source is invalid"}

      not is_binary(tmp_root) or tmp_root == "" ->
        {:error, "Android payload staging root is invalid"}

      operation not in [:native, :fast] ->
        {:error, "Android payload operation is invalid"}

      operation == :native and restart != true ->
        {:error, "Native Android payload requires checked restart"}

      operation == :fast and restart not in [true, false] ->
        {:error, "Fast Android restart mode is invalid"}

      not (is_nil(beam_flags) or
               (is_binary(beam_flags) and byte_size(beam_flags) <= 4_096 and
                  String.valid?(beam_flags))) ->
        {:error, "Android BEAM flags are invalid"}

      true ->
        :ok
    end
  end

  defp snapshot_payload_apk(root, identity) do
    path = Path.join(root, "payload.apk")

    with :ok <- File.cp(identity.apk, path),
         :ok <- File.chmod(path, 0o400),
         {:ok, %{type: :regular, size: size}} <- File.stat(path),
         true <- size == identity.apk_size,
         {:ok, sha256} <- file_sha256_hex(path),
         true <- sha256 == identity.apk_sha256 do
      {:ok, %{path: path, size: size, sha256: sha256}}
    else
      _failure -> {:error, "Could not snapshot exact Android APK"}
    end
  end

  defp prepare_payload_beam(root, identity, attempt_id, beam_dirs, priv_dir, opts) do
    stage = Path.join(root, "beam_stage")
    archive_path = Path.join(root, "beams.tar")
    local_runner = Keyword.get(opts, :local_runner, &run_local_command/3)
    file_writer = Keyword.get(opts, :file_writer, &File.write/2)
    beam_flags = Keyword.get(opts, :beam_flags)
    app_root = "/data/data/#{identity.package}/files"

    try do
      with :ok <- File.mkdir(stage),
           {:ok, sentinel} <- beam_sentinel(beam_dirs),
           :ok <- stage_android_beam_dirs(beam_dirs, stage, local_runner),
           {:ok, flag_checks} <- stage_android_beam_flags(stage, beam_flags, file_writer),
           {:ok, priv_checks} <- stage_android_priv(stage, priv_dir, local_runner),
           :ok <-
             checked_local_command(local_runner, "create immutable BEAM archive", "tar", [
               "cf",
               archive_path,
               "-C",
               stage,
               "."
             ]),
           {:ok, archive} <- payload_archive_identity(archive_path),
           {:ok, dist_snapshot} <- payload_dist_snapshot(beam_dirs) do
        {:ok,
         %{
           archive: archive,
           stage_device: "/data/local/tmp/mob_beams_#{attempt_id}.tar",
           app_stage: "#{app_root}/.mob_beams_stage_#{attempt_id}",
           app_backup: "#{app_root}/.mob_beams_backup_#{attempt_id}",
           activation_lock: "#{app_root}/.mob_beams_activation_lock",
           dist_snapshot: dist_snapshot,
           runtime_version: System.version(),
           beam_flags: beam_flags
         }, [{:file, sentinel} | flag_checks ++ priv_checks]}
      else
        {:error, reason} -> {:error, reason}
        _failure -> {:error, "Could not prepare immutable BEAM payload"}
      end
    after
      File.rm_rf(stage)
    end
  end

  defp prepare_payload_exqlite(root, identity, attempt_id, opts) do
    {vsn, ebin} = payload_exqlite_source(opts)

    case {vsn, ebin} do
      {nil, nil} ->
        {:ok, nil}

      {vsn, ebin} when is_binary(vsn) and is_binary(ebin) ->
        prepare_payload_exqlite_present(root, identity, attempt_id, vsn, ebin, opts)

      _incomplete ->
        {:error, "Configured exqlite state is incomplete"}
    end
  end

  defp prepare_payload_exqlite_present(root, identity, attempt_id, vsn, ebin, opts) do
    stage = Path.join(root, "exqlite_stage")
    archive_path = Path.join(root, "exqlite.tar")
    local_runner = Keyword.get(opts, :local_runner, &run_local_command/3)
    lib_root = "/data/data/#{identity.package}/files/otp/lib"

    try do
      with :ok <- validate_exqlite_version(vsn),
           {:ok, sentinel} <- validate_exqlite_source(ebin, vsn),
           :ok <- File.mkdir(stage),
           :ok <- prepare_exqlite_local_stage(stage),
           :ok <-
             checked_local_command(local_runner, "stage immutable exqlite ebin", "cp", [
               "-r",
               "#{ebin}/.",
               Path.join(stage, "ebin")
             ]),
           :ok <-
             checked_local_command(local_runner, "create immutable exqlite archive", "tar", [
               "cf",
               archive_path,
               "-C",
               stage,
               "."
             ]),
           {:ok, archive} <- payload_archive_identity(archive_path) do
        {:ok,
         %{
           archive: archive,
           stage_device: "/data/local/tmp/mob_exqlite_#{attempt_id}.tar",
           app_stage: "#{lib_root}/.mob_exqlite_stage_#{attempt_id}",
           app_backup: "#{lib_root}/.mob_exqlite_backup_#{attempt_id}",
           activation_lock: "#{lib_root}/.mob_exqlite_activation_lock",
           app_version: vsn,
           beam_sentinel: sentinel,
           nif: %{
             source: :installed_apk,
             filename: "libsqlite3_nif.so",
             selected_abis: identity.selected_abis,
             required_apk_entries:
               Map.new(identity.selected_abis, &{&1, "lib/#{&1}/libsqlite3_nif.so"})
           }
         }}
      else
        {:error, reason} -> {:error, reason}
        _failure -> {:error, "Could not prepare immutable exqlite payload"}
      end
    after
      File.rm_rf(stage)
    end
  end

  defp payload_exqlite_source(opts) do
    case Keyword.get(opts, :exqlite_source, :auto) do
      :auto -> {exqlite_version(), Path.wildcard("_build/dev/lib/exqlite/ebin") |> List.first()}
      nil -> {nil, nil}
      {vsn, ebin} -> {vsn, ebin}
      _invalid -> {:invalid, :invalid}
    end
  end

  defp prepare_restart_map(identity, opts) do
    restart = Keyword.get(opts, :restart, true)
    dist_override = Keyword.get(opts, :dist_port)
    suffix_override = Keyword.get(opts, :node_suffix)
    activity = Keyword.get(opts, :activity, @android_activity)
    resolver = Keyword.get(opts, :node_suffix_resolver, &Android.device_node_suffix/1)

    with :ok <- validate_android_activity(activity),
         true <- is_function(resolver, 1) do
      identity.serials
      |> Enum.reduce_while({:ok, %{}}, fn serial, {:ok, result} ->
        dist_port = dist_override || Tunnel.serial_base_port(serial)

        suffix =
          if is_binary(suffix_override),
            do: suffix_override,
            else: safe_suffix_call(resolver, serial)

        with :ok <- validate_android_dist_port(dist_port),
             :ok <- validate_android_node_suffix(suffix) do
          record = %{
            package: identity.package,
            activity: activity,
            restart?: restart,
            mode: if(restart, do: :checked_restart, else: :no_restart),
            dist_port: dist_port,
            node_suffix: suffix
          }

          {:cont, {:ok, Map.put(result, serial, record)}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    else
      _invalid -> {:error, "Android restart identity is invalid"}
    end
  end

  defp safe_suffix_call(resolver, serial) do
    try do
      resolver.(serial)
    rescue
      _error -> nil
    catch
      _kind, _reason -> nil
    end
  end

  defp payload_dist_snapshot(beam_dirs) do
    beam_dirs
    |> Enum.flat_map(&Path.wildcard(Path.join(&1, "*.beam")))
    |> Enum.sort()
    |> HotPush.prepare()
  end

  defp payload_archive_identity(path) do
    with :ok <- File.chmod(path, 0o400),
         {:ok, %{type: :regular, size: size}} <- File.stat(path),
         true <- size in 1..@max_android_payload_bytes,
         {:ok, sha256} <- file_sha256_hex(path) do
      {:ok, %{path: path, size: size, sha256: sha256}}
    else
      _failure -> {:error, "Immutable Android archive identity is invalid"}
    end
  end

  defp file_sha256_hex(path) do
    case File.open(path, [:read, :binary], fn io -> hash_file(io, :crypto.hash_init(:sha256)) end) do
      {:ok, digest} when is_binary(digest) -> {:ok, Base.encode16(digest, case: :lower)}
      _failure -> {:error, :hash_failed}
    end
  end

  defp hash_file(io, context) do
    case IO.binread(io, 1_048_576) do
      :eof -> :crypto.hash_final(context)
      bytes when is_binary(bytes) -> hash_file(io, :crypto.hash_update(context, bytes))
      {:error, _reason} -> {:error, :read_failed}
    end
  end

  defp default_priv_dir do
    path = Path.join(File.cwd!(), "priv")
    if File.dir?(path), do: path, else: nil
  end

  defp validate_payload_serials(serials) when is_list(serials) and serials != [] do
    valid = Enum.all?(serials, &(validate_adb_serial(&1) == :ok))
    folded = Enum.map(serials, &String.downcase/1)

    if valid and serials == Enum.sort(serials) and Enum.uniq(serials) == serials and
         Enum.uniq(folded) == folded and length(serials) <= 32,
       do: :ok,
       else: {:error, "Android target identity is invalid"}
  end

  defp validate_payload_serials(_serials), do: {:error, "Android target identity is invalid"}

  defp validate_selected_abis(abis) when is_list(abis) do
    if abis != [] and abis == Enum.sort(abis) and Enum.uniq(abis) == abis and
         Enum.all?(abis, &(&1 in @android_abis)),
       do: :ok,
       else: {:error, "Android ABI identity is invalid"}
  end

  defp validate_selected_abis(_abis), do: {:error, "Android ABI identity is invalid"}

  defp valid_hex_sha256?(value) when is_binary(value) do
    byte_size(value) == 64 and Regex.match?(Regex.compile!("\\A[0-9a-f]{64}\\z"), value)
  end

  defp valid_hex_sha256?(_value), do: false

  defp validate_android_payload_shape(
         %{
           version: 1,
           package: package,
           attempt_id: attempt_id,
           serials: serials,
           selected_abis: selected_abis,
           selected_abis_by_serial: selected_by_serial,
           apk: apk,
           beam: beam,
           exqlite: exqlite,
           restart_by_serial: restart_by_serial
         } = plan
       ) do
    with true <- map_size(plan) == 10,
         :ok <- validate_android_package(package),
         {:ok, ^attempt_id} <- android_attempt_id(attempt_id: attempt_id),
         :ok <- validate_payload_serials(serials),
         :ok <- validate_selected_abis(selected_abis),
         true <- is_map(selected_by_serial) and Enum.sort(Map.keys(selected_by_serial)) == serials,
         true <- Enum.all?(selected_by_serial, fn {_serial, abi} -> abi in selected_abis end),
         true <- selected_abis == selected_by_serial |> Map.values() |> Enum.uniq() |> Enum.sort(),
         {:ok, root} <- validate_payload_apk_shape(apk, attempt_id),
         :ok <- validate_payload_beam_shape(beam, root, package, attempt_id),
         :ok <- validate_payload_exqlite_shape(exqlite, root, package, attempt_id, selected_abis),
         :ok <- validate_restart_map_shape(restart_by_serial, package, serials) do
      :ok
    else
      _invalid -> {:error, :invalid_android_payload}
    end
  end

  defp validate_android_payload_shape(_plan), do: {:error, :invalid_android_payload}

  defp validate_fast_android_payload_shape(
         %{
           version: 1,
           operation: :fast,
           package: package,
           attempt_id: attempt_id,
           serials: serials,
           selected_abis: selected_abis,
           beam: beam,
           exqlite: exqlite,
           restart_by_serial: restart_by_serial
         } = plan
       ) do
    root =
      case beam do
        %{archive: %{path: path}} when is_binary(path) -> Path.dirname(path)
        _invalid -> nil
      end

    with true <- map_size(plan) == 9,
         :ok <- validate_android_package(package),
         {:ok, ^attempt_id} <- android_attempt_id(attempt_id: attempt_id),
         :ok <- validate_payload_serials(serials),
         :ok <- validate_selected_abis(selected_abis),
         true <- is_binary(root),
         true <- Path.basename(root) == "mob_android_fast_payload_#{attempt_id}",
         :ok <- validate_payload_beam_shape(beam, root, package, attempt_id),
         :ok <- validate_payload_exqlite_shape(exqlite, root, package, attempt_id, selected_abis),
         :ok <- validate_restart_map_shape(restart_by_serial, package, serials) do
      :ok
    else
      _invalid -> {:error, :invalid_fast_android_payload}
    end
  end

  defp validate_fast_android_payload_shape(_plan),
    do: {:error, :invalid_fast_android_payload}

  defp validate_payload_apk_shape(%{path: path, size: size, sha256: sha256} = apk, attempt_id) do
    root = if is_binary(path), do: Path.dirname(path), else: nil

    if map_size(apk) == 3 and is_binary(root) and
         Path.basename(root) == "mob_android_payload_#{attempt_id}" and
         path == Path.join(root, "payload.apk") and is_integer(size) and
         size in 1..@max_android_payload_bytes and valid_hex_sha256?(sha256) do
      {:ok, root}
    else
      {:error, :invalid_apk}
    end
  end

  defp validate_payload_apk_shape(_apk, _attempt_id), do: {:error, :invalid_apk}

  defp validate_payload_beam_shape(beam, root, package, attempt_id) when is_map(beam) do
    app_root = "/data/data/#{package}/files"

    with %{
           archive: archive,
           stage_device: "/data/local/tmp/mob_beams_" <> stage_tail,
           app_stage: app_stage,
           app_backup: app_backup,
           activation_lock: activation_lock,
           dist_snapshot: snapshot,
           runtime_version: runtime_version,
           beam_flags: beam_flags
         } <- beam,
         true <- map_size(beam) == 8,
         true <- stage_tail == "#{attempt_id}.tar",
         :ok <- validate_archive_shape(archive, Path.join(root, "beams.tar")),
         true <- app_stage == "#{app_root}/.mob_beams_stage_#{attempt_id}",
         true <- app_backup == "#{app_root}/.mob_beams_backup_#{attempt_id}",
         true <- activation_lock == "#{app_root}/.mob_beams_activation_lock",
         :ok <- HotPush.validate_prepared_snapshot(snapshot),
         true <- runtime_version == System.version(),
         true <-
           is_nil(beam_flags) or
             (is_binary(beam_flags) and byte_size(beam_flags) <= 4_096 and
                String.valid?(beam_flags)) do
      :ok
    else
      _invalid -> {:error, :invalid_beam_payload}
    end
  end

  defp validate_payload_beam_shape(_beam, _root, _package, _attempt_id),
    do: {:error, :invalid_beam_payload}

  defp validate_payload_exqlite_shape(nil, _root, _package, _attempt_id, _abis), do: :ok

  defp validate_payload_exqlite_shape(exqlite, root, package, attempt_id, abis)
       when is_map(exqlite) do
    lib_root = "/data/data/#{package}/files/otp/lib"

    with %{
           archive: archive,
           stage_device: "/data/local/tmp/mob_exqlite_" <> stage_tail,
           app_stage: app_stage,
           app_backup: app_backup,
           activation_lock: activation_lock,
           app_version: app_version,
           beam_sentinel: sentinel,
           nif: nif
         } <- exqlite,
         true <- map_size(exqlite) == 8,
         true <- stage_tail == "#{attempt_id}.tar",
         :ok <- validate_archive_shape(archive, Path.join(root, "exqlite.tar")),
         :ok <- validate_exqlite_version(app_version),
         true <- app_stage == "#{lib_root}/.mob_exqlite_stage_#{attempt_id}",
         true <- app_backup == "#{lib_root}/.mob_exqlite_backup_#{attempt_id}",
         true <- activation_lock == "#{lib_root}/.mob_exqlite_activation_lock",
         {:ok, ^sentinel} <- validate_beam_sentinel(sentinel),
         :ok <- validate_nif_plan_shape(nif, abis) do
      :ok
    else
      _invalid -> {:error, :invalid_exqlite_payload}
    end
  end

  defp validate_payload_exqlite_shape(_value, _root, _package, _attempt_id, _abis),
    do: {:error, :invalid_exqlite_payload}

  defp validate_nif_plan_shape(
         %{
           source: :installed_apk,
           filename: "libsqlite3_nif.so",
           selected_abis: abis,
           required_apk_entries: entries
         } = nif,
         abis
       ) do
    expected = Map.new(abis, &{&1, "lib/#{&1}/libsqlite3_nif.so"})

    if map_size(nif) == 4 and entries == expected,
      do: :ok,
      else: {:error, :invalid_nif_plan}
  end

  defp validate_nif_plan_shape(_nif, _abis), do: {:error, :invalid_nif_plan}

  defp validate_archive_shape(%{path: path, size: size, sha256: sha256} = archive, expected) do
    if map_size(archive) == 3 and path == expected and is_integer(size) and
         size in 1..@max_android_payload_bytes and valid_hex_sha256?(sha256),
       do: :ok,
       else: {:error, :invalid_archive}
  end

  defp validate_archive_shape(_archive, _expected), do: {:error, :invalid_archive}

  defp valid_payload_checks?(checks) when is_list(checks) and checks != [] do
    length(checks) <= 64 and Enum.uniq(checks) == checks and
      Enum.all?(checks, fn
        {kind, path} when kind in [:file, :dir] -> safe_android_relative_path?(path)
        _invalid -> false
      end)
  end

  defp valid_payload_checks?(_checks), do: false

  defp validate_restart_map_shape(restart_by_serial, package, serials)
       when is_map(restart_by_serial) do
    if Enum.sort(Map.keys(restart_by_serial)) == serials and
         Enum.all?(restart_by_serial, fn {_serial, record} ->
           valid_restart_record?(record, package)
         end),
       do: :ok,
       else: {:error, :invalid_restart_map}
  end

  defp validate_restart_map_shape(_restart_by_serial, _package, _serials),
    do: {:error, :invalid_restart_map}

  defp valid_restart_record?(record, package) when is_map(record) do
    with %{
           package: ^package,
           activity: activity,
           restart?: restart,
           mode: mode,
           dist_port: port,
           node_suffix: suffix
         } <- record,
         true <- map_size(record) == 6,
         true <- restart in [true, false],
         true <- mode == if(restart, do: :checked_restart, else: :no_restart),
         :ok <- validate_android_activity(activity),
         :ok <- validate_android_dist_port(port),
         :ok <- validate_android_node_suffix(suffix) do
      true
    else
      _invalid -> false
    end
  end

  defp valid_restart_record?(_record, _package), do: false

  defp register_android_payload(plan, root, beam_checks) do
    paths = payload_artifact_paths(plan)

    if plan_root(plan) == root and Enum.all?(paths, &(Path.dirname(&1) == root)) and
         valid_payload_checks?(beam_checks) do
      registry = Process.get(@payload_registry_key, %{})

      entry = %{
        root: root,
        paths: paths,
        beam_checks: beam_checks,
        cleaned?: false
      }

      Process.put(@payload_registry_key, Map.put(registry, payload_registry_id(plan), entry))
      :ok
    else
      {:error, :invalid_payload_registry_entry}
    end
  end

  defp registered_android_payload?(plan) do
    match?({:ok, %{cleaned?: false}}, registered_android_payload(plan))
  end

  defp registered_android_payload(plan) do
    case Process.get(@payload_registry_key, %{}) |> Map.fetch(payload_registry_id(plan)) do
      {:ok, %{root: root, paths: paths} = entry}
      when is_binary(root) and is_list(paths) ->
        if root == plan_root(plan) and paths == payload_artifact_paths(plan) do
          {:ok, entry}
        else
          {:error, :payload_registry_mismatch}
        end

      _missing ->
        {:error, :payload_not_registered}
    end
  end

  defp payload_registry_id(plan) do
    :crypto.hash(:sha256, :erlang.term_to_binary(plan))
  end

  defp cleanup_registered_android_payload(_plan, %{cleaned?: true}), do: :ok

  defp cleanup_registered_android_payload(plan, %{root: root, paths: paths}) do
    with :ok <- remove_registered_payload_files(paths),
         :ok <- remove_registered_payload_root(root) do
      registry = Process.get(@payload_registry_key, %{})
      id = payload_registry_id(plan)
      Process.put(@payload_registry_key, put_in(registry, [id, :cleaned?], true))
      :ok
    end
  end

  defp remove_registered_payload_files(paths) do
    Enum.reduce_while(paths, :ok, fn path, :ok ->
      case File.rm(path) do
        :ok -> {:cont, :ok}
        {:error, :enoent} -> {:cont, :ok}
        {:error, _reason} -> {:halt, {:error, "Could not remove Android payload artifact"}}
      end
    end)
  end

  defp remove_registered_payload_root(root) do
    case File.rmdir(root) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _reason} -> {:error, "Could not remove empty Android payload staging"}
    end
  end

  defp valid_payload_artifact_identities?(plan) do
    identities =
      if(Map.has_key?(plan, :apk), do: [plan.apk], else: []) ++
        [plan.beam.archive] ++ if(plan.exqlite, do: [plan.exqlite.archive], else: [])

    paths = Enum.map(identities, & &1.path)

    Enum.uniq(paths) == paths and Enum.all?(identities, &valid_payload_artifact_identity?/1)
  end

  defp valid_payload_artifact_identity?(%{path: path, size: size, sha256: sha256} = identity)
       when map_size(identity) == 3 do
    with true <- is_binary(path) and Path.type(path) == :absolute,
         true <- is_integer(size) and size in 1..@max_android_payload_bytes,
         true <- valid_hex_sha256?(sha256),
         {:ok, %{type: :regular}} <- File.lstat(path),
         {:ok, %{type: :regular, size: ^size, mode: mode}} <- File.stat(path),
         true <- Bitwise.band(mode, 0o222) == 0,
         {:ok, ^sha256} <- file_sha256_hex(path) do
      true
    else
      _invalid -> false
    end
  end

  defp valid_payload_artifact_identity?(_identity), do: false

  defp payload_artifact_paths(plan) do
    if(Map.has_key?(plan, :apk), do: [plan.apk.path], else: []) ++
      [plan.beam.archive.path] ++
      if(is_map(plan.exqlite), do: [plan.exqlite.archive.path], else: [])
  end

  defp plan_root(plan) do
    if Map.has_key?(plan, :apk),
      do: Path.dirname(plan.apk.path),
      else: Path.dirname(plan.beam.archive.path)
  end

  defp cleanup_payload_root(root) do
    for name <- ["payload.apk", "beams.tar", "exqlite.tar"] do
      File.rm(Path.join(root, name))
    end

    File.rm_rf(root)
    :ok
  end

  defp ios_beams_dir do
    # The simulator's OTP_ROOT is resolved by `MobDev.Paths.sim_runtime_dir/1`.
    # New projects: ~/.mob/runtime/ios-sim. Legacy projects (build.sh predates
    # MOB_SIM_RUNTIME_DIR support): /tmp/otp-ios-sim. Either way, if that
    # directory exists deploy beams there so the running BEAM picks them up
    # immediately. Fall back to the cache dir on a fresh machine that hasn't
    # done its first --native build yet.
    runtime_dir = MobDev.Paths.sim_runtime_dir()
    runtime_path = Path.join(runtime_dir, app_name())
    cache_path = Path.join(MobDev.OtpDownloader.ios_sim_otp_dir(), app_name())
    if File.dir?(runtime_dir), do: runtime_path, else: cache_path
  end

  @doc false
  @spec deploy_all_with_lease(keyword()) ::
          {{[Device.t()], [Device.t()], [Device.t()]}, map() | nil}
  def deploy_all_with_lease(opts) when is_list(opts) do
    case {Keyword.get(opts, :android_deploy_lock), Keyword.get(opts, :android_payload_plan)} do
      {%{} = lease, %{} = plan} ->
        deploy_native_android_with_lease(opts, lease, plan)

      {nil, nil} ->
        deploy_fast_or_non_android_with_lease(opts)

      _incomplete_authority ->
        devices = canonical_android_devices_for_failure(opts)
        reason = "Android deploy authority is incomplete; refusing device mutation"
        {{[], Enum.map(devices, &failed_android_device(&1, reason)), []}, nil}
    end
  end

  def deploy_all_with_lease(_opts), do: {{[], [], []}, nil}

  defp deploy_fast_or_non_android_with_lease(opts) do
    platforms = Keyword.get(opts, :platforms, [:android, :ios])

    if :android in platforms do
      deploy_fast_android_with_lease(opts, platforms)
    else
      {deploy_all_unleased(opts), nil}
    end
  end

  defp deploy_fast_android_with_lease(opts, platforms) do
    android_lister = Keyword.get(opts, :android_lister, &Android.list_devices/0)
    device_id = Keyword.get(opts, :device)
    canonical_serials = Keyword.get(opts, :canonical_android_serials)

    devices =
      android_lister.()
      |> select_android_devices!(device_id, canonical_serials)
      |> Enum.sort_by(& &1.serial)

    if devices == [] do
      remaining = Keyword.put(opts, :platforms, platforms -- [:android])
      {deploy_all_unleased(remaining), nil}
    else
      package = bundle_id()
      package_runner = Keyword.get(opts, :android_package_runner, &run_android_lock_command/1)

      case preflight_fast_android_targets(devices, package, package_runner) do
        {:ok, [], skipped} ->
          ios_result =
            opts
            |> Keyword.put(:platforms, platforms -- [:android])
            |> deploy_all_unleased()

          {merge_device_results({[], [], skipped}, ios_result), nil}

        {:ok, installed, skipped} ->
          IO.puts("  Pushing authoritative BEAM payload to #{length(installed)} device(s)...")

          {result, lease} = run_fast_android_operation(installed, opts, platforms)
          {merge_device_results(result, {[], [], skipped}), lease}

        {:error, reason} ->
          {{[], Enum.map(devices, &failed_android_device(&1, reason)), []}, nil}
      end
    end
  end

  defp preflight_fast_android_targets(devices, package, runner) do
    Enum.reduce_while(devices, {:ok, [], []}, fn device, {:ok, installed, skipped} ->
      result = runner.(["-s", device.serial, "shell", "pm", "list", "packages", package])

      case classify_android_package_probe(result, package) do
        :installed ->
          {:cont, {:ok, [device | installed], skipped}}

        :absent ->
          reason = "#{package} is not installed; Android target was not mutated"
          skipped_device = %{device | status: :skipped, error: reason}
          {:cont, {:ok, installed, [skipped_device | skipped]}}

        {:error, _reason} ->
          {:halt, {:error, "Android package preflight was ambiguous"}}
      end
    end)
    |> case do
      {:ok, installed, skipped} -> {:ok, Enum.reverse(installed), Enum.reverse(skipped)}
      {:error, _reason} = error -> error
    end
  rescue
    _error -> {:error, "Android package preflight was ambiguous"}
  catch
    _kind, _reason -> {:error, "Android package preflight was ambiguous"}
  end

  defp run_fast_android_operation(devices, opts, platforms) do
    package = bundle_id()
    serials = Enum.map(devices, & &1.serial)
    lock_runner = Keyword.get(opts, :android_lock_runner, &run_android_lock_command/1)
    prepare = Keyword.get(opts, :fast_android_payload_preparer, &prepare_fast_android_payload/3)

    with {:ok, plan} <-
           prepare.(devices, package,
             operation: :fast,
             restart: Keyword.get(opts, :restart, true),
             beam_flags: Keyword.get(opts, :beam_flags),
             dist_port: Keyword.get(opts, :dist_port),
             node_suffix: Keyword.get(opts, :node_suffix),
             beam_dirs: Keyword.get(opts, :beam_dirs, collect_android_beam_dirs()),
             priv_dir: Keyword.get(opts, :priv_dir, default_priv_dir()),
             exqlite_source: Keyword.get(opts, :exqlite_source, :auto),
             tmp_root: Keyword.get(opts, :tmp_root, System.tmp_dir!()),
             node_suffix_resolver:
               Keyword.get(opts, :node_suffix_resolver, &Android.device_node_suffix/1)
           ) do
      try do
        identity = %{package: package, serials: serials}

        with true <- valid_fast_android_payload?(plan, identity),
             {:ok, lease} <- AndroidDeployLock.acquire(package, serials, lock_runner) do
          result = deploy_fast_android_targets(devices, opts, lease, plan, identity, lock_runner)

          finalize_fast_android_operation(result, opts, platforms, lock_runner)
        else
          false ->
            reason = "Fast Android payload is invalid or changed"
            {{[], Enum.map(devices, &failed_android_device(&1, reason)), []}, nil}

          {:error, %{lease: retained} = failure} ->
            reason = AndroidDeployLock.message(failure)
            {{[], Enum.map(devices, &failed_android_device(&1, reason)), []}, retained}
        end
      after
        cleanup_deploy_payload(plan)
      end
    else
      {:error, reason} ->
        {{[], Enum.map(devices, &failed_android_device(&1, reason)), []}, nil}

      _invalid ->
        reason = "Could not prepare authoritative fast Android payload"
        {{[], Enum.map(devices, &failed_android_device(&1, reason)), []}, nil}
    end
  end

  defp deploy_fast_android_targets(devices, opts, lease, plan, identity, lock_runner) do
    case connected_fast_android_nodes(devices, opts) do
      {:ok, nodes, hot_push_devices} ->
        deploy_fast_android_via_dist(
          devices,
          nodes,
          hot_push_devices,
          opts,
          lease,
          plan,
          identity,
          lock_runner
        )

      :filesystem ->
        deploy_native_android_targets(devices, opts, lease, plan, identity, lock_runner)
    end
  end

  defp connected_fast_android_nodes(devices, opts) do
    if Keyword.get(opts, :force_fs, false) do
      :filesystem
    else
      connected = Keyword.get(opts, :connected_nodes, [Node.self() | Node.list()])

      if is_list(connected) and Enum.all?(connected, &is_atom/1) do
        nodes = Enum.map(devices, &Device.node_name/1)

        if nodes != [] and Enum.uniq(nodes) == nodes and Enum.all?(nodes, &(&1 in connected)) do
          hot_push_devices =
            Enum.zip_with(devices, nodes, fn device, node -> %{device | node: node} end)

          {:ok, nodes, hot_push_devices}
        else
          :filesystem
        end
      else
        :filesystem
      end
    end
  end

  defp deploy_fast_android_via_dist(
         devices,
         nodes,
         hot_push_devices,
         opts,
         lease,
         plan,
         identity,
         lock_runner
       ) do
    rpc = Keyword.get(opts, :hot_push_rpc, &hot_push_load_rpc/4)
    post_push = Keyword.get(opts, :hot_push_post_push, &hot_push_repaint/1)

    with :ok <- payload_deploy_barrier(plan, identity, lease, lock_runner),
         {pushed, []} when pushed == length(plan.beam.dist_snapshot) <-
           HotPush.push_prepared_fenced(nodes, plan.beam.dist_snapshot,
             package: identity.package,
             android_devices: hot_push_devices,
             android_deploy_lock: lease,
             expected_lock_phase: lease.phase,
             lock_runner: lock_runner,
             rpc: rpc,
             post_push: post_push
           ),
         :ok <- payload_deploy_barrier(plan, identity, lease, lock_runner),
         {:ok, committed} <-
           AndroidDeployLock.transition(lease, :acquired, :fast_committed, lock_runner) do
      {{devices, [], []}, committed}
    else
      {0, failures} when is_list(failures) ->
        failed_fast_dist_result(devices, lease, lock_runner, "Android hot push failed closed")

      {partial_count, failures} when is_integer(partial_count) and is_list(failures) ->
        failed_fast_dist_result(
          devices,
          lease,
          lock_runner,
          "Android hot push result was ambiguous"
        )

      {:error, %{lease: retained}} ->
        reason = "Android hot push commit became ambiguous; deploy lease retained"
        {{[], Enum.map(devices, &failed_android_device(&1, reason)), []}, retained}

      {:error, _reason} ->
        failed_fast_dist_result(
          devices,
          lease,
          lock_runner,
          "Android hot push authority changed"
        )

      _invalid ->
        failed_fast_dist_result(
          devices,
          lease,
          lock_runner,
          "Android hot push returned an invalid result"
        )
    end
  end

  defp failed_fast_dist_result(devices, lease, lock_runner, reason) do
    retained = retained_lease_after_failure(lease, lock_runner)
    {{[], Enum.map(devices, &failed_android_device(&1, reason)), []}, retained}
  end

  defp hot_push_load_rpc(node, module, filename, binary) do
    :rpc.call(node, :code, :load_binary, [module, filename, binary])
  end

  defp hot_push_repaint(node) do
    case :rpc.call(node, :erlang, :send, [:mob_screen, :__mob_hot_reload__]) do
      {:badrpc, _reason} -> {:error, :repaint_failed}
      _sent_message -> :ok
    end
  rescue
    _error -> {:error, :repaint_failed}
  catch
    _kind, _reason -> {:error, :repaint_failed}
  end

  defp finalize_fast_android_operation(
         {{deployed, [], []}, %{phase: :fast_committed} = committed},
         opts,
         platforms,
         lock_runner
       ) do
    case AndroidDeployLock.release(committed, lock_runner) do
      :ok ->
        ios_result =
          if :ios in platforms do
            opts
            |> Keyword.put(:platforms, [:ios])
            |> deploy_all_unleased()
          else
            {[], [], []}
          end

        {merge_device_results({deployed, [], []}, ios_result), nil}

      {:error, %{lease: retained}} ->
        reason = "Fast Android deploy committed but lease release is ambiguous"
        failures = Enum.map(deployed, &failed_android_device(&1, reason))
        {{[], failures, []}, retained}
    end
  end

  defp finalize_fast_android_operation({result, retained}, _opts, _platforms, _lock_runner),
    do: {result, retained}

  defp merge_device_results({deployed_a, failed_a, skipped_a}, {deployed_b, failed_b, skipped_b}) do
    {deployed_a ++ deployed_b, failed_a ++ failed_b, skipped_a ++ skipped_b}
  end

  defp deploy_native_android_with_lease(opts, lease, plan) do
    package = bundle_id()
    serials = Keyword.get(opts, :canonical_android_serials, [])
    lock_runner = Keyword.get(opts, :android_lock_runner, &run_android_lock_command/1)
    android_lister = Keyword.get(opts, :android_lister, &Android.list_devices/0)

    devices =
      android_lister.()
      |> select_android_devices!(nil, serials)

    identity = %{package: package, serials: serials}

    cond do
      not AndroidDeployLock.valid?(lease, :native_ready) or lease.bundle_id != package or
          lease.serials != serials ->
        reason = "Native Android deploy lease identity is invalid"
        {{[], Enum.map(devices, &failed_android_device(&1, reason)), []}, nil}

      not valid_android_payload?(plan, identity) ->
        reason = "Authoritative Android payload is invalid or changed"
        retained = %{lease | state: :retained_failure}
        {{[], Enum.map(devices, &failed_android_device(&1, reason)), []}, retained}

      true ->
        deploy_native_android_targets(devices, opts, lease, plan, identity, lock_runner)
    end
  rescue
    _error ->
      devices = canonical_android_devices_for_failure(opts)
      reason = "Native Android final deploy failed before commit"
      retained = if is_map(lease), do: Map.put(lease, :state, :retained_ambiguous), else: nil
      {{[], Enum.map(devices, &failed_android_device(&1, reason)), []}, retained}
  catch
    _kind, _reason ->
      devices = canonical_android_devices_for_failure(opts)
      reason = "Native Android final deploy failed before commit"
      retained = if is_map(lease), do: Map.put(lease, :state, :retained_ambiguous), else: nil
      {{[], Enum.map(devices, &failed_android_device(&1, reason)), []}, retained}
  end

  defp deploy_native_android_targets(devices, opts, lease, plan, identity, lock_runner) do
    commit_phase = if lease.phase == :native_ready, do: :final_committed, else: :fast_committed

    case deploy_native_android_targets_ordered(
           devices,
           opts,
           lease,
           plan,
           identity,
           lock_runner,
           []
         ) do
      {:ok, deployed} ->
        with :ok <- payload_deploy_barrier(plan, identity, lease, lock_runner),
             {:ok, committed} <-
               AndroidDeployLock.transition(
                 lease,
                 lease.phase,
                 commit_phase,
                 lock_runner
               ) do
          {{Enum.reverse(deployed), [], []}, committed}
        else
          {:error, %{lease: retained}} ->
            reason = "Android final commit became ambiguous; deploy lease retained"
            failures = Enum.map(Enum.reverse(deployed), &failed_android_device(&1, reason))
            {{[], failures, []}, retained}

          {:error, _reason} ->
            reason = "Android payload changed before final commit; deploy lease retained"
            retained = %{lease | state: :retained_failure}
            failures = Enum.map(Enum.reverse(deployed), &failed_android_device(&1, reason))
            {{[], failures, []}, retained}
        end

      {:error, deployed, failed, remaining, retained} ->
        reason = failed.error || "Native Android final deploy failed"

        indeterminate =
          deployed
          |> Enum.reverse()
          |> Enum.map(
            &failed_android_device(
              &1,
              "Device mutation is indeterminate because the exact set did not commit"
            )
          )

        halted = Enum.map(remaining, &failed_android_device(&1, "Operation halted: #{reason}"))
        {{[], indeterminate ++ [failed | halted], []}, retained}
    end
  end

  defp deploy_native_android_targets_ordered(
         [],
         _opts,
         _lease,
         _plan,
         _identity,
         _lock_runner,
         deployed
       ),
       do: {:ok, deployed}

  defp deploy_native_android_targets_ordered(
         [device | remaining],
         opts,
         lease,
         plan,
         identity,
         lock_runner,
         deployed
       ) do
    result =
      with :ok <- payload_deploy_barrier(plan, identity, lease, lock_runner) do
        case Keyword.get(opts, :device_deployer) do
          deployer when is_function(deployer, 1) -> deployer.(device)
          nil -> deploy_android_payload_plan(device, plan, identity, lease, lock_runner, opts)
          _invalid -> {:error, "Android device deployer is invalid"}
        end
      end

    case result do
      {:ok, %Device{} = deployed_device} ->
        deploy_native_android_targets_ordered(
          remaining,
          opts,
          lease,
          plan,
          identity,
          lock_runner,
          [deployed_device | deployed]
        )

      {:skipped, reason} ->
        retained = retained_lease_after_failure(lease, lock_runner)
        failed = failed_android_device(device, bounded_deploy_reason(reason))
        {:error, deployed, failed, remaining, retained}

      {:error, reason} ->
        retained = retained_lease_after_failure(lease, lock_runner)
        failed = failed_android_device(device, bounded_deploy_reason(reason))
        {:error, deployed, failed, remaining, retained}

      _invalid ->
        retained = retained_lease_after_failure(lease, lock_runner)
        failed = failed_android_device(device, "Android device deploy returned an invalid result")
        {:error, deployed, failed, remaining, retained}
    end
  end

  defp deploy_android_payload_plan(device, plan, identity, lease, lock_runner, opts) do
    serial = device.serial
    package = identity.package
    runner = Keyword.get(opts, :android_runner, &run_adb/1)

    fenced_runner = fn args ->
      case payload_deploy_barrier(plan, identity, lease, lock_runner) do
        :ok -> runner.(args)
        {:error, _reason} -> {:error, "Android payload or deploy lease changed"}
      end
    end

    restart = Map.fetch!(plan.restart_by_serial, serial)
    app_data = "/data/data/#{package}/files"
    beams_dir = "#{app_data}/otp/#{app_name()}"

    with :installed <-
           probe_installed_android_package(serial, package, plan, identity, lease, lock_runner),
         :ok <- ensure_erts_on_device(serial, package, fenced_runner),
         :ok <-
           verify_elixir_runtime_version_android(
             serial,
             package,
             app_data,
             plan.beam.runtime_version,
             fenced_runner
           ),
         {:ok, %{beam_checks: beam_checks}} <- registered_android_payload(plan),
         :ok <-
           push_staged_beams(
             fenced_runner,
             serial,
             package,
             beams_dir,
             plan.beam.archive.path,
             plan.beam.stage_device,
             plan.beam.app_stage,
             plan.beam.app_backup,
             plan.beam.activation_lock,
             beam_checks
           ),
         :ok <- deploy_payload_exqlite(serial, package, plan.exqlite, fenced_runner),
         :ok <-
           if(restart.restart?,
             do:
               restart_android(
                 serial,
                 [
                   package: restart.package,
                   activity: restart.activity,
                   dist_port: restart.dist_port,
                   node_suffix: restart.node_suffix,
                   sleeper: Keyword.get(opts, :sleeper, &:timer.sleep/1),
                   operation_authority: {plan, identity, lease, lock_runner}
                 ],
                 fenced_runner
               ),
             else: :ok
           ) do
      {:ok, device}
    else
      :absent -> {:error, "Native Android target became unavailable after install"}
      {:error, reason} -> {:error, bounded_deploy_reason(reason)}
      _invalid -> {:error, "Android payload deployment failed closed"}
    end
  end

  defp deploy_payload_exqlite(_serial, _package, nil, _runner), do: :ok

  defp deploy_payload_exqlite(serial, package, exqlite, runner) do
    live_dir = "/data/data/#{package}/files/otp/lib/exqlite-#{exqlite.app_version}"

    with {:ok, nif_target} <- resolve_exqlite_nif_target(serial, package, runner, []),
         :ok <-
           push_staged_exqlite(
             runner,
             serial,
             package,
             exqlite.archive.path,
             exqlite.stage_device,
             live_dir,
             exqlite.app_stage,
             exqlite.app_backup,
             exqlite.activation_lock,
             nif_target,
             exqlite.beam_sentinel
           ) do
      :ok
    end
  end

  defp probe_installed_android_package(serial, package, plan, identity, lease, lock_runner) do
    with :ok <- payload_deploy_barrier(plan, identity, lease, lock_runner) do
      lock_runner.(["-s", serial, "shell", "pm", "list", "packages", package])
      |> classify_android_package_probe(package)
    end
  end

  defp payload_deploy_barrier(plan, identity, lease, lock_runner) do
    with true <- valid_deploy_payload?(plan, identity),
         :ok <- verify_android_lease_set(lease, lock_runner) do
      :ok
    else
      false -> {:error, :payload_changed}
      {:error, _failure} = error -> error
    end
  end

  defp validate_android_operation_authority(
         {plan, %{package: package, serials: serials} = identity, lease, lock_runner},
         serial,
         package
       )
       when is_list(serials) and is_function(lock_runner, 1) do
    if serial in serials and is_map(lease) and lease.serials == serials do
      case payload_deploy_barrier(plan, identity, lease, lock_runner) do
        :ok -> :ok
        {:error, _reason} -> {:error, "Android operation authority is not current"}
      end
    else
      {:error, "Android operation authority does not cover this target"}
    end
  end

  defp validate_android_operation_authority(_authority, _serial, _package),
    do: {:error, "Android mutation requires an operation-wide deploy lease"}

  defp fenced_android_operation_runner(authority, serial, package, runner) do
    fn args ->
      case validate_android_operation_authority(authority, serial, package) do
        :ok -> runner.(args)
        {:error, _reason} -> {:error, "Android operation authority changed"}
      end
    end
  end

  defp verify_android_lease_set(lease, lock_runner) do
    Enum.reduce_while(lease.serials, :ok, fn serial, :ok ->
      case AndroidDeployLock.verify_owner(lease, serial, lock_runner) do
        :ok -> {:cont, :ok}
        {:error, failure} -> {:halt, {:error, failure}}
      end
    end)
  end

  defp retained_lease_after_failure(lease, lock_runner) do
    case verify_android_lease_set(lease, lock_runner) do
      :ok -> %{lease | state: :retained_failure}
      {:error, %{lease: retained}} -> retained
      {:error, _failure} -> %{lease | state: :retained_ambiguous}
    end
  end

  defp canonical_android_devices_for_failure(opts) do
    opts
    |> Keyword.get(:canonical_android_serials, [])
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&%Device{platform: :android, serial: &1})
  end

  defp failed_android_device(%Device{} = device, reason) do
    %{device | status: :error, error: bounded_deploy_reason(reason)}
  end

  defp bounded_deploy_reason(reason) when is_binary(reason) do
    if String.valid?(reason), do: String.slice(reason, 0, 512), else: "Android deploy failed"
  end

  defp bounded_deploy_reason(_reason), do: "Android deploy failed"

  defp run_android_lock_command(args) do
    System.cmd("adb", args, stderr_to_stdout: true)
  rescue
    _error -> {"", 1}
  catch
    _kind, _reason -> {"", 1}
  end

  @doc """
  Discovers devices, pushes BEAMs, and optionally restarts apps.
  Returns `{deployed, failed, skipped}` lists of `%Device{}`.
  `skipped` is the deploy-isn't-applicable case — e.g. the app
  isn't installed on a device because only the other platform was
  built. Distinct from `failed` (real error during push).
  """
  @spec deploy_all(keyword()) :: {[Device.t()], [Device.t()], [Device.t()]}
  def deploy_all(opts \\ []) do
    {result, _lease} = deploy_all_with_lease(opts)
    result
  end

  defp deploy_all_unleased(opts) do
    restart = Keyword.get(opts, :restart, true)
    platforms = Keyword.get(opts, :platforms, [:android, :ios])
    force_fs = Keyword.get(opts, :force_fs, false)
    device_id = Keyword.get(opts, :device, nil)
    ios_device_id = Keyword.get(opts, :ios_device, nil)
    canonical_android_serials = Keyword.get(opts, :canonical_android_serials, nil)
    android_lister = Keyword.get(opts, :android_lister, &Android.list_devices/0)
    device_deployer = Keyword.get(opts, :device_deployer, nil)
    beam_flags = Keyword.get(opts, :beam_flags, nil)
    beam_dirs = collect_beam_dirs()

    android =
      if :android in platforms,
        do:
          android_lister.()
          |> select_android_devices!(device_id, canonical_android_serials),
        else: []

    ios =
      if :ios in platforms,
        do: IOS.list_devices() |> filter_by_device_id(ios_device_id || device_id),
        else: []

    all = android ++ ios

    if all == [] do
      IO.puts("  #{color(:yellow)}No devices found.#{color(:reset)}")
      {[], [], []}
    else
      IO.puts("  Pushing #{count_beams(beam_dirs)} BEAM file(s) to #{length(all)} device(s)...")

      # Try Erlang dist first — hot-loads modules with no restart. We set up
      # tunnels and attempt Node.connect for each device; those that respond
      # get BEAMs via RPC, the rest fall back to adb/cp + restart.
      # force_fs: true skips dist and always writes to the filesystem — required
      # after a native build/install where the old BEAM process is dead.
      dist_nodes = if force_fs or is_function(device_deployer, 1), do: [], else: connect_dist(all)

      # Manual overrides from `mix mob.deploy --dist-port N --node-suffix X`.
      # When set, all targeted devices share the same port/suffix (the user
      # is being explicit about a single device they care about). The
      # auto-allocated per-device values (one port per index, suffix per
      # serial/UDID) only apply when these are nil.
      dist_port_override = Keyword.get(opts, :dist_port)
      node_suffix_override = Keyword.get(opts, :node_suffix)

      results =
        all
        |> Enum.map(fn device ->
          IO.write("  #{device.name || device.serial}  →  pushing...")
          # Serial-derived so the port a device is deployed to listen on matches
          # what `mix mob.connect` later forwards to (same crc32(serial) base).
          dist_port = dist_port_override || Tunnel.serial_base_port(device.serial)
          node = Device.node_name(device)

          {method, result} =
            cond do
              is_function(device_deployer, 1) ->
                {:injected, device_deployer.(device)}

              node in dist_nodes ->
                {:dist, push_via_dist(node, device)}

              true ->
                fallback =
                  case device.platform do
                    :android ->
                      deploy_android(device, beam_dirs,
                        restart: restart,
                        dist_port: dist_port,
                        node_suffix: node_suffix_override,
                        beam_flags: beam_flags,
                        android_deploy_lock: Keyword.get(opts, :android_deploy_lock)
                      )

                    :ios ->
                      deploy_ios(device, beam_dirs,
                        restart: restart,
                        dist_port: dist_port,
                        node_suffix: node_suffix_override,
                        beam_flags: beam_flags
                      )
                  end

                {:adb, fallback}
            end

          case result do
            {:ok, d} ->
              suffix = if method == :dist, do: " (dist, no restart)", else: ""
              IO.puts(" #{color(:green)}✓#{suffix}#{color(:reset)}")
              {:ok, d}

            {:skipped, reason} ->
              # Yellow dash, not a red x — this device wasn't a target.
              IO.puts(
                " #{color(:yellow)}—#{color(:reset)} #{color(:faint)}#{reason}#{color(:reset)}"
              )

              {:skipped, %{device | status: :skipped, error: reason}}

            {:error, reason} ->
              IO.puts(" #{color(:red)}✗#{color(:reset)}")
              IO.puts("    #{color(:red)}#{reason}#{color(:reset)}")
              {:error, %{device | status: :error, error: reason}}
          end
        end)

      categorize_results(results)
    end
  end

  @doc """
  Bucket a per-device results list into `{deployed, failed, skipped}`.

  Three outcomes:

    * `:ok` — push succeeded → `deployed`
    * `:skipped` — device wasn't a target (e.g. app not installed,
      typical when only one platform was built) → `skipped`
    * `:error` — push attempted and failed for a real reason → `failed`

  Public so the categorization invariant (skipped never crosses into
  failed; an unknown outcome isn't silently dropped) can be tested
  independent of the hardware-dependent push pipeline.
  """
  @spec categorize_results([{:ok | :skipped | :error, Device.t()}]) ::
          {[Device.t()], [Device.t()], [Device.t()]}
  def categorize_results(results) do
    deployed = for {:ok, d} <- results, do: d
    failed = for {:error, d} <- results, do: d
    skipped = for {:skipped, d} <- results, do: d
    {deployed, failed, skipped}
  end

  @doc """
  True when the `adb shell pm list packages <pkg>` output indicates
  `<pkg>` is installed on the device.

  The check is a substring match for `package:<pkg>` because adb's
  output is one `package:<name>` line per matching package — empty
  output means "no match" (not "package called empty").

  Public so the rule can be regression-tested without an emulator.
  """
  @spec android_package_installed?(String.t(), String.t()) :: boolean()
  def android_package_installed?(pm_output, package_name) when is_binary(pm_output) do
    if byte_size(pm_output) <= @max_android_query_output_bytes and String.valid?(pm_output) do
      marker = "package:#{package_name}"

      pm_output
      |> String.split("\n")
      |> Enum.any?(&(String.trim(&1) == marker))
    else
      false
    end
  end

  @doc false
  @spec classify_android_package_probe(term(), String.t()) ::
          :installed | :absent | {:error, String.t()}
  def classify_android_package_probe({output, 0}, package_name) when is_binary(output) do
    cond do
      byte_size(output) > @max_android_query_output_bytes or not String.valid?(output) ->
        {:error, "verify installed Android app failed: invalid adb output"}

      android_package_installed?(output, package_name) ->
        :installed

      true ->
        :absent
    end
  end

  def classify_android_package_probe({_output, status}, _package_name) when is_integer(status),
    do: {:error, "verify installed Android app failed"}

  def classify_android_package_probe(_result, _package_name),
    do: {:error, "verify installed Android app failed: invalid command result"}

  # ── Device filtering ─────────────────────────────────────────────────────────

  @doc false
  @spec select_canonical_android_devices([Device.t()], [String.t()]) ::
          {:ok, [Device.t()]} | {:error, atom()}
  def select_canonical_android_devices(devices, canonical_serials)
      when is_list(devices) and is_list(canonical_serials) do
    cond do
      canonical_serials == [] ->
        {:error, :invalid_canonical_targets}

      Enum.any?(canonical_serials, &(not is_binary(&1) or &1 == "" or not String.valid?(&1))) ->
        {:error, :invalid_canonical_targets}

      Enum.uniq(canonical_serials) != canonical_serials ->
        {:error, :duplicate_canonical_target}

      true ->
        Enum.reduce_while(canonical_serials, {:ok, []}, fn serial, {:ok, selected} ->
          case select_canonical_android_device(devices, serial) do
            {:ok, device} -> {:cont, {:ok, [device | selected]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> case do
          {:ok, selected} -> {:ok, Enum.reverse(selected)}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def select_canonical_android_devices(_devices, _canonical_serials),
    do: {:error, :invalid_canonical_targets}

  defp select_android_devices!(devices, device_id, nil) do
    devices
    |> Enum.reject(&(&1.status == :unauthorized))
    |> filter_by_device_id(device_id)
  end

  defp select_android_devices!(devices, _device_id, canonical_serials) do
    case select_canonical_android_devices(devices, canonical_serials) do
      {:ok, selected} ->
        selected

      {:error, _reason} ->
        Mix.raise(
          "Canonical Android target set no longer matches discovery; refusing final deploy"
        )
    end
  end

  defp select_canonical_android_device(devices, serial) do
    case_insensitive = Enum.filter(devices, &same_android_serial?(&1, serial, :case_insensitive))
    exact = Enum.filter(case_insensitive, &same_android_serial?(&1, serial, :exact))

    cond do
      exact == [] and case_insensitive != [] -> {:error, :canonical_case_collision}
      exact == [] -> {:error, :canonical_target_missing}
      length(exact) > 1 -> {:error, :canonical_target_duplicated}
      length(case_insensitive) > 1 -> {:error, :canonical_case_collision}
      not canonical_android_device_ready?(hd(exact)) -> {:error, :canonical_target_unavailable}
      true -> {:ok, hd(exact)}
    end
  end

  defp same_android_serial?(%Device{serial: candidate}, serial, :exact),
    do: candidate == serial

  defp same_android_serial?(%Device{serial: candidate}, serial, :case_insensitive)
       when is_binary(candidate) do
    String.valid?(candidate) and String.downcase(candidate) == String.downcase(serial)
  end

  defp same_android_serial?(_device, _serial, :case_insensitive), do: false

  defp canonical_android_device_ready?(%Device{platform: :android, status: status}),
    do: status in [:discovered, :connected, :tunneled]

  defp canonical_android_device_ready?(_device), do: false

  defp filter_by_device_id(devices, nil), do: devices

  defp filter_by_device_id(devices, id) do
    case Enum.filter(devices, &Device.match_id?(&1, id)) do
      [] ->
        IO.puts("  #{color(:red)}No device matched \"#{id}\".#{color(:reset)}")

        IO.puts(
          "  Run #{color(:cyan)}mix mob.devices#{color(:reset)} to see available device IDs."
        )

        []

      matched ->
        matched
    end
  end

  # ── Android ─────────────────────────────────────────────────────────────────

  defp deploy_android(%Device{} = device, beam_dirs, opts) do
    deploy_android_device(device, beam_dirs, opts)
  end

  @doc false
  @spec deploy_android_device(Device.t(), [String.t()], keyword(), keyword()) ::
          {:ok | :skipped | :error, Device.t() | String.t()}
  def deploy_android_device(%Device{serial: serial}, _beam_dirs, _opts, _deps \\ []) do
    with :ok <- validate_adb_serial(serial) do
      {:error,
       "Direct Android device mutation is disabled; use deploy_all/1 for a fenced transaction"}
    end
  end

  # Verify the OTP runtime (erts-X.Y/bin/erl_child_setup) is present on
  # the device. Without this, the BEAM can't start — symlinks fail with
  # ENOENT, the app crashes immediately. This typically happens when the
  # device wasn't connected during a previous `mix mob.deploy --native`.
  #
  # Returns :ok if ERTS is present, {:error, message} with a helpful hint
  # if missing.
  @doc false
  @spec ensure_erts_on_device(String.t(), String.t(), ([String.t()] -> tuple())) ::
          :ok | {:error, String.t()}
  def ensure_erts_on_device(serial, pkg, runner \\ &run_adb/1) do
    with :ok <- validate_adb_serial(serial),
         :ok <- validate_android_package(pkg) do
      # The wildcard must be expanded *inside* the run-as sandbox — `run-as`
      # itself does not invoke a shell, and the outer adb-shell shell can't
      # see /data/data/<pkg>/, so expand the wildcard in an app-context shell.
      # `test -r` deliberately has no output contract: exit status is the
      # authoritative readability check.
      cmd =
        "run-as #{pkg} sh -c 'test -r /data/data/#{pkg}/files/otp/erts-*/bin/erl_child_setup'"

      case runner.(["-s", serial, "shell", cmd]) do
        {:ok, _out} ->
          :ok

        {:error, _reason} ->
          {:error,
           "Could not verify OTP runtime on #{bounded_device_label(serial)}; adb probe failed"}

        _other ->
          {:error,
           "Could not verify OTP runtime on #{bounded_device_label(serial)}: invalid adb result"}
      end
    end
  end

  # If the Elixir stdlib on the device was installed by a different Elixir version
  # than the host (e.g. after an Elixir upgrade), regex literals and other stdlib
  # internals will be incompatible. An online three-directory replacement cannot
  # be made atomic with the app BEAM swap, so fail closed and require the native
  # deployment path to replace the complete OTP runtime.
  @doc false
  @spec verify_elixir_runtime_version_android(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          ([String.t()] -> tuple())
        ) :: :ok | {:error, String.t()}
  def verify_elixir_runtime_version_android(serial, pkg, app_data, host_vsn, runner) do
    with :ok <- validate_adb_serial(serial),
         :ok <- validate_android_package(pkg),
         :ok <- validate_android_app_data(app_data, pkg),
         true <- is_binary(host_vsn) do
      elixir_app = "#{app_data}/otp/lib/elixir/ebin/elixir.app"

      case runner.(["-s", serial, "shell", "run-as #{pkg} cat #{elixir_app}"]) do
        {:ok, content}
        when is_binary(content) and byte_size(content) <= @max_android_query_output_bytes ->
          if String.valid?(content) and MobDev.AppFile.vsn_from_content(content) == host_vsn do
            :ok
          else
            {:error, "Elixir runtime version mismatch; rerun mix mob.deploy --native"}
          end

        {:error, _reason} ->
          {:error, "Could not verify Elixir runtime version; rerun mix mob.deploy --native"}

        _other ->
          {:error, "Could not verify Elixir runtime version: invalid adb result"}
      end
    else
      false -> {:error, "Invalid host Elixir version; refusing Android deploy"}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec setup_exqlite_android_runas(String.t(), String.t(), String.t(), keyword()) ::
          :ok | {:error, String.t()}
  def setup_exqlite_android_runas(serial, exqlite_ebin, vsn, opts \\ []) do
    package = Keyword.get(opts, :package, android_package())
    app_data = Keyword.get(opts, :app_data, android_app_data())
    runner = Keyword.get(opts, :runner, &run_adb/1)
    local_runner = Keyword.get(opts, :local_runner, &run_local_command/3)
    tmp_root = Keyword.get(opts, :tmp_root, System.tmp_dir!())

    with :ok <- validate_adb_serial(serial),
         :ok <- validate_android_package(package),
         :ok <- validate_android_app_data(app_data, package),
         :ok <-
           validate_android_operation_authority(
             Keyword.get(opts, :operation_authority),
             serial,
             package
           ),
         :ok <- validate_exqlite_version(vsn),
         {:ok, beam_sentinel} <- validate_exqlite_source(exqlite_ebin, vsn),
         {:ok, attempt_id} <- android_attempt_id(opts) do
      runner =
        fenced_android_operation_runner(
          Keyword.fetch!(opts, :operation_authority),
          serial,
          package,
          runner
        )

      stage_local = Path.join(tmp_root, "mob_exqlite_#{attempt_id}.tar")
      stage_device = "/data/local/tmp/mob_exqlite_#{attempt_id}.tar"
      tmp = Path.join(tmp_root, "mob_exqlite_stage_#{attempt_id}")
      lib_parent = "#{app_data}/otp/lib"
      live_dir = "#{lib_parent}/exqlite-#{vsn}"
      app_stage = "#{lib_parent}/.mob_exqlite_stage_#{attempt_id}"
      app_backup = "#{lib_parent}/.mob_exqlite_backup_#{attempt_id}"
      activation_lock = "#{lib_parent}/.mob_exqlite_activation_lock"

      local_result =
        try do
          File.rm_rf!(tmp)

          with :ok <- prepare_exqlite_local_stage(tmp),
               :ok <-
                 checked_local_command(local_runner, "stage exqlite ebin", "cp", [
                   "-r",
                   "#{exqlite_ebin}/.",
                   Path.join(tmp, "ebin")
                 ]),
               :ok <-
                 checked_local_command(
                   local_runner,
                   "create exqlite archive",
                   "tar",
                   ["cf", stage_local, "-C", tmp, "."],
                   env: [{"COPYFILE_DISABLE", "1"}]
                 ) do
            :ok
          end
        after
          File.rm_rf(tmp)
        end

      try do
        case local_result do
          :ok ->
            with {:ok, nif_target} <- resolve_exqlite_nif_target(serial, package, runner, opts) do
              push_staged_exqlite(
                runner,
                serial,
                package,
                stage_local,
                stage_device,
                live_dir,
                app_stage,
                app_backup,
                activation_lock,
                nif_target,
                beam_sentinel
              )
            end

          {:error, _reason} = error ->
            error
        end
      after
        File.rm(stage_local)
      end
    end
  end

  defp prepare_exqlite_local_stage(tmp) do
    with :ok <- File.mkdir_p(Path.join(tmp, "ebin")),
         :ok <- File.mkdir_p(Path.join(tmp, "priv")) do
      :ok
    else
      {:error, _reason} -> {:error, "prepare local exqlite stage failed"}
    end
  end

  defp validate_exqlite_source(exqlite_ebin, expected_vsn) when is_binary(exqlite_ebin) do
    beam_sentinels =
      exqlite_ebin
      |> Path.join("*.beam")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(&Path.basename/1)
      |> Enum.sort()

    app_file = Path.join(exqlite_ebin, "exqlite.app")

    with true <- File.dir?(exqlite_ebin),
         {:ok, app_content} <- File.read(app_file),
         true <- byte_size(app_content) <= @max_android_query_output_bytes,
         true <- String.valid?(app_content),
         ^expected_vsn <- MobDev.AppFile.vsn_from_content(app_content),
         [beam_sentinel | _] <- beam_sentinels,
         {:ok, safe_sentinel} <- validate_beam_sentinel(beam_sentinel) do
      {:ok, safe_sentinel}
    else
      _ -> {:error, "Configured exqlite ebin is incomplete; refusing Android deploy"}
    end
  end

  defp validate_exqlite_source(_exqlite_ebin, _expected_vsn),
    do: {:error, "Configured exqlite ebin is invalid; refusing Android deploy"}

  defp validate_exqlite_version(vsn) when is_binary(vsn) do
    if byte_size(vsn) in 1..128 and String.valid?(vsn) and
         Regex.match?(Regex.compile!("\\A[A-Za-z0-9._-]+\\z"), vsn),
       do: :ok,
       else: {:error, "Invalid exqlite version; refusing Android deploy"}
  end

  defp validate_exqlite_version(_vsn),
    do: {:error, "Invalid exqlite version; refusing Android deploy"}

  defp resolve_exqlite_nif_target(serial, package, runner, opts) do
    case Keyword.fetch(opts, :nif_target) do
      {:ok, target} ->
        validate_nif_target(target)

      :error ->
        with {:ok, path_output} <-
               checked_android_query(runner, "locate Android package", [
                 "-s",
                 serial,
                 "shell",
                 "pm path #{package}"
               ]),
             {:ok, apk_dir} <- android_apk_dir(path_output),
             {:ok, nif_output} <-
               checked_android_query(runner, "locate exqlite NIF", [
                 "-s",
                 serial,
                 "shell",
                 "ls #{apk_dir}/lib/*/libsqlite3_nif.so 2>/dev/null"
               ]),
             {:ok, target} <- exact_exqlite_nif_target(nif_output),
             {:ok, safe_target} <- validate_nif_target(target) do
          {:ok, safe_target}
        else
          {:error, _reason} = error -> error
        end
    end
  end

  defp android_apk_dir(path_output) when is_binary(path_output) do
    if byte_size(path_output) <= @max_android_query_output_bytes and String.valid?(path_output) do
      directories =
        path_output
        |> String.split("\n", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reduce_while([], fn
          "package:" <> path, directories ->
            if safe_android_device_path?(path) do
              {:cont, [Path.dirname(path) | directories]}
            else
              {:halt, :invalid}
            end

          _unexpected_line, _directories ->
            {:halt, :invalid}
        end)

      case directories do
        directories when is_list(directories) ->
          case Enum.uniq(directories) do
            [directory] ->
              {:ok, directory}

            _none_or_ambiguous ->
              {:error, "Ambiguous Android package path; refusing exqlite setup"}
          end

        :invalid ->
          {:error, "Invalid Android package path; refusing exqlite setup"}
      end
    else
      {:error, "Invalid Android package path; refusing exqlite setup"}
    end
  end

  defp validate_nif_target(target) when is_binary(target) do
    if safe_android_device_path?(target) and String.ends_with?(target, "/libsqlite3_nif.so") do
      {:ok, target}
    else
      {:error, "Invalid exqlite NIF path; refusing Android deploy"}
    end
  end

  defp validate_nif_target(_target),
    do: {:error, "Invalid exqlite NIF path; refusing Android deploy"}

  defp exact_exqlite_nif_target(output) when is_binary(output) do
    targets = normalized_exqlite_nif_targets(String.split(output, "\n", trim: true))

    case targets do
      [target] -> {:ok, target}
      [] -> {:error, "Could not locate exqlite NIF; refusing Android deploy"}
      _multiple -> {:error, "Ambiguous exqlite NIF targets; refusing Android deploy"}
    end
  end

  defp normalized_exqlite_nif_targets(lines) when is_list(lines) do
    lines
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&String.ends_with?(&1, "/libsqlite3_nif.so"))
    |> Enum.uniq()
  end

  defp normalized_exqlite_nif_targets(_lines), do: []

  defp safe_android_device_path?(path) do
    is_binary(path) and byte_size(path) <= 1_024 and String.valid?(path) and
      Regex.match?(Regex.compile!("\\A/[A-Za-z0-9._/+=~:-]+\\z"), path) and
      not Enum.member?(Path.split(path), "..")
  end

  defp push_staged_exqlite(
         runner,
         serial,
         package,
         stage_local,
         stage_device,
         live_dir,
         app_stage,
         app_backup,
         activation_lock,
         nif_target,
         beam_sentinel
       ) do
    push_result =
      checked_android_command(runner, "push exqlite archive", [
        "-s",
        serial,
        "push",
        stage_local,
        stage_device
      ])

    case push_result do
      :ok ->
        deploy_result =
          with :ok <-
                 checked_android_command(runner, "prepare exqlite staging directory", [
                   "-s",
                   serial,
                   "shell",
                   "run-as #{package} sh -c 'test ! -e #{app_backup} && rm -rf #{app_stage} && mkdir -p #{app_stage}'"
                 ]),
               :ok <-
                 checked_android_command(runner, "extract exqlite archive", [
                   "-s",
                   serial,
                   "shell",
                   "run-as #{package} tar xof #{stage_device} -C #{app_stage}/"
                 ]),
               :ok <-
                 checked_android_command(runner, "link staged exqlite NIF", [
                   "-s",
                   serial,
                   "shell",
                   "run-as #{package} ln -sf #{nif_target} #{app_stage}/priv/sqlite3_nif.so"
                 ]),
               :ok <-
                 verify_staged_exqlite(runner, serial, package, app_stage, beam_sentinel),
               :ok <-
                 checked_android_command(runner, "activate exqlite runtime", [
                   "-s",
                   serial,
                   "shell",
                   exqlite_activation_command(
                     package,
                     live_dir,
                     app_stage,
                     app_backup,
                     activation_lock,
                     beam_sentinel
                   )
                 ]),
               :ok <-
                 verify_active_exqlite(
                   runner,
                   serial,
                   package,
                   live_dir,
                   beam_sentinel
                 ),
               :ok <-
                 checked_android_command(runner, "release exqlite activation lock", [
                   "-s",
                   serial,
                   "shell",
                   android_activation_lock_release_command(package, activation_lock)
                 ]),
               :ok <-
                 checked_android_command(runner, "clean exqlite activation backup", [
                   "-s",
                   serial,
                   "shell",
                   android_activation_backup_cleanup_command(package, app_backup)
                 ]) do
            :ok
          end

        case deploy_result do
          :ok ->
            merge_deploy_and_cleanup_results(
              :ok,
              cleanup_android_exqlite_stage(
                runner,
                serial,
                package,
                stage_device,
                app_stage
              )
            )

          {:error, _reason} = error ->
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp verify_staged_exqlite(runner, serial, package, app_stage, beam_sentinel) do
    checked_android_command(runner, "verify staged exqlite runtime", [
      "-s",
      serial,
      "shell",
      "run-as #{package} sh -c 'test -r #{app_stage}/ebin/exqlite.app && test -r #{app_stage}/ebin/#{beam_sentinel} && test -L #{app_stage}/priv/sqlite3_nif.so && test -r #{app_stage}/priv/sqlite3_nif.so'"
    ])
  end

  defp verify_active_exqlite(runner, serial, package, live_dir, beam_sentinel) do
    checked_android_command(runner, "verify active exqlite runtime", [
      "-s",
      serial,
      "shell",
      "run-as #{package} sh -c 'test -r #{live_dir}/ebin/exqlite.app && test -r #{live_dir}/ebin/#{beam_sentinel} && test -L #{live_dir}/priv/sqlite3_nif.so && test -r #{live_dir}/priv/sqlite3_nif.so'"
    ])
  end

  defp exqlite_activation_command(
         package,
         live_dir,
         app_stage,
         app_backup,
         activation_lock,
         beam_sentinel
       ) do
    checks =
      "test -r #{live_dir}/ebin/exqlite.app && " <>
        "test -r #{live_dir}/ebin/#{beam_sentinel} && " <>
        "test -L #{live_dir}/priv/sqlite3_nif.so && test -r #{live_dir}/priv/sqlite3_nif.so"

    "run-as #{package} sh -c 'set -e; mkdir #{activation_lock}; had_live=0; " <>
      "if [ -e #{live_dir} ]; then mv #{live_dir} #{app_backup}; had_live=1; fi; " <>
      "if mv #{app_stage} #{live_dir} && #{checks}; then :; " <>
      "else rm -rf #{live_dir}; if [ \"$had_live\" -eq 1 ]; then " <>
      "mv #{app_backup} #{live_dir}; fi; exit 1; fi'"
  end

  defp cleanup_android_exqlite_stage(
         runner,
         serial,
         package,
         stage_device,
         app_stage
       ) do
    cleanup_results = [
      checked_android_command(runner, "clean app-private exqlite staging directory", [
        "-s",
        serial,
        "shell",
        "run-as #{package} rm -rf #{app_stage}"
      ]),
      cleanup_remote_exqlite_archive(runner, serial, stage_device)
    ]

    Enum.find(cleanup_results, :ok, &match?({:error, _reason}, &1))
  end

  defp cleanup_remote_exqlite_archive(runner, serial, stage_device) do
    checked_android_command(runner, "clean remote exqlite archive", [
      "-s",
      serial,
      "shell",
      "rm -f #{stage_device}"
    ])
  end

  defp checked_android_query(runner, operation, args) do
    case runner.(args) do
      {:ok, output}
      when is_binary(output) and byte_size(output) <= @max_android_query_output_bytes ->
        if String.valid?(output),
          do: {:ok, output},
          else: {:error, "#{operation} failed: invalid adb output"}

      {:ok, _output} ->
        {:error, "#{operation} failed: invalid adb output"}

      {:error, _reason} ->
        {:error, "#{operation} failed"}

      _other ->
        {:error, "#{operation} failed: invalid adb result"}
    end
  end

  # The native lib lands under `lib/<abi>/` — `arm64-v8a` → "arm64",
  # `armeabi-v7a` → "arm". Android extracts only the device's active ABI, so a
  # glob matches exactly one file. Probe for it rather than assuming 64-bit, so
  # 32-bit devices (older / low-end phones) get a real target instead of a
  # dangling `lib/arm64` symlink (which left exqlite `:nif_not_loaded` and
  # crashed boot). Returns the absolute path or nil.
  @doc false
  @spec __sqlite_nif_target__([String.t()]) :: String.t() | nil
  def __sqlite_nif_target__(ls_lines) do
    case normalized_exqlite_nif_targets(ls_lines) do
      [target] -> target
      _none_or_ambiguous -> nil
    end
  end

  defp exqlite_version, do: MobDev.AppFile.dep_version(:exqlite)

  @doc false
  @spec push_beams_android_runas(String.t(), [String.t()], keyword()) ::
          :ok | {:error, String.t()}
  def push_beams_android_runas(serial, beam_dirs, opts \\ []) do
    package = Keyword.get(opts, :package, android_package())
    beams_dir = Keyword.get(opts, :beams_dir, android_beams_dir())
    runner = Keyword.get(opts, :runner, &run_adb/1)
    local_runner = Keyword.get(opts, :local_runner, &run_local_command/3)
    file_writer = Keyword.get(opts, :file_writer, &File.write/2)
    tmp_root = Keyword.get(opts, :tmp_root, System.tmp_dir!())
    beam_flags = Keyword.get(opts, :beam_flags)
    priv_dir = Keyword.get(opts, :priv_dir)

    with :ok <- validate_adb_serial(serial),
         :ok <- validate_android_package(package),
         :ok <- validate_android_beams_dir(beams_dir, package),
         :ok <-
           validate_android_operation_authority(
             Keyword.get(opts, :operation_authority),
             serial,
             package
           ),
         {:ok, attempt_id} <- android_attempt_id(opts) do
      runner =
        fenced_android_operation_runner(
          Keyword.fetch!(opts, :operation_authority),
          serial,
          package,
          runner
        )

      stage_local = Path.join(tmp_root, "mob_beams_#{attempt_id}.tar")
      stage_device = "/data/local/tmp/mob_beams_#{attempt_id}.tar"
      tmp = Path.join(tmp_root, "mob_beam_stage_#{attempt_id}")
      app_stage = "#{Path.dirname(beams_dir)}/.mob_beams_stage_#{attempt_id}"
      app_backup = "#{Path.dirname(beams_dir)}/.mob_beams_backup_#{attempt_id}"
      activation_lock = "#{Path.dirname(beams_dir)}/.mob_beams_activation_lock"

      local_result =
        try do
          File.rm_rf!(tmp)
          File.mkdir_p!(tmp)

          with {:ok, sentinel} <- beam_sentinel(beam_dirs),
               :ok <- stage_android_beam_dirs(beam_dirs, tmp, local_runner),
               {:ok, flag_checks} <- stage_android_beam_flags(tmp, beam_flags, file_writer),
               {:ok, priv_checks} <- stage_android_priv(tmp, priv_dir, local_runner),
               :ok <-
                 checked_local_command(
                   local_runner,
                   "create BEAM archive",
                   "tar",
                   ["cf", stage_local, "-C", tmp, "."],
                   env: [{"COPYFILE_DISABLE", "1"}]
                 ) do
            {:ok, [{:file, sentinel} | flag_checks ++ priv_checks]}
          end
        after
          File.rm_rf(tmp)
        end

      try do
        case local_result do
          {:ok, verification_checks} ->
            push_staged_beams(
              runner,
              serial,
              package,
              beams_dir,
              stage_local,
              stage_device,
              app_stage,
              app_backup,
              activation_lock,
              verification_checks
            )

          {:error, _reason} = error ->
            error
        end
      after
        File.rm(stage_local)
      end
    end
  end

  defp push_staged_beams(
         runner,
         serial,
         package,
         beams_dir,
         stage_local,
         stage_device,
         app_stage,
         app_backup,
         activation_lock,
         verification_checks
       ) do
    push_result =
      checked_android_command(runner, "push BEAM archive", [
        "-s",
        serial,
        "push",
        stage_local,
        stage_device
      ])

    case push_result do
      :ok ->
        deploy_result =
          with :ok <-
                 checked_android_command(runner, "prepare BEAM directory", [
                   "-s",
                   serial,
                   "shell",
                   "run-as #{package} sh -c 'test ! -e #{app_backup} && rm -rf #{app_stage} && mkdir -p #{app_stage}'"
                 ]),
               :ok <-
                 checked_android_command(runner, "extract BEAM archive", [
                   "-s",
                   serial,
                   "shell",
                   "run-as #{package} tar xof #{stage_device} -C #{app_stage}/"
                 ]),
               :ok <-
                 verify_android_payload(
                   serial,
                   package,
                   app_stage,
                   verification_checks,
                   runner
                 ),
               :ok <-
                 checked_android_command(runner, "activate deployed BEAMs", [
                   "-s",
                   serial,
                   "shell",
                   beam_activation_command(
                     package,
                     beams_dir,
                     app_stage,
                     app_backup,
                     activation_lock,
                     verification_checks
                   )
                 ]),
               :ok <-
                 verify_android_payload(
                   serial,
                   package,
                   beams_dir,
                   verification_checks,
                   runner
                 ),
               :ok <-
                 checked_android_command(runner, "release BEAM activation lock", [
                   "-s",
                   serial,
                   "shell",
                   android_activation_lock_release_command(package, activation_lock)
                 ]),
               :ok <-
                 checked_android_command(runner, "clean BEAM activation backup", [
                   "-s",
                   serial,
                   "shell",
                   android_activation_backup_cleanup_command(package, app_backup)
                 ]) do
            :ok
          end

        case deploy_result do
          :ok ->
            merge_deploy_and_cleanup_results(
              :ok,
              cleanup_android_beam_stage(runner, serial, package, stage_device, app_stage)
            )

          {:error, _reason} = error ->
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  @doc false
  @spec restart_android(String.t(), keyword(), ([String.t()] -> tuple())) ::
          :ok | {:error, String.t()}
  def restart_android(serial, opts, runner \\ &run_adb/1) do
    with :ok <- validate_adb_serial(serial) do
      dist_port = Keyword.get(opts, :dist_port, 9100)
      node_suffix = Keyword.get(opts, :node_suffix) || Android.device_node_suffix(serial)
      package = Keyword.get(opts, :package, android_package())
      activity = Keyword.get(opts, :activity, @android_activity)
      sleeper = Keyword.get(opts, :sleeper, &:timer.sleep/1)

      with :ok <- validate_android_package(package),
           :ok <- validate_android_activity(activity),
           :ok <- validate_android_node_suffix(node_suffix),
           :ok <- validate_android_dist_port(dist_port),
           :ok <-
             validate_android_operation_authority(
               Keyword.get(opts, :operation_authority),
               serial,
               package
             ) do
        runner =
          fenced_android_operation_runner(
            Keyword.fetch!(opts, :operation_authority),
            serial,
            package,
            runner
          )

        restart_stopped_android(
          serial,
          package,
          activity,
          dist_port,
          node_suffix,
          sleeper,
          runner
        )
      end
    end
  end

  defp restart_stopped_android(
         serial,
         package,
         activity,
         dist_port,
         node_suffix,
         sleeper,
         runner
       ) do
    with :ok <-
           checked_android_command(runner, "force-stop Android app", [
             "-s",
             serial,
             "shell",
             "am",
             "force-stop",
             package
           ]) do
      sleeper.(300)

      checked_android_launch(runner, [
        "-s",
        serial,
        "shell",
        "am",
        "start",
        "-W",
        "-n",
        "#{package}/#{activity}",
        "--ei",
        "mob_dist_port",
        to_string(dist_port),
        "--es",
        "mob_node_suffix",
        node_suffix
      ])
    end
  end

  defp beam_sentinel(beam_dirs) do
    sentinels =
      beam_dirs
      |> Enum.flat_map(&Path.wildcard(Path.join(&1, "*.beam")))
      |> Enum.filter(&File.regular?/1)
      |> Enum.sort()

    case sentinels do
      [sentinel | _] -> validate_beam_sentinel(Path.basename(sentinel))
      [] -> {:error, "No local BEAM sentinel found; refusing Android deploy"}
    end
  end

  defp validate_beam_sentinel(sentinel)
       when is_binary(sentinel) and byte_size(sentinel) <= 255 do
    if String.valid?(sentinel) and
         Regex.match?(Regex.compile!("\\A[A-Za-z0-9_.-]+\\.beam\\z"), sentinel) do
      {:ok, sentinel}
    else
      {:error, "Unsafe local BEAM sentinel name; refusing Android deploy"}
    end
  end

  defp validate_beam_sentinel(_sentinel),
    do: {:error, "Unsafe local BEAM sentinel name; refusing Android deploy"}

  defp stage_android_beam_dirs(beam_dirs, tmp, local_runner) do
    Enum.reduce_while(beam_dirs, :ok, fn dir, :ok ->
      case checked_local_command(
             local_runner,
             "stage BEAM files",
             "cp",
             ["-r", "#{dir}/.", tmp]
           ) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp stage_android_beam_flags(_tmp, nil, _file_writer), do: {:ok, []}

  defp stage_android_beam_flags(tmp, flags, file_writer) when is_binary(flags) do
    if byte_size(flags) <= 4_096 and String.valid?(flags) do
      case file_writer.(Path.join(tmp, "mob_beam_flags"), flags) do
        :ok -> {:ok, [{:file, "mob_beam_flags"}]}
        {:error, _reason} -> {:error, "stage Android BEAM flags failed"}
      end
    else
      {:error, "stage Android BEAM flags failed: invalid flags"}
    end
  end

  defp stage_android_beam_flags(_tmp, _flags, _file_writer),
    do: {:error, "stage Android BEAM flags failed: invalid flags"}

  defp stage_android_priv(_tmp, nil, _local_runner), do: {:ok, []}

  defp stage_android_priv(tmp, priv_dir, local_runner) when is_binary(priv_dir) do
    with true <- File.dir?(priv_dir),
         {:ok, verification_check} <- android_priv_verification_check(priv_dir),
         :ok <- File.mkdir_p(Path.join(tmp, "priv")),
         :ok <-
           checked_local_command(local_runner, "stage Android priv files", "cp", [
             "-r",
             "#{priv_dir}/.",
             Path.join(tmp, "priv")
           ]) do
      {:ok, [verification_check]}
    else
      false -> {:error, "stage Android priv files failed: directory missing"}
      {:error, reason} = error when is_binary(reason) -> error
      {:error, _reason} -> {:error, "stage Android priv files failed"}
    end
  end

  defp stage_android_priv(_tmp, _priv_dir, _local_runner),
    do: {:error, "stage Android priv files failed: invalid directory"}

  defp android_priv_verification_check(priv_dir) do
    safe_file =
      priv_dir
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(&Path.relative_to(&1, priv_dir))
      |> Enum.sort()
      |> Enum.find(&safe_android_relative_path?/1)

    case {safe_file, File.ls(priv_dir)} do
      {safe_file, _listing} when is_binary(safe_file) ->
        {:ok, {:file, Path.join("priv", safe_file)}}

      {nil, {:ok, []}} ->
        {:ok, {:dir, "priv"}}

      {nil, {:ok, _entries}} ->
        {:error, "No safe Android priv sentinel found; refusing deploy"}

      {nil, {:error, _reason}} ->
        {:error, "Could not inspect Android priv directory; refusing deploy"}
    end
  end

  defp safe_android_relative_path?(path) when is_binary(path) do
    byte_size(path) <= 1_024 and String.valid?(path) and not String.starts_with?(path, "/") and
      not Enum.member?(Path.split(path), "..") and
      Regex.match?(Regex.compile!("\\A[A-Za-z0-9_./-]+\\z"), path)
  end

  defp verify_android_payload(serial, package, beams_dir, checks, runner) do
    shell_checks = android_payload_checks(beams_dir, checks)

    checked_android_command(runner, "verify deployed BEAM", [
      "-s",
      serial,
      "shell",
      "run-as #{package} sh -c '#{shell_checks}'"
    ])
  end

  defp beam_activation_command(
         package,
         beams_dir,
         app_stage,
         app_backup,
         activation_lock,
         checks
       ) do
    shell_checks = android_payload_checks(beams_dir, checks)

    "run-as #{package} sh -c 'set -e; mkdir #{activation_lock}; had_live=0; " <>
      "if [ -e #{beams_dir} ]; then mv #{beams_dir} #{app_backup}; had_live=1; fi; " <>
      "if mv #{app_stage} #{beams_dir} && #{shell_checks}; then " <>
      ":; else rm -rf #{beams_dir}; " <>
      "if [ \"$had_live\" -eq 1 ]; then mv #{app_backup} #{beams_dir}; fi; exit 1; fi'"
  end

  defp android_activation_lock_release_command(package, activation_lock),
    do: "run-as #{package} rmdir #{activation_lock}"

  defp android_activation_backup_cleanup_command(package, app_backup),
    do: "run-as #{package} rm -rf #{app_backup}"

  defp android_payload_checks(base_dir, checks) do
    Enum.map_join(checks, " && ", fn
      {:file, relative_path} -> "test -r #{Path.join(base_dir, relative_path)}"
      {:dir, relative_path} -> "test -d #{Path.join(base_dir, relative_path)}"
    end)
  end

  defp cleanup_android_beam_stage(
         runner,
         serial,
         package,
         stage_device,
         app_stage
       ) do
    cleanup_results = [
      checked_android_command(runner, "clean app-private BEAM staging directory", [
        "-s",
        serial,
        "shell",
        "run-as #{package} rm -rf #{app_stage}"
      ]),
      cleanup_remote_beam_archive(runner, serial, stage_device)
    ]

    Enum.find(cleanup_results, :ok, &match?({:error, _reason}, &1))
  end

  defp cleanup_remote_beam_archive(runner, serial, stage_device) do
    checked_android_command(runner, "clean remote BEAM archive", [
      "-s",
      serial,
      "shell",
      "rm -f #{stage_device}"
    ])
  end

  defp merge_deploy_and_cleanup_results(:ok, :ok), do: :ok

  defp merge_deploy_and_cleanup_results(:ok, {:error, _reason} = cleanup_error),
    do: cleanup_error

  defp checked_android_command(runner, operation, args) do
    case runner.(args) do
      {:ok, output}
      when is_binary(output) and byte_size(output) <= @max_android_query_output_bytes ->
        if String.valid?(output),
          do: :ok,
          else: {:error, "#{operation} failed: invalid adb output"}

      {:ok, _output} ->
        {:error, "#{operation} failed: invalid adb output"}

      {:error, reason} ->
        {:error, android_command_error(operation, reason)}

      _other ->
        {:error, "#{operation} failed: invalid adb result"}
    end
  end

  defp checked_android_launch(runner, args) do
    case runner.(args) do
      {:ok, output}
      when is_binary(output) and byte_size(output) <= @max_android_launch_output_bytes ->
        if String.valid?(output) do
          lines = output |> String.split("\n") |> Enum.map(&String.trim/1)
          status_lines = Enum.filter(lines, &String.starts_with?(&1, "Status:"))

          if status_lines == ["Status: ok"] and
               not Enum.any?(lines, &String.starts_with?(&1, "Error")) do
            :ok
          else
            {:error, "launch Android app failed: adb returned no success status"}
          end
        else
          {:error, "launch Android app failed: invalid adb output"}
        end

      {:ok, _output} ->
        {:error, "launch Android app failed: invalid adb output"}

      {:error, _reason} ->
        {:error, "launch Android app failed"}

      _other ->
        {:error, "launch Android app failed: invalid adb result"}
    end
  end

  defp checked_local_command(local_runner, operation, executable, args, opts \\ []) do
    case local_runner.(executable, args, Keyword.put_new(opts, :stderr_to_stdout, true)) do
      {output, 0}
      when is_binary(output) and byte_size(output) <= @max_android_query_output_bytes ->
        if String.valid?(output),
          do: :ok,
          else: {:error, "#{operation} failed: invalid command output"}

      {_output, 0} ->
        {:error, "#{operation} failed: invalid command output"}

      {output, _status} ->
        {:error, android_command_error(operation, output)}

      _other ->
        {:error, "#{operation} failed: invalid command result"}
    end
  end

  defp run_local_command(executable, args, opts) do
    System.cmd(executable, args, Keyword.put_new(opts, :stderr_to_stdout, true))
  end

  defp android_command_error(operation, _output), do: "#{operation} failed"

  defp android_attempt_id(opts) do
    attempt_id =
      case Keyword.get(opts, :attempt_id) do
        nil -> :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
        attempt_id -> attempt_id
      end

    if is_binary(attempt_id) and String.valid?(attempt_id) and
         Regex.match?(Regex.compile!(@android_attempt_id_pattern), attempt_id) do
      {:ok, attempt_id}
    else
      {:error, "Invalid Android deploy attempt id; refusing BEAM delivery"}
    end
  end

  defp validate_adb_serial(serial) when is_binary(serial) do
    valid? =
      byte_size(serial) in 1..@max_adb_serial_bytes and not String.starts_with?(serial, "-") and
        serial
        |> :binary.bin_to_list()
        |> Enum.all?(fn byte ->
          byte in ?0..?9 or byte in ?A..?Z or byte in ?a..?z or byte in ~c".:-_"
        end)

    if valid? do
      :ok
    else
      {:error, "Invalid adb serial; refusing BEAM delivery"}
    end
  end

  defp validate_adb_serial(_serial),
    do: {:error, "Invalid adb serial; refusing BEAM delivery"}

  defp validate_android_package(package) when is_binary(package) do
    if byte_size(package) <= 255 and String.valid?(package) and
         Regex.match?(
           Regex.compile!("\\A[A-Za-z][A-Za-z0-9_]*(?:\\.[A-Za-z0-9_]+)+\\z"),
           package
         ) do
      :ok
    else
      {:error, "Invalid Android package; refusing deploy"}
    end
  end

  defp validate_android_package(_package),
    do: {:error, "Invalid Android package; refusing deploy"}

  defp validate_android_app_data(app_data, package) do
    if app_data == "/data/data/#{package}/files" do
      :ok
    else
      {:error, "Invalid Android app-data path; refusing deploy"}
    end
  end

  defp validate_android_beams_dir(beams_dir, package) when is_binary(beams_dir) do
    app_data = "/data/data/#{package}/files"

    if safe_android_device_path?(beams_dir) and
         String.starts_with?(beams_dir, "#{app_data}/otp/") do
      :ok
    else
      {:error, "Invalid Android BEAM path; refusing deploy"}
    end
  end

  defp validate_android_beams_dir(_beams_dir, _package),
    do: {:error, "Invalid Android BEAM path; refusing deploy"}

  defp validate_android_activity(activity) when is_binary(activity) do
    if byte_size(activity) in 1..255 and String.valid?(activity) and
         Regex.match?(Regex.compile!("\\A\\.?[A-Za-z][A-Za-z0-9_.]*\\z"), activity),
       do: :ok,
       else: {:error, "Invalid Android activity; refusing launch"}
  end

  defp validate_android_activity(_activity),
    do: {:error, "Invalid Android activity; refusing launch"}

  defp validate_android_node_suffix(node_suffix) when is_binary(node_suffix) do
    if byte_size(node_suffix) in 1..128 and String.valid?(node_suffix) and
         Regex.match?(Regex.compile!("\\A[A-Za-z0-9_]+\\z"), node_suffix),
       do: :ok,
       else: {:error, "Invalid Android node suffix; refusing launch"}
  end

  defp validate_android_node_suffix(_node_suffix),
    do: {:error, "Invalid Android node suffix; refusing launch"}

  defp validate_android_dist_port(port) when is_integer(port) and port in 1..65_535, do: :ok

  defp validate_android_dist_port(_port),
    do: {:error, "Invalid Android distribution port; refusing launch"}

  defp bounded_device_label(serial) when is_binary(serial),
    do: String.slice(serial, 0, 128)

  # ── iOS ─────────────────────────────────────────────────────────────────────

  defp deploy_ios(%Device{type: :physical} = device, beam_dirs, opts) do
    deploy_ios_physical(device, beam_dirs, opts)
  end

  defp deploy_ios(device, beam_dirs, opts) do
    deploy_ios_simulator(device, beam_dirs, opts)
  end

  defp deploy_ios_simulator(%Device{serial: udid} = device, beam_dirs, opts) do
    restart = Keyword.get(opts, :restart, true)
    dist_port = Keyword.get(opts, :dist_port, 9100)
    beam_flags = Keyword.get(opts, :beam_flags, nil)

    try do
      File.mkdir_p!(ios_beams_dir())

      # Use rsync rather than cp -r for two reasons that hit Nix users hard:
      #
      # 1. macOS BSD `cp` preserves source mode in practice (despite what the
      #    man page implies). Sources in /nix/store are mode 444, so cp leaves
      #    444 files in our managed runtime dir; the next deploy then trips on
      #    `cp: cannot create regular file ... Permission denied` when trying
      #    to overwrite them.
      #
      # 2. cp -r unconditionally overwrites every file, even when nothing has
      #    changed. rsync's mtime+size check skips identical files, so a
      #    no-op deploy after a previous successful one is genuinely a no-op.
      #
      # `--no-perms` keeps existing destination permissions untouched and uses
      # the user's umask for newly-created files (so we don't propagate Nix's
      # 444 mode). rsync's atomic-rename writer can also overwrite a 444
      # destination cleanly without needing a chmod first.
      Enum.each(beam_dirs, fn dir ->
        abs_dir = Path.expand(dir)

        case System.cmd(
               "rsync",
               ["-a", "--no-perms", "#{abs_dir}/", "#{ios_beams_dir()}/"],
               stderr_to_stdout: true
             ) do
          {_, 0} -> :ok
          {out, _} -> throw({:error, "rsync failed: #{out}"})
        end
      end)

      # Push priv/ alongside the BEAMs so migrations and other priv assets are
      # available at runtime. On iOS, beams_dir = $RUNTIME_DIR/APP_NAME and
      # MOB_DATA_DIR = the app's Documents directory — these are two different
      # paths, so we can't derive beams_dir from MOB_DATA_DIR. mob_beam.m sets
      # MOB_BEAMS_DIR=beams_dir explicitly so app code always knows where to look.
      local_priv = Path.join(File.cwd!(), "priv")

      if File.dir?(local_priv) do
        priv_dest = Path.join(ios_beams_dir(), "priv")
        File.mkdir_p!(priv_dest)

        case System.cmd(
               "rsync",
               ["-a", "--no-perms", "#{Path.expand(local_priv)}/", "#{priv_dest}/"],
               stderr_to_stdout: true
             ) do
          {_, 0} -> :ok
          {out, _} -> IO.puts("    (warning: iOS priv push failed: #{out})")
        end
      end

      if beam_flags do
        File.write!(Path.join(ios_beams_dir(), "mob_beam_flags"), beam_flags)
      end

      if restart do
        IOS.terminate_app(udid, ios_bundle_id())
        :timer.sleep(300)
        # node_suffix nil → IOS.launch_app omits SIMCTL_CHILD_MOB_NODE_SUFFIX
        # → mob_beam.m auto-derives from SIMULATOR_UDID. Pass explicit when
        # `mix mob.deploy --node-suffix ...` was used.
        node_suffix = Keyword.get(opts, :node_suffix)
        IOS.launch_app(udid, ios_bundle_id(), dist_port: dist_port, node_suffix: node_suffix)
      end

      {:ok, device}
    catch
      {:error, reason} -> {:error, reason}
    end
  end

  # Physical iOS deploy: push BEAMs into the app's Documents container via
  # `xcrun devicectl`. mob_beam.m (MOB_BUNDLE_OTP build) checks
  # Documents/otp/<app>/ at startup and prefers it over the read-only in-bundle
  # copy, enabling fast deploys without a full Xcode rebuild.
  #
  # The merged staging dir is named <app> so that devicectl's directory-copy
  # semantics land the files at Documents/otp/<app>/ on device.
  defp deploy_ios_physical(%Device{serial: udid} = device, beam_dirs, opts) do
    restart = Keyword.get(opts, :restart, true)
    beam_flags = Keyword.get(opts, :beam_flags, nil)
    bundle = ios_bundle_id()
    app = app_name()

    # When discovered via WiFi-only EPMD scan the serial is the IP address, which
    # xcrun devicectl does not accept as a --device argument. Resolve to a hardware
    # UDID before proceeding.
    udid = resolve_ios_udid_if_ip(udid)

    if Regex.match?(Regex.compile!("^\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}$"), udid) do
      throw(
        {:error,
         "device only reachable via WiFi (#{udid}) — use `mix mob.push` for BEAM-only updates, or connect via USB for a native deploy"}
      )
    end

    # Stage all BEAMs (and priv/) into a temp dir named <app>.
    staging_parent =
      Path.join(System.tmp_dir!(), "mob_ios_deploy_#{:erlang.unique_integer([:positive])}")

    staging_dir = Path.join(staging_parent, app)
    File.mkdir_p!(staging_dir)

    try do
      Enum.each(beam_dirs, fn dir ->
        case System.cmd("cp", ["-r", "#{Path.expand(dir)}/.", staging_dir],
               stderr_to_stdout: true
             ) do
          {_, 0} -> :ok
          {out, _} -> throw({:error, "cp failed: #{out}"})
        end
      end)

      local_priv = Path.join(File.cwd!(), "priv")

      if File.dir?(local_priv) do
        priv_dest = Path.join(staging_dir, "priv")
        File.mkdir_p!(priv_dest)

        case System.cmd("cp", ["-r", "#{Path.expand(local_priv)}/.", priv_dest],
               stderr_to_stdout: true
             ) do
          {_, 0} -> :ok
          {out, _} -> IO.puts("    (warning: priv copy failed: #{out})")
        end
      end

      if beam_flags do
        File.write!(Path.join(staging_dir, "mob_beam_flags"), beam_flags)
      end

      # devicectl copies the contents of --source into --destination.
      # To land BEAMs at Documents/otp/<app>/, the destination must include
      # the app subdirectory explicitly (staging_dir naming alone is not enough).
      case System.cmd(
             "xcrun",
             [
               "devicectl",
               "device",
               "copy",
               "to",
               "--device",
               udid,
               "--domain-type",
               "appDataContainer",
               "--domain-identifier",
               bundle,
               "--source",
               staging_dir,
               "--destination",
               "Documents/otp/#{app}"
             ],
             stderr_to_stdout: true
           ) do
        {_, 0} ->
          :ok

        {out, _} ->
          reason =
            if String.contains?(out, "ContainerLookupErrorDomain") do
              """
              App '#{bundle}' is not installed on this device.

              To fix this, you need to build and install the app on the device first.
              The easiest way is to open the ios/ directory in Xcode and run on device:

                  open ios/*.xcodeproj    (or ios/*.xcworkspace)

              Then select your device in Xcode and press Run (⌘R).

              Alternatively, if you have another app with a different bundle ID already
              installed on the device, update bundle_id in mob.exs to match it:

                  config :mob_dev, bundle_id: "com.yourcompany.yourapp"
              """
            else
              "devicectl copy failed: #{out}"
            end

          throw({:error, reason})
      end

      if restart, do: IOS.restart_app_physical(udid, bundle)

      {:ok, device}
    catch
      {:error, reason} -> {:error, reason}
    after
      File.rm_rf!(staging_parent)
    end
  end

  # ── iOS WiFi UDID resolution ──────────────────────────────────────────────────

  # When a physical device was discovered only via LAN EPMD scan (no USB), its
  # serial is the IP address. xcrun devicectl requires a hardware UDID or
  # CoreDevice UUID for --device. This function resolves an IP to a UDID.
  defp resolve_ios_udid_if_ip(udid) do
    if Regex.match?(Regex.compile!("^\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}$"), udid) do
      resolve_udid_from_ip(udid) || udid
    else
      udid
    end
  end

  defp resolve_udid_from_ip(ip) do
    # Strategy 1: idevice_id -n lists network-connected device UDIDs.
    # If exactly one is found, it must be the WiFi-only device we're targeting.
    # Strategy 2: xcrun devicectl list devices, subtract known USB devices.
    from_idevice_id_network(ip) ||
      from_devicectl_list(ip)
  end

  defp from_idevice_id_network(ip) do
    with true <- not is_nil(System.find_executable("idevice_id")),
         {out, 0} <- System.cmd("idevice_id", ["-n"], stderr_to_stdout: true),
         udids <-
           out |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")),
         true <- udids != [] do
      # With a single network device, return it immediately without querying its IP.
      # With multiple, use ideviceinfo to find which UDID has the target IP.
      case udids do
        [single] ->
          single

        many ->
          Enum.find_value(many, fn udid ->
            case System.cmd("ideviceinfo", ["--network", "-u", udid, "-k", "IPAddress"],
                   stderr_to_stdout: true
                 ) do
              {ip_out, 0} ->
                if String.trim(ip_out) == ip, do: udid, else: nil

              _ ->
                nil
            end
          end)
      end
    else
      _ -> nil
    end
  end

  defp from_devicectl_list(_ip) do
    usb_udids =
      if System.find_executable("idevice_id") do
        case System.cmd("idevice_id", ["-l"], stderr_to_stdout: true) do
          {out, 0} ->
            out
            |> String.split("\n")
            |> Enum.map(&String.trim/1)
            |> Enum.reject(&(&1 == ""))
            |> MapSet.new()

          _ ->
            MapSet.new()
        end
      else
        MapSet.new()
      end

    with {json, 0} <-
           System.cmd("xcrun", ["devicectl", "list", "devices", "--json-output", "-"],
             stderr_to_stdout: true
           ),
         {:ok, data} <- Jason.decode(json),
         devices <- get_in(data, ["result", "devices"]) || [],
         wifi_only <-
           Enum.reject(devices, fn d ->
             hw_udid = get_in(d, ["hardwareProperties", "udid"]) || ""
             MapSet.member?(usb_udids, hw_udid)
           end),
         [device] <- wifi_only,
         udid when not is_nil(udid) <- get_in(device, ["hardwareProperties", "udid"]) do
      udid
    else
      _ -> nil
    end
  end

  # ── Dist push ────────────────────────────────────────────────────────────────

  # Try to connect via Erlang dist to each discovered device. Returns a list of
  # connected node atoms. Devices that don't respond are left for the adb fallback.
  defp connect_dist(devices) do
    ensure_local_dist()

    Enum.flat_map(devices, fn device ->
      node = Device.node_name(device)
      Node.set_cookie(node, @cookie)
      if Node.connect(node), do: [node], else: []
    end)
  rescue
    _ -> []
  end

  defp ensure_local_dist do
    unless Node.alive?() do
      Node.start(:"mob_dev@127.0.0.1", :longnames)
      Node.set_cookie(@cookie)
    end
  end

  # Push all compiled BEAMs to a single dist-connected node, then trigger
  # a re-render of the currently displayed screen so the user sees the changes
  # immediately without a full restart.
  #
  # WHY THE RE-RENDER MESSAGE IS NECESSARY
  #
  # Erlang hot code loading (`code:load_binary`) replaces the module in the
  # code server but does NOT cause running processes to re-execute. A
  # Mob.Screen GenServer that is already mounted and displaying will continue
  # to sit in its receive loop waiting for the next message. Until something
  # sends it a message, `render/1` never runs again — so the user sees the
  # old UI even though the new code is live in memory.
  #
  # The fix: immediately after the push, RPC-send `:__mob_hot_reload__` to the
  # `:mob_screen` registered process on the device. Mob.Screen's handle_info
  # catch-all receives it, delegates to the user module's handle_info (which
  # ignores unknown messages), then calls do_render/2 using the now-current
  # version of the screen module. The screen repaints with the new code, with
  # no restart and no loss of GenServer state.
  #
  # This is why `mix mob.deploy` appeared to do nothing before this fix — the
  # code WAS pushed correctly, the screen just had no trigger to repaint.
  defp push_via_dist(node, device) do
    {_pushed, failed} = HotPush.push_all([node])

    if failed == [] do
      # Best-effort: ignored if no screen is currently registered (nav edge
      # cases, app in background, etc.).
      :rpc.call(node, :erlang, :send, [:mob_screen, :__mob_hot_reload__])
      {:ok, device}
    else
      mods = Enum.map_join(failed, ", ", fn {mod, _} -> inspect(mod) end)
      {:error, "dist push failed for: #{mods}"}
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp collect_beam_dirs do
    # Use the same runtime-dep filter as HotPush so we don't push dev-only
    # tooling (mob_dev, credo, etc.) to the device filesystem.
    app_dirs = HotPush.runtime_beam_dirs()

    # EEx is part of the Elixir stdlib but not in _build/dev/lib/. Ecto depends
    # on it, so include it in every push so it lands in the flat beams_dir
    # (which is already on the -pa code path on both Android and iOS).
    eex_ebin = Path.join(to_string(:code.lib_dir(:eex)), "ebin")
    stdlib_dirs = if File.dir?(eex_ebin), do: [eex_ebin], else: []

    # ssl is a required OTP app (thousand_island lists it as a dependency) but the
    # iOS and Android OTP builds omit it. ssl is pure Erlang (no NIFs), so host
    # BEAM files run identically on both targets. For HTTP-only Phoenix at loopback,
    # ssl starts but no TLS sockets are opened.
    ssl_ebin = Path.join(to_string(:code.lib_dir(:ssl)), "ebin")
    ssl_dirs = if File.dir?(ssl_ebin), do: [ssl_ebin], else: []

    # crypto is a required OTP app. Older device-side OTP builds (pre-2026-05)
    # were configured `--without-ssl` to skip OpenSSL, so the device runtime
    # had no real crypto and we shipped a deliberately-insecure shim
    # (md5-only hash, no x25519, no AEAD) just to let `ensure_all_started`
    # succeed for HTTP-only Phoenix at loopback.
    #
    # Newer tarballs ship a real crypto.so NIF + crypto.beam built against
    # OpenSSL 3.x. When the host has a cached OTP runtime that already
    # contains crypto.beam, we MUST NOT push the shim — its `crypto.beam`
    # would land first in the on-device code path and shadow the real one,
    # making `crypto:generate_key/2` undef even though the NIF is loaded.
    shim_dirs =
      if real_device_crypto_available?() do
        []
      else
        case generate_crypto_shim() do
          {:ok, dir} -> [dir]
          _ -> []
        end
      end

    app_dirs ++ stdlib_dirs ++ ssl_dirs ++ shim_dirs
  end

  # Detects whether any cached device-side OTP runtime under ~/.mob/cache/
  # already ships a real crypto.beam. If yes, the deployer must skip the
  # shim — pushing the shim's crypto.beam shadows the real one in the
  # on-device code path, making :crypto.generate_key/2 (and friends) undef
  # despite the NIF being loaded.
  @spec real_device_crypto_available?() :: boolean()
  defp real_device_crypto_available? do
    cache = Path.join([System.user_home!(), ".mob", "cache"])

    Path.wildcard(Path.join([cache, "otp-*", "lib", "crypto-*", "ebin", "crypto.beam"]))
    |> Enum.any?()
  end

  # Generates crypto.beam + crypto.app in a temp dir and returns {:ok, dir}.
  # Returns {:error, reason} if erlc is not available.
  #
  # Used only as a fallback when the device-side OTP runtime was built
  # `--without-ssl` (pre-2026-05 tarballs). Modern tarballs ship a real
  # crypto.so NIF; in that case `real_device_crypto_available?/0` returns
  # true and this shim is skipped.
  @doc false
  @spec generate_crypto_shim() :: {:ok, String.t()} | {:error, term()}
  def generate_crypto_shim do
    dir = Path.join(System.tmp_dir!(), "mob_crypto_shim")
    File.mkdir_p!(dir)

    src = Path.join(dir, "crypto.erl")

    File.write!(src, """
    -module(crypto).
    -export([strong_rand_bytes/1, hash/2, mac/4, mac/3, supports/1, pbkdf2_hmac/5, exor/2]).

    strong_rand_bytes(N) -> rand:bytes(N).

    hash(_Type, Data) -> erlang:md5(Data).

    %% HMAC-MD5 (ignores hash algorithm) — dev-only shim, no OpenSSL required.
    mac(hmac, _Alg, Key, Data) -> hmac_md5(Key, Data);
    mac(_Type, _SubType, _Key, _Data) -> <<>>.

    mac(hmac, Key, Data) -> hmac_md5(Key, Data);
    mac(_Type, _Key, _Data) -> <<>>.

    supports(_Type) -> [].

    %% PBKDF2-HMAC shim using HMAC-MD5 as PRF. Not cryptographically secure;
    %% suitable only for local dev on-device where 127.0.0.1 is the only listener.
    pbkdf2_hmac(_Hash, Password0, Salt0, Iterations, DerivedLen) ->
        Password = iolist_to_binary(Password0),
        Salt     = iolist_to_binary(Salt0),
        Blocks = (DerivedLen + 15) div 16,
        Derived = iolist_to_binary([pbkdf2_block(Password, Salt, Iterations, I)
                                    || I <- lists:seq(1, Blocks)]),
        binary:part(Derived, 0, DerivedLen).

    pbkdf2_block(Password, Salt, Iterations, BlockNum) ->
        U1 = hmac_md5(Password, <<Salt/binary, BlockNum:32/big>>),
        pbkdf2_iterate(Password, U1, Iterations - 1, U1).

    pbkdf2_iterate(_Password, _Prev, 0, Acc) -> Acc;
    pbkdf2_iterate(Password, Prev, N, Acc) ->
        U = hmac_md5(Password, Prev),
        pbkdf2_iterate(Password, U, N - 1, xor_bins(Acc, U)).

    hmac_md5(Key0, Data0) ->
        Key  = iolist_to_binary(Key0),
        Data = iolist_to_binary(Data0),
        BS = 64,
        K = case byte_size(Key) > BS of
            true  -> erlang:md5(Key);
            false -> Key
        end,
        Pad = binary:copy(<<0>>, BS - byte_size(K)),
        KPad = <<K/binary, Pad/binary>>,
        IKey = << <<(X bxor 16#36)>> || <<X>> <= KPad >>,
        OKey = << <<(X bxor 16#5c)>> || <<X>> <= KPad >>,
        erlang:md5(<<OKey/binary, (erlang:md5(<<IKey/binary, Data/binary>>))/binary>>).

    xor_bins(A, B) ->
        list_to_binary([X bxor Y || {X, Y} <- lists:zip(binary_to_list(A), binary_to_list(B))]).

    exor(A, B) ->
        xor_bins(iolist_to_binary(A), iolist_to_binary(B)).
    """)

    app =
      "{application,crypto,[{modules,[crypto]},{applications,[kernel,stdlib]}," <>
        "{description,\"Crypto shim for mobile (no OpenSSL; uses rand:bytes)\"}," <>
        "{registered,[]},{vsn,\"5.6\"}]}."

    File.write!(Path.join(dir, "crypto.app"), app)

    case System.cmd("erlc", ["-o", dir, src], stderr_to_stdout: true) do
      {_, 0} -> {:ok, dir}
      {out, _} -> {:error, "crypto shim compile failed: #{out}"}
    end
  end

  defp count_beams(beam_dirs) do
    Enum.reduce(beam_dirs, 0, fn dir, acc ->
      case File.ls(dir) do
        {:ok, files} -> acc + Enum.count(files, &String.ends_with?(&1, ".beam"))
        _ -> acc
      end
    end)
  end

  defp run_adb(args) do
    case System.cmd("adb", args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, _} -> {:error, output}
    end
  end

  defp color(:green), do: IO.ANSI.green()
  defp color(:yellow), do: IO.ANSI.yellow()
  defp color(:red), do: IO.ANSI.red()
  defp color(:cyan), do: IO.ANSI.cyan()
  defp color(:faint), do: IO.ANSI.faint()
  defp color(:reset), do: IO.ANSI.reset()
end
