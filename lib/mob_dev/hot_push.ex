defmodule MobDev.HotPush do
  @moduledoc """
  Connects to already-running device nodes and hot-pushes BEAM modules via RPC.

  Unlike `MobDev.Deployer`, this does NOT restart apps — modules are loaded
  into the running BEAM in place, just like `nl/1` in IEx.

  Requires apps to already be running (start with `mix mob.connect` or
  `mix mob.deploy` first).
  """

  alias MobDev.{AndroidDeployLock, Config, Tunnel}
  alias MobDev.Discovery.{Android, IOS}

  @cookie :mob_secret
  @max_beam_files 20_000
  @max_beam_file_bytes 16 * 1024 * 1024
  @max_beam_total_bytes 256 * 1024 * 1024
  @max_beam_path_bytes 4_096
  @max_android_targets 32

  @type prepared_beam :: %{
          required(:module) => module(),
          required(:path) => String.t(),
          required(:binary) => binary(),
          required(:sha256) => binary()
        }

  @doc """
  Sets up adb tunnels (idempotent) and connects to all running device nodes.
  Returns list of connected node atoms.
  """
  @spec connect(keyword()) :: [node()]
  def connect(opts \\ []) do
    cookie = Keyword.get(opts, :cookie, @cookie)

    nodes =
      (Android.list_devices() ++ IOS.list_simulators())
      |> Enum.flat_map(fn device ->
        case Tunnel.setup(device) do
          {:ok, d} -> [d]
          _ -> []
        end
      end)
      |> Enum.flat_map(fn device ->
        ensure_local_dist(cookie)
        Node.set_cookie(device.node, cookie)

        case Node.connect(device.node) do
          true -> [device.node]
          _ -> []
        end
      end)

    nodes
  end

  @doc """
  Pushes all compiled BEAM files from `_build/dev/lib/*/ebin/` to `nodes`.

  Only pushes BEAMs for runtime dependencies — deps marked `only: :dev` or
  `runtime: false` in `mix.exs` (and their transitive deps) are excluded.
  This prevents dev tooling (mob_dev, Bandit, Phoenix, etc.) from being pushed
  to the device when using `path:` deps during local framework development.

  Returns `{pushed_count, failed_list}`.
  """
  @spec push_all([node()]) :: {non_neg_integer(), list()}
  def push_all(nodes) do
    case prepare(runtime_beam_paths()) do
      {:ok, snapshot} -> push_with_ordinary_android_lease(nodes, snapshot)
      {:error, _reason} -> {0, [{:snapshot, :invalid}]}
    end
  end

  @doc """
  Takes a snapshot of current BEAM mtimes for runtime deps only.
  Pass the result to `push_changed/2` before and after compiling to get only
  the modules that actually changed.
  """
  @spec snapshot_beams() :: %{String.t() => non_neg_integer()}
  def snapshot_beams do
    runtime_beam_paths()
    |> Map.new(fn path ->
      mtime =
        case File.stat(path, time: :posix) do
          {:ok, %{mtime: t}} -> t
          _ -> 0
        end

      {path, mtime}
    end)
  end

  @doc """
  Pushes BEAM files that changed since `snapshot` (from `snapshot_beams/0`).
  Returns `{pushed_count, failed_list}` — pushed_count is 0 if nothing changed.
  """
  @spec push_changed([node()], %{String.t() => non_neg_integer()}) :: {non_neg_integer(), list()}
  def push_changed(nodes, snapshot) do
    beams =
      runtime_beam_paths()
      |> Enum.filter(fn path ->
        current_mtime =
          case File.stat(path, time: :posix) do
            {:ok, %{mtime: t}} -> t
            _ -> 0
          end

        current_mtime != Map.get(snapshot, path, 0)
      end)

    case prepare(beams) do
      {:ok, prepared} -> push_with_ordinary_android_lease(nodes, prepared)
      {:error, _reason} -> {0, [{:snapshot, :invalid}]}
    end
  end

  @doc false
  @spec prepare([String.t()]) :: {:ok, [prepared_beam()]} | {:error, String.t()}
  def prepare(paths) when is_list(paths) do
    ordered_paths = Enum.sort(paths)

    cond do
      length(ordered_paths) > @max_beam_files ->
        {:error, "BEAM snapshot exceeds file-count limit"}

      Enum.uniq(ordered_paths) != ordered_paths ->
        {:error, "BEAM snapshot contains duplicate paths"}

      true ->
        prepare_paths(ordered_paths)
    end
  end

  def prepare(_paths), do: {:error, "BEAM snapshot paths are invalid"}

  @doc """
  Loads an already prepared immutable snapshot.

  Raw prepared pushes are iOS-only. Android callers must use
  `push_prepared_fenced/3`; Android-looking nodes are rejected before any RPC.
  User-facing hot pushes go through `push_all/1` or `push_changed/2`, which
  acquire, commit, and release an ordinary Android lease around the RPC phase.
  """
  @spec push_prepared([node()], [prepared_beam()]) :: {non_neg_integer(), list()}
  def push_prepared(nodes, snapshot) do
    push_prepared(nodes, snapshot, fn node, module, filename, binary ->
      :rpc.call(node, :code, :load_binary, [module, filename, binary])
    end)
  end

  @doc false
  @spec push_prepared([node()], [prepared_beam()], (node(), module(), charlist(), binary() ->
                                                      term())) ::
          {non_neg_integer(), list()}
  def push_prepared(nodes, snapshot, rpc) when is_list(nodes) and is_function(rpc, 4) do
    with :ok <- validate_nodes(nodes),
         :ok <- validate_prepared_snapshot(snapshot),
         false <- Enum.any?(nodes, &android_node?/1) do
      push_prepared_internal(nodes, snapshot, rpc, fn _node -> :ok end)
    else
      true -> {0, [{:android_deploy_lock, :required}]}
      {:error, _reason} -> {0, [{:snapshot, :invalid}]}
    end
  end

  def push_prepared(_nodes, _snapshot, _rpc), do: {0, [{:snapshot, :invalid}]}

  # ── Runtime dep filtering ────────────────────────────────────────────────────

  # Returns only BEAM paths that belong to the app's runtime dependency tree.
  # Excludes deps marked only: :dev or runtime: false in mix.exs, and all of
  # their transitive deps (resolved via OTP .app files).
  defp runtime_beam_paths do
    runtime = runtime_lib_names()

    Path.wildcard("_build/dev/lib/*/ebin/*.beam")
    |> Enum.filter(fn path ->
      lib = path |> Path.split() |> Enum.at(-3)
      MapSet.member?(runtime, lib)
    end)
  end

  @doc """
  Returns ebin directories for runtime deps only (no dev-only tooling).
  Used by `Deployer` so the filesystem push matches the dist push scope.
  """
  @spec runtime_beam_dirs() :: [String.t()]
  def runtime_beam_dirs do
    runtime = runtime_lib_names()

    case File.ls("_build/dev/lib") do
      {:ok, libs} ->
        libs
        |> Enum.filter(&MapSet.member?(runtime, &1))
        |> Enum.map(&"_build/dev/lib/#{&1}/ebin")
        |> Enum.filter(&File.dir?/1)

      {:error, _} ->
        []
    end
  end

  defp runtime_lib_names do
    project_app = to_string(Mix.Project.config()[:app])

    # Direct runtime deps: no only: :dev and not runtime: false
    direct =
      Mix.Project.config()
      |> Keyword.get(:deps, [])
      |> Enum.flat_map(&dep_runtime_name/1)
      |> MapSet.new()
      |> MapSet.put(project_app)

    expand_runtime_libs(direct)
  end

  # Expand a set of lib names to include their transitive OTP deps,
  # by reading each lib's .app file in _build/dev.
  defp expand_runtime_libs(libs) do
    new_libs =
      Enum.flat_map(libs, fn lib ->
        case Path.wildcard("_build/dev/lib/#{lib}/ebin/*.app") do
          [app_file | _] ->
            case :file.consult(String.to_charlist(app_file)) do
              {:ok, [{:application, _app, props}]} ->
                (props[:applications] || []) |> Enum.map(&to_string/1)

              _ ->
                []
            end

          [] ->
            []
        end
      end)
      |> MapSet.new()
      |> MapSet.difference(libs)

    if MapSet.size(new_libs) == 0 do
      libs
    else
      expand_runtime_libs(MapSet.union(libs, new_libs))
    end
  end

  # Returns the app name as a string if this dep is a runtime dep, else [].
  defp dep_runtime_name(dep) do
    {app, opts} =
      case dep do
        {app, _version, opts} when is_list(opts) -> {app, opts}
        {app, opts} when is_list(opts) -> {app, opts}
        {app, _version} -> {app, []}
        app when is_atom(app) -> {app, []}
      end

    only = Keyword.get(opts, :only)
    runtime = Keyword.get(opts, :runtime, true)
    dev_only = only == :dev or only == [:dev] or (is_list(only) and only == [:dev])
    if dev_only or not runtime, do: [], else: [to_string(app)]
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  defp prepare_paths(paths) do
    paths
    |> Enum.reduce_while({:ok, [], 0, MapSet.new()}, fn path,
                                                        {:ok, prepared, total_bytes, modules} ->
      with :ok <- validate_beam_path(path),
           {:ok, stat} <- File.stat(path),
           true <- stat.type == :regular and stat.size <= @max_beam_file_bytes,
           true <- total_bytes + stat.size <= @max_beam_total_bytes,
           {:ok, binary} <- File.read(path),
           true <- byte_size(binary) == stat.size and byte_size(binary) <= @max_beam_file_bytes,
           {:ok, module} <- beam_module(binary),
           true <- Atom.to_string(module) == Path.basename(path, ".beam"),
           false <- MapSet.member?(modules, module) do
        entry = %{
          module: module,
          path: path,
          binary: binary,
          sha256: :crypto.hash(:sha256, binary)
        }

        {:cont,
         {:ok, [entry | prepared], total_bytes + byte_size(binary), MapSet.put(modules, module)}}
      else
        _invalid -> {:halt, {:error, "BEAM snapshot source is invalid"}}
      end
    end)
    |> case do
      {:ok, prepared, _total_bytes, _modules} -> {:ok, Enum.reverse(prepared)}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec validate_prepared_snapshot(term()) :: :ok | {:error, atom()}
  def validate_prepared_snapshot(snapshot) when is_list(snapshot) do
    snapshot
    |> Enum.reduce_while({:ok, 0, MapSet.new(), MapSet.new()}, fn entry,
                                                                  {:ok, total, modules, paths} ->
      with %{
             module: module,
             path: path,
             binary: binary,
             sha256: sha256
           } <- entry,
           true <- map_size(entry) == 4,
           true <- is_atom(module),
           :ok <- validate_beam_path(path),
           true <- is_binary(binary) and byte_size(binary) <= @max_beam_file_bytes,
           true <- is_binary(sha256) and byte_size(sha256) == 32,
           true <- :crypto.hash(:sha256, binary) == sha256,
           {:ok, ^module} <- beam_module(binary),
           true <- Atom.to_string(module) == Path.basename(path, ".beam"),
           false <- MapSet.member?(modules, module),
           false <- MapSet.member?(paths, path),
           true <- total + byte_size(binary) <= @max_beam_total_bytes do
        {:cont,
         {:ok, total + byte_size(binary), MapSet.put(modules, module), MapSet.put(paths, path)}}
      else
        _invalid -> {:halt, {:error, :invalid_snapshot}}
      end
    end)
    |> case do
      {:ok, _total, _modules, _paths} ->
        if length(snapshot) <= @max_beam_files,
          do: :ok,
          else: {:error, :too_many_files}

      {:error, _reason} = error ->
        error
    end
  end

  def validate_prepared_snapshot(_snapshot), do: {:error, :invalid_snapshot}

  defp push_with_ordinary_android_lease(nodes, snapshot) do
    push_prepared_fenced(nodes, snapshot, [])
  end

  @doc false
  @spec push_prepared_fenced([node()], [prepared_beam()], keyword()) ::
          {non_neg_integer(), list()}
  def push_prepared_fenced(nodes, snapshot, opts)
      when is_list(nodes) and is_list(opts) do
    with :ok <- validate_nodes(nodes),
         :ok <- validate_prepared_snapshot(snapshot),
         {:ok, post_push} <- validate_post_push(Keyword.get(opts, :post_push)),
         {:ok, serials} <- android_serials_for_nodes(nodes, opts) do
      {android_nodes, other_nodes} = Enum.split_with(nodes, &android_node?/1)

      case {Keyword.get(opts, :android_deploy_lock), serials} do
        {lease, serials} when not is_nil(lease) ->
          push_with_existing_android_lease(
            android_nodes,
            other_nodes,
            snapshot,
            serials,
            lease,
            post_push,
            opts
          )

        {nil, []} ->
          push_without_android(nodes, snapshot, post_push, opts)

        {nil, serials} ->
          push_with_acquired_android_lease(
            android_nodes,
            other_nodes,
            snapshot,
            serials,
            post_push,
            opts
          )
      end
    else
      {:error, :android_target_ambiguous} -> {0, [{:android_deploy_lock, :target_ambiguous}]}
      {:error, :invalid_post_push} -> {0, [{:android_post_push, :invalid}]}
      {:error, _reason} -> {0, [{:snapshot, :invalid}]}
    end
  end

  def push_prepared_fenced(_nodes, _snapshot, _opts), do: {0, [{:snapshot, :invalid}]}

  defp push_without_android(nodes, snapshot, nil, opts) do
    push_prepared_internal(
      nodes,
      snapshot,
      Keyword.get(opts, :rpc, &load_binary_rpc/4),
      fn _node -> :ok end
    )
  end

  defp push_without_android(_nodes, _snapshot, _post_push, _opts),
    do: {0, [{:android_post_push, :requires_android_lease}]}

  defp push_with_acquired_android_lease(
         android_nodes,
         other_nodes,
         snapshot,
         serials,
         post_push,
         opts
       ) do
    package = Keyword.get(opts, :package, Config.bundle_id())
    runner = Keyword.get(opts, :lock_runner, &run_adb_lock_command/1)
    rpc = Keyword.get(opts, :rpc, &load_binary_rpc/4)

    case AndroidDeployLock.acquire(package, serials, runner) do
      {:ok, lease} ->
        case run_ordinary_hot_push(
               android_nodes,
               snapshot,
               lease,
               runner,
               rpc,
               post_push
             ) do
          {:ok, pushed} ->
            push_other_nodes_after_android_release(other_nodes, snapshot, rpc, pushed)

          {:error, failures} ->
            {0, failures}
        end

      {:error, %{lease: %{state: state}}}
      when state in [:retained_failure, :retained_ambiguous] ->
        {0,
         [
           {:android_deploy_lock, :acquire_ambiguous},
           {:android_deploy_lock, :retained}
         ]}

      {:error, _failure} ->
        {0, [{:android_deploy_lock, :unavailable}]}
    end
  end

  defp run_ordinary_hot_push(nodes, snapshot, lease, runner, rpc, post_push) do
    fence = fn _node -> verify_hot_push_lease(lease, runner) end

    with :ok <- verify_hot_push_lease(lease, runner) do
      case push_prepared_internal(nodes, snapshot, rpc, fence) do
        {pushed, []} ->
          with :ok <- run_fenced_post_push(post_push, nodes, lease, runner),
               :ok <- verify_hot_push_lease(lease, runner) do
            commit_and_release_hot_push(pushed, lease, runner)
          else
            {:error, :post_push_ambiguous} ->
              {:error,
               [
                 {:android_post_push, :ambiguous},
                 {:android_deploy_lock, :retained}
               ]}

            {:error, _failure} ->
              {:error,
               [
                 {:android_deploy_lock, :authority_ambiguous},
                 {:android_deploy_lock, :retained}
               ]}
          end

        {_pushed, failed} ->
          {:error, failed ++ [{:android_deploy_lock, :retained}]}
      end
    else
      {:error, _failure} ->
        {:error,
         [
           {:android_deploy_lock, :authority_ambiguous},
           {:android_deploy_lock, :retained}
         ]}
    end
  end

  defp push_with_existing_android_lease(
         nodes,
         other_nodes,
         snapshot,
         serials,
         lease,
         post_push,
         opts
       ) do
    package = Keyword.get(opts, :package, Config.bundle_id())
    runner = Keyword.get(opts, :lock_runner, &run_adb_lock_command/1)
    rpc = Keyword.get(opts, :rpc, &load_binary_rpc/4)
    expected_phase = Keyword.get(opts, :expected_lock_phase)

    with true <- other_nodes == [],
         true <- expected_phase in [:acquired, :native_ready],
         true <- AndroidDeployLock.valid?(lease, expected_phase),
         true <- lease.bundle_id == package,
         true <- serials == lease.serials,
         :ok <- verify_hot_push_lease(lease, runner) do
      case push_prepared_internal(nodes, snapshot, rpc, fn _node ->
             verify_hot_push_lease(lease, runner)
           end) do
        {pushed, []} ->
          with :ok <- run_fenced_post_push(post_push, nodes, lease, runner),
               :ok <- verify_hot_push_lease(lease, runner) do
            {pushed, []}
          else
            {:error, :post_push_ambiguous} ->
              {0,
               [
                 {:android_post_push, :ambiguous},
                 {:android_deploy_lock, :retained}
               ]}

            {:error, _failure} ->
              {0,
               [
                 {:android_deploy_lock, :authority_ambiguous},
                 {:android_deploy_lock, :retained}
               ]}
          end

        {_pushed, failed} ->
          {0, failed ++ [{:android_deploy_lock, :retained}]}
      end
    else
      _invalid_or_ambiguous ->
        {0,
         [
           {:android_deploy_lock, :authority_ambiguous},
           {:android_deploy_lock, :retained}
         ]}
    end
  end

  defp push_other_nodes_after_android_release([], _snapshot, _rpc, pushed),
    do: {pushed, []}

  defp push_other_nodes_after_android_release(nodes, snapshot, rpc, _android_pushed) do
    case push_prepared_internal(nodes, snapshot, rpc, fn _node -> :ok end) do
      {pushed, []} -> {pushed, []}
      {_pushed, failed} -> {0, failed ++ [{:hot_push, :partial_after_android_commit}]}
    end
  end

  defp run_fenced_post_push(nil, _nodes, _lease, _runner), do: :ok

  defp run_fenced_post_push(post_push, nodes, lease, runner) do
    with :ok <- invoke_post_push_on_nodes(post_push, nodes, lease, runner),
         :ok <- verify_hot_push_lease(lease, runner) do
      :ok
    else
      _failure_or_ambiguity -> {:error, :post_push_ambiguous}
    end
  end

  defp invoke_post_push_on_nodes(post_push, nodes, lease, runner) do
    Enum.reduce_while(nodes, :ok, fn node, :ok ->
      with :ok <- verify_hot_push_lease(lease, runner),
           :ok <- invoke_post_push(post_push, node) do
        {:cont, :ok}
      else
        _failure_or_ambiguity -> {:halt, {:error, :post_push_ambiguous}}
      end
    end)
  end

  defp invoke_post_push(post_push, node) do
    try do
      case post_push.(node) do
        :ok -> :ok
        _failure -> {:error, :post_push_ambiguous}
      end
    rescue
      _error -> {:error, :post_push_ambiguous}
    catch
      _kind, _reason -> {:error, :post_push_ambiguous}
    end
  end

  defp validate_post_push(nil), do: {:ok, nil}
  defp validate_post_push(post_push) when is_function(post_push, 1), do: {:ok, post_push}
  defp validate_post_push(_post_push), do: {:error, :invalid_post_push}

  defp verify_hot_push_lease(lease, runner) do
    Enum.reduce_while(lease.serials, :ok, fn serial, :ok ->
      case AndroidDeployLock.verify_owner(lease, serial, runner) do
        :ok -> {:cont, :ok}
        {:error, _failure} = error -> {:halt, error}
      end
    end)
  end

  defp commit_and_release_hot_push(pushed, lease, runner) do
    case AndroidDeployLock.transition(lease, :acquired, :fast_committed, runner) do
      {:ok, committed} ->
        case AndroidDeployLock.release(committed, runner) do
          :ok ->
            {:ok, pushed}

          {:error, _failure} ->
            {:error,
             [
               {:android_deploy_lock, :release_ambiguous},
               {:android_deploy_lock, :retained}
             ]}
        end

      {:error, _failure} ->
        {:error,
         [
           {:android_deploy_lock, :transition_ambiguous},
           {:android_deploy_lock, :retained}
         ]}
    end
  end

  defp android_serials_for_nodes([], _opts), do: {:ok, []}

  defp android_serials_for_nodes(nodes, opts) do
    android_nodes = Enum.filter(nodes, &android_node?/1)

    if android_nodes == [] do
      {:ok, []}
    else
      with {:ok, devices} <- android_devices(opts),
           {:ok, serials} <- exact_android_serials(android_nodes, devices),
           true <- length(serials) <= @max_android_targets do
        {:ok, serials}
      else
        _missing_duplicate_or_excessive -> {:error, :android_target_ambiguous}
      end
    end
  end

  defp android_devices(opts) do
    case Keyword.fetch(opts, :android_devices) do
      {:ok, devices} when is_list(devices) -> {:ok, devices}
      {:ok, _invalid} -> {:error, :invalid_discovery}
      :error -> discover_android_devices()
    end
  end

  defp discover_android_devices do
    try do
      case Android.list_devices() do
        devices when is_list(devices) -> {:ok, devices}
        _invalid -> {:error, :invalid_discovery}
      end
    rescue
      _error -> {:error, :invalid_discovery}
    catch
      _kind, _reason -> {:error, :invalid_discovery}
    end
  end

  defp exact_android_serials(nodes, devices) do
    grouped =
      devices
      |> Enum.flat_map(fn
        %{platform: :android, node: node, serial: serial}
        when is_atom(node) and is_binary(serial) ->
          [{node, serial}]

        _invalid ->
          []
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    nodes
    |> Enum.reduce_while({:ok, []}, fn node, {:ok, serials} ->
      case Map.get(grouped, node) do
        [serial] -> {:cont, {:ok, [serial | serials]}}
        _missing_or_ambiguous -> {:halt, {:error, :android_target_ambiguous}}
      end
    end)
    |> case do
      {:ok, serials} ->
        ordered = Enum.sort(serials)

        if Enum.uniq(ordered) == ordered,
          do: {:ok, ordered},
          else: {:error, :android_target_ambiguous}

      {:error, _reason} = error ->
        error
    end
  end

  defp android_node?(node) when is_atom(node) do
    app = Mix.Project.config()[:app] |> to_string()
    String.starts_with?(Atom.to_string(node), "#{app}_android")
  end

  defp run_adb_lock_command(args) do
    System.cmd("adb", args, stderr_to_stdout: true)
  end

  defp load_binary_rpc(node, module, filename, binary) do
    :rpc.call(node, :code, :load_binary, [module, filename, binary])
  end

  defp push_prepared_internal(nodes, snapshot, rpc, before_rpc) do
    snapshot
    |> Enum.reduce_while({0, []}, fn prepared, {count, []} ->
      case load_prepared_on_nodes(nodes, prepared, rpc, before_rpc) do
        :ok -> {:cont, {count + 1, []}}
        {:error, failure} -> {:halt, {count, [failure]}}
      end
    end)
  end

  defp load_prepared_on_nodes(nodes, prepared, rpc, before_rpc) do
    filename = String.to_charlist(prepared.path)

    Enum.reduce_while(nodes, :ok, fn node, :ok ->
      case invoke_before_rpc(before_rpc, node) do
        :ok ->
          load_prepared_on_node(rpc, node, prepared, filename)

        {:error, _reason} ->
          {:halt, {:error, {prepared.module, [{node, :authority_ambiguous}]}}}
      end
    end)
  end

  defp load_prepared_on_node(rpc, node, prepared, filename) do
    case invoke_rpc(rpc, node, prepared.module, filename, prepared.binary) do
      {:module, module} when module == prepared.module ->
        {:cont, :ok}

      {:badrpc, _reason} ->
        {:halt, {:error, {prepared.module, [{node, :badrpc}]}}}

      {:error, :on_load_failure} ->
        {:halt, {:error, {prepared.module, [{node, :on_load_failure}]}}}

      {:error, _reason} ->
        {:halt, {:error, {prepared.module, [{node, :load_failed}]}}}

      _unexpected ->
        {:halt, {:error, {prepared.module, [{node, :unexpected_reply}]}}}
    end
  end

  defp invoke_before_rpc(before_rpc, node) do
    try do
      case before_rpc.(node) do
        :ok -> :ok
        _failure -> {:error, :authority_ambiguous}
      end
    rescue
      _error -> {:error, :authority_ambiguous}
    catch
      _kind, _reason -> {:error, :authority_ambiguous}
    end
  end

  defp invoke_rpc(rpc, node, module, filename, binary) do
    try do
      rpc.(node, module, filename, binary)
    rescue
      _error -> {:error, :rpc_exception}
    catch
      _kind, _reason -> {:error, :rpc_exception}
    end
  end

  defp validate_nodes(nodes) do
    if Enum.all?(nodes, &is_atom/1) and Enum.uniq(nodes) == nodes,
      do: :ok,
      else: {:error, :invalid_nodes}
  end

  defp validate_beam_path(path) when is_binary(path) do
    if byte_size(path) in 1..@max_beam_path_bytes and String.valid?(path) and
         String.ends_with?(path, ".beam"),
       do: :ok,
       else: {:error, :invalid_path}
  end

  defp validate_beam_path(_path), do: {:error, :invalid_path}

  defp beam_module(binary) when is_binary(binary) do
    try do
      case :beam_lib.info(binary) do
        info when is_list(info) ->
          case Keyword.fetch(info, :module) do
            {:ok, module} when is_atom(module) -> {:ok, module}
            _missing -> {:error, :invalid_beam}
          end

        _invalid ->
          {:error, :invalid_beam}
      end
    rescue
      _error -> {:error, :invalid_beam}
    catch
      _kind, _reason -> {:error, :invalid_beam}
    end
  end

  defp ensure_local_dist(cookie) do
    unless Node.alive?() do
      Node.start(:"mob_dev@127.0.0.1", :longnames)
      Node.set_cookie(cookie)
    end
  end
end
