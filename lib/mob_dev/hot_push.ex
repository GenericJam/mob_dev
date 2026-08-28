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
  Pushes all compiled BEAM files from the active Mix build path to `nodes`.

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

    push_beams(nodes, beams)
  end

  # ── Runtime dep filtering ────────────────────────────────────────────────────

  # Returns only BEAM paths that belong to the app's runtime dependency tree.
  # Excludes deps marked only: :dev or runtime: false in mix.exs, and all of
  # their transitive deps (resolved via OTP .app files).
  defp runtime_beam_paths do
    runtime = runtime_lib_names()
    project_app = to_string(Mix.Project.config()[:app])

    select_runtime_beam_paths(
      Mix.Project.build_path(),
      active_compile_path(),
      runtime,
      project_app
    )
  end

  @doc """
  Returns ebin directories for runtime deps only (no dev-only tooling).
  Used by `Deployer` so the filesystem push matches the dist push scope.
  """
  @spec runtime_beam_dirs() :: [String.t()]
  def runtime_beam_dirs do
    runtime = runtime_lib_names()
    project_app = to_string(Mix.Project.config()[:app])

    select_runtime_beam_dirs(
      Mix.Project.build_path(),
      active_compile_path(),
      runtime,
      project_app
    )
  end

  @doc false
  @spec select_runtime_beam_paths(String.t(), String.t(), MapSet.t(String.t()), String.t()) ::
          [String.t()]
  def select_runtime_beam_paths(build_path, compile_path, runtime, project_app) do
    build_path
    |> select_runtime_beam_dirs(compile_path, runtime, project_app)
    |> Enum.flat_map(&beam_files/1)
  end

  @doc false
  @spec select_runtime_beam_dirs(String.t(), String.t(), MapSet.t(String.t()), String.t()) ::
          [String.t()]
  def select_runtime_beam_dirs(build_path, compile_path, runtime, project_app) do
    lib_path = Path.join(build_path, "lib")

    runtime_dirs =
      case File.ls(lib_path) do
        {:ok, libs} ->
          libs
          |> Enum.filter(&(MapSet.member?(runtime, &1) and &1 != project_app))
          |> Enum.map(&Path.join([lib_path, &1, "ebin"]))
          |> Enum.filter(&File.dir?/1)

        {:error, _} ->
          []
      end

    dependency_dirs = Enum.sort(runtime_dirs)

    if File.dir?(compile_path), do: dependency_dirs ++ [compile_path], else: dependency_dirs
  end

  # Mix.Project.compile_path/0 RAISES for an umbrella root ("umbrellas have no
  # app"), where the previous hardcoded _build/dev wildcard just returned
  # nothing. mob does not support umbrellas (MobDev.AdoptGuard refuses them
  # outright), so fail with that message rather than leaking Mix's internal
  # error out of a deploy.
  defp active_compile_path do
    if Mix.Project.umbrella?() do
      Mix.raise(
        "mob does not support umbrella applications — run mix mob.deploy from a " <>
          "child app, not the umbrella root"
      )
    end

    Mix.Project.compile_path()
  end

  @doc false
  # Test seam. runtime_lib_names/0 reads Mix.Project.config() and is the
  # function that actually decides what gets pushed, but being private it had
  # no coverage — the tests all hand-built the MapSet it produces and so could
  # not catch a regression in it. Exposed so a fixture project can drive it.
  @spec __runtime_lib_names__() :: MapSet.t(String.t())
  def __runtime_lib_names__, do: runtime_lib_names()

  defp runtime_lib_names do
    config = Mix.Project.config()
    project_app = to_string(config[:app])

    # Direct runtime deps: no only: :dev and not runtime: false
    direct =
      config
      |> Keyword.get(:deps, [])
      |> Enum.flat_map(&dep_runtime_name/1)
      |> MapSet.new()

    # Seed with the project itself so its OWN .app is traversed. A dependency
    # can be reachable only through the project's `applications:` list — the
    # documented `runtime: false` + `extra_applications:` idiom, where
    # extra_applications deliberately overrides the runtime: false flag. Drop
    # the seed and those libs are never pushed; the app boots and dies with
    # undef on first use, which is the same failure class this module exists
    # to avoid.
    #
    # The reason the seed was previously removed is real though: the project's
    # .app also lists `only: :dev` deps under MIX_ENV=dev, which leaked them
    # into the runtime set and contradicted this module's docs. So expand
    # first, then subtract the deps we know are dev-only or runtime: false.
    # project_app itself is excluded at the directory-selection step
    # (select_runtime_beam_dirs/4), where the stale-output concern lives.
    expanded =
      direct
      |> MapSet.put(project_app)
      |> expand_runtime_libs(Mix.Project.build_path())

    MapSet.difference(expanded, non_runtime_dep_names(config))
  end

  # Names of direct deps explicitly marked `only: :dev`/`:test` or
  # `runtime: false`, EXCEPT any the project re-declares in
  # `extra_applications` — that combination is how a build-time dep is opted
  # back into the runtime application list, and it must survive the subtraction.
  defp non_runtime_dep_names(config) do
    # extra_applications lives on the project module's application/0 callback,
    # NOT in Mix.Project.config/0 — reading it from config silently yields []
    # and subtracts the very libs this is meant to keep.
    kept =
      case Mix.Project.get() do
        nil ->
          MapSet.new()

        module ->
          if function_exported?(module, :application, 0) do
            module.application()
            |> Keyword.get(:extra_applications, [])
            |> Enum.map(&to_string/1)
            |> MapSet.new()
          else
            MapSet.new()
          end
      end

    config
    |> Keyword.get(:deps, [])
    |> Enum.flat_map(fn dep ->
      case dep_runtime_name(dep) do
        [] -> [to_string(elem(dep, 0))]
        _ -> []
      end
    end)
    |> MapSet.new()
    |> MapSet.difference(kept)
  end

  # Expand a set of lib names to include their transitive OTP deps,
  # by reading each lib's .app file in the active Mix build path.
  defp expand_runtime_libs(libs, build_path) do
    new_libs =
      Enum.flat_map(libs, fn lib ->
        case app_files(Path.join([build_path, "lib", lib, "ebin"])) do
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
      expand_runtime_libs(MapSet.union(libs, new_libs), build_path)
    end
  end

  defp beam_files(dir) do
    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".beam"))
        |> Enum.sort()
        |> Enum.map(&Path.join(dir, &1))

      {:error, _} ->
        []
    end
  end

  defp app_files(dir) do
    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".app"))
        |> Enum.sort()
        |> Enum.map(&Path.join(dir, &1))

      {:error, _} ->
        []
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

  defp push_beams(_nodes, []), do: {0, []}

  defp push_beams(nodes, beam_files) do
    results =
      Enum.map(beam_files, fn path ->
        module = beam_path_to_module(path)

        case File.read(path) do
          {:ok, binary} -> load_on_nodes(nodes, module, path, binary)
          {:error, reason} -> {:error, {module, reason}}
        end
      end)

    pushed = Enum.count(results, &match?(:ok, &1))
    failed = for {:error, pair} <- results, do: pair
    {pushed, failed}
  end

  defp load_on_nodes(nodes, module, path, binary) do
    fname = String.to_charlist(path)

    errors =
      Enum.flat_map(nodes, fn node ->
        case :rpc.call(node, :code, :load_binary, [module, fname, binary]) do
          {:module, ^module} -> []
          # NIF modules already loaded — safe to ignore
          {:error, :on_load_failure} -> []
          {:badrpc, reason} -> [{node, reason}]
          {:error, reason} -> [{node, reason}]
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
