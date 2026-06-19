defmodule Mix.Tasks.Mob.Adopt.DepsTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  @phx_mix_exs """
  defmodule Test.MixProject do
    use Mix.Project
    def project, do: [app: :test, version: "0.1.0", elixir: "~> 1.15", deps: deps()]
    def application, do: [extra_applications: [:logger]]
    defp deps,
      do: [
        {:phoenix, "~> 1.7"},
        {:ecto_sql, "~> 3.10"},
        {:ecto_sqlite3, "~> 0.18"}
      ]
  end
  """

  @stock_app_js """
  import {Socket} from "phoenix"
  let liveSocket = new LiveSocket("/live", Socket, {hooks: {}})
  """

  @stock_root_heex """
  <html>
    <body>
      Hello
    </body>
  </html>
  """

  defp blessed_project do
    test_project(
      files: %{
        "mix.exs" => @phx_mix_exs,
        "assets/js/app.js" => @stock_app_js,
        "lib/test_web/components/layouts/root.html.heex" => @stock_root_heex
      }
    )
  end

  describe "mob.adopt.deps" do
    test "adds :mob and :mob_dev to mix.exs" do
      igniter =
        blessed_project()
        |> Igniter.compose_task("mob.adopt.deps")

      source = Rewrite.source!(igniter.rewrite, "mix.exs")
      content = Rewrite.Source.get(source, :content)

      assert content =~ ":mob"
      assert content =~ ":mob_dev"
      assert content =~ "only: :dev"
    end

    test "is idempotent on a second run" do
      igniter =
        blessed_project()
        |> Igniter.compose_task("mob.adopt.deps")
        |> apply_igniter!()
        |> Igniter.compose_task("mob.adopt.deps")

      assert_unchanged(igniter)
    end

    test "refuses on a non-Phoenix host (standalone guard)" do
      igniter =
        test_project()
        |> Igniter.compose_task("mob.adopt.deps")

      assert Enum.any?(igniter.issues, &String.contains?(&1, "requires a Phoenix project"))
      assert_unchanged(igniter)
    end
  end
end
