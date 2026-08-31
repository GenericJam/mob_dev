defmodule MobDev.Plugin.AndroidBootstrap do
  @moduledoc """
  Generates opt-in Android `ui_components` registrations for
  `io.mob.plugin.MobPluginBootstrap`.

  `ui_components.android.composable` remains the native-view registry key used
  by existing plugins. A plugin opts into generated registration by declaring
  a separate `ui_components.android.factory` Kotlin function. Generated
  factories receive both the component props and native event sender.

  A bare factory name is qualified with the package of
  `android.bridge_class`; a fully-qualified factory works without a bridge.
  Plugins that do not declare `factory` keep their existing bridge- or
  host-owned registration unchanged.
  """

  alias MobDev.Plugin.Merge

  @type classified :: %{
          registrations: [%{key: String.t(), factory: String.t(), plugin: atom()}],
          errors: [String.t()]
        }

  @doc """
  Classifies explicitly auto-registered Android components.

  Components without `android.factory` contribute nothing. Output order is
  activation order followed by declaration order within each manifest.
  """
  @spec classify([Merge.plugin()]) :: classified()
  def classify(plugins) do
    buckets =
      for {_dir, manifest} <- plugins,
          is_map(manifest),
          component <- Map.get(manifest, :ui_components, []),
          is_map(component),
          android = component[:android],
          is_map(android),
          Map.has_key?(android, :factory) do
        classify_component(component, android, manifest)
      end

    %{
      registrations: for({:registration, registration} <- buckets, do: registration),
      errors: for({:error, error} <- buckets, do: error)
    }
  end

  defp classify_component(component, android, manifest) do
    plugin = manifest[:name]
    key = registry_key(component)
    factory = android[:factory]
    bridge_pkg = bridge_package(manifest)

    cond do
      not is_binary(factory) ->
        {:error,
         "plugin #{inspect(plugin)}: ui_components #{component_label(component)} declares " <>
           "android.factory #{inspect(factory)}; expected a Kotlin identifier or dotted path"}

      not is_binary(key) ->
        {:error,
         "plugin #{inspect(plugin)}: ui_components #{component_label(component)} declares " <>
           "android.factory #{inspect(factory)} but no registry key — add " <>
           "android.view_module, android.composable, or ios.view_module"}

      String.contains?(factory, ".") ->
        {:registration, %{key: key, factory: factory, plugin: plugin}}

      is_binary(bridge_pkg) ->
        {:registration, %{key: key, factory: "#{bridge_pkg}.#{factory}", plugin: plugin}}

      true ->
        {:error,
         "plugin #{inspect(plugin)}: android.factory #{inspect(factory)} for " <>
           "ui_components #{component_label(component)} must be fully qualified when the " <>
           "plugin has no android.bridge_class"}
    end
  end

  defp registry_key(component) do
    android = component[:android]

    cond do
      is_binary(android[:composable]) -> android[:composable]
      is_binary(android[:view_module]) -> android[:view_module]
      true -> get_in(component, [:ios, :view_module])
    end
  end

  defp component_label(component), do: inspect(component[:atom] || component[:tag] || component)

  defp bridge_package(manifest) do
    with cls when is_binary(cls) <- get_in(manifest, [:android, :bridge_class]),
         parts when parts != [] <- cls |> String.split(".") |> Enum.drop(-1) do
      Enum.join(parts, ".")
    else
      _ -> nil
    end
  end

  @doc """
  Returns the generated Kotlin registration call and object body, or `nil`.
  """
  @spec ui_source(classified(), String.t()) :: %{call: String.t(), body: String.t()} | nil
  def ui_source(%{registrations: []}, _app_package), do: nil

  def ui_source(%{registrations: registrations}, app_package) do
    lines = Enum.map(registrations, &registration_kotlin(&1, app_package))
    %{call: "registerUiComponents()", body: ui_body(lines)}
  end

  defp registration_kotlin(%{key: key, factory: factory, plugin: plugin}, app_package) do
    """
            // #{plugin}: #{key}
            #{app_package}.MobNativeViewRegistry.register(\"#{key}\") { props, send ->
                #{factory}(props, send)
            }
    """
    |> String.trim_trailing()
  end

  defp ui_body(lines) do
    "\n\n    // Registers explicitly opted-in plugin ui_components factories.\n" <>
      "    private fun registerUiComponents() {\n" <>
      Enum.join(lines, "\n") <>
      "\n    }"
  end
end
