defmodule MobDev.PathsTest do
  use ExUnit.Case, async: false

  alias MobDev.Paths

  setup do
    # Each test runs in its own tmp project dir so build.sh detection is
    # deterministic and parallelisable.
    tmp =
      Path.join(System.tmp_dir!(), "mob_paths_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(tmp, "ios"))

    on_exit(fn ->
      File.rm_rf!(tmp)
      System.delete_env("MOB_SIM_RUNTIME_DIR")
    end)

    {:ok, project: tmp}
  end

  describe "default_runtime_dir/0" do
    test "is under ~/.mob/runtime/ios-sim" do
      assert Paths.default_runtime_dir() ==
               Path.join([System.user_home!(), ".mob", "runtime", "ios-sim"])
    end
  end

  describe "legacy_tmp_path/0" do
    test "is /tmp/otp-ios-sim" do
      assert Paths.legacy_tmp_path() == "/tmp/otp-ios-sim"
    end
  end

  describe "build_sh_aware?/1" do
    test "false when build.sh is missing", %{project: project} do
      refute Paths.build_sh_aware?(project)
    end

    test "false when build.sh exists but doesn't reference the env var", %{project: project} do
      File.write!(Path.join([project, "ios", "build.sh"]), "echo /tmp/otp-ios-sim\n")
      refute Paths.build_sh_aware?(project)
    end

    test "true when build.sh contains MOB_SIM_RUNTIME_DIR", %{project: project} do
      File.write!(
        Path.join([project, "ios", "build.sh"]),
        "RUNTIME_DIR=\"${MOB_SIM_RUNTIME_DIR:-$HOME/.mob/runtime/ios-sim}\"\n"
      )

      assert Paths.build_sh_aware?(project)
    end
  end

  describe "sim_runtime_dir/1" do
    test "MOB_SIM_RUNTIME_DIR env wins over everything", %{project: project} do
      System.put_env("MOB_SIM_RUNTIME_DIR", "/somewhere/else")

      try do
        # Even with a build.sh-aware project, the env var wins.
        File.write!(Path.join([project, "ios", "build.sh"]), "MOB_SIM_RUNTIME_DIR\n")
        assert Paths.sim_runtime_dir(project_dir: project) == "/somewhere/else"
      after
        System.delete_env("MOB_SIM_RUNTIME_DIR")
      end
    end

    test "new default when build.sh is aware", %{project: project} do
      System.delete_env("MOB_SIM_RUNTIME_DIR")
      File.write!(Path.join([project, "ios", "build.sh"]), "MOB_SIM_RUNTIME_DIR\n")
      assert Paths.sim_runtime_dir(project_dir: project) == Paths.default_runtime_dir()
    end

    test "legacy /tmp when build.sh is missing or unaware", %{project: project} do
      System.delete_env("MOB_SIM_RUNTIME_DIR")
      assert Paths.sim_runtime_dir(project_dir: project) == Paths.legacy_tmp_path()

      # Now create an unaware build.sh — still legacy.
      File.write!(Path.join([project, "ios", "build.sh"]), "echo old\n")
      assert Paths.sim_runtime_dir(project_dir: project) == Paths.legacy_tmp_path()
    end
  end
end
