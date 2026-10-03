defmodule MobDev.UrlSchemes do
  @moduledoc """
  Custom URL schemes that open the app (MOB-379): `config :mob_dev,
  url_schemes: ["myapp"]` in `mob.exs`. mob delivers the URL to the BEAM as
  `{:link, %{url: url, source: :launch | :running}}`; this module only makes the
  OS route the URL to the app.

  The build stamps the setting into native files every time, so a changed or
  removed setting takes effect on the next native build of new and existing
  apps alike:

    * Android — a managed `<intent-filter>` (`android.intent.action.VIEW`,
      categories `DEFAULT` + `BROWSABLE`, one `<data android:scheme>` per
      scheme) inside the launcher activity of
      `android/app/src/main/AndroidManifest.xml`, fenced by
      `mob:url-schemes` markers (`MobDev.Plugin.ManagedBlock`). The dev build
      (`mix mob.deploy --native`) and `mix mob.release --android` regenerate it;
      unset, `nil` or `[]` removes it.
    * iOS — a `CFBundleURLTypes` entry (`CFBundleURLName` = the iOS bundle id,
      `CFBundleTypeRole` `Viewer`) appended to the built bundle's Info.plist by
      the simulator and device builds and `mix mob.release --ios`.
      `ios/Info.plist` is never rewritten.

  A scheme the project already routes to the app is left to it. On Android
  that is a `VIEW` + `DEFAULT` + `BROWSABLE` intent filter on the launcher
  activity, outside the managed block, declaring the scheme with no host,
  path or other narrowing. A scheme in a `VIEW` filter on another activity is
  still added to the launcher, with a build warning: Android may then ask
  which activity opens the link. On iOS it is a scheme in any existing
  `CFBundleURLTypes` entry, compared case-insensitively as iOS does. The app's
  own entries are never changed.

  Schemes must be lowercase RFC 3986 schemes. `http` and `https` are refused:
  verified App Links and universal links need a host and domain verification,
  which a bare scheme can't express.

  The launcher activity must be `android:launchMode="singleTask"` (or
  `singleInstance`) when `url_schemes` is set; the build refuses anything
  else rather than rewrite `launchMode`. Otherwise a link opened from another
  app's task starts a second `MainActivity` there, and two activities drive
  one BEAM. mob_new's template uses `singleTop`, since `singleTask` also
  finishes the activities stacked above `MainActivity` whenever the app is
  reopened from its icon, so an app that takes deep links opts in.

  See `decisions/2026-10-03-url-schemes.md`.
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

  @markers {
    "            <!-- mob:url-schemes BEGIN (managed — regenerated each build; do not edit) -->",
    "            <!-- mob:url-schemes END -->"
  }

  @android_manifest "android/app/src/main/AndroidManifest.xml"
  @launch_modes ["singleTask", "singleInstance"]

  @typedoc "One `mix mob.doctor` row."
  @type check :: {:ok | :fail, String.t(), String.t(), String.t() | nil}

  @doc """
  Validates `mob.exs` `url_schemes`. Unset, `nil` (read as unset, like
  `MobDev.IosLayoutPlist`'s keys) and `[]` are `{:ok, []}` (no deep-link
  scheme); duplicates are dropped, order kept.
  """
  @spec schemes(keyword()) :: {:ok, [String.t()]} | {:error, String.t()}
  def schemes(cfg) do
    case cfg[:url_schemes] do
      nil ->
        {:ok, []}

      list when is_list(list) ->
        case Enum.find_value(list, &scheme_error/1) do
          nil -> {:ok, Enum.uniq(list)}
          message -> {:error, message}
        end

      other ->
        {:error,
         "mob.exs url_schemes must be a list of URL scheme strings such as [\"myapp\"], " <>
           "got #{inspect(other)}"}
    end
  end

  defp scheme_error(scheme) when scheme in ["http", "https"] do
    "mob.exs url_schemes can't claim #{inspect(scheme)}: Android App Links and iOS universal " <>
      "links need a host and domain verification (assetlinks.json, " <>
      "apple-app-site-association), which a bare scheme doesn't set up. Use a scheme of " <>
      "your own, such as \"myapp\""
  end

  defp scheme_error(scheme) when is_binary(scheme) do
    cond do
      Regex.match?(scheme_regex(), scheme) ->
        nil

      Regex.match?(scheme_regex(), String.downcase(scheme)) ->
        "mob.exs url_schemes: #{inspect(scheme)} must be lowercase " <>
          "(#{inspect(String.downcase(scheme))}): Android matches intent-filter schemes " <>
          "case-sensitively, and URLs carry the scheme in lowercase"

      true ->
        "mob.exs url_schemes: #{inspect(scheme)} isn't a URL scheme. Write just the scheme, " <>
          "without \"://\": a lowercase letter, then lowercase letters, digits, \"+\", \"-\" " <>
          "or \".\" (RFC 3986), such as \"myapp\""
    end
  end

  defp scheme_error(other),
    do: "mob.exs url_schemes entries must be strings such as \"myapp\", got #{inspect(other)}"

  defp scheme_regex, do: Regex.compile!("^[a-z][a-z0-9+.-]*$")

  defp schemes!(cfg) do
    case schemes(cfg) do
      {:ok, schemes} -> schemes
      {:error, message} -> Mix.raise(message)
    end
  end

  @doc """
  The `mix mob.doctor` row for `mob.exs`'s `url_schemes` and the text of the
  project's `AndroidManifest.xml` (`nil` when there is none): none when
  `url_schemes` is unset or empty, `:ok` listing the schemes, or `:fail` on a
  value the build refuses or a launcher activity it refuses
  (`launch_mode_error/2`).
  """
  @spec audit(keyword(), String.t() | nil) :: [check()]
  def audit(cfg, manifest) do
    case schemes(cfg) do
      {:ok, []} ->
        []

      {:ok, schemes} ->
        case manifest && launch_mode_error(manifest, @android_manifest) do
          nil ->
            [{:ok, "deep-link URL schemes", Enum.map_join(schemes, ", ", &"#{&1}://"), nil}]

          message ->
            [{:fail, "deep-link URL schemes", message, "Fix #{@android_manifest}"}]
        end

      {:error, message} ->
        [
          {:fail, "deep-link URL schemes", message,
           "Fix the value in mob.exs; the build refuses it"}
        ]
    end
  end

  # ── Android ──────────────────────────────────────────────────────────────────

  @doc """
  Regenerates the managed deep-link `<intent-filter>` inside the launcher
  activity (the one with a `MAIN` + `LAUNCHER` intent filter; the first, if
  several), just before its `</activity>`. A scheme the launcher activity
  already routes in full outside the managed block is skipped: one in a
  `VIEW` filter with the `DEFAULT` and `BROWSABLE` categories whose `<data>`
  elements set no `android:` attribute besides `android:scheme`. A filter
  narrowed by a host, port, path, ssp or MIME type, one missing a category,
  or one on another activity doesn't count. With nothing left to declare the
  block is removed.
  Idempotent. Raises `Mix.Error` when `schemes` is non-empty and there is no
  launcher activity, or its `</activity>` shares a line with other markup (the
  managed block occupies whole lines).
  """
  @spec merge_manifest(String.t(), [String.t()]) :: String.t()
  def merge_manifest(manifest, schemes) do
    stripped = MobDev.Plugin.ManagedBlock.strip(manifest, @markers)

    body =
      case added_schemes(stripped, schemes) do
        [] -> ""
        added -> intent_filter(added)
      end

    MobDev.Plugin.ManagedBlock.upsert(stripped, @markers, body, &place_in_launcher_activity/2)
  end

  @doc """
  The schemes `merge_manifest/2` adds that a `VIEW` intent filter on another
  activity also declares. Android may then ask the user which activity opens
  the link, so the build warns about each.
  """
  @spec declared_elsewhere(String.t(), [String.t()]) :: [String.t()]
  def declared_elsewhere(manifest, schemes) do
    stripped = MobDev.Plugin.ManagedBlock.strip(manifest, @markers)

    case added_schemes(stripped, schemes) do
      [] ->
        []

      added ->
        text = blank_comments(stripped)
        launcher = launcher!(text)

        others =
          text
          |> activities()
          |> Enum.reject(&(&1.close == launcher.close))
          |> Enum.flat_map(&view_schemes(&1.body))

        Enum.filter(added, &(&1 in others))
    end
  end

  defp added_schemes(_stripped, []), do: []

  defp added_schemes(stripped, schemes) do
    covered =
      stripped |> blank_comments() |> launcher!() |> Map.fetch!(:body) |> covered_schemes()

    Enum.reject(schemes, &(&1 in covered))
  end

  defp intent_filter(schemes) do
    data = Enum.map_join(schemes, "\n", &~s(                <data android:scheme="#{&1}" />))

    """
                <intent-filter>
                    <action android:name="android.intent.action.VIEW" />
                    <category android:name="android.intent.category.DEFAULT" />
                    <category android:name="android.intent.category.BROWSABLE" />
    #{data}
                </intent-filter>\
    """
  end

  defp place_in_launcher_activity(manifest, region) do
    %{close: close} = launcher!(blank_comments(manifest))
    line = binary_part(manifest, 0, close) |> String.split("\n") |> List.last()

    if String.trim(line) != "" do
      Mix.raise(
        "mob.exs url_schemes: the launcher activity's </activity> in AndroidManifest.xml " <>
          "shares a line with other markup. Put </activity> on a line of its own so the " <>
          "build can add the deep-link intent filter before it"
      )
    end

    MobDev.Plugin.ManagedBlock.insert_before_index(manifest, close, region)
  end

  defp launcher!(text) do
    Enum.find(activities(text), &launcher?(&1.body)) || Mix.raise(no_launcher_message())
  end

  defp no_launcher_message do
    "mob.exs url_schemes is set, but AndroidManifest.xml has no launcher activity (an " <>
      "<activity> with an <intent-filter> holding android.intent.action.MAIN and " <>
      "android.intent.category.LAUNCHER) to add the deep-link intent filter to"
  end

  # Every <activity> / <activity-alias> with a body, in comment-blanked text:
  # its element name, start tag, body and the byte index of its closing tag.
  defp activities(text) do
    "<(activity-alias|activity)(?=[\\s/>])[^>]*>"
    |> Regex.compile!()
    |> Regex.scan(text, return: :index)
    |> Enum.flat_map(fn [{start, len}, {name_start, name_len}] ->
      body_start = start + len
      rest = binary_part(text, body_start, byte_size(text) - body_start)
      tag = binary_part(text, start, len)
      name = binary_part(text, name_start, name_len)
      close = Regex.compile!("</" <> name <> "\\s*>")

      with false <- String.ends_with?(tag, "/>"),
           [{offset, _}] <- Regex.run(close, rest, return: :index) do
        [%{name: name, tag: tag, body: binary_part(rest, 0, offset), close: body_start + offset}]
      else
        _ -> []
      end
    end)
  end

  @doc """
  Why the launcher activity in `manifest` (the text of the file at `path`)
  can't take deep links, or `nil` when it can: its `android:launchMode` must
  be `singleTask` or `singleInstance`. For an `<activity-alias>` launcher
  that is the launch mode of its `android:targetActivity`, matched against
  `<activity android:name>` as Android resolves names (`.X`, `X` and
  `<package>.X` name the same activity; an exact spelling wins). A manifest
  with no launcher activity, or an alias with no or an undeclared target, is
  an error too.
  """
  @spec launch_mode_error(String.t(), Path.t()) :: String.t() | nil
  def launch_mode_error(manifest, path) do
    text = manifest |> MobDev.Plugin.ManagedBlock.strip(@markers) |> blank_comments()

    case Enum.find(activities(text), &launcher?(&1.body)) do
      nil -> no_launcher_message()
      launcher -> launcher |> launched_activity_tag(text) |> launch_mode_problem(path)
    end
  end

  defp launched_activity_tag(%{name: "activity", tag: tag}, _text), do: {:ok, tag}

  defp launched_activity_tag(%{tag: alias_tag}, text) do
    case attribute(alias_tag, "android:targetActivity") do
      nil -> :no_target
      target -> find_activity_tag(text, target)
    end
  end

  # Android resolves a name with a leading "." or no "." at all against the
  # package, so ".MainActivity", "MainActivity" and "com.ex.app.MainActivity"
  # can all name one activity. An exact spelling wins over a resolved one.
  defp find_activity_tag(text, target) do
    tags =
      "<activity(?=[\\s/>])[^>]*>"
      |> Regex.compile!()
      |> Regex.scan(text)
      |> List.flatten()

    found =
      Enum.find(tags, &(attribute(&1, "android:name") == target)) ||
        Enum.find(tags, &same_activity?(attribute(&1, "android:name"), target))

    if found, do: {:ok, found}, else: {:missing_target, target}
  end

  defp same_activity?(nil, _target), do: false

  # Two relative names resolve against the same package, so they match only
  # when equal (".MainActivity" is not ".ui.MainActivity"); a relative name
  # matches a fully qualified one that ends with it.
  defp same_activity?(name, target) do
    a = package_relative(name)
    b = package_relative(target)

    a == b or (relative?(b) and not relative?(a) and String.ends_with?(a, b)) or
      (relative?(a) and not relative?(b) and String.ends_with?(b, a))
  end

  defp package_relative("." <> _ = name), do: name
  defp package_relative(name), do: if(String.contains?(name, "."), do: name, else: "." <> name)

  defp relative?(name), do: String.starts_with?(name, ".")

  defp launch_mode_problem(:no_target, path) do
    "mob.exs url_schemes: the launcher <activity-alias> in #{path} has no " <>
      "android:targetActivity, so the activity it opens, whose android:launchMode must " <>
      "be singleTask, can't be found. Add android:targetActivity naming that <activity>"
  end

  defp launch_mode_problem({:missing_target, target}, path) do
    "mob.exs url_schemes: the launcher <activity-alias> in #{path} targets " <>
      "#{inspect(target)}, but no <activity> there has that android:name (relative to the " <>
      "package or fully qualified), so its android:launchMode (which must be singleTask) " <>
      "can't be checked. Point android:targetActivity at a declared <activity>"
  end

  defp launch_mode_problem({:ok, tag}, path) do
    mode = attribute(tag, "android:launchMode")

    if mode in @launch_modes do
      nil
    else
      name = attribute(tag, "android:name") || ".MainActivity"
      short = name |> String.split(".") |> List.last()
      current = if mode, do: "it is #{inspect(mode)}", else: "it has none, so it is \"standard\""

      "mob.exs url_schemes needs android:launchMode=\"singleTask\" on " <>
        "<activity android:name=\"#{name}\"> in #{path} (#{current}): a link opened from " <>
        "another app's task (a QR scanner, some browsers) would otherwise start a second " <>
        "#{short} there, and two activities would drive one BEAM. singleTask also finishes " <>
        "activities stacked above #{short} when the app is reopened from its icon"
    end
  end

  defp attribute(tag, name) do
    case List.keyfind(attributes(tag), name, 0) do
      {_, value} -> value
      nil -> nil
    end
  end

  defp launcher?(activity_body) do
    activity_body
    |> intent_filters()
    |> Enum.any?(
      &(has_name?(&1, "android.intent.action.MAIN") and
          has_name?(&1, "android.intent.category.LAUNCHER"))
    )
  end

  # A browser's or another app's implicit intent needs both DEFAULT and
  # BROWSABLE. Android merges every <data> in a filter, so one android:host
  # (or port, path*, ssp*, mimeType) narrows all of its schemes to part of
  # their URIs.
  defp covered_schemes(activity_body) do
    activity_body
    |> intent_filters()
    |> Enum.filter(
      &(has_name?(&1, "android.intent.action.VIEW") and
          has_name?(&1, "android.intent.category.DEFAULT") and
          has_name?(&1, "android.intent.category.BROWSABLE"))
    )
    |> Enum.flat_map(fn filter ->
      attributes = filter |> data_elements() |> Enum.flat_map(&attributes/1)

      if Enum.all?(attributes, fn {name, _} -> scheme_only?(name) end),
        do: for({"android:scheme", scheme} <- attributes, do: scheme),
        else: []
    end)
  end

  defp scheme_only?(name),
    do: name == "android:scheme" or not String.starts_with?(name, "android:")

  defp view_schemes(activity_body) do
    activity_body
    |> intent_filters()
    |> Enum.filter(&has_name?(&1, "android.intent.action.VIEW"))
    |> Enum.flat_map(&data_elements/1)
    |> Enum.flat_map(&attributes/1)
    |> Enum.flat_map(fn
      {"android:scheme", scheme} -> [scheme]
      _ -> []
    end)
  end

  defp intent_filters(text) do
    "<intent-filter(?=[\\s>])[^>]*>(.*?)</intent-filter\\s*>"
    |> Regex.compile!("s")
    |> Regex.scan(text, capture: :all_but_first)
    |> List.flatten()
  end

  defp data_elements(filter) do
    "<data(?=[\\s/>])[^>]*>"
    |> Regex.compile!()
    |> Regex.scan(filter)
    |> List.flatten()
  end

  defp attributes(tag) do
    ~S{([A-Za-z_][\w:.-]*)\s*=\s*(["'])(.*?)\2}
    |> Regex.compile!("s")
    |> Regex.scan(tag, capture: :all_but_first)
    |> Enum.map(fn [name, _quote, value] -> {name, value} end)
  end

  defp has_name?(filter, name),
    do:
      Regex.match?(
        Regex.compile!(~S{android:name\s*=\s*["']} <> Regex.escape(name) <> "[\"']"),
        filter
      )

  # Same length, so byte offsets into the result index the original; keeps a
  # commented-out activity or filter from counting.
  defp blank_comments(text) do
    Regex.replace(Regex.compile!("<!--.*?-->", "s"), text, &String.duplicate(" ", byte_size(&1)))
  end

  @doc """
  Applies `merge_manifest/2` with `mob.exs`'s schemes to the manifest at
  `path`, writing only when it changed. With `url_schemes` unset the merge
  still runs, which removes a block an earlier build added. Raises `Mix.Error`
  on an invalid setting, when schemes are set and `path` doesn't exist, or
  when schemes are set and `launch_mode_error/2` objects to the launcher
  activity.
  """
  @spec apply_android_manifest!(Path.t(), keyword()) :: :ok
  def apply_android_manifest!(path, cfg) do
    schemes = schemes!(cfg)

    case File.read(path) do
      {:ok, content} ->
        if schemes != [], do: launch_mode!(content, path)
        patched = merge_manifest(content, schemes)

        for scheme <- declared_elsewhere(content, schemes) do
          IO.puts(
            "  warning: url_schemes #{scheme}:// is also in a VIEW intent filter on another " <>
              "activity in #{path}; Android may ask which activity opens the link"
          )
        end

        if patched != content, do: File.write!(path, patched)
        :ok

      {:error, :enoent} when schemes == [] ->
        :ok

      {:error, reason} ->
        Mix.raise(
          "mob.exs url_schemes is set but #{path} can't be read (#{:file.format_error(reason)})"
        )
    end
  end

  defp launch_mode!(manifest, path) do
    case launch_mode_error(manifest, path) do
      nil -> :ok
      message -> Mix.raise(message)
    end
  end

  # ── iOS ──────────────────────────────────────────────────────────────────────

  @doc """
  The PlistBuddy commands that add `schemes` to an Info.plist whose XML text
  is `xml`: one new `CFBundleURLTypes` entry named `url_name`, role `Viewer`
  (Apple requires `CFBundleTypeRole` in each entry), appended after the
  plist's own entries (creating the array when absent), holding the schemes
  the plist doesn't already declare. `[]` when there is nothing to
  add. Every command must succeed. Raises `Mix.Error` when `xml` isn't an XML
  property list or its `CFBundleURLTypes` isn't an array.
  """
  @spec plist_commands([String.t()], String.t(), String.t()) :: [String.t()]
  def plist_commands(schemes, xml, url_name) do
    url_types =
      case declared_url_types(xml) do
        {:ok, url_types} ->
          url_types

        {:error, message} ->
          Mix.raise("mob.exs url_schemes: can't add CFBundleURLTypes, #{message}")
      end

    declared = url_types |> List.wrap() |> List.flatten() |> MapSet.new(&String.downcase/1)

    case {Enum.reject(schemes, &(&1 in declared)), url_types} do
      {[], _} -> []
      {new, nil} -> ["Add :CFBundleURLTypes array" | entry_commands(0, new, url_name)]
      {new, entries} -> entry_commands(length(entries), new, url_name)
    end
  end

  # PlistBuddy's `Add :CFBundleURLTypes:<n> dict` inserts at <n>, shifting what
  # is there, so <n> is the entry count: the new entry goes after the app's.
  defp entry_commands(index, schemes, url_name) do
    entry = ":CFBundleURLTypes:#{index}"

    [
      "Add #{entry} dict",
      "Add #{entry}:CFBundleURLName string #{url_name}",
      "Add #{entry}:CFBundleTypeRole string Viewer",
      "Add #{entry}:CFBundleURLSchemes array"
    ] ++
      (schemes
       |> Enum.with_index()
       |> Enum.map(fn {scheme, i} -> "Add #{entry}:CFBundleURLSchemes:#{i} string #{scheme}" end))
  end

  # Each CFBundleURLTypes entry's schemes, or nil when the key is absent.
  defp declared_url_types(xml) do
    with {:ok, entries} <- top_level_entries(xml) do
      case List.keyfind(entries, "CFBundleURLTypes", 0) do
        nil ->
          {:ok, nil}

        {_, xml_element(name: :array, content: content)} ->
          {:ok, content |> elements() |> Enum.map(&entry_schemes/1)}

        {_, _} ->
          {:error, "the plist's CFBundleURLTypes isn't an array"}
      end
    end
  end

  defp entry_schemes(xml_element(name: :dict, content: content)) do
    case content |> elements() |> pairs([]) |> List.keyfind("CFBundleURLSchemes", 0) do
      {_, xml_element(name: :array, content: schemes)} ->
        for xml_element(name: :string, content: value) <- elements(schemes), do: text(value)

      _ ->
        []
    end
  end

  defp entry_schemes(_), do: []

  defp top_level_entries(xml) do
    {doc, _rest} =
      :xmerl_scan.string(:binary.bin_to_list(xml),
        quiet: true,
        fetch_fun: fn _uri, state -> {:ok, :not_fetched, state} end
      )

    with xml_element(name: :plist, content: content) <- doc,
         [xml_element(name: :dict, content: entries)] <- elements(content) do
      {:ok, entries |> elements() |> pairs([])}
    else
      _ -> {:error, "not an XML property list with a top-level <dict>"}
    end
  catch
    :exit, _ -> {:error, "not an XML property list"}
  end

  defp elements(content), do: Enum.filter(content, &Record.is_record(&1, :xmlElement))

  defp pairs([xml_element(name: :key, content: key), value | rest], acc),
    do: pairs(rest, [{text(key), value} | acc])

  defp pairs(_, acc), do: Enum.reverse(acc)

  defp text(content) do
    content
    |> Enum.filter(&Record.is_record(&1, :xmlText))
    |> Enum.map_join(fn xml_text(value: value) -> IO.chardata_to_string(value) end)
    |> String.trim()
  end

  @doc """
  `plist_commands/3` for `mob.exs`'s schemes and the Info.plist at `path` (any
  plist format; read with macOS `plutil`). `[]` without reading the file when
  `url_schemes` is unset or empty. Raises `Mix.Error` on an invalid setting.
  """
  @spec bundle_plist_commands!(Path.t(), keyword(), String.t()) :: [String.t()]
  def bundle_plist_commands!(path, cfg, url_name) do
    case schemes!(cfg) do
      [] ->
        []

      schemes ->
        case System.cmd("plutil", ["-convert", "xml1", "-o", "-", path], stderr_to_stdout: true) do
          {xml, 0} ->
            plist_commands(schemes, xml, url_name)

          {output, status} ->
            Mix.raise("plutil couldn't read #{path} (exit #{status}): #{output}")
        end
    end
  end

  @doc """
  Adds `mob.exs`'s schemes to the Info.plist at `path` with PlistBuddy
  (macOS), under `CFBundleURLName` `url_name`. Leaves the file untouched when
  `url_schemes` is unset or every scheme is already declared. Raises when any
  command fails.
  """
  @spec apply_plist!(Path.t(), keyword(), String.t()) :: :ok
  def apply_plist!(path, cfg, url_name) do
    for command <- bundle_plist_commands!(path, cfg, url_name) do
      case System.cmd("/usr/libexec/PlistBuddy", ["-c", command, path], stderr_to_stdout: true) do
        {_, 0} ->
          :ok

        {output, status} ->
          Mix.raise("PlistBuddy `#{command}` on #{path} exited #{status}: #{String.trim(output)}")
      end
    end

    :ok
  end
end
