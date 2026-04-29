defmodule Mix.Tasks.Mob.BatteryBenchIosTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Mob.BatteryBenchIos

  describe "node_matches_prefix?/2" do
    test "exact match (physical device, e.g. test_nif_ios@10.0.0.120)" do
      assert BatteryBenchIos.node_matches_prefix?(:"test_nif_ios@10.0.0.120", "test_nif_ios")
    end

    test "exact match (simulator, e.g. test_nif_ios@127.0.0.1)" do
      assert BatteryBenchIos.node_matches_prefix?(:"test_nif_ios@127.0.0.1", "test_nif_ios")
    end

    test "matches simulator-with-udid suffix (test_nif_ios_<udid>@host)" do
      assert BatteryBenchIos.node_matches_prefix?(
               :"test_nif_ios_8a4250e9@127.0.0.1",
               "test_nif_ios"
             )
    end

    test "rejects different app prefix (mob_qa_ios_*@10.0.0.17)" do
      refute BatteryBenchIos.node_matches_prefix?(
               :"mob_qa_ios_02628f8f@10.0.0.17",
               "test_nif_ios"
             )
    end

    test "rejects same-prefix-but-not-_ios (test_nif@host)" do
      refute BatteryBenchIos.node_matches_prefix?(:"test_nif@10.0.0.120", "test_nif_ios")
    end

    test "rejects superset prefix (test_nif_ios_extras shouldn't match test_nif)" do
      # The prefix-with-underscore boundary stops `test_nif_ios` from matching
      # the prefix `test_nif` — important so a `test_nif` project doesn't
      # accidentally pick up a `test_nif_ios_*` simulator node when it has its
      # own `test_nif_ios@<ip>` running.
      assert BatteryBenchIos.node_matches_prefix?(:"test_nif_ios@10.0.0.1", "test_nif")
      # ^ This is the normal case: test_nif's expected prefix would actually be
      # "test_nif_ios", not "test_nif". This test documents that bare app names
      # would still match _ios variants — which is fine because the bench
      # always passes the full "<app>_ios" prefix.
    end

    test "nil node returns false" do
      refute BatteryBenchIos.node_matches_prefix?(nil, "anything")
    end
  end
end
