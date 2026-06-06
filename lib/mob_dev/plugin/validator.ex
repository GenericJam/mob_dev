defmodule MobDev.Plugin.Validator do
  @moduledoc """
  Validates plugin manifests, in two stages (see `MOB_PLUGINS.md`).

  **Single-plugin** (`validate_plugin/3`, behind `mix mob.validate_plugin`): a
  plugin author's pre-publish check — required fields, referenced files exist,
  `mob_version` satisfied by the installed mob, plus advisory warnings.

  **Cross-plugin** (`cross_validate/1`, run by mob_dev when activating): the
  collision checks that only make sense across the *set* of activated plugins —
  no two may claim the same component atom, screen route, or migration namespace.

  Every result is `%{errors: [...], warnings: [...]}`. Errors fail loud;
  warnings are advisory. Both stages are pure given their inputs (the only I/O
  is `File.exists?/1` for path checks, isolated in `validate_plugin/3`).
  """

  alias MobDev.Plugin.Manifest

  @type result :: %{errors: [String.t()], warnings: [String.t()]}

  @doc """
  Collects the file paths a manifest references, relative to the plugin root.

  Pure. Covers the concrete file declarations (`nifs.native_dir`,
  `android.bridge_kt`, `android.jni_source`, `ios.swift_files`). Component
  `view_module`/`composable` are type/function names, not paths, so they are
  not included here.
  """
  @spec referenced_paths(map() | nil) :: [String.t()]
  def referenced_paths(nil), do: []

  def referenced_paths(manifest) when is_map(manifest) do
    nif_dirs = for n <- Map.get(manifest, :nifs, []), is_map(n), do: n[:native_dir]
    android = Map.get(manifest, :android, %{})
    ios = Map.get(manifest, :ios, %{})

    [
      nif_dirs,
      [android[:bridge_kt], android[:jni_source]],
      List.wrap(ios[:swift_files])
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Single-plugin validation, run from the plugin's own project directory.

  `installed_mob_version` is the version of `:mob` resolved in the plugin's
  deps (a string), or `nil` to skip the compatibility check.
  """
  @spec validate_plugin(map() | nil, Path.t(), String.t() | nil) :: result()
  def validate_plugin(manifest, plugin_dir, installed_mob_version \\ nil) do
    %{errors: structural_errors(manifest), warnings: []}
    |> add_path_errors(manifest, plugin_dir)
    |> add_mob_version_error(manifest, installed_mob_version)
    |> add_nif_module_errors(manifest)
    |> add_swift_struct_errors(manifest)
    |> add_swift_import_errors(manifest, plugin_dir)
    |> add_android_permission_errors(manifest, plugin_dir)
    |> add_warnings(manifest)
  end

  # iOS frameworks the host always links — a plugin doesn't have to redeclare
  # these in its `ios.frameworks`. Mirrors the `frameworks_base` array in
  # mob_new's iOS build.zig.eex (UIKit/Foundation/CoreGraphics/QuartzCore/SwiftUI).
  # Accelerate is added when MLX is active, but plugin manifests don't know
  # about the host's MLX configuration, so we treat it as always-allowed at
  # validate time (an undeclared import will still surface in the host's link
  # step when MLX isn't on — the failure mode the validator can't pre-empt).
  @ios_base_frameworks ~w(UIKit Foundation CoreGraphics QuartzCore SwiftUI Accelerate)

  @doc """
  Verifies every `import X` in the plugin's Swift sources resolves to either
  a base iOS framework or one declared in `manifest.ios.frameworks`.

  See `MOB_PLUGIN_SECURITY.md` (Layer 2 — capability enforcement at compile
  time): the manifest is the contract; the plugin's source cannot reach for a
  framework that isn't manifest-declared. Catches drift at validate time
  rather than at link time, where the error points at the linker invocation
  and not at the manifest that produced it.

  Returns a list of error strings (empty when the manifest passes). Skips
  plugins with no `ios.swift_files`. Files referenced by the manifest but
  missing on disk are flagged by `add_path_errors/3`, not here — this check
  only opens files that exist.
  """
  @spec validate_swift_imports(map() | nil, Path.t()) :: [String.t()]
  def validate_swift_imports(nil, _plugin_dir), do: []

  def validate_swift_imports(manifest, plugin_dir) when is_map(manifest) do
    declared = MapSet.new(@ios_base_frameworks ++ declared_ios_frameworks(manifest))

    for rel <- declared_swift_files(manifest),
        abs = Path.join(plugin_dir, rel),
        File.exists?(abs),
        framework <- imported_frameworks(abs),
        not MapSet.member?(declared, framework) do
      ~s(iOS framework "#{framework}" imported by #{rel} but not declared in ) <>
        "manifest.ios.frameworks — add it to the manifest"
    end
  end

  @doc """
  Activation-time capability check across every activated plugin.

  `plugins` is the `MobDev.Plugin.activated/0` shape — a list of
  `{plugin_dir, manifest}` pairs. For each plugin, runs
  `validate_swift_imports/2` and `validate_android_permissions/2` and
  returns the flattened error list, each entry prefixed with the
  plugin's `:name` so the user can tell which plugin tripped.

  Empty list means every activated plugin's source matches its manifest's
  declared capability surface. The build hooks this into iOS + Android
  builds via `raise_on_capability_drift!/1`, which raises a `Mix.raise/1`
  with the full list when any drift is found.
  """
  @spec activated_capability_errors([{Path.t(), map() | nil}]) :: [String.t()]
  def activated_capability_errors(plugins) do
    for {dir, manifest} <- plugins,
        is_map(manifest),
        err <-
          validate_swift_imports(manifest, dir) ++ validate_android_permissions(manifest, dir) do
      prefix_with_plugin_name(manifest, err)
    end
  end

  @doc """
  Runs `activated_capability_errors/1` and raises a `Mix.raise/1` (with a
  user-readable bullet list) when any plugin's source references a
  capability not in its manifest. No-op when every plugin is clean.

  Lives in the validator (not NativeBuild) so the iOS-sim and iOS-device
  build paths can both call it as a one-liner, and so it stays unit-testable.

  Also runs the Phase 2 signature gate
  (`MobDev.Plugin.SignatureGate.raise_on_signature_drift!/1`) at the top
  — fails fast on a tampered or untrusted plugin before any capability
  analysis runs. The unsigned-plugin banner is printed afterwards so it
  surfaces on every successful invocation.
  """
  @spec raise_on_capability_drift!([{Path.t(), map() | nil}]) :: :ok
  def raise_on_capability_drift!(plugins) do
    MobDev.Plugin.SignatureGate.raise_on_signature_drift!(plugins)
    MobDev.Plugin.SignatureGate.maybe_print_unsafe_banner(plugins)

    case activated_capability_errors(plugins) do
      [] ->
        :ok

      errors ->
        bullets = Enum.map_join(errors, "\n", &"  - #{&1}")

        Mix.raise(
          "plugin capability check failed — undeclared framework or permission " <>
            "in an activated plugin (see MOB_PLUGIN_SECURITY.md, Layer 2):\n" <> bullets
        )
    end
  end

  defp prefix_with_plugin_name(manifest, err) do
    case manifest[:name] do
      name when is_atom(name) and not is_nil(name) -> "[#{name}] #{err}"
      _ -> err
    end
  end

  @doc """
  Verifies every `<uses-permission android:name="X"/>` declared in
  AndroidManifest.xml fragments under the plugin's tree appears in
  `manifest.android.permissions`.

  Scope (deliberate): scans `priv/native/android/**/*.xml` for
  `<uses-permission/>` entries — declarations the plugin author explicitly
  wrote. Does not attempt to infer permissions from Kotlin/Java API usage
  (the static-analysis rabbit hole `MOB_PLUGIN_SECURITY.md` warns against).
  Returns `[]` when the plugin ships no AndroidManifest fragment.
  """
  @spec validate_android_permissions(map() | nil, Path.t()) :: [String.t()]
  def validate_android_permissions(nil, _plugin_dir), do: []

  def validate_android_permissions(manifest, plugin_dir) when is_map(manifest) do
    declared = MapSet.new(declared_android_permissions(manifest))

    for {rel, found} <- android_manifest_permissions(plugin_dir),
        permission <- found,
        not MapSet.member?(declared, permission) do
      ~s(Android permission "#{permission}" referenced in #{rel} but not declared in ) <>
        "manifest.android.permissions — add it to the manifest"
    end
  end

  @doc """
  Cross-plugin collision validation across the activated set.

  `plugins` is a list of `{name, manifest}` for the activated plugins (tier-0
  no-manifest plugins, i.e. `manifest == nil`, contribute nothing and are
  ignored).
  """
  @spec cross_validate([{atom(), map() | nil}]) :: result()
  def cross_validate(plugins) do
    manifests = for {_name, m} <- plugins, is_map(m), do: m

    errors =
      collisions(manifests, &component_atoms/1, "component atom (ui_components.atom)") ++
        collisions(
          manifests,
          &component_view_modules/1,
          "iOS native view key (ui_components.ios.view_module)"
        ) ++
        collisions(
          manifests,
          &component_composables/1,
          "Android native view key (ui_components.android.composable)"
        ) ++
        collisions(manifests, &screen_routes/1, "screen route (screens.default_route)") ++
        collisions(manifests, &repo_namespaces/1, "migration repo_namespace")

    %{errors: errors, warnings: []}
  end

  # ── single-plugin checks ──────────────────────────────────────────────────

  defp structural_errors(manifest) do
    case Manifest.validate(manifest) do
      {:ok, _} -> []
      {:error, errs} -> errs
    end
  end

  defp add_path_errors(result, manifest, plugin_dir) do
    missing =
      manifest
      |> referenced_paths()
      |> Enum.reject(&File.exists?(Path.join(plugin_dir, &1)))
      |> Enum.map(&"declared path does not exist: #{&1}")

    %{result | errors: result.errors ++ missing}
  end

  defp add_mob_version_error(result, %{mob_version: req}, installed)
       when is_binary(req) and is_binary(installed) do
    case Version.parse_requirement(req) do
      {:ok, _} ->
        if Version.match?(installed, req) do
          result
        else
          err = "installed :mob #{installed} does not satisfy mob_version #{inspect(req)}"
          %{result | errors: result.errors ++ [err]}
        end

      :error ->
        # The bad-requirement string is already reported by structural validation.
        result
    end
  end

  defp add_mob_version_error(result, _manifest, _installed), do: result

  # `nif :module` is the Erlang module name used by ERL_NIF_INIT both as the
  # registered module atom and as the prefix of the static-init symbol
  # (`<module>_nif_init`). It must therefore be a valid C token shape — a
  # lowercase ASCII atom — not an Elixir module alias. Catch this at validate
  # time rather than at link time. See MOB_PLUGINS.md (nifs section).
  @nif_module_pattern ~r/^[a-z][a-z0-9_]*$/

  # Core/runtime NIF module names baked into the static driver table by
  # `MobDev.StaticNifs.default_nifs/0`. A plugin must not reuse one: the
  # driver-tab generator de-duplicates by `:module` keeping the *last* entry
  # (`StaticNifs.resolve/1`), so a plugin declaring e.g. `:crypto` silently
  # overrides the core builtin row — dropping its `builtin: true` flag and
  # repointing the `<module>_nif_init` symbol at the plugin's source. That
  # breaks the core NIF at runtime/link time, far from the manifest that
  # caused it. Catch the collision at validate time instead.
  @reserved_nif_modules MapSet.new(MobDev.StaticNifs.default_nifs(), & &1.module)

  defp add_nif_module_errors(result, manifest) when is_map(manifest) do
    errs =
      for n <- Map.get(manifest, :nifs, []),
          is_map(n),
          Map.has_key?(n, :module),
          err = nif_module_error(n[:module]),
          do: err

    %{result | errors: result.errors ++ errs}
  end

  defp add_nif_module_errors(result, _manifest), do: result

  defp nif_module_error(mod) when is_atom(mod) and not is_nil(mod) do
    cond do
      not Regex.match?(@nif_module_pattern, Atom.to_string(mod)) ->
        bad_nif_module_message(mod)

      MapSet.member?(@reserved_nif_modules, mod) ->
        reserved_nif_module_message(mod)

      true ->
        nil
    end
  end

  defp nif_module_error(other), do: bad_nif_module_message(other)

  defp reserved_nif_module_message(mod) do
    "nifs :module #{inspect(mod)} collides with a core/runtime NIF baked into " <>
      "the static driver table — it would silently override the core entry " <>
      "(dropping its builtin flag and repointing #{mod}_nif_init). Choose a " <>
      "plugin-specific name (e.g. :my_plugin_nif)"
  end

  defp bad_nif_module_message(value) do
    "nifs :module #{inspect(value)} must be a C-token atom matching " <>
      "/^[a-z][a-z0-9_]*$/ (e.g. :mob_bluetooth_nif), not an Elixir module — " <>
      "ERL_NIF_INIT uses it as the static-init symbol prefix"
  end

  # ui_components.ios.swift_struct names the SwiftUI struct the iOS bootstrap
  # codegen instantiates (`StructName(props: props)`). It must therefore be a
  # valid Swift identifier — the codegen pastes it straight into source.
  # Catch a bad value at validate time rather than at swiftc time, where the
  # error is far from the manifest that produced it.
  @swift_identifier_pattern ~r/^[A-Za-z_][A-Za-z0-9_]*$/

  defp add_swift_struct_errors(result, manifest) when is_map(manifest) do
    errs =
      for c <- Map.get(manifest, :ui_components, []),
          is_map(c),
          ios = c[:ios],
          is_map(ios),
          Map.has_key?(ios, :swift_struct),
          err = swift_struct_error(ios[:swift_struct]),
          do: err

    %{result | errors: result.errors ++ errs}
  end

  defp add_swift_struct_errors(result, _manifest), do: result

  defp swift_struct_error(value) when is_binary(value) do
    if Regex.match?(@swift_identifier_pattern, value),
      do: nil,
      else: bad_swift_struct_message(value)
  end

  defp swift_struct_error(other), do: bad_swift_struct_message(other)

  defp bad_swift_struct_message(value) do
    "ui_components.ios.swift_struct #{inspect(value)} must be a Swift " <>
      "identifier matching /^[A-Za-z_][A-Za-z0-9_]*$/ (e.g. \"MobSignaturePadView\") — " <>
      "the iOS bootstrap codegen instantiates it as `<StructName>(props: props)`"
  end

  defp add_swift_import_errors(result, manifest, plugin_dir) do
    %{result | errors: result.errors ++ validate_swift_imports(manifest, plugin_dir)}
  end

  defp add_android_permission_errors(result, manifest, plugin_dir) do
    %{result | errors: result.errors ++ validate_android_permissions(manifest, plugin_dir)}
  end

  defp declared_ios_frameworks(manifest) do
    for fw <- List.wrap(get_in(manifest, [:ios, :frameworks])), is_binary(fw), do: fw
  end

  defp declared_swift_files(manifest) do
    for f <- List.wrap(get_in(manifest, [:ios, :swift_files])), is_binary(f), do: f
  end

  defp declared_android_permissions(manifest) do
    for p <- List.wrap(get_in(manifest, [:android, :permissions])), is_binary(p), do: p
  end

  # Matches `import Foundation`, `import SwiftUI`, `@testable import CoreLocation`
  # — Swift's basic module-import forms — and captures the module name. The
  # `[A-Z][A-Za-z0-9_]*` shape matches an iOS framework / Swift module name,
  # which always begins with an uppercase letter. Submodule imports like
  # `import struct Foundation.URL` capture `Foundation`, which is the
  # framework-level granularity the manifest tracks.
  @swift_import_pattern ~r/^[\t ]*(?:@testable[\t ]+)?import(?:[\t ]+(?:struct|class|enum|protocol|func|var|let|typealias))?[\t ]+([A-Z][A-Za-z0-9_]*)/m

  defp imported_frameworks(path) do
    case File.read(path) do
      {:ok, content} ->
        @swift_import_pattern
        |> Regex.scan(content, capture: :all_but_first)
        |> Enum.map(fn [m] -> m end)
        |> Enum.uniq()

      _ ->
        []
    end
  end

  # Matches `<uses-permission android:name="X"/>` (and its `</uses-permission>`
  # form) and captures the permission string. Tolerates whitespace and arbitrary
  # extra attributes on the element.
  @android_uses_permission_pattern ~r/<uses-permission\b[^>]*android:name\s*=\s*"([^"]+)"/

  # Scans `priv/native/android/**/*.xml` (plus a few historical paths) for
  # AndroidManifest fragments contributed by the plugin and returns a list of
  # `{rel_path, [permission_string]}` tuples — empty when the plugin ships no
  # such fragment.
  defp android_manifest_permissions(plugin_dir) do
    candidates =
      Path.wildcard(Path.join(plugin_dir, "priv/native/android/**/*.xml")) ++
        Path.wildcard(Path.join(plugin_dir, "priv/android/**/*.xml")) ++
        Path.wildcard(Path.join(plugin_dir, "android/**/AndroidManifest.xml"))

    for path <- Enum.uniq(candidates),
        File.regular?(path),
        perms = scan_android_permissions(path),
        perms != [] do
      {Path.relative_to(path, plugin_dir), perms}
    end
  end

  defp scan_android_permissions(path) do
    case File.read(path) do
      {:ok, content} ->
        @android_uses_permission_pattern
        |> Regex.scan(content, capture: :all_but_first)
        |> Enum.map(fn [p] -> p end)
        |> Enum.uniq()

      _ ->
        []
    end
  end

  defp add_warnings(result, manifest) do
    %{result | warnings: result.warnings ++ warnings(manifest)}
  end

  defp warnings(nil), do: []

  defp warnings(manifest) do
    single_platform_components(manifest) ++
      permission_review(manifest) ++
      plist_review(manifest)
  end

  defp single_platform_components(manifest) do
    for c <- Map.get(manifest, :ui_components, []),
        is_map(c),
        xor?(Map.has_key?(c, :ios), Map.has_key?(c, :android)) do
      "ui_components #{inspect(c[:atom] || c[:tag])} declares only one platform — " <>
        "the other platform will silently render nothing"
    end
  end

  defp permission_review(manifest) do
    case get_in(manifest, [:android, :permissions]) do
      [_ | _] = perms ->
        [
          "declares Android permissions #{inspect(perms)} — review before publishing (opt-in via activation)"
        ]

      _ ->
        []
    end
  end

  defp plist_review(manifest) do
    case get_in(manifest, [:ios, :plist_keys]) do
      m when is_map(m) and map_size(m) > 0 ->
        ["declares iOS plist_keys #{inspect(Map.keys(m))} — review before publishing"]

      _ ->
        []
    end
  end

  defp xor?(a, b), do: a != b

  # ── cross-plugin collision detection ──────────────────────────────────────

  defp collisions(manifests, extractor, label) do
    manifests
    |> Enum.flat_map(extractor)
    |> Enum.frequencies()
    |> Enum.filter(fn {_value, count} -> count > 1 end)
    |> Enum.map(fn {value, count} ->
      "#{count} activated plugins declare the same #{label}: #{inspect(value)}"
    end)
  end

  defp component_atoms(manifest) do
    for c <- Map.get(manifest, :ui_components, []), is_map(c), c[:atom], do: c[:atom]
  end

  # Two plugins resolving to the same native view-registry key would silently
  # shadow each other (last-write-wins) at build time, so flag the collision.
  defp component_view_modules(manifest) do
    for c <- Map.get(manifest, :ui_components, []),
        is_map(c),
        ios = c[:ios],
        is_map(ios),
        is_binary(ios[:view_module]),
        do: ios[:view_module]
  end

  defp component_composables(manifest) do
    for c <- Map.get(manifest, :ui_components, []),
        is_map(c),
        android = c[:android],
        is_map(android),
        is_binary(android[:composable]),
        do: android[:composable]
  end

  defp screen_routes(manifest) do
    for s <- Map.get(manifest, :screens, []), is_map(s), s[:default_route], do: s[:default_route]
  end

  defp repo_namespaces(manifest) do
    case get_in(manifest, [:migrations, :repo_namespace]) do
      nil -> []
      ns -> [ns]
    end
  end
end
