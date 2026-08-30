defmodule MobDev.ToolchainPackageTest do
  use ExUnit.Case, async: false

  test "packed Hex artifact compiles and retains exact Zig preflights" do
    root = Path.expand("../..", __DIR__)

    temp =
      Path.join(
        System.tmp_dir!(),
        "mob_dev_toolchain_package_#{System.unique_integer([:positive])}"
      )

    package = Path.join(temp, "package")
    build = Path.join(temp, "build")
    on_exit(fn -> File.rm_rf!(temp) end)

    {pack_output, pack_status} =
      System.cmd("mix", ["hex.build", "--unpack", "--output", package],
        cd: root,
        stderr_to_stdout: true
      )

    assert pack_status == 0, pack_output
    refute File.exists?(Path.join(package, ".tool-versions"))
    File.cp!(Path.join(root, "mix.lock"), Path.join(package, "mix.lock"))
    link_compiled_dependencies(root, build)

    env = [
      {"MIX_ENV", "prod"},
      {"MIX_BUILD_PATH", build},
      {"MIX_DEPS_PATH", Path.join(root, "deps")}
    ]

    {compile_output, compile_status} =
      System.cmd("mix", ["compile"],
        cd: package,
        env: env,
        stderr_to_stdout: true
      )

    assert compile_status == 0, compile_output

    probe = ~S'''
    beam = :code.which(MobDev.Toolchain) |> List.to_string()
    true = String.contains?(beam, "mob_dev_toolchain_package_")

    version = MobDev.Toolchain.required_zig_version()
    exact = MobDev.Toolchain.zig_status_from_result({version <> "\n", 0})
    mismatch = MobDev.Toolchain.zig_status_from_result({"0.15.2\n", 0})
    failed = MobDev.Toolchain.zig_status_from_result({"dyld failure\n", 127})

    {:ok, "zig", ^version, nil} = Mix.Tasks.Mob.Doctor.__zig_check_result__(exact)
    {:fail, "zig", _, _} = Mix.Tasks.Mob.Doctor.__zig_check_result__(mismatch)
    {:fail, "zig", _, _} = Mix.Tasks.Mob.Doctor.__zig_check_result__(failed)

    :run_zig = MobDev.NativeBuild.zig_build_plan(true, exact, false)
    {:zig_required, ^mismatch} = MobDev.NativeBuild.zig_build_plan(true, mismatch, true)
    {:zig_required, ^failed} = MobDev.NativeBuild.zig_build_plan(true, failed, true)
    IO.puts("packed_toolchain_ok=#{version}")
    '''

    {probe_output, probe_status} =
      System.cmd(
        "mix",
        ["run", "--no-compile", "--no-start", "-e", probe],
        cd: package,
        env: env,
        stderr_to_stdout: true
      )

    assert probe_status == 0, probe_output
    assert probe_output =~ "packed_toolchain_ok=#{MobDev.Toolchain.required_zig_version()}"
  end

  defp link_compiled_dependencies(root, build) do
    build_lib = Path.join(build, "lib")
    File.mkdir_p!(build_lib)

    root
    |> Path.join("_build/test/lib/*")
    |> Path.wildcard()
    |> Enum.reject(&(Path.basename(&1) == "mob_dev"))
    |> Enum.each(fn dependency ->
      File.ln_s!(dependency, Path.join(build_lib, Path.basename(dependency)))
    end)
  end
end
