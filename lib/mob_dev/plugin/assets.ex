defmodule MobDev.Plugin.Assets do
  @moduledoc """
  Pure planners for the tier-3 build-time file merges — migrations, fonts, and
  images — that `native_build` copies into the host app at build.

  Unlike the runtime manifest (behavioral data read on device), these are
  physical files: a plugin's migration `.exs`, font, and image files are
  meaningless as build-machine paths on device, so they're copied into the host
  bundle at build time. This module computes *what* gets copied where (pure +
  unit-tested); `native_build` does the I/O (listing dirs, copying, patching
  Info.plist).
  """

  @doc """
  Plans the migration copies: maps each plugin migration source file to a
  destination under the host's `migrations_dir`, prefixed with the plugin's
  `repo_namespace` so files from different vendors don't collide.

  Takes `[%{repo_namespace, files: [src_path]}]` (the caller lists each plugin's
  migration dir) and the host migrations dir; returns `[{src, dest}]`.
  """
  @spec migration_copies([%{repo_namespace: String.t(), files: [Path.t()]}], Path.t()) ::
          [{Path.t(), Path.t()}]
  def migration_copies(plugin_migrations, dest_dir) do
    for %{repo_namespace: ns, files: files} <- plugin_migrations,
        src <- files do
      {src, Path.join(dest_dir, namespaced_filename(ns, Path.basename(src)))}
    end
  end

  @doc """
  Prefixes a migration filename with the plugin's `repo_namespace`, unless it is
  already prefixed (idempotent — re-running a build doesn't double-prefix).
  """
  @spec namespaced_filename(String.t(), String.t()) :: String.t()
  def namespaced_filename(ns, filename) do
    if String.starts_with?(filename, ns), do: filename, else: ns <> filename
  end

  @doc """
  The on-device bundle path a `plugin://<plugin>/<file>` reference resolves to.
  Plugin images are copied here at build time; the core `plugin://` resolver
  maps to the same convention. Returns a path relative to the app bundle root.
  """
  @spec image_bundle_path(atom() | String.t(), String.t()) :: String.t()
  def image_bundle_path(plugin, basename) do
    Path.join(["assets", "plugin", to_string(plugin), basename])
  end

  @doc """
  Merges font basenames into an iOS `Info.plist` XML string under `UIAppFonts`,
  creating the array if absent and de-duplicating existing entries. Pure string
  transform over the plist's XML (the same approach as the plist-keys merge).
  """
  @spec merge_ui_app_fonts(String.t(), [String.t()]) :: String.t()
  def merge_ui_app_fonts(plist, []), do: plist

  def merge_ui_app_fonts(plist, font_basenames) do
    existing = parse_ui_app_fonts(plist)
    merged = Enum.uniq(existing ++ font_basenames)
    array = render_ui_app_fonts_array(merged)

    cond do
      has_ui_app_fonts?(plist) ->
        replace_ui_app_fonts(plist, array)

      true ->
        # Insert before the closing </dict></plist>.
        String.replace(
          plist,
          ~r{(\n\s*</dict>\s*</plist>\s*)$},
          "\n\t<key>UIAppFonts</key>\n#{array}\\1"
        )
    end
  end

  @doc "Extracts the current `UIAppFonts` entries from an `Info.plist` (or `[]`)."
  @spec parse_ui_app_fonts(String.t()) :: [String.t()]
  def parse_ui_app_fonts(plist) do
    case Regex.run(~r{<key>UIAppFonts</key>\s*<array>(.*?)</array>}s, plist) do
      [_, body] -> Regex.scan(~r{<string>(.*?)</string>}s, body) |> Enum.map(fn [_, s] -> s end)
      _ -> []
    end
  end

  defp has_ui_app_fonts?(plist), do: String.contains?(plist, "<key>UIAppFonts</key>")

  defp replace_ui_app_fonts(plist, array) do
    String.replace(
      plist,
      ~r{<key>UIAppFonts</key>\s*<array>.*?</array>}s,
      "<key>UIAppFonts</key>\n#{array}"
    )
  end

  defp render_ui_app_fonts_array(basenames) do
    items = Enum.map_join(basenames, "\n", &"\t\t<string>#{&1}</string>")
    "\t<array>\n#{items}\n\t</array>"
  end
end
