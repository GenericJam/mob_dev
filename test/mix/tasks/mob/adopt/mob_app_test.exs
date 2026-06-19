defmodule Mix.Tasks.Mob.Adopt.MobAppTest do
  use ExUnit.Case, async: true

  import Igniter.Test

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

  # Thin mode only requires the `:phoenix` dep — no app.js / layout / SQLite shape.
  defp phoenix_project do
    test_project(files: %{"mix.exs" => @phx_mix_exs})
  end

  describe "mob.adopt.mob_app (default — LiveView flavour)" do
    test "generates LV-flavoured mob_app.ex that boots the host Phoenix app" do
      igniter =
        blessed_project()
        |> Igniter.compose_task("mob.adopt.mob_app")

      content =
        Rewrite.source!(igniter.rewrite, "lib/test/mob_app.ex")
        |> Rewrite.Source.get(:content)

      assert content =~ "defmodule Test.MobApp"
      assert content =~ "{:ok, _} = Application.ensure_all_started(:test)"
      assert content =~ "Mob.NativeLogger.install()"
      assert content =~ "Ecto.Migrator.run"
    end

    test "endpoint config uses a safe `live_reload` value (regression)" do
      # `live_reload: false` crashes `Phoenix.LiveReloader.call/2` because
      # it does `config[:patterns]` on the value, and `Access` has no
      # clause for booleans. Phoenix's contract is keyword-list-or-unset,
      # so we ship `[patterns: []]` (active plug, no patterns to match).
      igniter =
        blessed_project()
        |> Igniter.compose_task("mob.adopt.mob_app")

      content =
        Rewrite.source!(igniter.rewrite, "lib/test/mob_app.ex")
        |> Rewrite.Source.get(:content)

      assert content =~ "live_reload: [patterns: []]"
      refute content =~ "live_reload: false"
    end

    test "writes src/<app>.erl bootstrap" do
      igniter =
        blessed_project()
        |> Igniter.compose_task("mob.adopt.mob_app")

      erl = Rewrite.source!(igniter.rewrite, "src/test.erl") |> Rewrite.Source.get(:content)
      assert erl =~ "test"
    end

    test "patches mix.exs with erlc_paths and erlc_options" do
      igniter =
        blessed_project()
        |> Igniter.compose_task("mob.adopt.mob_app")

      content = Rewrite.source!(igniter.rewrite, "mix.exs") |> Rewrite.Source.get(:content)
      assert content =~ ~s(erlc_paths: ["src"])
      assert content =~ "erlc_options: [:debug_info]"
    end

    test "refuses on a non-Phoenix host (standalone guard)" do
      igniter =
        test_project()
        |> Igniter.compose_task("mob.adopt.mob_app")

      assert Enum.any?(igniter.issues, &String.contains?(&1, "requires a Phoenix project"))
    end
  end

  describe "mob.adopt.mob_app --no-live-view (thin-client flavour)" do
    test "generates thin mob_app.ex using `use Mob.App` without ensure_all_started" do
      igniter =
        phoenix_project()
        |> Igniter.compose_task("mob.adopt.mob_app", ["--no-live-view"])

      content =
        Rewrite.source!(igniter.rewrite, "lib/test/mob_app.ex")
        |> Rewrite.Source.get(:content)

      assert content =~ "defmodule Test.MobApp"
      assert content =~ "use Mob.App"
      assert content =~ "def navigation"
      assert content =~ "def on_start"
      assert content =~ "Mob.Screen.start_root(Test.MobScreen)"
      assert content =~ "Mob.DNS.configure_pure_beam"

      # Crucially, the thin variant does NOT actually boot the host
      # Phoenix app or run Ecto migrations on-device. (The docstring
      # mentions both in prose, but the code body does not.)
      refute content =~ "{:ok, _} = Application.ensure_all_started"
      refute content =~ "Ecto.Migrator.run"
    end
  end
end
