defmodule MobDev.Plugin.Report do
  @moduledoc """
  Pure transforms behind `mix mob.plugins`: turn discovered deps + the
  activation list into report rows, and render them as a table.

  Kept separate from the Mix task (which does the filesystem/config I/O) so
  the classification and formatting are unit-testable without a project on disk.
  """

  alias MobDev.Plugin.Manifest

  @typedoc "An app and its loaded manifest (nil = no manifest / tier 0)."
  @type dep :: {atom(), map() | nil}

  @typedoc "One row of `mix mob.plugins` output."
  @type row :: %{
          name: atom(),
          tier: 0..4,
          hot_pushable: true | false | :partial,
          status: :activated | :installed,
          manifest?: boolean(),
          description: String.t() | nil
        }

  @doc """
  Builds sorted report rows from all deps and the activated-plugin list.

  A dep is a plugin row if it ships a manifest *or* is named in
  `config :mob, :plugins`. A tier-0 plugin (no manifest) therefore only
  appears once activated — otherwise it's indistinguishable from an ordinary
  library dependency. Status is `:activated` when in the list, else
  `:installed` (present in deps, not yet activated).
  """
  @spec rows([dep()], [atom()]) :: [row()]
  def rows(deps, activated) do
    deps
    |> Enum.filter(fn {name, manifest} -> manifest != nil or name in activated end)
    |> Enum.map(fn {name, manifest} ->
      %{
        name: name,
        tier: Manifest.tier(manifest),
        hot_pushable: Manifest.hot_pushable(manifest),
        status: if(name in activated, do: :activated, else: :installed),
        manifest?: manifest != nil,
        description: manifest && Map.get(manifest, :description)
      }
    end)
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  Renders rows as a human-readable table (or a friendly empty message).
  """
  @spec render([row()]) :: String.t()
  def render([]) do
    "No mob plugins found.\n\n" <>
      "A plugin appears here once it ships a priv/mob_plugin.exs manifest, or\n" <>
      "is activated in mob.exs via `config :mob, :plugins, [...]`."
  end

  def render(rows) do
    header = "  " <> pad("PLUGIN", 26) <> pad("TIER", 8) <> pad("HOT-PUSH", 10) <> "STATUS"
    lines = Enum.map(rows, &render_row/1)

    ([header, "  " <> String.duplicate("─", 58)] ++ lines ++ ["", legend(rows)])
    |> Enum.join("\n")
  end

  defp render_row(row) do
    status =
      case row.status do
        :activated -> "activated"
        :installed -> "installed (not activated)"
      end

    note = if row.manifest?, do: "", else: "  — no manifest (regular dep)"

    "  " <>
      pad(to_string(row.name), 26) <>
      pad("tier #{row.tier}", 8) <>
      pad(hot_push(row.hot_pushable), 10) <>
      status <> note
  end

  defp hot_push(true), do: "yes"
  defp hot_push(false), do: "no"
  defp hot_push(:partial), do: "partial"

  defp legend(rows) do
    not_activated = Enum.any?(rows, &(&1.status == :installed))

    base =
      "tier 0 = pure Elixir · 1 = NIF · 2 = component · 3 = screens · 4 = sub-app"

    if not_activated do
      base <>
        "\nInstalled-but-not-activated plugins contribute nothing until added to\n" <>
        "`config :mob, :plugins` in mob.exs."
    else
      base
    end
  end

  defp pad(s, n), do: String.pad_trailing(s, n)
end
