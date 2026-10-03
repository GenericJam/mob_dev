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
      unset or `[]` removes it.
    * iOS — a `CFBundleURLTypes` entry (`CFBundleURLName` = the iOS bundle id)
      appended to the built bundle's Info.plist by the simulator and device
      builds and `mix mob.release --ios`. `ios/Info.plist` is never rewritten.

  A scheme the project already declares itself is left to it: on Android, one
  in any `VIEW` intent filter outside the managed block (a second filter for
  the same scheme in another activity makes Android ask which activity should
  open the link); on iOS, one in any existing `CFBundleURLTypes` entry, compared
  case-insensitively as iOS does. The app's own entries are never changed.

  Schemes must be lowercase RFC 3986 schemes. `http` and `https` are refused:
  verified App Links and universal links need a host and domain verification,
  which a bare scheme can't express.

  The launcher activity should be `android:launchMode="singleTask"` (mob_new's
  template is), or a link opened from another app's task starts a second
  `MainActivity` there. The build doesn't rewrite `launchMode`.

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

  @typedoc "One `mix mob.doctor` row."
  @type check :: {:ok | :fail, String.t(), String.t(), String.t() | nil}

  @doc """
  Validates `mob.exs` `url_schemes`. Unset and `[]` are `{:ok, []}` (no
  deep-link scheme); duplicates are dropped, order kept.
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
  The `mix mob.doctor` row: none when `url_schemes` is unset or empty, `:ok`
  listing the schemes, or `:fail` on a value the build refuses.
  """
  @spec audit(keyword()) :: [check()]
  def audit(cfg) do
    case schemes(cfg) do
      {:ok, []} ->
        []

      {:ok, schemes} ->
        [{:ok, "deep-link URL schemes", Enum.map_join(schemes, ", ", &"#{&1}://"), nil}]

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
  several), just before its `</activity>`. Schemes declared in a `VIEW` intent
  filter outside the managed block are skipped; with nothing left to declare
  the block is removed. Idempotent. Raises `Mix.Error` when there is a scheme
  to declare and no launcher activity, or its `</activity>` shares a line with
  other markup (the managed block occupies whole lines).
  """
  @spec merge_manifest(String.t(), [String.t()]) :: String.t()
  def merge_manifest(manifest, schemes) do
    stripped = MobDev.Plugin.ManagedBlock.strip(manifest, @markers)
    declared = stripped |> blank_comments() |> declared_view_schemes()

    body =
      case Enum.reject(schemes, &(&1 in declared)) do
        [] -> ""
        missing -> intent_filter(missing)
      end

    MobDev.Plugin.ManagedBlock.upsert(stripped, @markers, body, &place_in_launcher_activity/2)
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
    close = launcher_activity_close(blank_comments(manifest))
    before_close = binary_part(manifest, 0, close)
    line = before_close |> String.split("\n") |> List.last()

    if String.trim(line) != "" do
      Mix.raise(
        "mob.exs url_schemes: the launcher activity's </activity> in AndroidManifest.xml " <>
          "shares a line with other markup. Put </activity> on a line of its own so the " <>
          "build can add the deep-link intent filter before it"
      )
    end

    MobDev.Plugin.ManagedBlock.insert_before_index(manifest, close, region)
  end

  # Byte index of the launcher activity's closing tag in comment-blanked text.
  defp launcher_activity_close(text) do
    opening = Regex.compile!("<(activity-alias|activity)(?=[\\s/>])[^>]*>")

    launcher =
      opening
      |> Regex.scan(text, return: :index, capture: :all)
      |> Enum.find_value(fn [{start, len}, {name_start, name_len}] ->
        unless String.ends_with?(binary_part(text, start, len), "/>"),
          do: launcher_close(text, start + len, binary_part(text, name_start, name_len))
      end)

    launcher ||
      Mix.raise(
        "mob.exs url_schemes is set, but AndroidManifest.xml has no launcher activity (an " <>
          "<activity> with an <intent-filter> holding android.intent.action.MAIN and " <>
          "android.intent.category.LAUNCHER) to add the deep-link intent filter to"
      )
  end

  defp launcher_close(text, body_start, name) do
    rest = binary_part(text, body_start, byte_size(text) - body_start)

    with {offset, _} <- :binary.match(rest, "</#{name}>"),
         true <- launcher?(binary_part(rest, 0, offset)) do
      body_start + offset
    else
      _ -> nil
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

  defp declared_view_schemes(text) do
    scheme = Regex.compile!(~S{android:scheme\s*=\s*["']([^"']*)["']})

    text
    |> intent_filters()
    |> Enum.filter(&has_name?(&1, "android.intent.action.VIEW"))
    |> Enum.flat_map(&Regex.scan(scheme, &1, capture: :all_but_first))
    |> List.flatten()
  end

  defp intent_filters(text) do
    "<intent-filter(?=[\\s>])[^>]*>(.*?)</intent-filter>"
    |> Regex.compile!("s")
    |> Regex.scan(text, capture: :all_but_first)
    |> List.flatten()
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
  on an invalid setting, or when schemes are set and `path` doesn't exist.
  """
  @spec apply_android_manifest!(Path.t(), keyword()) :: :ok
  def apply_android_manifest!(path, cfg) do
    schemes = schemes!(cfg)

    case File.read(path) do
      {:ok, content} ->
        patched = merge_manifest(content, schemes)
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

  # ── iOS ──────────────────────────────────────────────────────────────────────

  @doc """
  The PlistBuddy commands that add `schemes` to an Info.plist whose XML text
  is `xml`: one new `CFBundleURLTypes` entry named `url_name`, appended after
  the plist's own entries (creating the array when absent), holding the
  schemes the plist doesn't already declare. `[]` when there is nothing to
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
