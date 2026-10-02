defmodule MobDev.DeployerSimRuntimeTest do
  @moduledoc """
  An iOS-simulator deploy writes the BEAMs into the runtime dir the app boots
  from (MOB-230), with `restart: false` — the options the dist fast path
  persists with after a hot load. Before MOB-118 the sim fast path wrote
  nothing, so a `simctl terminate` + `launch` silently ran the native build's
  code.

  async: false — MOB_SIM_RUNTIME_DIR is process-global.
  """
  use ExUnit.Case, async: false

  alias MobDev.{Deployer, Device}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    previous = System.get_env("MOB_SIM_RUNTIME_DIR")
    runtime = Path.join(tmp, "runtime")
    File.mkdir_p!(runtime)
    System.put_env("MOB_SIM_RUNTIME_DIR", runtime)

    on_exit(fn ->
      if previous,
        do: System.put_env("MOB_SIM_RUNTIME_DIR", previous),
        else: System.delete_env("MOB_SIM_RUNTIME_DIR")
    end)

    {:ok, runtime: runtime}
  end

  test "a non-restarting sim deploy lands the compiled BEAMs in <runtime>/<app>", %{
    runtime: runtime
  } do
    sim = %Device{
      name: "sim",
      serial: "0A1B2C3D-0000-0000-0000-000000000000",
      platform: :ios,
      type: :simulator
    }

    app = to_string(Mix.Project.config()[:app])

    ExUnit.CaptureIO.capture_io(fn ->
      assert {[_], [], []} =
               Deployer.deploy_all(
                 devices: [sim],
                 platforms: [:ios],
                 restart: false,
                 force_fs: true
               )
    end)

    app_dir = Path.join(runtime, app)
    compiled = Path.join(Mix.Project.compile_path(), "Elixir.MobDev.Deployer.beam")
    deployed = Path.join(app_dir, "Elixir.MobDev.Deployer.beam")

    assert File.read!(deployed) == File.read!(compiled)
    assert File.exists?(Path.join(app_dir, "#{app}.app"))
  end
end
