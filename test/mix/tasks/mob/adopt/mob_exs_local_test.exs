defmodule Mix.Tasks.Mob.Adopt.MobExsLocalTest do
  # async: false — `--local` resolves the checkouts from the MOB_DIR /
  # MOB_DEV_DIR env vars, which are process-global.
  use ExUnit.Case, async: false

  import Igniter.Test

  @phx_mix_exs """
  defmodule Test.MixProject do
    use Mix.Project
    def project, do: [app: :test, version: "0.1.0", elixir: "~> 1.15", deps: deps()]
    def application, do: [extra_applications: [:logger]]
    defp deps, do: [{:phoenix, "~> 1.7"}, {:ecto_sql, "~> 3.10"}, {:ecto_sqlite3, "~> 0.18"}]
  end
  """

  setup do
    dir = Path.join(System.tmp_dir!(), "mob_adopt_local_#{System.unique_integer([:positive])}")
    mob_dir = Path.join(dir, "checkout/mob")
    File.mkdir_p!(mob_dir)

    env = %{"MOB_DIR" => mob_dir, "MOB_DEV_DIR" => Path.join(dir, "checkout/mob_dev")}
    previous = Map.new(env, fn {var, _} -> {var, System.get_env(var)} end)
    System.put_env(env)

    on_exit(fn ->
      Enum.each(previous, fn
        {var, nil} -> System.delete_env(var)
        {var, value} -> System.put_env(var, value)
      end)

      File.rm_rf!(dir)
    end)

    {:ok, dir: dir, mob_dir: mob_dir}
  end

  # MOB-286: `--local` used to bake the absolute checkout path into mob.exs —
  # the file that also carries plugin activation and must be committed.
  test "--local keeps the absolute mob_dir out of mob.exs and in mob.local.exs", %{
    dir: dir,
    mob_dir: mob_dir
  } do
    igniter =
      test_project(
        files: %{
          "mix.exs" => @phx_mix_exs,
          "assets/js/app.js" => """
          import {Socket} from "phoenix"
          let liveSocket = new LiveSocket("/live", Socket, {hooks: {}})
          """,
          "lib/test_web/components/layouts/root.html.heex" =>
            "<html>\n  <body>\n    Hello\n  </body>\n</html>\n"
        }
      )
      |> Igniter.compose_task("mob.adopt.mob_exs", ["--local"])

    content = fn path ->
      igniter.rewrite |> Rewrite.source!(path) |> Rewrite.Source.get(:content)
    end

    mob_exs = content.("mob.exs")

    refute mob_exs =~ mob_dir
    refute mob_exs =~ to_string(:code.lib_dir(:elixir))

    File.write!(Path.join(dir, "mob.exs"), mob_exs)
    File.write!(Path.join(dir, "mob.local.exs"), content.("mob.local.exs"))

    assert Config.Reader.read!(Path.join(dir, "mob.exs"))[:mob_dev][:mob_dir] == mob_dir
  end
end
