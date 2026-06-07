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
    copies =
      for %{repo_namespace: ns, files: files} <- plugin_migrations,
          src <- files do
        {src, Path.join(dest_dir, namespaced_filename(ns, Path.basename(src)))}
      end

    assert_unique_destinations!(copies)
    copies
  end

  # Two distinct sources mapping to the same destination would make the second
  # `File.cp!` silently clobber the first migration. After namespacing this can
  # only happen if two plugins share a `repo_namespace` (which cross-validation
  # already rejects) — so this is a defensive build-time guard, surfaced loudly
  # rather than as silent data loss.
  defp assert_unique_destinations!(copies) do
    dups =
      copies
      |> Enum.group_by(fn {_src, dest} -> dest end)
      |> Enum.filter(fn {_dest, list} -> length(list) > 1 end)

    unless dups == [] do
      detail =
        Enum.map_join(dups, "\n", fn {dest, list} ->
          "  #{Path.basename(dest)} <- #{Enum.map_join(list, ", ", fn {src, _} -> src end)}"
        end)

      raise "plugin migration filename collision — distinct sources map to the same destination:\n" <>
              detail <> "\nRename the migrations so their <version>_<description> differ."
    end
  end

  @doc """
  Namespaces a migration filename with the plugin's `repo_namespace`, inserting
  it into the *name* part after the `<version>_` prefix so Ecto can still parse
  the leading-integer version (`20260101000000_create.exs` →
  `20260101000000_kv_create.exs`). Files without a numeric version prefix fall
  back to a plain prefix.

  The namespace is **always** inserted — there is no "already namespaced?" guard.
  Migration sources are always the plugin author's raw files (never our output),
  so re-run idempotency comes from the deterministic source→dest mapping, not
  from inspecting the name. A guard that skipped namespacing when the description
  happened to begin with the namespace text would silently drop the namespace and
  cause cross-vendor collisions, so we don't do it.
  """
  @spec namespaced_filename(String.t(), String.t()) :: String.t()
  def namespaced_filename(ns, filename) do
    case Regex.run(~r/^(\d+)_(.*)$/, filename) do
      [_, version, rest] -> "#{version}_#{ns}#{rest}"
      _ -> ns <> filename
    end
  end

  @doc """
  The Android `res/font/` resource name for a font file: lowercase, the
  extension dropped, and any character outside `[a-z0-9_]` replaced with `_`
  (Android resource-name rules). `"Georgia.ttf"` → `"georgia"`,
  `"Inter-Regular.ttf"` → `"inter_regular"`. The renderer normalises the `font:`
  prop the same way to find the resource. A leading non-letter is prefixed with
  `f_` so the name is a valid resource identifier.
  """
  @spec android_font_resource_name(String.t()) :: String.t()
  def android_font_resource_name(filename) do
    base =
      filename
      |> Path.basename(Path.extname(filename))
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_]/, "_")

    if base =~ ~r/^[a-z]/, do: base, else: "f_" <> base
  end

  @doc """
  Plans the iOS font-bundle copies: each distinct source font copies to the `.app`
  root under its basename (and is listed in `UIAppFonts` by basename). Two distinct
  sources sharing a basename (e.g. two plugins both shipping `Icons.ttf`) would
  silently overwrite each other in the bundle and collapse to a single `UIAppFonts`
  entry, so that is surfaced as an error instead of a silent loss.

  Returns `{:ok, [{src, dest_basename}]}` or
  `{:error, {:font_basename_collision, basename, [src, ...]}}`.
  """
  @spec plan_ios_font_bundle([Path.t()]) ::
          {:ok, [{Path.t(), String.t()}]}
          | {:error, {:font_basename_collision, String.t(), [Path.t()]}}
  def plan_ios_font_bundle(fonts) do
    plan_font_copies(fonts, &Path.basename/1, :font_basename_collision)
  end

  @doc """
  Plans the Android `res/font/` copies: each distinct source maps to
  `<android_font_resource_name>.<ext>`. Two distinct sources normalising to the
  same resource name (e.g. `Inter-Regular.ttf` and `Inter_Regular.ttf` both →
  `inter_regular.ttf`) would silently overwrite each other, so that is surfaced
  as an error.

  Returns `{:ok, [{src, res_filename}]}` or
  `{:error, {:font_resource_collision, res_filename, [src, ...]}}`.
  """
  @spec plan_android_font_copies([Path.t()]) ::
          {:ok, [{Path.t(), String.t()}]}
          | {:error, {:font_resource_collision, String.t(), [Path.t()]}}
  def plan_android_font_copies(fonts) do
    plan_font_copies(
      fonts,
      fn src ->
        android_font_resource_name(Path.basename(src)) <> String.downcase(Path.extname(src))
      end,
      :font_resource_collision
    )
  end

  defp plan_font_copies(fonts, dest_fun, collision_tag) do
    copies = fonts |> Enum.uniq() |> Enum.map(fn src -> {src, dest_fun.(src)} end)

    collision =
      copies
      |> Enum.group_by(fn {_src, dest} -> dest end)
      |> Enum.find(fn {_dest, list} -> length(list) > 1 end)

    case collision do
      nil -> {:ok, copies}
      {dest, list} -> {:error, {collision_tag, dest, Enum.map(list, fn {src, _} -> src end)}}
    end
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
        # Insert before the closing </dict></plist>. The replacement is a
        # function (not a string) so that `\N` sequences in a font basename
        # — e.g. a file literally named `x\1y.ttf` — are emitted verbatim
        # rather than interpreted as regex backreferences, which would splice
        # the captured closing tags into the middle of the array.
        String.replace(
          plist,
          ~r{(\n\s*</dict>\s*</plist>\s*)$},
          fn closing -> "\n\t<key>UIAppFonts</key>\n#{array}#{closing}" end
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
    # Function replacement (not a string) so `\N` in a font basename is not
    # interpreted as a backreference — see merge_ui_app_fonts/2 for details.
    String.replace(
      plist,
      ~r{<key>UIAppFonts</key>\s*<array>.*?</array>}s,
      fn _matched -> "<key>UIAppFonts</key>\n#{array}" end
    )
  end

  defp render_ui_app_fonts_array(basenames) do
    items = Enum.map_join(basenames, "\n", &"\t\t<string>#{&1}</string>")
    "\t<array>\n#{items}\n\t</array>"
  end
end
