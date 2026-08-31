defmodule MobDev.Plugin.AndroidBootstrap do
  @moduledoc """
  Code-generates the Android `ui_components` registrations spliced into the
  generated `io.mob.plugin.MobPluginBootstrap` — the Android analog of
  `MobDev.Plugin.IOSBootstrap`.

  Before this module existed the manifest's `ui_components.android` entry was
  data nobody consumed: every host had to hand-register the plugin's Compose
  factory in `MainActivity.onCreate`, and a host that forgot rendered the
  component as *nothing* — `MobNativeViewRegistry.render` returns silently on
  an unknown key (mob_scene3d-q03, the chopaat repro). Now
  `MobPluginBootstrap.registerAll(this)` — which every generated/adopted
  MainActivity already calls before `setContent` — also registers the
  activated plugins' composables, so a declared component either works or
  fails loudly:

    * **Resolvable entries are auto-registered.** The registry key comes from
      `ui_components.android.view_module`, falling back to
      `ui_components.ios.view_module` (both platforms share the key — it is
      the Elixir module name with dots → underscores, what the BEAM sends as
      the node's `module` prop). The Compose factory is
      `ui_components.android.composable`: used as-is when fully qualified
      (contains a `.`), otherwise qualified with the package of
      `android.bridge_class` (the composable ships in the plugin's
      `bridge_kt`, which declares that package). A typo'd composable fails
      the Gradle Kotlin compile — loud, at build time.

    * **Unresolvable-but-declared entries get a loud placeholder.** A bare
      `composable` with no `bridge_class` to derive a package from (the
      hand-copied tier-2 workflow, where the host pastes the factory into its
      own source) registers a placeholder that renders a red
      "Missing native component" tile and logs an error. A host that follows
      the documented workflow — registering the real factory in
      `MainActivity.onCreate` *after* `registerAll(this)` — overwrites the
      placeholder; a host that forgot sees the tile instead of silence.

    * **Malformed entries fail the build.** An android-backed component with
      no resolvable registry key (or no `composable` at all) is returned in
      `:errors`; `MobDev.NativeBuild` raises with the message. The manifest is
      the bug, so build time — next to the manifest — is where it surfaces.

  `MobNativeViewRegistry` lives in the *app* package (MobBridge.kt), which
  `io.mob.plugin` code cannot import by name at authoring time — the reason a
  plugin bridge's own `register()` can't do this. Codegen can: the caller
  passes the discovered app package and every reference is emitted fully
  qualified.

  Pure, no I/O: `classify/1` takes the activated-plugin list
  (`[{plugin_dir, manifest}]`, the `MobDev.Plugin.activated/0` shape) and
  `ui_source/2` renders the Kotlin. Output order is activation order, then
  declaration order within a manifest — stable output keeps builds
  reproducible.
  """

  alias MobDev.Plugin.Merge

  @type classified :: %{
          registrations: [%{key: String.t(), composable: String.t(), plugin: atom()}],
          placeholders: [%{key: String.t(), plugin: atom()}],
          errors: [String.t()]
        }

  @doc """
  Buckets the activated plugins' android-backed `ui_components` into
  auto-registrations, loud placeholders, and build errors (see moduledoc).

  Components without an `:android` map (iOS-only) contribute nothing here —
  the validator's single-platform warning is what nags about those.
  """
  @spec classify([Merge.plugin()]) :: classified()
  def classify(plugins) do
    buckets =
      for {_dir, manifest} <- plugins,
          is_map(manifest),
          component <- Map.get(manifest, :ui_components, []),
          is_map(component),
          android = component[:android],
          is_map(android) do
        classify_component(component, android, manifest)
      end

    %{
      registrations: for({:registration, r} <- buckets, do: r),
      placeholders: for({:placeholder, p} <- buckets, do: p),
      errors: for({:error, e} <- buckets, do: e)
    }
  end

  defp classify_component(component, android, manifest) do
    plugin = manifest[:name]
    key = registry_key(component)
    composable = android[:composable]
    bridge_pkg = bridge_package(manifest)

    cond do
      not is_binary(key) ->
        {:error,
         "plugin #{inspect(plugin)}: ui_components #{component_label(component)} declares " <>
           ":android backing but no registry key — add android.view_module (or " <>
           "ios.view_module; both default to the Elixir module name with dots → " <>
           "underscores, e.g. \"Mob_Scene3d_Viewport\") so the generated " <>
           "MobPluginBootstrap can register the composable"}

      not is_binary(composable) ->
        {:error,
         "plugin #{inspect(plugin)}: ui_components #{component_label(component)} declares " <>
           ":android backing but no :composable — name the @Composable factory " <>
           "(fully qualified, or bare when the plugin ships a bridge_class in the " <>
           "same package) so the generated MobPluginBootstrap can register it"}

      String.contains?(composable, ".") ->
        {:registration, %{key: key, composable: composable, plugin: plugin}}

      is_binary(bridge_pkg) ->
        {:registration, %{key: key, composable: "#{bridge_pkg}.#{composable}", plugin: plugin}}

      true ->
        {:placeholder, %{key: key, plugin: plugin}}
    end
  end

  # Registry key both platforms share; android.view_module wins so an
  # Android-only plugin needs no :ios map.
  defp registry_key(component) do
    case get_in(component, [:android, :view_module]) do
      key when is_binary(key) -> key
      _ -> get_in(component, [:ios, :view_module])
    end
  end

  defp component_label(component) do
    inspect(component[:atom] || component[:tag] || component)
  end

  # Package of android.bridge_class ("io.mob.scene3d.MobScene3dBridge" →
  # "io.mob.scene3d") — where a bare :composable lives, since it ships in the
  # plugin's bridge_kt (which declares that package). A dotless bridge_class
  # (default package) yields nil: nothing to qualify with.
  defp bridge_package(manifest) do
    with cls when is_binary(cls) <- get_in(manifest, [:android, :bridge_class]),
         parts when parts != [] <- cls |> String.split(".") |> Enum.drop(-1) do
      Enum.join(parts, ".")
    else
      _ -> nil
    end
  end

  @doc """
  Kotlin for the ui_components half of `MobPluginBootstrap`, or `nil` when
  there is nothing to register (so plugin-less and UI-less builds emit a
  byte-identical bootstrap to before this feature).

  Returns `%{call:, body:}` — `call` is the statement `registerAll` runs,
  `body` the member functions spliced into the object. `app_package` is the
  host app's Kotlin package (where MobBridge.kt defines
  `MobNativeViewRegistry`); every registry reference is emitted fully
  qualified against it.
  """
  @spec ui_source(classified(), String.t()) :: %{call: String.t(), body: String.t()} | nil
  def ui_source(classified, app_package) do
    lines =
      Enum.map(classified.registrations, &registration_kotlin(&1, app_package)) ++
        Enum.map(classified.placeholders, &placeholder_kotlin(&1, app_package))

    if lines == [] do
      nil
    else
      %{call: "registerUiComponents()", body: ui_body(lines, classified.placeholders)}
    end
  end

  # Unused lambda params are `_` — Kotlin warns on named-but-unused ones.
  defp registration_kotlin(%{key: key, composable: composable, plugin: plugin}, app_package) do
    """
            // #{plugin}: #{key}
            #{app_package}.MobNativeViewRegistry.register(\"#{key}\") { props, _ ->
                #{composable}(props)
            }
    """
    |> String.trim_trailing()
  end

  defp placeholder_kotlin(%{key: key, plugin: plugin}, app_package) do
    """
            // #{plugin}: #{key} — composable not resolvable from the manifest
            // (bare :composable, no bridge_class package to qualify it with).
            // The host's own MainActivity registration (after registerAll)
            // overwrites this loud placeholder.
            #{app_package}.MobNativeViewRegistry.register(\"#{key}\") { _, _ ->
                MissingUiComponent(\"#{key}\", \"#{plugin}\")
            }
    """
    |> String.trim_trailing()
  end

  defp ui_body(lines, placeholders) do
    register_fun =
      "\n\n    // Registers the activated plugins' ui_components Compose factories\n" <>
        "    // with the app's MobNativeViewRegistry (generated from each plugin\n" <>
        "    // manifest — the Android analog of iOS's mob_register_plugins()).\n" <>
        "    private fun registerUiComponents() {\n" <>
        Enum.join(lines, "\n") <>
        "\n    }"

    register_fun <> if placeholders == [], do: "", else: missing_component_kotlin()
  end

  # The loud placeholder: visible red tile + error log instead of the silent
  # nothing MobNativeViewRegistry.render produces for an unknown key.
  defp missing_component_kotlin do
    """


        // Loud placeholder for a declared ui_component whose Compose factory
        // codegen could not resolve. Renders red and logs instead of nothing.
        @androidx.compose.runtime.Composable
        private fun MissingUiComponent(key: String, plugin: String) {
            android.util.Log.e(
                "MobPluginBootstrap",
                "ui_component \\"$key\\" (plugin $plugin) mounted with no registered Compose " +
                    "factory — register it in MainActivity.onCreate after " +
                    "MobPluginBootstrap.registerAll(this), or declare a fully-qualified " +
                    "android.composable (or an android.bridge_class in the composable's " +
                    "package) in the plugin manifest."
            )
            androidx.compose.material3.Text(
                text = "Missing native component: $key ($plugin)",
                color = androidx.compose.ui.graphics.Color.Red
            )
        }
    """
    |> String.trim_trailing("\n")
  end
end
