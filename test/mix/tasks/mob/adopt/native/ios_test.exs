defmodule Mix.Tasks.Mob.Adopt.Native.IosTest do
  use ExUnit.Case, async: false

  import Igniter.Test

  setup do
    cwd = File.cwd!()
    tmp = System.tmp_dir!() |> Path.join("mob_adopt_ios_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    File.cd!(tmp)
    on_exit(fn -> File.cd!(cwd) end)
    {:ok, tmp: tmp}
  end

  describe "mob.adopt.native.ios" do
    test "creates Info.plist and beam_main.m" do
      igniter =
        test_project()
        |> Igniter.compose_task("mob.adopt.native.ios")
        |> apply_igniter!()

      assert Rewrite.has_source?(igniter.rewrite, "ios/Info.plist")
      assert Rewrite.has_source?(igniter.rewrite, "ios/beam_main.m")
    end
  end

  describe "mob.adopt.native.ios --python" do
    # `maybe_apply_python/3` shells out to MobDev.Adopt.Generator.apply_python_patches/2,
    # which mutates the real cwd (predates the Igniter file API). The setup
    # block already cd's into a tmp dir, so write a real mix.exs there for it
    # to patch, then assert the on-disk side effects.
    test "applies Pythonx wiring (mix.exs dep + python_paths.ex)", %{tmp: tmp} do
      File.write!(Path.join(tmp, "mix.exs"), """
      defmodule Test.MixProject do
        use Mix.Project
        def project, do: [app: :test, version: "0.1.0", deps: deps()]
        defp deps do
          [{:phoenix, "~> 1.7"}]
        end
      end
      """)

      igniter =
        test_project()
        |> Igniter.compose_task("mob.adopt.native.ios", ["--python"])

      assert Enum.any?(igniter.notices, &String.contains?(&1, "Pythonx wiring"))

      assert File.exists?(Path.join(tmp, "lib/test/python_paths.ex"))
      assert File.read!(Path.join(tmp, "mix.exs")) =~ ~s({:pythonx, "~> 0.4"})
    end

    test "no Pythonx wiring without --python" do
      igniter =
        test_project()
        |> Igniter.compose_task("mob.adopt.native.ios")

      refute Enum.any?(igniter.notices, &String.contains?(&1, "Pythonx wiring"))
    end
  end
end
