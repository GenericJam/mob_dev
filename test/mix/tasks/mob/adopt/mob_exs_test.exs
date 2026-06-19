defmodule Mix.Tasks.Mob.Adopt.MobExsTest do
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
    files =
      Map.merge(
        %{
          "mix.exs" => @phx_mix_exs,
          "assets/js/app.js" => @stock_app_js,
          "lib/test_web/components/layouts/root.html.heex" => @stock_root_heex
        },
        extra_files
      )

    test_project(files: files)
  end

  describe "mob.adopt.mob_exs" do
    test "creates mob.exs" do
      blessed_project()
      |> Igniter.compose_task("mob.adopt.mob_exs")
      |> assert_creates("mob.exs")
    end

    test "mob.exs content has the expected structure" do
      igniter =
        blessed_project()
        |> Igniter.compose_task("mob.adopt.mob_exs")

      source = Rewrite.source!(igniter.rewrite, "mob.exs")
      content = Rewrite.Source.get(source, :content)

      assert content =~ "import Config"
      assert content =~ "config :mob_dev"
      assert content =~ "mob_dir:"
      assert content =~ "elixir_lib:"
    end

    # `igniter.assigns[:test_files]` is the Igniter test struct, not a
    # Phoenix LiveView socket — `:plug_test` opts these out of the
    # `AvoidSocketAssignsInTest` LiveView check.
    @tag :plug_test
    test "patches .gitignore to ignore mob.exs" do
      igniter =
        blessed_project(%{".gitignore" => "/_build\n/deps\n"})
        |> Igniter.compose_task("mob.adopt.mob_exs")
        |> apply_igniter!()

      # Dotfiles are filtered out by the post-apply `**/*.*` include_glob
      # in `Igniter.Test.simulate_write/1`, so they only live in
      # `assigns[:test_files]` after apply. Read from there.
      content = igniter.assigns[:test_files][".gitignore"]
      assert content =~ "mob.exs"
    end

    @tag :plug_test
    test "is idempotent on .gitignore patches" do
      base =
        blessed_project(%{".gitignore" => "/_build\n/deps\n"})
        |> Igniter.compose_task("mob.adopt.mob_exs")
        |> apply_igniter!()

      first_content = base.assigns[:test_files][".gitignore"]

      after_second =
        base
        |> Igniter.compose_task("mob.adopt.mob_exs")
        |> apply_igniter!()

      assert after_second.assigns[:test_files][".gitignore"] == first_content
    end

    test "refuses on a non-Phoenix host (standalone guard)" do
      igniter =
        test_project()
        |> Igniter.compose_task("mob.adopt.mob_exs")

      assert Enum.any?(igniter.issues, &String.contains?(&1, "requires a Phoenix project"))
    end
  end
end
