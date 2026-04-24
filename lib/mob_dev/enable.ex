defmodule MobDev.Enable do
  @moduledoc """
  Pure helpers for `mix mob.enable` — extracted for testability.
  """

  @mob_hook_js ~S"""
  // MobHook — Mob LiveView bridge. Added by `mix mob.enable liveview`.
  // Exposes window.mob.send / window.mob.onMessage using LiveView pushEvent /
  // handleEvent so the same JS API works in both WebView and LiveView mode.
  const MobHook = {
    mounted() {
      window.mob = {
        send: (data) => this.pushEvent("mob_message", data),
        onMessage: (handler) => this.handleEvent("mob_push", handler),
        _dispatch: () => {}
      }
    }
  }
  """

  @doc """
  Returns the MobHook JS constant to inject into app.js.
  """
  def mob_hook_js, do: @mob_hook_js

  @doc """
  Injects the MobHook definition and registration into `content` (the full
  text of `assets/js/app.js`).

  - Inserts the hook constant after the last top-level `import` line.
  - Registers `MobHook` in the `hooks:` option passed to `LiveSocket`.

  Returns the patched JS string.
  """
  def inject_mob_hook(content) do
    content
    |> insert_hook_definition()
    |> register_hook_in_live_socket()
  end

  @doc """
  Reads the `app:` atom from the given `mix.exs` path and returns the app
  name as a string, or raises.
  """
  def read_app_name_from(mix_exs_path) do
    case File.read(mix_exs_path) do
      {:ok, content} ->
        case Regex.run(~r/app:\s+:([a-z0-9_]+)/, content) do
          [_, name] -> name
          _ -> raise "Could not read app name from #{mix_exs_path}"
        end

      _ ->
        raise "Could not read #{mix_exs_path}"
    end
  end

  @doc """
  Builds a plist `<key>/<value>` entry for Info.plist injection.

  Options:
    - `type: :bool` — emits `<true/>` or `<false/>` instead of `<string>`
  """
  def build_plist_entry(key, value, opts \\ []) do
    if opts[:type] == :bool do
      "\t<key>#{key}</key>\n\t<#{value}/>"
    else
      "\t<key>#{key}</key>\n\t<string>#{value}</string>"
    end
  end

  # ── Private ───────────────────────────────────────────────────────────────

  defp insert_hook_definition(content) do
    lines = String.split(content, "\n")

    last_import_idx =
      lines
      |> Enum.with_index()
      |> Enum.filter(fn {line, _} -> String.starts_with?(String.trim(line), "import ") end)
      |> Enum.map(fn {_, idx} -> idx end)
      |> List.last()

    insert_at = (last_import_idx || -1) + 1
    hook_lines = String.split(@mob_hook_js, "\n")

    (Enum.take(lines, insert_at) ++ [""] ++ hook_lines ++ Enum.drop(lines, insert_at))
    |> Enum.join("\n")
  end

  defp register_hook_in_live_socket(content) do
    cond do
      String.contains?(content, "hooks: {}") ->
        String.replace(content, "hooks: {}", "hooks: {MobHook}")

      Regex.match?(~r/hooks:\s*\{/, content) ->
        Regex.replace(~r/(hooks:\s*\{)/, content, "\\1MobHook, ", global: false)

      true ->
        Regex.replace(
          ~r/(new LiveSocket\([^)]+)\)/,
          content,
          fn full, prefix ->
            if String.contains?(full, "{") do
              String.replace(full, "}", ", hooks: {MobHook}}", global: false)
            else
              "#{prefix}, {hooks: {MobHook}})"
            end
          end,
          global: false
        )
    end
  end
end
