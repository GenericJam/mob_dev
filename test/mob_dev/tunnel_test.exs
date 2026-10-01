defmodule MobDev.TunnelTest do
  use ExUnit.Case, async: true

  alias MobDev.Tunnel

  describe "base_port/2" do
    test "is stable: the same app on the same device always gets the same port" do
      assert Tunnel.base_port("emulator-5556", "mob_deliver_hello") ==
               Tunnel.base_port("emulator-5556", "mob_deliver_hello")
    end

    test "stays within the [9100, 9900) window" do
      for serial <- ~w(ZY22CRLMWK ZY22K6BSJM emulator-5554 00008110-001E1C3A34F8401E foo),
          app <- ~w(my_app mdfix mob_deliver_hello x) do
        assert Tunnel.base_port(serial, app) in 9100..9899
      end
    end

    # N18: two apps on one emulator both took the serial's port, and the second
    # one's dist failed with :nodistribution.
    test "distinct apps on the same device get distinct ports" do
      ports =
        for app <- ~w(mob_deliver_hello mdfix mdfix2 mob_wake_verify muster_app),
            do: Tunnel.base_port("emulator-5556", app)

      assert length(Enum.uniq(ports)) == length(ports)
    end

    test "hash collisions are resolved: apps started one after another never share a port" do
      # crc32 into 800 slots collides now and then (birthday odds); what keeps
      # two live apps apart is that each one's port is in use for the next.
      apps = for n <- 1..60, do: "app_#{n}"

      ports =
        apps
        |> Enum.map_reduce(MapSet.new(), fn app, in_use ->
          port = Tunnel.assign_dist_port("emulator-5556", app, in_use)
          {port, MapSet.put(in_use, port)}
        end)
        |> elem(0)

      assert length(Enum.uniq(ports)) == length(apps)
      # The fixture does contain a collision, so the bump path was exercised.
      bases = Enum.map(apps, &Tunnel.base_port("emulator-5556", &1))
      assert length(Enum.uniq(bases)) < length(apps)
    end
  end

  describe "assign_dist_port/3" do
    test "returns the base port when nothing is in use" do
      assert Tunnel.assign_dist_port("ZY22CRLMWK", "my_app") ==
               Tunnel.base_port("ZY22CRLMWK", "my_app")
    end

    test "bumps past every port already in use, staying in the window" do
      base = Tunnel.base_port("ZY22CRLMWK", "my_app")
      # A contiguous block starting at the base forces several bumps.
      taken = MapSet.new(for n <- 0..9, do: 9100 + rem(base - 9100 + n, 800))
      assigned = Tunnel.assign_dist_port("ZY22CRLMWK", "my_app", taken)

      refute MapSet.member?(taken, assigned)
      assert assigned in 9100..9899
    end
  end

  describe "in_use_ports/4 and stale_dist_forwards/4" do
    @epmd [
      {"mdfix_android_emulator_5558", 9764},
      {"other_app_android_emulator_5558", 9300},
      {"mdfix_ios_90e55910", 9312}
    ]
    @forwards """
    emulator-5558 tcp:9764 tcp:9764
    emulator-5558 tcp:9300 tcp:9300
    emulator-5558 tcp:9555 tcp:9555
    emulator-5558 tcp:51340 localabstract:mobilecli-server
    emulator-5554 tcp:9119 tcp:9119
    """
    @own :"mdfix_android_emulator_5558@127.0.0.1"

    test "the app's own node and this device's forwards don't block its port" do
      in_use = Tunnel.in_use_ports(@epmd, @forwards, @own, "emulator-5558")

      refute 9764 in in_use
      refute 9555 in in_use
      # Another app's live node, another sim's node, another device's forward.
      assert MapSet.new([9300, 9312, 9119]) == in_use
    end

    test "cleaning removes only this device's stale dist forwards" do
      # 9300 is another app on the same emulator, live: connecting to mdfix
      # must not cut it off. The localabstract forward isn't ours at all.
      assert Tunnel.stale_dist_forwards(@forwards, @epmd, @own, "emulator-5558") == [9764, 9555]
    end
  end

  describe "forward_owner/2" do
    @list """
    emulator-5554 tcp:9119 tcp:9119
    emulator-5554 tcp:51340 localabstract:mobilecli-server
    ZY22DP6HFL tcp:9721 tcp:9721
    """

    test "names the device a host port already forwards to" do
      assert Tunnel.forward_owner(@list, 9119) == "emulator-5554"
      assert Tunnel.forward_owner(@list, 9721) == "ZY22DP6HFL"
    end

    test "a port nobody forwards has no owner, even when another port contains its digits" do
      assert Tunnel.forward_owner(@list, 911) == nil
      assert Tunnel.forward_owner(@list, 9100) == nil
      assert Tunnel.forward_owner("", 9100) == nil
    end
  end
end
