defmodule MobDev.ConfigTest do
  use ExUnit.Case, async: true

  alias MobDev.Config

  describe "parse_platforms/1" do
    test "nil (unset) defaults to both platforms" do
      assert Config.parse_platforms(nil) == [:android, :ios]
    end

    test "a single platform is kept" do
      assert Config.parse_platforms([:ios]) == [:ios]
      assert Config.parse_platforms([:android]) == [:android]
    end

    test "both platforms normalize to a stable order" do
      assert Config.parse_platforms([:ios, :android]) == [:android, :ios]
    end

    test "unknown entries are dropped, valid ones kept" do
      assert Config.parse_platforms([:windows, :ios]) == [:ios]
    end

    test "an empty list falls back to both platforms" do
      assert Config.parse_platforms([]) == [:android, :ios]
    end

    test "a list with no valid platforms falls back to both" do
      assert Config.parse_platforms([:bogus, "ios"]) == [:android, :ios]
    end

    test "a non-list value falls back to both platforms" do
      assert Config.parse_platforms(:ios) == [:android, :ios]
      assert Config.parse_platforms("ios") == [:android, :ios]
    end
  end
end
