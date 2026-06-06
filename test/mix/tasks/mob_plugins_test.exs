defmodule Mix.Tasks.Mob.PluginsTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Mob.Plugins

  describe "normalize_activated/1 (config :mob, :plugins coercion)" do
    test "keeps a clean list of atom plugin names" do
      assert Plugins.normalize_activated([:a, :b]) == [:a, :b]
    end

    test "filters out non-atom entries (e.g. a stray string typo)" do
      assert Plugins.normalize_activated([:a, "mob_haptic", :b]) == [:a, :b]
    end

    test "a non-list (misconfigured) value coerces to [] instead of crashing" do
      # The defect: `name in activated` raises Protocol.UndefinedError when
      # :plugins is a non-list (e.g. a bare map or atom).
      assert Plugins.normalize_activated(%{a: 1}) == []
      assert Plugins.normalize_activated(:not_a_list) == []
      assert Plugins.normalize_activated(nil) == []
    end
  end
end
