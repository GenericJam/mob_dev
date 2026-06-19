defmodule MobDev.AdoptGuardTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  alias MobDev.AdoptGuard

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

  @phx_postgres_mix_exs """
  defmodule Test.MixProject do
    use Mix.Project
    def project, do: [app: :test, version: "0.1.0", elixir: "~> 1.15", deps: deps()]
    def application, do: [extra_applications: [:logger]]
    defp deps,
      do: [
        {:phoenix, "~> 1.7"},
        {:ecto_sql, "~> 3.10"},
        {:postgrex, ">= 0.0.0"}
      ]
  end
  """

  @phx_no_ecto_mix_exs """
  defmodule Test.MixProject do
    use Mix.Project
    def project, do: [app: :test, version: "0.1.0", elixir: "~> 1.15", deps: deps()]
    def application, do: [extra_applications: [:logger]]
    defp deps, do: [{:phoenix, "~> 1.7"}]
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

  # Build a project from the blessed set minus the given keys. Used to
  # test "missing X" cases — building without it from the start is the
  # only reliable way to drop a file (deleting from `test_files` after
  # `test_project` still leaves it in `rewrite.sources` via the
  # `**/*.*` include_glob).
  defp project_without(keys) do
    test_project(files: Map.drop(blessed_files(), keys))
  end

  describe "umbrella" do
    test "refused when Mix.Project.umbrella? returns true" do
      igniter =
        blessed_project()
        |> Igniter.assign(:umbrella?, true)
        |> AdoptGuard.check(:live_view)

      assert Enum.any?(igniter.issues, &String.contains?(&1, "umbrella applications"))
    end
  end

  describe "Phoenix dep" do
    test "refused when :phoenix not in deps" do
      igniter =
        test_project()
        |> AdoptGuard.check(:thin)

      assert Enum.any?(igniter.issues, &String.contains?(&1, "requires a Phoenix project"))
    end
  end

  describe "LV-mode shape (:live_view)" do
    test "refused without assets/js/app.js" do
      igniter =
        project_without(["assets/js/app.js"])
        |> AdoptGuard.check(:live_view)

      assert Enum.any?(
               igniter.issues,
               &(String.contains?(&1, "requires assets/js/app.js") and
                   String.contains?(&1, "--no-live-view"))
             )
    end

    test "refused when app.js has no `new LiveSocket(`" do
      igniter =
        blessed_project(%{"assets/js/app.js" => "// custom bundle, no LiveSocket\n"})
        |> AdoptGuard.check(:live_view)

      assert Enum.any?(igniter.issues, &String.contains?(&1, "stock `new LiveSocket"))
    end

    test "refused without root.html.heex" do
      igniter =
        project_without(["lib/test_web/components/layouts/root.html.heex"])
        |> AdoptGuard.check(:live_view)

      assert Enum.any?(igniter.issues, &String.contains?(&1, "requires a root layout"))
    end

    test "refused when root.html.heex has no <body>" do
      igniter =
        blessed_project(%{
          "lib/test_web/components/layouts/root.html.heex" => "<div>nothing here</div>\n"
        })
        |> AdoptGuard.check(:live_view)

      assert Enum.any?(igniter.issues, &String.contains?(&1, "requires a `<body>` tag"))
    end

    test "refused when host has no Ecto Repo (no :ecto_sql in deps)" do
      igniter =
        blessed_project(%{"mix.exs" => @phx_no_ecto_mix_exs})
        |> AdoptGuard.check(:live_view)

      assert Enum.any?(igniter.issues, &String.contains?(&1, "no Ecto Repo"))
    end

    test "refused when host Repo uses Postgres (not SQLite)" do
      igniter =
        blessed_project(%{"mix.exs" => @phx_postgres_mix_exs})
        |> AdoptGuard.check(:live_view)

      assert Enum.any?(
               igniter.issues,
               &(String.contains?(&1, "assumes SQLite") and String.contains?(&1, "Postgres"))
             )
    end

    test "blessed shape passes" do
      igniter = blessed_project() |> AdoptGuard.check(:live_view)
      assert igniter.issues == []
    end
  end

  describe "thin-mode (:thin)" do
    test "passes without app.js / root.html.heex when project has :phoenix" do
      igniter =
        test_project(files: %{"mix.exs" => @phx_mix_exs})
        |> AdoptGuard.check(:thin)

      assert igniter.issues == []
    end

    test "passes against a Postgres host (no on-device DB in thin mode)" do
      igniter =
        test_project(files: %{"mix.exs" => @phx_postgres_mix_exs})
        |> AdoptGuard.check(:thin)

      assert igniter.issues == []
    end

    test "passes against a no-Ecto host (thin mode doesn't need a Repo)" do
      igniter =
        test_project(files: %{"mix.exs" => @phx_no_ecto_mix_exs})
        |> AdoptGuard.check(:thin)

      assert igniter.issues == []
    end
  end
end
