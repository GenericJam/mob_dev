defmodule MobDev.HotPush do
  @moduledoc """
  Connects to already-running device nodes and hot-pushes BEAM modules via RPC.

  Unlike `MobDev.Deployer`, this does NOT restart apps — modules are loaded
  into the running BEAM in place, just like `nl/1` in IEx.

  Requires apps to already be running (start with `mix mob.connect` or
  `mix mob.deploy` first).
  """

  alias MobDev.{Tunnel}
  alias MobDev.Discovery.{Android, IOS}

  @cookie :mob_secret

  @doc """
  Sets up adb tunnels (idempotent) and connects to all running device nodes.
  Returns list of connected node atoms.
  """
  @spec connect(keyword()) :: [node()]
  def connect(opts \\ []) do
    cookie = Keyword.get(opts, :cookie, @cookie)

    nodes =
      (Android.list_devices() ++ IOS.list_simulators())
      |> Enum.with_index()
      |> Enum.flat_map(fn {device, idx} ->
        case Tunnel.setup(device, idx) do
          {:ok, d} -> [d]
          _        -> []
        end
      end)
      |> Enum.flat_map(fn device ->
        ensure_local_dist(cookie)
        Node.set_cookie(device.node, cookie)
        case Node.connect(device.node) do
          true -> [device.node]
          _    -> []
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
    beams = runtime_beam_paths()
    push_beams(nodes, beams)
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
      mtime = case File.stat(path, time: :posix) do
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
        current_mtime = case File.stat(path, time: :posix) do
          {:ok, %{mtime: t}} -> t
          _ -> 0
        end
        current_mtime != Map.get(snapshot, path, 0)
      end)

    push_beams(nodes, beams)
  end

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
              _ -> []
            end
          [] -> []
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
    {app, opts} = case dep do
      {app, _version, opts} when is_list(opts) -> {app, opts}
      {app, opts}           when is_list(opts) -> {app, opts}
      {app, _version}                          -> {app, []}
      app                   when is_atom(app)  -> {app, []}
    end
    only    = Keyword.get(opts, :only)
    runtime = Keyword.get(opts, :runtime, true)
    dev_only = only == :dev or only == [:dev] or (is_list(only) and only == [:dev])
    if dev_only or not runtime, do: [], else: [to_string(app)]
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  defp push_beams(_nodes, []), do: {0, []}

  defp push_beams(nodes, beam_files) do
    results = Enum.map(beam_files, fn path ->
      module = beam_path_to_module(path)
      case File.read(path) do
        {:ok, binary} -> load_on_nodes(nodes, module, path, binary)
        {:error, reason} -> {:error, {module, reason}}
      end
    end)

    pushed  = Enum.count(results, &match?(:ok, &1))
    failed  = for {:error, pair} <- results, do: pair
    {pushed, failed}
  end

  defp load_on_nodes(nodes, module, path, binary) do
    fname = String.to_charlist(path)
    errors = Enum.flat_map(nodes, fn node ->
      case :rpc.call(node, :code, :load_binary, [module, fname, binary]) do
        {:module, ^module}       -> []
        {:error, :on_load_failure} -> []  # NIF modules already loaded — safe to ignore
        {:badrpc, reason}        -> [{node, reason}]
        {:error, reason}         -> [{node, reason}]
      end
    end)
    if errors == [], do: :ok, else: {:error, {module, errors}}
  end

  defp beam_path_to_module(path) do
    path |> Path.basename(".beam") |> String.to_atom()
  end

  defp ensure_local_dist(cookie) do
    unless Node.alive?() do
      Node.start(:"mob_dev@127.0.0.1", :longnames)
      Node.set_cookie(cookie)
    end
  end
end
