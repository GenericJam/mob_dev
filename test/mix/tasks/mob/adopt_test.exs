defmodule Mix.Tasks.Mob.AdoptTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  alias Mix.Tasks.Mob.Adopt

  @phx_mix_exs """
  defmodule Test.MixProject do
    use Mix.Project

    def project do
      [app: :test, version: "0.1.0", elixir: "~> 1.15", deps: deps()]
    end

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

  describe "info/2" do
    test "composes the expected sub-tasks" do
      info = Adopt.info([], nil)

      assert info.composes == [
               "mob.adopt.deps",
               "mob.adopt.bridge",
               "mob.adopt.screen",
               "mob.adopt.mob_app",
               "mob.adopt.mob_exs",
               "mob.adopt.native",
               "mob.adopt.finalize"
             ]
    end

    test "defaults to both platforms on" do
      info = Adopt.info([], nil)
      assert info.defaults[:ios] == true
      assert info.defaults[:android] == true
    end
  end

  describe "validate_platforms!/1" do
    test "raises when both --no-ios and --no-android are passed" do
      assert_raise Mix.Error, ~r/Cannot pass both --no-ios and --no-android/, fn ->
        blessed_project()
        |> Igniter.compose_task("mob.adopt", ["--no-ios", "--no-android"])
      end
    end
  end

  describe "igniter/1 guard gate" do
    test "composes the sub-installers when the host matches the blessed shape" do
      igniter =
        blessed_project()
        |> Igniter.compose_task("mob.adopt", ["--no-ios"])

      assert igniter.issues == []
      assert Enum.member?(Rewrite.paths(igniter.rewrite), "lib/test/mob_app.ex")
      assert Enum.member?(Rewrite.paths(igniter.rewrite), "lib/test/mob_screen.ex")
    end

    test "refuses without composing when the host is not a Phoenix project" do
      igniter =
        test_project()
        |> Igniter.compose_task("mob.adopt", ["--no-ios"])

      assert Enum.any?(igniter.issues, &String.contains?(&1, "requires a Phoenix project"))
      refute Enum.member?(Rewrite.paths(igniter.rewrite), "lib/test/mob_app.ex")
    end
  end
end
