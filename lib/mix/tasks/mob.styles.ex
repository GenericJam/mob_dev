defmodule Mix.Tasks.Mob.Styles do
  @shortdoc "List the project's style packages and the active default"

  @moduledoc """
  Lists the activated style packages (MOB_STYLES.md, tokens-only tier) with
  their themes, the fonts each bundles (`assets: %{fonts: [...]}`), and which
  one `config :mob, :default_style` selects.

      mix mob.styles
  """

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.config")

    styles = MobDev.Style.activated()
    default = MobDev.Style.default_style()

    if styles == [] do
      Mix.shell().info("""
        No style packages activated. The app renders mob's neutral baseline
        (or its own `use Mob.App, theme:`). Activate one in mob.exs:

          config :mob, :styles, [:mob_themes]
          config :mob, :default_style, :mob_themes
      """)
    else
      Mix.shell().info("\n  STYLE             THEME                       DEFAULT")
      Mix.shell().info("  " <> String.duplicate("─", 60))

      for {dir, manifest} <- styles do
        case MobDev.Style.validate(manifest) do
          {:ok, m} ->
            marker = if m.name == default, do: "  ← default", else: ""

            Mix.shell().info(
              "  #{String.pad_trailing(to_string(m.name), 18)}#{String.pad_trailing(inspect(m.theme), 28)}#{marker}"
            )

            print_fonts(dir, m)

          {:error, errs} ->
            Mix.shell().error("  #{Path.basename(dir)}: INVALID — #{Enum.join(errs, "; ")}")
        end
      end

      if default != nil and not Enum.any?(styles, fn {_d, m} -> m[:name] == default end) do
        Mix.shell().error(
          "\n  ✗ :default_style #{inspect(default)} is not among the activated styles (build will fail)"
        )
      end

      Mix.shell().info("")
    end
  end

  defp print_fonts(dir, manifest) do
    for rel <- get_in(manifest, [:assets, :fonts]) || [] do
      if File.regular?(Path.join(dir, rel)) do
        Mix.shell().info("    font  #{rel}")
      else
        Mix.shell().error("    font  #{rel}  ✗ missing (build will fail)")
      end
    end
  end
end
