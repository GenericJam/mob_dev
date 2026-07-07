defmodule MobDev.Plugin.Merge do
  @moduledoc """
  Gathers the contributions of the activated plugins into combined lists the
  build pipeline consumes.

  Pure: every function takes `plugins` — a list of `{plugin_dir, manifest}` for
  the activated plugins — and returns the merged contribution for one build
  concern (NIFs, permissions, gradle deps, frameworks, native sources, …).
  Path-bearing declarations are resolved to absolute paths against each
  plugin's own directory, so contributions from different plugins don't
  collide or get misresolved. Tier-0 (nil-manifest) plugins contribute nothing.

  Discovery (deps → activated → load manifest) is the caller's job; this module
  is the testable transform once the manifests are in hand.
  """

  @type plugin :: {Path.t(), map() | nil}

  @doc """
  Combined NIF entries across all plugins, with `:native_dir` resolved to an
  absolute path. Shape matches `MobDev.StaticNifs` entries (`:module` plus the
  plugin's native source dir), so the result can be fed straight into
  `StaticNifs.resolve/1`.
  """
  @spec nifs([plugin()]) :: [map()]
  def nifs(plugins) do
    for {dir, manifest} <- with_manifests(plugins),
        nif <- Map.get(manifest, :nifs, []),
        is_map(nif) do
      case nif[:native_dir] do
        nil -> nif
        rel -> Map.put(nif, :native_dir, Path.join(dir, rel))
      end
    end
  end

  @doc "Unique Android permission strings declared across plugins."
  @spec android_permissions([plugin()]) :: [String.t()]
  def android_permissions(plugins), do: collect_uniq(plugins, [:android, :permissions])

  @doc "Unique Android gradle dependency strings across plugins."
  @spec gradle_deps([plugin()]) :: [String.t()]
  def gradle_deps(plugins), do: collect_uniq(plugins, [:android, :gradle_deps])

  @doc """
  AndroidManifest `<application>` snippets each plugin contributes (a `<service>`,
  `<receiver>`, `<provider>`, …), tagged with `:plugin`. `native_build` splices
  each into the app manifest's `<application>` block (idempotent on the
  component's `android:name`). Ships the manifest half of a component whose class
  rides in the plugin's `bridge_kt`; see also `android_res_files/1` for the
  `res/` half (e.g. an `apduservice.xml`).
  """
  @spec android_manifest_snippets([plugin()]) :: [%{plugin: atom(), snippet: String.t()}]
  def android_manifest_snippets(plugins) do
    for {_dir, manifest} <- with_manifests(plugins),
        snippet <- List.wrap(get_in(manifest, [:android, :manifest_application_snippets])),
        is_binary(snippet),
        do: %{plugin: manifest[:name], snippet: snippet}
  end

  @doc """
  Android `res/` files each plugin contributes, resolved to `{plugin, src, dest}`.
  `src` is absolute (against the plugin dir); `dest` is the path under
  `android/app/src/main/` derived from the declared path's last `res/` segment
  (`priv/native/android/res/xml/foo.xml` → `res/xml/foo.xml`). `native_build`
  copies each into the app res tree. Pairs with `android_manifest_snippets/1`
  (a `<meta-data android:resource="@xml/foo"/>` needs its `res/xml/foo.xml`).
  """
  @spec android_res_files([plugin()]) :: [%{plugin: atom(), src: String.t(), dest: String.t()}]
  def android_res_files(plugins) do
    for {dir, manifest} <- with_manifests(plugins),
        rel <- List.wrap(get_in(manifest, [:android, :res_files])),
        is_binary(rel) do
      %{plugin: manifest[:name], src: Path.join(dir, rel), dest: res_dest(rel)}
    end
  end

  # Android res destination for a plugin-relative path: everything from the last
  # `res` path segment onward, so it lands correctly typed under the app's
  # `res/` tree. Falls back to `res/<basename>` when no `res` segment is present
  # (the manifest validator rejects that case up front).
  defp res_dest(rel) do
    parts = Path.split(rel)

    case last_index(parts, "res") do
      nil -> Path.join("res", Path.basename(rel))
      idx -> Path.join(Enum.drop(parts, idx))
    end
  end

  defp last_index(list, value) do
    list
    |> Enum.with_index()
    |> Enum.reduce(nil, fn {v, i}, acc -> if v == value, do: i, else: acc end)
  end

  @doc "Unique iOS framework names across plugins."
  @spec ios_frameworks([plugin()]) :: [String.t()]
  def ios_frameworks(plugins), do: collect_uniq(plugins, [:ios, :frameworks])

  @doc "Absolute paths of all plugin iOS Swift source files."
  @spec swift_files([plugin()]) :: [String.t()]
  def swift_files(plugins), do: collect_paths(plugins, [:ios, :swift_files])

  @doc """
  Absolute paths of all plugin Android native sources (`bridge_kt`,
  `jni_source`) plus NIF `native_dir`s — everything the Android build must
  compile in.
  """
  @spec android_sources([plugin()]) :: [String.t()]
  def android_sources(plugins) do
    bridge = collect_paths(plugins, [:android, :bridge_kt])
    jni = collect_paths(plugins, [:android, :jni_source])
    nif_dirs = for nif <- nifs(plugins), dir = nif[:native_dir], do: dir

    (bridge ++ jni ++ nif_dirs) |> Enum.uniq()
  end

  @doc """
  Absolute paths of plugin Android `jni_source` files — plain JNI-thunk C
  (e.g. `Java_<pkg>_<Class>_nativeDeliver*`) that the build compiles into the
  app `.so` without a NIF-init libname (unlike `nif_sources/1`). Fed to the
  build's `-Dplugin_jni_sources` arg.
  """
  @spec jni_sources([plugin()]) :: [String.t()]
  def jni_sources(plugins), do: collect_paths(plugins, [:android, :jni_source])

  @doc """
  Absolute paths of plugin Android `bridge_kt` Kotlin sources. `native_build`
  copies each into the app source tree (at its package-derived path) before
  `gradle assembleDebug`, so the app's Kotlin sourceSet compiles it.
  """
  @spec bridge_kt_sources([plugin()]) :: [String.t()]
  def bridge_kt_sources(plugins), do: collect_paths(plugins, [:android, :bridge_kt])

  @doc """
  Fully-qualified Kotlin class names (e.g. `"io.mob.bluetooth.MobBluetoothBridge"`)
  each activated plugin wants registered at startup. `native_build` generates a
  `MobPluginBootstrap.registerAll/0` that calls `<class>.register()` for each, so
  the plugin's `nativeRegister` thunk can cache its own jclass + method IDs.
  """
  @spec bridge_classes([plugin()]) :: [String.t()]
  def bridge_classes(plugins), do: collect_uniq(plugins, [:android, :bridge_class])

  @doc """
  Absolute paths of each plugin **C-family** NIF's primary source — entries with
  no `:lang`, `lang: :c` (`<module>.c`), or `lang: :objc` (`<module>.m`, compiled
  as Objective-C so iOS plugins can drive Apple frameworks like CoreLocation).

  Convention: for a manifest entry `%{module: :foo_nif, native_dir: "priv/jni"}`
  the source is `<plugin_dir>/priv/jni/foo_nif.c` (or `.m` for `lang: :objc`).
  This is the `<name>.c` pattern the build.zig templates already use for
  project-level NIFs (`c_src/<name>.c`), extended to plugins. Returned paths feed
  the build's `-Dplugin_c_nifs` arg; build.zig derives the NIF name from the
  basename and applies `-DSTATIC_ERLANG_NIF_LIBNAME=<name>` so ERL_NIF_INIT emits
  the static-init symbol the driver table references (and adds `-fobjc-arc` for
  `.m` sources).
  """
  @spec nif_sources([plugin()]) :: [String.t()]
  def nif_sources(plugins), do: nif_sources(plugins, :all)

  @doc """
  Like `nif_sources/1` but restricted to NIFs the given platform compiles.

  A NIF entry with `platform: :ios | :android` is only compiled on that
  platform; an entry with no `:platform` is compiled everywhere. Lets a
  cross-platform plugin ship an iOS C/ObjC NIF and an Android NIF for the same
  module without the iOS source (which may reference iOS-only symbols) ending up
  in the Android build, and vice-versa. `:all` keeps every entry.
  """
  @spec nif_sources([plugin()], :ios | :android | :all) :: [String.t()]
  def nif_sources(plugins, platform) do
    for {dir, manifest} <- with_manifests(plugins),
        nif <- Map.get(manifest, :nifs, []),
        is_map(nif),
        name = nif[:module],
        is_atom(name),
        nif_lang(nif) in [:c, :objc],
        nif_for_platform?(nif, platform) do
      ext = if nif_lang(nif) == :objc, do: "m", else: "c"
      native_dir = nif[:native_dir] || "priv/native/jni"
      Path.join([dir, native_dir, "#{name}.#{ext}"])
    end
  end

  @doc """
  Absolute paths of each plugin **zig** NIF's primary source (NIFs whose
  manifest entry has `lang: :zig`).

  Same `<plugin_dir>/<native_dir>/<module>.zig` convention as the C path, but
  fed to the build's `-Dplugin_zig_nifs` arg and compiled via `addZigObject`.
  Unlike C, no `-DSTATIC_ERLANG_NIF_LIBNAME` is needed — the zig source names
  its own `export fn <module>_nif_init()` directly. The plugin source reaches
  mob-core bindings via the named imports `@import("erts")` / `@import("jni")`
  that build.zig wires for plugin zig objects.
  """
  @spec zig_nif_sources([plugin()]) :: [String.t()]
  def zig_nif_sources(plugins), do: zig_nif_sources(plugins, :all)

  @doc "Like `zig_nif_sources/1` but restricted to the given platform (see `nif_sources/2`)."
  @spec zig_nif_sources([plugin()], :ios | :android | :all) :: [String.t()]
  def zig_nif_sources(plugins, platform), do: nif_sources_for_lang(plugins, :zig, "zig", platform)

  defp nif_sources_for_lang(plugins, lang, ext, platform) do
    for {dir, manifest} <- with_manifests(plugins),
        nif <- Map.get(manifest, :nifs, []),
        is_map(nif),
        name = nif[:module],
        is_atom(name),
        nif_lang(nif) == lang,
        nif_for_platform?(nif, platform) do
      native_dir = nif[:native_dir] || "priv/native/jni"
      Path.join([dir, native_dir, "#{name}.#{ext}"])
    end
  end

  # A NIF manifest entry defaults to C so existing (haptic) plugins are
  # unaffected; `lang: :zig` opts into the zig compile path.
  defp nif_lang(nif), do: nif[:lang] || :c

  # An entry with no `:platform` is compiled on every platform; one tagged
  # `:ios`/`:android` only on that platform. `:all` keeps everything.
  #
  # `lang: :objc` is implicitly Apple-only: Objective-C has no Android runtime,
  # so an objc NIF authored without an explicit `platform: :ios` must still be
  # excluded from the Android build args + driver_tab (otherwise zig tries to
  # compile a `.m` source Android cannot build).
  defp nif_for_platform?(_nif, :all), do: true

  defp nif_for_platform?(nif, platform) do
    if nif_lang(nif) == :objc and platform != :ios do
      false
    else
      nif[:platform] in [nil, platform]
    end
  end

  @doc """
  Cross-compiled C++ static-archive contributions (`lang: :cpp_archive`) across
  plugins, resolved for one platform.

  Unlike `nif_sources/2` (a single source `build.zig` compiles inline), a
  `:cpp_archive` NIF is a set of C++ sources cross-compiled into a `libNAME.a`
  by `MobDev.Plugin.CppArchive` and static-linked into the app — the path for
  heavyweight NIFs like the Nx/Eigen CPU backend (Eigen headers, RTTI/exceptions,
  per-arch CXXFLAGS) that don't fit the single-source model.

  Each returned spec has `:sources` (absolute) and `:includes` resolved: a
  plugin-relative string becomes absolute against the plugin dir, while a
  `{:dep, name, subpath}` token is passed through unchanged for the build to
  resolve against `Mix.Project.deps_path/0` (Eigen/Fine live in the plugin's
  *deps*, not its own tree, and this module stays Mix-free/pure). CXXFLAGS and
  `:nm_symbol` pass through; the entry is tagged with `:plugin`.
  """
  @spec static_archives([plugin()], :ios | :android | :all) :: [map()]
  def static_archives(plugins, platform \\ :all) do
    for {dir, manifest} <- with_manifests(plugins),
        nif <- Map.get(manifest, :nifs, []),
        is_map(nif),
        nif_lang(nif) == :cpp_archive,
        is_atom(nif[:module]),
        nif_for_platform?(nif, platform) do
      %{
        module: nif[:module],
        sources: resolve_paths(dir, List.wrap(nif[:sources])),
        includes: resolve_paths(dir, List.wrap(nif[:includes])),
        cxxflags: List.wrap(nif[:cxxflags]),
        cxxflags_android: List.wrap(nif[:cxxflags_android]),
        cxxflags_ios: List.wrap(nif[:cxxflags_ios]),
        nm_symbol: nif[:nm_symbol],
        platform: nif[:platform],
        plugin: manifest[:name]
      }
    end
  end

  # Resolve a cpp_archive's `:sources`/`:includes` entries. A plugin-relative
  # string resolves to absolute against the plugin dir; a `{:dep, name, subpath}`
  # token passes through (resolved at build time against the deps path — keeps
  # this module pure / Mix-free). The dep form lets a plugin reference sources or
  # headers that live in one of its deps (e.g. nx_eigen's own c_src + Eigen
  # headers) rather than vendoring a copy that can drift.
  defp resolve_paths(dir, entries) do
    for entry <- entries do
      case entry do
        bin when is_binary(bin) -> Path.join(dir, bin)
        {:dep, name, sub} when is_atom(name) and is_binary(sub) -> {:dep, name, sub}
        other -> other
      end
    end
  end

  @doc "Merged iOS `plist_keys` across plugins (later plugins win on conflict)."
  @spec plist_keys([plugin()]) :: map()
  def plist_keys(plugins) do
    for {_dir, manifest} <- with_manifests(plugins),
        keys = get_in(manifest, [:ios, :plist_keys]),
        is_map(keys),
        reduce: %{} do
      acc -> Map.merge(acc, keys)
    end
  end

  @doc "Combined `ui_components` entries across plugins."
  @spec ui_components([plugin()]) :: [map()]
  def ui_components(plugins) do
    for {_dir, manifest} <- with_manifests(plugins),
        c <- Map.get(manifest, :ui_components, []),
        is_map(c),
        do: Map.put(c, :plugin, manifest[:name])
  end

  # ── Tier 3/4: runtime-manifest contributions ──────────────────────────────
  #
  # Unlike the native gatherers above (which feed build args), these feed the
  # host's generated runtime plugin manifest (priv/generated/mob_plugins.exs) —
  # a terms file the on-device `Mob.Plugins` module reads at boot. Each entry is
  # tagged with `:plugin` (the owning plugin name) so the runtime can namespace
  # settings, order notification handlers, and attribute screens. Everything
  # here must be serializable terms (atoms / tuples / maps / strings) — no
  # closures (the manifest validator enforces that for notification matches).

  @doc """
  Static screen declarations across plugins, each tagged with `:plugin`.

  Generator-produced screens (spec-v2 `:screens_generator`) are folded in
  separately by the runtime-manifest codegen; this is the static `:screens` half.
  """
  @spec screens([plugin()]) :: [map()]
  def screens(plugins) do
    for {_dir, manifest} <- with_manifests(plugins),
        s <- Map.get(manifest, :screens, []),
        is_map(s),
        do: Map.put(s, :plugin, manifest[:name])
  end

  @doc """
  Migration declarations across plugins, with `:migrations_dir` resolved to an
  absolute path and tagged with `:plugin` + `:repo_namespace`.
  """
  @spec migrations([plugin()]) :: [map()]
  def migrations(plugins) do
    for {dir, manifest} <- with_manifests(plugins),
        m = Map.get(manifest, :migrations),
        is_map(m),
        is_binary(m[:migrations_dir]) do
      %{
        plugin: manifest[:name],
        repo_namespace: m[:repo_namespace],
        migrations_dir: Path.join(dir, m[:migrations_dir])
      }
    end
  end

  @doc """
  Asset declarations across plugins, with font/image paths resolved to absolute
  and tagged with `:plugin` (used by the `plugin://<name>/<file>` image resolver
  and the native font-bundling merge).
  """
  @spec assets([plugin()]) :: [map()]
  def assets(plugins) do
    for {dir, manifest} <- with_manifests(plugins),
        a = Map.get(manifest, :assets),
        is_map(a) do
      %{
        plugin: manifest[:name],
        fonts: abs_paths(dir, a[:fonts]),
        images: abs_paths(dir, a[:images])
      }
    end
  end

  @doc "Lifecycle declarations across plugins, each tagged with `:plugin`."
  @spec lifecycle([plugin()]) :: [map()]
  def lifecycle(plugins) do
    for {_dir, manifest} <- with_manifests(plugins),
        lc = Map.get(manifest, :lifecycle),
        is_map(lc),
        do: Map.put(lc, :plugin, manifest[:name])
  end

  @doc "Settings declarations across plugins, each tagged with `:plugin`."
  @spec settings([plugin()]) :: [map()]
  def settings(plugins) do
    for {_dir, manifest} <- with_manifests(plugins),
        s = Map.get(manifest, :settings),
        is_map(s),
        do: Map.put(s, :plugin, manifest[:name])
  end

  @doc """
  Notification handlers across all plugins, flattened in plugin-then-declaration
  order (first match wins at dispatch), each tagged with `:plugin`.
  """
  @spec notification_handlers([plugin()]) :: [map()]
  def notification_handlers(plugins) do
    for {_dir, manifest} <- with_manifests(plugins),
        notes = Map.get(manifest, :notifications),
        is_map(notes),
        h <- Map.get(notes, :handlers, []),
        is_map(h),
        do: Map.put(h, :plugin, manifest[:name])
  end

  @doc """
  Host-app obligations the plugin system can't automate (e.g. AndroidManifest
  fragments — a typed foreground `<service>`, a `FileProvider`), tagged with
  `:plugin`. The native build prints these so a host author can't activate a
  plugin and only discover the missing manual step at first feature use.
  """
  @spec host_requirements([plugin()]) :: [%{plugin: atom(), requirement: String.t()}]
  def host_requirements(plugins) do
    for {_dir, manifest} <- with_manifests(plugins),
        req <- List.wrap(Map.get(manifest, :host_requirements)),
        is_binary(req),
        do: %{plugin: manifest[:name], requirement: req}
  end

  defp abs_paths(dir, paths) when is_list(paths),
    do: for(p <- paths, is_binary(p), do: Path.join(dir, p))

  # A malformed (non-list) :fonts/:images declaration contributes no paths
  # rather than crashing the merge — the manifest validator is the place that
  # reports the shape error, but `activated/0` feeds Merge unvalidated maps.
  defp abs_paths(_dir, _paths), do: []

  # ── helpers ─────────────────────────────────────────────────────────────

  defp with_manifests(plugins) do
    for {dir, manifest} <- plugins, is_map(manifest), do: {dir, manifest}
  end

  defp collect_uniq(plugins, path) do
    for {_dir, manifest} <- with_manifests(plugins),
        value <- List.wrap(get_in(manifest, path)),
        is_binary(value),
        uniq: true,
        do: value
  end

  defp collect_paths(plugins, path) do
    for {dir, manifest} <- with_manifests(plugins),
        rel <- List.wrap(get_in(manifest, path)),
        is_binary(rel),
        do: Path.join(dir, rel)
  end
end
