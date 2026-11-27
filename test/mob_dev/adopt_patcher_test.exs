defmodule MobDev.Adopt.PatcherTest do
  use ExUnit.Case, async: true

  alias MobDev.Adopt.Patcher

  # MOB-552: generated apps take the private cookie mob_dev hands them; they
  # must not name the public legacy one.
  describe "generated Mob.Dist start" do
    test "the thin client leaves the cookie to mob_dev" do
      content = Patcher.mob_app_content_thin("MyApp", "my_app")

      assert content =~ ~s|Mob.Dist.ensure_started(node: :"my_app_android@127.0.0.1")|
      refute content =~ "cookie:"
    end

    test "the LiveView app leaves the cookie to mob_dev" do
      content = Patcher.mob_live_app_content("MyApp", "my_app", "skb", "salt")

      assert content =~ ~s|Mob.Dist.ensure_started(node: :"my_app_android@127.0.0.1")|
      refute content =~ "cookie:"
    end
  end
end
