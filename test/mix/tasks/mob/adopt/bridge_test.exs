defmodule Mix.Tasks.Mob.Adopt.BridgeTest do
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

  defp blessed_project(extra_files \\ %{}) do
    test_project(files: Map.merge(blessed_files(), extra_files))
  end

  defp blessed_files do
    %{
      "mix.exs" => @phx_mix_exs,
      "assets/js/app.js" => @stock_app_js,
      "lib/test_web/components/layouts/root.html.heex" => @stock_root_heex
    }
  end

  defp project_without(keys) do
    test_project(files: Map.drop(blessed_files(), keys))
  end

  describe "mob.adopt.bridge (LV mode, blessed shape)" do
    test "injects MobHook into assets/js/app.js" do
      igniter =
        blessed_project()
        |> Igniter.compose_task("mob.adopt.bridge")
        |> apply_igniter!()

      content =
        Rewrite.source!(igniter.rewrite, "assets/js/app.js") |> Rewrite.Source.get(:content)

      assert content =~ "MobHook"
    end

    test "injects bridge element into root.html.heex" do
      igniter =
        blessed_project()
        |> Igniter.compose_task("mob.adopt.bridge")
        |> apply_igniter!()

      content =
        Rewrite.source!(igniter.rewrite, "lib/test_web/components/layouts/root.html.heex")
        |> Rewrite.Source.get(:content)

      assert content =~ ~s(id="mob-bridge")
    end
  end

  describe "mob.adopt.bridge (LV mode, refusal)" do
    test "refuses when assets/js/app.js missing (no warn-and-proceed)" do
      igniter =
        project_without(["assets/js/app.js"])
        |> Igniter.compose_task("mob.adopt.bridge")

      assert Enum.any?(
               igniter.issues,
               &(String.contains?(&1, "requires assets/js/app.js") and
                   String.contains?(&1, "--no-live-view"))
             )

      # No warning fallback any more.
      refute Enum.any?(igniter.warnings, &String.contains?(&1, "MobHook"))
    end

    test "refuses when root.html.heex missing" do
      igniter =
        project_without(["lib/test_web/components/layouts/root.html.heex"])
        |> Igniter.compose_task("mob.adopt.bridge")

      assert Enum.any?(igniter.issues, &String.contains?(&1, "requires a root layout"))
    end
  end

  describe "mob.adopt.bridge --no-live-view" do
    test "skips patches with a notice; files untouched" do
      # apply_igniter! resets `notices` to [] during simulate_write, so we
      # inspect the un-applied igniter for notices, then check file content.
      igniter =
        blessed_project()
        |> Igniter.compose_task("mob.adopt.bridge", ["--no-live-view"])

      assert Enum.any?(igniter.notices, &String.contains?(&1, "skipped (--no-live-view)"))

      app_js_source = Rewrite.source!(igniter.rewrite, "assets/js/app.js")
      refute Rewrite.Source.get(app_js_source, :content) =~ "MobHook"

      heex_source =
        Rewrite.source!(igniter.rewrite, "lib/test_web/components/layouts/root.html.heex")

      refute Rewrite.Source.get(heex_source, :content) =~ "mob-bridge"
    end
  end
end
