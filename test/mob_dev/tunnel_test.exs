defmodule MobDev.TunnelTest do
  use ExUnit.Case, async: true

  alias MobDev.Tunnel

  describe "serial_base_port/1" do
    test "is deterministic — same serial always maps to the same port" do
      assert Tunnel.serial_base_port("ZY22CRLMWK") == Tunnel.serial_base_port("ZY22CRLMWK")
    end

    test "stays within the [9100, 9900) window" do
      for serial <- ~w(ZY22CRLMWK ZY22K6BSJM emulator-5554 00008110-001E1C3A34F8401E foo bar) do
        port = Tunnel.serial_base_port(serial)
        assert port >= 9100 and port < 9900
      end
    end

    test "different serials generally map to different ports (no per-run index collision)" do
      # The whole point: two phones (or two projects' device-0) no longer both
      # land on 9100. crc32 spreads them across the window.
      ports =
        Enum.map(~w(ZY22CRLMWK ZY22K6BSJM ZY22DP6HFL emulator-5554), &Tunnel.serial_base_port/1)

      assert length(Enum.uniq(ports)) == length(ports)
    end
  end

  describe "assign_dist_port/2" do
    test "returns the serial's base port when nothing is in use" do
      assert Tunnel.assign_dist_port("ZY22CRLMWK") == Tunnel.serial_base_port("ZY22CRLMWK")
    end

    test "bumps to a free port when the base is taken (collision avoidance)" do
      base = Tunnel.serial_base_port("ZY22CRLMWK")
      taken = MapSet.new([base])
      assigned = Tunnel.assign_dist_port("ZY22CRLMWK", taken)

      assert assigned != base
      refute MapSet.member?(taken, assigned)
      assert assigned >= 9100 and assigned < 9900
    end

    test "always returns a port not in the in-use set" do
      base = Tunnel.serial_base_port("ZY22CRLMWK")
      # A contiguous block starting at the base forces several bumps.
      taken = MapSet.new(for n <- 0..9, do: 9100 + rem(base - 9100 + n, 800))
      assigned = Tunnel.assign_dist_port("ZY22CRLMWK", taken)

      refute MapSet.member?(taken, assigned)
      assert assigned >= 9100 and assigned < 9900
    end
  end
end
