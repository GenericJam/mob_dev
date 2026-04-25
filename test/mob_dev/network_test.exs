defmodule MobDev.NetworkTest do
  use ExUnit.Case, async: true

  alias MobDev.Network

  describe "first_lan_ip/1" do
    test "returns nil for empty list" do
      assert Network.first_lan_ip([]) == nil
    end

    test "returns nil when only loopback" do
      assert Network.first_lan_ip([{127, 0, 0, 1}]) == nil
    end

    test "returns nil for non-private public address" do
      assert Network.first_lan_ip([{8, 8, 8, 8}]) == nil
    end

    test "matches 10.x.x.x" do
      assert Network.first_lan_ip([{10, 0, 0, 1}]) == {10, 0, 0, 1}
      assert Network.first_lan_ip([{10, 255, 255, 255}]) == {10, 255, 255, 255}
    end

    test "matches 192.168.x.x" do
      assert Network.first_lan_ip([{192, 168, 0, 1}]) == {192, 168, 0, 1}
      assert Network.first_lan_ip([{192, 168, 1, 100}]) == {192, 168, 1, 100}
    end

    test "matches 172.16.x.x through 172.31.x.x" do
      assert Network.first_lan_ip([{172, 16, 0, 1}]) == {172, 16, 0, 1}
      assert Network.first_lan_ip([{172, 31, 0, 1}]) == {172, 31, 0, 1}
      assert Network.first_lan_ip([{172, 20, 5, 1}]) == {172, 20, 5, 1}
    end

    test "does not match 172.15.x.x (just below private range)" do
      assert Network.first_lan_ip([{172, 15, 0, 1}]) == nil
    end

    test "does not match 172.32.x.x (just above private range)" do
      assert Network.first_lan_ip([{172, 32, 0, 1}]) == nil
    end

    test "skips loopback and returns first LAN address" do
      ips = [{127, 0, 0, 1}, {192, 168, 1, 5}, {10, 0, 0, 1}]
      assert Network.first_lan_ip(ips) == {192, 168, 1, 5}
    end

    test "returns first match when multiple LAN addresses present" do
      ips = [{10, 0, 0, 1}, {192, 168, 1, 5}]
      assert Network.first_lan_ip(ips) == {10, 0, 0, 1}
    end
  end

  describe "lan_ip?/1" do
    test "loopback is false" do
      refute Network.lan_ip?({127, 0, 0, 1})
      refute Network.lan_ip?({127, 1, 2, 3})
    end

    test "10.x is true" do
      assert Network.lan_ip?({10, 0, 0, 1})
    end

    test "192.168.x is true" do
      assert Network.lan_ip?({192, 168, 1, 1})
    end

    test "172.16-31.x is true" do
      assert Network.lan_ip?({172, 16, 0, 1})
      assert Network.lan_ip?({172, 31, 0, 1})
      refute Network.lan_ip?({172, 15, 0, 1})
      refute Network.lan_ip?({172, 32, 0, 1})
    end

    test "public addresses are false" do
      refute Network.lan_ip?({8, 8, 8, 8})
      refute Network.lan_ip?({1, 1, 1, 1})
      refute Network.lan_ip?({93, 184, 216, 34})
    end
  end

  describe "lan_ip/0" do
    test "returns a tuple or nil" do
      result = Network.lan_ip()
      assert result == nil or (is_tuple(result) and tuple_size(result) == 4)
    end
  end
end
