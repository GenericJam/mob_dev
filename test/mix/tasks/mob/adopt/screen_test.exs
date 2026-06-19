defmodule Mix.Tasks.Mob.Adopt.ScreenTest do
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

  describe "mob.adopt.screen" do
    test "creates lib/<app>/mob_screen.ex reading host URL from app config" do
      igniter =
        blessed_project()
        |> Igniter.compose_task("mob.adopt.screen")

      source = Rewrite.source!(igniter.rewrite, "lib/test/mob_screen.ex")
      content = Rewrite.Source.get(source, :content)

      assert content =~ "Test.MobScreen"
      assert content =~ "Application.get_env(:mob, :host_url"
      assert content =~ ~s("http://127.0.0.1:4000/")
      refute content =~ "Mob.LiveView.local_url"
    end

    test "is idempotent" do
      igniter =
        blessed_project()
        |> Igniter.compose_task("mob.adopt.screen")
        |> apply_igniter!()
        |> Igniter.compose_task("mob.adopt.screen")

      assert_unchanged(igniter)
    end

    test "--host-url writes `config :mob, host_url: URL` to config/config.exs" do
      igniter =
        blessed_project()
        |> Igniter.compose_task("mob.adopt.screen", ["--host-url", "https://my.fly.dev/"])

      # The mob_screen.ex itself remains URL-agnostic — it reads the config.
      mob_screen = Rewrite.source!(igniter.rewrite, "lib/test/mob_screen.ex")
      refute Rewrite.Source.get(mob_screen, :content) =~ "https://my.fly.dev/"

      # config/config.exs gets the new key.
      config = Rewrite.source!(igniter.rewrite, "config/config.exs")
      content = Rewrite.Source.get(config, :content)
      assert content =~ "config :mob"
      assert content =~ ~s(host_url: "https://my.fly.dev/")
    end

    test "refuses on a non-Phoenix host (standalone guard)" do
      igniter =
        test_project()
        |> Igniter.compose_task("mob.adopt.screen")

      assert Enum.any?(igniter.issues, &String.contains?(&1, "requires a Phoenix project"))
    end
  end
end
