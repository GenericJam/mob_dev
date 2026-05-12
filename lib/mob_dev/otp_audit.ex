defmodule MobDev.OtpAudit do
  @moduledoc """
  Reachability analysis for the bundled OTP runtime tree of a Mob app.

  Walks every `.beam` file under an OTP root, extracts the `imports` chunk
  to learn who calls whom, and computes the transitive closure starting
  from the app's entry-point modules. Anything not reachable is a strip
  candidate — modules, whole libs, or duplicate library versions.

  Used by `mix mob.audit_otp` (read-only report) and the planned
  `mix mob.release --slim` flag (auto-strip based on the report).

  ## Entry points

  Reachability seeding is deliberately generous:

    * App's `start/2` callback module (read from each `.app` file's `mod` key)
    * All exported functions of `kernel` and `stdlib` (BEAM startup needs them)
    * `elixir`, `logger`, `eex` (runtime support that gets called via macros)

  Anything reachable from those is kept; the rest is candidate-for-strip.

  ## Output

  Returns a map with:

    * `:libs` — every lib found, with reachable/total module counts and KB
    * `:duplicates` — libs that appear multiple times (only newest is kept)
    * `:foreign_apps` — non-OTP, non-app code in the lib dir (other projects)
    * `:strippable_libs` — libs with zero reachable modules
    * `:total_kb` / `:reachable_kb` / `:strippable_kb` — size summary

  All sizes are post-strip — i.e. what `mix mob.release` actually ships,
  not raw OTP source.
  """

  @type module_atom :: atom()
  @type lib_name :: String.t()

  @type lib_report :: %{
          name: lib_name(),
          version: String.t() | nil,
          path: String.t(),
          modules_total: non_neg_integer(),
          modules_reachable: non_neg_integer(),
          modules_traced: non_neg_integer() | nil,
          kb_total: non_neg_integer(),
          kb_reachable: non_neg_integer(),
          unreachable_modules: [module_atom()],
          untraced_modules: [module_atom()] | nil,
          is_app_under_test?: boolean()
        }

  @type report :: %{
          otp_root: String.t(),
          app_name: String.t() | nil,
          libs: [lib_report()],
          duplicates: %{lib_name() => [String.t()]},
          foreign_apps: [String.t()],
          foreign_app_names: [lib_name()],
          strippable_libs: [lib_name()],
          trace_strippable_libs: [lib_name()] | nil,
          total_kb: non_neg_integer(),
          reachable_kb: non_neg_integer(),
          strippable_kb: non_neg_integer()
        }

  # OTP runtime support that's called implicitly by every BEAM app.
  # Some of these don't show up in the static call graph (init invokes
  # them dynamically) so we seed them as always-reachable.
  @runtime_seed_libs ~w(kernel stdlib elixir logger sasl)

  # Apps that ship with OTP. Used by the foreign-app classifier — anything
  # in the bundle whose name is in this set is assumed legitimate. Sourced
  # from `lib/` in a stock OTP 28 release; update when OTP adds or removes
  # apps. `erts` is here too: in a stock OTP install it lives one level
  # above lib/, but mob's iOS bundle layout copies it into lib/ alongside
  # the apps, so the audit's `Path.wildcard("<root>/lib/*")` discovers it
  # like a normal lib and we have to allow-list it explicitly. Without
  # this the BEAM runtime gets classified as foreign cache cruft.
  @otp_shipped_libs ~w(
    asn1 common_test compiler crypto debugger dialyzer diameter edoc
    eldap erl_docgen erl_interface erts et eunit ftp inets jinterface
    kernel megaco mnesia observer odbc os_mon parsetools public_key
    reltool runtime_tools sasl snmp ssh ssl stdlib syntax_tools tftp
    tools wx xmerl
  )

  # Apps that ship with Elixir under the same lib/ tree as OTP libs after
  # mob bundles. Same purpose as @otp_shipped_libs — keep these out of
  # the foreign-app set.
  @elixir_shipped_libs ~w(elixir eex ex_unit iex logger mix)

  @doc """
  Run the audit. `otp_root` is the directory containing `lib/` and `erts-*/`
  (typically the runtime tree extracted into the app bundle, or the cache
  the release packaging copies from).

  ## Options

    * `:app_name` — the application's atom name (e.g. `:air_cart_max`).
      Used to seed reachability from the app's modules. If omitted, every
      lib with no `mod` callback is treated as a potential entry point
      (broader, finds less to strip).

    * `:project_deps` — list of atoms naming the project's deps (the
      transitive closure, as Mix sees them). When given, the foreign-app
      classifier uses it as the authoritative set of "non-OTP libs that
      are supposed to be in this bundle." Anything in the bundle whose
      name isn't OTP-shipped, Elixir-shipped, the app under test, or in
      `:project_deps` is classified as foreign and quarantined into
      `report.foreign_apps`. The `mix mob.audit_otp` task auto-detects
      this from the current `Mix.Project`.

      When omitted, the classifier falls back to a narrow name-pattern
      heuristic (`test_`, `toy_`, `mob_test`, `scratch_`) — sufficient
      for tests, less accurate in real bundles.

    * `:trace_input` — a `MapSet` (or list) of `module()` atoms that
      were observed at runtime during a trace window. Comes from
      `MobDev.OtpTrace.capture/1` (local synthetic harness) or
      `Mob.Diag.mfa_trace/1` (remote device trace). When given, the
      report grows two fields per lib (`modules_traced`,
      `untraced_modules`) and one top-level field
      (`trace_strippable_libs`) listing libs whose modules were
      ALL absent from the trace — i.e., empirically never called.

      Static reachability misses dynamic dispatch (`apply/3`,
      `:erlang.load_nif`, runtime config). Trace data catches
      everything that actually ran. The intersection `strippable_libs
      ∩ trace_strippable_libs` is the high-confidence strip set;
      `trace_strippable_libs \\ strippable_libs` is the "static graph
      reaches it but nothing actually called it" set that lets you
      strip partly-used libs like megaco / snmp / diameter.
  """
  @spec audit(String.t(), keyword()) :: report()
  def audit(otp_root, opts \\ []) do
    app_name = Keyword.get(opts, :app_name)
    project_deps = Keyword.get(opts, :project_deps)
    trace_input = normalize_trace_input(Keyword.get(opts, :trace_input))
    libs = discover_libs(otp_root)
    {duplicates, libs} = collapse_duplicates(libs)
    {foreign_apps, foreign_app_names, libs} = split_foreign_apps(libs, app_name, project_deps)
    module_to_lib = build_module_index(libs)
    imports = build_import_graph(libs)

    seed_modules = compute_seed_modules(libs, app_name)
    reachable = bfs(seed_modules, imports)

    lib_reports = build_lib_reports(libs, reachable, trace_input, module_to_lib)
    strippable = Enum.filter(lib_reports, &(&1.modules_reachable == 0)) |> Enum.map(& &1.name)

    trace_strippable =
      if trace_input do
        lib_reports
        |> Enum.filter(&(&1.modules_total > 0 and &1.modules_traced == 0))
        |> Enum.map(& &1.name)
      end

    %{
      otp_root: otp_root,
      app_name: app_name,
      libs: lib_reports,
      duplicates: duplicates,
      foreign_apps: foreign_apps,
      foreign_app_names: foreign_app_names,
      strippable_libs: strippable,
      trace_strippable_libs: trace_strippable,
      total_kb: Enum.sum(Enum.map(lib_reports, & &1.kb_total)),
      reachable_kb: Enum.sum(Enum.map(lib_reports, & &1.kb_reachable)),
      strippable_kb:
        lib_reports
        |> Enum.filter(&(&1.modules_reachable == 0))
        |> Enum.sum_by(& &1.kb_total)
    }
  end

  # Accept either nil, a MapSet, a list of atoms, or an `OtpTrace.result`
  # / `Mob.Diag.mfa_trace` map (which carries `:modules` of MapSet shape).
  # Returns a MapSet or nil.
  defp normalize_trace_input(nil), do: nil

  defp normalize_trace_input(%MapSet{} = ms), do: ms

  defp normalize_trace_input(%{modules: %MapSet{} = ms}), do: ms

  defp normalize_trace_input(%{modules: list}) when is_list(list), do: MapSet.new(list)

  defp normalize_trace_input(list) when is_list(list), do: MapSet.new(list)

  # ── Discovery ─────────────────────────────────────────────────────────

  defp discover_libs(otp_root) do
    Path.join(otp_root, "lib/*")
    |> Path.wildcard()
    |> Enum.filter(&File.dir?/1)
    |> Enum.map(fn dir ->
      {name, version} = parse_lib_dirname(Path.basename(dir))

      %{
        name: name,
        version: version,
        path: dir,
        beams: Path.wildcard(Path.join(dir, "ebin/*.beam")),
        app_callback: read_app_callback(dir, name)
      }
    end)
  end

  defp parse_lib_dirname(dirname) do
    case String.split(dirname, "-", parts: 2) do
      [name, version] -> {name, version}
      [name] -> {name, nil}
    end
  end

  defp read_app_callback(lib_dir, name) do
    app_file = Path.join(lib_dir, "ebin/#{name}.app")

    with true <- File.exists?(app_file),
         {:ok, [{:application, _, props}]} <- :file.consult(String.to_charlist(app_file)) do
      case Keyword.get(props, :mod) do
        {mod, _args} -> mod
        _ -> nil
      end
    else
      _ -> nil
    end
  end

  # When the same lib appears in multiple versions (asn1-5.4, asn1-5.4.3),
  # keep the highest version and report the others as duplicates.
  defp collapse_duplicates(libs) do
    by_name = Enum.group_by(libs, & &1.name)

    {dupes, kept} =
      Enum.reduce(by_name, {%{}, []}, fn
        {_name, [single]}, {dupes, kept} ->
          {dupes, [single | kept]}

        {name, multiple}, {dupes, kept} ->
          [latest | older] = Enum.sort_by(multiple, & &1.version, &version_gt/2)
          dupe_paths = Enum.map(older, & &1.path)
          {Map.put(dupes, name, dupe_paths), [latest | kept]}
      end)

    {dupes, Enum.reverse(kept)}
  end

  # Best-effort version comparison — handles `5.4` vs `5.4.3` correctly,
  # falls back to string compare for anything weirder.
  defp version_gt(a, b) when is_binary(a) and is_binary(b) do
    case {Version.parse(loosen(a)), Version.parse(loosen(b))} do
      {{:ok, va}, {:ok, vb}} -> Version.compare(va, vb) == :gt
      _ -> a > b
    end
  end

  defp version_gt(a, _b) when is_nil(a), do: false
  defp version_gt(_a, nil), do: true

  # Pad short versions ("5.4" → "5.4.0") so Version.parse accepts them.
  defp loosen(v) do
    parts = String.split(v, ".")

    case length(parts) do
      1 -> v <> ".0.0"
      2 -> v <> ".0"
      _ -> v
    end
  end

  # Anything in `lib/` that isn't a known OTP library and isn't the
  # current app is foreign (leaked from another project's release tree
  # via a shared cache, almost always). Report separately so the user
  # can clean their cache.
  #
  # Returns `{paths, names, kept_libs}`: paths feed report.foreign_apps
  # (what to delete), names feed report.foreign_app_names (what to log
  # / dedupe against a hardcoded strip list).
  defp split_foreign_apps(libs, app_name, project_deps) do
    app_str = if app_name, do: to_string(app_name), else: nil
    classifier = foreign_classifier(app_str, project_deps)

    {foreign, kept} = Enum.split_with(libs, classifier)

    {Enum.map(foreign, & &1.path), Enum.map(foreign, & &1.name), kept}
  end

  # When the caller supplies `:project_deps`, use the strict classifier:
  # foreign = NOT shipped with OTP/Elixir AND NOT the app under test AND
  # NOT in the project's dep closure. This is the production path (driven
  # by `mix mob.audit_otp` reading `Mix.Project.deps_apps/0`) and catches
  # any leftover from a shared OTP cache, no matter what the lib is named.
  #
  # When `:project_deps` is nil (default, tests and ad-hoc CLI use), fall
  # back to the historical name-pattern heuristic. It's narrower but
  # backward-compatible — tests built against the old behaviour keep
  # working.
  defp foreign_classifier(app_str, nil) do
    fn lib ->
      is_nil(lib.app_callback) and lib.name != app_str and not is_nil(lib.version) and
        name_pattern_user_app?(lib.name)
    end
  end

  defp foreign_classifier(app_str, project_deps) when is_list(project_deps) do
    allow_list =
      project_deps
      |> Enum.map(&to_string/1)
      |> MapSet.new()
      |> MapSet.union(MapSet.new(@otp_shipped_libs))
      |> MapSet.union(MapSet.new(@elixir_shipped_libs))
      |> then(fn s -> if app_str, do: MapSet.put(s, app_str), else: s end)

    fn lib ->
      not is_nil(lib.version) and not MapSet.member?(allow_list, lib.name)
    end
  end

  # Narrow legacy heuristic — kept for backwards compat with tests and
  # CLI use that doesn't have a Mix.Project context to provide deps.
  defp name_pattern_user_app?(name) do
    String.starts_with?(name, "test_") or String.starts_with?(name, "toy_") or
      String.starts_with?(name, "scratch_") or
      name in ~w(mob_test air_cart_max_test)
  end

  # ── Import graph ──────────────────────────────────────────────────────

  defp build_module_index(libs) do
    for lib <- libs,
        beam <- lib.beams,
        into: %{} do
      module = beam |> Path.basename(".beam") |> String.to_atom()
      {module, lib.name}
    end
  end

  defp build_import_graph(libs) do
    for lib <- libs,
        beam <- lib.beams,
        into: %{} do
      module = beam |> Path.basename(".beam") |> String.to_atom()
      imports = read_imports(beam)
      {module, MapSet.new(imports, fn {m, _f, _a} -> m end)}
    end
  end

  defp read_imports(beam) do
    case :beam_lib.chunks(String.to_charlist(beam), [:imports]) do
      {:ok, {_module, [{:imports, imports}]}} -> imports
      _ -> []
    end
  end

  # ── Reachability ──────────────────────────────────────────────────────

  defp compute_seed_modules(libs, app_name) do
    runtime_modules =
      libs
      |> Enum.filter(&(&1.name in @runtime_seed_libs))
      |> Enum.flat_map(&modules_in/1)

    app_modules =
      if app_name do
        case Enum.find(libs, &(&1.name == to_string(app_name))) do
          nil -> []
          lib -> modules_in(lib)
        end
      else
        []
      end

    callback_modules =
      libs
      |> Enum.flat_map(fn
        %{app_callback: cb} when is_atom(cb) and not is_nil(cb) -> [cb]
        _ -> []
      end)

    MapSet.new(runtime_modules ++ app_modules ++ callback_modules)
  end

  defp modules_in(lib) do
    Enum.map(lib.beams, fn b ->
      b |> Path.basename(".beam") |> String.to_atom()
    end)
  end

  defp bfs(seed, imports) do
    do_bfs(MapSet.new(seed), MapSet.new(seed), imports)
  end

  defp do_bfs(reached, frontier, imports) do
    next =
      frontier
      |> Enum.flat_map(fn mod -> Map.get(imports, mod, MapSet.new()) end)
      |> MapSet.new()
      |> MapSet.difference(reached)

    if MapSet.size(next) == 0 do
      reached
    else
      do_bfs(MapSet.union(reached, next), next, imports)
    end
  end

  # ── Reporting ─────────────────────────────────────────────────────────

  defp build_lib_reports(libs, reachable, trace_input, _module_to_lib) do
    Enum.map(libs, fn lib ->
      modules = modules_in(lib) |> MapSet.new()
      reach = MapSet.intersection(modules, reachable)

      {traced_count, untraced} =
        case trace_input do
          nil ->
            {nil, nil}

          ms ->
            traced = MapSet.intersection(modules, ms)
            {MapSet.size(traced), MapSet.difference(modules, ms) |> Enum.sort()}
        end

      %{
        name: lib.name,
        version: lib.version,
        path: lib.path,
        modules_total: MapSet.size(modules),
        modules_reachable: MapSet.size(reach),
        modules_traced: traced_count,
        kb_total: dir_size_kb(lib.path),
        kb_reachable: beam_size_kb(lib.beams, reach),
        unreachable_modules: MapSet.difference(modules, reach) |> Enum.sort(),
        untraced_modules: untraced,
        is_app_under_test?: false
      }
    end)
    |> Enum.sort_by(& &1.kb_total, :desc)
  end

  defp dir_size_kb(path) do
    case System.cmd("du", ["-sk", path], stderr_to_stdout: true) do
      {out, 0} -> out |> String.split() |> List.first() |> String.to_integer()
      _ -> 0
    end
  end

  defp beam_size_kb(beams, reachable_modules) do
    beams
    |> Enum.filter(fn b ->
      mod = b |> Path.basename(".beam") |> String.to_atom()
      MapSet.member?(reachable_modules, mod)
    end)
    |> Enum.map(fn beam -> File.stat!(beam).size / 1024 end)
    |> Enum.sum()
    |> round()
  end
end
