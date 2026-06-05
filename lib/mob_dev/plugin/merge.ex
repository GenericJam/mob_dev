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
  Absolute paths of each plugin **C** NIF's primary source (NIFs whose
  manifest entry has no `:lang` or `lang: :c`).

  Convention: for a manifest entry `%{module: :foo_nif, native_dir: "priv/jni"}`
  the source is `<plugin_dir>/priv/jni/foo_nif.c`. This is the `<name>.c`
  pattern the build.zig templates already use for project-level NIFs
  (`c_src/<name>.c`), extended to plugins. Returned paths feed the build's
  `-Dplugin_c_nifs` arg; build.zig derives the NIF name from the basename
  and applies `-DSTATIC_ERLANG_NIF_LIBNAME=<name>` so ERL_NIF_INIT emits the
  static-init symbol the driver table references.
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
  def nif_sources(plugins, platform), do: nif_sources_for_lang(plugins, :c, "c", platform)

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
  defp nif_for_platform?(_nif, :all), do: true
  defp nif_for_platform?(nif, platform), do: nif[:platform] in [nil, platform]

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
        do: c
  end

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
