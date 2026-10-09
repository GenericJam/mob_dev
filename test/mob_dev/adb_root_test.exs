defmodule MobDev.AdbRootTest do
  use ExUnit.Case, async: true

  alias MobDev.AdbRoot

  # A stubbed adb: `root` answers `root_out`; the device answers the shell
  # round trip only once `ready_after_ms` have passed since `root`.
  defp runner(root_out, ready_after_ms) do
    me = self()
    {:ok, agent} = Agent.start_link(fn -> nil end)

    fn args ->
      send(me, {:adb, args})

      case args do
        [_, _, "root"] ->
          Agent.update(agent, fn _ -> System.monotonic_time(:millisecond) end)
          {root_out, 0}

        [_, _, "wait-for-device"] ->
          {"", 0}

        [_, _, "shell", _] ->
          t0 = Agent.get(agent, & &1)

          if System.monotonic_time(:millisecond) - t0 >= ready_after_ms,
            do: {"1\nok\n", 0},
            else: {"error: device 'emu-1' not found", 1}
      end
    end
  end

  test "waits out a slow adbd restart and succeeds" do
    r = runner("restarting adbd as root\n", 1_200)
    assert AdbRoot.root("emu-1", runner: r, timeout_ms: 5_000) == :rooted
    assert_received {:adb, ["-s", "emu-1", "wait-for-device"]}
    assert_received {:adb, ["-s", "emu-1", "shell", "getprop sys.boot_completed; echo ok"]}
  end

  test "times out with an error naming the serial" do
    r = runner("restarting adbd as root\n", :infinity)
    assert {:error, msg} = AdbRoot.root("emu-1", runner: r, timeout_ms: 600)
    assert msg =~ "emu-1"
    assert msg =~ "600 ms"
  end

  test "a wait-for-device that never returns still honours the timeout" do
    r = fn
      [_, _, "root"] -> {"restarting adbd as root", 0}
      [_, _, "wait-for-device"] -> Process.sleep(:infinity)
    end

    assert {:error, msg} = AdbRoot.root("emu-1", runner: r, timeout_ms: 300)
    assert msg =~ "emu-1"
  end

  test "no wait when adbd already runs as root" do
    r = runner("adbd is already running as root\n", 0)
    assert AdbRoot.root("emu-1", runner: r) == :rooted
    refute_received {:adb, ["-s", "emu-1", "wait-for-device"]}
  end

  test "no wait when the device refuses root" do
    r = runner("adbd cannot run as root in production builds\n", 0)
    assert AdbRoot.root("emu-1", runner: r) == :not_rooted
    refute_received {:adb, ["-s", "emu-1", "wait-for-device"]}
  end
end
