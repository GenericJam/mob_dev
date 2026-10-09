defmodule Mix.Tasks.Mob.SelftestTest do
  @moduledoc """
  `mix mob.selftest` driven end to end with fake discovery, leases, grants,
  connect and runner: the exit status has to come from the entries the
  runner returns, and the grants have to happen before the app is relaunched.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Mob.Selftest, as: SelftestTask
  alias MobDev.{Device, DeviceLeases}

  @emulator %Device{
    platform: :android,
    serial: "emulator-5554",
    name: "Pixel 8",
    type: :emulator,
    node: :"app_android_emulator_5554@127.0.0.1"
  }

  @simulator %Device{
    platform: :ios,
    serial: "2CAF98B3-FFAF-42D0-AA93-F62694E2BFE4",
    name: "iPhone 17",
    type: :simulator,
    node: :"app_ios@127.0.0.1"
  }

  @plugins [
    {:mob_location,
     %{
       name: :mob_location,
       selftest: MobLocation.SelfTest,
       android: %{permissions: ["android.permission.ACCESS_FINE_LOCATION"]}
     }, :ok},
    {:mob_deliver, %{name: :mob_deliver}, :ok}
  ]

  defp entries(:pass),
    do: [
      %{plugin: :mob_location, module: MobLocation.SelfTest, result: :pass, ms: 4},
      %{plugin: :mob_deliver, module: nil, result: {:skip, "no selftest in manifest"}, ms: 0}
    ]

  defp entries(:fail),
    do: [
      %{
        plugin: :mob_location,
        module: MobLocation.SelfTest,
        result: {:fail, "location_stop/0 returned {:error, :nif_not_loaded}"},
        ms: 2
      }
    ]

  # Records every step so the test can check what ran, and in which order.
  defp deps(devices, outcome, opts \\ []) do
    test = self()
    failed = Keyword.get(opts, :failed, [])
    lost = Keyword.get(opts, :lost, [])
    leases = Keyword.get(opts, :leases, %DeviceLeases{})

    %{
      plugins: fn -> @plugins end,
      leases: fn -> leases end,
      discover: fn platforms ->
        send(test, {:discover, platforms})
        devices
      end,
      grant: fn device, plugins ->
        send(test, {:grant, device.serial})

        MobDev.Plugin.SelfTest.android_permissions(plugins)
        |> Enum.map(fn {p, perm} -> %{plugin: p, permission: perm, status: :ok} end)
      end,
      connect: fn connect_opts ->
        send(test, {:connect, connect_opts})
        only = Keyword.fetch!(connect_opts, :only)
        connected = (Enum.filter(devices, &(&1.serial in only)) -- failed) -- lost
        {connected, failed}
      end,
      run_all: fn node, ctx, run_opts ->
        send(test, {:run_all, node, ctx, run_opts})
        entries(outcome)
      end
    }
  end

  defp run_task(args, deps) do
    capture_io(fn -> send(self(), {:result, SelftestTask.run(args, deps)}) end)
  end

  defp steps do
    {:messages, messages} = Process.info(self(), :messages)
    messages |> Enum.map(&elem(&1, 0)) |> Enum.filter(&(&1 in [:grant, :connect, :run_all]))
  end

  test "passes, printing a table per device, when every self-test passed or skipped" do
    output = run_task([], deps([@emulator], :pass))

    assert_received {:result, :ok}
    assert output =~ "Pixel 8 (emulator-5554) android emulator"
    assert output =~ "mob_location  pass     4"
    assert output =~ "mob_deliver   skip     0   no selftest in manifest"
    assert output =~ "1 passed, 0 failed, 1 skipped"
    assert output =~ "mob.selftest passed on 1 device(s)"
  end

  test "fails (non-zero exit) naming the device and plugin when a self-test failed" do
    error = assert_raise Mix.Error, fn -> run_task([], deps([@emulator], :fail)) end

    assert error.message =~ "mob.selftest failed:"

    assert error.message =~
             "Pixel 8 (emulator-5554) mob_location: location_stop/0 returned {:error, :nif_not_loaded}"
  end

  test "grants the manifests' permissions before relaunching, then runs with the device's context" do
    run_task(["--timeout", "5000"], deps([@emulator], :pass))

    assert steps() == [:grant, :connect, :run_all]

    assert_received {:discover, [:android, :ios]}
    assert_received {:grant, "emulator-5554"}
    assert_received {:connect, connect_opts}
    assert_received {:run_all, :"app_android_emulator_5554@127.0.0.1", ctx, run_opts}

    assert Keyword.fetch!(connect_opts, :only) == ["emulator-5554"]
    assert Keyword.fetch!(connect_opts, :restart) == true
    assert Keyword.fetch!(connect_opts, :platforms) == [:android]
    assert ctx == %{platform: :android, device: :emulator}
    assert Keyword.fetch!(run_opts, :timeout_ms) == 5000
    assert Keyword.fetch!(run_opts, :plugins) == @plugins
  end

  test "--no-restart attaches to the running app without granting, --device narrows the targets" do
    output = run_task(["--no-restart", "-d", "2CAF98B3"], deps([@emulator, @simulator], :pass))

    assert_received {:result, :ok}
    assert steps() == [:connect, :run_all]
    assert_received {:connect, connect_opts}
    assert Keyword.fetch!(connect_opts, :restart) == false
    assert Keyword.fetch!(connect_opts, :only) == [@simulator.serial]
    assert_received {:run_all, :"app_ios@127.0.0.1", %{platform: :ios, device: :simulator}, _}
    assert output =~ "iPhone 17"
    refute output =~ "Pixel 8"
  end

  test "two development devices need --all-devices; with it both run" do
    assert_raise Mix.Error, fn -> run_task([], deps([@emulator, @simulator], :pass)) end
    refute_received {:connect, _}

    run_task(["--all-devices"], deps([@emulator, @simulator], :pass))
    assert_received {:result, :ok}
    assert_received {:run_all, :"app_android_emulator_5554@127.0.0.1", _, _}
    assert_received {:run_all, :"app_ios@127.0.0.1", _, _}
  end

  test "a device another agent-device session holds is left alone unless named" do
    claimed = %DeviceLeases{
      claims: [
        %{
          id: "emulator-5554",
          platform: :android,
          kind: :emulator,
          session: "other",
          workspace: "/w"
        }
      ]
    }

    run_task([], deps([@emulator, @simulator], :pass, leases: claimed))
    assert_received {:result, :ok}
    refute_received {:grant, "emulator-5554"}
    assert_received {:connect, connect_opts}
    assert Keyword.fetch!(connect_opts, :only) == [@simulator.serial]
  end

  test "a selected device whose node could not be reached fails the run" do
    down = %{@simulator | node: nil, status: :error, error: "no node after 30 s"}

    error =
      assert_raise Mix.Error, fn ->
        run_task(["--all-devices"], deps([@emulator, @simulator], :pass, failed: [down]))
      end

    assert error.message =~
             "iPhone 17 (#{@simulator.serial}): node not reachable (no node after 30 s)"

    # The reachable device still ran.
    assert_received {:run_all, :"app_android_emulator_5554@127.0.0.1", _, _}
  end

  test "a device lost between discovery and connect fails the run instead of passing on 0 devices" do
    error =
      assert_raise Mix.Error, fn ->
        run_task([], deps([@emulator], :pass, lost: [@emulator]))
      end

    assert error.message =~ "Pixel 8 (emulator-5554): not found when connecting"
    refute_received {:run_all, _, _, _}
  end

  test "prints the permissions it granted" do
    output = run_task([], deps([@emulator], :pass))
    assert output =~ "Pixel 8 (emulator-5554) permissions:"
    assert output =~ "granted android.permission.ACCESS_FINE_LOCATION (mob_location)"
  end

  test "no devices is an error, not a pass" do
    error = assert_raise Mix.Error, fn -> run_task([], deps([], :pass)) end
    assert error.message =~ "No connected devices"
    refute_received {:run_all, _, _, _}
  end

  test "rejects unknown options, a bad timeout and both platform flags" do
    assert_raise Mix.Error, ~r/Unknown option/, fn ->
      run_task(["--flows", "x"], deps([], :pass))
    end

    assert_raise Mix.Error, ~r/--timeout must be/, fn ->
      run_task(["--timeout", "0"], deps([], :pass))
    end

    assert_raise Mix.Error, ~r/Cannot combine/, fn ->
      run_task(["--ios-only", "--android-only"], deps([], :pass))
    end
  end

  test "--help prints the usage and runs nothing" do
    output = run_task(["--help"], deps([@emulator], :fail))
    assert output =~ "mix mob.selftest"
    assert_received {:result, _}
    refute_received {:discover, _}
  end
end
