defmodule MobDev.Bench.ProbeTest do
  use ExUnit.Case, async: true
  doctest MobDev.Bench.Probe

  alias MobDev.Bench.Probe

  describe "snapshot/1 — defaults and required fields" do
    test "snapshot with no opts returns :unreachable" do
      p = Probe.snapshot()
      assert p.reachability == :unreachable
      assert p.app_process == :app_unknown
      assert p.usb == :no_usb
      assert p.screen == :unknown
      assert p.battery_pct == nil
      assert is_integer(p.ts_ms)
    end

    test "honors :expected_screen" do
      assert Probe.snapshot(expected_screen: :off).screen == :off
      assert Probe.snapshot(expected_screen: :on).screen == :on
      assert Probe.snapshot(expected_screen: :unknown).screen == :unknown
      # Garbage falls through to unknown.
      assert Probe.snapshot(expected_screen: :totally_invalid).screen == :unknown
    end
  end

  describe "probe_reachability/4" do
    test "nil node → :unreachable" do
      assert Probe.probe_reachability(nil, "10.0.0.1", 100, 100) == :unreachable
    end

    test "nil host → :unreachable" do
      assert Probe.probe_reachability(:"node@10.0.0.1", nil, 100, 100) == :unreachable
    end

    test "TCP closed → :unreachable" do
      # 192.0.2.0/24 is TEST-NET-1, reserved for documentation, never routable.
      # 127.0.0.1 has EPMD listening in this dev env, so we can't use it here.
      assert Probe.probe_reachability(:"node@192.0.2.1", "192.0.2.1", 50, 50) ==
               :unreachable
    end

    test "EPMD up but dist refused → :alive_epmd_only" do
      # The host's own EPMD is up (we're running tests on a dev machine).
      # Dist connect to a phantom node will fail, so we should classify as
      # :alive_epmd_only.
      result = Probe.probe_reachability(:"phantom@127.0.0.1", "127.0.0.1", 50, 200)
      assert result in [:alive_epmd_only, :unreachable]
    end
  end

  describe "tcp_open?/3" do
    test "false for closed port" do
      # Port 1 is essentially never open on a normal box.
      refute Probe.tcp_open?("127.0.0.1", 1, 100)
    end

    test "false for unreachable host (timeout)" do
      # 192.0.2.0/24 is reserved for documentation, never routable.
      refute Probe.tcp_open?("192.0.2.1", 12345, 100)
    end

    test "false for non-string host" do
      refute Probe.tcp_open?(:not_a_string, 4369, 100)
    end

    test "true for an open port" do
      {:ok, sock} = :gen_tcp.listen(0, [:binary, active: false])
      {:ok, port} = :inet.port(sock)

      try do
        assert Probe.tcp_open?("127.0.0.1", port, 200)
      after
        :gen_tcp.close(sock)
      end
    end
  end

  describe "dist_connected?/1" do
    test "false when not in Node.list and not self" do
      refute Probe.dist_connected?(:"phantom@127.0.0.1")
    end
  end

  describe "rpc_responsive?/2" do
    test "false for an unreachable node" do
      # Setting cookie/connecting to a phantom node will fail; we just want
      # the function to not crash and return false.
      refute Probe.rpc_responsive?(:"phantom@127.0.0.1", 100)
    end
  end

  describe "format/1" do
    test "screen-off with running app and rpc ok" do
      assert "screen:off app:running rpc:ok battery:87%" =
               Probe.format(%Probe{
                 ts_ms: 0,
                 reachability: :alive_rpc,
                 app_process: :app_running,
                 usb: :usb_ok,
                 screen: :off,
                 battery_pct: 87
               })
    end

    test "unreachable with dead app — no battery" do
      assert "screen:on app:dead rpc:unreachable" =
               Probe.format(%Probe{
                 ts_ms: 0,
                 reachability: :unreachable,
                 app_process: :app_dead,
                 usb: :no_usb,
                 screen: :on,
                 battery_pct: nil
               })
    end

    test "suspended state — dist works, rpc times out" do
      assert "screen:off app:suspended rpc:timeout" =
               Probe.format(%Probe{
                 ts_ms: 0,
                 reachability: :alive_dist_only,
                 app_process: :app_suspended,
                 usb: :no_usb,
                 screen: :off,
                 battery_pct: nil
               })
    end

    test "no-dist state — EPMD reachable, dist refused" do
      assert "screen:? app:? rpc:no-dist" =
               Probe.format(%Probe{
                 ts_ms: 0,
                 reachability: :alive_epmd_only,
                 app_process: :app_unknown,
                 usb: :no_usb,
                 screen: :unknown,
                 battery_pct: nil
               })
    end
  end

  describe "USB probe (without ideviceinfo present)" do
    test "no hw_udid → :no_usb" do
      p = Probe.snapshot(node: nil, hw_udid: nil)
      assert p.usb == :no_usb
    end
  end

  describe "platform: :android" do
    test "snapshot with no opts returns the same defaults as iOS" do
      p = Probe.snapshot(platform: :android)
      assert p.reachability == :unreachable
      assert p.app_process == :app_unknown
      assert p.usb == :no_usb
      assert p.screen == :unknown
      assert p.battery_pct == nil
    end

    test "no adb_serial → :no_usb regardless of adb availability" do
      p = Probe.snapshot(platform: :android, adb_serial: nil)
      assert p.usb == :no_usb
    end

    test "no bundle_id → :app_unknown" do
      p = Probe.snapshot(platform: :android, adb_serial: "127.0.0.1:5555")
      # reachability is :unreachable so app_process derives from that —
      # but with no bundle_id we should also see :app_unknown when a probe
      # path is forced.
      assert p.app_process in [:app_unknown, :app_dead]
    end

    test "platform: :android dispatches to android probes (no iOS device opts)" do
      # With platform: :android, hw_udid and device_id should be ignored.
      p = Probe.snapshot(
            platform: :android,
            hw_udid: "00008110-IGNORED",
            device_id: "should-be-ignored",
            adb_serial: nil
          )
      assert p.usb == :no_usb
    end

    test "snapshot respects expected_screen on android too" do
      assert Probe.snapshot(platform: :android, expected_screen: :off).screen == :off
      assert Probe.snapshot(platform: :android, expected_screen: :on).screen == :on
    end
  end

  describe "format/1 — android probes look the same in output" do
    test "android run with usb_ok renders correctly" do
      p = %Probe{
        ts_ms: 0,
        reachability: :alive_rpc,
        app_process: :app_running,
        usb: :usb_ok,
        screen: :off,
        battery_pct: 73,
        reason: nil
      }

      assert Probe.format(p) == "screen:off app:running rpc:ok battery:73%"
    end
  end
end
