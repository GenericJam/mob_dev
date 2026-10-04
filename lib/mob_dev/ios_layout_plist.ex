defmodule MobDev.IosLayoutPlist do
  @moduledoc """
  The Info.plist keys that decide where an iOS app runs and how it may lay
  out: `UIDeviceFamily` (iPhone `1`, iPad `2`), `UISupportedInterfaceOrientations`
  (iPhone), `UISupportedInterfaceOrientations~ipad`, and `UIRequiresFullScreen`.

  ## `mob.exs` overrides

  Three `config :mob_dev` keys override the project's `ios/Info.plist` in the
  built app bundle (the dev simulator and device builds and `mix mob.release`).
  The project file is never rewritten, so the setting reaches new and existing
  apps alike:

    * `ios_target_devices` — `[:iphone, :ipad]` (universal) or `[:iphone]`.
      Sets `UIDeviceFamily`. Without iPad, an iPad runs the app letterboxed
      in iPhone compatibility mode, and it can't join Split View. An App Store
      app that has shipped iPad support can't drop it in an update.
    * `ios_orientations` — `:all`, `:portrait` or `:landscape`. Sets the
      iPhone `UISupportedInterfaceOrientations` (and removes any
      `UISupportedInterfaceOrientations~iphone`). iPad always declares all four
      (`UISupportedInterfaceOrientations~ipad`): iPadOS 26 rotates resizable
      apps freely, and iPad multitasking requires all four.
    * `multi_window` — `true` or `false` (MOB-245). `true` sets
      `UIApplicationSceneManifest` → `UIApplicationSupportsMultipleScenes`, so
      iPad users can open several windows of the app, each with its own
      navigation (`Mob.Scene` in mob). It needs the plist's existing
      `UISceneConfigurations` → `UIWindowSceneSessionRoleApplication` entry
      (the generated `SceneDelegate`); the build refuses a plist without one
      rather than add a manifest that would switch the app to a scene
      lifecycle with no delegate. `false` removes the
      key, which iOS reads as `false`. Needs a mob release with `Mob.Scene`.

  Unset keys leave `ios/Info.plist` as written. `UIRequiresFullScreen` has no
  override: the only supported value is `false` (or no key), and
  `mix mob.doctor` warns when a plist sets it.

  See `decisions/2026-10-01-ios-layout-plist-keys.md`.
  """

  require Record

  Record.defrecordp(
    :xml_element,
    :xmlElement,
    Record.extract(:xmlElement, from_lib: "xmerl/include/xmerl.hrl")
  )

  Record.defrecordp(
    :xml_text,
    :xmlText,
    Record.extract(:xmlText, from_lib: "xmerl/include/xmerl.hrl")
  )

  @portrait ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown"]
  @landscape ["UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"]
  @all_orientations @portrait ++ @landscape

  @orientation_sets %{all: @all_orientations, portrait: @portrait, landscape: @landscape}

  @scene_configurations ":UIApplicationSceneManifest:UISceneConfigurations:UIWindowSceneSessionRoleApplication:0"
  @multiple_scenes ":UIApplicationSceneManifest:UIApplicationSupportsMultipleScenes"

  @typedoc "One `mix mob.doctor` row."
  @type check :: {:ok | :warn | :fail, String.t(), String.t(), String.t() | nil}

  @typedoc "The layout keys of a parsed Info.plist; `nil` when the key is absent."
  @type keys :: %{
          device_family: [integer()] | nil,
          orientations: [String.t()] | nil,
          iphone_orientations: [String.t()] | nil,
          ipad_orientations: [String.t()] | nil,
          requires_full_screen: boolean() | nil,
          scene_configurations?: boolean()
        }

  @doc """
  Validates the `mob.exs` overrides. Returns the resolved settings, `nil` for
  each key that is unset.
  """
  @spec settings(keyword()) ::
          {:ok,
           %{
             device_family: [integer()] | nil,
             orientations: [String.t()] | nil,
             multi_window: boolean() | nil
           }}
          | {:error, String.t()}
  def settings(cfg) do
    with {:ok, family} <- device_family(cfg[:ios_target_devices]),
         {:ok, orientations} <- orientations(cfg[:ios_orientations]),
         {:ok, multi_window} <- multi_window(cfg[:multi_window]) do
      {:ok, %{device_family: family, orientations: orientations, multi_window: multi_window}}
    end
  end

  defp device_family(nil), do: {:ok, nil}

  defp device_family([_ | _] = devices) do
    case devices |> Enum.uniq() |> Enum.sort() do
      [:iphone] -> {:ok, [1]}
      [:ipad, :iphone] -> {:ok, [1, 2]}
      _ -> device_family_error(devices)
    end
  end

  defp device_family(other), do: device_family_error(other)

  defp device_family_error(value) do
    {:error,
     "mob.exs ios_target_devices must be [:iphone, :ipad] or [:iphone], got #{inspect(value)}"}
  end

  defp orientations(nil), do: {:ok, nil}

  defp orientations(value) when is_map_key(@orientation_sets, value),
    do: {:ok, @orientation_sets[value]}

  defp orientations(other) do
    {:error,
     "mob.exs ios_orientations must be :all, :portrait or :landscape, got #{inspect(other)}"}
  end

  defp multi_window(value) when is_boolean(value) or is_nil(value), do: {:ok, value}

  defp multi_window(other),
    do: {:error, "mob.exs multi_window must be true or false, got #{inspect(other)}"}

  @doc """
  The PlistBuddy commands that stamp the `mob.exs` overrides into a bundle's
  Info.plist, in order. A `Delete` of a key the plist lacks fails harmlessly;
  every other command must succeed, including the `Print` that checks a
  `multi_window: true` plist has an application scene configuration. Raises
  `Mix.Error` on an invalid setting.
  """
  @spec plist_commands(keyword()) :: [String.t()]
  def plist_commands(cfg) do
    case settings(cfg) do
      {:ok, %{device_family: family, orientations: orientations, multi_window: multi_window}} ->
        family_commands(family) ++
          orientation_commands(orientations) ++ multi_window_commands(multi_window)

      {:error, message} ->
        Mix.raise(message)
    end
  end

  defp family_commands(nil), do: []

  defp family_commands(family),
    do: array_commands("UIDeviceFamily", "integer", Enum.map(family, &Integer.to_string/1))

  defp orientation_commands(nil), do: []

  defp orientation_commands(orientations) do
    ["Delete :UISupportedInterfaceOrientations~iphone"] ++
      array_commands("UISupportedInterfaceOrientations", "string", orientations) ++
      array_commands("UISupportedInterfaceOrientations~ipad", "string", @all_orientations)
  end

  defp multi_window_commands(nil), do: []
  defp multi_window_commands(false), do: ["Delete #{@multiple_scenes}"]

  # PlistBuddy's Add creates a missing UIApplicationSceneManifest dict on its
  # own, which would put a manifest-less app on the scene lifecycle with no
  # delegate (a blank window), so check the configurations exist first.
  defp multi_window_commands(true),
    do: [
      "Print #{@scene_configurations}",
      "Delete #{@multiple_scenes}",
      "Add #{@multiple_scenes} bool true"
    ]

  defp array_commands(key, type, values) do
    ["Delete :#{key}", "Add :#{key} array"] ++
      (values
       |> Enum.with_index()
       |> Enum.map(fn {value, i} -> "Add :#{key}:#{i} #{type} #{value}" end))
  end

  @doc """
  Applies `plist_commands/1` to the Info.plist at `path` with PlistBuddy
  (macOS). Raises when a command other than `Delete` fails.
  """
  @spec apply!(Path.t(), keyword()) :: :ok
  def apply!(path, cfg) do
    for command <- plist_commands(cfg) do
      case System.cmd("/usr/libexec/PlistBuddy", ["-c", command, path], stderr_to_stdout: true) do
        {_, 0} ->
          :ok

        {output, status} ->
          cond do
            String.starts_with?(command, "Delete ") ->
              :ok

            command == "Print #{@scene_configurations}" ->
              Mix.raise(missing_scene_configurations(path))

            true ->
              Mix.raise(
                "PlistBuddy `#{command}` on #{path} exited #{status}: #{String.trim(output)}"
              )
          end
      end
    end

    :ok
  end

  # The error for `multi_window: true` on a plist without a scene manifest;
  # release_device.sh prints the same advice.
  defp missing_scene_configurations(path) do
    "mob.exs multi_window: true needs UIApplicationSceneManifest → UISceneConfigurations → " <>
      "UIWindowSceneSessionRoleApplication (a SceneDelegate) in #{path}. Copy the " <>
      "UIApplicationSceneManifest dict from a newly generated app's ios/Info.plist " <>
      "(mix mob.new), or set multi_window: false"
  end

  @doc """
  Reads the layout keys from an XML Info.plist. `{:error, reason}` when the
  text isn't an XML property list (a binary plist, say).
  """
  @spec read(String.t()) :: {:ok, keys()} | {:error, String.t()}
  def read(xml) do
    with {:ok, dict} <- top_level_dict(xml) do
      {:ok,
       %{
         device_family: dict |> Map.get("UIDeviceFamily") |> integers(),
         orientations: dict |> Map.get("UISupportedInterfaceOrientations") |> strings(),
         iphone_orientations:
           dict |> Map.get("UISupportedInterfaceOrientations~iphone") |> strings(),
         ipad_orientations: dict |> Map.get("UISupportedInterfaceOrientations~ipad") |> strings(),
         requires_full_screen: dict |> Map.get("UIRequiresFullScreen") |> boolean(),
         scene_configurations?:
           dict |> Map.get("UIApplicationSceneManifest") |> scene_configurations?()
       }}
    end
  end

  @doc """
  The keys of an XML property list's top-level `<dict>`, parsed structurally
  (comments, CDATA and nested dictionaries contribute nothing).
  """
  @spec top_level_keys(String.t()) :: {:ok, [String.t()]} | {:error, String.t()}
  def top_level_keys(xml) do
    with {:ok, dict} <- top_level_dict(xml), do: {:ok, Map.keys(dict)}
  end

  defp top_level_dict(xml) do
    {doc, _rest} =
      :xmerl_scan.string(:binary.bin_to_list(xml),
        quiet: true,
        fetch_fun: fn _uri, state -> {:ok, :not_fetched, state} end
      )

    with xml_element(name: :plist, content: content) <- doc,
         [xml_element(name: :dict, content: entries)] <- elements(content) do
      {:ok, entries |> elements() |> pairs(%{})}
    else
      _ -> {:error, "not an XML property list with a top-level <dict>"}
    end
  catch
    :exit, _ -> {:error, "not an XML property list"}
  end

  defp elements(content), do: Enum.filter(content, &Record.is_record(&1, :xmlElement))

  defp pairs([xml_element(name: :key, content: key), value | rest], acc),
    do: pairs(rest, Map.put(acc, text(key), value))

  defp pairs(_, acc), do: acc

  defp text(content) do
    content
    |> Enum.filter(&Record.is_record(&1, :xmlText))
    |> Enum.map_join(fn xml_text(value: value) -> IO.chardata_to_string(value) end)
    |> String.trim()
  end

  defp integers(xml_element(name: :array, content: content)) do
    content
    |> elements()
    |> Enum.flat_map(fn xml_element(name: name, content: value) ->
      with true <- name in [:integer, :string],
           {n, ""} <- Integer.parse(text(value)) do
        [n]
      else
        _ -> []
      end
    end)
  end

  defp integers(xml_element(name: :integer, content: value)) do
    case Integer.parse(text(value)) do
      {n, ""} -> [n]
      _ -> []
    end
  end

  defp integers(_), do: nil

  defp strings(xml_element(name: :array, content: content)) do
    content
    |> elements()
    |> Enum.flat_map(fn
      xml_element(name: :string, content: value) -> [text(value)]
      _ -> []
    end)
  end

  defp strings(_), do: nil

  defp boolean(xml_element(name: true)), do: true
  defp boolean(xml_element(name: false)), do: false
  defp boolean(_), do: nil

  # An application-role scene configuration (the SceneDelegate) to extend.
  defp scene_configurations?(xml_element(name: :dict, content: content)) do
    with xml_element(name: :dict, content: configurations) <-
           content |> elements() |> pairs(%{}) |> Map.get("UISceneConfigurations"),
         xml_element(name: :array, content: roles) <-
           configurations
           |> elements()
           |> pairs(%{})
           |> Map.get("UIWindowSceneSessionRoleApplication") do
      elements(roles) != []
    else
      _ -> false
    end
  end

  defp scene_configurations?(_), do: false

  @doc """
  The `mix mob.doctor` rows for an app's Info.plist text and `mob.exs`
  config: one `:ok` row when the app can run full-screen on iPad, rotate and
  join Split View, otherwise a `:warn` per problem with the exact fix.
  Problems a `mob.exs` setting chose on purpose (`ios_target_devices:
  [:iphone]`, `ios_orientations: :portrait`) aren't warned about.
  """
  @spec audit(String.t(), keyword()) :: [check()]
  def audit(xml, cfg) do
    with {:settings, {:ok, settings}} <- {:settings, settings(cfg)},
         {:plist, {:ok, keys}} <- {:plist, read(xml)} do
      family = settings.device_family || keys.device_family || [1]
      orientations = settings.orientations || keys.iphone_orientations || keys.orientations

      ipad_orientations =
        if settings.orientations,
          do: @all_orientations,
          else: keys.ipad_orientations || keys.orientations

      rows =
        List.flatten([
          family_check(family, settings.device_family, keys.device_family),
          orientation_check(orientations, settings.orientations),
          ipad_orientation_check(2 in family, ipad_orientations),
          full_screen_check(keys.requires_full_screen),
          multi_window_check(settings.multi_window, keys.scene_configurations?)
        ])

      if rows == [], do: [{:ok, label(), summary(family, orientations), nil}], else: rows
    else
      {:settings, {:error, message}} ->
        [{:fail, label(), message, "Fix the value in mob.exs; the iOS build refuses it"}]

      {:plist, {:error, message}} ->
        [{:warn, label(), "couldn't check ios/Info.plist: #{message}", nil}]
    end
  end

  defp multi_window_check(true, false) do
    {:fail, "iOS multi_window (Info.plist)",
     "mob.exs sets multi_window: true but ios/Info.plist has no UIApplicationSceneManifest → " <>
       "UISceneConfigurations → UIWindowSceneSessionRoleApplication, so the iOS build refuses it",
     "Copy the UIApplicationSceneManifest dict from a newly generated app's ios/Info.plist " <>
       "(mix mob.new), or set multi_window: false"}
  end

  defp multi_window_check(_, _), do: []

  defp label, do: "iOS iPad / Split View (Info.plist)"

  defp summary(family, orientations) do
    devices = if 2 in family, do: "iPhone + iPad", else: "iPhone only (ios_target_devices)"

    rotation =
      cond do
        orientations == nil -> "orientations not declared"
        rotates?(orientations) -> "rotates"
        true -> "orientation-locked (ios_orientations)"
      end

    "#{devices}, #{rotation}, resizable"
  end

  defp family_check(family, configured, declared) do
    cond do
      2 in family or configured != nil ->
        []

      true ->
        declared_text =
          if declared, do: "UIDeviceFamily is #{inspect(declared)}", else: "no UIDeviceFamily key"

        {:warn, "iOS iPad support",
         "ios/Info.plist declares iPhone only (#{declared_text}): on iPad the app runs " <>
           "letterboxed in iPhone compatibility mode and can't join Split View or Slide Over",
         """
         Add to mob.exs (config :mob_dev):  ios_target_devices: [:iphone, :ipad]
         or to ios/Info.plist:
           <key>UIDeviceFamily</key>
           <array><integer>1</integer><integer>2</integer></array>
         An App Store app that ships iPad support can't drop it in an update.
         To stay iPhone-only on purpose, set ios_target_devices: [:iphone]\
         """}
    end
  end

  defp orientation_check(nil, _configured), do: []

  defp orientation_check(orientations, configured) do
    cond do
      configured != nil or rotates?(orientations) ->
        []

      true ->
        {locked, other} =
          if Enum.any?(orientations, &(&1 in @landscape)),
            do: {"landscape", "portrait"},
            else: {"portrait", "landscape"}

        {:warn, "iOS orientations",
         "ios/Info.plist allows only #{locked} on iPhone (UISupportedInterfaceOrientations), " <>
           "so the app can't rotate to fill a #{other} screen or window",
         """
         Add to mob.exs (config :mob_dev):  ios_orientations: :all
         or list all four in ios/Info.plist UISupportedInterfaceOrientations:
           #{Enum.join(@all_orientations, ", ")}
         To keep the lock on purpose, set ios_orientations: :#{locked}\
         """}
    end
  end

  # Portrait and landscape both reachable. Apple's own iPhone default
  # (everything but upside-down) rotates.
  defp rotates?(orientations),
    do:
      Enum.any?(orientations, &(&1 in @portrait)) and Enum.any?(orientations, &(&1 in @landscape))

  defp ipad_orientation_check(false, _orientations), do: []
  defp ipad_orientation_check(true, nil), do: []

  defp ipad_orientation_check(true, orientations) do
    if all_orientations?(orientations) do
      []
    else
      {:warn, "iOS iPad orientations",
       "ios/Info.plist restricts iPad orientations: iPad multitasking requires all four, " <>
         "and iPadOS 26 rotates resizable apps freely regardless",
       """
       Add to ios/Info.plist:
         <key>UISupportedInterfaceOrientations~ipad</key>
         <array> #{Enum.map_join(@all_orientations, " ", &"<string>#{&1}</string>")} </array>
       or set ios_orientations in mob.exs (config :mob_dev), which declares all four on iPad\
       """}
    end
  end

  defp full_screen_check(true) do
    {:warn, "iOS UIRequiresFullScreen",
     "ios/Info.plist sets UIRequiresFullScreen: the app opts out of Split View and Slide Over. " <>
       "The key is deprecated since iPadOS 26, and apps built with the iOS 27 SDK are resized anyway",
     "Delete the UIRequiresFullScreen key from ios/Info.plist (or set it to <false/>)"}
  end

  defp full_screen_check(_), do: []

  defp all_orientations?(orientations), do: Enum.all?(@all_orientations, &(&1 in orientations))
end
